// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Math {
    /// @notice Calcula la raíz cuadrada usando Assembly (Optimizado)
    /// @param x Número del cual calcular la raíz cuadrada
    /// @return y Raíz cuadrada
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        assembly {
            let z := add(div(x, 2), 1)
            y := x

            for {} gt(y, z) {} {
                y := z
                z := div(add(div(x, z), z), 2)
            }
        }
    }
}
