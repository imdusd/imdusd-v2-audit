// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";

/// @notice A review of the wave-5 fixes: UNPAUSE was accepted on an OPEN path, where it reopens nothing and (since audit wave 5)
/// empties the honest instant allowance.
/// PROPERTY: UNPAUSE applies only to a paused path (checked at proposal and at application); on an open path it is refused,
/// so the only effect of an UNPAUSE is the reopening it names.
contract AuditW5BridgeUnpauseOpenTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    function test_unpauseOnAnOpenPathRefused() public {
        _warp(1 days);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathOpen.selector, HOME));
        rh.propose(abi.encode(uint8(5), HOME));
        assertEq(rh.availableInstant(HOME), C, "the honest allowance untouched");
    }

    function test_unpauseOnAPausedPathApplies() public {
        vm.prank(safe);
        rh.pause(HOME);
        _governRh(abi.encode(uint8(5), HOME));
        assertFalse(rh.paused(HOME));
    }
}
