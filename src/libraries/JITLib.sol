// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Window} from "../contracts/JITPoolManager.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library JITLib {
    function getJITWindows(Pool.State storage state, int24 spacing, bool zeroForOne)
        internal
        view
        returns (Window memory active, Window memory next)
    {
        active = getActiveWindow(state, spacing);

        next = zeroForOne
            ? Window(active.tickLower - spacing, active.tickLower, 0, false)
            : Window(active.tickUpper, active.tickUpper + spacing, 0, false);

        if (zeroForOne) {
            Pool.TickInfo storage info = state.ticks[next.tickUpper];
            next.liquidity = active.liquidity + -info.liquidityNet;
        } else {
            Pool.TickInfo storage info = state.ticks[next.tickLower];
            next.liquidity = active.liquidity + info.liquidityNet;
        }

        return (active, next);
    }

    function getActiveWindow(Pool.State storage state, int24 spacing) internal view returns (Window memory) {
        int24 currentTick = state.slot0.tick();
        int24 activeTickLower = currentTick - (currentTick % spacing);
        return Window({
            tickLower: activeTickLower,
            tickUpper: activeTickLower + spacing,
            liquidity: int128(state.liquidity),
            initialized: true
        });
    }

    function modify(IPoolManager pm, PoolKey memory key, Window memory w) internal {
        if (w.liquidity == 0) return;
        pm.modifyLiquidity(key, ModifyLiquidityParams(w.tickLower, w.tickUpper, w.liquidity, bytes32(0)), "");
    }
}
