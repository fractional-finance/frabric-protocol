// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IVotesUpgradeable as IVotes } from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/erc20/IFrabricERC20.sol";
import "../interfaces/dao/IDAO.sol";

// DAO around an ERC20 with getPastVotes (ERC20Votes)
abstract contract DAO is Initializable, IDAO {
  enum ProposalState {
    Active,
    Queued,
    Executed,
    Cancelled
  }

  enum VoteDirection {
    None,
    No,
    Yes
  }

  struct Action {
    address target;
    bytes data;
  }

  struct Proposal {
    // The following are embedded into easily accessible events
    address creator;
    ProposalState state;
    // This actually requires getting the block of the event as well, yet generally isn't needed
    uint256 stateStartTime;

    // The following are exposed via getters
    uint256 voteBlock;
    mapping(address => VoteDirection) voters;
    // Safe due to the FrabricERC20 being uint224
    int256 votes;
    uint256 totalVotes;

    // Used by inheriting contracts
    uint256 proposalType;
  }

  address public erc20;
  uint256 public votingPeriod;

  mapping(uint256 => Proposal) private _proposals;
  uint256 internal _nextProposalID;

  function __DAO_init(address _erc20, uint256 _votingPeriod) internal onlyInitializing {
    erc20 = _erc20;
    votingPeriod = _votingPeriod;
  }

  function proposalVoteBlock(uint256 id) external view override returns (uint256) {
    return _proposals[id].voteBlock;
  }
  function proposalVoteDirection(uint256 id, address voter) external view override returns (uint256) {
    return uint256(_proposals[id].voters[voter]);
  }
  function proposalVotes(uint256 id) external view override returns (int256) {
    return _proposals[id].votes;
  }
  function proposalTotalVotes(uint256 id) external view override returns (uint256) {
    return _proposals[id].totalVotes;
  }

  function proposalActive(uint256 id) public view override returns (bool) {
    return (_proposals[id].state == ProposalState.Active) && ((_proposals[id].stateStartTime + votingPeriod) > block.timestamp);
  }

  modifier activeProposal(uint256 id) {
    require(proposalActive(id), "DAO: Proposal isn't active");
    _;
  }

  // Not exposed as despite working with arbitrary calldata, this calldata is currently contract crafted for specific purposes
  function _createProposal(string calldata info, uint256 proposalType) internal returns (uint256 id) {
    id = _nextProposalID;
    _nextProposalID++;

    Proposal storage proposal = _proposals[id];
    proposal.creator = msg.sender;
    proposal.state = ProposalState.Active;
    proposal.stateStartTime = block.timestamp;
    // Use the previous block as it's finalized
    // While the creator could have sold in this block, they can also sell over the next few weeks
    // This is why cancelProposal exists
    proposal.voteBlock = block.number - 1;
    proposal.proposalType = proposalType;

    // Separate event to allow indexing by type/creator while maintaining state machine consistency
    // Also exposes info
    emit NewProposal(id, proposalType, proposal.creator, info);
    emit ProposalStateChanged(id, uint256(_proposals[id].state));

    // Automatically vote Yes for the creator
    if (IVotes(erc20).getPastVotes(msg.sender, proposal.voteBlock) != 0) {
      vote(id, uint256(VoteDirection.Yes));
    }
  }

  function vote(uint256 id, uint256 direction) public override {
    require(_proposals[id].voters[msg.sender] != VoteDirection(direction), "DAO: Already voted this way");

    int256 votes = int256(IVotes(erc20).getPastVotes(msg.sender, _proposals[id].voteBlock));
    require(votes != 0, "DAO: No votes");
    // Remove old votes
    if (_proposals[id].voters[msg.sender] == VoteDirection.Yes) {
      _proposals[id].votes -= votes;
    } else if (_proposals[id].voters[msg.sender] == VoteDirection.No) {
      _proposals[id].votes += votes;
    } else {
      // If they had previously abstained, increase the amount of total votes
      _proposals[id].totalVotes += uint256(votes);
    }

    // Set new votes
    _proposals[id].voters[msg.sender] = VoteDirection(direction);
    if (VoteDirection(direction) == VoteDirection.Yes) {
      _proposals[id].votes += votes;
    } else if (VoteDirection(direction) == VoteDirection.No) {
      _proposals[id].votes -= votes;
    } else {
      // If they're now abstaining, decrease the amount of total votes
      _proposals[id].totalVotes -= uint256(votes);
    }

    emit Vote(id, uint256(direction), msg.sender, uint256(votes));
  }

  function queueProposal(uint256 id) external activeProposal(id) {
    Proposal storage proposal = _proposals[id];
    require(proposal.votes > 0, "DAO: Queueing proposal which didn't pass");
    // Uses the current total supply instead of the historical total supply to represent the current community
    require(proposal.totalVotes > (IERC20(erc20).totalSupply() / 10), "DAO: Proposal didn't have 10% participation");
    proposal.state = ProposalState.Queued;
    proposal.stateStartTime = block.timestamp;
    emit ProposalStateChanged(id, uint256(_proposals[id].state));
  }

  function cancelProposal(uint256 id, address[] calldata voters) external {
    // Must be queued. Even if it's completable, if it has yet to be completed, allow this
    require(_proposals[id].state == ProposalState.Queued, "DAO: Cancelling a proposal which wasn't queued");

    for (uint i = 0; i < voters.length; i++) {
      require(_proposals[id].voters[voters[i]] == VoteDirection.Yes, "DAO: Specified voter didn't vote yes");
      uint256 oldVotes = IVotes(erc20).getPastVotes(voters[i], _proposals[id].voteBlock);
      uint256 votes = IERC20(erc20).balanceOf(voters[i]);
      // This will error if their votes have actually increased since
      // That would enable front running cancellation TXs with bumps of a single account
      // This shouldn't be a feasible attack vector given retries though
      // Writes directly to the votes to update it to its (more) accurate value
      _proposals[id].votes -= int256(oldVotes - votes);
    }
    require(_proposals[id].votes < 0, "DAO: Cancelling a proposal with more yes votes than no votes");

    _proposals[id].state = ProposalState.Cancelled;
    _proposals[id].stateStartTime = block.timestamp;
    emit ProposalStateChanged(id, uint256(_proposals[id].state));
  }

  function _completeProposal(uint256 id, uint256 proposalType) internal virtual;

  // Does not require canonically ordering when executing proposals in case a proposal has invalid actions, halting everything
  function completeProposal(uint256 id) external {
    require(!IFrabricERC20(erc20).paused(), "DAO: ERC20 is paused");

    // Safe against re-entrancy as long as this block is untouched as internal
    // While paused can re-enter (theoretically, it never should), it hasn't verified the proposal state yet
    // Said state will be cleared by the first instance to run
    Proposal storage proposal = _proposals[id];
    require(proposal.state == ProposalState.Queued, "DAO: Proposal wasn't queued");
    require((proposal.stateStartTime + (12 hours)) < block.timestamp, "DAO: Proposal was queued less than 12 hours ago");
    proposal.state = ProposalState.Executed;
    proposal.stateStartTime = block.timestamp;
    emit ProposalStateChanged(id, uint256(proposal.state));

    // Re-entrancy here would do nothing as the proposal has had its state updated
    _completeProposal(id, proposal.proposalType);
  }

  // Enables withdrawing a proposal
  function withdrawProposal(uint256 id) activeProposal(id) external override {
    // Only allow the proposer to withdraw a proposal.
    require((_proposals[id].state == ProposalState.Active) || (_proposals[id].state == ProposalState.Queued), "DAO: Proposal was already executed or cancelled");
    require(_proposals[id].creator == msg.sender, "DAO: Only the proposal creator may withdraw it");
    _proposals[id].state = ProposalState.Cancelled;
    _proposals[id].stateStartTime = block.timestamp;
    emit ProposalStateChanged(id, uint256(_proposals[id].state));
  }
}
