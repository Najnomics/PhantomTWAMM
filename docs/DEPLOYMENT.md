# PhantomTWAMM Deployment Guide

## Overview

This guide provides step-by-step instructions for deploying the PhantomTWAMM hook to various networks.

## Prerequisites

### Required Tools
- [Foundry](https://getfoundry.sh/) (latest version)
- [Node.js](https://nodejs.org/) (v18+)
- [Git](https://git-scm.com/)

### Required Accounts
- Ethereum account with sufficient ETH for gas
- RPC access to target network
- Etherscan API key (for verification)

## Environment Setup

### 1. Clone Repository

```bash
git clone https://github.com/your-org/PhantomTWAMM.git
cd PhantomTWAMM
```

### 2. Install Dependencies

```bash
# Install Foundry dependencies
forge install

# Install Node.js dependencies
npm install
```

### 3. Configure Environment

```bash
# Copy environment template
cp .env.example .env

# Edit environment variables
nano .env
```

### 4. Environment Variables

```bash
# Required variables
PRIVATE_KEY=your_private_key_here
RPC_URL=https://your-rpc-url.com
ETHERSCAN_API_KEY=your_etherscan_api_key

# Optional variables
MAINNET_RPC=https://mainnet.infura.io/v3/your-project-id
TESTNET_RPC=https://sepolia.infura.io/v3/your-project-id
POOL_MANAGER_ADDRESS=0x0000000000000000000000000000000000000000
```

## Deployment Scripts

### 1. SimpleDeploy.s.sol

Basic deployment script for testing and development.

```solidity
// Deploy to local Anvil
forge script script/SimpleDeploy.s.sol --rpc-url http://localhost:8545 --broadcast

// Deploy to testnet
forge script script/SimpleDeploy.s.sol --rpc-url $RPC_URL --broadcast
```

### 2. DeployPhantomTWAMM.s.sol

Full deployment script with hook address mining.

```solidity
// Deploy to testnet
forge script script/DeployPhantomTWAMM.s.sol --rpc-url $RPC_URL --broadcast --verify

// Deploy to mainnet
forge script script/DeployPhantomTWAMM.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
```

## Network-Specific Deployment

### Local Development (Anvil)

```bash
# Start Anvil
anvil --host 0.0.0.0 --port 8545

# Deploy in another terminal
forge script script/SimpleDeploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet (Sepolia)

```bash
# Set testnet RPC
export RPC_URL=https://sepolia.infura.io/v3/your-project-id

# Deploy with verification
forge script script/DeployPhantomTWAMM.s.sol --rpc-url $RPC_URL --broadcast --verify
```

### Mainnet

```bash
# Set mainnet RPC
export MAINNET_RPC=https://mainnet.infura.io/v3/your-project-id

# Deploy with verification
forge script script/DeployPhantomTWAMM.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
```

## Hook Address Mining

### Understanding Hook Permissions

Uniswap V4 hooks require specific address patterns based on their permissions:

```solidity
// Hook permissions for PhantomTWAMM
uint160 flags = uint160(
    Hooks.BEFORE_SWAP_FLAG |
    Hooks.AFTER_INITIALIZE_FLAG
);
```

### Mining Process

The deployment script automatically mines for a valid hook address:

```solidity
// Find valid hook address
(address hookAddress, bytes32 salt) = HookMiner.find(
    deployer,
    flags,
    type(PhantomTWAMM).creationCode,
    abi.encode(address(poolManager))
);
```

### Address Requirements

- Must match permission flags
- Must be deterministic via CREATE2
- Must be unique per deployment

## Deployment Verification

### 1. Contract Verification

```bash
# Verify on Etherscan
forge verify-contract <CONTRACT_ADDRESS> PhantomTWAMM --etherscan-api-key $ETHERSCAN_API_KEY

# Verify with constructor arguments
forge verify-contract <CONTRACT_ADDRESS> PhantomTWAMM --etherscan-api-key $ETHERSCAN_API_KEY --constructor-args $(cast abi-encode "constructor(address)" <POOL_MANAGER_ADDRESS>)
```

### 2. Function Verification

```bash
# Test basic functions
cast call <CONTRACT_ADDRESS> "isComputationReady(bytes32)" <POOL_ID>

# Test hook permissions
cast call <CONTRACT_ADDRESS> "getHookPermissions()" 
```

### 3. Integration Testing

```bash
# Run integration tests
forge test --match-path "test/integration/*"

# Test with deployed contract
forge test --fork-url $RPC_URL --match-test "testDeployedContract"
```

## Post-Deployment Setup

### 1. Initialize Pools

```solidity
// Initialize pool with hook
poolManager.initialize(
    PoolKey({
        currency0: currency0,
        currency1: currency1,
        fee: 3000,
        tickSpacing: 60,
        hooks: IHooks(hookAddress)
    }),
    SQRT_PRICE_1_1
);
```

### 2. Grant Permissions

```solidity
// Grant hook permissions
poolManager.updateHookPermissions(
    hookAddress,
    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
);
```

### 3. Configure Parameters

```solidity
// Set virtual time parameters
phantomTWAMM.setVirtualTimeParameters(
    poolId,
    timeAdvancementRate,
    maxTimeAdvancement
);
```

## Monitoring and Maintenance

### 1. Event Monitoring

Monitor key events for system health:

```solidity
// Order events
PhantomTWAMMCommitted(bytes32 indexed commitmentHash, PoolId indexed poolId)
OrderRevealed(bytes32 indexed commitmentHash, address indexed revealer)

// Virtual time events
VirtualTimeAdvanced(PoolId indexed poolId, euint64 newVirtualTime)

// Computation events
DeltaComputationRequested(PoolId indexed poolId, bytes32 indexed requestId, uint256 orderCount)
AnonymousDeltaApplied(PoolId indexed poolId, euint128 totalDelta)
```

### 2. Health Checks

```bash
# Check contract state
cast call <CONTRACT_ADDRESS> "getVirtualTime(bytes32)" <POOL_ID>

# Check computation status
cast call <CONTRACT_ADDRESS> "isComputationReady(bytes32)" <POOL_ID>

# Check order count
cast call <CONTRACT_ADDRESS> "getActiveOrderCount(bytes32)" <POOL_ID>
```

### 3. Gas Monitoring

Monitor gas usage for optimization:

```bash
# Run gas report
forge test --gas-report

# Monitor deployment gas
forge script script/DeployPhantomTWAMM.s.sol --gas-report
```

## Troubleshooting

### Common Issues

#### 1. Hook Address Mining Fails

```bash
# Increase mining attempts
export MINING_ATTEMPTS=1000000

# Use different salt
export SALT_PREFIX=0x1234567890abcdef
```

#### 2. Verification Fails

```bash
# Check constructor arguments
cast abi-encode "constructor(address)" <POOL_MANAGER_ADDRESS>

# Verify manually on Etherscan
```

#### 3. Permission Errors

```bash
# Check hook permissions
cast call <CONTRACT_ADDRESS> "getHookPermissions()"

# Verify pool configuration
cast call <POOL_MANAGER_ADDRESS> "getSlot0(bytes32)" <POOL_ID>
```

### Debug Commands

```bash
# Debug deployment
forge script script/DeployPhantomTWAMM.s.sol --debug

# Trace transaction
cast trace <TX_HASH>

# Inspect contract
cast code <CONTRACT_ADDRESS>
```

## Security Considerations

### 1. Private Key Security

- Use hardware wallets for mainnet
- Never commit private keys to version control
- Use environment variables for sensitive data

### 2. Contract Verification

- Always verify contracts on Etherscan
- Verify constructor arguments correctly
- Test on testnet before mainnet

### 3. Access Control

- Review hook permissions carefully
- Implement proper access controls
- Monitor for unauthorized access

## Production Checklist

- [ ] All tests passing
- [ ] Gas optimization complete
- [ ] Security audit completed
- [ ] Contract verification successful
- [ ] Monitoring setup complete
- [ ] Documentation updated
- [ ] Team training completed
- [ ] Incident response plan ready

## Support

For deployment support:

- GitHub Issues: [Create Issue](https://github.com/your-org/PhantomTWAMM/issues)
- Documentation: [Read the Docs](https://docs.phantomtwamm.com)
- Community: [Discord](https://discord.gg/phantomtwamm)
