// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice Wave-5 audit 74838ad4, LOW 4 (judge; economics): a cap change did not checkpoint the instant meter, so the time
/// before a raise decayed at the NEW cap: a raise freed up to the old cap more than its headroom.
/// PROPERTY (P2 across a cap change): the time before a change of C decays at the cap that held then. Right after it the
/// room is at most what it was just before plus the raise's headroom (none for a lowering), and afterwards it grows at
/// the new rate only. (Since audit wave 5 a raise restarts the allowance empty: see AuditW5BridgeStockpile.)
contract AuditW5BridgeCapCheckpointTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    /// The judge's sequence: a raise to 60,000 proposed; at ETA - 2 h a 5,000 message fills the meter; at ETA it applies.
    function test_raisedCapDoesNotDecayThePastAtTheNewRate() public {
        _proposeRh(_setDelayP(60_000e18, D, B, 0));
        _warp(46 hours);
        (, bool ok) = _forgeRun(5_000e18);
        assertTrue(ok);
        assertEq(rh.availableInstant(HOME), 0, "full");
        _warp(2 hours);
        rh.applyPending();
        uint256 expected = 60_000e18 - (5_000e18 - uint256(5_000e18) * 2 / 24);
        assertLe(rh.availableInstant(HOME), expected, "raise freed more than its headroom");
    }

    /// Property, fuzzed over the new cap, the fill and the times: the room right after a change (timelocked or the Safe's
    /// tighten) is at most the room just before plus the raise's headroom, and `t` later at most that plus newCap x t / 1 day.
    function testFuzz_capChangeFreesNothingAtOnce(uint256 newCap, uint256 fill, uint256 gap, uint256 t, bool instant)
        public
    {
        newCap = bound(newCap, 0, 200_000) * 1e18;
        fill = bound(fill, 10, 5_000) * 1e18;
        (, bool ok) = _forgeRun(fill);
        assertTrue(ok);
        if (instant) {
            _warp(bound(gap, 0, 2 days));
            uint256 before = rh.availableInstant(HOME);
            vm.prank(safe);
            rh.tighten(HOME, newCap, D, B, 0);
            uint256 after_ = rh.availableInstant(HOME);
            assertLe(after_, before, "the instant route freed room");
            _warp(bound(t, 0, 2 days));
            assertLe(rh.availableInstant(HOME), after_ + (newCap < C ? newCap : C) * bound(t, 0, 2 days) / 1 days);
        } else {
            _proposeRh(_setDelayP(newCap, D, B, 0));
            _warp(48 hours - 1);
            gap = bound(gap, 0, 1 days);
            _warp(1 + gap);
            uint256 before = rh.availableInstant(HOME);
            rh.applyPending();
            uint256 after_ = rh.availableInstant(HOME);
            assertLe(after_, before + (newCap > C ? newCap - C : 0), "a cap change freed more than its headroom");
            t = bound(t, 0, 3 days);
            _warp(t);
            assertLe(rh.availableInstant(HOME), after_ + newCap * t / 1 days, "room grew faster than the new rate");
        }
    }
}
