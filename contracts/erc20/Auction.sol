// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { IERC20Upgradeable as IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable as SafeERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { ERC165CheckerUpgradeable as ERC165Checker } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/erc20/IFrabricWhitelist.sol";
import "../interfaces/erc20/IFrabricERC20.sol";

import "../common/Composable.sol";

import "../interfaces/erc20/IAuction.sol";

/** 
 * @title Auction contract
 * @author Fractional Finance
 * @notice This contract implements the Frabric auction system
 * @dev Upgradable contract
 */
contract Auction is ReentrancyGuardUpgradeable, Composable, IAuctionInitializable {
  using SafeERC20 for IERC20;
  using ERC165Checker for address;

  uint256 private _nextID;

  // Fields optimised for efficient packing
  struct AuctionStruct {
    address token;
    uint64 start;
    uint32 length;
    // 4 bytes left open in this slot
    address traded;
    uint64 end;
    address seller;
    address bidder;
    /**
     * uint96 amounts would be perfectly packed here and support 70 billion 1e18
     * This would be sufficient for all ERC20s worth more than $0.01
     * (or less with appropriately shifted decimals)
     * While this would act as a micro-optimization, it would reduce compatibility
     * and could set a partially hidden and unfair bid value ceiling
     */
    uint256 amount;
    uint256 bid;
  }

  // Private as auction list can be aquired from events or getter functions for active auctions
  mapping(uint256 => AuctionStruct) private _auctions;
  /// @notice Balance tracker of user addresses across multiple tokens
  mapping(address => mapping(address => uint256)) public override balances;

  /// @notice Auction contract initialization
  function initialize() external override initializer {
    __ReentrancyGuard_init();
    __Composable_init("Auction", false);
    supportsInterface[type(IAuctionCore).interfaceId] = true;
    supportsInterface[type(IAuction).interfaceId] = true;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() Composable("Auction") initializer {}

  /**
   * @notice Create a new auction or batch of auctions
   * @param seller Auction seller address
   * @param _token Address of token denominating sale asset
   * @param _traded Address of token used for payment
   * @param _amount Amount of asset token (`_token`) to be auctioned
   * @param batches Number of batches to execute the auction in
   * @param start Absolute start time in seconds. Will be set to current time if past value provided
   * @param length Auction length
   * @return id id of newly created auction
   */
  function list(
    address seller,
    address _token,
    address _traded,
    uint256 _amount,
    uint8 batches,
    uint64 start,
    uint32 length
  ) external override nonReentrant returns (uint256 id) {
    // Require the caller to be the token - forcing a sale, or the seller
    if ((msg.sender != _token) && (msg.sender != seller)) {
      revert Unauthorized(msg.sender, seller);
    }

    /**
     * Vulnerable pattern, hence reentrancy protection modifier.
     * It would be possible to call complete/withdraw during this action,
     * decreasing the balance
     */
    uint256 startBal = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransferFrom(seller, address(this), _amount);
    _amount = IERC20(_token).balanceOf(address(this)) - startBal;
    if (_amount == 0) {
      revert ZeroAmount();
    }

    // If amount is very small, list in a single batch. Also ensures batches != 0
    uint256 batchAmount = _amount / batches;
    if (batchAmount == 0) {
      batches = 1;
    }

    // If start not specified or in the past, use current time
    if (start < block.timestamp) {
      start = uint64(block.timestamp);
    }

    // Emit a single event for gas efficiency 
    emit Auctions(_nextID, seller, _token, _traded, _amount, batches, start, length);

    for (uint256 i = 0; i < batches; i++) {
      // This could be futher optimized by moving it outside the loop with 
      // a duplicated loop body. Deemed not worth it.
      if (i == (batches - 1)) {
        // Correct for potential rounding errors
        batchAmount = _amount;
      }

      id = _nextID;
      _nextID++;

      AuctionStruct storage auction = _auctions[id];
      auction.seller = seller;
      auction.token = _token;
      auction.traded = _traded;
      auction.amount = batchAmount;
      auction.start = start;
      auction.length = length;
      auction.end = auction.start + length;

      _amount -= batchAmount;
      start += length;
    }
  }

  /**
   * In the event of an unexpected fallback function, or non-EIP165 compliant supportsInterface function,
   * this check may always return true, preventing all bids and triggering a burn.
   * To handle this, this contract defines a scope for ERC20 compatibility such that the token must:
   * - Support EIP165
   * - Not support EIP165 and not have a fallback function
   * - Not support EIP165 and have a fallback function not passing as EIP165 compatible
   * - Not support EIP165 and have a fallback function and claim all addresses are whitelisted
   * The final requirement should not be practically encountered as this is an outdated design.
   * EIP165 ensures fallback functions which always return true or false are not compliant.
   * If a contract does not implement EIP165 and thows an error here the ERC165Checker lib
   * will return false, eliminating the requirement for a try/catch block.
   * Notably, WETH has a fallback function with no return value, making it non-EIP165 compliant
   */
  function notWhitelisted(address _token, address person) private view returns (bool) {
    return (
      // If the contract does not support whitelisting, all users are defacto
      // whitelisted, hence return false
      _token.supportsInterface(type(IFrabricWhitelistCore).interfaceId) &&
      // If there is a whitelist and the user is not whitelisted, return true
      (!IFrabricWhitelistCore(_token).whitelisted(person))
    );
  }

  /// @notice Sumbit a new bid on an auction
  /// @param id Id of auction to bid on
  /// @param bidAmount Bid size
  function bid(uint256 id, uint256 bidAmount) external override nonReentrant {
    AuctionStruct storage auction = _auctions[id];

    // Check the auction has started
    if (block.timestamp < auction.start) {
      revert AuctionPending(block.timestamp, auction.start);
    }

    // Check the auction is not over
    if (block.timestamp > auction.end) {
      revert AuctionOver(block.timestamp, auction.end);
    }

    // Transfer funds
    uint256 start = IERC20(auction.traded).balanceOf(address(this));
    IERC20(auction.traded).safeTransferFrom(msg.sender, address(this), bidAmount);
    bidAmount = IERC20(auction.traded).balanceOf(address(this)) - start;
  
    /**
     * Check the bid is greater than the current bid.
     * This could fail due to fee-on-transfer tokens or if reentrancy was attempted
     * into the list, listTransferred or bid functions
     */
    if (bidAmount <= auction.bid) {
      revert BidTooLow(bidAmount, auction.bid);
    }

    // Ensure caller is whitelisted and capable of receiving funds in the event they win
    if (notWhitelisted(auction.token, msg.sender)) {
      revert NotWhitelisted(msg.sender);
    }

    // Ensure caller is not already the high bidder
    if (auction.bidder == msg.sender) {
      revert HighBidder(msg.sender);
    }

    // Return the funds. This uses an internal mapping in case the transfer fails,
    // preventing futher bids.
    balances[auction.traded][auction.bidder] += auction.bid;
  
    // Extend the auction if the bid is being executed near the end of the auction period.
    // An auction is prevented from being extended beyond twice its original duration to prevent
    // DoS attacks, for which there could be sufficient incentive
    uint64 newEnd = uint64(block.timestamp) + (1 days);
    uint64 maxEnd = auction.start + (auction.length * 2);
    if (newEnd > maxEnd) {
      newEnd = maxEnd;
    }
    if (newEnd > auction.end) {
      auction.end = newEnd;
    }

    // Update bid and bidder
    auction.bidder = msg.sender;
    auction.bid = bidAmount;
    emit Bid(id, auction.bidder, auction.bid);
  }
  
  /// @notice Complete an auction
  /// @param id Auction id to be completed
  function complete(uint256 id) external override {
    AuctionStruct memory auction = _auctions[id];
    // Prevent reentrancy concerning this auction and return a gas refund.
    // While other auctions can be still be accessed, this does not give rise to
    // any side effects in this case.
    delete _auctions[id];

    if (block.timestamp <= auction.end) {
      revert AuctionActive(block.timestamp, auction.end);
    }

    // If no bids were made, return tokens to the seller.
    // If this auction was the result of a removal, this will fail as they are not whitelisted.
    // If this is the case, burn the tokens.
    if (auction.bidder == address(0)) {
      if (notWhitelisted(auction.token, auction.seller)) {
        // Utilises a try/catch block to ensure auction completion.
        // In the worst case these funds are locked permanently.
        try IFrabricERC20(auction.token).burn(auction.amount) {} catch {}
      } else {
        balances[auction.token][auction.seller] += auction.amount;
      }
    } else {
      // Transfer to the bidder
      balances[auction.token][auction.bidder] += auction.amount;
      balances[auction.traded][auction.seller] += auction.bid;
    }

    emit AuctionComplete(id);
  }

  /// @notice Withdraw token balance of a user (`trader`)
  /// @param _token Address of token to be withdrawn
  /// @param trader Address of user to have balance withdrawn
  function withdraw(address _token, address trader) external override {
    uint256 _amount = balances[_token][trader];
    balances[_token][trader] = 0;
    IERC20(_token).safeTransfer(trader, _amount);
  }

  /**
   * @dev These functions only work for auctions yet to complete
   * @notice Check if an auction is currently active
   * @param id Id of auction to be checked
   * @return bool True is auction is active, false otherwise
   */
  function active(uint256 id) external view override returns (bool) {
    return (_auctions[id].start <= block.timestamp) && (block.timestamp <= _auctions[id].end);
  }

  /**
  * We could expose start/length/seller here, but we encourage using
  * the event API due to improved data availability. These functions will
  * only provide data while the auction is active, which may have
  * value on chain
  */

  /// @notice Get asset token address of active auction with id `id`
  /// @param id Id of auction to be queried
  /// @return address Address of asset token for auction with id `id`
  function token(uint256 id) external view override returns (address) {
    return _auctions[id].token;
  }

  /// @notice Get payment token address of active auction with id `id`
  /// @param id Id of auction to be queried
  /// @return address Address of payment token for auction with id `id`
  function traded(uint256 id) external view override returns (address) {
    return _auctions[id].traded;
  }

  /// @notice Get asset token quantity for active auction with id `id`
  /// @param id Id of auction to be queried
  /// @return uint256 Quantity of asset token being offered for auction with id `id`
  function amount(uint256 id) external view override returns (uint256) {
    return _auctions[id].amount;
  }

  /// @notice Get current highest bidder of auction with id `id`
  /// @param id Id of auction to be queried
  /// @return address Address of current highest bidder for auction with id `id`
  function highBidder(uint256 id) external view override returns (address) {
    return _auctions[id].bidder;
  }

  /// @notice Get size of current highest bid for auction with id `id`
  /// @param id Id of auction to be queried
  /// @return uint256 Size of current highest bid for auction with id `id`
  function highBid(uint256 id) external view override returns (uint256) {
    return _auctions[id].bid;
  }

  /// @notice Get end time for auction with id `id`
  /// @param id Id of auction to be queried
  /// @return uint64 Absolute end time in seconds for auction with id `id`
  function end(uint256 id) external view override returns (uint64) {
    return _auctions[id].end;
  }
}
