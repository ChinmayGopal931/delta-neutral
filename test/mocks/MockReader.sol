// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Mock GMX Reader for testing
contract MockReader {
    struct Position {
        address account;
        address market;
        bool isLong;
        uint256 sizeInUsd;
        uint256 collateralAmount;
    }

    mapping(address => mapping(address => Position)) private positions;

    // Set a position for testing
    function setPosition(address account, address market, bool isLong, uint256 sizeInUsd, uint256 collateral)
        external
    {
        positions[account][market] = Position({
            account: account,
            market: market,
            isLong: isLong,
            sizeInUsd: sizeInUsd,
            collateralAmount: collateral
        });
    }

    // Get account positions
    function getAccountPositions(address dataStore, address account, uint256 start, uint256 end)
        external
        view
        returns (Position[] memory)
    {
        // For simplicity, just return a single position if it exists
        Position memory pos = positions[account][positions[account][address(0)].market];

        if (pos.sizeInUsd > 0) {
            Position[] memory result = new Position[](1);
            result[0] = pos;
            return result;
        }

        // Return empty array if no position
        Position[] memory empty = new Position[](0);
        return empty;
    }
}
