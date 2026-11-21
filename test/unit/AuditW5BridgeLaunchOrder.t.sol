// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge, GatedTok} from "../utils/W5Bridge.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice A review before wave 5b: the unblock class missed SET_BRIDGE. Until Parameters' SET_BRIDGE
/// applies, ImdUSD.mint reverts for the bridge, and the launch files opened the path (file B2) before SET_BRIDGE (B1). The
/// first SET_PATH left the instant allowance full, so packets verified in between ran at SET_BRIDGE into a full C at once.
/// PROPERTY: whatever the order of SET_BRIDGE and the path, no packet mints at once more than C x (time since the path could
/// first mint, i.e. since both SET_BRIDGE and the path have applied) / 1 day, and no claim matures before queuedAt + D.
contract AuditW5BridgeLaunchOrderTest is W5Bridge {
    GatedTok gtok;

    function setUp() public {
        _setUpW4();
        gtok = new GatedTok();
        rh = new ImdBridge(ILayerZeroEndpointV2(address(rhEp)), IMintableBurnable(address(gtok)), safe, makeAddr("rhTreasury"));
        _govern(home, _launchBatch(home, RH, _b32(address(rh)), LIM, LIM));
    }

    function _openRh() internal {
        _govern(rh, _launchBatch(rh, HOME, _b32(address(home)), LIM, LIM));
    }

    function _stock(uint256 k, uint256 piece) internal returns (uint256[] memory s) {
        s = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            s[j] = _forge(piece);
        }
    }

    function _runAll(uint256[] memory s) internal {
        for (uint256 j; j < s.length; ++j) {
            homeEp.deliver(s[j]);
        }
    }

    /// The reviewer's route: path first (B2), packets verified in between, SET_BRIDGE (B1) days later; they run at once.
    function test_pathBeforeSetBridgeNothingAtOnce() public {
        _openRh();
        uint256[] memory s = _stock(4, 2_500e18);
        _warp(3 days);
        gtok.setBridge(address(rh)); // SET_BRIDGE applies
        _runAll(s);
        assertEq(gtok.balanceOf(attacker), 0, "packets verified before SET_BRIDGE minted at once at it");
    }

    /// A claim queued before SET_BRIDGE matures at queuedAt + D, and cannot mint before SET_BRIDGE.
    function test_claimBeforeSetBridgeWaits() public {
        _openRh();
        (uint256 i, bool ok) = _forgeRun(10_000e18); // above C: queued
        assertTrue(ok);
        _warp(D);
        assertFalse(_tryClaim(i), "a claim minted before SET_BRIDGE");
        gtok.setBridge(address(rh));
        assertTrue(_tryClaim(i), "matured at queuedAt + D, mints once SET_BRIDGE applied");
    }

    /// Property, fuzzed over the order, the gap between the two acts and the time the stockpile runs after both.
    function testFuzz_anyOrderWithinTheRate(bool bridgeFirst, uint256 gap, uint256 t, uint8 k) public {
        gap = bound(gap, 0, 5 days);
        t = bound(t, 0, 2 days);
        uint256 pieces = bound(k, 1, 8);
        uint256[] memory s;
        if (bridgeFirst) {
            gtok.setBridge(address(rh));
            _warp(gap);
            _openRh();
            s = _stock(pieces, 1_000e18);
        } else {
            _openRh();
            s = _stock(pieces, 1_000e18);
            _warp(gap);
            gtok.setBridge(address(rh));
        }
        _warp(t);
        _runAll(s);
        uint256 cap = t >= 1 days ? C : C * t / 1 days;
        assertLe(gtok.balanceOf(attacker), cap, "minted at once above C x (time since the path could first mint) / 1 day");
    }
}
