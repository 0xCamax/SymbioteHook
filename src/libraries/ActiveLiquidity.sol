// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ActiveLiquidityLibrary {
    bytes32 private constant SLOT = keccak256("ActiveLiquidity.ref");
    bytes32 private constant SLOT0 = keccak256(abi.encodePacked(SLOT, uint256(0)));
    bytes32 private constant SLOT1 = keccak256(abi.encodePacked(SLOT, uint256(1)));

    function isActive() internal view returns (bool active) {
        bytes32 slot = SLOT;
        assembly {
            active := tload(slot)
        }
    }

    /* -------------------------- store/load two refs -------------------------- */

    /// @notice Store both int24 refs into transient storage
    function setRefs(int24 ref0, int24 ref1) internal {
        bool active = true;
        bytes32 slot = SLOT;
        bytes32 slot0 = SLOT0;
        bytes32 slot1 = SLOT1;
        assembly {
            tstore(slot, active)
            tstore(slot0, ref0)
            tstore(slot1, ref1)
        }
    }

    /// @notice Load first ref (int24)
    function getRef0() internal view returns (int24 ref0) {
        bytes32 slot0 = SLOT0;
        assembly {
            ref0 := tload(slot0)
        }
    }

    /// @notice Load second ref (int24)
    function getRef1() internal view returns (int24 ref1) {
        bytes32 slot1 = SLOT1;
        assembly {
            ref1 := tload(slot1)
        }
    }

    function getRefs() internal view returns (int24 ref0, int24 ref1) {
        ref0 = getRef0();
        ref1 = getRef1();
    }

    function toggleActive() internal {
        bool active = !ActiveLiquidityLibrary.isActive();
        bytes32 slot = SLOT;
        assembly {
            tstore(slot, active)
        }
    }
}
