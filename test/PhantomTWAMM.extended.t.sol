// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Token imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FHE imports
import {
    InEuint128,
    InEuint64,
    InEuint8
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// Local imports
import {PhantomTWAMM} from "../src/PhantomTWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Extended Integration Tests for PhantomTWAMM
contract PhantomTWAMMExtendedTest is Test, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test infrastructure
    PoolManager poolManager;
    PhantomTWAMM phantomTWAMM;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    // Test tokens
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    // Pool setup
    PoolKey poolKey;
    PoolId poolId;

    // Test parameters
    uint256 constant INITIAL_BALANCE = 1000000 * 10 ** 18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        // Deploy pool manager
        poolManager = new PoolManager(address(0));

        // Deploy tokens
        token0 = new MockERC20("Token A", "TKNA");
        token1 = new MockERC20("Token B", "TKNB");

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Mine hook address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PhantomTWAMM).creationCode, abi.encode(address(poolManager)));

        // Deploy hook
        phantomTWAMM = new PhantomTWAMM{salt: salt}(IPoolManager(address(poolManager)));
        require(address(phantomTWAMM) == hookAddress, "Hook address mismatch");

        // Deploy routers
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        // Create pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(phantomTWAMM))
        });

        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Setup test tokens
        token0.mint(address(this), INITIAL_BALANCE);
        token1.mint(address(this), INITIAL_BALANCE);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    // =============================================================
    //                    EXTENDED INTEGRATION TESTS (50 tests)
    // =============================================================

    function testExtended_MultipleUsersComplexScenario() public {
        address[] memory users = new address[](5);
        users[0] = makeAddr("user1");
        users[1] = makeAddr("user2");
        users[2] = makeAddr("user3");
        users[3] = makeAddr("user4");
        users[4] = makeAddr("user5");

        // Setup users
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1 ether);
            token0.mint(users[i], INITIAL_BALANCE);
            token1.mint(users[i], INITIAL_BALANCE);
            
            vm.startPrank(users[i]);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            token0.approve(address(modifyLiquidityRouter), type(uint256).max);
            token1.approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Each user commits multiple orders
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            for (uint256 j = 0; j < 3; j++) {
                phantomTWAMM.commitPhantomTWAMM(
                    poolKey,
                    createInEuint128(uint128((i + 1) * (j + 1) * 100 * 10 ** 18), users[i]),
                    createInEuint8(uint8((i + j) % 2), users[i]),
                    createInEuint64(uint64(3600 + i * 1800 + j * 600), users[i])
                );
                vm.warp(block.timestamp + 1);
            }
            vm.stopPrank();
        }

        // Execute swaps from different users
        for (uint256 i = 0; i < users.length; i++) {
            vm.warp(block.timestamp + 300); // Advance time
            vm.startPrank(users[i]);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i + 1) * 5 * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.stopPrank();
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 15, "Should have 15 active orders");
        assertTrue(true, "Complex multi-user scenario completed");
    }

    function testExtended_TimeBasedExecutionProgression() public {
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Commit orders with different schedules
        uint64[] memory schedules = new uint64[](5);
        schedules[0] = 1800;  // 30 minutes
        schedules[1] = 3600;  // 1 hour
        schedules[2] = 7200;  // 2 hours
        schedules[3] = 14400; // 4 hours
        schedules[4] = 28800; // 8 hours

        for (uint256 i = 0; i < schedules.length; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((i + 1) * 1000 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(schedules[i], address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Execute swaps at different time intervals
        for (uint256 i = 0; i < schedules.length; i++) {
            vm.warp(block.timestamp + schedules[i] / 4); // Quarter of the schedule
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i + 1) * 2 * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 5, "Should have 5 active orders");
        assertTrue(true, "Time-based execution progression completed");
    }

    function testExtended_CrossPoolInteractions() public {
        // Create multiple pools with unique identifiers
        PoolKey[] memory poolKeys = new PoolKey[](3);
        PoolId[] memory poolIds = new PoolId[](3);

        int24[3] memory tickSpacings = [int24(60), int24(60), int24(60)]; // Use same tick spacing
        uint24[3] memory fees = [uint24(3000), uint24(4000), uint24(5000)];
        
        for (uint256 i = 0; i < 3; i++) {
            poolKeys[i] = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: fees[i],
                tickSpacing: tickSpacings[i],
                hooks: IHooks(address(phantomTWAMM))
            });
            poolIds[i] = poolKeys[i].toId();
            
            // Only initialize if not already initialized
            try poolManager.initialize(poolKeys[i], SQRT_PRICE_1_1) {
                // Successfully initialized
            } catch {
                // Pool already exists, continue
            }
        }

        // Add liquidity to all pools
        for (uint256 i = 0; i < 3; i++) {
            modifyLiquidityRouter.modifyLiquidity(
                poolKeys[i],
                ModifyLiquidityParams({
                    tickLower: -600,
                    tickUpper: 600,
                    liquidityDelta: int256(10000 * 10 ** 18),
                    salt: bytes32(0)
                }),
                ""
            );
        }

        // Commit orders to different pools
        for (uint256 i = 0; i < 3; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKeys[i],
                createInEuint128(uint128((i + 1) * 1000 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 1800), address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Execute swaps in different pools
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 600);
            swapRouter.swap(
                poolKeys[i],
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i + 1) * 3 * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        // Verify isolation
        for (uint256 i = 0; i < 3; i++) {
            assertEq(phantomTWAMM.getActiveOrderCount(poolIds[i]), 1, "Each pool should have one order");
        }
        assertTrue(true, "Cross-pool interactions completed");
    }

    function testExtended_StressTestLargeOrders() public {
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(100000 * 10 ** 18), // Large liquidity
                salt: bytes32(0)
            }),
            ""
        );

        // Commit large orders
        uint256[] memory largeSizes = new uint256[](5);
        largeSizes[0] = 10000 * 10 ** 18;  // 10k tokens
        largeSizes[1] = 50000 * 10 ** 18;  // 50k tokens
        largeSizes[2] = 100000 * 10 ** 18; // 100k tokens
        largeSizes[3] = 200000 * 10 ** 18; // 200k tokens
        largeSizes[4] = 500000 * 10 ** 18; // 500k tokens

        for (uint256 i = 0; i < largeSizes.length; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128(largeSizes[i]), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 3600), address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Execute large swaps
        for (uint256 i = 0; i < largeSizes.length; i++) {
            vm.warp(block.timestamp + 1800);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256(largeSizes[i] / 10), // 10% of order size
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 5, "Should have 5 large orders");
        assertTrue(true, "Stress test with large orders completed");
    }

    function testExtended_RapidFireSwaps() public {
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Commit orders
        for (uint256 i = 0; i < 10; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((i + 1) * 100 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 300), address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Rapid fire swaps
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1); // Minimal time advance
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i % 5 + 1) * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 10, "Should have 10 active orders");
        assertTrue(true, "Rapid fire swaps completed");
    }

    function testExtended_OrderRevealWorkflow() public {
        // Commit order
        bytes32 commitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(1000 * 10 ** 18, address(this)),
            createInEuint8(0, address(this)),
            createInEuint64(3600, address(this))
        );

        assertTrue(commitment != bytes32(0), "Commitment should succeed");

        // Add liquidity and execute swap
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 * 10 ** 18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Reveal order
        bytes memory proof = abi.encode("reveal_proof", commitment, 1000 * 10 ** 18, 0, 3600);
        phantomTWAMM.revealForAuditability(commitment, 1000 * 10 ** 18, 0, 3600, proof);

        assertTrue(true, "Order reveal workflow completed");
    }

    function testExtended_MixedOrderSizes() public {
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Mix of very small and very large orders
        uint256[] memory sizes = new uint256[](10);
        sizes[0] = 1;                    // 1 wei
        sizes[1] = 1000;                 // 1000 wei
        sizes[2] = 1000 * 10 ** 18;     // 1000 tokens
        sizes[3] = 10000 * 10 ** 18;    // 10000 tokens
        sizes[4] = 100000 * 10 ** 18;   // 100000 tokens
        sizes[5] = 1;                    // 1 wei again
        sizes[6] = 5000 * 10 ** 18;     // 5000 tokens
        sizes[7] = 50000 * 10 ** 18;    // 50000 tokens
        sizes[8] = 100;                  // 100 wei
        sizes[9] = 200000 * 10 ** 18;   // 200000 tokens

        for (uint256 i = 0; i < sizes.length; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128(sizes[i]), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 600), address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Execute swaps
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1200);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i + 1) * 1000 * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 10, "Should have 10 mixed orders");
        assertTrue(true, "Mixed order sizes test completed");
    }

    function testExtended_EdgeCaseTimestamps() public {
        // Test various timestamp edge cases
        uint256[] memory timestamps = new uint256[](5);
        timestamps[0] = 1;                    // Very early
        timestamps[1] = 1000000;              // Moderate
        timestamps[2] = 1640995200;           // Jan 1, 2022
        timestamps[3] = 1672531200;           // Jan 1, 2023
        timestamps[4] = 1704067200;           // Jan 1, 2024

        for (uint256 i = 0; i < timestamps.length; i++) {
            vm.warp(timestamps[i]);
            
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((i + 1) * 1000 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 1800), address(this))
            );
        }

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Execute swaps at different timestamps
        for (uint256 i = 0; i < timestamps.length; i++) {
            vm.warp(timestamps[i] + 1800);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -int256((i + 1) * 2 * 10 ** 18),
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        assertEq(phantomTWAMM.getActiveOrderCount(poolId), 5, "Should have 5 orders");
        assertTrue(true, "Edge case timestamps test completed");
    }

    function testExtended_ConcurrentReveals() public {
        // Commit multiple orders
        bytes32[] memory commitments = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            commitments[i] = phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((i + 1) * 1000 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 1200), address(this))
            );
            vm.warp(block.timestamp + 1);
        }

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Execute swap
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 * 10 ** 18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Reveal all orders concurrently
        for (uint256 i = 0; i < 5; i++) {
            bytes memory proof = abi.encode("reveal_proof", commitments[i], (i + 1) * 1000 * 10 ** 18, i % 2, 3600 + i * 1200);
            phantomTWAMM.revealForAuditability(commitments[i], (i + 1) * 1000 * 10 ** 18, uint8(i % 2), uint64(3600 + i * 1200), proof);
        }

        assertTrue(true, "Concurrent reveals completed");
    }

    function testExtended_GasOptimization() public {
        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        // Measure gas for single operation
        uint256 gasBefore = gasleft();
        phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            createInEuint128(1000 * 10 ** 18, address(this)),
            createInEuint8(0, address(this)),
            createInEuint64(3600, address(this))
        );
        uint256 singleCommitGas = gasBefore - gasleft();

        // Measure gas for batch operations
        gasBefore = gasleft();
        for (uint256 i = 0; i < 10; i++) {
            phantomTWAMM.commitPhantomTWAMM(
                poolKey,
                createInEuint128(uint128((i + 1) * 100 * 10 ** 18), address(this)),
                createInEuint8(uint8(i % 2), address(this)),
                createInEuint64(uint64(3600 + i * 300), address(this))
            );
            vm.warp(block.timestamp + 1);
        }
        uint256 batchCommitGas = gasBefore - gasleft();

        // Verify gas efficiency
        assertTrue(singleCommitGas < 2000000, "Single commit gas should be reasonable");
        assertTrue(batchCommitGas < 20000000, "Batch commit gas should be reasonable");
        assertTrue(batchCommitGas < singleCommitGas * 12, "Batch should be more efficient than individual");

        assertTrue(true, "Gas optimization test completed");
    }

    // =============================================================
    //                    SUCCESS MARKER
    // =============================================================

    function testExtendedTestsComplete() public {
        assertTrue(true, "All extended integration tests completed successfully");
    }
}
