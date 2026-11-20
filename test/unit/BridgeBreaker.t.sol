// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice The queue circuit breaker.
///  B1 With no human action a forged stream makes at most 4C + QUEUE_BREAKER spendable on a path in any 72 h (the fuzzed
///     bound is AuditW5BridgeBreakerProps; here the mechanism): past QUEUE_BREAKER queued within the breaker window (the
///     current UTC day and the BREAKER_DAYS - 1 before it) the path trips and no claim runs. With QUEUE_BREAKER 50,000
///     (whales) that bound is 70,000, above the 4663 line by decision (AuditW4BridgeInLimitLine).
/// Amounts derive from QUEUE_BREAKER and DELAY_THRESHOLD. The inbound limit (L, 50,000/day) lets at most L in flight at
/// once, so queueing past QUEUE_BREAKER (= L) takes two messages GAP apart inside the same breaker window
/// (`_queuePast`).
///  B2 Honest claims are never lost: a tripped path's claims resume after the timelocked RESET_BREAKER, with no expiry.
///  B3 Nobody resets the breaker instantly: only RESET_BREAKER (48h), naming the trip it releases.
/// Normal use below the breaker is unchanged (the delay's own tests run with it in place).
contract BridgeBreakerTest is W4Bridge {
    uint256 constant L = 50_000e18;
    uint256 C;
    uint256 B;
    uint256 D;
    uint256 constant GAP = 12 hours; // half the limit's 1-day window: half of L has decayed, the same UTC day

    event BreakerTripped(uint32 indexed srcEid, uint256 trip, address by);
    event BreakerReset(uint32 indexed srcEid, uint256 trip);

    function setUp() public {
        _setUpW4();
        _openBoth(L);
        (C, B, D) = (rh.DEFAULT_INSTANT_CAP(), rh.DEFAULT_QUEUE_BREAKER(), rh.DEFAULT_DELAY());
        // start at a UTC midnight so day arithmetic in these tests is exact
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
    }

    function _reset(uint256 trip) internal returns (bytes memory p) {
        p = abi.encode(uint8(14), HOME, trip);
    }

    function _tripped() internal view returns (bool t) {
        (,, t,,,,) = rh.breakers(HOME);
    }

    function _trips() internal view returns (uint256 n) {
        (, n,,,,,) = rh.breakers(HOME);
    }

    function _claim(uint256 i) internal {
        bytes32 k = _claimKey(homeEp, i);
        vm.prank(makeAddr("anyone"));
        rh.claim(HOME, k);
    }

    /// @dev Forge and deliver `rest` (> 2C) of queued imdUSD in two messages GAP apart (each above the instant cap, so
    /// queued whole; each fits the inbound limit), returning both packet indexes.
    function _queueSplit(uint256 rest) internal returns (uint256 a, uint256 b) {
        uint256 first = rest / 2 / 1e18 * 1e18;
        a = _forge(first);
        assertTrue(homeEp.deliver(a));
        vm.warp(vm.getBlockTimestamp() + GAP);
        b = _forge(rest - first);
        assertTrue(homeEp.deliver(b));
    }

    /// @dev Queue enough forged imdUSD that, with `already` queued in the window, the total is one unit past QUEUE_BREAKER.
    function _queuePast(uint256 already) internal returns (uint256 a, uint256 b) {
        (a, b) = _queueSplit(B - already + 1e18);
    }

    function _cancel(uint256 i) internal {
        bytes32 k = _claimKey(homeEp, i);
        vm.prank(safe);
        rh.cancelClaim(HOME, k);
    }

    function test_constants() public view {
        // 10,000 -> 50,000 so whales' large transfers flow; the no-action 72 h bound is then
        // 4C + 50,000 = 70,000 > the 4663 line (30,000), accepted: the line holds when the Safe acts within DELAY
        assertEq(B, 50_000e18, "50,000 (whales; Safe within DELAY holds the line)");
        assertLe(rh.HOLD_TIME(), (uint256(4) - 1) * 1 days, "a HOLD_TIME span of queue times fits the window");
    }

    /// Exactly QUEUE_BREAKER queued does not trip (normal use below it is unchanged); one unit more does, by the bridge.
    /// Day 0 and day 1 of one window (the inbound limit lets at most L = B in flight, so B is reached across two days).
    function test_tripsOnlyPastTheBreaker() public {
        assertTrue(homeEp.deliver(_forge(B - 2 * C))); // above the instant cap: queued whole
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(homeEp.deliver(_forge(2 * C))); // queued whole: B exactly within the window
        assertEq(rh.queued(), B);
        assertFalse(_tripped());
        assertTrue(homeEp.deliver(_forge(C))); // the instant part: not counted
        assertFalse(_tripped());
        uint256 i = _forge(10e18); // the instant allowance is used up: queued
        vm.expectEmit(address(rh));
        emit BreakerTripped(HOME, 1, address(rh));
        assertTrue(homeEp.deliver(i), "the message still queues: only claims stop");
        assertTrue(_tripped());
        assertEq(rh.queued(), B + 10e18);
    }

    /// The window is the current UTC day and the 3 before (amounts above the instant cap, so each queues whole; each one
    /// day or more apart, so each fits the inbound limit): with a = 3B/5 (30,000), B - a + C (25,000) on day 0 and a on
    /// day 4 does not trip (day 0 fell out; together they are past B); a on day 4 and B - a + 1 (20,001) on day 7 does.
    function test_windowIsFourUtcDays() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 a = B * 3 / 5;
        assertTrue(homeEp.deliver(_forge(B - a + C)));
        vm.warp(t0 + 4 days);
        assertTrue(homeEp.deliver(_forge(a)));
        assertFalse(_tripped(), "day 0 fell out of the window");
        vm.warp(t0 + 7 days + 23 hours);
        assertTrue(homeEp.deliver(_forge(B - a + 1e18)));
        assertTrue(_tripped(), "day 4 + day 7 = QUEUE_BREAKER + 1 > QUEUE_BREAKER");
    }

    /// B1 mechanism: a tripped path refuses every claim, due or not, honest or forged, for as long as nobody acts.
    function test_trippedPathRefusesClaims() public {
        uint256 h = _send(alice, 6_000e18);
        assertTrue(homeEp.deliver(h));
        (uint256 f,) = _queuePast(6_000e18);
        assertTrue(_tripped());
        vm.warp(vm.getBlockTimestamp() + 30 days);
        bytes32 k = _claimKey(homeEp, h);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.Tripped.selector, HOME));
        rh.claim(HOME, k);
        k = _claimKey(homeEp, f);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.Tripped.selector, HOME));
        rh.claim(HOME, k);
        assertEq(rhTok.balanceOf(attacker), 0);
    }

    /// B2: the Safe cancels the forgery, RESET_BREAKER (48h) releases the trip, and the honest claim runs, a year later too.
    function test_honestClaimResumesAfterTimelockedReset() public {
        uint256 h = _send(alice, 6_000e18);
        assertTrue(homeEp.deliver(h));
        (uint256 f, uint256 f2) = _queuePast(6_000e18);
        assertTrue(_tripped());
        bytes32 fk = _claimKey(homeEp, f);
        vm.prank(safe);
        rh.cancelClaim(HOME, fk);
        _cancel(f2);
        // audit wave 5: a reset only on a paused path; reopened in the same BATCH
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathOpen.selector, HOME));
        rh.propose(_reset(1));
        rh.pause(HOME);
        rh.propose(_b(_reset(1), abi.encode(uint8(5), HOME)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectEmit(address(rh));
        emit BreakerReset(HOME, 1);
        rh.applyPending();
        assertFalse(_tripped());
        assertFalse(rh.paused(HOME));
        assertEq(rh.breakerBuckets(HOME), 1 << 255, "the window restarts at zero (the sentinel bit kept)");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _claim(h);
        assertEq(rhTok.balanceOf(alice), 6_000e18, "no expiry");
        vm.expectRevert();
        rh.claim(HOME, fk);
    }

    /// B3: the governor cannot reset instantly; nobody else can trip or propose; the timelock is 48h; a reset proposed
    /// before a trip (or naming an earlier trip) never releases a later one.
    function test_noInstantReset() public {
        vm.prank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.tripBreaker(HOME);
        vm.prank(safe);
        rh.pause(HOME); // audit wave 5: a reset is proposed (and applied) only on a paused path
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector); // not tripped: nothing to reset
        rh.propose(_reset(0));
        // trip 1 (by the Safe, instant), reset proposed, then 48h - 1 s is too early
        vm.expectEmit(address(rh));
        emit BreakerTripped(HOME, 1, safe);
        vm.prank(safe);
        rh.tripBreaker(HOME);
        vm.prank(safe);
        rh.tripBreaker(HOME); // already tripped: no new trip
        assertEq(_trips(), 1);
        vm.prank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.propose(_reset(1));
        vm.prank(safe);
        rh.propose(_reset(1));
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        rh.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        rh.applyPending();
        assertFalse(_tripped());
        // a reset naming trip 1 is refused now (nothing tripped), and cannot be parked for a later trip
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.propose(_reset(1));
        // trip 2 by the queue; a stale reset(1) is refused; only reset(2) passes
        _govern(rh, abi.encode(uint8(5), HOME)); // reopened to queue
        vm.warp(vm.getBlockTimestamp() + 1 days); // the reopened path's limits and allowance refill
        _queuePast(0);
        vm.prank(safe);
        rh.pause(HOME);
        assertEq(_trips(), 2);
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.propose(_reset(1));
        vm.prank(safe);
        rh.propose(_reset(2));
    }

    /// The breaker only stops claims: instant mints and queueing go on (the inbound limit still bounds what queues), and a
    /// pause is independent of it.
    function test_trippedPathStillReceives() public {
        vm.prank(safe);
        rh.tripBreaker(HOME);
        assertTrue(homeEp.deliver(_send(alice, C)));
        assertEq(rhTok.balanceOf(alice), C, "instant mint unchanged");
        assertTrue(homeEp.deliver(_send(alice, 2 * C)));
        assertEq(rh.queued(), 2 * C);
    }

    /// A cancel does not refund the breaker's window (like the limit): the forger cannot cancel its way under it (only the
    /// Safe cancels anyway).
    function test_cancelDoesNotRefundTheWindow() public {
        uint256 f = _forge(B - C);
        assertTrue(homeEp.deliver(f));
        _cancel(f);
        vm.warp(vm.getBlockTimestamp() + GAP); // the inbound limit refills half; the same UTC day
        // above the instant cap, so queued whole: B - C (cancelled, still counted) + C + 1 > QUEUE_BREAKER
        assertTrue(homeEp.deliver(_forge(C + 1e18)));
        assertTrue(_tripped());
    }

    /// Runbook: after a forgery the Safe pauses (instant) and cancels; UNPAUSE and RESET_BREAKER of the trip go in ONE
    /// BATCH (one 48h proposal: the reset is not a path change), and the honest claim runs.
    function test_unpauseAndResetInOneBatch() public {
        uint256 h = _send(alice, 6_000e18);
        assertTrue(homeEp.deliver(h));
        (uint256 f, uint256 f2) = _queuePast(6_000e18);
        assertTrue(_tripped());
        vm.prank(safe);
        rh.pause(HOME);
        bytes32 fk = _claimKey(homeEp, f);
        vm.prank(safe);
        rh.cancelClaim(HOME, fk);
        _cancel(f2);
        _govern(rh, _b(abi.encode(uint8(5), HOME), _reset(1)));
        assertFalse(rh.paused(HOME));
        assertFalse(_tripped());
        _claim(h);
        assertEq(rhTok.balanceOf(alice), 6_000e18);
        assertEq(rhTok.balanceOf(attacker), 0);
    }
}
