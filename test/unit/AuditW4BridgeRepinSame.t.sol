// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 LOW (audit 34e546c2): re-pinning the library a path already uses passes _check but reverts at application
/// (EndpointV2 LZ_SameValue), failing the whole BATCH after 48h.
/// PROPERTY: a proposal accepted at proposal time applies (no act EndpointV2 is known to refuse is accepted).
contract AuditW4BridgeRepinSameTest is W4Bridge {
    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function test_samePinRefusedAtProposal() public {
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_pinSend(HOME, rhSendLib));
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_pinRecv(HOME, rhRecvLib, 0));
    }
}
