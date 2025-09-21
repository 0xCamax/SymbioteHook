// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ActiveLiquidityLibrary {
    bytes32 private constant SLOT = keccak256("ActiveLiquidity");

    /// @notice Checks if active liquidity exists
    function isActive() internal view returns (bool active) {
        bytes32 slot = SLOT;
        assembly {
            let data := sload(slot)
            active := and(shr(224, data), 1) // bit 224 reserved for the bool
        }
    }

    /// @notice Sets active liquidity and tick bounds
    function set(int24 tL, int24 tU, uint128 l) internal {
        bytes32 slot = SLOT;
        uint256 data = 0;
        // l: bits 0-127
        data |= uint256(l);
        // tL: bits 128-151
        data |= uint256(uint24(tL)) << 128;
        // tU: bits 152-175
        data |= uint256(uint24(tU)) << 152;
        // active: bit 224
        data |= 1 << 224;
        assembly {
            sstore(slot, data)
        }
    }

    /// @notice Gets active liquidity, tick bounds, and state
    function get() internal view returns (uint128 l, int24 tL, int24 tU, bool active) {
        bytes32 slot = SLOT;
        assembly {
            let data := sload(slot)
            l := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)              // bits 0-127
            tL := and(shr(128, data), 0xFFFFFF)                            // bits 128-151
            tU := and(shr(152, data), 0xFFFFFF)                            // bits 152-175
            active := eq(and(shr(224, data), 1), 1)                        // bit 224
        }
    }

    /// @notice Toggles the active state
    function toggle() internal {
        bytes32 slot = SLOT;
        assembly {
            let data := sload(slot)
            data := xor(data, shl(224, 1)) // toggle bit 224
            sstore(slot, data)
        }
    }

    /// @notice Clears the entire slot
    function clear() internal {
        bytes32 slot = SLOT;
        assembly {
            sstore(slot, 0)
        }
    }
}

