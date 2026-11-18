// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 LOW (audit 34e546c2): an honest message larger than a LOWERED inbound limit can never pass (amount >
/// limit in every block) until a 48h raise: not "retry later".
/// PROPERTY (P4): an honest message within the peer's outbound limit is never stranded by a limit; an inbound limit is
/// lowered only on a paused path (the operator procedure: lower the peer's outbound, wait for its in-flight, then lower here).
contract AuditW4BridgeStrandedOverLimitTest is W4Bridge {
    uint256 constant L = 10_000e18;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
    }

    /// The judge's sequence, refused at its first step: lowering the inbound limit of an open path.
    function test_loweringAnOpenInboundLimitRefused() public {
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_path(HOME, _b32(address(home)), L, L / 2));
    }

    function test_loweringAPausedInboundLimitAccepted() public {
        vm.prank(safe);
        rh.pause(HOME);
        _govern(rh, _path(HOME, _b32(address(home)), L, L / 2));
        (uint128 limit,,,) = rh.inbound(HOME);
        assertEq(limit, L / 2);
    }
}
