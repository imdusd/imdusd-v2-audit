// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Wave-5 audit 74838ad4, LOW 6 (judge; flow): `voided` is keyed by the payload hash alone, so voiding a forged
/// replay of an honest (guid, message) verified at another nonce also refuses the honest message, and UNVOID reopens both.
/// NOT CHANGED IN CODE (no runtime room). The response to a replayed payload is NONCE-SCOPED: hold the
/// forged nonce (instant) and RELEASE it (48 h, inside the 72 h hold) naming a hash nothing has, so that nonce never runs;
/// the honest nonce is untouched. Documented on `voidPayload`.
/// PROPERTY (P4/P6, as a procedure): the Safe can refuse a forged replay for good while the honest twin still runs.
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

    /// The documented response: hold the forged nonce, RELEASE it to a hash nothing has. The forged replay never runs (in
    /// the hold, after it, after a re-verify), the honest twin runs at once.
    function test_nonceScopedResponseKeepsTheHonestTwin() public {
        (Origin memory h, bytes32 guid, bytes memory m, Origin memory f) = _twins();
        vm.prank(safe);
        rh.hold(HOME, f.nonce);
        _proposeRh(abi.encode(uint8(12), HOME, f.sender, f.nonce, keccak256("nothing has this")));
        this.run(h, guid, m); // the honest twin runs
        assertEq(rhTok.balanceOf(alice), 100e18);
        vm.expectRevert();
        this.run(f, guid, m); // in the hold
        _warp(48 hours);
        rh.applyPending();
        _warp(30 days);
        vm.expectRevert();
        this.run(f, guid, m); // after the hold: bound to the released (junk) hash
        assertEq(rhTok.balanceOf(alice), 100e18);
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
