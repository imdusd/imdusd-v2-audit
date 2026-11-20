// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice Wave-5 audit 74838ad4, MEDIUM 2 (judge; economics): forged packets a compromised DVN set verified at the endpoint
/// but did not execute are untouched by pause, the DVN fix and the cutoff; after the 48 h UNPAUSE the instant meter had
/// decayed, so the stockpile minted a fresh instant cap at once (10,000 > P3's 7,500), with no Queued for the Safe to see.
/// PROPERTY (P3, P2 at a reopening): nothing loosens the instant allowance at once. After an UNPAUSE the path's instant
/// allowance restarts EMPTY and refills at C per day, and so does it after a cap raise (SET_DELAY), so
/// what mints at once in the t after either is at most C x t / 1 day: a stockpile executed at a reopening queues (Queued,
/// visible, waiting D) and the Safe's answer within D covers it again.
contract AuditW5BridgeStockpileTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    function _pauseFixReopen() internal {
        vm.prank(safe);
        rh.pause(HOME);
        _governRh(_recvCfg(rhRecvLib, HOME, 0x2000)); // the DVN fix on the same receive library
        _governRh(abi.encode(uint8(5), HOME)); // UNPAUSE, its own proposal
    }

    /// The auditor's sequence: two 5,000 forgeries verified, one executed (instant); pause, DVN fix, UNPAUSE; the second runs.
    function test_stockpiledForgeryQueuesAfterUnpause() public {
        uint256 n1 = _forge(5_000e18);
        uint256 n2 = _forge(5_000e18); // verified, not executed
        assertTrue(homeEp.deliver(n1)); // instant 5,000
        _warp(1 hours);
        _pauseFixReopen();
        assertTrue(homeEp.deliver(n2), "the stockpiled packet executes after the reopening");
        assertEq(rhTok.balanceOf(attacker), 5_000e18, "it minted at once after the reopening");
        assertEq(rh.queued(), 5_000e18, "it is queued: visible as Queued, waiting D");
        // the Safe answers within D, as P3 asks
        bytes32 k2 = _claimKey(homeEp, n2);
        vm.prank(safe);
        rh.cancelClaim(HOME, k2);
        _warp(30 days);
        assertFalse(_tryClaim(n2));
        assertLe(rhTok.balanceOf(attacker), C + C * D / 1 days, "P3: forged mint above C x (1 + D / 1 day)");
    }

    /// Property, fuzzed: a stockpile of `k` pieces executed `t` after an UNPAUSE mints at once at most C x t / 1 day.
    function testFuzz_reopeningOpensTheInstantAllowanceAtTheRate(uint256 t, uint256 k, uint256 piece) public {
        t = bound(t, 0, 2 days);
        k = bound(k, 1, 20);
        piece = bound(piece, 10, 5_000) * 1e18;
        uint256[] memory s = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            s[j] = _forge(piece);
        }
        _pauseFixReopen();
        _warp(t);
        for (uint256 j; j < k; ++j) {
            homeEp.deliver(s[j]);
        }
        uint256 cap = t >= 1 days ? C : C * t / 1 days;
        assertLe(rhTok.balanceOf(attacker), cap, "instant mints after a reopening above C x t / 1 day");
    }

    /// The same for a cap restored by SET_DELAY after the Safe's C = 0 (P3's other reopening): raising the cap restarts the
    /// allowance empty: it refills at the new rate, not at once.
    function testFuzz_capRestoreOpensAtTheRate(uint256 t, uint256 k) public {
        t = bound(t, 0, 2 days);
        k = bound(k, 1, 20);
        uint256[] memory s = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            s[j] = _forge(500e18);
        }
        vm.prank(safe);
        rh.tighten(HOME, 0, D, B, 0);
        _warp(3 days); // the meter decays fully meanwhile
        _governRh(_setDelayP(C, D, B, 0)); // C restored
        _warp(t);
        for (uint256 j; j < k; ++j) {
            homeEp.deliver(s[j]);
        }
        uint256 cap = t >= 1 days ? C : C * t / 1 days;
        assertLe(rhTok.balanceOf(attacker), cap, "instant mints after a cap restore above C x t / 1 day");
    }

    /// Honest flow resumes: a day after the reopening the full C is instant again.
    function test_fullAllowanceADayAfter() public {
        _pauseFixReopen();
        _warp(1 days);
        assertEq(rh.availableInstant(HOME), C);
    }
}
