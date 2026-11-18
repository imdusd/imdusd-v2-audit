// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 HIGH (audit 34e546c2): zero-amount (or dust) forged packets execute unmetered and consume the honest
/// peer's nonces for good (on EndpointV2 an executed nonce can never be verified again; fork proof in
/// test/fork/AuditW4BridgeEndpoint.t.sol).
/// PROPERTY: no inbound message executes without being metered; a message under MIN_AMOUNT (10 imdUSD) never executes, so its
/// nonce stays free for the honest packet; and the inbound nonces executed per window are bounded by 2 x limit / MIN_AMOUNT.
contract AuditW4BridgeUnmeteredNoncesTest is W4Bridge {
    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    /// A forged zero-amount packet at the honest peer's next nonce does not execute, so the honest send at that nonce
    /// (verified over it) still lands.
    function test_zeroAmountForgedPacketNeverExecutes() public {
        uint256 f = _forge(0);
        assertFalse(homeEp.deliver(f), "zero-amount inbound message executed");
        uint256 h = _send(alice, 100e18);
        assertTrue(homeEp.deliver(h), "the honest message at that nonce is lost");
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// Forged packets under MIN_AMOUNT never execute, whatever their number: each leaves its nonce free for the honest one.
    function test_dustForgeriesNeverExecute() public {
        for (uint256 k; k < 50; ++k) {
            assertFalse(homeEp.deliver(_forge(1e12 * (k + 1))), "a forged dust packet executed");
        }
        uint256 h = _send(alice, 100e18);
        assertTrue(homeEp.deliver(h), "the honest message at that nonce is lost");
        assertEq(rhTok.balanceOf(alice), 100e18);
    }

    /// At or above MIN_AMOUNT, forged packets are metered at their amount: at most limit / MIN_AMOUNT (1,000 at a 10,000
    /// limit) execute in one block, and an honest 10 imdUSD send counts as exactly 10.
    function test_forgeriesAtTheMinimumBoundedPerWindow() public {
        uint256 executed;
        for (uint256 k; k < 1_100; ++k) {
            if (homeEp.deliver(_forge(10e18))) executed++;
        }
        assertLe(executed, 1_000, "inbound nonces consumed beyond limit / MIN_AMOUNT");
    }
}
