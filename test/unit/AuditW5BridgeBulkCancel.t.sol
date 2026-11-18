// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice Bulk cancel: a compromised DVN set signs any number of forged messages, so the Safe needs ONE
/// act that stops every forged claim, whatever their number. The act is the instant `tighten` with a cutoff
/// (`cancelFrom`); the restore is the timelocked SET_DELAY.
///  K1 One governor act, `tighten(srcEid, .., cancelFrom = F)` with F = the first forgery's queue time, makes every claim
///     queued at or after F (and every one queued later) unclaimable, in gas that does not grow with their number.
///  K2 Claims queued before F are untouched; no claim is lost: they all stay pending, and a timelocked SET_DELAY (48h)
///     lifts the cutoff or moves it later; the honest ones then claim, the forged ones the Safe cancelled one by one never
///     do.
///  K3 Only the governor cuts; the instant route only moves the cutoff earlier (never lifts or delays it); a cut bumps the
///     settings version, so a restore proposed before it is refused when applied.
contract AuditW5BridgeBulkCancelTest is W4Bridge {
    uint256 constant L = 50_000e18;
    uint256 C;
    uint256 D;
    uint256 B;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
        (D, B) = (rh.DEFAULT_DELAY(), rh.DEFAULT_QUEUE_BREAKER());
        vm.prank(safe);
        rh.tighten(HOME, 0, D, B, 0); // cap 0: every message queues
    }

    function _cut() internal view returns (uint40 cut, uint16 version) {
        (,,,,, cut, version) = rh.breakers(HOME);
    }

    /// @dev The instant bulk cancel: the cap, delay and breaker as they are, the cutoff `since`.
    function _cancelFrom(uint40 since) internal {
        vm.prank(safe);
        rh.tighten(HOME, 0, D, B, since);
    }

    /// @dev The timelocked restore: SET_DELAY with the same settings and cutoff `cutoff` (0 = none), naming the version.
    function _restore(uint256 cutoff) internal view returns (bytes memory) {
        (, uint16 version) = _cut();
        return abi.encode(uint8(15), HOME, uint256(0), D, B, cutoff, uint256(version));
    }

    function _claimable(uint256 i) internal returns (bool ok) {
        bytes32 k = _claimKey(homeEp, i);
        (ok,) = address(rh).call(abi.encodeWithSignature("claim(uint32,bytes32)", HOME, k));
    }

    /// K1 + K2, fuzzed over the number of forged messages and their spacing.
    function testFuzz_oneActCancelsEveryForgery(uint8 n, uint256 gap) public {
        uint256 count = bound(n, 1, 60);
        gap = bound(gap, 1, 10 minutes);
        uint256 h = _send(alice, 100e18); // honest, before the forgery
        assertTrue(homeEp.deliver(h));
        vm.warp(vm.getBlockTimestamp() + 1);
        uint40 f0 = uint40(vm.getBlockTimestamp());
        uint256[] memory f = new uint256[](count);
        for (uint256 j; j < count; ++j) {
            f[j] = _forge(10e18 + j * 1e18);
            assertTrue(homeEp.deliver(f[j]));
            vm.warp(vm.getBlockTimestamp() + gap);
        }
        _cancelFrom(f0);
        uint256 late = _forge(500e18); // queued after the act: cancelled too
        assertTrue(homeEp.deliver(late));
        vm.warp(vm.getBlockTimestamp() + D + 30 days);
        for (uint256 j; j < count; ++j) {
            assertFalse(_claimable(f[j]), "a forged claim minted after the bulk cancel");
        }
        assertFalse(_claimable(late));
        assertEq(rhTok.balanceOf(attacker), 0);
        assertTrue(_claimable(h), "a claim queued before the cutoff is untouched");
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// K1: the act's gas does not depend on how many claims it cancels (1 or 50, same state otherwise).
    function test_constantGas() public {
        uint40 t = uint40(vm.getBlockTimestamp());
        uint256 snap = vm.snapshotState();
        assertTrue(homeEp.deliver(_forge(10e18)));
        uint256 g1 = _cutGas(t);
        vm.revertToState(snap);
        for (uint256 j; j < 50; ++j) {
            assertTrue(homeEp.deliver(_forge(10e18)));
        }
        uint256 g50 = _cutGas(t);
        assertApproxEqAbs(g50, g1, 100, "O(1) in the number of claims (a few gas of harness noise)");
    }

    function _cutGas(uint40 t) internal returns (uint256 g) {
        vm.prank(safe);
        g = gasleft();
        rh.tighten(HOME, 0, D, B, t);
        g -= gasleft();
    }

    /// K2: honest claims after the cutoff are restorable; forged ones cancelled one by one stay dead.
    function test_restoreThroughTheTimelock() public {
        uint256 h = _send(alice, 700e18); // an honest transfer, delivered after the forgery: caught by the cut
        uint256 f = _forge(1_000e18);
        assertTrue(homeEp.deliver(f));
        uint40 f0 = uint40(vm.getBlockTimestamp());
        vm.warp(f0 + 1 hours);
        assertTrue(homeEp.deliver(h));
        _cancelFrom(f0);
        vm.warp(f0 + D + 2 hours);
        bytes32 hk = _claimKey(homeEp, h);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.CancelledSince.selector, HOME, f0));
        rh.claim(HOME, hk);
        // the Safe cancels the forgery itself at leisure, then restores the path's claims (48h)
        bytes32 fk = _claimKey(homeEp, f);
        vm.prank(safe);
        rh.cancelClaim(HOME, fk);
        bytes memory lift = _restore(0);
        vm.prank(safe);
        rh.propose(lift);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        rh.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        rh.applyPending();
        rh.claim(HOME, hk);
        assertEq(rhTok.balanceOf(alice), 700e18);
        vm.expectRevert();
        rh.claim(HOME, fk);
        assertEq(rhTok.balanceOf(attacker), 0);
    }

    /// K3: only the governor; instantly only earlier; a cut refuses a restore proposed before it.
    function test_rules() public {
        vm.prank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.tighten(HOME, 0, D, B, 1);
        uint40 t = uint40(vm.getBlockTimestamp());
        _cancelFrom(t);
        vm.startPrank(safe);
        vm.expectRevert(ImdBridge.NotTighter.selector);
        rh.tighten(HOME, 0, D, B, t + 5); // later: a loosening
        vm.expectRevert(ImdBridge.NotTighter.selector);
        rh.tighten(HOME, 0, D, B, 0); // lifting: a loosening
        rh.tighten(HOME, 0, D, B, t); // the same: allowed (no change)
        rh.tighten(HOME, 0, D, B, t - 5); // earlier: tighter
        vm.stopPrank();
        (uint40 cut,) = _cut();
        assertEq(cut, t - 5);
        bytes memory later = _restore(t + 100);
        vm.prank(safe);
        rh.propose(later);
        _cancelFrom(t - 10); // a cut in between: the pending restore is refused when applied
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.applyPending();
        (cut,) = _cut();
        assertEq(cut, t - 10);
    }
}
