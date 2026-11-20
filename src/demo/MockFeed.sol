// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Fork-only stand-in for a Coinbase stock price feed: the demo writes the price it wants Aave to read.
/// Its runtime code is copied over the real feed's address on a local fork; storage starts empty there.
contract MockFeed {
    int256 public latestAnswer;
    uint256 public updatedAt;

    function set(int256 price) external {
        latestAnswer = price;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, latestAnswer, updatedAt, updatedAt, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
