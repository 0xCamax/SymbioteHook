// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library LiquidityMath {
    function mulLeverage(int128 liquidity, uint16 leverageBps) internal pure returns (uint128 leveraged) {
        // leverageBps is scaled, e.g. 4700 = 4.7x leverage in basis points (1e3 = 1x)
        unchecked {
            // First divide to reduce risk of overflow
            leveraged = (uint128(liquidity) / 1e3) * leverageBps;
            // Or more precise with mulDiv if you want rounding control
            // leveraged = (liquidity * leverageBps) / 1e3;
        }
    }
}
