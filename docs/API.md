# PhantomTWAMM API Reference

## Overview

This document provides a comprehensive API reference for the PhantomTWAMM hook contract and its supporting libraries.

## Main Contract: PhantomTWAMM.sol

### Functions

#### `commitPhantomTWAMM`

Commits a new encrypted TWAMM order to the system.

```solidity
function commitPhantomTWAMM(
    PoolKey calldata key,
    InEuint128 calldata encryptedSize,
    InEuint8 calldata encryptedDirection,
    InEuint64 calldata encryptedSchedule
) external returns (bytes32 commitmentHash)
```

**Parameters:**
- `key`: Pool configuration (currency0, currency1, fee, tickSpacing, hooks)
- `encryptedSize`: Encrypted total order size
- `encryptedDirection`: Encrypted buy/sell direction (0 = buy, 1 = sell)
- `encryptedSchedule`: Encrypted execution schedule in seconds

**Returns:**
- `commitmentHash`: Unique identifier for the committed order

**Events:**
- `PhantomTWAMMCommitted(bytes32 indexed commitmentHash, PoolId indexed poolId)`

#### `revealForAuditability`

Reveals order parameters for compliance and audit purposes.

```solidity
function revealForAuditability(
    bytes32 commitmentHash,
    uint256 originalSize,
    uint8 originalDirection,
    uint64 originalSchedule,
    bytes calldata proof
) external
```

**Parameters:**
- `commitmentHash`: Order commitment to reveal
- `originalSize`: Original unencrypted order size
- `originalDirection`: Original unencrypted direction
- `originalSchedule`: Original unencrypted schedule
- `proof`: Cryptographic proof of ownership

**Events:**
- `OrderRevealed(bytes32 indexed commitmentHash, address indexed revealer)`

#### `isComputationReady`

Checks if CoFHE computation results are ready for a pool.

```solidity
function isComputationReady(PoolId poolId) external view returns (bool)
```

**Parameters:**
- `poolId`: Pool identifier

**Returns:**
- `bool`: True if computation results are ready

### Hook Functions

#### `afterInitialize`

Hook callback called after pool initialization.

```solidity
function afterInitialize(
    address,
    PoolKey calldata key,
    uint160,
    int24,
    bytes calldata
) external override returns (bytes4)
```

**Parameters:**
- `key`: Pool configuration
- `sqrtPriceX96`: Initial pool price
- `tick`: Initial tick
- `hookData`: Additional hook data

**Returns:**
- `bytes4`: Hook selector

#### `beforeSwap`

Hook callback called before each swap.

```solidity
function beforeSwap(
    address,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata,
    bytes calldata
) external override returns (bytes4)
```

**Parameters:**
- `key`: Pool configuration
- `params`: Swap parameters
- `hookData`: Additional hook data

**Returns:**
- `bytes4`: Hook selector

## Library: VirtualTimeEngine.sol

### Functions

#### `advanceVirtualTime`

Advances the virtual time for a pool.

```solidity
function advanceVirtualTime(PoolId poolId) internal
```

**Parameters:**
- `poolId`: Pool identifier

**Events:**
- `VirtualTimeAdvanced(PoolId indexed poolId, euint64 newVirtualTime)`

#### `getVirtualTimeProgress`

Calculates execution progress for an order.

```solidity
function getVirtualTimeProgress(
    PhantomTWAMMOrder memory order,
    euint64 currentVirtualTime
) internal pure returns (euint128)
```

**Parameters:**
- `order`: Order to calculate progress for
- `currentVirtualTime`: Current virtual time

**Returns:**
- `euint128`: Execution progress amount

#### `calculateExecutionRate`

Calculates the execution rate for an order.

```solidity
function calculateExecutionRate(
    euint128 totalSize,
    euint64 schedule,
    euint64 timeElapsed
) internal pure returns (euint128)
```

**Parameters:**
- `totalSize`: Total order size
- `schedule`: Execution schedule
- `timeElapsed`: Time elapsed since start

**Returns:**
- `euint128`: Execution rate

## Library: EncryptedDeltaCalculator.sol

### Functions

#### `requestDeltaComputation`

Requests CoFHE computation for encrypted deltas.

```solidity
function requestDeltaComputation(PoolId poolId) internal
```

**Parameters:**
- `poolId`: Pool identifier

**Events:**
- `DeltaComputationRequested(PoolId indexed poolId, bytes32 indexed requestId, uint256 orderCount)`

#### `applyAnonymousDeltas`

Applies computed deltas to the pool.

```solidity
function applyAnonymousDeltas(
    PoolId poolId,
    BalanceDelta currentDelta
) internal
```

**Parameters:**
- `poolId`: Pool identifier
- `currentDelta`: Current pool delta

**Events:**
- `AnonymousDeltaApplied(PoolId indexed poolId, euint128 totalDelta)`

#### `aggregateOrderDeltas`

Aggregates deltas from multiple orders.

```solidity
function aggregateOrderDeltas(
    bytes32[] memory commitments,
    euint64 currentVirtualTime
) internal pure returns (BundledDelta memory)
```

