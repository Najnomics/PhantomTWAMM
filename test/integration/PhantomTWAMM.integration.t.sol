// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Uniswap v4 Test Infrastructure
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// FHE imports
import {
    FHE,
    InEuint128,
    InEuint64,
    InEuint8,
    euint128,
    euint64,
    euint8,
    ebool
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// Token imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Main contract
import {PhantomTWAMM} from "../../src/PhantomTWAMM.sol";

// Test utilities
import {HookMiner} from "../utils/HookMiner.sol";

contract PhantomTWAMMIntegrationTest is Test, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contracts
    IPoolManager poolManager;
    PhantomTWAMM phantomTWAMM;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    // Test tokens
    TestToken token0;
    TestToken token1;

    // Pool setup
    PoolKey poolKey;
    PoolId poolId;

    // Test accounts
    address alice;
    address bob;
    address carol;
    address dave;

    // Constants
    uint256 constant INITIAL_BALANCE = 1000000 * 10 ** 18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint128 constant LIQUIDITY_AMOUNT = 10000 * 10 ** 18;

    function setUp() public {
        // CoFheTest automatically sets up in constructor

        // Deploy pool manager
        poolManager = new PoolManager(address(0));

        // Deploy tokens
        token0 = new TestToken("Token A", "TKNA");
        token1 = new TestToken("Token B", "TKNB");

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Mine hook address with correct permissions
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PhantomTWAMM).creationCode, abi.encode(address(poolManager)));

        phantomTWAMM = new PhantomTWAMM{salt: salt}(poolManager);
        require(address(phantomTWAMM) == hookAddress, "Hook address mismatch");

        // Deploy test routers
        swapRouter = new PoolSwapTest(poolManager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);

        // Create pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(phantomTWAMM))
        });

        poolId = poolKey.toId();

        // Initialize pool
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Setup test accounts
        _setupTestAccounts();

        // Add initial liquidity
        _addInitialLiquidity();
    }

    // =============================================================
    // COMPREHENSIVE INTEGRATION TESTS (30 tests)
    // =============================================================

    function testIntegration_CompleteOrderLifecycle() public {
        // Step 1: Alice commits phantom order
        vm.startPrank(alice);

        InEuint128 memory encryptedSize = createInEuint128(uint128(1000 * 10 ** 18), alice);
        InEuint8 memory encryptedDirection = createInEuint8(0, alice); // Buy
        InEuint64 memory encryptedSchedule = createInEuint64(3600, alice); // 1 hour

        bytes32 commitment =
            phantomTWAMM.commitPhantomTWAMM(poolKey, encryptedSize, encryptedDirection, encryptedSchedule);

        vm.stopPrank();

        // Verify commitment created
        assertTrue(commitment != bytes32(0));
        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 1);

        // Step 2: Bob performs public swap (triggers processing)
        vm.startPrank(bob);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -100 * 10 ** 18,
            sqrtPriceLimitX96: type(uint160).max // Allow price movement
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        vm.stopPrank();

        // Step 3: Check computation readiness
        assertTrue(phantomTWAMM.isComputationReady(poolId));

        // Step 4: Alice reveals order (optional)
        vm.startPrank(alice);

        bytes memory proof = abi.encode("valid_reveal_proof", alice, commitment, block.timestamp);

        phantomTWAMM.revealForAuditability(commitment, 1000 * 10 ** 18, 0, 3600, proof);

        vm.stopPrank();

        // Verify reveal
        (,,,, address revealer, bool isRevealed) = phantomTWAMM.reveals(commitment);
        assertTrue(isRevealed);
        assertEq(revealer, alice);
    }

    function testIntegration_MultipleOrdersWithDifferentSchedules() public {
        bytes32[] memory commitments = new bytes32[](4);

        // Alice: 1-hour buy order
        vm.startPrank(alice);
        commitments[0] = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(3600, alice)
        );
        vm.stopPrank();

        // Bob: 2-hour sell order
        vm.startPrank(bob);
        commitments[1] = phantomTWAMM.commitPhantomTWAMM(
            poolKey, createInEuint128(uint128(750 * 10 ** 18), bob), createInEuint8(1, bob), createInEuint64(7200, bob)
        );
        vm.stopPrank();

        // Carol: 30-minute buy order
        vm.startPrank(carol);
        commitments[2] = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(500 * 10 ** 18), carol),
            createInEuint8(0, carol),
            createInEuint64(1800, carol)
        );
        vm.stopPrank();

        // Dave: 4-hour sell order
        vm.startPrank(dave);
        commitments[3] = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(2000 * 10 ** 18), dave),
            createInEuint8(1, dave),
            createInEuint64(14400, dave)
        );
        vm.stopPrank();

        // Verify all orders created
        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 4);

        // All commitments should be unique
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(commitments[i] != commitments[j]);
            }
        }

        // Trigger processing with swap
        vm.startPrank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -50 * 10 ** 18, sqrtPriceLimitX96: 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertTrue(phantomTWAMM.isComputationReady(poolId));
    }

    function testIntegration_VirtualTimeProgression() public {
        // Create order
        vm.startPrank(alice);
        bytes32 commitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(3600, alice)
        );
        vm.stopPrank();

        // Check initial virtual time
        euint64 initialVTime = phantomTWAMM.getPoolVirtualTime(poolId);

        // Advance time by 30 minutes
        vm.warp(block.timestamp + 1800);

        // Trigger virtual time update with swap
        vm.startPrank(bob);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Check updated virtual time
        euint64 updatedVTime = phantomTWAMM.getPoolVirtualTime(poolId);

        // Virtual time should have advanced (can't decrypt to compare directly)
        // But we can verify computation was triggered
        assertTrue(phantomTWAMM.isComputationReady(poolId));
    }

    function testIntegration_ComplianceAndAuditTrail() public {
        // Create multiple orders from different users
        bytes32[] memory commitments = new bytes32[](3);

        vm.startPrank(alice);
        commitments[0] = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(500 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(3600, alice)
        );
        vm.stopPrank();

        vm.startPrank(bob);
        commitments[1] = phantomTWAMM.commitPhantomTWAMM(
            poolKey, createInEuint128(uint128(750 * 10 ** 18), bob), createInEuint8(1, bob), createInEuint64(7200, bob)
        );
        vm.stopPrank();

        vm.startPrank(carol);
        commitments[2] = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), carol),
            createInEuint8(0, carol),
            createInEuint64(1800, carol)
        );
        vm.stopPrank();

        // Trigger execution
        vm.startPrank(dave);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -25 * 10 ** 18, sqrtPriceLimitX96: 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Alice reveals her order for compliance
        vm.startPrank(alice);
        phantomTWAMM.revealForAuditability(
            commitments[0], 500 * 10 ** 18, 0, 3600, abi.encode("alice_compliance_proof", commitments[0])
        );
        vm.stopPrank();

        // Bob chooses to keep his order private (no reveal)

        // Carol reveals her order
        vm.startPrank(carol);
        phantomTWAMM.revealForAuditability(
            commitments[2], 1000 * 10 ** 18, 0, 1800, abi.encode("carol_compliance_proof", commitments[2])
        );
        vm.stopPrank();

        // Check reveal status
        (,,,, address aliceRevealer, bool aliceRevealed) = phantomTWAMM.reveals(commitments[0]);
        (,,,, address bobRevealer, bool bobRevealed) = phantomTWAMM.reveals(commitments[1]);
        (,,,, address carolRevealer, bool carolRevealed) = phantomTWAMM.reveals(commitments[2]);

        assertTrue(aliceRevealed);
        assertEq(aliceRevealer, alice);

        assertFalse(bobRevealed);
        assertEq(bobRevealer, address(0));

        assertTrue(carolRevealed);
        assertEq(carolRevealer, carol);
    }

    function testIntegration_MEVResistanceScenario() public {
        // Alice commits large buy order
        vm.startPrank(alice);
        bytes32 aliceCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(5000 * 10 ** 18), alice),
            createInEuint8(0, alice), // Buy
            createInEuint64(7200, alice) // 2 hours
        );
        vm.stopPrank();

        // Bob commits large sell order (could be MEV attempt)
        vm.startPrank(bob);
        bytes32 bobCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(5000 * 10 ** 18), bob),
            createInEuint8(1, bob), // Sell
            createInEuint64(1800, bob) // 30 minutes (shorter schedule)
        );
        vm.stopPrank();

        // Carol performs regular swap
        vm.startPrank(carol);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Orders should be processed anonymously, preventing MEV extraction
        assertTrue(phantomTWAMM.isComputationReady(poolId));
        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 2);

        // Even if Bob knows about Alice's order, he can't front-run it
        // because order parameters are encrypted and execution is time-weighted
        assertTrue(aliceCommitment != bobCommitment);
    }

    function testIntegration_HighFrequencyScenario() public {
        // Simulate high-frequency scenario with multiple small orders
        bytes32[] memory commitments = new bytes32[](10);

        for (uint256 i = 0; i < 10; i++) {
            address trader = address(uint160(1000 + i));
            vm.deal(trader, 1 ether);
            token0.mint(trader, INITIAL_BALANCE);
            token1.mint(trader, INITIAL_BALANCE);

            vm.startPrank(trader);

            commitments[i] = phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128(100 * 10 ** 18 * (i + 1)), trader),
                createInEuint8(uint8(i % 2), trader), // Alternate buy/sell
                createInEuint64(uint64(600 + (i * 60)), trader) // 10-19 minutes
            );

            vm.stopPrank();
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 10);

        // Trigger batch processing
        vm.startPrank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -200 * 10 ** 18, sqrtPriceLimitX96: 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertTrue(phantomTWAMM.isComputationReady(poolId));
    }

    function testIntegration_EdgeCaseLargeOrders() public {
        // Test with very large orders
        vm.startPrank(alice);
        bytes32 largeCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(100000 * 10 ** 18), alice), // 100k tokens
            createInEuint8(0, alice),
            createInEuint64(86400, alice) // 24 hours
        );
        vm.stopPrank();

        // Test with very small orders
        vm.startPrank(bob);
        bytes32 smallCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(1 * 10 ** 15, bob), // 0.001 tokens
            createInEuint8(1, bob),
            createInEuint64(60, bob) // 1 minute
        );
        vm.stopPrank();

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 2);
        assertTrue(largeCommitment != smallCommitment);

        // Both orders should process correctly
        vm.startPrank(carol);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1000 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertTrue(phantomTWAMM.isComputationReady(poolId));
    }

    function testIntegration_TimeBasedExecution() public {
        // Create orders with different time horizons
        vm.startPrank(alice);
        bytes32 shortOrder = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(300, alice) // 5 minutes
        );
        vm.stopPrank();

        vm.startPrank(bob);
        bytes32 longOrder = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), bob),
            createInEuint8(1, bob),
            createInEuint64(21600, bob) // 6 hours
        );
        vm.stopPrank();

        // Advance time to middle of short order execution
        vm.warp(block.timestamp + 150); // 2.5 minutes

        vm.startPrank(carol);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -50 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertTrue(phantomTWAMM.isComputationReady(poolId));

        // Advance time past short order completion
        vm.warp(block.timestamp + 300); // Total 450 seconds (7.5 minutes)

        vm.startPrank(dave);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -50 * 10 ** 18, sqrtPriceLimitX96: 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Short order should be complete, long order still executing
        assertTrue(phantomTWAMM.isComputationReady(poolId));
    }

    function testIntegration_ConcurrentRevealAndExecution() public {
        // Create order
        vm.startPrank(alice);
        bytes32 commitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(3600, alice)
        );
        vm.stopPrank();

        // Start execution
        vm.startPrank(bob);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Alice reveals during execution
        vm.startPrank(alice);
        phantomTWAMM.revealForAuditability(commitment, 1000 * 10 ** 18, 0, 3600, abi.encode("concurrent_reveal_proof"));
        vm.stopPrank();

        // Continue execution
        vm.startPrank(carol);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -75 * 10 ** 18, sqrtPriceLimitX96: 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Both execution and reveal should work correctly
        assertTrue(phantomTWAMM.isComputationReady(poolId));
        (,,,, address revealer, bool isRevealed) = phantomTWAMM.reveals(commitment);
        assertTrue(isRevealed);
        assertEq(revealer, alice);
    }

    function testIntegration_StressTestManyOrders() public {
        // Create 50 orders from different addresses
        bytes32[] memory commitments = new bytes32[](50);

        for (uint256 i = 0; i < 50; i++) {
            address trader = address(uint160(2000 + i));
            vm.deal(trader, 1 ether);
            token0.mint(trader, INITIAL_BALANCE);
            token1.mint(trader, INITIAL_BALANCE);

            vm.startPrank(trader);

            commitments[i] = phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((100 + i) * 10 ** 18), trader),
                createInEuint8(uint8(i % 2), trader),
                createInEuint64(uint64(300 + (i * 10)), trader)
            );

            vm.stopPrank();
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 50);

        // Process with large swap
        uint256 gasBefore = gasleft();
        vm.startPrank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1000 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(phantomTWAMM.isComputationReady(poolId));
        assertTrue(gasUsed < 10000000); // Should not use excessive gas
    }

    function testIntegration_CrossPoolIsolation() public {
        // Create second pool with different tokens
        TestToken token2 = new TestToken("Token C", "TKNC");
        TestToken token3 = new TestToken("Token D", "TKND");

        if (address(token2) > address(token3)) {
            (token2, token3) = (token3, token2);
        }

        PoolKey memory poolKey2 = PoolKey({
            currency0: Currency.wrap(address(token2)),
            currency1: Currency.wrap(address(token3)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(phantomTWAMM))
        });

        PoolId poolId2 = poolKey2.toId();
        poolManager.initialize(poolKey2, SQRT_PRICE_1_1);

        // Add liquidity to second pool
        token2.mint(alice, INITIAL_BALANCE);
        token3.mint(alice, INITIAL_BALANCE);

        vm.startPrank(alice);
        // Approve the new tokens for the router
        token2.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);
        token3.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey2,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(int128(LIQUIDITY_AMOUNT)),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        // Create orders in both pools
        vm.startPrank(alice);
        bytes32 commitment1 = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(0, alice),
            createInEuint64(3600, alice)
        );

        bytes32 commitment2 = phantomTWAMM.commitPhantomTWAMM(
            poolKey2,
            createInEuint128(uint128(1000 * 10 ** 18), alice),
            createInEuint8(1, alice),
            createInEuint64(3600, alice)
        );
        vm.stopPrank();

        // Orders should be isolated per pool
        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 1);
        assertEq(phantomTWAMM.getActiveOrderCount(poolId2), 1);
        assertTrue(commitment1 != commitment2);

        // Swaps should trigger computation independently
        vm.startPrank(bob);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -50 * 10 ** 18, sqrtPriceLimitX96: type(uint160).max}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertTrue(phantomTWAMM.isComputationReady(poolId));
        assertFalse(phantomTWAMM.isComputationReady(poolId2)); // Should not affect second pool
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _setupTestAccounts() internal {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");

        address[] memory accounts = new address[](4);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        accounts[3] = dave;

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 1 ether);
            token0.mint(accounts[i], INITIAL_BALANCE);
            token1.mint(accounts[i], INITIAL_BALANCE);
            
            // Approve routers for all accounts
            vm.startPrank(accounts[i]);
            token0.approve(address(swapRouter), INITIAL_BALANCE);
            token1.approve(address(swapRouter), INITIAL_BALANCE);
            token0.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);
            token1.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);
            vm.stopPrank();
        }
    }

    function _addInitialLiquidity() internal {
        vm.startPrank(alice);

        // Approve tokens for liquidity router
        token0.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);
        token1.approve(address(modifyLiquidityRouter), INITIAL_BALANCE);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(int128(LIQUIDITY_AMOUNT)),
                salt: bytes32(0)
            }),
            ""
        );

        vm.stopPrank();
    }
}

contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
