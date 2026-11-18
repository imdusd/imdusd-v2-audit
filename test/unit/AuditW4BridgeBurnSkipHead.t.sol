// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 LOW (audit 34e546c2): ENDPOINT_BURN / ENDPOINT_SKIP of a verified payload at the head nonce of a paused
/// path are accepted at proposal but revert on EndpointV2 (LZ_InvalidNonce) after 48h, holding the one pending slot.
/// PROPERTY: an endpoint act is accepted only if EndpointV2 can apply it (checked at proposal and at application), and a
/// nilified payload below lazyInboundNonce can be burned without a second pause round.
contract AuditW4BridgeBurnSkipHeadTest is W4Bridge {
    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function test_infeasibleBurnRefusedAtProposal() public {
        uint256 f = _forge(20_000e18); // over the limit: waits verified at the head
        (uint64 n, bytes32 sender) = _origin(f);
        vm.prank(safe);
        rh.pause(HOME);
        bytes32 h = homeEp.payloadHashOf(f);
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(abi.encode(uint8(10), HOME, sender, n, h));
    }

    function test_infeasibleSkipRefusedAtProposal() public {
        uint256 f = _forge(20_000e18);
        (uint64 n, bytes32 sender) = _origin(f);
        vm.prank(safe);
        rh.pause(HOME);
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(abi.encode(uint8(8), HOME, sender, n)); // verified: not skippable
    }

    /// The feasible durable void: a nilified nonce that a later nonce passed is burned with the path open.
    function test_burnNilBelowLazyOnAnOpenPath() public {
        uint256 f1 = _forge(20_000e18);
        (uint64 n1, bytes32 sender) = _origin(f1);
        bytes32 h1 = homeEp.payloadHashOf(f1);
        // the timelocked endpoint nilify (paused path), then reopen (no instant nilify since 2026-11-15)
        vm.prank(safe);
        rh.pause(HOME);
        _govern(rh, abi.encode(uint8(9), HOME, sender, n1, h1));
        _govern(rh, abi.encode(uint8(5), HOME));
        uint256 f2 = _forge(100e18);
        assertTrue(homeEp.deliver(f2)); // a forgery under the limit: passes n1 (NIL is a hash), lazy = n1 + 1
        bytes32 nil = rhEp.NIL_PAYLOAD_HASH();
        _govern(rh, abi.encode(uint8(10), HOME, sender, n1, nil));
        assertEq(rhEp.inboundPayloadHash(address(rh), HOME, sender, n1), bytes32(0));
        assertFalse(homeEp.reverify(f1), "burned nonce re-verifiable");
    }
}
