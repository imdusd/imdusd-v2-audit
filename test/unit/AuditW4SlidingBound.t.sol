// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DoorLeaf} from "./PricerTwin.t.sol";

/// @notice AUDIT WAVE 4 (price design, low P1: the sliding-window bound was understated). PROPERTY, as now documented in
/// SwarmFeed's header (P1) and the README: over any closed window of one maxAge, the stored value moves at most
/// (1 + c)^2 - 1 up / 1 - (1 - c)^2 down, and when the window opens on a silence (the wide band), at most
/// (1 + 2c)(1 + c)^2 - 1 up / 1 - (1 - 2c)(1 - c)^2 down: the wide step, a further cap inside its epoch, and one more cap from
/// the epoch that opens exactly maxAge later. The rule is unchanged (per-epoch statements held); the stated bound was wrong.
/// Production price policy: 1 h, 2,000 bps.
contract AuditW4SlidingBoundTest is Test {
    uint256 constant C = 2000;
    DoorLeaf leaf;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        leaf = new DoorLeaf();
        leaf.set(1e18);
    }

    function _stored() internal view returns (uint256 v) {
        (v,) = leaf.latestValue();
    }

    /// The judge's sequence: T, T + maxAge - 1, T + maxAge after a 2 h silence: 2.016x up and 0.384x down, beyond the old
    /// "(1 + allowance)^2 - 1 once" (1.96x / 0.36x... and the request's per-epoch reading of 1.68x / 0.48x). Asserts the
    /// measured values, which the corrected bound admits exactly.
    function test_judgeSequence_reachesTheCorrectedBoundExactly() public {
        for (uint256 up; up < 2; ++up) {
            leaf = new DoorLeaf();
            leaf.set(1e18);
            vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
            uint256 t = vm.getBlockTimestamp();
            uint256 target = up == 1 ? 100e18 : 1;
            leaf.set(target);
            vm.warp(t + 1 hours - 1);
            leaf.set(target);
            vm.warp(t + 1 hours);
            leaf.set(target);
            assertEq(_stored(), up == 1 ? 2.016e18 : 0.384e18);
        }
    }

    /// PROPERTY (fuzzed over a silence or none, up to 10 deliveries at chosen times inside one closed maxAge window from the
    /// first, any targets): every stored value in the window is within the corrected bound of the value standing at its start.
    function testFuzz_closedWindowBound(bool silent, uint256 seed, uint8 n) public {
        vm.warp(vm.getBlockTimestamp() + (silent ? 2 hours + 1 : 1 hours)); // a fresh epoch either way
        uint256 s0 = _stored();
        uint256 t0 = vm.getBlockTimestamp();
        uint256 hi = silent ? s0 * (10_000 + 2 * C) * (10_000 + C) ** 2 / 1e12 : s0 * (10_000 + C) ** 2 / 1e8;
        uint256 lo = silent ? s0 * (10_000 - 2 * C) * (10_000 - C) ** 2 / 1e12 : s0 * (10_000 - C) ** 2 / 1e8;
        uint256 count = 1 + uint256(n) % 10;
        uint256 t = t0;
        for (uint256 i; i < count; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (i != 0 && i == count - 1 && r % 2 == 0) t = t0 + 1 hours; // often land exactly at the window's far edge
            else if (i != 0) t = t + (r >> 8) % (t0 + 1 hours + 1 - t);
            vm.warp(t);
            leaf.set(r % 3 == 0 ? 1 : r % 3 == 1 ? 1e30 : 1 + (r >> 64) % 3e18);
            uint256 v = _stored();
            assertLe(v, hi + 2, "above the closed-window bound");
            assertGe(v + 2, lo, "below the closed-window bound");
        }
    }
}
