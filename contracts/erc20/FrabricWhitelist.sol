// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { ERC165CheckerUpgradeable as ERC165Checker } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";

import "../common/Composable.sol";

import "../interfaces/erc20/IFrabricWhitelist.sol";

/** 
 * @title Whitelist contract
 * @author Fractional Finance
 * @notice This contract implements the Frabric whitelisting system,
 * whitelists with KYC hashes instead of booleans, and can be disabled in the future
 * @dev Upgradable contract
 */
abstract contract FrabricWhitelist is Composable, IFrabricWhitelist {
  using ERC165Checker for address;

  // This is intended to be settable without an upgrade in the future, yet no path currently will
  // A future upgrade may add a governance-followable path to set it
  /// @notice True if all addresses are globally whitelisted, false otherwise
  bool public override global;
  /// @notice Whitelist used for the entire Frabric platform
  address public override parent;
  // Current status on the whitelist
  mapping(address => Status) private _status;
  // Height at which people were removed from the whitelist
  mapping(address => uint256) private _removed;
  /// @notice Mapping of whitelisted user addresses to hashes of KYC information.
  /// This will not resolve to the parent information is no hash is set
  mapping(address => bytes32) public override kyc;
  /// @notice Mapping of user addresses to current nonce, preventing replays
  mapping(address => uint256) public override kycNonces;

  uint256[100] private __gap;

  function _setGlobal() internal {
    global = true;
    emit GlobalAcceptance();
  }

  function _setParent(address _parent) internal {
    if ((_parent != address(0)) && (!_parent.supportsInterface(type(IFrabricWhitelistCore).interfaceId))) {
      revert UnsupportedInterface(_parent, type(IFrabricWhitelistCore).interfaceId);
    }

    // Still emits even if address 0 was changed to address 0.
    // Used to signify that address 0 as the parent is intentional
    emit ParentChange(parent, _parent);
    parent = _parent;
  }

  function __FrabricWhitelist_init(address _parent) internal onlyInitializing {
    supportsInterface[type(IFrabricWhitelistCore).interfaceId] = true;
    supportsInterface[type(IFrabricWhitelist).interfaceId] = true;
    _setParent(_parent);
  }

  function _whitelist(address person) internal {
    if (_status[person] != Status.Null) {
      if (_status[person] == Status.Removed) {
        revert Removed(person);
      }
      revert AlreadyWhitelisted(person);
    }

    _status[person] = Status.Whitelisted;
    emit Whitelisted(person, true);
  }

  function _setKYC(address person, bytes32 hash, uint256 nonce) internal {
    // Ensure this is a real user
    if (_status[person] == Status.Null) {
      revert NotWhitelisted(person);
    }

    // Make sure this is not replayed
    if (nonce != kycNonces[person]) {
      revert Replay(nonce, kycNonces[person]);
    }
    kycNonces[person]++;

    // If user was previously solely whitelisted, mark them as KYCd
    if (_status[person] == Status.Whitelisted) {
      _status[person] = Status.KYC;
    }

    emit KYCUpdate(person, kyc[person], hash, nonce);
    // Update the KYC hash
    kyc[person] = hash;
  }

  function _setRemoved(address person) internal {
    if (removed(person)) {
      revert Removed(person);
    }

    _status[person] = Status.Removed;
    _removed[person] = block.number;
    emit Whitelisted(person, false);
  }

  /// @notice Get current status of user `person`
  /// @param person Address of user to have status checked
  /// @return Status Status of user `person`
  function status(address person) public view override returns (Status) {
    Status res = _status[person];
    if (res == Status.Removed) {
      return res;
    }

    // If we have a parent, get their status
    if (parent != address(0)) {
      // Use a raw call, giving access to the uint8 format instead of the Status format
      (bool success, bytes memory data) = parent.staticcall(
        abi.encodeWithSelector(IFrabricWhitelistCore.status.selector, person)
      );
      if (!success) {
        revert ExternalCallFailed(parent, IFrabricWhitelistCore.status.selector, data);
      }

      // Decode status
      (uint8 parentStatus) = abi.decode(data, (uint8));
      // If the parent expanded their Status enum, convert it into our range to prevent bricking
      // This does still have rules on how the parent can expand yet is better than a complete failure
      if (parentStatus > uint8(type(Status).max)) {
        parentStatus = uint8(type(Status).max);
      }

      // Use whichever status is higher
      if (parentStatus > uint8(res)) {
        return Status(parentStatus);
      }
    }

    return res;
  }

  /// @notice Check if user `person` is currently whitelisted
  /// @param person Address of user to have whitelisting status checked
  /// @return bool True is user `person` is whitelisted, false otherwise
  function whitelisted(address person) public view virtual override returns (bool) {
    return (
      // Was never removed
      (!removed(person)) && (
        // Whitelisted by the parent (usually relevant)
        ((parent != address(0)) && IFrabricWhitelistCore(parent).whitelisted(person)) ||
        // Explicitly whitelisted or global
        explicitlyWhitelisted(person) || global
      )
    );
  }

  /// @notice Check if user `person` has been KYCd
  /// @param person Address of user to be checked
  /// @return bool True if user `person` has been KYCd, false otherwise
  function hasKYC(address person) external view override returns (bool) {
    return uint8(status(person)) >= uint8(Status.KYC);
  }

  /// @notice Check if user `person` has been removed from the whitelist
  /// @param person Adress of user to be checked
  /// @return bool True if user `person` has been removed, false otherwise
  function removed(address person) public view virtual override returns (bool) {
    return _status[person] == Status.Removed;
  }

  /// @notice Check is a user `person` has been explicitly whitelisted
  /// @param person Address of user to be checked
  /// @return bool True if user `person` has been explicitly whitelisted, false otherwise
  function explicitlyWhitelisted(address person) public view override returns (bool) {
    return uint8(_status[person]) >= uint8(Status.Whitelisted);
  }

  /// @notice Get height at which a user `person` was removed
  /// @param person Address of user to be checked
  /// @return uint256 Height at which the user `person` was removed at
  function removedAt(address person) external view override returns (uint256) {
    return _removed[person];
  }
}
