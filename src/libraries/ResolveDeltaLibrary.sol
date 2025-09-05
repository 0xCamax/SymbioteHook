// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@oz/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

library ResolveDeltaLibrary {
    function resolve(BalanceDelta delta, address resolver, PoolKey memory key, IPoolManager manager) internal {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if (delta0 < 0) {
            if (address(0) == token0) {
                manager.settle{value: uint128(delta.amount0())}();
            } else {
                manager.sync(key.currency0);
                IERC20(token0).transferFrom(resolver, address(manager), uint128(delta.amount0()));
                manager.settle();
            }
        }
        if (delta1 < 0) {
            manager.sync(key.currency1);
            IERC20(token1).transferFrom(resolver, address(manager), uint128(delta.amount1()));
            manager.settle();
        }
        if (delta0 > 0) {
            manager.take(key.currency0, resolver, uint128(delta0));
        }
        if (delta1 > 0) {
            manager.take(key.currency1, resolver, uint128(delta1));
        }
    }
}
