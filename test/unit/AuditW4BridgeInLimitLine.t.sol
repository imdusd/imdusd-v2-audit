// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";

/// @notice Wave 4 LOW (audit 34e546c2): one day's forged mint into 4663 must be bounded by what the 4663 book can lose (the
/// chain line, 30,000). The wave-4 rule (2 x IN_LIMIT <= CHAIN_LINE) went with the 50,000/day limits. Its
/// successor states two bounds on what a forged stream makes SPENDABLE. The
/// instant cap C, claim delay D and queue breaker B are governable per path (no bound on C and B), so the
/// rule is on the LAUNCH values (RobinhoodConfig, set by the launch BATCH's SET_DELAY on both paths), which must equal what
/// the bridge writes at a path's first SET_PATH:
///  (a) THE ONE THAT HOLDS THE LINE: the Safe acts within D, cancelling every queued forgery before it matures (one
///      `cancelQueuedSince`), so only the instant part is reachable: C x (1 + D / 1 day) <= the 4663 chain line.
///  (b) No human action over the 72 h weekend (HOLD_TIME): the instant part 4C plus B through claims. At the launch values
///      this is 70,000, ABOVE the 30,000 line: accepted (whales). Recorded so a change shows up.
/// A later SET_DELAY is the Safe's public, 48h decision; it is not bounded against the line.
contract AuditW4BridgeInLimitLineTest is W4Bridge {
    uint256 constant C = RobinhoodConfig.INSTANT_CAP;
    uint256 constant D = RobinhoodConfig.CLAIM_DELAY;
    uint256 constant B = RobinhoodConfig.QUEUE_BREAKER;

    function setUp() public {
        _setUpW4();
    }

    /// The launch config is what the bridge writes at a path's first SET_PATH (one set of launch values).
    function test_launchConfigIsTheBridgeDefault() public view {
        assertEq(C, rh.DEFAULT_INSTANT_CAP());
        assertEq(D, rh.DEFAULT_DELAY());
        assertEq(B, rh.DEFAULT_QUEUE_BREAKER());
    }

    function test_inboundIntoRobinhoodWithinTheChainLine() public view {
        // (a) the Safe within D: only the instant part
        uint256 safeActs = C + C * D / (1 days);
        assertEq(safeActs, 7_500e18, "5,000 + 2,500 instant within D");
        assertLe(safeActs, RobinhoodConfig.CHAIN_LINE, "a forgery the Safe cancels within D spends past the line");
        // the Safe's window is shorter than the weekend: the breaker is the backstop for a slower Safe
        assertLt(D, uint256(72 hours));
    }

    /// (b) the no-action 72 h figure at the launch values, recorded: it EXCEEDS the 4663 line by decision.
    function test_noActionWeekendFigureRecorded() public view {
        uint256 instant = C + C * uint256(72 hours) / (1 days);
        assertEq(instant, 4 * C, "the instant part over 72 h is 4C");
        uint256 noAction = instant + B;
        assertEq(noAction, 70_000e18, "20,000 instant + 50,000 through claims");
        assertGt(noAction, RobinhoodConfig.CHAIN_LINE, "by decision: past the 4663 line with no human action");
    }

    /// (c) the breaker window covers any HOLD_TIME span of queue times, or the breaker bounds less than 72 h.
    function test_breakerWindowCoversTheWeekend() public view {
        assertLe(uint256(72 hours), (uint256(4) - 1) * 1 days, "breaker window shorter than the weekend");
    }
}
