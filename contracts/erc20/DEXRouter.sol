// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/erc20/IIntegratedLimitOrderDEX.sol";

import "../common/Composable.sol";

import "../interfaces/erc20/IDEXRouter.sol";

/**
 * The IntegratedLimitOrderDEX contract may be upgraded with the FrabricERC20 contract by a Thread.
 * While this behaviour is intended, it would enable a rougue Thread to drain user wallets, since they
 * are expected to enable infinite approvals for UX purposes.
 * This non-upgradable contract resolves this issue, users need only approve the router to spend their non Frabric tokens.
 * Frabric tokens are still directly traded via the Thread contract, as are order cancellations.
 * Threads may still abscond with all tokens held in open orders.
 * A global DEX not built into each Threads ERC20 token would also be viable, although slash mechanics
 * are most effective with a built in system.
 * While Uniswap will be whitelisted, it cannot be used to hold tokens - only to swap or provide liquidity.
 */

/** 
 * @title DEXRouter contract
 * @author Fractional Finance
 * @notice This contract implements the Frabric DEXRouter
 * @dev Non-upgradable to prevent Threads draining token balances
 */
contract DEXRouter is Composable, IDEXRouter {
  constructor() Composable("DEXRouter") initializer {
    // Set here as final version to prevent upgrades
    __Composable_init("DEXRouter", true);
    supportsInterface[type(IDEXRouter).interfaceId] = true;
  }

  /**
   * @notice Execute a token swap
   * @param token Token address to be purchased
   * @param tradeToken Token address to be sold
   * @param payment Amount of tradeToken (`tradeToken`) to be sold
   * @param price Purchase price in whole tokens
   * @param minimumAmount Minimum amount of tokens (`token`) received (in whole tokens)
   * @return filled uint256 quantity of succesfully purchased tokens (`token`) 
   */
  function buy(
    address token,
    address tradeToken,
    uint256 payment,
    uint256 price,
    uint256 minimumAmount
  ) external override returns (uint256) {

    /**
     * Interface support not checked here for gas efficiency. If the function successfully runs,
     * the contract has all the required functions.
     * While tradeToken could be inferred from IIntegratedLimitOrderDEX(token), this would make the function
     * vulnerable to a frontrunning attack where the user spends a different token to the intended one.
     * SafeERC20 not used as IntegratedLimitOrderDEX will validate the transfer and repeating those checks
     * here would not be gas efficient.
     */
    IERC20(tradeToken).transferFrom(msg.sender, token, payment);

    return IIntegratedLimitOrderDEX(token).buy(msg.sender, price, minimumAmount);
  }

  /**
   * No fund recovery function is included as this contract should never hold funds.
   * A recovery function would act as an MEV pit unless a specific address received the funds,
   * however this would require the definition of a Frabric address which is not the intention
   * or intent of this contract.
   */
}
