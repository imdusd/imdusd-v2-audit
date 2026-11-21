// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice A review before wave 5b: the reopening CLASS. The wave-5 fixes restarted the instant meter on a
/// list of acts (UNPAUSE, a cap raise, a peer change or inbound raise); every other act that lets a blocked packet run
/// (UNVOID, RELEASE, a hold's expiry, a SET_PATH that only shortens the inbound window) let it run into the full standing
/// allowance: C at once.
/// The class, by lzReceive's revert reasons and what removes each:
///   path level:    OnlyPeer (SET_PATH), PathPaused (UNPAUSE), RateLimited at a closed/shortened limit (SET_PATH),
///                  instant cap 0 (SET_DELAY): every timelocked act on the path restarts the meter empty;
///   payload level: PayloadVoided (UNVOID), OnHold (RELEASE, expiry): a payload the Safe blocked QUEUES when it runs.
///   (Unconfigured cannot return after launch; ZeroAmount/BelowMinimum never; RateLimited at an unchanged limit is the
///   limiter's own refill: the instant cap's normal rate, C per day, applies.)
/// PROPERTY: after any state change after which a packet that reverted can execute, what mints at once is at most
/// C x (time since that change) / 1 day; a payload the Safe held or voided never mints at once (it waits D as a claim).
contract AuditW5BridgeUnblockClassTest is W5Bridge {
    function setUp() public {
        _setUpW5();
        assertTrue(homeEp.deliver(_send(alice, 100e18))); // lazy nonce above 0
        _warp(1 days); // the meter is full again
    }

    function _hash(uint256 i) internal view returns (bytes32) {
        return homeEp.payloadHashOf(i);
    }

    /// UNVOID: a voided payload brought back runs; it must not mint at once.
    function test_unvoidedPayloadQueues() public {
        uint256 f = _forge(5_000e18);
        bytes32 h = _hash(f);
        vm.prank(safe);
        rh.voidPayload(h);
        assertFalse(homeEp.deliver(f));
        _governRh(abi.encode(uint8(11), _hash(f)));
        assertTrue(homeEp.deliver(f));
        assertEq(rhTok.balanceOf(attacker), 0, "an unvoided payload minted at once");
        assertEq(rh.queued(), 5_000e18);
    }

    /// RELEASE with the held hash (48 h, inside the hold): queued, not minted.
    function test_releasedPayloadQueues() public {
        uint256 f = _forge(5_000e18);
        (uint64 n,) = _origin(f);
        vm.prank(safe);
        rh.hold(HOME, n);
        _governRh(abi.encode(uint8(12), HOME, _b32(address(home)), n, _hash(f)));
        assertTrue(homeEp.deliver(f));
        assertEq(rhTok.balanceOf(attacker), 0, "a released payload minted at once");
    }

    /// A hold's expiry (72 h, no human act): queued, not minted.
    function test_expiredHoldQueues() public {
        uint256 f = _forge(5_000e18);
        (uint64 n,) = _origin(f);
        vm.prank(safe);
        rh.hold(HOME, n);
        _warp(72 hours);
        assertTrue(homeEp.deliver(f));
        assertEq(rhTok.balanceOf(attacker), 0, "an auto-released hold minted at once");
        assertEq(rh.queued(), 5_000e18);
    }

    /// A SET_PATH that only shortens the inbound window: packets held back by RateLimited run at once into a full meter.
    function test_windowShorteningRestartsTheMeter() public {
        _governRh(_path(HOME, _b32(address(home)), LIM, LIM)); // (no change: restarts the meter too, then a day passes)
        _warp(1 days);
        (, bool ok) = _forgeRun(LIM); // the inbound limit used up (queued: above C)
        assertTrue(ok);
        uint256 s = _forge(5_000e18);
        assertFalse(homeEp.deliver(s), "RateLimited");
        bytes memory p = abi.encode(uint8(1), HOME, _b32(address(home)), LIM, uint256(1 days), LIM, uint256(1 hours), bytes(""));
        _governRh(p); // inbound window 1 day -> 1 hour: the limit refilled long before the apply
        assertTrue(homeEp.deliver(s));
        assertEq(rhTok.balanceOf(attacker), 0, "a window change let a blocked packet mint at once");
    }

    /// Property, fuzzed over the unblocking route and the time after it: a packet that reverted, run t after the act that
    /// unblocked it, mints at once at most C x t / 1 day (payload-level routes: nothing at once).
    function testFuzz_unblockedPacketWithinTheRate(uint8 route, uint256 t) public {
        route = uint8(bound(route, 0, 5));
        t = bound(t, 0, 2 days);
        uint256 f = _forge(2_000e18);
        (uint64 n,) = _origin(f);
        bytes32 h = _hash(f);
        if (route == 0) {
            vm.prank(safe);
            rh.voidPayload(h);
            assertFalse(homeEp.deliver(f));
            _governRh(abi.encode(uint8(11), _hash(f)));
        } else if (route == 1) {
            vm.prank(safe);
            rh.hold(HOME, n);
            assertFalse(homeEp.deliver(f));
            _governRh(abi.encode(uint8(12), HOME, _b32(address(home)), n, _hash(f)));
        } else if (route == 2) {
            vm.prank(safe);
            rh.hold(HOME, n);
            assertFalse(homeEp.deliver(f));
            _warp(72 hours);
        } else if (route == 3) {
            vm.prank(safe);
            rh.pause(HOME);
            assertFalse(homeEp.deliver(f));
            _warp(1 days);
            _governRh(abi.encode(uint8(5), HOME));
        } else if (route == 4) {
            _governRh(_path(HOME, _b32(address(0xBEEF)), LIM, LIM));
            assertFalse(homeEp.deliver(f));
            _warp(1 days);
            _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        } else {
            vm.prank(safe);
            rh.pause(HOME);
            _governRh(_path(HOME, _b32(address(home)), LIM, 0));
            _governRh(abi.encode(uint8(5), HOME));
            assertFalse(homeEp.deliver(f));
            _warp(1 days);
            _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        }
        _warp(t);
        homeEp.deliver(f);
        uint256 cap = route <= 2 ? 0 : (t >= 1 days ? C : C * t / 1 days);
        assertLe(rhTok.balanceOf(attacker), cap, "a blocked packet minted at once above C x t / 1 day");
    }
}
