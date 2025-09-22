// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Pool, Slot0} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IJITPoolManager} from "../interfaces/IJITPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@oz/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AaveHelper, IPool, ModifyLiquidityAave, SwapParamsAave, PoolMetrics} from "../libraries/AaveHelper.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ActiveLiquidityLibrary} from "../libraries/ActiveLiquidity.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {JITLib} from "../libraries/JITLib.sol";

import {console2} from "forge-std/Test.sol";

/// @notice Stores basic information about a user’s position
struct PositionInfo {
    /// @notice Owner of the position
    address owner;
    /// @notice Lower tick boundary of the position
    int24 tickLower;
    /// @notice Upper tick boundary of the position
    int24 tickUpper;
    /// @notice The amount of liquidity in this position
    uint128 liquidity;
    /// @notice The multiplier of liquidity in this position
    uint16 multiplier;
}

/// @notice Represents a liquidity window within a tick range
/// @dev Windows are used to manage concentrated liquidity across specific tick ranges
struct Window {
    /// @notice The lower tick boundary of the window
    int24 tickLower;
    /// @notice The upper tick boundary of the window
    int24 tickUpper;
    /// @notice The amount of liquidity in this window
    uint128 liquidity;
    /// @notice Whether this window has been initialized
    bool initialized;
}

