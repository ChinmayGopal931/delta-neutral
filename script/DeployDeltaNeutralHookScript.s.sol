// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeltaNeutralHook} from "../src/DeltaNeutralHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Constants} from "./base/Constants.sol";

/// @notice Deploys the DeltaNeutralHook contract with proper hook flags
contract DeployDeltaNeutralHookScript is Script, Constants {
    // GMX Arbitrum Goerli (testnet) addresses
    address constant EXCHANGE_ROUTER = 0x4bf010f1b9beDA5450a8dD702ED602A104ff65EE;
    address constant READER = 0xb317837966A69ffB533048208F06e8aa0D98eC47;
    address constant DATA_STORE = 0xB558f529F97a405178E2437737F97Bb10eFadAfE;
    address constant USDC = 0x04FC936a15352a1b15b3B9c56EA002051e3DB3e5; // USDC on Arbitrum Goerli
    address constant PRICE_FEED = 0x1e53158F1081B82FdE127FEE23d9F97213f08190;

    address constant WETH = 0xCdfF6DDCe19f2c536509eEC7c25Aef8Bb7f1DF1D; // WETH on Arbitrum Goerli
    address constant MARKET_ETH = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336; // ETH market

    // Configuration parameters
    uint8 constant TOKEN0_DECIMALS = 18; // ETH has 18 decimals
    uint256 constant REBALANCE_THRESHOLD = 1e30; // 1 USD with 30 decimals (GMX uses 30 decimals for USD)
    uint256 constant EXECUTION_FEE = 0.0001 ether; // Execution fee for GMX orders

    function run() public {
        // Define the hook flags the contract will use
        uint160 flags = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOLMANAGER),
            EXCHANGE_ROUTER,
            READER,
            DATA_STORE,
            MARKET_ETH,
            USDC,
            PRICE_FEED,
            WETH,
            TOKEN0_DECIMALS,
            REBALANCE_THRESHOLD,
            EXECUTION_FEE
        );

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(DeltaNeutralHook).creationCode, constructorArgs);

        console.log("DeltaNeutralHook address with correct flags: %s", hookAddress);
        console.log("Salt: %s", vm.toString(salt));

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        DeltaNeutralHook hook = new DeltaNeutralHook{salt: salt}(
            IPoolManager(POOLMANAGER),
            EXCHANGE_ROUTER,
            READER,
            DATA_STORE,
            MARKET_ETH,
            USDC,
            PRICE_FEED,
            WETH,
            TOKEN0_DECIMALS,
            REBALANCE_THRESHOLD,
            EXECUTION_FEE
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployDeltaNeutralHookScript: hook address mismatch");
        console.log("DeltaNeutralHook deployed at:", address(hook));
    }
}
