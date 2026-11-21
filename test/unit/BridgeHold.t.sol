// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice Bridge-local holds, no guardian. Properties:
///  H1 a forged payload under hold or void never executes;
///  H2 an honest message is never lost: a hold delays it at most HOLD_TIME and then anyone executes it, with no DVN or
///     governance action, unless its payload changed or the Safe voided it (since a review before wave 5b it then runs as a claim:
///     anyone claims it after the path's delay D; a held payload never mints at once);
///  H3 no instant act opens or releases anything (only delay or permanent void by the governor; RELEASE/UNVOID/UNPAUSE are
///     timelocked);
///  H4 a hold cannot be renewed past HOLD_TIME for the same nonce.
/// On the mock endpoint (EndpointV2's channel rules); the endpoint facts these rely on are proven on the real EndpointV2 in
/// test/fork/AuditW4BridgeEndpoint.t.sol.
contract BridgeHoldTest is W4Bridge {
    uint256 constant T = 72 hours;

    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function _hold(uint256 i) internal returns (uint64 n) {
        (n,) = _origin(i);
        vm.prank(safe);
        rh.hold(HOME, n);
    }

    /// @dev Since a review before wave 5b: a payload the Safe held runs as a claim (never at once); anyone claims it after the path's delay.
    function _claimLater(uint256 i) internal {
        vm.warp(vm.getBlockTimestamp() + rh.DEFAULT_DELAY());
        bytes32 k = _claimKey(homeEp, i);
        vm.prank(makeAddr("anyone"));
        rh.claim(HOME, k);
    }

    function _release(uint256 i, bytes32 h) internal {
        (uint64 n, bytes32 sender) = _origin(i);
        _govern(rh, abi.encode(uint8(12), HOME, sender, n, h));
    }

    // ---------------------------------------------------------------- H1

    function test_H1_heldForgeryDoesNotExecuteAndAVoidKeepsItDead() public {
        uint256 f = _forge(5_000e18);
        _hold(f);
        assertFalse(homeEp.deliver(f), "held forgery executed");
        bytes32 fh = homeEp.payloadHashOf(f);
        vm.prank(safe);
        rh.voidPayload(fh);
        vm.warp(vm.getBlockTimestamp() + T + 1);
        assertFalse(homeEp.deliver(f), "voided forgery executed after the hold");
        assertTrue(homeEp.reverify(f));
        assertFalse(homeEp.deliver(f), "voided forgery executed after re-verification");
        assertEq(rhTok.balanceOf(attacker), 0);
    }

    /// A forged re-verify OVER a held honest payload never runs by itself: the held hash no longer matches.
    function test_H1_overwriteDuringAHoldNeverAutoReleases() public {
        uint256 h = _send(alice, 100e18);
        uint64 n = _hold(h);
        uint256 f = homeEp.forgeAt(RH, _b32(address(rh)), _b32(address(home)), _msg(attacker, 5_000e18), n);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertFalse(homeEp.deliver(f), "overwriting forgery executed after the hold");
        assertEq(rhTok.balanceOf(attacker), 0);
        // H2: honest DVNs verify the held payload back: it runs, nobody else needed
        assertTrue(homeEp.reverify(h));
        assertTrue(homeEp.deliver(h));
        _claimLater(h);
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    // ---------------------------------------------------------------- H2

    function testFuzz_H2_heldHonestMessageRunsAfterHoldTimeByAnyone(uint256 dt, address anyone) public {
        dt = bound(dt, 0, 400 days);
        uint256 h = _send(alice, 100e18);
        _hold(h);
        uint256 placed = vm.getBlockTimestamp();
        vm.warp(placed + T - 1);
        assertFalse(homeEp.deliver(h), "ran inside the hold");
        vm.warp(placed + T + dt);
        vm.prank(anyone);
        assertTrue(homeEp.deliver(h), "not executable at HOLD_TIME");
        _claimLater(h); // a review before wave 5b: a held payload queues when it runs
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// A held nonce does not block the nonces after it (lazy nonces), and runs later itself, below lazyInboundNonce.
    function test_H2_aHoldDoesNotBlockLaterNonces() public {
        uint256 h1 = _send(alice, 100e18);
        uint64 n1 = _hold(h1);
        uint256 h2 = _send(alice, 200e18);
        assertTrue(homeEp.deliver(h2), "a later nonce blocked by the hold");
        assertGt(rhEp.lazyInboundNonce(address(rh), HOME, _b32(address(home))), n1);
        vm.warp(vm.getBlockTimestamp() + T);
        assertTrue(homeEp.deliver(h1), "the held nonce below lazy did not run");
        _claimLater(h1); // a review before wave 5b: a held payload queues when it runs
        assertEq(rhTok.balanceOf(alice), 300e18);
    }

    function test_H2_aVoidedHonestMessageComesBackWithUnvoidOnly() public {
        uint256 h = _send(alice, 100e18);
        bytes32 ph = homeEp.payloadHashOf(h);
        _hold(h);
        vm.prank(safe);
        rh.voidPayload(ph);
        vm.warp(vm.getBlockTimestamp() + T);
        assertFalse(homeEp.deliver(h), "voided ran when the hold ended");
        _govern(rh, abi.encode(uint8(11), ph));
        assertTrue(homeEp.deliver(h), "unvoided honest message, no re-verification");
    }

    // ---------------------------------------------------------------- H3

    /// RELEASE is timelocked: proposed, the message still waits; applied, it runs at once, and only with the released hash.
    function test_H3_releaseIsTimelockedAndBindsThePayload() public {
        uint256 h = _send(alice, 100e18);
        _hold(h);
        (uint64 n, bytes32 sender) = _origin(h);
        bytes memory release = abi.encode(uint8(12), HOME, sender, n, homeEp.payloadHashOf(h));
        vm.prank(safe);
        rh.propose(release);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        assertFalse(homeEp.deliver(h), "ran before the RELEASE applied");
        vm.warp(vm.getBlockTimestamp() + 1);
        rh.applyPending();
        assertTrue(homeEp.deliver(h), "released message did not run");
    }

    /// A RELEASE naming another payload lets only that one through (the governance path after an overwrite).
    function test_H3_releaseOfAnotherPayloadAfterAnOverwrite() public {
        uint256 f = _forge(5_000e18);
        uint64 n = _hold(f);
        uint256 h = homeEp.forgeAt(RH, _b32(address(rh)), _b32(address(home)), _msg(alice, 100e18), n); // stand-in: honest
        _release(h, homeEp.payloadHashOf(h));
        assertTrue(homeEp.reverify(f)); // the compromised DVNs put the forgery back
        assertFalse(homeEp.deliver(f), "a payload the RELEASE did not name ran");
        assertTrue(homeEp.reverify(h));
        assertTrue(homeEp.deliver(h));
    }

    /// No instant act reopens: hold, void, pause by the Safe only delay; a hold on a paused path does not let it through.
    function test_H3_noInstantActOpens() public {
        uint256 h = _send(alice, 100e18);
        (uint64 n,) = _origin(h);
        vm.startPrank(safe);
        rh.pause(HOME);
        rh.hold(HOME, n);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + T);
        assertFalse(homeEp.deliver(h), "the path is still paused: no instant act may open it");
        _govern(rh, abi.encode(uint8(5), HOME));
        assertTrue(homeEp.deliver(h));
    }

    function test_H3_onlyTheGovernorHoldsVoidsOrPauses() public {
        uint256 h = _send(alice, 100e18);
        (uint64 n,) = _origin(h);
        bytes32 ph = homeEp.payloadHashOf(h);
        bytes memory release = abi.encode(uint8(12), HOME, _b32(address(home)), n, ph);
        vm.startPrank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.hold(HOME, n);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.voidPayload(ph);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.pause(HOME);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.propose(release);
        vm.stopPrank();
    }

    /// RELEASE only for a nonce that was held, and never of an empty or NIL payload.
    function test_H3_releaseRefusedForANonceNeverHeld() public {
        uint256 h = _send(alice, 100e18);
        (uint64 n, bytes32 sender) = _origin(h);
        bytes memory release = abi.encode(uint8(12), HOME, sender, n, homeEp.payloadHashOf(h));
        vm.startPrank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.propose(release);
        rh.hold(HOME, n);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.propose(abi.encode(uint8(12), HOME, sender, n, bytes32(0)));
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.propose(abi.encode(uint8(12), HOME, sender, n, bytes32(type(uint256).max)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- H4

    /// Since a review of the wave-5 fixes: a second hold is a no-op (never a revert, never a renewal).
    function test_H4_aHoldCannotBeRenewed() public {
        uint256 h = _send(alice, 100e18);
        uint64 n = _hold(h);
        (, uint64 until) = rh.holds(HOME, _b32(address(home)), n);
        vm.prank(safe);
        rh.hold(HOME, n);
        vm.warp(vm.getBlockTimestamp() + T - 1);
        vm.prank(safe);
        rh.hold(HOME, n);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(safe);
        rh.hold(HOME, n);
        (, uint64 until2) = rh.holds(HOME, _b32(address(home)), n);
        assertEq(until2, until, "renewed");
        assertTrue(homeEp.deliver(h));
    }

    function test_H4_noRenewalAfterARelease() public {
        uint256 h = _send(alice, 100e18);
        uint64 n = _hold(h);
        _release(h, homeEp.payloadHashOf(h)); // 48h: still inside the 72h hold
        vm.prank(safe);
        rh.hold(HOME, n); // a no-op (a review of the wave-5 fixes): the released record stands
        (, uint64 u) = rh.holds(HOME, _b32(address(home)), n);
        assertEq(u, 1, "a released hold was renewed");
        assertTrue(homeEp.deliver(h));
    }

    /// Only a payload the endpoint stores can be held: not an unverified, executed or NIL nonce, nor a path with no peer.
    /// Since a review of the wave-5 fixes: such a hold is a no-op (nothing recorded, no event), not a revert.
    function test_holdOnlyAStoredPayload() public {
        vm.startPrank(safe);
        rh.hold(HOME, 1);
        rh.hold(7, 1);
        vm.stopPrank();
        (, uint64 u) = rh.holds(HOME, _b32(address(home)), 1);
        assertEq(u, 0);
        (, u) = rh.holds(7, bytes32(0), 1);
        assertEq(u, 0);
        uint256 h = _send(alice, 100e18);
        assertTrue(homeEp.deliver(h));
        (uint64 n,) = _origin(h);
        vm.prank(safe);
        rh.hold(HOME, n);
        (, u) = rh.holds(HOME, _b32(address(home)), n);
        assertEq(u, 0, "a hold recorded on an executed nonce");
    }

    function test_holdRecordsAndEmits() public {
        uint256 h = _send(alice, 100e18);
        (uint64 n, bytes32 sender) = _origin(h);
        bytes32 ph = homeEp.payloadHashOf(h);
        vm.expectEmit(address(rh));
        emit ImdBridge.HoldPlaced(HOME, sender, n, ph, vm.getBlockTimestamp() + T);
        vm.prank(safe);
        rh.hold(HOME, n);
        (bytes32 held, uint64 until) = rh.holds(HOME, sender, n);
        assertEq(held, ph);
        assertEq(until, vm.getBlockTimestamp() + T);
        assertEq(rh.HOLD_TIME(), T);
    }
}
