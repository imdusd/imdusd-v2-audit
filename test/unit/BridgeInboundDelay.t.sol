// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";
import {Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice The inbound delay: claims, cancels, pause and UNCANCEL.
///  D2 Nothing queued mints before receipt + DELAY; after it ANYONE mints it to the recipient, forever (no expiry).
///  D3 A cancelled claim never mints until the timelock's UNCANCEL; cancelling is the governor's alone and instant; a
///     paused path refuses claims (one signature round stops every claim on it).
///  D4 Every pending claim past DELAY on an open, untripped path is claimable (honest transfers are never lost unless
///     cancelled).
///  D7 Supply: `received` counts at claim; `queued` = Σ pending; the limiter is metered at receipt and never refunded.
///  D8 A claim is keyed by its origin's GUID, not the packet's guid field: a forger cannot take or block an honest key.
contract BridgeInboundDelayTest is W4Bridge {
    /// @dev The harness's limit per path (the launch value); C and D are read from the bridge, never
    /// hard-coded: C = DELAY_THRESHOLD (the instant cap), D = DELAY.
    uint256 constant L = 50_000e18;
    uint256 C;
    uint256 D;
    uint256 big; // one message above the cap: always queued

    event Queued(
        bytes32 indexed guid,
        uint32 indexed srcEid,
        address indexed to,
        uint256 amount,
        uint64 nonce,
        uint256 claimableAt
    );
    event Claimed(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount);
    event ClaimCancelled(bytes32 indexed guid, uint32 indexed srcEid);
    event ClaimRestored(bytes32 indexed guid, uint32 indexed srcEid);

    function setUp() public {
        _setUpW4();
        _openBoth(L);
        (C, D) = (rh.DEFAULT_INSTANT_CAP(), rh.DEFAULT_DELAY());
        big = C + 1_000e18;
    }

    function _key(uint256 i) internal view returns (bytes32) {
        return _claimKey(homeEp, i);
    }

    function _claimAs(address who, uint256 i) internal {
        bytes32 k = _key(i); // before the prank: _key is an external call
        vm.prank(who);
        rh.claim(HOME, k);
    }

    function test_constants() public view {
        assertEq(rh.DEFAULT_INSTANT_CAP(), 5_000e18, "the launch value");
        assertEq(rh.DEFAULT_DELAY(), 12 hours, "the launch value");
        assertLt(rh.DEFAULT_DELAY(), rh.TIMELOCK(), "an early release would never beat waiting");
    }

    /// D2 + events: Queued at receipt (before anything is spendable), Claimed by a stranger after DELAY.
    function test_honestLargeTransferClaimableByAnyoneAfterDelay() public {
        uint256 i = _send(alice, big);
        (uint64 n,) = _origin(i);
        bytes32 k = _key(i);
        vm.expectEmit(address(rh));
        emit Queued(k, HOME, alice, big, n, vm.getBlockTimestamp() + D);
        assertTrue(homeEp.deliver(i));
        (address to, uint48 sd, uint40 queuedAt, uint8 state) = rh.claims(HOME, k);
        uint256 at = uint256(queuedAt) + D; // claimable at queuedAt + the path's delay (governable)
        assertEq(to, alice);
        assertEq(uint256(sd) * 1e12, big);
        assertEq(queuedAt, vm.getBlockTimestamp());
        assertEq(state, 1);
        assertEq(rh.queued(), big);
        assertEq(rh.received(), 0, "received counts at claim");
        vm.warp(vm.getBlockTimestamp() + D - 1);
        {
            bytes32 kk = _key(i);
            vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotClaimable.selector, HOME, k, at));
            vm.prank(makeAddr("bot"));
            rh.claim(HOME, kk);
        }
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(address(rh));
        emit Claimed(k, HOME, alice, big);
        _claimAs(makeAddr("bot"), i);
        assertEq(rhTok.balanceOf(alice), big, "minted to the recipient, whoever claims");
        assertEq(rh.queued(), 0);
        assertEq(rh.received(), big);
        assertEq(rhTok.totalSupply(), rh.received() - rh.sent(), "supply == received - sent (token-only harness)");
        {
            bytes32 kk = _key(i);
            vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotClaimable.selector, HOME, k, at));
            vm.prank(alice);
            rh.claim(HOME, kk); // once
        }
    }

    /// D2/D4: no expiry: a claim left for a year still mints.
    function test_claimNeverExpires() public {
        uint256 i = _send(alice, big);
        assertTrue(homeEp.deliver(i));
        vm.warp(vm.getBlockTimestamp() + 400 days);
        _claimAs(alice, i);
        assertEq(rhTok.balanceOf(alice), big);
    }

    /// D3: the Safe cancels a forgery inside DELAY; it never mints, even long after; the inbound limit stays spent.
    function test_safeCancelsForgedClaim() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 i = _forge(2 * C);
        assertTrue(homeEp.deliver(i));
        bytes32 k = _key(i);
        vm.prank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.cancelClaim(HOME, k);
        vm.expectEmit(address(rh));
        emit ClaimCancelled(k, HOME);
        vm.prank(safe);
        rh.cancelClaim(HOME, k);
        assertEq(rh.queued(), 0);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        {
            bytes32 kk = _key(i);
            vm.expectRevert(
                abi.encodeWithSelector(ImdBridge.NotClaimable.selector, HOME, k, t0 + D)
            );
            vm.prank(attacker);
            rh.claim(HOME, kk);
        }
        assertEq(rhTok.balanceOf(attacker), 0);
        vm.prank(safe);
        rh.cancelClaim(HOME, k); // not pending any more: a no-op (a review of the wave-5 fixes)
        (,,, uint8 st) = rh.claims(HOME, k);
        assertEq(st, 3, "still cancelled");
    }

    /// D3: cancelling even after DELAY works while nobody has claimed (the Safe was slow but the forger was slower).
    function test_cancelAfterDelayBeforeClaim() public {
        uint256 i = _forge(big);
        assertTrue(homeEp.deliver(i));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        {
            bytes32 kk = _key(i);
            vm.prank(safe);
            rh.cancelClaim(HOME, kk);
        }
        {
            bytes32 kk = _key(i);
            vm.expectRevert();
            vm.prank(attacker);
            rh.claim(HOME, kk);
        }
    }

    /// D3: a pause stops every claim on the path at once; claims run again after the timelocked UNPAUSE.
    function test_pauseBlocksClaimsUntilUnpaused() public {
        assertTrue(homeEp.deliver(_send(alice, C))); // uses the instant allowance, so both below queue
        uint256 h = _send(alice, big);
        // the next nonce; with h, all the inbound limit leaves after the instant part (L - C), under QUEUE_BREAKER, so the
        // breaker stays open and only the pause stops the claims (the breaker is BridgeBreaker's)
        uint256 f = _forge(L - C - big);
        assertTrue(homeEp.deliver(f));
        assertTrue(homeEp.deliver(h));
        assertLe(rh.queued(), rh.DEFAULT_QUEUE_BREAKER());
        (,, bool tripped,,,,) = rh.breakers(HOME);
        assertFalse(tripped);
        vm.prank(safe);
        rh.pause(HOME);
        vm.warp(vm.getBlockTimestamp() + D);
        {
            bytes32 kk = _key(h);
            vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathPaused.selector, HOME));
            vm.prank(alice);
            rh.claim(HOME, kk);
        }
        {
            bytes32 kk = _key(f);
            vm.prank(safe);
            rh.cancelClaim(HOME, kk); // at leisure while paused
        }
        _govern(rh, abi.encode(uint8(5), HOME)); // UNPAUSE, 48h
        _claimAs(makeAddr("anyone"), h);
        assertEq(rhTok.balanceOf(alice), C + big, "the honest claim survived the pause");
        {
            bytes32 kk = _key(f);
            vm.expectRevert();
            vm.prank(attacker);
            rh.claim(HOME, kk);
        }
    }

    /// D3: UNCANCEL is timelocked, only for a cancelled claim, and restores it claimable.
    function test_uncancelRestoresThroughTheTimelock() public {
        uint256 i = _send(alice, big);
        assertTrue(homeEp.deliver(i));
        bytes32 k = _key(i);
        bytes memory p = abi.encode(uint8(13), HOME, k);
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector); // still pending: nothing to restore
        rh.propose(p);
        vm.prank(safe);
        rh.cancelClaim(HOME, k); // a mistake
        vm.prank(safe);
        rh.propose(p);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        rh.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(address(rh));
        emit ClaimRestored(k, HOME);
        rh.applyPending();
        assertEq(rh.queued(), big);
        _claimAs(makeAddr("anyone"), i);
        assertEq(rhTok.balanceOf(alice), big);
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector); // claimed: nothing to restore
        rh.propose(p);
    }

    /// D7: the limiter is metered at receipt, so it bounds what can queue; a cancel does not refund it.
    function test_limitBoundsTheQueue() public {
        assertTrue(homeEp.deliver(_forge(L - 2 * C)));
        uint256 j = _forge(2 * C + 1_000e18);
        assertFalse(homeEp.deliver(j), "RateLimited: over the inbound limit");
        {
            bytes32 kk = _key(0);
            vm.prank(safe);
            rh.cancelClaim(HOME, kk);
        }
        assertFalse(homeEp.deliver(j), "a cancel does not free the limit");
        assertEq(rh.availableIn(HOME), 2 * C);
    }

    /// The instant allowance: shared by every message on the path, refilled at C a day; what does not fit waits.
    function test_instantAllowanceDecays() public {
        uint256 first = C * 3 / 4;
        assertTrue(homeEp.deliver(_send(alice, first)));
        assertEq(rh.availableInstant(HOME), C - first);
        uint256 more = C - first + 100e18; // fits the limit, not the allowance
        uint256 i = _send(alice, more);
        assertTrue(homeEp.deliver(i));
        assertEq(rhTok.balanceOf(alice), first);
        assertEq(rh.queued(), more);
        vm.warp(vm.getBlockTimestamp() + 12 hours); // half a window refills C / 2
        assertEq(rh.availableInstant(HOME), C / 4 + C / 2);
        assertTrue(homeEp.deliver(_send(alice, C / 4 + C / 2)));
        assertEq(rhTok.balanceOf(alice), first + C / 4 + C / 2);
        assertEq(rh.availableInstant(HOME), 0);
    }

    /// D8: the forged packets carry a guid field that is not their origin's GUID; their claims sit at the origin's key,
    /// and a forged packet carrying an honest message's GUID cannot pre-empt or overwrite that honest claim.
    function test_keyIsTheOriginGuidNotThePacketField() public {
        uint256 h = _send(alice, big); // nonce 1
        bytes32 honestKey = _key(h);
        (,,,, bytes32 field,,,) = homeEp.packets(h);
        assertEq(field, honestKey, "an honest packet's guid field is its origin GUID");
        // a forgery at the next nonce whose packet carries the HONEST message's GUID in its guid field, verified and run
        // straight on the endpoint stand-in (EndpointV2.verify by the compromised DVNs, then the permissionless lzReceive)
        Origin memory o = Origin(HOME, _b32(address(home)), 2);
        bytes memory m = _msg(attacker, big + 1_000e18);
        rhEp.verify(o, address(rh), keccak256(abi.encodePacked(honestKey, m)));
        rhEp.lzReceive(o, address(rh), honestKey, m, "");
        bytes32 forgedKey = keccak256(abi.encodePacked(uint64(2), HOME, _b32(address(home)), RH, _b32(address(rh))));
        (address fto,,, uint8 s) = rh.claims(HOME, forgedKey);
        assertEq(fto, attacker);
        assertEq(s, 1);
        (,,, s) = rh.claims(HOME, honestKey);
        assertEq(s, 0, "the forgery did not take the honest key");
        assertTrue(homeEp.deliver(h));
        (address to,,,) = rh.claims(HOME, honestKey);
        assertEq(to, alice, "the honest claim sits at its own key");
    }

    /// Hold + delay: a held large message waits HOLD_TIME, then executes for anyone and queues like any other.
    function test_heldThenQueued() public {
        uint256 i = _send(alice, big);
        (uint64 n,) = _origin(i);
        vm.prank(safe);
        rh.hold(HOME, n);
        assertFalse(homeEp.deliver(i));
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        assertTrue(homeEp.deliver(i));
        assertEq(rh.queued(), big);
        vm.warp(vm.getBlockTimestamp() + D);
        _claimAs(makeAddr("anyone"), i);
        assertEq(rhTok.balanceOf(alice), big);
    }

    /// A voided payload never reaches the queue (P2 unchanged).
    function test_voidedNeverQueues() public {
        uint256 f = _forge(big);
        bytes32 h = homeEp.payloadHashOf(f);
        vm.prank(safe);
        rh.voidPayload(h);
        assertFalse(homeEp.deliver(f));
        assertEq(rh.queued(), 0);
    }

    /// Fuzz D2/D3/D4/D7 on one path: random amounts, cancels and waits; every pending claim past DELAY claims, no
    /// cancelled one ever does, and queued == Σ pending.
    function testFuzz_claimLifecycle(uint256 seed) public {
        uint256[] memory idx = new uint256[](8);
        bool[] memory cancelled = new bool[](8);
        uint256 pending;
        for (uint256 k; k < 8; ++k) {
            seed = uint256(keccak256(abi.encode(seed)));
            vm.warp(vm.getBlockTimestamp() + seed % 4 hours);
            uint256 a = (C + 1e18 + (seed >> 32) % C) / 1e12 * 1e12; // above the cap: always queued
            idx[k] = (seed >> 128) % 2 == 0 && home.availableOut(RH) >= a ? _send(alice, a) : _forge(a);
            if (!homeEp.deliver(idx[k])) {
                idx[k] = type(uint256).max;
                continue;
            }
            pending += a;
            if ((seed >> 200) % 3 == 0) {
                bytes32 kk = _key(idx[k]);
                vm.prank(safe);
                rh.cancelClaim(HOME, kk);
                cancelled[k] = true;
                pending -= a;
            }
            assertEq(rh.queued(), pending);
        }
        vm.warp(vm.getBlockTimestamp() + D);
        // B2: past QUEUE_BREAKER the path tripped; the timelocked reset of that trip resumes every claim
        (, uint16 trips, bool tripped,,,,) = rh.breakers(HOME);
        if (tripped) {
            // audit wave 5: the reset is accepted on a paused path; UNPAUSE in the same BATCH
            vm.prank(safe);
            rh.pause(HOME);
            bytes[] memory items = new bytes[](2);
            (items[0], items[1]) = (abi.encode(uint8(14), HOME, uint256(trips)), abi.encode(uint8(5), HOME));
            _govern(rh, abi.encode(uint8(6), items));
        }
        for (uint256 k; k < 8; ++k) {
            if (idx[k] == type(uint256).max) continue;
            bytes32 kc = _key(idx[k]);
            vm.prank(makeAddr("anyone"));
            try rh.claim(HOME, kc) {
                assertFalse(cancelled[k], "a cancelled claim minted");
            } catch {
                assertTrue(cancelled[k], "a pending claim past DELAY could not be claimed");
            }
        }
        assertEq(rh.queued(), 0);
        assertEq(rhTok.totalSupply(), rh.received());
    }
}
