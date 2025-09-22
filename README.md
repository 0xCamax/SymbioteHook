# SymbioteHook

A Uniswap V4 hook that integrates Aave lending protocol for capital-efficient liquidity provision through Just-In-Time (JIT) mechanisms.

## “No partner integrations”

## Overview

SymbioteHook enables liquidity providers to earn yield on their capital while it's not actively being used for swaps by storing idle liquidity in Aave instead of the Uniswap pool manager. The hook provides JIT liquidity during swaps and allows users to borrow against their deposited liquidity.

## Key Features

- **Aave Integration**: Stores idle liquidity in Aave to earn lending yield
- **JIT Liquidity**: Automatically provides liquidity just before swaps and removes it afterward
- **Borrowing Capability**: Allows users to borrow against their deposited liquidity positions
- **Capital Efficiency**: Maximizes capital utilization through dual yield sources
- **Slippage Protection**: Built-in slippage checks to protect JIT operations

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Uniswap V4    │    │  SymbioteHook   │    │   Aave Pool     │
│   Pool Manager  │◄──►│   (JIT Logic)   │◄──►│   (Lending)     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌─────────────────┐
                       │ Active Liquidity │
                       │    Library      │
                       └─────────────────┘
```

## Core Components

### SymbioteHook

The main hook contract that inherits from `BaseHook` and `JITPoolManager`. Manages the lifecycle of JIT liquidity operations.

### JITPoolManager

Abstract contract handling:

- Position management with leverage multipliers
- Aave lending/borrowing integration
- Granular liquidity distribution
- Flash loan-like operations for capital efficiency

### ActiveLiquidityLibrary

Bytecode-optimized library for tracking active liquidity state in transient storage.

## How It Works

### 1. Liquidity Provision

Users provide liquidity through the hook with optional leverage multipliers:

```solidity
function modifyLiquidity(
    PoolKey memory key,
    ModifyLiquidityParams memory params,
    uint16 multiplier
) external payable
```

- Liquidity is distributed across windows (tick ranges)
- Base liquidity is deposited into Aave for yield
- Leveraged positions can borrow additional capital from Aave

### 2. JIT Operation Flow

**Before Swap (`beforeSwap`)**:

1. Hook detects incoming swap
2. Calculates required liquidity windows
3. Temporarily adds JIT liquidity to the pool
4. Stores active liquidity reference in transient storage

**After Swap (`afterSwap`)**:

1. Verifies slippage protection conditions
2. Removes JIT liquidity from the pool
3. Settles any token imbalances through Aave
4. Returns excess tokens to Aave for yield

### 3. Window Management

Liquidity is organized in "windows" - specific tick ranges where liquidity is concentrated:

```solidity
struct Window {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bool initialized;
}
```

The JIT algorithm selects appropriate windows based on:

- Current price/tick position
- Swap direction (`zeroForOne`)
- Available liquidity in adjacent windows

## Position Management

### Creating Positions

```solidity
// Create a 2x liquidity position
modifyLiquidity(poolKey, params, 2);
```

## Aave Integration

### Lending Operations

- Deposits idle liquidity to earn yield
- Automatically compounds through Aave's aToken mechanism

### Borrowing Operations

```solidity
// Borrow against deposited collateral
borrow(asset, amount);

// Repay with underlying tokens
repay(asset, amount, maxRepay);

// Repay directly with aTokens
repayWithATokens(asset, amount, maxRepay);
```

### Health Factor Monitoring

```solidity
// Get current position metrics
PoolMetrics memory metrics = getPositionData();
```

## Security Features

### Access Control

- `auth` modifier restricts critical functions to owner or contract
- Hook restrictions prevent external liquidity additions

### Slippage Protection

```solidity
// Ensures JIT operations don't execute with excessive slippage
if (params.zeroForOne) {
    require(tickLower < tick, "Slippage");
} else {
    require(tickUpper > tick, "Slippage");
}
```

## Usage Example

```solidity
// 1. Deploy the hook
SymbioteHook hook = new SymbioteHook(
    owner,
    poolManager,
    weth,
    aavePool
);

// 2. Initialize a pool with the hook
PoolKey memory key = PoolKey({
    currency0: token0,
    currency1: token1,
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

// 3. Provide liquidity with 2x leverage
hook.modifyLiquidity{value: ethAmount}(
    key,
    ModifyLiquidityParams({
        tickLower: -600,
        tickUpper: 600,
        liquidityDelta: 1000e18,
        salt: bytes32(0)
    }),
    2  // 2x multiplier
);

// 4. Swaps automatically trigger JIT liquidity
// Users can also borrow against their positions
hook.borrow(address(token0), borrowAmount);
```

## Risk Considerations

### Liquidation Risk

- Leveraged positions can be liquidated if health factor drops below threshold
- Monitor Aave health factor regularly

### Smart Contract Risk

- Dependent on Aave protocol security
- Uniswap V4 hook system risks

### Impermanent Loss

- Concentrated liquidity positions subject to impermanent loss
- Amplified by leverage multipliers

## Dependencies

- **Uniswap V4**: Core AMM functionality
- **Aave V3**: Lending and borrowing protocol
- **OpenZeppelin**: ERC20 token standards
- **Solmate**: Gas-optimized contract utilities

## License

MIT License - See LICENSE file for details.

## Disclaimer

This is experimental DeFi infrastructure. Use at your own risk. Ensure thorough testing and auditing before mainnet deployment.
