// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Pool, Slot0} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IJITPoolManager} from "../interfaces/IJITPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@oz/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AaveHelper, IPool, ModifyLiquidityAave, SwapParamsAave, PoolMetrics} from "../libraries/AaveHelper.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {JITLibrary} from "../libraries/JITLibrary.sol";
import {PositionInfoLibrary, PositionInfo} from "../libraries/PositionInfoLibrary.sol";



/// @notice Represents a liquidity window within a tick range
/// @dev Windows are used to manage concentrated liquidity across specific tick ranges
struct Window {
    /// @notice The lower tick boundary of the window
    int24 tickLower;
    /// @notice The upper tick boundary of the window
    int24 tickUpper;
    /// @notice The amount of liquidity in this window
    int128 liquidity;
    /// @notice Whether this window has been initialized
    bool initialized;
}

/// @title JITPoolManager
/// @notice Manages concentrated liquidity with Just-In-Time (JIT) provisioning and integrates Aave for lending/borrowing
/// @dev Uses SafeCallback to ensure safe re-entrancy during liquidity operations
contract JITPoolManager is IJITPoolManager, SafeCallback {
    using Pool for Pool.State;
    using JITLibrary for Pool.State;
    using AaveHelper for IPool;
    using StateLibrary for IPoolManager;

    IWETH9 internal constant WETH = IWETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IPool internal immutable aavePool;
    address internal immutable owner;

    /// @notice Mapping from PoolId => tickLower => Window
    mapping(PoolId => mapping(int24 => Window)) public windows;

    /// @notice Stores the state of each Uniswap v4 pool
    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice Stores information about positions
    mapping(PoolId => mapping(bytes32 => PositionInfo)) public positionInfo;

    /// @notice Authorization modifier for owner or contract itself
    modifier auth() {
        require(msg.sender == owner);
        _;
    }

    /// @param o Owner address
    /// @param pm PoolManager address
    /// @param ap Aave pool address
    constructor(address o, address pm, address ap) SafeCallback(IPoolManager(pm)) {
        owner = o;
        aavePool = IPool(ap);
    }

    /// @notice Internal function to perform JIT liquidity modification
    /// @param key The PoolKey identifying the pool
    /// @param zeroForOne Swap direction
    /// @param add Whether to add or remove liquidity
    function _jitModifyLiquidity(PoolKey memory key, bool zeroForOne, bool add) internal {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);

        // Compute the active window and its liquidity
        (Window memory active, Window memory next) = JITLibrary.getWindows(pool, key.tickSpacing, zeroForOne);

        // Track active liquidity for next JIT operation
        if (add) {
            _checkSlot0Sync(id);
            JITLibrary.modify(poolManager, key, [active, next]);
        } else {
            _syncPoolState(id);
            active.liquidity = -active.liquidity;
            next.liquidity = -next.liquidity;
            JITLibrary.modify(poolManager, key, [active, next]);
            _resolveJIT(key);
        }
    }

    /// @notice Ensures pool slot0 is synchronized with PoolManager
    function _checkSlot0Sync(PoolId id) internal view {
        Pool.State storage pool = _getPool(id);
        Slot0 slot0 = pool.slot0;
        (uint160 pmSqrtPrice, int24 pmTick,,) = poolManager.getSlot0(id);
        (uint256 feeGrowth0, uint256 feeGrowth1) = poolManager.getFeeGrowthGlobals(id);
        require(pool.feeGrowthGlobal0X128 == feeGrowth0 && pool.feeGrowthGlobal1X128 == feeGrowth1, "Sync");
        require(slot0.sqrtPriceX96() == pmSqrtPrice && slot0.tick() == pmTick, "Sync");
    }

    /// @notice Synchronizes pool state with PoolManager data
    function _syncPoolState(PoolId id) internal {
        Pool.State storage pool = _getPool(id);

        (uint160 sqrtPrice, int24 tick,, uint24 fee) = poolManager.getSlot0(id);
        (uint256 feeGrowth0, uint256 feeGrowth1) = poolManager.getFeeGrowthGlobals(id);
        pool.feeGrowthGlobal0X128 = feeGrowth0;
        pool.feeGrowthGlobal1X128 = feeGrowth1;

        if (pool.slot0.tick() != tick) {
            pool.crossTick(tick, pool.feeGrowthGlobal0X128, pool.feeGrowthGlobal1X128);
            pool.liquidity = poolManager.getLiquidity(id);
        }

        pool.slot0 = pool.slot0.setSqrtPriceX96(sqrtPrice).setTick(tick).setLpFee(fee);
    }

    /// @notice Retrieves current Aave pool metrics
    /// @return PoolMetrics including health factor, utilization, and other position data
    function getPositionData() public view returns (PoolMetrics memory) {
        return aavePool.getPoolMetrics();
    }

    /// @notice Initializes a new pool
    /// @param key PoolKey
    /// @param sqrtPriceX96 Initial sqrt price
    /// @return tick Initial tick
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) public auth returns (int24 tick) {
        uint24 lpFee = key.fee;
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        tick = pool.initialize(sqrtPriceX96, lpFee);
        poolManager.initialize(key, sqrtPriceX96);
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        auth
        returns (bytes32 positionId, BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        uint16 multiplier = uint16(uint256(params.salt));
        int128 totalLiquidity = int128(int256(params.liquidityDelta) * int256(uint256(multiplier)));

        positionId = Position.calculatePositionKey(msg.sender, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage info = positionInfo[key.toId()][positionId];

        info.owner = msg.sender;
        info.asset0 = Currency.unwrap(key.currency0);
        info.asset1 = Currency.unwrap(key.currency1);
        info.tickLower = params.tickLower;
        info.tickUpper = params.tickUpper;
        info.liquidity = uint128(int128(info.liquidity) + int128(totalLiquidity));
        info.multiplier = multiplier;

        BalanceDelta principalDelta;
        (principalDelta, feesAccrued) = _modifyLiquidity(key, params);

        callerDelta = principalDelta + feesAccrued;

        _resolve(key, callerDelta, positionId);
        _sweep(key);

        emit ModifyLiquidity(positionId, msg.sender, params.tickLower, params.tickUpper, totalLiquidity, params.salt);
    }

    /// @notice Modify liquidity in the pool
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        {
            Pool.State storage pool = _getPool(id);
            pool.checkPoolInitialized();

            BalanceDelta principalDelta;
            (principalDelta, feesAccrued) = pool.modifyLiquidity(
                Pool.ModifyLiquidityParams({
                    owner: msg.sender,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: int128(params.liquidityDelta),
                    tickSpacing: key.tickSpacing,
                    salt: params.salt
                })
            );

            // fee delta and principal delta are both accrued to the caller
            callerDelta = principalDelta + feesAccrued;
        }
    }

    /// @notice Performs flash-like JIT operations
    function _resolve(PoolKey memory key, BalanceDelta deltas, bytes32 positionId) internal {
        poolManager.unlock(abi.encode(key, deltas, positionId));
    }

    /// @notice Settles asset amounts with pool manager
    function _settle(Currency currency, address from, int256 amount) internal {
        uint256 _amount = uint256(-amount);

        if (currency.isAddressZero()) {
            if (address(this).balance < _amount) {
                require(WETH.balanceOf(address(this)) >= _amount, "IF");
                WETH.withdraw(_amount);
            }
            poolManager.settle{value: _amount}();
        } else {
            address token = Currency.unwrap(currency);
            poolManager.sync(currency);
            from == address(this)
                ? IERC20(token).transfer(address(poolManager), _amount)
                : IERC20(token).transferFrom(from, address(poolManager), _amount);
            poolManager.settle();
        }
    }

    function supply(address asset, uint128 amount) external auth {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aavePool.supplyToAave(asset, amount);
    }

    function withdraw(address asset, uint128 amount) external auth {
        aavePool.safeWithdraw(asset, amount, msg.sender);
    }

    /// @notice Borrows assets from Aave pool
    function borrow(address asset, uint256 amount) external auth {
        aavePool.borrow(asset, amount);
        IERC20(asset).transfer(msg.sender, amount);
    }

    /// @notice Repays debt to Aave
    function repay(address asset, uint256 amount, bool max) external auth returns (uint256) {
        return aavePool.repay(asset, amount, max);
    }

    /// @notice Repays using aTokens directly
    function repayWithATokens(address asset, uint256 amount, bool max) external auth returns (uint256) {
        return aavePool.repayWithATokens(asset, amount, max);
    }

    /// @notice Sweeps leftover tokens back to the caller
    function _sweep(PoolKey memory key) internal {
        (address t0, address t1,,) = _get(key, toBalanceDelta(0, 0));
        if (address(this).balance > 0) {
            WETH.deposit{value: address(this).balance}();
        }
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        if (b0 > 0) IERC20(t0).transfer(msg.sender, b0);
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        if (b1 > 0) IERC20(t1).transfer(msg.sender, b1);
    }

    /// @notice Resolves JIT swap and liquidity interactions
    function _resolveJIT(PoolKey memory key) internal {
        (int128 d0, int128 d1) = _currencyDeltas(key.currency0, key.currency1);
        address a0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address a1 = Currency.unwrap(key.currency1);

        if (d0 > 0) poolManager.take(key.currency0, address(this), uint128(d0));
        if (d1 > 0) poolManager.take(key.currency1, address(this), uint128(d1));

        aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), a0, a1, toBalanceDelta(-d0, -d1)));

        if (d0 < 0) _settle(key.currency0, address(this), d0);
        if (d1 < 0) _settle(key.currency1, address(this), d1);
    }

    function poolId(PoolKey memory key) external pure returns (PoolId) {
        return key.toId();
    }

    /// @notice Internal getter for pool state
    function _getPool(PoolId id) internal view returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice Returns pool state metrics
    function getPoolState(PoolId id)
        public
        view
        returns (Slot0 slot0, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128, uint128 liquidity)
    {
        Pool.State storage pool = _getPool(id);
        slot0 = pool.slot0;
        liquidity = pool.liquidity;
        feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
        feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;
    }

    function _get(PoolKey memory key, BalanceDelta deltas)
        internal
        pure
        returns (address a0, address a1, int128 d0, int128 d1)
    {
        d0 = deltas.amount0();
        d1 = deltas.amount1();
        a0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        a1 = Currency.unwrap(key.currency1);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (PoolKey memory key, BalanceDelta deltas, bytes32 positionId) =
            abi.decode(data, (PoolKey, BalanceDelta, bytes32));

        PoolId id = key.toId();
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;

        PositionInfo storage info = positionInfo[id][positionId];
        (address a0, address a1, int128 d0, int128 d1) = _get(key, deltas);

        if (d0 < 0 || d1 < 0) {
            _borrowAndModify(c0, c1, a0, a1, d0, d1, deltas, info);
        } else {
            _repayAndModify(c0, c1, a0, a1, d0, d1, deltas, info);
        }
        return data;
    }

    function _borrowAndModify(
        Currency currency0,
        Currency currency1,
        address a0,
        address a1,
        int128 d0,
        int128 d1,
        BalanceDelta deltas,
        PositionInfo storage info
    ) internal {
        // bring liquidity in
        if (d0 < 0) poolManager.take(currency0, address(this), uint128(-d0));
        if (d1 < 0) poolManager.take(currency1, address(this), uint128(-d1));

        int128 userD0;
        int128 userD1;
        if (info.multiplier == 1) {
            userD0 = d0;
            userD1 = d1;
        } else {
            int16 m = int16(info.multiplier);
            userD0 = d0 / m;
            userD1 = d1 / m;
        }

        // deposit into Aave
        aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), a0, a1, deltas));

        // settle user share
        _settle(currency0, info.owner, userD0);
        _settle(currency1, info.owner, userD1);

        // recalc post-modification deltas
        (d0, d1) = _currencyDeltas(currency0, currency1);

        // borrow if necessary
        if (d0 < 0) {
            aavePool.borrow(a0, uint128(-d0));
            _settle(currency0, address(this), d0);
        }
        if (d1 < 0) {
            aavePool.borrow(a1, uint128(-d1));
            _settle(currency1, address(this), d1);
        }

        info.debt = toBalanceDelta(d0, d1);
    }

    function _repayAndModify(
        Currency currency0,
        Currency currency1,
        address a0,
        address a1,
        int128 d0,
        int128 d1,
        BalanceDelta deltas,
        PositionInfo storage info
    ) internal {
        uint256 DUST = 1_000;
        if (info.multiplier > 1) {
            require(info.liquidity == 0);
        }

        // repay if there is debt
        if (info.debt.amount0() < 0 && info.multiplier > 1) {
            poolManager.take(currency0, address(this), uint128(-info.debt.amount0()) + DUST);
            aavePool.repay(a0, uint128(-info.debt.amount0()), false);
        }
        if (info.debt.amount1() < 0) {
            poolManager.take(currency1, address(this), uint128(-info.debt.amount1()) + DUST);
            aavePool.repay(a1, uint128(-info.debt.amount1()), false);
        }

        // modify liquidity on behalf of owner
        aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), a0, a1, deltas));

        // recalc post-modification deltas
        (d0, d1) = _currencyDeltas(currency0, currency1);

        // settle remaining if still negative
        if (d0 < 0) _settle(currency0, address(this), d0);
        if (d1 < 0) _settle(currency1, address(this), d1);

        // reset debt
        info.debt = BalanceDelta.wrap(0);
    }

    function _currencyDeltas(Currency c0, Currency c1) private view returns (int128 d0, int128 d1) {
        d0 = int128(TransientStateLibrary.currencyDelta(poolManager, address(this), c0));
        d1 = int128(TransientStateLibrary.currencyDelta(poolManager, address(this), c1));
    }

    /// @notice Fallback to wrap ETH into WETH
    receive() external payable {
        if (msg.sender != address(WETH)) WETH.deposit{value: msg.value}();
    }
}
