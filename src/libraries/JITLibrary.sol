// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Window} from "../contracts/JITPoolManager.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

library JITLibrary {
    function getWindows(Pool.State storage state, int24 spacing, bool zeroForOne)
        internal
        view
        returns (Window memory active, Window memory next)
    {
        active = getActiveWindow(state, spacing);
        next = _nextNearestWindow(
            state, zeroForOne ? active.tickLower : active.tickUpper, spacing, zeroForOne, active.liquidity
        );
    }

    function getActiveWindow(Pool.State storage state, int24 spacing) internal view returns (Window memory window) {
        int24 currentTick = state.slot0.tick();
        int24 base = currentTick / spacing;
        if (currentTick < 0 && currentTick % spacing != 0) {
            base -= 1;
        }
        window.tickLower = base * spacing;
        window.tickUpper = window.tickLower + spacing;
        window.liquidity = int128(state.liquidity);
    }

    function _nextNearestWindow(Pool.State storage state, int24 tick, int24 spacing, bool zeroForOne, int128 liquidity)
        private
        view
        returns (Window memory window)
    {
        uint8 maxIterations = 2;
        uint8 i = 0;
        int24 currentTick = tick;

        while (i < maxIterations) {
            (int24 nearestTick, bool initialized) =
                TickBitmap.nextInitializedTickWithinOneWord(state.tickBitmap, currentTick, spacing, zeroForOne);

            int128 liqNet = state.ticks[nearestTick].liquidityNet;

            if (initialized) {
                if (zeroForOne) {
                    bool noGap = liqNet > 0 && liquidity > 0;
                    liquidity = noGap ? liquidity : liquidity + -liqNet;
                    window.tickUpper = noGap ? tick : nearestTick;
                    window.tickLower = noGap ? nearestTick : nearestTick - spacing;
                    window.liquidity = liquidity;
                } else {
                    bool noGap = liqNet < 0 && liquidity > 0;
                    liquidity = noGap ? liquidity : liquidity + liqNet;
                    window.tickLower = noGap ? tick : nearestTick;
                    window.tickUpper = noGap ? nearestTick : nearestTick + spacing;
                    window.liquidity = liquidity;
                }
                return window;
            }

            // Prepare for next iteration
            currentTick = zeroForOne ? nearestTick - spacing : nearestTick + spacing;
            i++;
        }

        // If not found after maxIterations, return default window
        window.tickLower = currentTick;
        window.tickUpper = zeroForOne ? currentTick - spacing : currentTick + spacing;
        window.liquidity = liquidity;
    }

    function modify(IPoolManager pm, PoolKey memory key, Window[2] memory w)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrue)
    {
        for (uint8 i = 0; i < w.length; i++) {
            if (w[i].liquidity == 0) continue;
            (callerDelta, feesAccrue) = pm.modifyLiquidity(
                key, ModifyLiquidityParams(w[i].tickLower, w[i].tickUpper, w[i].liquidity, bytes32(0)), ""
            );
        }
    }
}
