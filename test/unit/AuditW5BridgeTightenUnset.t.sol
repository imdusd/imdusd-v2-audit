// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Wave-5 audit 74838ad4, LOW 5 (judge; flow: low, math: info): `tighten` on a path before its first SET_PATH stored
/// a delay of 1 s (under MIN_DELAY) and bumped the version, so the first SET_PATH skipped the launch values (the path
/// opened with D = 1 s) and a launch BATCH carrying a version-0 SET_DELAY failed at application.
/// PROPERTY (P5): an open path's claim delay is always within [MIN_DELAY, MAX_DELAY], and no instant act can set a value
/// no timelocked act may: `tighten` acts only on a path whose settings exist (it is refused on a path never set).
contract AuditW5BridgeTightenUnsetTest is W4Bridge {
    function setUp() public {
        _setUpW4();
    }

    /// The judge's sequence: tighten(…, delay 1 s, …) on a fresh bridge, then the launch BATCH.
    function test_tightenBeforeFirstSetPathRefused() public {
        vm.prank(safe);
        vm.expectRevert(ImdBridge.NotTighter.selector);
        rh.tighten(HOME, 0, 1, 0, 0);
        _govern(rh, _launchBatch(rh, HOME, _b32(address(home)), 50_000e18, 50_000e18));
        (,,,, uint32 d,,) = rh.breakers(HOME);
        assertEq(uint256(d), rh.DEFAULT_DELAY(), "the launch values on the first SET_PATH");
    }

    /// Property, fuzzed: whatever the Safe tightens before the launch BATCH applies, the opened path's delay is within
    /// [MIN_DELAY, MAX_DELAY] and a launch BATCH with a version-0 SET_DELAY still applies.
    function testFuzz_noInstantActBeforeLaunchBreaksIt(uint256 cap, uint256 delay, uint256 brk, uint40 cut) public {
        bytes[] memory items = new bytes[](6);
        bytes memory l = _launchBatch(rh, HOME, _b32(address(home)), 50_000e18, 50_000e18);
        (, bytes[] memory five) = abi.decode(l, (uint8, bytes[]));
        for (uint256 j; j < 5; ++j) {
            items[j] = five[j];
        }
        items[5] = abi.encode(uint8(15), HOME, uint256(5_000e18), uint256(12 hours), uint256(50_000e18), uint40(0), uint256(0));
        vm.prank(safe);
        rh.propose(_batch(items));
        vm.prank(safe);
        try rh.tighten(HOME, cap, delay, brk, cut) {} catch {}
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.applyPending();
        (,,,, uint32 d,,) = rh.breakers(HOME);
        assertGe(uint256(d), uint256(1 hours));
        assertLe(uint256(d), uint256(7 days));
    }

    /// The same for a bridge with no path at all: nothing an instant act does leaves a delay under MIN_DELAY.
    function test_freshBridgeHasNoTightenableSettings() public {
        ImdBridge b2 = new ImdBridge(
            ILayerZeroEndpointV2(address(rhEp)), IMintableBurnable(address(rhTok)), safe, makeAddr("t2")
        );
        vm.prank(safe);
        vm.expectRevert(ImdBridge.NotTighter.selector);
        b2.tighten(HOME, 0, 7 days, 0, 1);
        (,,,, uint32 d,, uint16 v) = b2.breakers(HOME);
        assertEq(d, 0);
        assertEq(v, 0);
    }
}
