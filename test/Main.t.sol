// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

// Import your contracts (adjust paths as needed)
import "../src/SymbioteHook.sol";
import {PoolMetrics} from "../src/libraries/AaveHelper.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AbritrumConstants} from "../src/contracts/Constants.sol";
import {HookDeployer} from "../src/contracts/HookDeployer.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Commands} from "../src/libraries/Commands.sol";

/**
 * @title SymbioteHookTests
 * @notice Comprehensive test suite for the cXc Hook implementation
 * @dev Tests cover deployment, initialization, liquidity management, and swap functionality
 */
contract SymbioteHookTests is Test, AbritrumConstants {
    using StateLibrary for IPoolManager;
    using TickMath for int24;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Well-funded account on Arbitrum for testing
    address public constant WHALE = 0x0a8494F70031623C9C0043aff4D40f334b458b11;

    // Test liquidity amount
    int128 private constant LIQUIDITY_TO_ADD = 100_000_000_000_000_000;

    // Default fee for testing (0.3%)
    uint24 private constant DEFAULT_FEE = 3000;

    // Tick spacing for the test pool
    int24 private constant TICK_SPACING = 50;

    // Default swap amount
    uint128 private constant SWAP_AMOUNT = 1_000_000_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    SymbioteHook public hook;
    PoolKey public poolKey;
    PoolKey public basePoolKey;
    PoolId public poolId;

    address public testAccount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPrice);
    event LiquidityAdded(bytes32 indexed positionId, int128 liquidity);
    event LiquidityRemoved(bytes32 indexed positionId, int128 liquidity);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier validPool() {
        vm.assume(Currency.unwrap(poolKey.currency0) != Currency.unwrap(poolKey.currency1));
        vm.assume(poolKey.fee > 0);
        vm.assume(address(poolKey.hooks) != address(0));
        _;
    }

    modifier poolInitialized() {
        _initializePool();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Create Arbitrum mainnet fork
        vm.createSelectFork("arbitrum");

        testAccount = address(this);

        // Fund the test account with ETH
        vm.deal(testAccount, 1000 ether);

        // Transfer USDC from whale using safe approach
        vm.startPrank(WHALE);
        uint256 usdcAmount = 10_000_000 * 1e6;
        require(USDC.balanceOf(WHALE) >= usdcAmount, "Whale has insufficient USDC");
        USDC.transfer(testAccount, usdcAmount);
        vm.stopPrank();

        // Deploy hook with proper flag validation
        _deployHook();

        // Configure pool keys
        _configurePoolKeys();

        // Set up approvals
        _setupApprovals();

        // Validate initial state
        _validateSetup();
    }

    /*//////////////////////////////////////////////////////////////
                           DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HookDeployment_Success() public view {
        // Verify hook is deployed
        assertNotEq(address(hook), address(0), "Hook should be deployed");

        (
            bool beforeInitialize,
            bool afterInitialize,
            bool beforeAddLiquidity,
            bool afterAddLiquidity,
            bool beforeRemoveLiquidity,
            bool afterRemoveLiquidity,
            bool beforeSwap,
            bool afterSwap,
            bool beforeDonate,
            bool afterDonate,
            bool beforeSwapReturnDelta,
            bool afterSwapReturnDelta,
            bool afterAddLiquidityReturnDelta,
            bool afterRemoveLiquidityReturnDelta
        ) = HOOK_DEPLOYER.getPermissions(address(hook));

        console2.log("Hook Permissions:");
        console2.log("  beforeInitialize:", beforeInitialize);
        console2.log("  afterInitialize:", afterInitialize);
        console2.log("  beforeAddLiquidity:", beforeAddLiquidity);
        console2.log("  afterAddLiquidity:", afterAddLiquidity);
        console2.log("  beforeRemoveLiquidity:", beforeRemoveLiquidity);
        console2.log("  afterRemoveLiquidity:", afterRemoveLiquidity);
        console2.log("  beforeSwap:", beforeSwap);
        console2.log("  afterSwap:", afterSwap);
        console2.log("  beforeDonate:", beforeDonate);
        console2.log("  afterDonate:", afterDonate);
        console2.log("  beforeSwapReturnDelta:", beforeSwapReturnDelta);
        console2.log("  afterSwapReturnDelta:", afterSwapReturnDelta);
        console2.log("  afterAddLiquidityReturnDelta:", afterAddLiquidityReturnDelta);
        console2.log("  afterRemoveLiquidityReturnDelta:", afterRemoveLiquidityReturnDelta);

        console2.log(" Hook deployed at:", address(hook));
    }

    /*//////////////////////////////////////////////////////////////
                         INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PoolInitialization_Success() public {
        (, int24 baseTick,,) = POOL_MANAGER.getSlot0(basePoolKey.toId());
        uint160 sqrtPrice = (baseTick - (baseTick % poolKey.tickSpacing)).getSqrtPriceAtTick();

        hook.initialize(poolKey, sqrtPrice);

        // Verify pool state
        (uint160 actualSqrtPrice, int24 tick,,) = POOL_MANAGER.getSlot0(poolId);
        assertEq(actualSqrtPrice, sqrtPrice, "Price mismatch");

        console2.log(" Pool initialized with sqrt price:", sqrtPrice);
        console2.log(" Current tick:", tick);
    }

    /*//////////////////////////////////////////////////////////////
                       LIQUIDITY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddLiquidity_Success() public poolInitialized {
        uint256 ethBalanceBefore = testAccount.balance;
        uint256 usdcBalanceBefore = USDC.balanceOf(testAccount);

        (bytes32 positionId, BalanceDelta feesAccrued, int24 tickLower, int24 tickUpper) =
            _addLiquidity(LIQUIDITY_TO_ADD, 1);

        // Verify position was created
        assertNotEq(positionId, bytes32(0), "Position ID should be generated");

        // Verify fees are initially zero
        assertEq(feesAccrued.amount0(), 0, "Initial fees should be zero");
        assertEq(feesAccrued.amount1(), 0, "Initial fees should be zero");

        // Verify liquidity was added
        (,,, uint128 liquidity) = hook.getPoolState(poolKey.toId());
        assertGt(liquidity, 0, "Liquidity mismatch");

        // Verify balances changed appropriately
        assertLt(testAccount.balance, ethBalanceBefore, "ETH balance should decrease");
        assertLt(USDC.balanceOf(testAccount), usdcBalanceBefore, "USDC balance should decrease");

        // Verify pool metrics
        PoolMetrics memory metrics = hook.getPositionData();
        assertGt(metrics.totalCollateral, 0, "Should have collateral");

        console2.log(" Position created with ID:", vm.toString(positionId));
        console2.log(" Active liquidity:", liquidity);
        console2.log(" Tick range:", tickLower);
        console2.log(" to:", tickUpper);

        _logPoolMetrics(metrics);
    }

    function test_Borrow_Success() public poolInitialized {
        _addLiquidity(LIQUIDITY_TO_ADD, 1);

        hook.borrow(address(USDC), 100 * 1e6);

        // Verify pool metrics
        PoolMetrics memory metrics = hook.getPositionData();
        assertGt(metrics.totalCollateral, 0, "Should have collateral");

        _logPoolMetrics(metrics);
    }

    function test_BorrowRepay_Success() public poolInitialized {
        _addLiquidity(LIQUIDITY_TO_ADD, 1);

        hook.borrow(address(USDC), 100 * 1e6);

        hook.repayWithATokens(address(USDC), 0, true);

        PoolMetrics memory metrics = hook.getPositionData();
        assertGt(metrics.totalCollateral, 0, "Should have collateral");
        _logPoolMetrics(metrics);
    }

    function test_AddLeverageLiquidity_Success() public poolInitialized {
        // snapshots before
        uint256 ethBefore = testAccount.balance;
        uint256 usdcBefore = USDC.balanceOf(testAccount);

        USDC.approve(address(hook), type(uint256).max);

        // execute liquidity addition (returns tick range)
        (bytes32 positionId, BalanceDelta feesAccrued, int24 tickLower, int24 tickUpper) =
            _addLiquidity(LIQUIDITY_TO_ADD, 4);

        uint128 leveragedLiquidity = uint128(LIQUIDITY_TO_ADD) * 4;

        //  total required amounts for leveraged liquidity
        BalanceDelta amounts =
            hook.getAmountsForLiquidity(poolKey.toId(), Window(tickLower, tickUpper, leveragedLiquidity, false));

        uint256 required0 = uint128(amounts.amount0());
        uint256 required1 = uint128(amounts.amount1());

        //  amounts actually paid by user
        uint256 ethPaidByUser = ethBefore - testAccount.balance; // NOTE: includes gas noise
        uint256 usdcPaidByUser = usdcBefore - USDC.balanceOf(testAccount);

        //  infer leveraged portion (not covered by user)
        uint256 ethLeverageInferred = required0 > ethPaidByUser ? required0 - ethPaidByUser : 0;
        uint256 usdcLeverageInferred = required1 > usdcPaidByUser ? required1 - usdcPaidByUser : 0;

        console2.log("=== Liquidity & Payment Summary ===");
        console2.log("Required total token0:", required0);
        console2.log("Required total token1:", required1);
        console2.log("User paid token0 (ETH):", ethPaidByUser);
        console2.log("User paid token1 (USDC):", usdcPaidByUser);
        console2.log("Inferred leverage token0:", ethLeverageInferred);
        console2.log("Inferred leverage token1:", usdcLeverageInferred);

        PoolMetrics memory metrics = hook.getPositionData();
        _logPoolMetrics(metrics);

        assertNotEq(positionId, bytes32(0), "Position should be created");
        assertEq(feesAccrued.amount0(), 0, "Initial fees token0 should be zero");
        assertEq(feesAccrued.amount1(), 0, "Initial fees token1 should be zero");
        assertGt(usdcPaidByUser + usdcLeverageInferred, 0, "No USDC contribution detected");
    }

    function test_AddRemoveLeverage_Success() public poolInitialized {
        // execute liquidity addition (returns tick range)
        (,, int24 tickLower, int24 tickUpper) = _addLiquidity(LIQUIDITY_TO_ADD, 4);

        _removeLiquidity(poolKey, ModifyLiquidityParams(tickLower, tickUpper, -LIQUIDITY_TO_ADD , bytes32(abi.encode(4))));
    }

    function test_RemoveLiquidity_Success() public poolInitialized {
        // First add liquidity
        (,, int24 tickLower, int24 tickUpper) = _addLiquidity(LIQUIDITY_TO_ADD, 1);

        uint256 ethBalanceBefore = testAccount.balance;

        // Remove liquidity
        (BalanceDelta liquidityDelta,) =
            _removeLiquidity(poolKey, ModifyLiquidityParams(tickLower, tickUpper, -LIQUIDITY_TO_ADD, bytes32(abi.encode(1))));

        // Verify liquidity was removed
        assertGt(liquidityDelta.amount0(), 0, "Should return ETH");

        WETH.withdraw(uint128(liquidityDelta.amount0()));

        // Verify we got our ETH back
        assertGt(testAccount.balance, ethBalanceBefore, "ETH balance should increase");

        console2.log(" Liquidity removed successfully");
        console2.log(" ETH returned:", uint256(uint128(liquidityDelta.amount0())));
        console2.log(" USDC returned:", uint256(uint128(liquidityDelta.amount1())));
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY RESTRICTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BeforeAddLiquidity_RevertWhen_DirectPositionManagerCall() public poolInitialized {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](3);
        Currency currency0 = Currency.wrap(address(0));
        Currency currency1 = Currency.wrap(address(USDC));
        Window memory activeWindow = hook.getActiveWindow(poolKey.toId());

        params[0] = abi.encode(
            poolKey,
            activeWindow.tickLower,
            activeWindow.tickUpper,
            100_000_000_000,
            type(uint256).max,
            type(uint256).max,
            address(this),
            ""
        );

        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(address(0), address(this));

        uint256 deadline = block.timestamp + 60;
        uint256 valueToPass = currency0.isAddressZero() ? 1 ether : 0;

        vm.expectRevert();
        POSITION_MANAGER.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), deadline);

        console2.log(" Direct position manager call correctly reverted");
    }

    /*//////////////////////////////////////////////////////////////
                              SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapWithJITLiquidity_Success() public poolInitialized {
        // Add liquidity first
        (,, int24 tickLower, int24 tickUpper) = _addLiquidity(LIQUIDITY_TO_ADD, 1);

        uint256 ethBalanceBefore = testAccount.balance;

        // Perform swap
        vm.deal(address(this), 1 ether);
        _swap(SWAP_AMOUNT, true); // ETH -> USDC

        // Verify swap occurred
        assertLt(testAccount.balance, ethBalanceBefore, "ETH balance should decrease after swap");

        // Verify pool state after swap
        (, uint256 fees0, uint256 fees1,) = hook.getPoolState(poolKey.toId());

        // Calculate expected amounts
        BalanceDelta amounts =
            hook.getAmountsForLiquidity(poolKey.toId(), Window(tickLower, tickUpper, uint128(LIQUIDITY_TO_ADD), true));

        // Verify fees were generated
        assertTrue(fees0 > 0 || fees1 > 0, "Fees should be generated from swap");

        PoolMetrics memory metrics = hook.getPositionData();
        _logPoolMetrics(metrics);

        console2.log(" Swap executed successfully");
        console2.log(" Amount0 in position:", amounts.amount0());
        console2.log(" Amount1 in position:", amounts.amount1());
    }

    /*//////////////////////////////////////////////////////////////
                       INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_AddSwapRemove_Success() public poolInitialized {
        // Record initial balances
        uint256 initialETH = testAccount.balance;
        uint256 initialUSDC = USDC.balanceOf(testAccount);

        console2.log("=== INITIAL STATE ===");
        console2.log("ETH balance:", initialETH);
        console2.log("USDC balance:", initialUSDC);

        // Add liquidity
        (,, int24 tickLower, int24 tickUpper) = _addLiquidity(LIQUIDITY_TO_ADD, 1);

        uint256 afterAddETH = testAccount.balance;
        uint256 afterAddUSDC = USDC.balanceOf(testAccount);

        console2.log("=== AFTER ADD LIQUIDITY ===");
        console2.log("ETH balance:", afterAddETH);
        console2.log("USDC balance:", afterAddUSDC);
        console2.log("ETH used:", initialETH - afterAddETH);
        console2.log("USDC used:", initialUSDC - afterAddUSDC);

        // Execute multiple swaps to generate fees
        vm.startPrank(WHALE);
        PERMIT2.approve(
            Currency.unwrap(poolKey.currency1), address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 days)
        );
        USDC.approve(address(PERMIT2), type(uint256).max);

        // Perform alternating swaps
        for (uint8 i = 0; i < 100; i++) {
            if (i % 2 == 0) {
                _swap(SWAP_AMOUNT * 10, true); // ETH -> USDC
            } else {
                _swap(1_000_000, false); // USDC -> ETH
            }
        }
        vm.stopPrank();

        console2.log("=== AFTER SWAPS ===");
        PoolMetrics memory metricsAfterSwaps = hook.getPositionData();
        _logPoolMetrics(metricsAfterSwaps);

        // Remove liquidity
        (BalanceDelta liquidityDelta,) =
            _removeLiquidity(poolKey, ModifyLiquidityParams(tickLower, tickUpper, -LIQUIDITY_TO_ADD, bytes32(abi.encode(1))));

        uint256 finalETH = testAccount.balance + IERC20(address(WETH)).balanceOf(address(this));
        uint256 finalUSDC = USDC.balanceOf(testAccount);

        console2.log("=== FINAL STATE ===");
        console2.log("ETH balance:", finalETH);
        console2.log("USDC balance:", finalUSDC);
        console2.log("Net ETH change:", int256(finalETH) - int256(initialETH));
        console2.log("Net USDC change:", int256(finalUSDC) - int256(initialUSDC));
        console2.log("Liquidity delta ETH:", liquidityDelta.amount0());
        console2.log("Liquidity delta USDC:", liquidityDelta.amount1());

        // Hook should not retain significant balances
        uint256 hookETHBalance = address(hook).balance + IERC20(address(WETH)).balanceOf(address(hook));
        uint256 hookUSDCBalance = USDC.balanceOf(address(hook));

        console2.log("=== HOOK BALANCES ===");
        console2.log("Hook ETH balance:", hookETHBalance);
        console2.log("Hook USDC balance:", hookUSDCBalance);

        assertLt(hookETHBalance, 0.01 ether, "Hook ETH balance too high");
        assertLt(hookUSDCBalance, 1000, "Hook USDC balance too high");
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _deployHook() private {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

        uint160[] memory _flags = new uint160[](3);
        _flags[0] = Hooks.BEFORE_SWAP_FLAG;
        _flags[1] = Hooks.AFTER_SWAP_FLAG;
        _flags[2] = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

        bytes memory constructorArgs = abi.encode(address(this), POOL_MANAGER, WETH, AAVE_POOL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(HOOK_DEPLOYER), flags, type(SymbioteHook).creationCode, constructorArgs);

        hook = SymbioteHook(
            payable(
                HOOK_DEPLOYER.safeDeploy(type(SymbioteHook).creationCode, constructorArgs, salt, hookAddress, _flags)
            )
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function _configurePoolKeys() private {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(USDC)),
            fee: DEFAULT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        basePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(USDC)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        poolId = poolKey.toId();
    }

    function _setupApprovals() private {
        USDC.approve(address(hook), type(uint256).max);
        USDC.approve(address(PERMIT2), type(uint256).max);
    }

    function _validateSetup() private view {
        require(testAccount.balance > 100 ether, "Insufficient ETH for testing");
        require(USDC.balanceOf(testAccount) > 1_000_000 * 1e6, "Insufficient USDC for testing");
        require(address(hook) != address(0), "Hook not deployed");
    }

    function _initializePool() private {
        (, int24 baseTick,,) = POOL_MANAGER.getSlot0(basePoolKey.toId());
        uint160 sqrtPrice = (baseTick - (baseTick % poolKey.tickSpacing)).getSqrtPriceAtTick();
        hook.initialize(poolKey, sqrtPrice);
    }

    function _addLiquidity(int128 liquidity, uint16 multiplier)
        private
        returns (bytes32 positionId, BalanceDelta feesAccrued, int24 tickLower, int24 tickUpper)
    {
        Window memory activeWindow = hook.getActiveWindow(poolKey.toId());

        int128 baseLiquidity = liquidity;
        tickLower = activeWindow.tickLower - (poolKey.tickSpacing * 2);
        tickUpper = activeWindow.tickUpper + (poolKey.tickSpacing * 2);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: baseLiquidity,
            salt: bytes32(abi.encode(multiplier))
        });

        BalanceDelta amounts = hook.getAmountsForLiquidity(
            poolKey.toId(), Window(params.tickLower, params.tickUpper, uint128(int128(params.liquidityDelta)), false)
        );
        uint256 ethAmount = uint128(amounts.amount0());
        require(ethAmount <= address(this).balance, "Insufficient ETH for liquidity");

        (positionId,, feesAccrued) = hook.modifyLiquidity{value: ethAmount}(poolKey, params);
    }

    function _removeLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        private
        returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued)
    {
        (, liquidityDelta, feesAccrued) = hook.modifyLiquidity(key, params);
    }

    function _swap(uint128 amountIn, bool zeroForOne) private {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );

        params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 deadline = block.timestamp + 60;

        if (!zeroForOne) {
            PERMIT2.approve(
                Currency.unwrap(poolKey.currency1), address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 days)
            );
        }

        ROUTER.execute{value: zeroForOne ? amountIn : 0}(commands, inputs, deadline);
    }

    function _logPoolMetrics(PoolMetrics memory metrics) private pure {
        console2.log("--- Pool Metrics ---");
        console2.log("Total collateral (ETH):", metrics.totalCollateral);
        console2.log("Total debt (ETH):", metrics.totalDebt);
        console2.log("Available borrows (ETH):", metrics.availableBorrows);
        console2.log("Liquidation threshold:", metrics.currentLiquidationThreshold);
        console2.log("LTV:", metrics.ltv);
        console2.log("Health factor:", metrics.healthFactor);
        console2.log("-------------------");
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        // Allow contract to receive ETH
    }
}
