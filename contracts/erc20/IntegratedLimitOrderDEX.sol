// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable as SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../common/Composable.sol";

// Needed for errors
import "../interfaces/erc20/IFrabricWhitelist.sol";
import "../interfaces/erc20/IFrabricERC20.sol";

import "../interfaces/erc20/IIntegratedLimitOrderDEX.sol";

/** 
 * @title IntegratedLimitOrderDEX contract
 * @author Fractional Finance
 * @notice This contract implements the IntegratedLimitOrderDex for FrabricERC20
 * @dev Upgradable contract
 */
abstract contract IntegratedLimitOrderDEX is ReentrancyGuardUpgradeable, Composable, IIntegratedLimitOrderDEX {
  using SafeERC20 for IERC20;

  /// @notice Token to trade against, presumably a USD stablecoin or WETH
  address public override tradeToken;
  /// @notice Last known balance of the DEX token
  uint256 public override tradeTokenBalance;
  /// @notice DEX token balances of traders on the DEX
  mapping(address => uint256) public override tradeTokenBalances;
  /// @notice Locked funds of the token this is integrated into
  mapping(address => uint256) public override locked;

  struct OrderStruct {
    address trader;
    /**
     * Right now, we don't allow removed parties to be added back due to leftover
     * data such as DEX orders. With a versioning system, this could be effectively
     * handled. While this won't be implemented right now, as it's a pain with a
     * lot of security considerations not worth handling right now, this does leave
     * our options open (even though we could probably add it later without issue
     * as it fits into an existing storage slot)
     */
    uint8 version;
    uint256 amount;
  }

  struct PricePoint {
    OrderType orderType;
    OrderStruct[] orders;
  }

  // Indexed by price
  mapping(uint256 => PricePoint) private _points;

  // Used to flag when a transfer is triggered by the DEX, bypassing frozen
  bool internal _inDEX;

  uint256[100] private __gap;

  function _transfer(address from, address to, uint256 amount) internal virtual;

  /// @notice Query token balance of an account
  /// @param account Address to query balance of
  /// @return uint256 Token balance of `account`
  function balanceOf(address account) public view virtual returns (uint256);

  /// @notice Query decimals of token
  /// @return uint8 Decimals of token
  function decimals() public view virtual returns (uint8);

  /// @notice Check if tokens owned by address `person` are frozen
  /// @param person Address to check
  /// @return bool True if tokens owned by `person` are frozen, false otherwise
  function frozen(address person) public view virtual returns (bool);

  function _removeUnsafe(address person, uint8 fee) internal virtual;

  /// @notice Check if a user `person` is currently whitelisted
  /// @param person Address of user to be checked
  /// @return bool True is user `person` is whitelisted, false otherwise
  function whitelisted(address person) public view virtual returns (bool);

  /// @notice Check if a user `person` has been removed
  /// @param person Address of user to be checked
  /// @return bool True is user `person` has been removed, false otherwise
  function removed(address person) public view virtual returns (bool);

  function __IntegratedLimitOrderDEX_init(address _tradeToken) internal onlyInitializing {
    __ReentrancyGuard_init();
    supportsInterface[type(IIntegratedLimitOrderDEXCore).interfaceId] = true;
    supportsInterface[type(IIntegratedLimitOrderDEX).interfaceId] = true;
    tradeToken = _tradeToken;
  }

  /// @notice Convert a token quantity to atomic units
  /// @param amount Amount of full tokens to be converted to atomic units
  /// @return uint256 Atomic token units
  function atomic(uint256 amount) public view override returns (uint256) {
    return amount * (10 ** decimals());
  }

  // Since this balance cannot be used for buying, it has no use in here
  // Allow anyone to trigger a withdraw for anyone accordingly
  function _withdrawTradeToken(address trader) private {
    uint256 amount = tradeTokenBalances[trader];
    if (amount == 0) {
      return;
    }

    tradeTokenBalances[trader] = 0;
    // Even if re-entrancy was possible, the difference in actual balance and
    // tradeTokenBalance isn't exploitable. Solidity 0.8's underflow protections ensure
    // it will revert unless the balance is topped up. Topping up the balance won't
    // be credited as a transfer though and is solely an additional cost
    IERC20(tradeToken).safeTransfer(trader, amount);
    tradeTokenBalance = IERC20(tradeToken).balanceOf(address(this));
  }

  /// @notice Withdraw trade tokens for user `trader`
  /// @param trader User to have tokens withdrawn
  function withdrawTradeToken(address trader) external override nonReentrant {
    _withdrawTradeToken(trader);
  }

  // Fill orders
  function _fill(
    address trader,
    uint256 price,
    uint256 amount,
    PricePoint storage point
  ) private returns (uint256 filled) {
    bool buying = point.orderType == OrderType.Sell;

    // Fill orders until there are either no orders or our order is filled
    uint256 h = point.orders.length - 1;
    _inDEX = true;
    for (; amount != 0; h--) {
      // Trader was removed. Delete their order and move on
      // Technically this is an interaction, and check, in the middle of effects
      // This function is view meaning its only risk is calling the DEX and viewing
      // an invalid partial state to make its decision on if the trader is whitelisted
      // This function is trusted code, and here it is trusted to not be idiotic
      OrderStruct storage order = point.orders[h];
      while (!whitelisted(order.trader)) {
        _removeUnsafe(order.trader, 0);

        // If we're iterating over buy orders, return the removed trader's DEX tokens
        if (!buying) {
          tradeTokenBalances[order.trader] += price * order.amount;
        }

        emit OrderCancellation(order.trader, price, order.amount);
        point.orders.pop();

        // If all orders were by people removed, exit
        if (h == 0) {
          _inDEX = false;
          point.orderType = OrderType.Null;
          return 0;
        }

        // We could also call continue here, yet this should be a bit more efficient
        h--;
        order = point.orders[h];
      }

      uint256 thisAmount = order.amount;
      if (thisAmount > amount) {
        thisAmount = amount;
      }
      order.amount -= thisAmount;
      filled += thisAmount;
      amount -= thisAmount;
      emit OrderFill(order.trader, price, trader, thisAmount);

      uint256 atomicAmount = atomic(thisAmount);
      if (buying) {
        tradeTokenBalances[order.trader] += price * thisAmount;
        locked[order.trader] -= atomicAmount;
        _transfer(order.trader, trader, atomicAmount);
      } else {
        locked[trader] -= atomicAmount;
        _transfer(trader, order.trader, atomicAmount);
      }

      // If we filled this order, delete it
      if (order.amount == 0) {
        point.orders.pop();
      }

      // Break before underflowing
      if (h == 0) {
        break;
      }
    }
    _inDEX = false;

    // Transfer the DEX token sum if selling
    if (!buying) {
      tradeTokenBalances[trader] += filled * price;
    }

    // If we filled every order, set the order type to null
    if (point.orders.length == 0) {
      point.orderType = OrderType.Null;
    }

    return filled;
  }

  // Returns the amount of tokens filled and the position of the created order, if one exists
  // If the amount filled is equivalent to the amount, the position will be 0
  function _action(
    OrderType current,
    OrderType other,
    address trader,
    uint256 price,
    uint256 amount
  ) private returns (uint256 filled) {
    // Ensure the trader is whitelisted
    // If they're buying tokens, this would be a DoS if we didn't handle removed people above
    // Since we do, it's just pointless
    // If they're selling tokens, they shouldn't have any to sell, but they may
    // if they were removed from the whitelist yet not this ERC20 yet
    if (!whitelisted(trader)) {
      revert NotWhitelisted(trader);
    }

    /**
     * If they're currently frozen, don't let them place new orders
     * Their existing orders are allowed to stand however
     * If they were put up for a low value, anyone can snipe them
     * If they were put up for a high value, no one will bother buying them, and
     * they'll be removed if the removal proposal passes
     * If they were put up for their actual value, then this is them leaving the
     * ecosystem and that's that
     */
    if (frozen(trader)) {
      revert Frozen(trader);
    }

    if (price == 0) {
      revert ZeroPrice();
    }
    if (amount == 0) {
      revert ZeroAmount();
    }

    PricePoint storage point = _points[price];
    // If there's counter orders at this price, fill them
    if (point.orderType == other) {
      filled = _fill(trader, price, amount, point);
      // Return if fully filled
      if (filled == amount) {
        return filled;
      }
      amount -= filled;
    }

    // If there's nothing at this price point, naturally or due to filling orders, set it
    if (point.orderType == OrderType.Null) {
      point.orderType = current;
      emit Order(current, price);
    }

    // Add the new order
    // We could also merge orders here, if an existing order for this trader at this price point existed
    point.orders.push(OrderStruct(trader, 0, amount));
    emit OrderIncrease(trader, price, amount);

    return filled;
  }

  /**
   * @notice Execute a token purchase order
   * @param trader User executing the trade
   * @param price Purchase price per whole token (presumably 1e18 atomic units)
   * @param minimumAmount Minimum amount of tokens received (in whole tokens)
   * @return filled uint256 quantity of succesfully purchased tokens (in atomic units)
   */
  function buy(
    address trader,
    uint256 price,
    uint256 minimumAmount
  ) external override nonReentrant returns (uint256 filled) {
    // Determine the value sent
    // Not a pattern vulnerable to re-entrancy despite being a balance-based amount calculation
    uint256 balance = IERC20(tradeToken).balanceOf(address(this));
    uint256 received = balance - tradeTokenBalance;
    tradeTokenBalance = balance;

    // Unfortunately, does not allow buying with the DEX balance as we don't have msg.sender available
    // We could pass and verify a signature. It's just not worth it at this time
  
    /**
     * Supports fee on transfer tokens
     * The Crowdfund contract actually verifies its token isn't fee on transfer
     * The Thread initializer uses the same token for both that and this
     * That said, any token which can have its fee set may be set to 0 during Crowdfund,
     * allowing it to pass, yet set to non-0 later in its life, causing this to fail
     * USDT notably has fee on transfer code, currently set to 0, that may someday activate
     */
    uint256 amount = received / price;
    if (amount < minimumAmount) {
      revert LessThanMinimumAmount(amount, minimumAmount);
    }

    // Dust may exist in the form of received - (price * amount) thanks to rounding errors
    // While this likely isn't worth the gas it's cost to write it, do so to ensure correctness
    uint256 dust = received - (price * amount);
    if (dust != 0) {
      // Credit to the trader as msg.sender is presumably a router contract which shouldn't have funds
      // If a non-router contract trades on this DEX, it should specify itself as the trader, making this still valid
      // If this was directly chained into Uniswap though to execute a trade there, then this dust would effectively be burnt
      // It's insignificant enough to not bother adding an extra argument for that niche use case
      tradeTokenBalances[trader] += dust;
    }

    return _action(OrderType.Buy, OrderType.Sell, trader, price, amount);
  }

  /**
   * @notice Execute a token sell order
   * @param price Sell price per whole token (presumably 1e18 atomic units)
   * @param amount Amount of tokens to be sold (in whole tokens)
   * @return filled uint256 quantity of succesfully sold tokens 
   */
  function sell(
    uint256 price,
    uint256 amount
  ) external override nonReentrant returns (uint256 filled) {
    locked[msg.sender] += atomic(amount);
    if (balanceOf(msg.sender) < locked[msg.sender]) {
      revert NotEnoughFunds(locked[msg.sender], balanceOf(msg.sender));
    }
    filled = _action(OrderType.Sell, OrderType.Buy, msg.sender, price, amount);
    // Trigger a withdraw for any tokens from filled orders
    _withdrawTradeToken(msg.sender);
  }

  /**
   * @notice Cancel an existing order of either the caller or a removed user
   * @param price Price that the order to be cancelled exists at
   * @param i Index of order at given price point
   * @return bool True if caller's own order was cancelled, false otherwise
   */
  function cancelOrder(uint256 price, uint256 i) external override nonReentrant returns (bool) {
    PricePoint storage point = _points[price];
    OrderStruct storage order = point.orders[i];

    // If they are no longer whitelisted, remove them
    if (!whitelisted(order.trader)) {
      // Uses a 0 fee as this didn't have remove called, its parent did
      // This will cause the parent fee to carry
      _removeUnsafe(order.trader, 0);
    }

    // Cancelling our own order
    bool ours = order.trader == msg.sender;
    // Cancelling the order of someone removed
    if (!(ours || removed(order.trader))) {
      revert Unauthorized(msg.sender, order.trader);
    }

    if (point.orderType == OrderType.Buy) {
      tradeTokenBalances[order.trader] += price * order.amount;
    } else if (
      (point.orderType == OrderType.Sell) &&
      // If they were removed, they've already had their balance seized and put up for auction
      // They should only get their traded token left floating on the DEX back (previous case)
      (!removed(order.trader))
    ) {
      locked[order.trader] -= atomic(order.amount);
    }

    // Emitted even if the trader was removed
    emit OrderCancellation(order.trader, price, order.amount);

    // Delete the order
    if (i != point.orders.length - 1) {
      point.orders[i] = point.orders[point.orders.length - 1];
    }
    point.orders.pop();

    // Tidy up the order type
    if (point.orders.length == 0) {
      point.orderType = OrderType.Null;
    }

    // Withdraw our own funds to prevent the need for another transaction
    _withdrawTradeToken(msg.sender);

    // Return if our own order was cancelled
    return ours;
  }

  /// @notice Get the order type at price `price`
  /// @param price Price at which to retrieve order type
  /// @return OrderType Type of order at price `price`
  function pointType(uint256 price) external view override returns (OrderType) {
    return _points[price].orderType;
  }

  /// @notice Get the number of orders at price `price`
  /// @param price Price at which to retrieve order number at
  /// @return uint256 Current number or orders at price `price`
  function orderQuantity(uint256 price) external view override returns (uint256) {
    return _points[price].orders.length;
  }

  /**
   * @notice Get address of trader for a given order
   * @param price Price that the order to be queried exists at
   * @param i Index of order at given price point
   * @return address Address of the trader for the given order
   */
  function orderTrader(uint256 price, uint256 i) external view override returns (address) {
    return _points[price].orders[i].trader;
  }

  /**
   * @notice Get size of a given order
   * @param price Price that the order to be queried exists at
   * @param i Index of order at given price point
   * @return uint256 Size of queried order (atomic)
   */
  function orderAmount(uint256 price, uint256 i) external view override returns (uint256) {
    OrderStruct memory order = _points[price].orders[i];
    // The FrabricERC20 whitelisted function will check both whitelisted and removed
    // When this order is actioned, if they're no longer whitelisted yet have yet to be removed,
    // they will be removed, hence why either case has the order amount be effectively 0
    if (!whitelisted(order.trader)) {
      return 0;
    }
    return order.amount;
  }
}
