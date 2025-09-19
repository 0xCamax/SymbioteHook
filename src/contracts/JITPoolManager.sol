// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Pool, Slot0} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IJITPoolManager} from "../interfaces/IJITPoolManager.sol";
import {ProtocolFees} from "@uniswap/v4-core/src/ProtocolFees.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {CurrencyReserves} from "@uniswap/v4-core/src/libraries/CurrencyReserves.sol";
import {Extsload} from "@uniswap/v4-core/src/Extsload.sol";
import {Exttload} from "@uniswap/v4-core/src/Exttload.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@oz/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {AaveHelper, IPool, ModifyLiquidityAave, SwapParamsAave, PoolMetrics} from "../libraries/AaveHelper.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ActiveLiquidityLibrary} from "../libraries/ActiveLiquidity.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";


/**
 * @notice Information about a specific liquidity position
 * @dev Tracks ownership and parameters of user positions
 */
struct PositionInfo {
    /// @notice The address that owns this position
    address owner;
    /// @notice The lower tick of the position range
    int24 tickLower;
    /// @notice The upper tick of the position range
    int24 tickUpper;
    /// @notice The amount of liquidity in the position
    uint128 liquidity;
}

/**
 * @notice Parameters for modifying liquidity within a window
 * @dev Used to specify how liquidity should be added or removed from windows
 */
struct ModifyLiquidityWindow {
    /// @notice The lower tick offset relative to the active window
    int24 rangeLower;
    /// @notice The upper tick offset relative to the active window
    int24 rangeUpper;
    /// @notice The amount of liquidity to add (positive) or remove (negative)
    int128 liquidityDelta;
    uint16 leverage;
    /// @notice Salt for creating unique position identifiers
    bytes32 salt;
}

/**
 * @title JIT Pool Manager
 * @notice Abstract contract that manages Just-In-Time (JIT) liquidity provision with Aave integration
 * @dev Extends Uniswap V4 functionality with leveraged liquidity provision through Aave lending protocol
 * @dev This contract holds state for all managed pools and provides JIT liquidity mechanisms
 *
 * Key Features:
 * - JIT liquidity provision with automatic window management
 * - Integration with Aave lending protocol for leveraged positions
 * - Window-based liquidity distribution for efficient capital allocation
 * - Automated synchronization with Uniswap V4 pool states
 *
 * @author Protocol Team
 * @custom:security-contact security@protocol.com
 */
