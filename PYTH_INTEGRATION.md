# Pyth Network Oracle Integration

This document describes the Pyth Network oracle integration for Citadel Finance protocol.

## Overview

The Pyth Network integration provides real-time, high-frequency price feeds for the Citadel Finance synthetic stablecoin protocol. Pyth offers sub-second price updates with confidence intervals, making it ideal for DeFi applications requiring precise and timely price data.

## Architecture

### Core Components

1. **SynthereumPythPriceFeed** (`src/oracle/implementations/PythPriceFeed.sol`)
   - Main implementation contract that integrates with Pyth Network
   - Extends `SynthereumPriceFeedImplementation` base contract
   - Handles price feed configuration and retrieval

2. **Deployment Script** (`script/deployments/03_deploy_pyth_priceFeed.s.sol`)
   - Deploys and configures Pyth oracle integration
   - Sets up common price pairs (EUR/USD, BTC/USD, ETH/USD)

3. **Test Suite** (`test/PythPriceFeedTest.t.sol`)
   - Comprehensive tests for all Pyth integration functionality
   - Uses MockPyth for isolated testing

## Key Features

### 1. Real-time Price Updates
- Sub-second price updates from Pyth Network
- Automatic price staleness checks (60-second maximum age)
- On-chain price update mechanism with fee payment

### 2. Dynamic Spread Calculation
- Confidence interval-based spread calculation
- Fallback to static spread configuration
- Maximum 5% spread cap for safety

### 3. Multiple Price Types
- **Normal**: Direct price from Pyth (e.g., EUR/USD)
- **Reverse**: Inverted price calculation (e.g., USD/EUR from EUR/USD)
- **Conversion Units**: Custom unit conversions (e.g., troy ounce to grams)

### 4. Emergency Controls
- Admin-only emergency ETH withdrawal
- Maintainer role for price feed configuration
- Integrated access control from base contracts

## Deployment Guide

### Prerequisites

1. Pyth Network contract address for your target network:
   - **Ethereum Mainnet**: `0x4305FB66699C3B2702D4d05CF36551390A4c69C6`
   - **BSC Mainnet**: `0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594`
   - **BSC Testnet**: `0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb`

2. Deployed SynthereumFinder and SynthereumPriceFeed contracts

### Step 1: Deploy Pyth Integration

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export RPC_URL=your_rpc_url

# Deploy Pyth price feed
forge script script/deployments/03_deploy_pyth_priceFeed.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### Step 2: Configure Price Pairs

The deployment script automatically configures these pairs:
- **EUR/USD**: `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b`
- **BTC/USD**: `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`
- **ETH/USD**: `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`

## Usage Examples

### 1. Getting Price Data

```solidity
// Get latest EUR/USD price
uint256 price = priceFeed.getLatestPrice("EURUSD");

// Get multiple prices at once
string[] memory identifiers = new string[](2);
identifiers[0] = "EURUSD";
identifiers[1] = "BTCUSD";
uint256[] memory prices = priceFeed.getLatestPrices(identifiers);
```

### 2. Updating Price Feeds

```solidity
// Get price update data from Pyth API
bytes[] memory priceUpdates = getPriceUpdatesFromAPI();

// Calculate required fee
uint256 fee = pythPriceFeed.getUpdateFee(priceUpdates);

// Update prices
pythPriceFeed.updatePriceFeeds{value: fee}(priceUpdates);
```

### 3. Adding New Price Pairs

```solidity
// Add new price pair (maintainer only)
pythPriceFeed.setPair(
    "GBPUSD", // Price identifier
    SynthereumPriceFeedImplementation.Type.NORMAL, // Normal type
    pythContractAddress, // Pyth contract address
    0, // No conversion unit
    abi.encode(gbpUsdPythId), // Pyth price feed ID
    0 // Dynamic spread
);

// Register in main price feed
string[] memory emptyArray;
priceFeed.setPair(
    "GBPUSD",
    SynthereumPriceFeed.Type.STANDARD,
    "pyth",
    emptyArray
);
```

## Price Feed IDs

Pyth Network uses fixed price feed IDs for each trading pair. Here are commonly used IDs:

### Major Forex Pairs
- **EUR/USD**: `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b`
- **GBP/USD**: `0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1`
- **USD/JPY**: `0xef2c98c804ba503c6a707e38be4dfbb1efa5b1b7f2a1a72412cee6609ac6e2f2`

### Major Cryptocurrencies  
- **BTC/USD**: `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`
- **ETH/USD**: `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`
- **SOL/USD**: `0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d`

Complete list available at: https://pyth.network/developers/price-feed-ids

## Testing

Run the comprehensive test suite:

```bash
# Run all Pyth integration tests
forge test --match-contract PythPriceFeedTest

# Run specific test
forge test --match-test testGetLatestPrice

# Run tests with gas reporting
forge test --match-contract PythPriceFeedTest --gas-report
```

## Security Considerations

### 1. Price Update Fees
- Pyth requires ETH payment for price updates
- Contract can receive ETH for fee payments
- Emergency withdrawal function for admin

### 2. Price Staleness
- Maximum 60-second price age enforced
- Automatic reversion for stale prices
- Confidence interval monitoring

### 3. Access Control
- Admin role for emergency functions
- Maintainer role for configuration
- On-chain validation of all parameters

### 4. Price Validation
- Negative price rejection
- Confidence interval bounds checking
- Maximum spread limitations (5% cap)

## Integration with Citadel Finance

The Pyth oracle integrates seamlessly with Citadel Finance's existing price feed infrastructure:

1. **Multi-LP Pools**: Price feeds are consumed by liquidity pools for accurate EUR synthetic creation
2. **Risk Management**: Confidence intervals provide additional risk assessment data
3. **Cross-Oracle Support**: Can be used alongside Chainlink for price validation
4. **Real-time Updates**: Sub-second updates enable responsive pool management

## Troubleshooting

### Common Issues

1. **"Insufficient fee for price update"**
   - Solution: Call `getUpdateFee()` before updating prices
   - Ensure sufficient ETH balance for fee payment

2. **"Price too old"**
   - Solution: Update price feeds more frequently
   - Check Pyth Network status for feed availability

3. **"Source must be Pyth contract address"**
   - Solution: Verify correct Pyth contract address for your network
   - Ensure `_source` parameter matches deployed Pyth contract

4. **"Extra data must be 32 bytes"**
   - Solution: Verify price feed ID is correctly encoded as bytes32
   - Use `abi.encode(priceId)` for proper formatting

### Monitoring

Monitor these key metrics:
- Price update frequency
- Fee costs
- Confidence intervals
- Oracle uptime

## Gas Optimization

The implementation includes several gas optimizations:
- Efficient price encoding/decoding
- Minimal storage usage
- Batch price updates
- Emergency withdrawal for unused fees

## Future Enhancements

Potential improvements:
1. Automated price update bots
2. Multi-feed price aggregation
3. Historical price tracking
4. Advanced confidence interval analysis
5. Cross-chain price synchronization

---

For technical support or questions, refer to:
- [Pyth Network Documentation](https://docs.pyth.network/)
- [Citadel Finance Technical Documentation](./docs/)
- [Smart Contract Source Code](./src/oracle/implementations/PythPriceFeed.sol)