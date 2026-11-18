// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {MockMessageLib} from "../utils/MockLzEndpoint.sol";

/// @notice Wave 4 HIGH (audit 34e546c2): SET_PATH / SET_SEND_LIBRARY / SET_RECEIVE_LIBRARY without a floor-checked SET_CONFIG
/// leave the path on LayerZero's default ULN config (mainnet default for 30416: 1 DVN, 5 confirmations; fork proof in
/// test/fork/AuditW4BridgeEndpoint.t.sol).
/// PROPERTY (P6): a path carries value only while both its libraries are pinned and each holds a floor-checked ULN config
/// set by this OApp; no proposal leaves it otherwise.
contract AuditW4BridgeUnconfiguredPathTest is W4Bridge {
    function setUp() public {
        _setUpW4();
    }

    /// Control: the launch BATCH (path, both pins, both configs) stays accepted.
    function test_launchBatchAccepted() public {
        _govern(home, _launchBatch(home, RH, _b32(address(rh)), 10_000e18, 10_000e18));
        assertEq(home.sendLibrary(RH), homeSendLib);
    }

    function test_barePathRefused() public {
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_path(RH, _b32(address(rh)), 10_000e18, 10_000e18));
    }

    function test_barePinsRefused() public {
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_pinSend(RH, homeSendLib));
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_pinRecv(RH, homeRecvLib, 0));
    }

    function test_pathAndPinsWithoutConfigRefused() public {
        bytes[] memory items = new bytes[](3);
        items[0] = _path(RH, _b32(address(rh)), 10_000e18, 10_000e18);
        items[1] = _pinSend(RH, homeSendLib);
        items[2] = _pinRecv(RH, homeRecvLib, 0);
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_batch(items));
    }

    /// A LayerZero library migration that forgets the new library's config: refused.
    function test_libraryMoveWithoutConfigRefused() public {
        _govern(home, _launchBatch(home, RH, _b32(address(rh)), 10_000e18, 10_000e18));
        address next = address(new MockMessageLib());
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_pinRecv(RH, next, 0));
        vm.prank(safe);
        vm.expectRevert();
        home.propose(_pinSend(RH, next));
        // with its config in the same BATCH: accepted
        _govern(home, _b(_pinRecv(RH, next, 0), _recvCfg(next, RH, 0x1000)));
        assertEq(home.receiveLibrary(RH), next);
    }
}
