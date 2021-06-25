// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.4;

interface IWhitelist {
  event WhitelistChange(address indexed person, bool whitelisted);

  function whitelisted(address person) external view returns (bool);
}