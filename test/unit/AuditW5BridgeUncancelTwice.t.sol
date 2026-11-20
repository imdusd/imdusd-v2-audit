// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice Wave-5 audit 74838ad4, LOW 2 (judge; economics, flow): a BATCH naming one cancelled claim in two UNCANCEL items
/// passed validation (each item checked against the state before the BATCH) and added the claim to `queued` twice.
/// PROPERTY (P1 accounting): `queued` always equals the sum of the pending claims; and a proposal accepted at proposal time
/// applies (a repeated UNCANCEL restores the claim once and is otherwise a no-op).
contract AuditW5BridgeUncancelTwiceTest is W5Bridge {
    uint256[] idx;

    function setUp() public {
        _setUpW5();
    }

    function _uncancel(uint256 i) internal view returns (bytes memory) {
        return abi.encode(uint8(13), HOME, _claimKey(homeEp, i));
    }

    function _pendingSum() internal view returns (uint256 sum) {
        for (uint256 j; j < idx.length; ++j) {
            (, uint48 a,, uint8 st) = rh.claims(HOME, _claimKey(homeEp, idx[j]));
            if (st == 1) sum += uint256(a) * 1e12;
        }
    }

    /// The auditor's sequence.
    function test_duplicateUncancelCountsOnce() public {
        uint256 h = _send(alice, 10_000e18);
        assertTrue(homeEp.deliver(h)); // above C: queued
        idx.push(h);
        bytes32 k = _claimKey(homeEp, h);
        vm.prank(safe);
        rh.cancelClaim(HOME, k);
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (_uncancel(h), _uncancel(h));
        _governRh(_batch(items));
        assertEq(rh.queued(), 10_000e18);
        _warp(D);
        assertTrue(_tryClaim(h));
        assertEq(rh.queued(), 0, "P1: queued != sum of pending claims");
        assertEq(rhTok.balanceOf(alice), 10_000e18);
    }

    /// Property, fuzzed (n and the batch size from the seed): n claims, a subset cancelled, a BATCH of UNCANCELs naming cancelled claims with repeats: it applies,
    /// and queued == the sum of pending claims before and after every claim.
    function testFuzz_queuedEqualsPendingSum(uint256 seed) public {
        _sendSome(seed, 1 + seed % 8);
        _cancelSome(seed);
        assertEq(rh.queued(), _pendingSum());
        if (cancelled.length == 0) return;
        _governRh(_batch(_uncancels(seed, 1 + (seed >> 8) % 6))); // accepted at proposal: applies
        assertEq(rh.queued(), _pendingSum(), "queued != pending after the UNCANCEL batch");
        _warp(D);
        _claimAllChecked();
    }

    function _sendSome(uint256 seed, uint256 count) internal {
        for (uint256 j; j < count; ++j) {
            uint256 a = bound(uint256(keccak256(abi.encode(seed, j))), 5_001, 6_000) * 1e18;
            uint256 h = _send(alice, a);
            assertTrue(homeEp.deliver(h));
            idx.push(h);
        }
    }

    function _claimAllChecked() internal {
        for (uint256 j; j < idx.length; ++j) {
            _tryClaim(idx[j]);
            assertEq(rh.queued(), _pendingSum(), "queued != pending after a claim");
        }
    }

    uint256[] cancelled;

    function _cancelSome(uint256 seed) internal {
        for (uint256 j; j < idx.length; ++j) {
            if (uint256(keccak256(abi.encode(seed, j, "c"))) % 2 == 0) {
                bytes32 k = _claimKey(homeEp, idx[j]);
                vm.prank(safe);
                rh.cancelClaim(HOME, k);
                cancelled.push(idx[j]);
            }
        }
    }

    /// @dev `count` UNCANCEL items naming cancelled claims, with repeats.
    function _uncancels(uint256 seed, uint256 count) internal view returns (bytes[] memory items) {
        items = new bytes[](count);
        for (uint256 j; j < count; ++j) {
            items[j] = _uncancel(cancelled[uint256(keccak256(abi.encode(seed, j, "u"))) % cancelled.length]);
        }
    }
}
