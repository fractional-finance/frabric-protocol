// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./DistributionERC20.sol";
import "./FrabricWhitelist.sol";
import "./IntegratedLimitOrderDEX.sol";

import "../interfaces/erc20/IAuction.sol";

import "../interfaces/erc20/IFrabricERC20.sol";

/**
 * @title FrabricERC20 Contract
 * @author Fractional Finance
 * @notice This contract implements the FrabricERC20 system, with a limit order DEX, governance and distribution built in
 * @dev FrabricERC20 tokens include a built in limit order DEX as well as governance and distribution functionality.
 * The owner may also mint tokens, with an optional whitelist, defaulting to a parent whitelist.
 * Owners may pause transfers - this functionality is intended for migrations and dissolutions
 */
contract FrabricERC20 is OwnableUpgradeable, PausableUpgradeable, DistributionERC20, FrabricWhitelist, IntegratedLimitOrderDEX, IFrabricERC20Initializable {
  using ERC165Checker for address;

  address public override auction;

  bool private _burning;
  /// @notice Mapping of user addresses to absolute time in seconds when tokens will be unfrozen
  mapping(address => uint64) public override frozenUntil;
  /// @notice Mapping of user addresses to their associated removal fee
  mapping(address => uint8) public override removalFee;
  bool private _removal;

  /**
   * @notice Initialize a new FrabircERC20 contract
   * @param name Name of new token
   * @param symbol Symbol of new token
   * @param supply Total supply of new token
   * @param parent Address of parent contract
   * @param tradeToken Address of token used as purchasing token in integrated DEX
   * @param _auction Address of auction contract for token
   */
  function initialize(
    string memory name,
    string memory symbol,
    uint256 supply,
    address parent,
    address tradeToken,
    address _auction
  ) external override initializer {
    __Ownable_init();
    __Pausable_init();
    __DistributionERC20_init(name, symbol);
    __FrabricWhitelist_init(parent);
    __IntegratedLimitOrderDEX_init(tradeToken);

    __Composable_init("FrabricERC20", false);
    supportsInterface[type(OwnableUpgradeable).interfaceId] = true;
    supportsInterface[type(PausableUpgradeable).interfaceId] = true;
    supportsInterface[type(IRemovalFee).interfaceId] = true;
    supportsInterface[type(IFreeze).interfaceId] = true;
    supportsInterface[type(IFrabricERC20).interfaceId] = true;

    /**
     * Whitelist the initializer.
     * If this is the Frabric's deployer, they are expected to remove
     * their own whitelisting.
     * If this is the ThreadDeployer, this is intended behavior 
     */
    _whitelist(msg.sender);

    // Mint the supply
    mint(msg.sender, supply);

    auction = _auction;

    _removal = false;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() Composable("FrabricERC20") initializer {}

  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override(ERC20Upgradeable, IntegratedLimitOrderDEX) {
    super._transfer(from, to, amount);
  }

  /// @inheritdoc IntegratedLimitOrderDEX
  /// @dev Redefine ERC20 balanceOf function as an override so the DEX can call it
  function balanceOf(
    address account
  ) public view override(IERC20Upgradeable, ERC20Upgradeable, IntegratedLimitOrderDEX) returns (uint256) {
    return super.balanceOf(account);
  }

  /// @inheritdoc IntegratedLimitOrderDEX
  /// @dev Redefine ERC20 decimals function as an override so the DEX can call it
  function decimals() public view override(ERC20Upgradeable, IntegratedLimitOrderDEX) returns (uint8) {
    return super.decimals();
  }

  /**
   * @notice Mint new tokens, only available to owner
   * @param to Address for newly minted tokens to be credited to
   * @param amount Amount of new tokens to be minted
   * @dev Redefine ERC20 mint function as an override so the DEX can call it
   */
  function mint(address to, uint256 amount) public override onlyOwner {
    _mint(to, amount);

    /**
     * This check ensures the supply is within the bound of signed<int>.max set by the DAO contract.
     * uint112 is becoming a more frequently chosen bound by Uniswap and others, and is perfectly functional.
     * DistributedERC20 is bounded by uint112, hence it is also used here. This also removes the requirement
     * for the DAO to use uint120.
     */
    if (totalSupply() > uint256(uint112(type(int112).max))) {
      revert SupplyExceedsInt112(totalSupply(), type(int112).max);
    }
  }

  /// @notice Burn `amount` tokens
  /// @param amount Amount of new tokens to be burned
  /// @dev Redefine ERC20 burn function as an override so the DEX can call it
  function burn(uint256 amount) external override {
    _burning = true;
    _burn(msg.sender, amount);
    _burning = false;
  }

  /// @inheritdoc IntegratedLimitOrderDEX
  /// @dev Helper function to simplify calling and allow IntegratedLimitOrderDEX to abstract this away 
  function frozen(address person) public view override(IFreeze, IntegratedLimitOrderDEX) returns (bool) {
    return block.timestamp <= frozenUntil[person];
  }

  function _freeze(address person, uint64 until) private {
    // If an address is already frozen until the specified time, keep the existing freeze lock in place.
    // This prevents multiple freezes from overlapping or reducing the freeze time.
    if (frozenUntil[person] >= until) {
      return;
    }
    frozenUntil[person] = until;
    emit Freeze(person, until);
  }

  /// @notice Freeze tokens on an address (`person`) until a given time (`until`). Only callable by contract owner
  /// @param person Address to have tokens frozen
  /// @param until Absolute time in seconds to freeze tokens of `person` until
  function freeze(address person, uint64 until) external override onlyOwner {
    _freeze(person, until);
  }

  /// @notice Trigger an existing freeze on `person` from a parent contract
  /// @param person Address to have freeze triggered on
  function triggerFreeze(address person) external override {
    // supportsInterface removes the need for an address 0 check.
    // Even if the address was 0 and 0 values were returnd it would not be an issue 
    if (!parent.supportsInterface(type(IFreeze).interfaceId)) {
      return;
    }
    _freeze(person, IFreeze(parent).frozenUntil(person));
  }


  // Labelled unsafe due to its split checks with triggerRemoval and lack of
  // guarantees on what checks it will perform
  function _removeUnsafe(address person, uint8 fee) internal override {
    // If they were already removed, return
    if (removed(person)) {
      return;
    }
    _setRemoved(person);
  
    /**
     * If a fee is not specified, carry the parent fee.
     * Checks if it supports IRemovalFee, as that is not a requirement on the
     * parent. Solely IFrabricWhitelistCore is, and doing this check keeps the
     * parent bounds minmal. Note this is only a minor gas
     * cost given how infrequent removals are 
     */
    if (
      (fee == 0) &&
      // Redundant due to supportsInterface check
      (parent != address(0)) &&
      (parent.supportsInterface(type(IRemovalFee).interfaceId))
    ) {
      fee = IRemovalFee(parent).removalFee(person);
    }

    removalFee[person] = fee;

    /**
     * Clear the locked amount.
     * If this was not cleared, it would be easier to implement readding users.
     * The InegratedLimitOrderDEX would be able to successfully
     * correct this field as old orders are cleared.
     * This would cause issues though and the current solution is sufficient
     */
    locked[person] = 0;

    uint256 balance = balanceOf(person);
    emit Removal(person, balance);
    if (balance != 0) {
      // _removal is dangerous and this would be incredibly risky if re-entrancy
      // was possible, or if it was left set, yet every function which calls this
      // is nonReentrant and it is set to false immediately after these calls to
      // trusted code
      _removal = true;

      if (fee != 0) {
        // Send the removal fee to the owner (the DAO)
        uint256 actualFee = balance * fee / 100;
        _transfer(person, owner(), actualFee);
        balance -= actualFee;
      }

      // Put the rest up for auction
      _approve(person, auction, balance);

      IAuctionCore(auction).list(
        person,
        address(this),
        tradeToken,
        balance,
        4,
        uint64(block.timestamp),
        1 weeks
      );
      _removal = false;
    }
  }

  // Whitelisting functions

  /// @inheritdoc IntegratedLimitOrderDEX
  /// @dev Redefine function as an override so the DEX can call it
  function whitelisted(
    address person
  ) public view override(IntegratedLimitOrderDEX, FrabricWhitelist, IFrabricWhitelistCore) returns (bool) {
    return super.whitelisted(person);
  }

  /// @inheritdoc IntegratedLimitOrderDEX
  /// @dev Redefine function as an override so the DEX can call it
  function removed(
    address person
  ) public view override(IntegratedLimitOrderDEX, FrabricWhitelist, IFrabricWhitelistCore) returns (bool) {
    return super.removed(person);
  }

  /// @notice Set new parent contract, only callable by owner
  /// @param _parent Address of new parent contract
  function setParent(address _parent) external override onlyOwner {
    _setParent(_parent);
  }

  /// @notice Whitelist a new user (`person`), only callable by owner
  /// @param person Address of new user to be whitelisted
  function whitelist(address person) external override onlyOwner {
    _whitelist(person);
  }

  /**
   * @notice Set KYC status for a user (`person`), only callable by owner
   * @param person Address of user (`person`) to have KYC status added
   * @param hash KYC hash to be stored on chain
   * @param nonce Number used once for each KYC, to prevent replays
   */
  function setKYC(address person, bytes32 hash, uint256 nonce) external override onlyOwner {
    _setKYC(person, hash, nonce);
  }

  /**
   * @notice Remove user `person` from the whitelist, only callable by owner
   * @param person Address of user to be removed
   * @param fee Fee associated with removal of user `person`
   * 
   * nonReentrant modifier here could be considered overkill considering onlyOwner is also user,
   * except this must not be the initial vector while reentrancy hapens though functions labelled
   * nonReentrant. While the only external calls should be to trusted code in ecosystem, _removeUnsafe
   * is not a function to have unprotected in any way.
   */
  function remove(address person, uint8 fee) external override onlyOwner nonReentrant {
    // This will only apply to the Frabric/Thread in question
    // For a Frabric removal, this will remove them from the global whitelist,
    // and enable calling remove on any Thread. For a Thread, this won't change
    // the whitelist at all, as they'll still be whitelisted on the Frabric
    _removeUnsafe(person, fee);
  }

  /// @notice Trigger a removal on a no-longer whitelisted user `person`
  /// @param person Address of user to have removal triggered on
  function triggerRemoval(address person) public override nonReentrant {
    // Check user has been removed from whitelist
    if (whitelisted(person)) {
      revert NotRemoved(person);
    }

    // Check user actually used this contract
    // If they never held tokens, this could be a user who was never whitelisted
    // If they were whitelisted in the past, they are not anymore, thus there is no data to clean up
    if (numCheckpoints(person) == 0) {
      revert NothingToRemove(person);
    }

    _removeUnsafe(person, 0);
  }

  // Pause functions

  /// @notice Check if token trasfers are paused
  /// @return bool True if the contract is paused, false otherwise
  function paused() public view override(PausableUpgradeable, IFrabricERC20) returns (bool) {
    return super.paused();
  }

  /// @notice Pause token transfer, only callable by owner
  function pause() external override onlyOwner {
    _pause();
  }

  // Transfer requirements

  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);

    // !_removal is placed here (not just on from) as a gas optimization
    // The Auction contract transferred to during removals is whitelisted so that
    // occurs without issue. If it wasn't whitelisted, anyone could call remove.
    if ((!_removal) && (!_inDEX)) {
      // Whitelisted from or minting
      // A non-whitelisted user may have tokens if they were removed from the whitelist
      // and remove has yet to be called. That's why this code is inside `if !_removal`.
      // !_inDEX is simply an optimization as the DEX checks users are whitelisted

      // Technically, whitelisted is an interaction, as discussed in IntegratedLimitOrderDEX.
      // As stated there, it's trusted to not be idiotic AND it is a view function, limiting potential harm
      if ((!whitelisted(from)) && (from != address(0))) {
        revert NotWhitelisted(from);
      }

      if ((!whitelisted(to)) && (!_burning)) {
        revert NotWhitelisted(to);
      }

      // If the person is being removed, or if the DEX is executing a standing order,
      // this is disregarded. This will only matter in the case a user is attempting to transfer
      // after being frozen. The DEX ensures they cannot place new orders.
      if (frozen(from)) {
        revert Frozen(from);
      }
    }

    if (paused()) {
      revert CurrentlyPaused();
    }
  }

  function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._afterTokenTransfer(from, to, amount);
    // Require the balance of the sender be greater than the amount of tokens they have on the DEX
    if (balanceOf(from) < locked[from]) {
      revert Locked(from, balanceOf(from), locked[from]);
    }
  }
}
