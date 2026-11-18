// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {MockMessageLib} from "../utils/MockLzEndpoint.sol";

/// @notice Wave 4 LOW (audit 34e546c2): SET_RECEIVE_LIBRARY forwards an unbounded grace; during it the old, now unpinned
/// library still verifies but SET_CONFIG refuses it.
/// PROPERTY (C7): every library that can verify for a path is pinned or inside a bounded grace, holds this OApp's checked
/// config, and stays configurable; a path is not reopened while an old library can still verify.
contract AuditW4BridgeReceiveGraceTest is W4Bridge {
    address next;

    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
        next = address(new MockMessageLib());
    }

    function test_unboundedGraceRefused() public {
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_b(_pinRecv(HOME, next, 1 << 200), _recvCfg(next, HOME, 0x1000)));
    }

    function test_libraryInGraceStaysConfigurable() public {
        _govern(rh, _b(_pinRecv(HOME, next, 1_000), _recvCfg(next, HOME, 0x1000)));
        _govern(rh, _recvCfg(rhRecvLib, HOME, 0x5000)); // the old library, still verifying for 1,000 blocks
    }

    function test_unpauseRefusedWhileTheOldLibraryVerifies() public {
        vm.prank(safe);
        rh.pause(HOME);
        _govern(rh, _b(_pinRecv(HOME, next, 1_000), _recvCfg(next, HOME, 0x1000)));
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(abi.encode(uint8(5), HOME));
        vm.roll(block.number + 1_001);
        _govern(rh, abi.encode(uint8(5), HOME));
        assertFalse(rh.paused(HOME));
    }
}
