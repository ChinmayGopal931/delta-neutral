// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "forge-std/console.sol";

// GMX interfaces
interface IExchangeRouter {
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

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
}

interface IReader {
    struct Position {
        address account;
        address market;
        bool isLong;
        uint256 sizeInUsd;
        uint256 collateralAmount;
    }
    // Other fields as needed based on GMX's actual implementation

    function getAccountPositions(address dataStore, address account, uint256 start, uint256 end)
        external
        view
        returns (Position[] memory);
}

interface IPriceFeed {
    function getPrice(address token) external view returns (uint256);
}

contract DeltaNeutralHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // State variables for tracking hedge positions
    mapping(PoolId => uint256) public totalHedge; // Amount of token0 to hedge per pool

    // GMX integration variables
    address public immutable exchangeRouter;
    address public immutable reader;
    address public immutable dataStore;
    address public immutable marketAddress; // GMX market address
    address public immutable collateralToken; // USDC address
    address public immutable priceFeed; // Price oracle address
    address public immutable token0Address; // Address of token0 being hedged

    // Configuration parameters
    uint8 public immutable token0Decimals; // Decimals of token0
    uint256 public rebalanceThreshold; // Threshold for rebalancing (in USD with 30 decimals)
    uint256 public executionFee; // Fee for GMX orders (in wei)

    // Events
    event HedgeUpdated(PoolId indexed poolId, uint256 newHedgeAmount);
    event PositionIncreased(uint256 sizeDelta, uint256 collateralDelta);
    event PositionDecreased(uint256 sizeDelta);
    event RebalanceSkipped(PoolId indexed poolId, int256 deltaSize);
    event RebalanceThresholdUpdated(uint256 newThreshold);
    event ExecutionFeeUpdated(uint256 newFee);

    constructor(
        IPoolManager _poolManager,
        address _exchangeRouter,
        address _reader,
        address _dataStore,
        address _marketAddress,
        address _collateralToken,
        address _priceFeed,
        address _token0Address,
        uint8 _token0Decimals,
        uint256 _rebalanceThreshold,
        uint256 _executionFee
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        exchangeRouter = _exchangeRouter;
        reader = _reader;
        dataStore = _dataStore;
        marketAddress = _marketAddress;
        collateralToken = _collateralToken;
        priceFeed = _priceFeed;
        token0Address = _token0Address;
        token0Decimals = _token0Decimals;

        // Add debug logs for threshold
        console.log("CONSTRUCTOR: Received rebalanceThreshold:", _rebalanceThreshold);
        console.log("CONSTRUCTOR: Number of zeros in threshold:", countZeros(_rebalanceThreshold));

        rebalanceThreshold = _rebalanceThreshold;
        executionFee = _executionFee;

        // Debug log after setting
        console.log("CONSTRUCTOR: Set rebalanceThreshold:", rebalanceThreshold);
        console.log("CONSTRUCTOR: Number of zeros after set:", countZeros(rebalanceThreshold));
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // We need to update hedge after liquidity changes
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // We need to update hedge after liquidity changes
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    bool public skipRebalancing = false;

    function setSkipRebalancing(bool _skip) external onlyOwner {
        skipRebalancing = _skip;
    }

    // Called after liquidity is added to the pool
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Extract token0 delta (amount of tokens added to the pool)
        int256 tokenAmount = delta.amount0();
        console.log("inside main", tokenAmount);

        // When liquidity is added, amount0 is negative (tokens are deposited into the pool)
        if (tokenAmount < 0) {
            totalHedge[key.toId()] += uint256(-tokenAmount);
            emit HedgeUpdated(key.toId(), totalHedge[key.toId()]);

            console.log("inside main", skipRebalancing);

            // Rebalance the hedge position
            if (!skipRebalancing) {
                rebalanceHedge(key.toId());
            }
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // Called after liquidity is removed from the pool
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Extract token0 delta (amount of tokens removed from the pool)
        int256 tokenAmount = delta.amount0();

        // When liquidity is removed, amount0 is positive (tokens are withdrawn from the pool)
        if (tokenAmount > 0) {
            // Prevent underflow
            if (uint256(tokenAmount) <= totalHedge[key.toId()]) {
                totalHedge[key.toId()] -= uint256(tokenAmount);
            } else {
                totalHedge[key.toId()] = 0;
            }

            emit HedgeUpdated(key.toId(), totalHedge[key.toId()]);

            // Rebalance the hedge position
            if (!skipRebalancing) {
                rebalanceHedge(key.toId());
            }
        }

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function rebalanceHedge(PoolId poolId) internal {
        uint256 currentHedge = totalHedge[poolId];
        uint256 price = IPriceFeed(priceFeed).getPrice(token0Address);
        require(price > 0, "Invalid price from oracle");

        // Corrected formula
        uint256 desiredSizeUsd = (currentHedge * price) / (10 ** token0Decimals);
        console.log("Desired size USD:", desiredSizeUsd);

        uint256 currentSizeUsd = getCurrentPositionSize();
        console.log("Current position size:", currentSizeUsd);

        int256 deltaSizeUsd = desiredSizeUsd > currentSizeUsd
            ? int256(desiredSizeUsd - currentSizeUsd)
            : -int256(currentSizeUsd - desiredSizeUsd);

        console.log("Delta size USD:", deltaSizeUsd);
        console.log("Rebalance threshold:", rebalanceThreshold);

        if (deltaSizeUsd > int256(rebalanceThreshold)) {
            console.log("INCREASING position by:", uint256(deltaSizeUsd));
            increasePosition(uint256(deltaSizeUsd));
        } else if (deltaSizeUsd < -int256(rebalanceThreshold)) {
            console.log("DECREASING position by:", uint256(-deltaSizeUsd));
            decreasePosition(uint256(-deltaSizeUsd));
        } else {
            console.log("SKIPPING rebalance, delta within threshold");
            emit RebalanceSkipped(poolId, deltaSizeUsd);
        }
    }

    // Get current position size from GMX
    function getCurrentPositionSize() internal view returns (uint256) {
        IReader.Position[] memory positions = IReader(reader).getAccountPositions(dataStore, address(this), 0, 100);

        // Find the short position for our market
        for (uint256 i = 0; i < positions.length; i++) {
            IReader.Position memory position = positions[i];
            if (position.market == marketAddress && !position.isLong) {
                return position.sizeInUsd;
            }
        }

        return 0; // No position found
    }

    // Increase position on GMX
    function increasePosition(uint256 sizeDeltaUsd) internal {
        // Calculate collateral needed (assuming 1x leverage)
        // Converting from 30 decimals (GMX) to 6 decimals (USDC)
        console.log("Position size in GMX format (30 decimals):", sizeDeltaUsd);

        // First, convert the sizeDeltaUsd to a reasonable number for display
        uint256 displaySizeUsd = sizeDeltaUsd / 1e18;
        console.log("Position size in ETH (divide by 1e18):", displaySizeUsd);

        // Calculate collateral needed by dividing by 10^24
        uint256 collateralDelta = sizeDeltaUsd / 10 ** 30 + 1; // Use more aggressive divisor and add 1 to ensure non-zero
        console.log("Calculated collateral (USDC with 6 decimals):", collateralDelta);

        // Log available collateral
        uint256 availableCollateral = IERC20(collateralToken).balanceOf(address(this));
        console.log("Available USDC balance:", availableCollateral);

        // Log contract address
        console.log("Hook contract address:", address(this));

        // Use a larger divisor for debugging purposes
        uint256 testCollateral = sizeDeltaUsd / 10 ** 30;
        console.log("Test collateral using 10^30 divisor:", testCollateral);

        // Ensure sufficient collateral and execution fee
        require(availableCollateral >= collateralDelta, "Insufficient collateral");
        require(address(this).balance >= executionFee, "Insufficient ETH for execution fee");

        // Approve collateral token for GMX router
        IERC20(collateralToken).approve(exchangeRouter, collateralDelta);

        // Prepare empty arrays for token swap paths
        address[] memory emptyPath = new address[](0);

        // Create a market increase order to add to our short position
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            market: marketAddress,
            callbackContract: address(0), // No callback
            uiFeeReceiver: address(0), // No UI fee
            trader: address(this),
            sizeDeltaUsd: sizeDeltaUsd,
            initialCollateralDeltaAmount: collateralDelta,
            executionFee: executionFee,
            callbackGasLimit: 0,
            shouldUnwrapNativeToken: 0,
            minOutputAmount: 0,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath,
            callbackData: ""
        });

        // Submit the order with execution fee
        IExchangeRouter(exchangeRouter).createOrder{value: executionFee}(params);
        emit PositionIncreased(sizeDeltaUsd, collateralDelta);
    }

    // Decrease position on GMX
    function decreasePosition(uint256 sizeDeltaUsd) internal {
        require(address(this).balance >= executionFee, "Insufficient ETH for execution fee");

        console.log("[decreasePosition] Requested size delta USD:", sizeDeltaUsd);

        // Get current position details for logging
        IReader.Position[] memory positions = IReader(reader).getAccountPositions(dataStore, address(this), 0, 100);
        if (positions.length > 0) {
            console.log("[decreasePosition] Current position in GMX:", positions[0].sizeInUsd);
            console.log("[decreasePosition] Current collateral:", positions[0].collateralAmount);
        } else {
            console.log("[decreasePosition] No current position found in GMX");
        }

        // Prepare empty arrays for token swap paths
        address[] memory emptyPath = new address[](0);

        // Create a market decrease order to reduce our short position
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            market: marketAddress,
            callbackContract: address(0), // No callback
            uiFeeReceiver: address(0), // No UI fee
            trader: address(this),
            sizeDeltaUsd: sizeDeltaUsd,
            initialCollateralDeltaAmount: 0, // Not used for decrease
            executionFee: executionFee,
            callbackGasLimit: 0,
            shouldUnwrapNativeToken: 1, // Unwrap ETH if returned
            minOutputAmount: 0,
            longTokenSwapPath: emptyPath,
            shortTokenSwapPath: emptyPath,
            callbackData: ""
        });

        console.log("[decreasePosition] Creating order with size delta:", sizeDeltaUsd);

        // Submit the order with execution fee
        IExchangeRouter(exchangeRouter).createOrder{value: executionFee}(params);
        emit PositionDecreased(sizeDeltaUsd);
    }

    // Manual rebalance function that can be called by external keeper
    function manualRebalance(PoolId poolId) external {
        rebalanceHedge(poolId);
    }

    // Add collateral to the contract
    function addCollateral(uint256 amount) external {
        IERC20(collateralToken).transferFrom(msg.sender, address(this), amount);
    }

    // Withdraw excess collateral (owner only)
    function withdrawCollateral(uint256 amount) external onlyOwner {
        IERC20(collateralToken).transfer(msg.sender, amount);
    }

    // Update rebalance threshold (owner only)
    function setRebalanceThreshold(uint256 newThreshold) external onlyOwner {
        rebalanceThreshold = newThreshold;
        emit RebalanceThresholdUpdated(newThreshold);
    }

    // Update execution fee (owner only)
    function setExecutionFee(uint256 newFee) external onlyOwner {
        executionFee = newFee;
        emit ExecutionFeeUpdated(newFee);
    }

    // Helper function to count zeros in a number
    function countZeros(uint256 num) internal pure returns (uint256) {
        if (num == 0) return 1;

        uint256 count = 0;
        while (num > 0 && num % 10 == 0) {
            count++;
            num = num / 10;
        }
        return count;
    }
}