**Parameters:**
- `commitments`: Array of order commitments
- `currentVirtualTime`: Current virtual time

**Returns:**
- `BundledDelta`: Aggregated delta bundle

## Library: UnlinkableCommitments.sol

### Functions

#### `generateCommitment`

Generates an unlinkable commitment for an order.

```solidity
function generateCommitment(
    address user,
    uint256 timestamp,
    InEuint128 calldata encryptedSize,
    InEuint8 calldata encryptedDirection,
    InEuint64 calldata encryptedSchedule
) internal pure returns (bytes32)
```

**Parameters:**
- `user`: User address
- `timestamp`: Commitment timestamp
- `encryptedSize`: Encrypted order size
- `encryptedDirection`: Encrypted direction
- `encryptedSchedule`: Encrypted schedule

**Returns:**
- `bytes32`: Unlinkable commitment hash

#### `verifyCommitment`

Verifies the validity of a commitment.

```solidity
function verifyCommitment(
    bytes32 commitment,
    address user,
    uint256 timestamp,
    bytes calldata proof
) internal pure returns (bool)
```

**Parameters:**
- `commitment`: Commitment to verify
- `user`: User address
- `timestamp`: Commitment timestamp
- `proof`: Verification proof

**Returns:**
- `bool`: True if commitment is valid

## Library: OptionalRevealManager.sol

### Functions

#### `verifyRevealProof`

Verifies a reveal proof for order parameters.

```solidity
function verifyRevealProof(
    bytes32 commitmentHash,
    bytes calldata proof
) internal pure returns (bool)
```

**Parameters:**
- `commitmentHash`: Order commitment
- `proof`: Reveal proof

**Returns:**
- `bool`: True if proof is valid

#### `generateAuditReceipt`

Generates an audit receipt for a revealed order.

```solidity
function generateAuditReceipt(
    bytes32 commitmentHash
) internal view returns (AuditReceipt memory)
```

**Parameters:**
- `commitmentHash`: Order commitment

**Returns:**
- `AuditReceipt`: Audit receipt data

## Data Structures

### PhantomTWAMMOrder

```solidity
struct PhantomTWAMMOrder {
    euint128 totalSize;         // Encrypted total order size
    euint8 direction;           // Encrypted buy/sell direction
    euint64 schedule;           // Encrypted execution schedule
    euint128 virtualTime;       // Private virtual time tracking
    euint128 executedAmount;    // Encrypted executed amount
    euint64 lastExecution;      // Last execution timestamp
    ebool isRevealed;          // Reveal status
    bytes32 commitmentHash;     // Unlinkable commitment
}
```

### BundledDelta

```solidity
struct BundledDelta {
    euint128 totalDelta;        // Aggregated delta amount
    euint8 direction;           // Net direction
    uint256 orderCount;         // Number of orders processed
    bytes32 computationHash;    // Verification hash
}
```

### AuditReceipt

```solidity
struct AuditReceipt {
    bytes32 commitmentHash;     // Order commitment
    bytes executionProof;       // Execution proof
    euint64 revealTimestamp;    // Reveal timestamp
    bytes originalParameters;   // Original order parameters
    bytes complianceMetadata;   // Compliance metadata
}
```

## Events

### Order Events

```solidity
event PhantomTWAMMCommitted(bytes32 indexed commitmentHash, PoolId indexed poolId);
event OrderRevealed(bytes32 indexed commitmentHash, address indexed revealer);
```

### Virtual Time Events

```solidity
event VirtualTimeAdvanced(PoolId indexed poolId, euint64 newVirtualTime);
```

### Computation Events

```solidity
event DeltaComputationRequested(PoolId indexed poolId, bytes32 indexed requestId, uint256 orderCount);
event AnonymousDeltaApplied(PoolId indexed poolId, euint128 totalDelta);
```

## Error Handling

### Custom Errors

```solidity
error OrderNotFound(bytes32 commitmentHash);
error OrderAlreadyRevealed(bytes32 commitmentHash);
error InvalidRevealProof(bytes32 commitmentHash);
error ComputationNotReady(PoolId poolId);
error InvalidOrderParameters();
error UnauthorizedReveal();
```

## Usage Examples

### Committing an Order

```solidity
// Encrypt order parameters
InEuint128 memory encryptedSize = createInEuint128(1000 * 10**18, address(this));
InEuint8 memory encryptedDirection = createInEuint8(0, address(this)); // 0 = buy
InEuint64 memory encryptedSchedule = createInEuint64(3600, address(this)); // 1 hour

// Commit the order
bytes32 commitment = phantomTWAMM.commitPhantomTWAMM(
    poolKey,
    encryptedSize,
    encryptedDirection,
    encryptedSchedule
);
```

### Revealing an Order

```solidity
// Reveal order for audit
phantomTWAMM.revealForAuditability(
    commitmentHash,
    1000 * 10**18,  // original size
    0,              // original direction
    3600,           // original schedule
    proof           // cryptographic proof
);
```

### Checking Computation Status

```solidity
// Check if computation is ready
bool ready = phantomTWAMM.isComputationReady(poolId);
if (ready) {
    // Process results
}
```
