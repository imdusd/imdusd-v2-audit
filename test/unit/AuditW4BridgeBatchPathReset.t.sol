// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";

/// @notice Wave 4 LOW (audit 34e546c2): a BATCH of two SET_PATH (inbound limit to 0, then back) erases what is in flight in
/// one block while its final limits read as a no-op.
/// PROPERTY: a proposal raises what a path may admit now by at most what its final limits openly add; one item per path
/// and kind in a BATCH, and closing a path (limit 0) keeps what is in flight.
contract AuditW4BridgeBatchPathResetTest is W4Bridge {
    uint256 constant L = 10_000e18;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
    }

    function test_twoPathItemsForOneEidRefused() public {
        vm.prank(safe);
        rh.pause(HOME); // (lowering an inbound limit needs a paused path: AuditW4BridgeStrandedOverLimit)
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_b(_path(HOME, _b32(address(home)), L, 0), _path(HOME, _b32(address(home)), L, L)));
    }

    /// Closing a path (limit 0) keeps what is in flight, so reopening hands out no fresh window (outbound: lowering it needs
    /// no pause).
    function test_closingKeepsWhatIsInFlight() public {
        vm.prank(safe);
        rh.propose(_path(HOME, _b32(address(home)), 0, L));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _sendFromRh(L); // the window full in the block the close applies
        rh.applyPending();
        (,, uint128 inFlight,) = rh.outbound(HOME);
        assertEq(inFlight, L, "closing erased what was in flight");
        _govern(rh, _path(HOME, _b32(address(home)), L, L));
        assertEq(rh.availableOut(HOME), 0, "reopening handed out a fresh window");
    }

    function _sendFromRh(uint256 amount) internal {
        rhTok.mint(alice, amount);
        SendParam memory p = SendParam(HOME, _b32(alice), amount, 0, "", "", "");
        uint256 fee = rhEp.FEE();
        vm.prank(alice);
        rh.send{value: fee}(p, MessagingFee(fee, 0), alice);
    }
}