abstract contract JITPoolManager is ProtocolFees, Extsload, Exttload, IJITPoolManager, SafeCallback {
    using SafeCast for *;
    using Pool for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;
    using AaveHelper for IPool;
    using TickMath for uint160;
    using TickMath for int24;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using LiquidityMath for int128;

    /// @notice Maximum allowed tick spacing
    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    /// @notice Minimum allowed tick spacing
    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    /// @notice The Aave lending pool contract
    IPool internal immutable aavePool;

    /// @notice The WETH9 contract for handling ETH operations
    IWETH9 internal immutable WETH;

    /// @notice Reference tick for each pool, used as anchor for window calculations
    mapping(PoolId => int24) internal refTick;

    /// @notice Liquidity windows for each pool, organized by tick positions
    mapping(PoolId => mapping(int24 => Window)) public windows;

    /// @notice Internal pool states mirroring Uniswap V4 pools
    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice Position information mapped by pool ID and position hash
    mapping(PoolId => mapping(bytes32 => PositionInfo)) public positionInfo;

    /**
     * @notice Initializes the JIT Pool Manager
     * @param initialOwner The initial owner of the contract (for ProtocolFees)
     * @param _poolManager Address of the Uniswap V4 Pool Manager
     * @param _WETH Address of the WETH9 contract
     * @param _aavePool Address of the Aave lending pool
     */
    constructor(address initialOwner, address _poolManager, address _WETH, address _aavePool)
        ProtocolFees(initialOwner)
        SafeCallback(_poolManager)
    {
        WETH = IWETH9(_WETH);
        aavePool = IPool(_aavePool);
    }

    /**
     * @notice Modifies JIT liquidity by adding or removing from active windows
     * @dev This is the core JIT mechanism that manages liquidity across windows
     * @param key The pool key identifying the target pool
     * @param zeroForOne Direction of potential swap (affects window selection)
     * @param add Whether to add (true) or remove (false) liquidity
     */
    function _jitModifyLiquidity(PoolKey memory key, bool zeroForOne, bool add) internal {
        Window[2] memory _windows = getActiveWindows(key, zeroForOne);

        // Ensure pool state is synchronized before adding liquidity
        if (add) {
            _checkSlot0Sync(key.toId());
        }

        // Calculate total liquidity across both active windows
        uint128 totalLiquidity = _windows[0].liquidity + _windows[1].liquidity;

        // Modify liquidity in the pool manager
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                zeroForOne ? _windows[1].tickLower : _windows[0].tickLower,
                zeroForOne ? _windows[0].tickUpper : _windows[1].tickUpper,
                add ? totalLiquidity.toInt128() : -(totalLiquidity.toInt128()),
                bytes32(0)
            ),
            ""
        );

        if (add) {
            // Set active references for tracking
            ActiveLiquidityLibrary.setRefs(_windows[0].tickLower, _windows[1].tickLower);
        } else {
            // Synchronize state and resolve JIT position
            _syncPoolState(key.toId());
            _resolveJIT(key);
            ActiveLiquidityLibrary.toggleActive();
        }
    }

    /**
     * @notice Verifies that internal pool state is synchronized with Pool Manager
     * @dev Critical for ensuring JIT operations work with accurate price data
     * @param id The pool ID to check
     */
    function _checkSlot0Sync(PoolId id) internal view {
        Slot0 slot0 = _getPool(id).slot0;
        (uint160 pmSqrtPrice, int24 pmTick,,) = poolManager.getSlot0(id);

        require(slot0.sqrtPriceX96() == pmSqrtPrice && slot0.tick() == pmTick, "Not synced");
    }

    /**
     * @notice Synchronizes internal pool state with the Pool Manager
     * @dev Updates price, tick, fee, and fee growth data
     * @param id The pool ID to synchronize
     */
    function _syncPoolState(PoolId id) internal {
        Pool.State storage pool = _pools[id];

        (uint160 sqrtPrice,,, uint24 fee) = poolManager.getSlot0(id);
        (uint256 feeGrowth0, uint256 feeGrowth1) = poolManager.getFeeGrowthGlobals(id);

        pool.slot0 = _pools[id].slot0.setSqrtPriceX96(sqrtPrice).setTick(sqrtPrice.getTickAtSqrtPrice()).setLpFee(fee);
        pool.feeGrowthGlobal0X128 = feeGrowth0;
        pool.feeGrowthGlobal1X128 = feeGrowth1;
    }

    /**
     * @notice Initializes a new pool with the given parameters
     * @dev Sets up initial pool state and validates parameters
     * @param key The pool key containing currencies, fee, tick spacing, and hooks
     * @param sqrtPriceX96 The initial square root price (encoded as Q64.96)
     * @return tick The initial tick corresponding to the given price
     */
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) internal returns (int24 tick) {
        // Validate tick spacing bounds
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);

        // Validate currency ordering
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }

        uint24 lpFee = key.fee.getInitialLPFee();
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);

        // Initialize the pool and get the tick
        tick = pool.initialize(sqrtPriceX96, lpFee);
        refTick[id] = tick;

        // Emit initialization event with full pool details
        emit Initialize(
            id, key.currency0, key.currency1, key.fee, key.tickSpacing, address(key.hooks), sqrtPriceX96, tick
        );
    }

    /**
     * @notice Adds liquidity to a specific window range
     * @dev Only callable by the contract owner
     * @param key The pool key identifying the target pool
     * @param params Parameters specifying the range and amount of liquidity to add
     * @return positionId The unique identifier for the created position
     * @return principalDelta The change in token balances from the principal
     * @return feesAccrued The fees accrued to the position
     */
    function addLiquidity(PoolKey memory key, ModifyLiquidityWindow memory params)
        external
        payable
        onlyOwner
        returns (bytes32 positionId, BalanceDelta principalDelta, BalanceDelta feesAccrued)
    {
        require(params.rangeLower <= params.rangeUpper, "Invalid lower range");
        require(params.liquidityDelta >= 0, "Invalid liquidity");
        require(params.leverage >= 1000 && params.leverage <= getMaxLeverage(key), "Invalid leverage");

        int128 liquidity = params.liquidityDelta.mulLeverage(params.leverage).toInt128();

        // Calculate absolute tick positions based on active window
        Window memory activeWindow = getActiveWindows(key, true)[0];
        int24 tickLower = activeWindow.tickLower + (params.rangeLower * key.tickSpacing);
        int24 tickUpper = activeWindow.tickUpper + (params.rangeUpper * key.tickSpacing);

        // Execute the liquidity modification
        (positionId, principalDelta, feesAccrued) = _modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidity,
                salt: bytes32(0)
            }),
            params.liquidityDelta
        );

        // Update position information
        PositionInfo storage _info = positionInfo[key.toId()][positionId];
        positionInfo[key.toId()][positionId] = PositionInfo({
            owner: msg.sender,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: _info.liquidity + liquidity.toUint128()
        });

        // Enable tokens as collateral in Aave if needed
        if (principalDelta.amount0() < 0) {
            aavePool.setUserUseReserveAsCollateral(
                key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0), true
            );
        }
        if (principalDelta.amount1() < 0) {
            aavePool.setUserUseReserveAsCollateral(Currency.unwrap(key.currency1), true);
        }
    }

    /**
     * @notice Removes liquidity from a specific position
     * @dev Only callable by the position owner
     * @param key The pool key identifying the target pool
     * @param positionId The unique identifier of the position to modify
     * @param liquidity The amount of liquidity to remove (must be negative)
     * @return liquidityDelta The change in token balances from liquidity removal
     * @return feesAccrued The fees collected from the position
     */
    function removeLiquidity(PoolKey memory key, bytes32 positionId, int128 liquidity)
        external
        onlyOwner
        returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued)
    {
        require(liquidity <= 0, "Invalid liquidity");

        PositionInfo storage _info = positionInfo[key.toId()][positionId];

        // Execute the liquidity removal
        (, liquidityDelta, feesAccrued) = _modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: _info.tickLower,
                tickUpper: _info.tickUpper,
                liquidityDelta: liquidity,
                salt: bytes32(0)
            }),
            liquidity
        );

        // Update position liquidity tracking
        _info.liquidity -= (-liquidity).toUint128();
    }

    /**
     * @notice Internal function to modify liquidity in a position
     * @dev Core logic for adding/removing liquidity with proper accounting
     * @param key The pool key identifying the target pool
     * @param params The parameters for the liquidity modification
     * @return positionId The unique identifier for the position
     * @return principalDelta The change in token balances from the principal
     * @return feesAccrued The fees accrued to the position
     */
    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, int128 baseLiquidity)
        internal
        returns (bytes32 positionId, BalanceDelta principalDelta, BalanceDelta feesAccrued)
    {
        BalanceDelta callerDelta;
        {
            Pool.State storage pool = _getPool(key.toId());
            pool.checkPoolInitialized();

            // Execute the liquidity modification in the pool
            (principalDelta, feesAccrued) = pool.modifyLiquidity(
                Pool.ModifyLiquidityParams({
                    owner: msg.sender,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: params.liquidityDelta.toInt128(),
                    tickSpacing: key.tickSpacing,
                    salt: params.salt
                })
            );

            // Combine principal and fee deltas for the caller
            callerDelta = principalDelta + feesAccrued;
        }

        // Calculate position identifier
        positionId = Position.calculatePositionKey(msg.sender, params.tickLower, params.tickUpper, bytes32(0));

        // Handle token transfers and Aave interactions
        _resolveModifyLiquidity(
            key,
            callerDelta,
            Window(
                params.tickLower,
                params.tickUpper,
                baseLiquidity > 0 ? baseLiquidity.toUint128() : 0,
                baseLiquidity != params.liquidityDelta.toInt128()
            )
        );

        // Distribute liquidity across the specified windows
        _distributeLiquidityAcrossWindows(key, params.tickLower, params.tickUpper, params.liquidityDelta);

        // Emit event for tracking
        emit ModifyLiquidity(
            positionId, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt
        );
    }

    /**
     * @notice Distributes liquidity across multiple windows within a tick range
     * @dev Automatically initializes windows if they don't exist and distributes liquidity evenly
     * @param key The pool key identifying the target pool
     * @param tickLower The lower bound of the range
     * @param tickUpper The upper bound of the range
     * @param liquidityDelta The amount of liquidity to distribute (positive) or remove (negative)
     */
    function _distributeLiquidityAcrossWindows(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        // Calculate number of windows in the range
        uint256 nWindows = ((tickUpper - tickLower) / key.tickSpacing).toUint128();
        nWindows += 1;
        uint256 absDelta =
            liquidityDelta >= 0 ? liquidityDelta.toInt128().toUint128() : (-liquidityDelta).toInt128().toUint128();

        // Distribute liquidity across each window
        for (uint256 i = 0; i < nWindows; ++i) {
            int24 wLower = tickLower + int24(int256(i) * key.tickSpacing);

            // Initialize window if needed
            Window storage w = windows[key.toId()][wLower];
            if (!w.initilized) {
                w.tickLower = wLower;
                w.tickUpper = wLower + key.tickSpacing;
                w.liquidity = 0;
                w.initilized = true;
            }

            // Calculate liquidity assignment with even distribution and remainder handling
            uint128 assign = uint128((absDelta / nWindows) + (i < (absDelta % nWindows) ? 1 : 0));

            // Update window liquidity
            if (liquidityDelta >= 0) {
                unchecked {
                    w.liquidity += assign;
                }
            } else {
                require(w.liquidity >= assign, "window liquidity insufficient");
                unchecked {
                    w.liquidity -= assign;
                }
            }
        }
    }

    /**
     * @notice Resolves token settlements for liquidity modifications
     * @dev Handles token transfers, WETH wrapping/unwrapping, and Aave interactions
     * @param deltas The balance changes that need to be settled
     * @param key The pool key for the relevant pool
     */
    function _resolveModifyLiquidity(PoolKey memory key, BalanceDelta deltas, Window memory baseLiquidity) internal {
        int128 delta0 = deltas.amount0();
        int128 delta1 = deltas.amount1();
        address asset0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // Check available balances in Aave
        uint256 balance0 = aavePool.getATokenBalance(asset0, address(this));
        uint256 balance1 = aavePool.getATokenBalance(asset1, address(this));

        // Cap deltas to available balances if insufficient
        if ((int256(balance0) < delta0 && delta0 > 0) || (int256(balance1) < delta1 && delta1 > 0)) {
            deltas = toBalanceDelta(int128(int256(balance0)), int128(int256(balance1)));
        }

        if (!baseLiquidity.initilized) {
            if (delta0 < 0) {
                if (key.currency0.isAddressZero()) {
                    require(msg.value >= (-delta0).toUint128(), "Insufficient amount0");
                    WETH.deposit{value: (-delta0).toUint128()}();
                    payable(msg.sender).transfer(address(this).balance);
                } else {
                    IERC20(Currency.unwrap(key.currency0)).transferFrom(
                        msg.sender, address(this), (-delta0).toUint128()
                    );
                }
            }
            // Handle token1 requirements
            if (delta1 < 0) {
                IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), (-delta1).toUint128());
            }

            aavePool.modifyLiquidity(ModifyLiquidityAave(msg.sender, asset0, asset1, deltas));
        } else {
            _flash(key, deltas, baseLiquidity);
        }

        // Sweep any remaining tokens back to the caller
        _sweep(key);
    }

    function _flash(PoolKey memory key, BalanceDelta deltas, Window memory baseLiquidity) internal {
        bytes memory data = abi.encode(msg.sender, key, deltas, baseLiquidity);
        poolManager.unlock(data);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (address user, PoolKey memory key, BalanceDelta deltas, Window memory baseLiquidity) =
            abi.decode(data, (address, PoolKey, BalanceDelta, Window));

        address asset0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        int128 delta0 = -(deltas.amount0());
        int128 delta1 = -(deltas.amount1());

        Slot0 slot0 = _getPool(key.toId()).slot0;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            slot0.sqrtPriceX96(),
            baseLiquidity.tickLower.getSqrtPriceAtTick(),
            baseLiquidity.tickUpper.getSqrtPriceAtTick(),
            baseLiquidity.liquidity
        );

        if (delta0 > 0) {
            poolManager.take(key.currency0, address(this), delta0.toUint128());
        }
        if (delta1 > 0) {
            poolManager.take(key.currency1, address(this), delta1.toUint128());
        }

        aavePool.modifyLiquidity(ModifyLiquidityAave(address(this), asset0, asset1, deltas));

        _settle(key.currency0, user, amount0);
        _settle(key.currency1, user, amount1);

        delta0 = poolManager.currencyDelta(address(this), key.currency0).toInt128();
        delta1 = poolManager.currencyDelta(address(this), key.currency1).toInt128();

        if (delta0 < 0) {
            _borrow(asset0, (-delta0).toUint128());
            _settle(key.currency0, address(this), (-delta0).toUint128());
        }
        if (delta1 < 0) {
            _borrow(asset1, (-delta1).toUint128());
            _settle(key.currency1, address(this), (-delta1).toUint128());
        }

        return data;
    }

    function _settle(Currency currency, address from, uint256 amount) internal {
        if (currency.isAddressZero()) {
            if (address(this).balance < amount) {
                require(WETH.balanceOf(address(this)) >= amount, "Insufficient ETH");
                WETH.withdraw(amount);
            }
            poolManager.settle{value: amount}();
        } else {
            address token = Currency.unwrap(currency);
            poolManager.sync(currency);
            from == address(this)
                ? IERC20(token).transfer(address(poolManager), amount)
                : IERC20(token).transferFrom(from, address(poolManager), amount);
            poolManager.settle();
        }
    }

    /**
     * @notice Sweeps any remaining token balances back to the caller
     * @dev Safety mechanism to ensure no tokens are left in the contract
     * @param key The pool key to identify which tokens to sweep
     */
    function _sweep(PoolKey memory key) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        tokens[1] = Currency.unwrap(key.currency1);

        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0) {
                IERC20(tokens[i]).transfer(msg.sender, bal);
            }
        }
    }

    /**
     * @notice Resolves JIT position settlements with the Pool Manager
     * @dev Handles token settlements after JIT liquidity operations
     * @param key The pool key for the relevant pool
     */
    function _resolveJIT(PoolKey memory key) internal {
        // Get currency deltas from pool manager
        int128 delta0 = poolManager.currencyDelta(address(this), key.currency0).toInt128();
        int128 delta1 = poolManager.currencyDelta(address(this), key.currency1).toInt128();
        address asset0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // Take tokens from pool manager if owed to us
        if (delta0 > 0) {
            poolManager.take(key.currency0, address(this), delta0.toUint128());
        }
        if (delta1 > 0) {
            poolManager.take(key.currency1, address(this), delta1.toUint128());
        }

        // Process swap through Aave
        aavePool.swap(SwapParamsAave(asset0, asset1, toBalanceDelta(delta0, delta1)));

        // Settle any debts to the pool manager
        if (delta0 < 0) {
            _settle(key.currency0, address(this), (-delta0).toUint128());
        }
        if (delta1 < 0) {
            _settle(key.currency1, address(this), (-delta1).toUint128());
        }
    }

    /**
     * @notice Returns the swap fee for a given pool
     * @dev Virtual function that can be overridden for dynamic fee logic
     * @param key The pool key
     * @return The swap fee for the pool
     */
    function _swapFee(PoolKey memory key) internal virtual returns (uint24) {
        return key.fee;
    }

    /**
     * @notice Gets the pool state for a given pool ID
     * @dev Internal function required by the Pool library
     * @param id The pool ID
     * @return The pool state storage reference
     */
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /**
     * @notice Calculates the maximum leverage available for a pool
     * @dev Based on the minimum safe leverage between the two pool assets in Aave
     * @param key The pool key identifying the assets
     * @return maxLeverage The maximum leverage scaled by 1000 (e.g., 2500 = 2.5x leverage)
     */
    function getMaxLeverage(PoolKey memory key) public view returns (uint16 maxLeverage) {
        address asset0 = key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        uint256 l0 = aavePool.safeLeverage(asset0);
        uint256 l1 = aavePool.safeLeverage(asset1);

        // Select the more conservative (minimum) leverage
        uint256 minLeverage = l0 > l1 ? l1 : l0;

        // Convert from 1e18 scale to ×1000 scale
        maxLeverage = uint16((minLeverage * 1000) / 1e18);
    }

    /**
     * @notice Gets current position metrics from Aave
     * @dev Provides health factor, utilization, and other position data
     * @return Pool metrics including health factor and utilization rates
     */
    function getPositionData() public view returns (PoolMetrics memory) {
        return aavePool.getPoolMetrics();
    }

    /**
     * @notice Gets the current state of a specific pool
     * @dev Returns key pool state information including price, liquidity, and fees
     * @param id The pool ID to query
     * @return slot0 Current price and tick information
     * @return feeGrowthGlobal0X128 Accumulated fees for token0
     * @return feeGrowthGlobal1X128 Accumulated fees for token1
     * @return liquidity Current active liquidity in the pool
     */
    function getPoolState(PoolId id)
        public
        view
        returns (Slot0 slot0, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128, uint128 liquidity)
    {
        Pool.State storage pool = _pools[id];

        slot0 = pool.slot0;
        liquidity = pool.liquidity;
        feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
        feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;
    }

    /**
     * @notice Gets the two active windows for JIT liquidity operations
     * @dev Returns the current window and the adjacent window in the swap direction
     * @param key The pool key identifying the target pool
     * @param zeroForOne The swap direction (affects which adjacent window is selected)
     * @return _windows Array containing the active window [0] and adjacent window [1]
     */
    function getActiveWindows(PoolKey memory key, bool zeroForOne) public returns (Window[2] memory _windows) {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);

        // Return cached windows if already active
        if (ActiveLiquidityLibrary.isActive()) {
            (int24 w0, int24 w1) = ActiveLiquidityLibrary.getRefs();
            _windows[0] = windows[id][w0];
            _windows[1] = windows[id][w1];
            return (_windows);
        }

        // Calculate active window based on current tick
        int24 currentTick = pool.slot0.tick();
        int24 ref = refTick[id];

        int24 windowsFromRef = (currentTick - ref) / key.tickSpacing;
        if ((currentTick - ref) < 0 && (currentTick - ref) % key.tickSpacing != 0) {
            windowsFromRef -= 1;
        }
        int24 tickLower = ref + windowsFromRef * key.tickSpacing;

        // Initialize active window if needed
        Window storage activeWindow = windows[id][tickLower];
        if (!activeWindow.initilized) {
            activeWindow.tickLower = tickLower;
            activeWindow.tickUpper = tickLower + key.tickSpacing;
            activeWindow.liquidity = 0;
            activeWindow.initilized = true;
        }

        // Calculate neighbor window position based on swap direction
        int24 neighborLower = zeroForOne ? tickLower - key.tickSpacing : tickLower + key.tickSpacing;

        // Initialize neighbor window if needed
        Window storage nextWindow = windows[id][neighborLower];
        if (!nextWindow.initilized) {
            nextWindow.tickLower = neighborLower;
            nextWindow.tickUpper = neighborLower + key.tickSpacing;
            nextWindow.liquidity = 0;
            nextWindow.initilized = true;
        }

        _windows[0] = activeWindow;
        _windows[1] = nextWindow;
    }

    /**
     * @notice Borrows assets from Aave lending pool
     * @dev Only callable by contract owner, uses variable interest rate mode
     * @param asset The address of the asset to borrow
     * @param amount The amount to borrow
     */
    function borrow(address asset, uint256 amount) public onlyOwner {
        _borrow(asset, amount);
    }

    function _borrow(address asset, uint256 amount) internal {
        aavePool.borrow(asset, amount, 2, 0, address(this));
    }

    /**
     * @notice Repays borrowed assets to Aave lending pool
     * @dev Only callable by contract owner
     * @param asset The address of the asset to repay
     * @param amount The amount to repay
     * @param max Whether to repay the maximum possible amount
     */
    function repay(address asset, uint256 amount, bool max) public onlyOwner {
        _repay(asset, amount, max);
    }

    function _repay(address asset, uint256 amount, bool max) internal {
        aavePool.repay(asset, max ? type(uint256).max : amount, 2, address(this));
    }

    /**
     * @notice Repays debt using aTokens directly
     * @dev More gas efficient than withdrawing and repaying separately
     * @param asset The address of the underlying asset
     * @param amount The amount to repay with aTokens
     * @param max Whether to repay the maximum possible amount
     * @return The actual amount repaid
     */
    function repayWithATokens(address asset, uint256 amount, bool max) public onlyOwner returns (uint256) {
        return _repayWithATokens(asset, amount, max);
    }

    function _repayWithATokens(address asset, uint256 amount, bool max) internal returns (uint256) {
        return aavePool.repayWithATokens(asset, max ? type(uint256).max : amount, 2);
    }


    /**
     * @notice Handles ETH deposits and WETH wrapping
     * @dev Automatically wraps ETH to WETH unless sent from WETH contract
     */
    receive() external payable {
        if (msg.sender != address(WETH)) {
            WETH.deposit{value: msg.value}();
        }
    }
}
