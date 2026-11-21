// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 MEDIUM (audit 34e546c2): nilify does not kill a forged payload on EndpointV2: a NIL nonce stays
/// verifiable, the still-configured compromised DVNs verify it again, and it executes once the path is unpaused.
/// PROPERTY (P2): a voided forged payload never executes; only a timelocked UNVOID brings one back.
/// Since 2026-11-15 (no guardian, bridge-local holds) the instant void is the Safe's `voidPayload`, which leaves the endpoint
/// untouched; the timelocked ENDPOINT_NILIFY still records the void too.
contract AuditW4BridgeNilifyReverifyTest is W4Bridge {
    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function _kelpStart() internal returns (uint256 f) {
        f = _forge(5_000e18);
        vm.startPrank(safe);
        rh.pause(HOME);
        rh.voidPayload(homeEp.payloadHashOf(f));
        vm.stopPrank();
        assertTrue(homeEp.reverify(f), "the compromised DVNs verify the same payload again");
    }

    /// The Kelp order as the header states it: pause, void, fix the DVN config, unpause (two proposals).
    function test_voidedForgedPayloadNeverExecutes() public {
        uint256 f = _kelpStart();
        _govern(rh, _recvCfg(rhRecvLib, HOME, 0x5000)); // new DVN set
        _govern(rh, abi.encode(uint8(5), HOME));
        assertFalse(homeEp.deliver(f), "voided forged payload executed after unpause");
        assertEq(rhTok.balanceOf(attacker), 0);
    }

    /// The timelocked endpoint nilify voids too: re-verified by the same DVNs, it still never executes.
    function test_endpointNilifyAlsoVoids() public {
        uint256 f = _forge(5_000e18);
        (uint64 n, bytes32 sender) = _origin(f);
        vm.prank(safe);
        rh.pause(HOME);
        _govern(rh, abi.encode(uint8(9), HOME, sender, n, homeEp.payloadHashOf(f)));
        assertTrue(homeEp.reverify(f));
        _govern(rh, abi.encode(uint8(5), HOME));
        assertFalse(homeEp.deliver(f), "nilified forged payload executed");
    }

    /// UNPAUSE in the same BATCH as the config change would let a payload verified just before it run at once.
    function test_unpauseCannotShareABatchWithAConfigChange() public {
        _kelpStart();
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_b(_recvCfg(rhRecvLib, HOME, 0x5000), abi.encode(uint8(5), HOME)));
    }

    /// An honest payload voided by mistake: delayed, then brought back by the timelock (UNVOID), never lost, and with no
    /// DVN re-verification (the endpoint kept its proof).
    function test_honestVoidedByMistakeComesBackThroughTheTimelock() public {
        uint256 h = _send(alice, 100e18);
        bytes32 ph = homeEp.payloadHashOf(h);
        vm.prank(safe);
        rh.voidPayload(ph);
        assertFalse(homeEp.deliver(h), "voided payload executed without the timelock");
        _govern(rh, abi.encode(uint8(11), ph));
        assertTrue(homeEp.deliver(h), "no re-verification needed");
        // a review before wave 5b: an unvoided payload runs as a claim (never at once); anyone claims it after the delay
        vm.warp(vm.getBlockTimestamp() + rh.DEFAULT_DELAY());
        rh.claim(HOME, _claimKey(homeEp, h));
        assertEq(rhTok.balanceOf(alice), 100e18);
    }
}
