// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable as SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import "../common/Composable.sol";

import "../interfaces/erc20/IDistributionERC20.sol";

/** 
 * @title DistributionERC20 abstract contract
 * @author Fractional Finance
 * @notice This contract expands ERC20Votes with distribution functionality
 * @dev Upgradable contract
 */
abstract contract DistributionERC20 is ReentrancyGuardUpgradeable, ERC20VotesUpgradeable, Composable, IDistributionERC20 {
  using SafeERC20 for IERC20;

  struct DistributionStruct {
    address token;
    uint32 block;
    // 8 bytes left above
    // 4 bytes left below
    uint112 amount;
    // Restricts descendants to not mint beyond uint112
    uint112 supply;
  }

  uint256 private _nextID;
  // Mapping chosen over array for gas efficiency and potential for struct extensibility
  mapping(uint256 => DistributionStruct) private _distributions;
  /// @notice Mapping to keep track of which users have claimed over all distributions
  mapping(uint256 => mapping(address => bool)) public override claimed;

  uint256[100] private __gap;

  function __DistributionERC20_init(string memory name, string memory symbol) internal {
    __ReentrancyGuard_init();
    __ERC20_init(name, symbol);
    __ERC20Permit_init(name);
    __ERC20Votes_init();

    supportsInterface[type(IERC20).interfaceId] = true;
    supportsInterface[type(IERC20PermitUpgradeable).interfaceId] = true;
    supportsInterface[type(IVotesUpgradeable).interfaceId] = true;
    supportsInterface[type(IDistributionERC20).interfaceId] = true;
  }


  // Does not hook into _transfer as _mint does not pass through it
  function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._afterTokenTransfer(from, to, amount);
    // Delegate to self to track voting power, if not already tracked
    if (delegates(to) == address(0x0)) {
      super._delegate(to, to);
    }
  }

  /**
   * Disable delegation to enable distributions, removing the need to track
   * both historic balances and voting power. Also reduces potential legal liability, which
   * could be a future concern. Vote delegation may be enabled in the future, but it would
   * require duplication of the checkpointing code to keep voting private varibles in ERC20Votes
   * as purely votes. It is better to duplicate it in the future if required, retaining
   * control over the process. 
   */
  function _delegate(address, address) internal pure override {
    revert Delegation();
  }

  function _distribute(address token, uint112 amount) internal returns (uint256 id) {
    if (amount == 0) {
      revert ZeroAmount();
    }

    id = _nextID;
    _nextID++;
    _distributions[id] = DistributionStruct(
      token,
      uint32(block.number - 1),
      amount,
      // Cache the supply so each claim does not have to repeat this binary search
      uint112(getPastTotalSupply(block.number - 1))
    );
    emit Distribution(id, token, amount);
  }

  /**
   * @notice Distribute a token
   * @param token Token address to be distributed
   * @param amount Amount of tokens (`token`) to be distributed
   * @return id Id of the distribution in the _distributions mapping
   */
  function distribute(address token, uint112 amount) public override nonReentrant returns (uint256) {
    uint256 balance = IERC20(token).balanceOf(address(this));
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    /**
     * Notably, USDT does have a fee-on-transfer propery, albeit set to 0.
     * In the future, USDT distributions and any downstream flows could break.
     * Fee-on-transfer tokens are very challenging to integrate as they require a
     * reentrancy vulnerable balance check. As Crowdfund inherits from this contract,
     * you could buy crowdfund tokens with funds destined for this distribution. 
     * This requires reentrancy checks on every function, or banning fee-on-transfer tokens
     * from the protocol. The latter was chosen here
     */
    if (IERC20(token).balanceOf(address(this)) != (balance + amount)) {
      revert FeeOnTransfer(token);
    }
    return _distribute(token, amount);
  }

  /// @notice Claim tokens from a distribution
  /// @param id Id of distribution to be claimed from
  /// @param person Address of user claiming distributed tokens
  function claim(uint256 id, address person) external override {
    if (claimed[id][person]) {
      revert AlreadyClaimed(id, person);
    }
    claimed[id][person] = true;

    DistributionStruct storage distribution = _distributions[id];
    // Appropriate as amount will never exceed distribution.amount, which is a uint112
    uint112 amount = uint112(
      uint256(distribution.amount) * getPastVotes(person, distribution.block) / distribution.supply
    );
    // Also verifies this is a valid distribution rather an unset ID
    if (amount == 0) {
      revert ZeroAmount();
    }

    IERC20(distribution.token).safeTransfer(person, uint112(amount));
    emit Claim(id, person, amount);
  }
}
