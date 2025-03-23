// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Mock GMX Exchange Router for testing
contract MockExchangeRouter {
    struct CreateOrderParams {
        address market;
        address callbackContract;
        address uiFeeReceiver;
        address trader;
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 shouldUnwrapNativeToken;
        uint256 minOutputAmount;
        address[] longTokenSwapPath;
        address[] shortTokenSwapPath;
        bytes callbackData;
    }

    // Order tracking for testing
    struct Order {
        address market;
        address trader;
        uint256 sizeDeltaUsd;
        uint256 collateral;
        bool isLong;
    }

    Order[] public orders;

    event OrderCreated(address indexed trader, address indexed market, uint256 size, uint256 collateral);

    // Mock implementation of createOrder
    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32) {
        // For testing, we'll add the order to our array
        orders.push(
            Order({
                market: params.market,
                trader: params.trader,
                sizeDeltaUsd: params.sizeDeltaUsd,
                collateral: params.initialCollateralDeltaAmount,
                isLong: false // Always short for our test
            })
        );

        emit OrderCreated(params.trader, params.market, params.sizeDeltaUsd, params.initialCollateralDeltaAmount);

        return bytes32(keccak256(abi.encode(block.timestamp, params.trader, params.sizeDeltaUsd)));
    }

    // Helper to get the latest order
    function getLatestOrder() external view returns (Order memory) {
        require(orders.length > 0, "No orders");
        return orders[orders.length - 1];
    }

    // Helper to get order count
    function getOrderCount() external view returns (uint256) {
        return orders.length;
    }
}
