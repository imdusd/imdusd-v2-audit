// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";

/// @notice Wave-5 audit 74838ad4, MEDIUM 1 (judge; flow, economics, math): anyone could make the Safe's instant tighten revert
/// NotTighter by applying a matured SET_DELAY just before it (applyPending is permissionless), and Governed.cancel() reverted
/// NothingPending once that proposal was applied, so a Safe batch [cancel(), tighten()/pause()] reverted the same way.
/// PROPERTY (P3): the Safe's instant incident act (tighten to C 0 with a cutoff, pause, with or without a cancel() of the
/// pending proposal in the same batch) cannot be reverted by anyone else's transaction: whatever the path's settings are
/// when it lands, it lands, and the result is at least as tight as both what it names and what stood before.
contract AuditW5BridgeTightenRaceTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    /// The auditor's sequence: a routine lowering of B (SET_DELAY) matures; a forged 20,000 queues; inside D the forger
    /// applies the SET_DELAY just before the Safe's bulk cancel. The Safe's act must land and nothing forged may mint.
    function test_appliedSetDelayCannotRevertTheSafesTighten() public {
        _proposeRh(_setDelayP(C, D, 20_000e18, 0));
        _warp(48 hours);
        (, bool ok) = _forgeRun(20_000e18); // above C: queued
        assertTrue(ok);
        uint256 f = homeEp.packetCount() - 1;
        uint40 t0 = uint40(vm.getBlockTimestamp());
        _warp(11 hours);
        vm.prank(attacker);
        rh.applyPending(); // B becomes 20,000 just before the Safe's transaction
        vm.prank(safe);
        rh.tighten(HOME, 0, D, B, t0); // signed against B 50,000: must still land
        _warp(30 days);
        assertFalse(_tryClaim(f), "a forged claim minted although the Safe tightened within D");
        assertEq(rhTok.balanceOf(attacker), 0);
        (uint256 breaker,, uint40 cut,,,) = _brk();
        assertEq(breaker, 20_000e18, "the tighter of the two breakers stands");
        assertEq(cut, t0);
        assertEq(_cap(), 0);
    }

    /// The same front-run against a Safe batch that starts with cancel() (the README's incident order).
    function test_cancelInAnIncidentBatchCannotBeReverted() public {
        _proposeRh(_setDelayP(C, 1 days, B, 0));
        _warp(48 hours);
        vm.prank(attacker);
        rh.applyPending(); // nothing pending any more
        vm.startPrank(safe);
        rh.cancel(); // the batch's first call: must not revert
        rh.tighten(HOME, 0, D, B, uint40(vm.getBlockTimestamp())); // delay 12 h < 1 day now: clamped, not reverted
        rh.cancel();
        rh.pause(HOME);
        vm.stopPrank();
        (, uint256 delay,,,,) = _brk();
        assertEq(delay, 1 days, "the longer delay stands");
        assertTrue(rh.paused(HOME));
    }

    /// Property, fuzzed: from any valid settings (C, D, B, cutoff), a tighten with ANY arguments lands, bumps the version
    /// and leaves each field at the tighter of the two (cap and breaker min, delay max within MAX_DELAY, cutoff the earlier
    /// non-zero one).
    function testFuzz_tightenAlwaysLandsAtTheTighterOfBoth(
        uint256 cap0,
        uint256 d0,
        uint256 b0,
        uint40 cut0,
        uint256 capA,
        uint256 dA,
        uint256 bA,
        uint40 cutA
    ) public {
        cap0 = bound(cap0, 0, 1e9) * 1e18;
        b0 = bound(b0, 0, 1e9) * 1e18;
        d0 = bound(d0, rh.MIN_DELAY(), rh.MAX_DELAY());
        _governRh(_setDelayP(cap0, d0, b0, cut0));
        uint16 v0 = _version();
        vm.prank(safe);
        rh.tighten(HOME, capA, dA, bA, cutA);
        (uint256 breaker, uint256 delay, uint40 cut, uint16 v,,) = _brk();
        assertEq(v, v0 + 1, "version bumped");
        assertEq(_cap(), _min(capA / 1e12, cap0 / 1e12) * 1e12, "cap = the lower");
        assertEq(breaker, _min(bA / 1e12, b0 / 1e12) * 1e12, "breaker = the lower");
        assertEq(delay, _max(_min(dA, rh.MAX_DELAY()), d0), "delay = the longer, within MAX_DELAY");
        uint40 want = cut0 == 0 ? cutA : (cutA == 0 || cutA > cut0 ? cut0 : cutA);
        assertEq(cut, want, "cutoff = the earlier non-zero one");
    }

    /// Property, fuzzed: whatever SET_DELAY a stranger applies in front of it (any direction), the Safe's tighten lands.
    function testFuzz_noFrontRunRevertsTheTighten(uint256 capP, uint256 dP, uint256 bP, uint40 cutP) public {
        capP = bound(capP, 0, 1e9) * 1e18;
        bP = bound(bP, 0, 1e9) * 1e18;
        dP = bound(dP, rh.MIN_DELAY(), rh.MAX_DELAY());
        _proposeRh(_setDelayP(capP, dP, bP, cutP));
        _warp(48 hours);
        vm.prank(attacker);
        rh.applyPending();
        uint40 now_ = uint40(vm.getBlockTimestamp());
        vm.startPrank(safe);
        rh.cancel();
        rh.tighten(HOME, 0, D, B, now_);
        vm.stopPrank();
        assertEq(_cap(), 0);
        (,, uint40 cut,,,) = _brk();
        assertTrue(cut != 0 && cut <= now_, "the cutoff stands at or before the Safe's");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
