// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./contracts/BaseHook.sol";
import "./contracts/JITPoolManager.sol";

contract SymbioteHook is BaseHook, JITPoolManager {
    using StateLibrary for IPoolManager;

    constructor(address initialOwner, address _poolManager, address _WETH, address _aavePool)
        JITPoolManager(initialOwner, _poolManager, _WETH, _aavePool)
    {}

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

        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        (, int24 tickLower, int24 tickUpper,) = ActiveLiquidityLibrary.get();
        if (params.zeroForOne) {
            require(tickLower < tick, "Slippage");
        } else {
            require(tickUpper > tick, "Slippage");
        }

        _jitModifyLiquidity(key, params.zeroForOne, false);

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Returns the swap fee for a given pool
     * @dev Virtual function that can be overridden for dynamic fee logic
     * @param key The pool key
     * @return The swap fee for the pool
     */
    function _swapFee(PoolKey memory key) internal virtual returns (uint24) {
        return key.fee;
    }
}
