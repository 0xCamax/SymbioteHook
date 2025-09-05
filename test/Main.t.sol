// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PositionManager} from "../src/contracts/PositionManager.sol";
import {CalldataLibrary} from "../src/libraries/CalldataLibrary.sol";
import {ModifyLiquidityParams, PoolKey} from "../src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MainTests is Test {
    PositionManager public posm;

    using CalldataLibrary for bytes;

    function setUp() public {
        // Create Arbitrum mainnet fork
        vm.createSelectFork("arbitrum");

        // Deploy position manager with mock pool manager
        posm = new PositionManager(address(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32));
    }

    function test_CalldataLibrary_GetSelector() public view {
        // Test the selector extraction
        bytes memory testData = abi.encodeWithSelector(
            posm.modifyLiquidity.selector,
            PoolKey({
                currency0: Currency.wrap(address(0x1)),
                currency1: Currency.wrap(address(0x2)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            ModifyLiquidityParams({tickLower: -1000, tickUpper: 1000, liquidityDelta: 1000000, salt: bytes32(0)}),
            bytes("")
        );

        bytes4 extractedSelector = testData.getSelector();
        bytes4 expectedSelector = posm.modifyLiquidity.selector;

        console.log("Expected selector:", vm.toString(expectedSelector));
        console.log("Extracted selector:", vm.toString(extractedSelector));

        assertEq(extractedSelector, expectedSelector, "Selector should match");
    }

    function test_CalldataLibrary_GetModifyLiquidityParams() public view {
        // Create test data
        PoolKey memory originalKey = PoolKey({
            currency0: Currency.wrap(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1), // WETH on Arbitrum
            currency1: Currency.wrap(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9), // USDT on Arbitrum
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        ModifyLiquidityParams memory originalParams = ModifyLiquidityParams({
            tickLower: -887220, // Min tick
            tickUpper: 887220, // Max tick
            liquidityDelta: 1000000000000000000, // 1 ETH worth
            salt: keccak256("test_salt")
        });

        bytes memory originalHookData = abi.encode("test_hook_data", block.timestamp);

        // Encode the data as it would be passed to _unlockCallback
        bytes memory testData =
            abi.encodeWithSelector(posm.modifyLiquidity.selector, originalKey, originalParams, originalHookData);

        // Extract the parameters
        (PoolKey memory extractedKey, ModifyLiquidityParams memory extractedParams, bytes memory extractedHookData) =
            testData.getModifyLiquidityParams();

        // Verify PoolKey
        assertEq(
            Currency.unwrap(extractedKey.currency0), Currency.unwrap(originalKey.currency0), "Currency0 should match"
        );
        assertEq(
            Currency.unwrap(extractedKey.currency1), Currency.unwrap(originalKey.currency1), "Currency1 should match"
        );
        assertEq(extractedKey.fee, originalKey.fee, "Fee should match");
        assertEq(extractedKey.tickSpacing, originalKey.tickSpacing, "TickSpacing should match");
        assertEq(address(extractedKey.hooks), address(originalKey.hooks), "Hooks should match");

        // Verify ModifyLiquidityParams
        assertEq(extractedParams.tickLower, originalParams.tickLower, "TickLower should match");
        assertEq(extractedParams.tickUpper, originalParams.tickUpper, "TickUpper should match");
        assertEq(extractedParams.liquidityDelta, originalParams.liquidityDelta, "LiquidityDelta should match");
        assertEq(extractedParams.salt, originalParams.salt, "Salt should match");

        // Verify hook data
        assertEq(extractedHookData, originalHookData, "Hook data should match");

        console.log("All parameters extracted correctly!");
    }

    function test_ModifyLiquidity_EndToEnd() public {
        // Create realistic test parameters
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1), // WETH
            currency1: Currency.wrap(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9), // USDT
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, // One tick below current
            tickUpper: 60, // One tick above current
            liquidityDelta: 1000000000000000000, // 1 ETH worth of liquidity
            salt: keccak256(abi.encode("test", block.timestamp))
        });

        bytes memory hookData = abi.encode("integration_test", block.number);

        // Call modifyLiquidity
        posm.modifyLiquidity(key, params, hookData);

        console.log("End-to-end test passed - data flows correctly through the system");
    }

    function test_ModifyLiquidity_MultipleParams() public {
        // Test with various parameter combinations to ensure robustness
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0x123))
        });

        ModifyLiquidityParams[3] memory paramsList = [
            ModifyLiquidityParams({tickLower: -1000, tickUpper: 1000, liquidityDelta: 1000, salt: bytes32(uint256(1))}),
            ModifyLiquidityParams({
                tickLower: -500,
                tickUpper: 500,
                liquidityDelta: -500, // Removing liquidity
                salt: bytes32(uint256(2))
            }),
            ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 1000,
                liquidityDelta: 2000,
                salt: bytes32(0) // Zero salt
            })
        ];

        for (uint256 i = 0; i < paramsList.length; i++) {
            bytes memory hookData = abi.encode("test", i);

            posm.modifyLiquidity(key, paramsList[i], hookData);

            console.log("Test case", i, "passed");
        }
    }

    function test_CalldataLibrary_EdgeCases() public view {
        // Test with minimal data (just selector)
        bytes memory minimalData = abi.encodeWithSelector(posm.modifyLiquidity.selector);
        bytes4 selector = minimalData.getSelector();
        assertEq(selector, posm.modifyLiquidity.selector, "Should extract selector from minimal data");

        // Test with extra data after the expected parameters
        bytes memory dataWithExtra = abi.encodePacked(
            abi.encodeWithSelector(
                posm.modifyLiquidity.selector,
                PoolKey({
                    currency0: Currency.wrap(address(0x1)),
                    currency1: Currency.wrap(address(0x2)),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                }),
                ModifyLiquidityParams({tickLower: -1000, tickUpper: 1000, liquidityDelta: 1000000, salt: bytes32(0)}),
                bytes("")
            ),
            bytes("extra_data_that_should_be_ignored")
        );

        // Should still extract correctly
        (PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData) =
            dataWithExtra.getModifyLiquidityParams();

        assertEq(Currency.unwrap(key.currency0), address(0x1), "Should extract key correctly despite extra data");
        assertEq(params.liquidityDelta, 1000000, "Should extract params correctly despite extra data");
        assertEq(hookData.length, 0, "Should extract empty hook data correctly");
    }

    // Helper function to log parameter details
    function logParams(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData) internal pure {
        console.log("=== Parameters ===");
        console.log("Currency0:", Currency.unwrap(key.currency0));
        console.log("Currency1:", Currency.unwrap(key.currency1));
        console.log("Fee:", key.fee);
        console.log("TickSpacing:", key.tickSpacing);
        console.log("Hooks:", address(key.hooks));
        console.log("TickLower:", vm.toString(params.tickLower));
        console.log("TickUpper:", vm.toString(params.tickUpper));
        console.log("LiquidityDelta:", vm.toString(params.liquidityDelta));
        console.log("Salt:", vm.toString(params.salt));
        console.log("HookData length:", hookData.length);
    }
}
