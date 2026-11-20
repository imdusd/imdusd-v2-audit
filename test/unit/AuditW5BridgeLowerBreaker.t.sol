// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice Wave-5 audit 74838ad4, LOW 1 (judge; permissions: medium, math: low): lowering the queue breaker B (tighten, or a
/// SET_DELAY) below what the 4-day window already holds did not trip the path: the breaker was evaluated only when a new
/// message queued, so the forged claims already queued matured and minted.
/// PROPERTY (P2, breaker): whenever the path's breaker window holds more than its CURRENT B, the path is tripped (no claim
/// runs until RESET_BREAKER), whether the window grew or B fell.
contract AuditW5BridgeLowerBreakerTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    /// The auditor's sequence: 5,000 instant, 40,000 queued; the Safe lowers B to 10,000: the path trips, the claim waits.
    function test_tightenBreakerBelowQueuedTrips() public {
        (, bool ok1) = _forgeRun(5_000e18);
        (uint256 i2, bool ok2) = _forgeRun(40_000e18);
        assertTrue(ok1 && ok2);
        _warp(1 hours);
        vm.prank(safe);
        rh.tighten(HOME, C, D, 10_000e18, 0);
        assertTrue(_tripped(), "40,000 queued in the window > the new breaker 10,000, yet the path is not tripped");
        _warp(D);
        assertFalse(_tryClaim(i2), "the forged claim minted after B was tightened");
        assertEq(rhTok.balanceOf(attacker), 5_000e18);
    }

    /// The same through a timelocked SET_DELAY lowering B.
    function test_setDelayLoweringBreakerTrips() public {
        (, bool ok) = _forgeRun(40_000e18);
        assertTrue(ok);
        _governRh(_setDelayP(C, D, 10_000e18, 0));
        assertTrue(_tripped());
    }

    /// Queues that fell out of the 4-UTC-day window do not count: lowering B then does not trip.
    function test_outOfWindowQueuesDoNotTrip() public {
        (, bool ok) = _forgeRun(40_000e18);
        assertTrue(ok);
        _warp(4 days);
        vm.prank(safe);
        rh.tighten(HOME, C, D, 10_000e18, 0);
        assertFalse(_tripped());
    }

    /// Property, fuzzed: queue a few amounts over a few days, then lower B to `b` (instantly or through the timelock); the
    /// path is tripped iff the window sum exceeds b (or it was tripped already).
    function testFuzz_trippedIffWindowOverB(uint256 seed, uint256 b, bool timelocked) public {
        uint256[] memory amt = new uint256[](4);
        uint256[] memory dayOf = new uint256[](4);
        for (uint256 j; j < 4; ++j) {
            uint256 a = bound(uint256(keccak256(abi.encode(seed, j))), 5_001, 12_000) * 1e18; // above C: queued
            (, bool ok) = _forgeRun(a);
            if (ok) {
                amt[j] = a;
                dayOf[j] = vm.getBlockTimestamp() / 1 days;
            }
            _warp(bound(uint256(keccak256(abi.encode(seed, j, "dt"))), 1 hours, 30 hours));
        }
        bool before = _tripped();
        b = bound(b, 0, 60_000) * 1e18;
        uint256 at = timelocked ? vm.getBlockTimestamp() + 48 hours : vm.getBlockTimestamp();
        uint256 sum;
        for (uint256 j; j < 4; ++j) {
            if (amt[j] != 0 && dayOf[j] + 4 > at / 1 days) sum += amt[j];
        }
        if (timelocked) {
            _governRh(_setDelayP(C, D, b, 0));
        } else {
            vm.prank(safe);
            rh.tighten(HOME, C, D, b, 0);
        }
        if (before || sum > b) assertTrue(_tripped(), "window over the new B, not tripped");
        else assertFalse(_tripped(), "tripped with the window within B");
    }
}
