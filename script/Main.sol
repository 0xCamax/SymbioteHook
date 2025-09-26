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

    uint256 deployerPrivateKey;

    ModifyLiquidityParams internal params;

    function setUp() public {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        hook = SymbioteHook(payable(0x5958786F1ea187531a423bC960718564A45f48c0));
        _configurePoolKeys(3000, 50, address(hook));
    }

    function run() public {
        deployHook();
        initializePool();
    }

    function deployHook() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

        uint160[] memory _flags = new uint160[](3);
        _flags[0] = Hooks.BEFORE_SWAP_FLAG;
        _flags[1] = Hooks.AFTER_SWAP_FLAG;
        _flags[2] = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

        bytes memory constructorArgs = abi.encode(0xa14BB91455e3b70d2d4F59a0D3CbF35d939308Fc, POOL_MANAGER, AAVE_POOL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(HOOK_DEPLOYER), flags, type(SymbioteHook).creationCode, constructorArgs);

        _configurePoolKeys(3000, 50, hookAddress);

        vm.broadcast(deployerPrivateKey);
        hook = SymbioteHook(
            payable(
                HOOK_DEPLOYER.safeDeploy(type(SymbioteHook).creationCode, constructorArgs, salt, hookAddress, _flags)
            )
        );

        console2.log("Hook deployed at:", address(hook));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function initializePool() public {
        require(address(hook) != address(0), "Hook not deployed");

        _setupApprovals();

        (, int24 baseTick,,) = POOL_MANAGER.getSlot0(baseKey.toId());
        uint160 sqrtPrice = (baseTick - (baseTick % poolKey.tickSpacing)).getSqrtPriceAtTick();

        vm.broadcast(deployerPrivateKey);
        hook.initialize(poolKey, sqrtPrice);

        console2.log("Pool initialized");
    }

    function addLiquidity(uint256 amount0, uint16 multiplier) public {
        require(address(hook) != address(0), "Hook not deployed");

        _addLiquidity(amount0, multiplier);
        console2.log("Liquidity added");
    }

    function removeLiquidity() public {
        require(address(hook) != address(0), "Hook not deployed");

        _removeLiquidity(poolKey, params);
        console2.log("Liquidity removed");
    }

    function borrow(uint256 amount) public {
        vm.broadcast(deployerPrivateKey);
        hook.borrow(address(WETH), amount);
    }

    function swap(uint128 amountIn, bool zeroForOne) public {
        _swap(amountIn, zeroForOne);
    }

    function _removeLiquidity(PoolKey memory _key, ModifyLiquidityParams memory _params)
        private
        returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued)
    {
        _params.liquidityDelta = -_params.liquidityDelta;
        (, liquidityDelta, feesAccrued) = hook.modifyLiquidity{value: 1_000}(_key, _params);
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

    function _setupApprovals() private {
        vm.broadcast(deployerPrivateKey);
        USDC.approve(address(hook), type(uint256).max);
        USDC.approve(address(PERMIT2), type(uint256).max);
    }

    function _initializePool() private {
        (, int24 baseTick,,) = POOL_MANAGER.getSlot0(baseKey.toId());
        uint160 sqrtPrice = (baseTick - (baseTick % poolKey.tickSpacing)).getSqrtPriceAtTick();
        vm.broadcast(deployerPrivateKey);
        hook.initialize(poolKey, sqrtPrice);
    }

    function _addLiquidity(uint256 amount0, uint16 multiplier)
        private
        returns (bytes32 positionId, BalanceDelta feesAccrued, int24 tickLower, int24 tickUpper)
    {
        Window memory activeWindow = hook.getActiveWindow(poolKey.toId());

        tickLower = activeWindow.tickLower - (poolKey.tickSpacing * 2);
        tickUpper = activeWindow.tickUpper + (poolKey.tickSpacing * 2);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            tickLower.getSqrtPriceAtTick(), tickUpper.getSqrtPriceAtTick(), amount0
        );

        params = ModifyLiquidityParams({
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

    function _swap(uint128 amountIn, bool zeroForOne) private {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory _params = new bytes[](3);
        _params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );

        _params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        _params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, _params);
        uint256 deadline = block.timestamp + 1 days;
        vm.startBroadcast(deployerPrivateKey);

        if (!zeroForOne) {
            // Approve USDC (currency1) to Router via Permit2
            PERMIT2.approve(
                Currency.unwrap(poolKey.currency1), address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 days)
            );
        }

        ROUTER.execute{value: zeroForOne ? amountIn : 0}(commands, inputs, deadline);

        vm.stopBroadcast();
    }
}
