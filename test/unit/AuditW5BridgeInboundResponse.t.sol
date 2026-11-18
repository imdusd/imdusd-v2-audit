// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";

/// @notice FIXED BEFORE AUDIT WAVE 5. The path LIMITS are 50,000/day both ways; the loss bound
/// on a forged inbound stream over the Safe's 72 h response (instant cap x 4 <= the 4663 chain line) belongs to the inbound
/// delay's INSTANT cap, and is added there.
/// RULE pinned here: the two paths mirror each other (4663's out = mainnet's in, 4663's in = mainnet's out, same window), so
/// a send one side would refuse at delivery is refused at the source; every limit is open (nonzero) and within MAX_LIMIT.
contract AuditW5BridgeInboundResponseTest is Test {
    /// @dev ImdBridge.MAX_LIMIT (src/bridge/ImdBridge.sol:144; SET_PATH refuses a limit above it). A literal: Solar does not
    /// resolve a contract constant by type name.
    uint256 constant MAX_LIMIT = 10_000_000e18;
    struct Path {
        uint8 kind;
        uint32 eid;
        bytes32 peer;
        uint256 outLimit;
        uint256 outWindow;
        uint256 inLimit;
        uint256 inWindow;
        bytes options;
    }

    function _decode(bytes memory p) internal pure returns (Path memory x) {
        (x.kind, x.eid, x.peer, x.outLimit, x.outWindow, x.inLimit, x.inWindow, x.options) =
            abi.decode(p, (uint8, uint32, bytes32, uint256, uint256, uint256, uint256, bytes));
    }

    function test_pathsMirrorAndStayWithinMaxLimit() public pure {
        Path memory rh = _decode(RobinhoodConfig.mainnetPath(bytes32(uint256(1)))); // 4663's bridge, path to mainnet
        Path memory eth = _decode(RobinhoodConfig.robinhoodPathOnMainnet(bytes32(uint256(2)))); // mainnet's, path to 4663
        assertEq(rh.outLimit, eth.inLimit, "4663 out != mainnet in");
        assertEq(rh.inLimit, eth.outLimit, "4663 in != mainnet out");
        assertEq(rh.outWindow, eth.inWindow);
        assertEq(rh.inWindow, eth.outWindow);
        assertEq(rh.outLimit, RobinhoodConfig.OUT_LIMIT);
        assertEq(rh.inLimit, RobinhoodConfig.IN_LIMIT);
        assertTrue(rh.outLimit != 0 && rh.inLimit != 0, "a path limit of 0 closes the path");
        assertLe(rh.outLimit, MAX_LIMIT, "SET_PATH would refuse it");
        assertLe(rh.inLimit, MAX_LIMIT, "SET_PATH would refuse it");
    }
}
