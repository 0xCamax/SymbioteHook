// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    PoolId, Window, BalanceDelta, toBalanceDelta, IPoolManager, StateLibrary
} from "../contracts/JITPoolManager.sol";

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library LiquidityMath {
    using StateLibrary for IPoolManager;

    /// @notice Computes asset delta for a given window
    function _getAmountsDelta(IPoolManager pm, PoolId id, Window memory pos)
        private
        view
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = pm.getSlot0(id);
        if (tick < pos.tickLower) {
            delta = toBalanceDelta(
                int128(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower),
                        TickMath.getSqrtPriceAtTick(pos.tickUpper),
                        int128(pos.liquidity)
                    )
                ),
                0
            );
        } else if (tick < pos.tickUpper) {
            delta = toBalanceDelta(
                int128(
                    SqrtPriceMath.getAmount0Delta(
                        sqrtPriceX96, TickMath.getSqrtPriceAtTick(pos.tickUpper), int128(pos.liquidity)
                    )
                ),
                int128(
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower), sqrtPriceX96, int128(pos.liquidity)
                    )
                )
            );
        } else {
            delta = toBalanceDelta(
                0,
                int128(
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower),
                        TickMath.getSqrtPriceAtTick(pos.tickUpper),
                        int128(pos.liquidity)
                    )
                )
            );
        }
    }

    /// @notice Returns amounts for a given liquidity window, negated for settlement
    function getAmountsForLiquidity(IPoolManager pm, PoolId id, Window memory pos)
        internal
        view
        returns (BalanceDelta)
    {
        BalanceDelta deltas = _getAmountsDelta(pm, id, pos);
        return toBalanceDelta(-deltas.amount0(), -deltas.amount1());
    }
}
