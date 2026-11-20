// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTypes} from "../../script/DeployConfig.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";
import {StageChain} from "../../script/deploy/StageChain.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";

contract W5CalendarResumeHarness is StageChain {
    function calendarIs(MarketCalendar c, DeployTypes.Config memory cfg) external view returns (bool) {
        return _calendarIs(c, cfg);
    }
}

/// @notice WAVE 5 (judge, low; job ec9fe0d5): on a staged resume `_calendarIs` read only the governor and the days the config
/// lists, so a recorded MarketCalendar seeded from another list (an earlier config revision, a rehearsal) that closes or
/// early-closes an extra weekday was adopted as the configured one: every MarketHoursFeed built over it, all nine types
/// unpriced that day until the Safe repaired it through the 48 h timelock.
/// PROPERTY: a recorded calendar is adopted only if it was seeded from exactly the config's lists (the calendar a fresh
/// DeployRobinhood would build); any other seed, extra or missing day, either status, is rebuilt.
contract AuditW5StockCalendarResumeTest is Test {
    W5CalendarResumeHarness h;
    DeployTypes.Config cfg;
    address constant SAFE = address(0x5AFE);

    function setUp() public {
        h = new W5CalendarResumeHarness();
        cfg.governor = SAFE;
        cfg.stocks = RobinhoodConfig.stocks();
    }

    function _with(uint32[] memory list, uint32 extra) internal pure returns (uint32[] memory out) {
        out = new uint32[](list.length + 1);
        for (uint256 i; i < list.length; ++i) out[i] = list[i];
        out[list.length] = extra;
    }

    function test_configSeededCalendarIsAdopted() public {
        MarketCalendar c = new MarketCalendar(SAFE, cfg.stocks.closedDays, cfg.stocks.earlyDays);
        assertTrue(h.calendarIs(c, cfg));
    }

    /// The judge's case: the config's closed days plus Mon 2026-12-14 (day 20801).
    function test_judgeProof_extraClosedDayAccepted() public {
        MarketCalendar c = new MarketCalendar(SAFE, _with(cfg.stocks.closedDays, 20_801), cfg.stocks.earlyDays);
        assertFalse(h.calendarIs(c, cfg), "a calendar closing a day the config leaves open is not the configured calendar");
    }

    /// Fuzz: one extra weekday, closed or early, anywhere 2026-2030, not already listed.
    function testFuzz_anyExtraDayIsRefused(uint32 day, bool early) public {
        day = uint32(bound(day, 20_454, 22_280)); // 2026-01-01 .. 2030-12-31
        vm.assume((day + 4) % 7 != 0 && (day + 4) % 7 != 6);
        for (uint256 i; i < cfg.stocks.closedDays.length; ++i) vm.assume(cfg.stocks.closedDays[i] != day);
        for (uint256 i; i < cfg.stocks.earlyDays.length; ++i) vm.assume(cfg.stocks.earlyDays[i] != day);
        MarketCalendar c = early
            ? new MarketCalendar(SAFE, cfg.stocks.closedDays, _with(cfg.stocks.earlyDays, day))
            : new MarketCalendar(SAFE, _with(cfg.stocks.closedDays, day), cfg.stocks.earlyDays);
        assertFalse(h.calendarIs(c, cfg), "an extra day is not the configured calendar");
    }
}
