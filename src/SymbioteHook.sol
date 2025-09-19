// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./contracts/BaseHook.sol";
import "./contracts/JITPoolManager.sol";

contract SymbioteHook is BaseHook, JITPoolManager {
    using TickMath for int24;
    using StateLibrary for IPoolManager;

    constructor(address initialOwner, address _poolManager, address _WETH, address _aavePool)
        JITPoolManager(initialOwner, _poolManager, _WETH, _aavePool)
    {}

    /// @notice The hook called after the state of a pool is initialized
    /// @return bytes4 The function selector for the hook
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPrice, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        initialize(key, sqrtPrice);
        return this.afterInitialize.selector;
    }

    /*
        Users can only add liquidity from hook
    */
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "Error: Add liquidity from hook");
        return (this.beforeAddLiquidity.selector);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        /*
        add JIT liquidity
        */

        _jitModifyLiquidity(key, params.zeroForOne, true);
        return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), _swapFee(key));
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        /*
        remove JIT liquidity
        */

        (uint160 pmSqrtPrice,,,) = poolManager.getSlot0(key.toId());

        Window[2] memory activeWindows = getActiveWindows(key, params.zeroForOne);
        if (params.zeroForOne) {
            require(activeWindows[1].tickLower.getSqrtPriceAtTick() < pmSqrtPrice, "Slippage");
        } else {
            require(activeWindows[1].tickUpper.getSqrtPriceAtTick() > pmSqrtPrice, "Slippage");
        }

        _jitModifyLiquidity(key, params.zeroForOne, false);

        return (this.afterSwap.selector, 0);
    }

}
