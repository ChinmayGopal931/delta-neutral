// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Mock Price Feed for testing
contract MockPriceFeed {
    mapping(address => uint256) private prices;

    // Set the price for a token
    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    // Get the price of a token
    function getPrice(address token) external view returns (uint256) {
        return prices[token];
    }
}
