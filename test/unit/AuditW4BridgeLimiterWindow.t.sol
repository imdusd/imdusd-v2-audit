// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 LOW (audit 34e546c2): the limiter admits almost 2 x limit inside one window while the header and
/// DeployConfig said "at most `limit` in any `window`".
/// PROPERTY (P1, as now stated): in any interval of length t the path admits at most limit + limit x t / window (so
/// < 2 x limit inside one window), never more, over any schedule of arrivals.
contract AuditW4BridgeLimiterWindowTest is W4Bridge {
    uint256 constant L = 10_000e18;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
    }

    /// The judge's sequence: a full burst, then 86,399 s later almost a second limit.
    function test_almostTwiceTheLimitInsideOneWindow() public {
        assertTrue(homeEp.deliver(_forge(L)));
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        uint256 avail = rh.availableIn(HOME);
        assertTrue(homeEp.deliver(_forge(avail / 1e12 * 1e12)));
        // metered = minted at once + queued as claims (above DELAY_THRESHOLD a message waits DELAY)
        assertGt(_admitted(), L, "more than one limit inside one window");
        assertLt(_admitted(), 2 * L);
    }

    /// Fuzzed schedule: never more than limit + limit x t / window in any interval t from the start.
    function testFuzz_admittedWithinTheStatedBound(uint256 seed) public {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 k; k < 12; ++k) {
            seed = uint256(keccak256(abi.encode(seed)));
            vm.warp(vm.getBlockTimestamp() + seed % 6 hours);
            homeEp.deliver(_forge((seed >> 64) % (L + 1)));
            uint256 t = vm.getBlockTimestamp() - t0;
            assertLe(_admitted(), L + L * t / 1 days);
        }
    }
}
