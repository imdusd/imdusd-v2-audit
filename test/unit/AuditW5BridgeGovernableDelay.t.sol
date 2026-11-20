// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice Governable inbound delay settings per path (no bound on the cap or the breaker: millions in volume
/// a day).
///  G1 A path's first SET_PATH writes the launch values (cap 5,000/day, delay 12 h, breaker 50,000): no open path is ever
///     without a delay.
///  G2 SET_DELAY (48h) sets cap and breaker to ANY value the 64-bit shared-decimals fields hold (well past 1e12 imdUSD) and
///     the delay within [MIN_DELAY 1 h, MAX_DELAY 7 d]; outside the delay bounds it is refused.
///  G3 Loosening (a higher cap or breaker, a shorter delay) only through the timelock; `tighten` (governor, instant)
///     only tightens, and bumps the path's settings version, so a SET_DELAY proposed before it (naming the old version)
///     is refused when applied (no undo by a stale loosening).
///  G4 A delay change applies to claims already queued (claimable at queuedAt + the path's delay at claim time): a
///     lengthening never shortens any wait.
///  G5 Scale: limits of hundreds of millions a day pass SET_PATH (MAX_LIMIT 250,000,000/window), and with a 2,000,000 cap a
///     1,500,000 message mints at once.
contract AuditW5BridgeGovernableDelayTest is W4Bridge {
    uint256 constant L = 50_000e18;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
    }

    function _settings() internal view returns (uint256 cap, uint256 delay, uint256 breaker) {
        (,, uint64 capSD) = rh.instantIn(HOME);
        (,,, uint64 breakerSD, uint32 d,,) = rh.breakers(HOME);
        (cap, delay, breaker) = (uint256(capSD) * 1e12, d, uint256(breakerSD) * 1e12);
    }

    /// @dev SET_DELAY names the settings version it is proposed against (bumped by every instant tightening).
    function _setDelay(uint256 cap, uint256 delay, uint256 breaker) internal view returns (bytes memory) {
        (,,,,,, uint16 version) = rh.breakers(HOME);
        return abi.encode(uint8(15), HOME, cap, delay, breaker, uint256(0), uint256(version));
    }

    function test_G1_launchValuesAtFirstSetPath() public view {
        (uint256 cap, uint256 delay, uint256 breaker) = _settings();
        assertEq(cap, 5_000e18);
        assertEq(delay, 12 hours);
        assertEq(breaker, 50_000e18);
        assertEq(rh.availableInstant(HOME), 5_000e18);
    }

    function test_G2_noBoundOnCapAndBreaker_delayBounded() public {
        uint256 huge = 1e12 * 1e18; // a trillion imdUSD
        _govern(rh, _setDelay(huge, 7 days, huge));
        (uint256 cap, uint256 delay, uint256 breaker) = _settings();
        assertEq(cap, huge);
        assertEq(delay, 7 days);
        assertEq(breaker, huge);
        _govern(rh, _setDelay(0, 1 hours, 0)); // zero cap: everything queues; zero breaker: any queue trips
        bytes memory short = _setDelay(1e18, 1 hours - 1, 1e18);
        bytes memory long = _setDelay(1e18, 7 days + 1, 1e18);
        bytes memory odd = _setDelay(1e18 + 1, 12 hours, 1e18); // not a whole shared-decimals unit
        vm.startPrank(safe);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.propose(short);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.propose(long);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.propose(odd);
        vm.stopPrank();
    }

    function test_G3_tightenInstantOnly_loosenThroughTheTimelock() public {
        vm.prank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.tighten(HOME, 1_000e18, 1 days, 10_000e18, 0);
        vm.startPrank(safe);
        // audit wave 5: a loosening argument is clamped to what stands (never a revert, never a loosening)
        rh.tighten(HOME, 5_001e18, 12 hours - 1, 50_001e18, 0); // higher cap and breaker, shorter delay: no change
        (uint256 cap, uint256 delay, uint256 breaker) = _settings();
        assertEq(cap, 5_000e18);
        assertEq(delay, 12 hours);
        assertEq(breaker, 50_000e18);
        rh.tighten(HOME, 5_000e18, 7 days + 1, 50_000e18, 0); // past MAX_DELAY: MAX_DELAY
        (, delay,) = _settings();
        assertEq(delay, 7 days);
        rh.tighten(HOME, 1_000e18, 1 days, 10_000e18, 0); // a shorter delay than 7 days: stays 7 days
        vm.stopPrank();
        (cap, delay, breaker) = _settings();
        assertEq(cap, 1_000e18);
        assertEq(delay, 7 days);
        assertEq(breaker, 10_000e18);
        // a loosening needs 48h
        bytes memory loosen = _setDelay(5_000e18, 12 hours, 50_000e18);
        vm.prank(safe);
        rh.propose(loosen);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        rh.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        rh.applyPending();
        (cap,,) = _settings();
        assertEq(cap, 5_000e18);
    }

    /// G3: a loosening proposed, then an instant tightening: the proposal names the old version and is refused when
    /// applied, so it cannot undo the tightening.
    function test_G3_tighteningOutlivesAPendingLoosening() public {
        bytes[] memory items = new bytes[](1);
        items[0] = _setDelay(100_000e18, 1 hours, 1_000_000e18);
        vm.prank(safe);
        rh.propose(abi.encode(uint8(6), items));
        vm.prank(safe);
        rh.tighten(HOME, 0, 3 days, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.applyPending();
        (uint256 cap, uint256 delay, uint256 breaker) = _settings();
        assertEq(cap, 0);
        assertEq(delay, 3 days);
        assertEq(breaker, 0);
    }

    /// G4: an instant lengthening applies to a claim already queued; the timelocked shortening applies to it too, never
    /// below queuedAt + the new delay.
    function test_G4_delayChangeAppliesToQueuedClaims() public {
        uint256 i = _forge(10_000e18); // above the cap: queued
        assertTrue(homeEp.deliver(i));
        bytes32 k = _claimKey(homeEp, i);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(safe);
        rh.tighten(HOME, 5_000e18, 5 days, 50_000e18, 0);
        vm.warp(t0 + 12 hours);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotClaimable.selector, HOME, k, t0 + 5 days));
        rh.claim(HOME, k);
        vm.warp(t0 + 5 days - 1);
        vm.expectRevert();
        rh.claim(HOME, k);
        vm.warp(t0 + 5 days);
        rh.claim(HOME, k);
        assertEq(rhTok.balanceOf(attacker), 10_000e18);
    }

    /// G4 fuzzed: whatever the new delay, a claim queued at t0 is never claimable before t0 + min(old, new) when shortened
    /// (only via the 48h timelock) and never before t0 + new when lengthened.
    function testFuzz_G4_lengtheningNeverShortens(uint256 d) public {
        d = bound(d, 12 hours, 7 days);
        uint256 i = _forge(10_000e18);
        assertTrue(homeEp.deliver(i));
        bytes32 k = _claimKey(homeEp, i);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(safe);
        rh.tighten(HOME, 5_000e18, d, 50_000e18, 0);
        vm.warp(t0 + d - 1);
        vm.expectRevert();
        rh.claim(HOME, k);
        vm.warp(t0 + d);
        rh.claim(HOME, k);
    }

    function test_G5_millionsPerDay() public {
        uint256 big = 200_000_000e18;
        _govern(rh, _path(HOME, _b32(address(home)), big, big));
        _govern(rh, _setDelay(2_000_000e18, 12 hours, 50_000_000e18));
        vm.warp(vm.getBlockTimestamp() + 1 days); // audit wave 5: a raise's headroom opens at the new rate over a day
        uint256 i = _forge(1_500_000e18);
        assertTrue(homeEp.deliver(i));
        assertEq(rhTok.balanceOf(attacker), 1_500_000e18, "minted at once under a 2,000,000 cap");
        assertEq(rh.queued(), 0);
        i = _forge(40_000_000e18);
        assertTrue(homeEp.deliver(i));
        assertEq(rh.queued(), 40_000_000e18);
        (,, bool tripped,,,,) = rh.breakers(HOME);
        assertFalse(tripped, "40M under a 50M breaker");
        i = _forge(10_000_001e18);
        assertTrue(homeEp.deliver(i));
        (,, tripped,,,,) = rh.breakers(HOME);
        assertTrue(tripped, "past 50M");
        // the ceiling
        vm.prank(safe);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.propose(_path(HOME, _b32(address(home)), 250_000_001e18, 1e18));
    }
}
