// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/SymbioteHook.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArbitrumConstants} from "../src/contracts/Constants.sol";
import {HookDeployer} from "../src/contracts/HookDeployer.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityMath} from "../src/libraries/LiquidityMath.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Test, console2} from "forge-std/Test.sol";

contract HookScript is Script, ArbitrumConstants {
    using StateLibrary for IPoolManager;
    using TickMath for int24;

    PoolKey internal poolKey;
    PoolKey internal baseKey;
    SymbioteHook internal hook;

    function setUp() public {}

    function run() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

        uint160[] memory _flags = new uint160[](3);
        _flags[0] = Hooks.BEFORE_SWAP_FLAG;
        _flags[1] = Hooks.AFTER_SWAP_FLAG;
        _flags[2] = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

        bytes memory constructorArgs = abi.encode(0xa14BB91455e3b70d2d4F59a0D3CbF35d939308Fc, POOL_MANAGER, AAVE_POOL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(HOOK_DEPLOYER), flags, type(SymbioteHook).creationCode, constructorArgs);
        _configurePoolKeys(3000, 50, hookAddress);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.broadcast(deployerPrivateKey);
        hook = SymbioteHook(
            payable(
                HOOK_DEPLOYER.safeDeploy(type(SymbioteHook).creationCode, constructorArgs, salt, hookAddress, _flags)
            )
        );

        console2.log("Hook address:", address(hook));

        require(address(hook) == hookAddress, "Hook address mismatch");

        _setupApprovals(deployerPrivateKey);

        // Initialize pool
        _initializePool(deployerPrivateKey);

        // Add liquidity (EOA must have ETH)
        _addLiquidity(5e14, 4, deployerPrivateKey);
    }

    function _configurePoolKeys(uint24 fee, int24 tickSpacing, address hookAddress) private {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(USDC)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        baseKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(USDC)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function _setupApprovals(uint256 deployerPrivateKey) private {
        vm.broadcast(deployerPrivateKey);
        USDC.approve(address(hook), type(uint256).max);
        USDC.approve(address(PERMIT2), type(uint256).max);
    }

    function _initializePool(uint256 deployerPrivateKey) private {
        (, int24 baseTick,,) = POOL_MANAGER.getSlot0(baseKey.toId());
        uint160 sqrtPrice = (baseTick - (baseTick % poolKey.tickSpacing)).getSqrtPriceAtTick();
        vm.broadcast(deployerPrivateKey);
        hook.initialize(poolKey, sqrtPrice);
    }

    function _addLiquidity(uint256 amount0, uint16 multiplier, uint256 deployerPrivateKey)
        private
        returns (bytes32 positionId, BalanceDelta feesAccrued, int24 tickLower, int24 tickUpper)
    {
        Window memory activeWindow = hook.getActiveWindow(poolKey.toId());

        tickLower = activeWindow.tickLower - (poolKey.tickSpacing * 2);
        tickUpper = activeWindow.tickUpper + (poolKey.tickSpacing * 2);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            tickLower.getSqrtPriceAtTick(), tickUpper.getSqrtPriceAtTick(), amount0
        );

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int128(liquidity),
            salt: bytes32(abi.encode(multiplier))
        });

        BalanceDelta amounts = LiquidityMath.getAmountsForLiquidity(
            POOL_MANAGER, poolKey.toId(), Window(params.tickLower, params.tickUpper, int128(liquidity), false)
        );

        uint256 ethAmount = uint128(amounts.amount0());
        require(ethAmount <= vm.addr(deployerPrivateKey).balance, "EOA lacks ETH for liquidity");

        vm.broadcast(deployerPrivateKey);
        (positionId,, feesAccrued) = hook.modifyLiquidity{value: ethAmount}(poolKey, params);
        console2.log("Position Id: ", vm.toString(positionId));
    }
}
