// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {Window} from "../contracts/JITPoolManager.sol";
import {AaveHelper, IPool, ReserveConfigDecoded} from "./AaveHelper.sol";
import {ERC20} from "@oz/contracts/token/ERC20/ERC20.sol";

/// @notice Stores basic information about a user’s position
struct PositionInfo {
    /// @notice Owner of the position
    address owner;
    address asset0;
    address asset1;
    /// @notice Lower tick boundary of the position
    int24 tickLower;
    /// @notice Upper tick boundary of the position
    int24 tickUpper;
    /// @notice The amount of liquidity in this position
    uint128 liquidity;
    /// @notice The multiplier of liquidity in this position
    uint16 multiplier;
    /// @notice Position debt
    BalanceDelta debt;
}

library PositionInfoLibrary {
    using PositionInfoLibrary for PositionInfo;

    function collateral(PositionInfo memory info, uint160 sqrtPrice) internal pure returns (BalanceDelta) {
        return LiquidityMath.getAmountsForLiquidity(sqrtPrice, info.toWindow());
    }

    function toWindow(PositionInfo memory info) internal pure returns (Window memory) {
        return Window(info.tickLower, info.tickUpper, int128(info.liquidity), true);
    }

    function healthFactor(PositionInfo memory info, IPool pool, uint160 sqrtPrice) external view returns (uint256) {
        BalanceDelta col = info.collateral(sqrtPrice);
        BalanceDelta deb = info.debt;

        address[] memory tokens = new address[](2);
        tokens[0] = info.asset0;
        tokens[1] = info.asset1;

        uint256 decimals0 = ERC20(info.asset0).decimals();
        uint256 decimals1 = ERC20(info.asset1).decimals();

        uint256[] memory prices = AaveHelper.getAssetsPrices(pool, tokens);

        ReserveConfigDecoded memory token0Config = AaveHelper.getReserveConfiguration(pool, info.asset0);
        ReserveConfigDecoded memory token1Config = AaveHelper.getReserveConfiguration(pool, info.asset1);

        uint256 adjCol = ((uint128(col.amount0()) * prices[0] * token0Config.ltv) / (10 ** decimals0 * 10000))
            + ((uint128(col.amount1()) * prices[1] * token1Config.ltv) / (10 ** decimals1 * 10000));


        uint256 debtVal = ((uint128(deb.amount0()) * prices[0]) / 10 ** decimals0)
            + ((uint128(deb.amount1()) * prices[1]) / 10 ** decimals1);

        if (debtVal == 0) return type(uint256).max; 


        return (adjCol * 1e18) / debtVal;
    }
}