/// @title JITPoolManager
/// @notice Manages concentrated liquidity with Just-In-Time (JIT) provisioning and integrates Aave for lending/borrowing
/// @dev Uses SafeCallback to ensure safe re-entrancy during liquidity operations
contract JITPoolManager is IJITPoolManager, SafeCallback {
    using Pool for Pool.State;
    using JITLib for Pool.State;
    using AaveHelper for IPool;
    using TickMath for uint160;
    using TickMath for int24;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    IPool internal immutable aavePool;
    IWETH9 internal immutable WETH;
    address internal owner;

    /// @notice Mapping from PoolId => tickLower => Window
    mapping(PoolId => mapping(int24 => Window)) public windows;

    /// @notice Stores the state of each Uniswap v4 pool
    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice Stores information about positions
    mapping(PoolId => mapping(bytes32 => PositionInfo)) public positionInfo;

    /// @notice Mapping from PoolId => tickSpacing for that pool
    mapping(PoolId => int24) internal poolSpacing;

    /// @notice Authorization modifier for owner or contract itself
    modifier auth() {
        require(msg.sender == owner);
        _;
    }

    /// @param o Owner address
    /// @param pm PoolManager address
    /// @param w WETH address
    /// @param ap Aave pool address
    constructor(address o, address pm, address w, address ap) SafeCallback(IPoolManager(pm)) {
        owner = o;
        WETH = IWETH9(w);
        aavePool = IPool(ap);
    }

    /// @notice Internal function to perform JIT liquidity modification
    /// @param key The PoolKey identifying the pool
    /// @param zeroForOne Direction of swap
    /// @param add Whether to add or remove liquidity
    function _jitModifyLiquidity(PoolKey memory key, bool zeroForOne, bool add) internal {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);

        // Compute the active window and its liquidity
        Window memory window = pool.getJITWindow(key.tickSpacing, zeroForOne);

        if (add) _checkSlot0Sync(id);

        // Modify liquidity in the pool manager
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                window.tickLower,
                window.tickUpper,
                add ? int128(window.liquidity) : -int128(window.liquidity),
                bytes32(0)
            ),
            ""
        );

        // Track active liquidity for next JIT operation
        if (add) {
            ActiveLiquidityLibrary.set(window.tickLower, window.tickUpper, window.liquidity);
        } else {
            _syncPoolState(id);
            _resolveJIT(key);
            ActiveLiquidityLibrary.toggle();
        }
    }

    /// @notice Retrieves current Aave pool metrics
    /// @return PoolMetrics including health factor, utilization, and other position data
    function getPositionData() public view returns (PoolMetrics memory) {
        return aavePool.getPoolMetrics();
    }

    /// @notice Ensures pool slot0 is synchronized with PoolManager
    function _checkSlot0Sync(PoolId id) internal view {
        Slot0 slot0 = _getPool(id).slot0;
        (uint160 pmSqrtPrice, int24 pmTick,,) = poolManager.getSlot0(id);
        require(slot0.sqrtPriceX96() == pmSqrtPrice && slot0.tick() == pmTick);
    }

    /// @notice Synchronizes pool state with PoolManager data
    function _syncPoolState(PoolId id) internal {
        Pool.State storage pool = _pools[id];
        (uint160 sqrtPrice,,, uint24 fee) = poolManager.getSlot0(id);
        (uint256 feeGrowth0, uint256 feeGrowth1) = poolManager.getFeeGrowthGlobals(id);
        pool.slot0 = _pools[id].slot0.setSqrtPriceX96(sqrtPrice).setTick(sqrtPrice.getTickAtSqrtPrice()).setLpFee(fee);
        pool.feeGrowthGlobal0X128 = feeGrowth0;
        pool.feeGrowthGlobal1X128 = feeGrowth1;
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
        poolSpacing[id] = key.tickSpacing;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        auth
        returns (bytes32 positionId, BalanceDelta principalDelta, BalanceDelta feesAccrued)
    {
        uint16 multiplier = uint16(uint256(params.salt));
        int128 totalLiquidity = int128(params.liquidityDelta * int16(multiplier));
        int24 nWindows = (params.tickUpper - params.tickLower) / key.tickSpacing;
        if (nWindows < 0) nWindows = -nWindows;

        int128 liquidityPerWindow = totalLiquidity / nWindows;
        int128 remainder = totalLiquidity % nWindows;

        for (int24 i = 0; i < nWindows; i++) {
            int24 lower = params.tickLower + key.tickSpacing * i;
            if (i == nWindows - 1) liquidityPerWindow += remainder;

            ModifyLiquidityParams memory p = ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: lower + key.tickSpacing,
                liquidityDelta: liquidityPerWindow,
                salt: params.salt
            });

            (BalanceDelta pd, BalanceDelta fa) = _modifyLiquidity(key, p);
            principalDelta = principalDelta + pd;
            feesAccrued = feesAccrued + fa;
        }

        positionId = Position.calculatePositionKey(msg.sender, params.tickLower, params.tickUpper, params.salt);
        positionInfo[key.toId()][positionId] = PositionInfo(
            msg.sender,
            params.tickLower,
            params.tickUpper,
            uint128(int128(positionInfo[key.toId()][positionId].liquidity) + int128(params.liquidityDelta)),
            multiplier
        );

        _resolveModifyLiquidity(key, principalDelta + feesAccrued, multiplier);

        emit ModifyLiquidity(positionId, msg.sender, params.tickLower, params.tickUpper, totalLiquidity, params.salt);
    }

    /// @notice Modify liquidity in the pool
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta principalDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        {
            Pool.State storage pool = _getPool(id);
            pool.checkPoolInitialized();

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
        }
    }

    /// @notice Resolves liquidity changes and interacts with Aave if necessary
    function _resolveModifyLiquidity(PoolKey memory key, BalanceDelta deltas, uint16 multiplier) internal {
        (address a0, address a1, int128 d0, int128 d1) = _get(key, deltas);

        if (multiplier == 1) {
            if (d0 < 0) {
                if (key.currency0.isAddressZero()) {
                    require(msg.value >= uint128(-d0));
                    WETH.deposit{value: msg.value}();
                } else {
                    IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), uint128(-d0));
                }
            }
            if (d1 < 0) {
                IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), uint128(-d1));
            }
            aavePool.modifyLiquidity(ModifyLiquidityAave(msg.sender, a0, a1, deltas));
        } else {
            _flash(key, deltas, multiplier);
        }
        _sweep(key);
    }

    /// @notice Performs flash-like JIT operations
    function _flash(PoolKey memory key, BalanceDelta deltas, uint16 multiplier) internal {
        poolManager.unlock(abi.encode(msg.sender, key, deltas, multiplier));
    }

    /// @notice Settles asset amounts with pool manager
    function _settle(Currency currency, address from, int256 amount) internal {
        uint256 _amount = uint256(-amount);
        if (currency.isAddressZero()) {
            if (address(this).balance < _amount) {
                require(WETH.balanceOf(address(this)) >= _amount);
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

    /// @notice Borrows assets from Aave pool
    function borrow(address asset, uint256 amount) public auth {
        aavePool.borrow(asset, amount);
    }

    /// @notice Repays debt to Aave
    function repay(address asset, uint256 amount, bool max) public auth returns (uint256) {
        return aavePool.repay(asset, amount, max);
    }

    /// @notice Repays using aTokens directly
    function repayWithATokens(address asset, uint256 amount, bool max) public auth returns (uint256) {
        return aavePool.repayWithATokens(asset, amount, max);
    }

    /// @notice Sweeps leftover tokens back to the caller
    function _sweep(PoolKey memory key) internal {
        (address t0, address t1,,) = _get(key, toBalanceDelta(0, 0));
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        if (b0 > 0) IERC20(t0).transfer(msg.sender, b0);
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        if (b1 > 0) IERC20(t1).transfer(msg.sender, b1);
    }

    /// @notice Resolves JIT swap and liquidity interactions
    function _resolveJIT(PoolKey memory key) internal {
        int128 d0 = int128(poolManager.currencyDelta(address(this), key.currency0));
        int128 d1 = int128(poolManager.currencyDelta(address(this), key.currency1));
        address a0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address a1 = Currency.unwrap(key.currency1);

        if (d0 > 0) poolManager.take(key.currency0, address(this), uint128(d0));
        if (d1 > 0) poolManager.take(key.currency1, address(this), uint128(d1));

        aavePool.swap(SwapParamsAave(a0, a1, toBalanceDelta(d0, d1)));

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

    /// @notice Returns the currently active window for a pool
    function getActiveWindow(PoolId id) external view returns (Window memory) {
        return _getActiveWindow(id);
    }

    function _getActiveWindow(PoolId id) internal view returns (Window memory) {
        Pool.State storage pool = _getPool(id);
        int24 spacing = poolSpacing[id];
        return pool.getActiveWindow(spacing);
    }

    function _get(PoolKey memory key, BalanceDelta deltas)
        internal
        view
        returns (address a0, address a1, int128 d0, int128 d1)
    {
        d0 = deltas.amount0();
        d1 = deltas.amount1();
        a0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        a1 = Currency.unwrap(key.currency1);
    }

    /// @notice Callback handler for flash-like JIT operations
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (address user, PoolKey memory key, BalanceDelta deltas, uint16 multiplier) =
            abi.decode(data, (address, PoolKey, BalanceDelta, uint16));
        (address a0, address a1, int128 d0, int128 d1) = _get(key, deltas);

        int128 userD0 = d0 / int16(multiplier);
        int128 userD1 = d1 / int16(multiplier);

        //We can assume that delta1 is also < 0
        if (d0 < 0) {
            poolManager.take(key.currency0, address(this), uint128(-d0));
            poolManager.take(key.currency1, address(this), uint128(-d1));

            aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), a0, a1, deltas));

            _settle(key.currency0, user, userD0);
            _settle(key.currency1, user, userD1);

            d0 = int128(poolManager.currencyDelta(address(this), key.currency0));
            d1 = int128(poolManager.currencyDelta(address(this), key.currency1));

            aavePool.borrow(a0, uint128(-d0));
            _settle(key.currency0, address(this), d0);

            aavePool.borrow(a1, uint128(-d1));
            _settle(key.currency1, address(this), d1);
        } else {
            uint256 debt0 = uint128(d0) - uint128(userD0);
            uint256 debt1 = uint128(d1) - uint128(userD1);

            poolManager.take(key.currency0, address(this), debt0);
            poolManager.take(key.currency1, address(this), debt1);

            aavePool.repay(a0, debt0, false);
            aavePool.repay(a1, debt1, false);

            aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), a0, a1, deltas));

            _settle(key.currency0, address(this), -int256(debt0));
            _settle(key.currency1, address(this), -int256(debt1));
        }

        return data;
    }

    /// @notice Computes asset delta for a given window
    function _getAmountsDelta(PoolId id, Window memory pos) internal view returns (BalanceDelta delta) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        if (tick < pos.tickLower) {
            delta = toBalanceDelta(
                int128(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower),
                        TickMath.getSqrtPriceAtTick(pos.tickUpper),
                        int128(pos.liquidity)
                    )
                ),
                0
            );
        } else if (tick < pos.tickUpper) {
            delta = toBalanceDelta(
                int128(
                    SqrtPriceMath.getAmount0Delta(
                        sqrtPriceX96, TickMath.getSqrtPriceAtTick(pos.tickUpper), int128(pos.liquidity)
                    )
                ),
                int128(
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower), sqrtPriceX96, int128(pos.liquidity)
                    )
                )
            );
        } else {
            delta = toBalanceDelta(
                0,
                int128(
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(pos.tickLower),
                        TickMath.getSqrtPriceAtTick(pos.tickUpper),
                        int128(pos.liquidity)
                    )
                )
            );
        }
    }

    /// @notice Returns amounts for a given liquidity window, negated for settlement
    function getAmountsForLiquidity(PoolId id, Window memory pos) public view returns (BalanceDelta) {
        BalanceDelta deltas = _getAmountsDelta(id, pos);
        return toBalanceDelta(-deltas.amount0(), -deltas.amount1());
    }

    /// @notice Fallback to wrap ETH into WETH
    receive() external payable {
        if (msg.sender != address(WETH)) WETH.deposit{value: msg.value}();
    }
}
