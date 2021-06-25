// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.4;

interface IScoreList {
  event ScoreChange(address indexed person, uint8 indexed score);

  function maxScore() external view returns (uint8);
  function score(address person) external view returns (uint8);
}