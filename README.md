# JIT Pool Manager

A sophisticated Just-In-Time (JIT) liquidity management system built on Uniswap V4 with integrated Aave lending protocol support for leveraged liquidity provision.

## Overview

The JIT Pool Manager enables automated liquidity provision with leverage through a window-based system that optimally distributes capital across price ranges. By integrating with Aave's lending protocol, liquidity providers can achieve leveraged positions while maintaining efficient capital utilization.

## Key Features

### 🚀 **Just-In-Time Liquidity**

- Automated liquidity provision based on current market conditions
- Window-based distribution system for optimal capital allocation
- Real-time synchronization with Uniswap V4 pool states

### 💰 **Leveraged Positions**

- Integration with Aave lending protocol for borrowing capacity
- Dynamic leverage calculation based on asset safety parameters
- Automated collateral management and position health monitoring

### 🎯 **Window-Based Management**

- Intelligent liquidity distribution across price ranges
- Automatic window initialization and liquidity rebalancing
- Efficient capital deployment through active window targeting

### 🔄 **Advanced Settlement**

- Flash loan integration for capital-efficient operations
- Automated token wrapping/unwrapping (ETH ↔ WETH)
- Comprehensive token sweeping and settlement mechanisms

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   JIT Pool      │    │   Uniswap V4    │    │   Aave Lending  │
│   Manager       │◄──►│   Pool Manager  │    │   Pool          │
│                 │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         ├─ Window Management    ├─ Price Discovery      ├─ Lending/Borrowing
         ├─ Liquidity Distribution├─ Swap Execution      ├─ Collateral Management
         └─ Position Tracking    └─ Fee Collection       └─ Health Factor Monitoring
```

## Core Components

### Windows

- **Purpose**: Discrete price ranges for liquidity distribution
- **Structure**: Each window spans one tick spacing and contains liquidity amount
- **Management**: Automatic initialization and liquidity balancing

### Positions

- **Tracking**: Comprehensive position information including owner, range, and liquidity
- **Leverage**: Dynamic leverage calculation with safety limits
- **Fees**: Automatic fee collection and distribution

### Aave Integration

- **Borrowing**: Automated borrowing against deposited collateral
- **Repayment**: Flexible repayment options including aToken direct repayment
- **Health Monitoring**: Real-time position health and leverage monitoring

### JIT Operations

```solidity
// Execute JIT liquidity for incoming swap
function beforeSwap(
    address,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata
) external returns (bytes4, BeforeSwapDelta, uint24) {
    // Add JIT liquidity
    _jitModifyLiquidity(key, params.zeroForOne, true);

    return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}

function afterSwap(
    address,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    BalanceDelta,
    bytes calldata
) external returns (bytes4, int128) {
    // Remove JIT liquidity
    _jitModifyLiquidity(key, params.zeroForOne, false);

    return (this.afterSwap.selector, 0);
}
```

## Advanced Features

### Dynamic Leverage Calculation

The system automatically calculates maximum safe leverage based on Aave's risk parameters:

```solidity
function getMaxLeverage(PoolKey memory key) public view returns (uint16) {
    // Returns leverage scaled by 1000 (2500 = 2.5x)
    // Based on minimum safe leverage of both assets
}
```

### Window Management

Active windows are determined based on current price and swap direction:

```solidity
function getActiveWindows(PoolKey memory key, bool zeroForOne)
    public returns (Window[2] memory) {
    // Returns current active window and adjacent window
    // Automatically initializes windows if needed
}
```

### Health Monitoring

```solidity
function getPositionData() public view returns (PoolMetrics memory) {
    // Returns comprehensive position health data
    // Including health factor, utilization rates, etc.
}
```

## Security Considerations

### Access Control

- Only contract owner can add/remove liquidity
- Position-specific access control for modifications
- Protected Aave interactions

### Smart Settlements

- Direct aToken repayments when possible
- Efficient token sweeping mechanisms

### Validation

- Comprehensive parameter validation
- Pool state synchronization checks
- Leverage limit enforcement

## Disclaimer

This is experimental software. Use at your own risk. Always conduct thorough testing and audits before deploying to mainnet.

---

_Built with ❤️ for the DeFi ecosystem_
