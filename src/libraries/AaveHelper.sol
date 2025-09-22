// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPool} from "@aave/src/contracts/interfaces/IPool.sol";
import {ICreditDelegationToken} from "@aave/src/contracts/interfaces/ICreditDelegationToken.sol";
import {IAToken} from "@aave/src/contracts/interfaces/IAToken.sol";
import {IERC20} from "@oz/contracts/token/ERC20/IERC20.sol";
import {IVariableDebtToken} from "@aave/src/contracts/interfaces/IVariableDebtToken.sol";
import {DataTypes} from "@aave/src/contracts/protocol/libraries/types/DataTypes.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

struct ModifyLiquidityAave {
    address user;
    address asset0;
    address asset1;
    BalanceDelta delta;
}

struct SwapParamsAave {
    address asset0;
    address asset1;
    BalanceDelta delta;
}

struct AssetData {
    address aTokenAddress;
    address variableDebtTokenAddress;
    uint128 liquidityIndex;
    uint128 variableBorrowIndex;
    uint128 currentLiquidityRate;
    uint128 currentVariableBorrowRate;
    uint40 lastUpdateTimestamp;
}

struct PoolMetrics {
    uint256 totalCollateral;
    uint256 totalDebt;
    uint256 availableBorrows;
    uint256 currentLiquidationThreshold;
    uint256 ltv;
    uint256 healthFactor;
}

library AaveHelper {
    using AaveHelper for IPool;

    uint256 private constant DUST = 1_000;

    function _supplyToAave(IPool pool, address asset, uint128 amount) private {
        IERC20(asset).approve(address(pool), amount);
        pool.supply(asset, amount, address(this), 0);
    }

    function safeWithdraw(IPool pool, address asset, uint128 amount, address to) internal {
        try pool.withdraw(asset, amount, to) {
            _handleResidualDebt(pool, asset);
        } catch {
            _handleFallbackWithdraw(pool, asset, to);
        }
    }

    function _handleResidualDebt(IPool pool, address asset) private {
        uint256 debt = getVariableDebtBalance(pool, asset);
        if (debt < DUST && debt != 0) {
            repay(pool, asset, 0, true);
        }
    }

    function _handleFallbackWithdraw(IPool pool, address asset, address to) private {
        uint256 debt = getVariableDebtBalance(pool, asset);
        if (debt < DUST && debt != 0) {
            repayWithATokens(pool, asset, 0, true);
        }

        pool.withdraw(asset, getATokenBalance(pool, asset), to);
    }

    function modifyLiquidity(IPool pool, ModifyLiquidityAave memory params) internal {
        int128 amount0 = params.delta.amount0();
        int128 amount1 = params.delta.amount1();

        // Supply negative amounts (using helper)
        if (amount0 < 0) _supplyToAave(pool, params.asset0, uint128(-amount0));
        if (amount1 < 0) _supplyToAave(pool, params.asset1, uint128(-amount1));

        // Withdraw positive amounts (direct calls)
        if (amount0 > 0) safeWithdraw(pool, params.asset0, uint128(amount0), params.user);
        if (amount1 > 0) safeWithdraw(pool, params.asset1, uint128(amount1), params.user);
    }

    function swap(IPool pool, SwapParamsAave memory params) internal {
        int128 amount0 = params.delta.amount0();
        int128 amount1 = params.delta.amount1();
        require(amount0 > 0 || amount1 > 0);

        if (amount0 > amount1) {
            _supplyToAave(pool, params.asset0, uint128(amount0));
            safeWithdraw(pool, params.asset1, uint128(-amount1), address(this));
        } else {
            _supplyToAave(pool, params.asset1, uint128(amount1));
            safeWithdraw(pool, params.asset0, uint128(-amount0), address(this));
        }
    }

    function borrow(IPool pool, address asset, uint256 amount) internal {
        pool.setUserUseReserveAsCollateral(asset, true);
        pool.borrow(asset, amount, 2, 0, address(this));
    }

    function repay(IPool pool, address asset, uint256 amount, bool max) internal returns (uint256) {
        IERC20(asset).approve(address(pool), max ? DUST : amount);
        return pool.repay(asset, max ? type(uint256).max : amount, 2, address(this));
    }

    function repayWithATokens(IPool pool, address asset, uint256 amount, bool max) internal returns (uint256) {
        return pool.repayWithATokens(asset, max ? type(uint256).max : amount, 2);
    }

    function getAssetReserveData(IPool pool, address asset)
        internal
        view
        returns (DataTypes.ReserveDataLegacy memory)
    {
        return pool.getReserveData(asset);
    }

    /**
     * @dev Get comprehensive asset data from Aave
     */
    function getAssetData(IPool pool, address asset) internal view returns (AssetData memory data) {
        DataTypes.ReserveDataLegacy memory d = pool.getReserveData(asset);
        data.liquidityIndex = d.liquidityIndex;
        data.variableBorrowIndex = d.variableBorrowIndex;
        data.currentLiquidityRate = d.currentLiquidityRate;
        data.currentVariableBorrowRate = d.currentVariableBorrowRate;
        data.lastUpdateTimestamp = d.lastUpdateTimestamp;
        data.aTokenAddress = pool.getReserveAToken(asset);
        data.variableDebtTokenAddress = pool.getReserveVariableDebtToken(asset);
    }

    /**
     * @dev Get pool's current metrics from Aave
     */
    function getPoolMetrics(IPool pool) internal view returns (PoolMetrics memory metrics) {
        (
            metrics.totalCollateral,
            metrics.totalDebt,
            metrics.availableBorrows,
            metrics.currentLiquidationThreshold,
            metrics.ltv,
            metrics.healthFactor
        ) = pool.getUserAccountData(address(this));
    }

    /**
     * @dev Get current aToken balance for an asset
     */
    function getATokenBalance(IPool pool, address asset) internal view returns (uint256 balance) {
        AssetData memory data = getAssetData(pool, asset);
        if (data.aTokenAddress != address(0)) {
            balance = IAToken(data.aTokenAddress).balanceOf(address(this));
        }
    }

    /**
     * @dev Get current variable debt balance for an asset
     */
    function getVariableDebtBalance(IPool pool, address asset) internal view returns (uint256 balance) {
        AssetData memory data = getAssetData(pool, asset);
        if (data.variableDebtTokenAddress != address(0)) {
            balance = IERC20(data.variableDebtTokenAddress).balanceOf(address(this));
        }
    }

    /**
     * @dev Check if asset can be used as collateral
     */
    function canUseAsCollateral(IPool pool, address asset) internal view returns (bool) {
        AssetData memory data = getAssetData(pool, asset);
        return data.aTokenAddress != address(0) && data.currentLiquidityRate > 0;
    }
}
