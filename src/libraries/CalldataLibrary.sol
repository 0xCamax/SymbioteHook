// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ModifyLiquidityParams, PoolKey} from "../interfaces/IPositionManager.sol";

library CalldataLibrary {
    error InsufficientDataLength();
    error InvalidSelector();

    function getSelector(bytes memory data) internal pure returns (bytes4) {
        if (data.length < 4) revert InsufficientDataLength();

        // Extract first 4 bytes using assembly for efficiency
        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        return selector;
    }

    function getModifyLiquidityParams(bytes memory data)
        internal
        pure
        returns (PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
    {
        if (data.length < 4) revert InsufficientDataLength();

        // Skip the first 4 bytes (function selector) and create new bytes array
        bytes memory paramData = new bytes(data.length - 4);

        // Copy data after selector
        for (uint256 i = 4; i < data.length; i++) {
            paramData[i - 4] = data[i];
        }

        // Decode the parameters
        (key, params, hookData) = abi.decode(paramData, (PoolKey, ModifyLiquidityParams, bytes));
    }

    // Additional utility functions
    function skipSelector(bytes memory data) internal pure returns (bytes memory) {
        if (data.length < 4) revert InsufficientDataLength();

        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            result[i - 4] = data[i];
        }
        return result;
    }

    // Safe version that handles insufficient data
    function getSelectorSafe(bytes memory data) internal pure returns (bytes4 selector, bool success) {
        if (data.length < 4) {
            return (bytes4(0), false);
        }

        assembly {
            selector := mload(add(data, 0x20))
        }
        return (selector, true);
    }
}
