// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice A review of the wave-5 fixes (of the clamped-tighten fix): that fix made `tighten` and `cancel()` impossible
/// to revert by a stranger, but `cancelClaim` reverted once anyone claimed the claim, and `hold` once anyone executed the
/// held nonce (both permissionless). In a Safe MultiSend [cancelClaim(..)/hold(..), pause()], the stranger's transaction
/// reverted the pause with them.
/// PROPERTY (P3): none of the Safe's instant acts (pause, tighten, cancel, cancelClaim, hold, voidPayload, tripBreaker) can
/// be reverted by another account's transaction: an act whose target already moved on does nothing, so a batch of them
/// always lands.
contract AuditW5BridgeIncidentBatchTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    /// The reviewer's case: the forger claims at maturity just before the Safe's [cancelClaim, pause].
    function test_strangerClaimDoesNotRevertTheBatch() public {
        (uint256 i, bool ok) = _forgeRun(6_000e18); // above C: queued
        assertTrue(ok);
        bytes32 k = _claimKey(homeEp, i);
        _warp(D);
        assertTrue(_tryClaim(i));
        vm.startPrank(safe);
        rh.cancelClaim(HOME, k); // already claimed: nothing to do
        rh.pause(HOME);
        vm.stopPrank();
        assertTrue(rh.paused(HOME));
        (,,, uint8 st) = rh.claims(HOME, k);
        assertEq(st, 2, "still claimed: the no-op changed nothing");
    }

    /// The same for hold: a stranger executes the nonce (or it was held before) just before the Safe's [hold, pause].
    function test_strangerExecuteDoesNotRevertTheBatch() public {
        uint256 i = _forge(100e18);
        (uint64 n,) = _origin(i);
        assertTrue(homeEp.deliver(i)); // executed by anyone first
        vm.startPrank(safe);
        rh.hold(HOME, n); // nothing stored there any more
        rh.hold(HOME, n + 7); // nothing ever stored
        rh.pause(HOME);
        vm.stopPrank();
        assertTrue(rh.paused(HOME));
        (, uint64 until) = rh.holds(HOME, _b32(address(home)), n);
        assertEq(until, 0, "no hold recorded on an executed nonce");
    }

    /// A second hold on the same nonce does nothing (never renews: H4 holds) instead of reverting.
    function test_secondHoldIsANoOp() public {
        uint256 i = _forge(100e18);
        (uint64 n,) = _origin(i);
        vm.prank(safe);
        rh.hold(HOME, n);
        (, uint64 until) = rh.holds(HOME, _b32(address(home)), n);
        _warp(1 days);
        vm.prank(safe);
        rh.hold(HOME, n);
        (, uint64 until2) = rh.holds(HOME, _b32(address(home)), n);
        assertEq(until2, until, "a hold was renewed");
    }

    /// Property, fuzzed: whatever a stranger did to the claim first (nothing, claim, or the Safe's own earlier cancel), the
    /// Safe's [cancelClaim, hold, tighten, pause] lands and the path ends paused.
    function testFuzz_batchAlwaysLands(uint8 before) public {
        (uint256 i, bool ok) = _forgeRun(6_000e18);
        assertTrue(ok);
        bytes32 k = _claimKey(homeEp, i);
        (uint64 n,) = _origin(i);
        _warp(D);
        before = uint8(bound(before, 0, 2));
        if (before == 1) _tryClaim(i);
        if (before == 2) {
            vm.prank(safe);
            rh.cancelClaim(HOME, k);
        }
        vm.startPrank(safe);
        rh.cancelClaim(HOME, k);
        rh.hold(HOME, n);
        rh.tighten(HOME, 0, D, B, uint40(vm.getBlockTimestamp()));
        rh.cancel();
        rh.pause(HOME);
        vm.stopPrank();
        assertTrue(rh.paused(HOME));
    }
}
