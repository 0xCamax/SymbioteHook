// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {Window} from "../contracts/JITPoolManager.sol";
import {ActiveLiquidityLibrary} from "./ActiveLiquidity.sol";

library JITLib {
    using TickBitmap for mapping(int16 => uint256);

    function getJITWindow(Pool.State storage state, int24 spacing, bool zeroForOne)
        internal
        view
        returns (Window memory window)
    {
        if (ActiveLiquidityLibrary.isActive()) {
            (uint128 l, int24 tl, int24 tu, bool a) = ActiveLiquidityLibrary.get();
            return Window(tl, tu, l, a);
        }
        window = getActiveWindow(state, spacing);

        (int24 tickNext, bool initilized) = state.tickBitmap.nextInitializedTickWithinOneWord(
            zeroForOne ? window.tickLower - 1 : window.tickLower + 1, spacing, zeroForOne
        );

        Pool.TickInfo storage info = state.ticks[tickNext];

        if (initilized && zeroForOne) {
            window.tickLower = tickNext;
            window.liquidity += uint128(-info.liquidityNet);
        } else if (initilized && !zeroForOne) {
            window.tickUpper = tickNext + spacing;
            window.liquidity += uint128(info.liquidityNet);
        }

        return window;
    }

    function getActiveWindow(Pool.State storage state, int24 spacing) internal view returns (Window memory) {
        int24 currentTick = state.slot0.tick();
        int24 activeTickLower = currentTick - (currentTick % spacing);
        return Window({
            tickLower: activeTickLower,
            tickUpper: activeTickLower + spacing,
            liquidity: state.liquidity,
            initialized: true
        });
    }
}
