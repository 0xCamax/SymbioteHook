// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IPositionManager {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams calldata params, bytes memory hookData)
        external;
}
