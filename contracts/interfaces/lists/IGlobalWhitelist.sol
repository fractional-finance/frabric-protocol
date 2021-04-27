// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./IWhitelist.sol";

interface IGlobalWhitelist is IWhitelist {
  function explicitlyWhitelisted(address person) external view returns (bool);
}
