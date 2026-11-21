// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Wave-5 audit 74838ad4, LOW 6 (judge; flow): `voided` is keyed by the payload hash alone, so voiding a forged
/// replay of an honest (guid, message) verified at another nonce also refuses the honest message, and UNVOID reopens both.
/// The response to a replayed payload is NONCE-SCOPED (a review before wave 5b): hold the forged nonce
/// (instant), then RELEASE it with payload hash 0 = DROP (48 h, inside the 72 h hold): the held payload never runs at that
/// nonce, and any OTHER payload verified there later (the honest peer's next message at that nonce) runs, as a claim.
/// Earlier versions used a RELEASE to a junk hash, which bound the nonce to the junk: the next honest message there then waited
/// for a second 48 h RELEASE. The honest twin at its own nonce is untouched and mints at once (it was never held).
/// PROPERTY (P4/P6): the Safe can refuse a forged replay for good while the honest twin runs, and no later honest message at
/// the forged nonce waits for another Safe act.
contract AuditW5BridgeVoidReplayTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    function run(Origin calldata o, bytes32 guid, bytes calldata m) external {
        rhEp.lzReceive(o, address(rh), guid, m, "");
    }

    /// The judge's case, as it stands: a void by hash refuses the honest twin too (the documented hazard).
    function test_voidByHashRefusesTheTwin() public {
        (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) = _twins();
        vm.prank(safe);
        rh.voidPayload(keccak256(abi.encodePacked(guid, m)));
        vm.expectRevert();
        this.run(f, guid, m);
        vm.expectRevert();
        this.run(h, guid, m);
    }

    /// The response: hold the forged nonce, RELEASE it as a DROP (hash 0). The forged replay never runs (in the hold, after
    /// it, after a re-verify), the honest twin runs at once.
    function test_nonceScopedResponseKeepsTheHonestTwin() public {
        (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) = _twins();
        vm.prank(safe);
        rh.hold(HOME, f.nonce);
        _proposeRh(abi.encode(uint8(12), HOME, f.sender, f.nonce, bytes32(0)));
        this.run(h, guid, m); // the honest twin runs
        assertEq(rhTok.balanceOf(alice), 100e18);
        vm.expectRevert();
        this.run(f, guid, m); // in the hold
        _warp(48 hours);
        rh.applyPending();
        _warp(30 days);
        vm.expectRevert();
        this.run(f, guid, m); // after the hold: the dropped payload never runs at that nonce
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// Since a review before wave 5b: after the drop, the honest peer's NEXT message lands at the forged nonce (the honest DVNs overwrite the
    /// stored hash): it runs with no second RELEASE (as a claim: the nonce was held), and the forged replay still never does.
    function test_nextHonestMessageAtTheDroppedNonceRuns() public {
        (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) = _twins();
        this.run(h, guid, m); // the twin runs at once
        vm.prank(safe);
        rh.hold(HOME, f.nonce);
        _governRh(abi.encode(uint8(12), HOME, f.sender, f.nonce, bytes32(0)));
        uint256 j = _send(alice, 200e18); // the honest next send takes nonce f.nonce, verified over the replay
        assertEq(homeEp.originOf(j).nonce, f.nonce);
        assertTrue(homeEp.deliver(j), "the next honest message at the dropped nonce waits for a second RELEASE");
        assertEq(rh.queued(), 200e18, "as a claim (the nonce was held)");
        assertFalse(rhEp.verify(f, address(rh), keccak256(abi.encodePacked(guid, m))), "an executed nonce cannot be verified again");
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// The reviewer's case (the earlier procedure): a RELEASE to a junk hash binds the nonce to the junk, so the honest
    /// peer's next message there reverts OnHold until a second RELEASE names it. Kept: a RELEASE names what runs.
    function test_junkReleaseStrandsTheNextHonestMessage() public {
        (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) = _twins();
        this.run(h, guid, m);
        vm.prank(safe);
        rh.hold(HOME, f.nonce);
        _governRh(abi.encode(uint8(12), HOME, f.sender, f.nonce, keccak256("nothing has this")));
        uint256 j = _send(alice, 200e18);
        assertFalse(homeEp.deliver(j), "bound to the junk hash");
    }

    /// An honest 100 imdUSD transfer waiting at nonce n, and the same (guid, message) verified by the DVNs at nonce n + 1.
    function _twins() internal returns (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) {
        uint256 i = _send(alice, 100e18); // verified at once by the mock's honest DVNs, not executed
        h = homeEp.originOf(i);
        (,,,, guid, m,,) = homeEp.packets(i);
        f = Origin(h.srcEid, h.sender, h.nonce + 1);
        rhEp.verify(f, address(rh), keccak256(abi.encodePacked(guid, m)));
    }
}
