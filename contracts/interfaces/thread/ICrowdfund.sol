// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.13;

interface ICrowdfund {
  enum State {
    Active,
    Cancelled,
    Executing,
    Refunding,
    Finished
  }

  event CrowdfundStarted(address indexed agent, address indexed thread, address indexed token, uint256 target);
  event StateChange(State indexed state, bytes data);
  event Deposit(address indexed depositor, uint256 amount);
  event Withdraw(address indexed depositor, uint256 amount);
  event Refund(address indexed depositor, uint256 refundAmount);

  function whitelist() external view returns (address);

  function agent() external view returns (address);
  function thread() external view returns (address);

  function token() external view returns (address);
  function target() external view returns (uint256);
  function deposited() external view returns (uint256);

  function state() external view returns (State);
  function refunded() external view returns (uint256);

  function initialize(
    string memory name,
    string memory symbol,
    address _whitelist,
    address _agent,
    address _thread,
    address _token,
    uint256 _target
  ) external;

  function normalizeRaiseToThread(uint256 amount) external returns (uint256);

  function deposit(uint256 amount) external;
  function withdraw(uint256 amount) external;
  function cancel() external;
  function execute() external;
  function refund(uint256 amount) external;
  function claimRefund(address depositor) external;
  function finish() external;
  function burn(address depositor) external;
}
