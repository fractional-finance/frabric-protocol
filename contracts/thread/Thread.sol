// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../interfaces/erc20/IDividendERC20.sol";
import "../interfaces/erc20/IFrabricERC20.sol";
import "../interfaces/frabric/IFrabric.sol";

import "../dao/FrabricDAO.sol";

import "../interfaces/thread/IThread.sol";

contract Thread is FrabricDAO, IThread {
  using SafeERC20 for IERC20;

  address public override agent;
  address public override frabric;
  uint256 public override upgradesEnabled;

  struct Dissolution {
    address purchaser;
    address token;
    uint256 price;
  }

  // Private as all this info is available via events
  mapping(uint256 => address) private _agents;
  mapping(uint256 => address) private _frabrics;
  mapping(uint256 => Dissolution) private _dissolutions;

  function initialize(
    address _erc20,
    address _agent,
    address _frabric
  ) external initializer {
    // The Frabric uses a 2 week voting period. If it wants to upgrade every Thread on the Frabric's code,
    // then it will be able to push an update in 2 weeks. If a Thread sees the new code and wants out,
    // it needs a shorter window in order to explicitly upgrade to the existing code to prevent Frabric upgrades
    __FrabricDAO_init(_erc20, 1 weeks);
    agent = _agent;
    frabric = _frabric;
    emit AgentChanged(address(0), agent);
    emit FrabricChanged(address(0), frabric);
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() initializer {}

  function canPropose() public view override(IDAO, DAO) returns (bool) {
    return (
      // Whitelisted token holder
      (
        IFrabricERC20(erc20).whitelisted(msg.sender) &&
        (IERC20(erc20).balanceOf(msg.sender) != 0)
      ) ||
      // Both of these should also be whitelisted. It's not technically a requirement however
      // The Thread is allowed to specify whoever they want for either, and if they are splitting off,
      // they should successfully manage their own whitelist, yet there's no reason to force it here
      // Agent
      (msg.sender == address(agent)) ||
      // Frabric
      (msg.sender == address(frabric))
    );
  }

  function _canProposeUpgrade(
    address beacon,
    address instance,
    address code
  ) internal view override returns (bool) {
    return (
      // If upgrades are enabled, all good
      (block.timestamp >= upgradesEnabled) ||
      // Upgrades to the current code/release channels are always allowed
      // This prevents the Frabric from forcing an update onto Threads and allows
      // switching between versions presumably published by the Frabric
      (code == IFrabricBeacon(beacon).implementation(instance)) ||
      (uint160(code) <= IFrabricBeacon(beacon).releaseChannels())
    );
  }

  function proposeEnablingUpgrades(string calldata info) external returns (uint256) {
    // Doesn't emit a dedicated event for the same reason Paper proposals don't
    return _createProposal(uint256(ThreadProposalType.EnableUpgrades), info);
  }

  function proposeAgentChange(
    address _agent,
    string calldata info
  ) external override returns (uint256) {
    _agents[_nextProposalID] = _agent;
    emit AgentChangeProposed(_nextProposalID, _agent);
    return _createProposal(uint256(ThreadProposalType.AgentChange), info);
  }

  function proposeFrabricChange(
    address _frabric,
    string calldata info
  ) external override returns (uint256) {
    _frabrics[_nextProposalID] = _frabric;
    emit FrabricChangeProposed(_nextProposalID, _frabric);
    return _createProposal(uint256(ThreadProposalType.FrabricChange), info);
  }

  function proposeDissolution(
    address token,
    uint256 price,
    string calldata info
  ) external override returns (uint256) {
    if (price == 0) {
      revert ZeroPrice();
    }
    _dissolutions[_nextProposalID] = Dissolution(msg.sender, token, price);
    emit DissolutionProposed(_nextProposalID, msg.sender, token, price);
    return _createProposal(uint256(ThreadProposalType.Dissolution), info);
  }

  function _completeSpecificProposal(uint256 id, uint256 _pType) internal override {
    ThreadProposalType pType = ThreadProposalType(_pType);
    if (pType == ThreadProposalType.EnableUpgrades) {
      // Enable upgrades after the Frabric's voting period + 1 week

      // There is an attack where a Thread upgrades and claws back timelocked tokens
      // Once this proposal passes, the Frabric can immediately void its timelock,
      // yet it'll need 2 weeks to pass a proposal on what to do with them
      // The added 1 week is because neither selling on the token's DEX nor an auction
      // would complete instantly, so this gives a buffer for it to execute

      // While the Frabric also needs time to decide what to do and can't be expected
      // to be perfect with time, enabling upgrades only enables Upgrade proposals to be created
      // That means there's an additional delay of the Thread's voting period (1 week)
      // while the actual Upgrade proposal occurs, granting that time
      upgradesEnabled = block.timestamp + IDAO(frabric).votingPeriod() + (1 weeks);

    } else if (pType == ThreadProposalType.AgentChange) {
      emit AgentChanged(agent, _agents[id]);
      agent = _agents[id];
      delete _agents[id];

    } else if (pType == ThreadProposalType.FrabricChange) {
      emit FrabricChanged(frabric, _frabrics[id]);
      frabric = _frabrics[id];
      // Update our parent whitelist to the new Frabric's
      IFrabricERC20(erc20).setParentWhitelist(IFrabric(frabric).erc20());
      delete _frabrics[id];

    } else if (pType == ThreadProposalType.Dissolution) {
      // Prevent the Thread from being locked up in a Dissolution the agent won't honor for whatever reason
      // This will issue payment and then the agent will be obligated to transfer property or have bond slashed
      // Not calling complete on a passed Dissolution may also be grounds for a bond slash
      // The intent is to allow the agent to not listen to impropriety with the Frabric as arbitrator
      // See the Frabric's community policies for more information on process
      if (msg.sender != agent) {
        revert NotAgent(msg.sender, agent);
      }
      Dissolution storage dissolution = _dissolutions[id];
      IERC20(dissolution.token).safeTransferFrom(dissolution.purchaser, address(this), dissolution.price);
      IFrabricERC20(erc20).pause();
      IERC20(dissolution.token).approve(erc20, dissolution.price);
      // See IFrabricERC20 for why that doesn't include IDividendERC20 despite FrabricERC20 being a DividendERC20
      IDividendERC20(erc20).distribute(dissolution.token, dissolution.price);
      emit Dissolved(id);
      delete _dissolutions[id];

    } else {
      revert UnhandledEnumCase("Thread _completeSpecificProposal", _pType);
    }
  }
}
