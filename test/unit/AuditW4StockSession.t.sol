// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";

contract W4SessRegistry {
    function paused() external pure returns (bool) {
        return false;
    }

    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

contract W4SessStock {
    address public immutable ACCESS_CONTROLLED_REGISTRY;

    constructor(address r) {
        ACCESS_CONTROLLED_REGISTRY = r;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function newUIMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function effectiveAt() external pure returns (uint256) {
        return 0;
    }
}

contract W4SessAggregator {
    int256 public answer = 600e8;
    uint256 public updatedAt;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Audit wave 4 (stocks), high: MarketHoursFeed priced the regular session from answers printed outside it (overnight,
/// pre-market, Sunday 20:00 New York).
/// P1: inside the regular session a type is priced only from an answer printed in the current session, or, once the session
/// has run OPEN_GRACE (5 min) with no such print, from the standing answer (the deviation trigger then had regular-session
/// prices to replace it, measured on 4663); outside the session never.
contract AuditW4StockSessionTest is Test {
    MarketCalendar cal;
    MarketHoursFeed feed;
    W4SessAggregator agg;
    uint256 monday; // 2026-11-16 00:00 UTC (EST: session 14:30-21:00 UTC)
    uint32 constant THANKSGIVING = 20783; // Thu 2026-11-26
    uint32 constant DAY_AFTER = 20784; // Fri 2026-11-27, 13:00 close

    function setUp() public {
        uint32[] memory closed = new uint32[](1);
        closed[0] = THANKSGIVING;
        uint32[] memory early = new uint32[](1);
        early[0] = DAY_AFTER;
        cal = new MarketCalendar(address(0xBEEF), closed, early);
        agg = new W4SessAggregator();
        W4SessStock stock = new W4SessStock(address(new W4SessRegistry()));
        vm.warp(1_790_000_000);
        agg.set(600e8, block.timestamp);
        feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, 25 hours);
        monday = cal.daysFromCivil(2026, 11, 16) * 1 days;
    }

    /// The judge's proof (first test unchanged): Sunday 20:00 New York's overnight print read at Monday 09:30:00.
    function test_judgeProof_sundayOvernightPrintPricesMondayOpen() public {
        agg.set(612e8, monday + 1 hours); // Sun 2026-11-15 20:00 ET
        vm.warp(monday + 14 hours + 30 minutes); // Mon 09:30:00 ET
        (uint256 v,) = feed.latestValue();
        emit log_named_uint("value read at the open (1e18 USD)", v);
        assertTrue(feed.isStale(), "Monday 09:30 is priced from Sunday 20:00's overnight answer");
    }

    /// The judge's fuzz, over the first OPEN_GRACE of the session (P1's grace is the one deliberate exception after it).
    function testFuzz_judgeProof_outOfSessionAnswerAtTheOpen(uint256 printAt, uint256 readAt) public {
        printAt = bound(printAt, monday + 1 hours, monday + 14 hours + 30 minutes - 1);
        readAt = bound(readAt, monday + 14 hours + 30 minutes, monday + 14 hours + 35 minutes - 1);
        agg.set(612e8, printAt);
        vm.warp(readAt);
        assertTrue(feed.isStale(), "P1/C5: an out-of-session answer is used inside the session");
    }

    /// P1 over any day from 2026 to 2035 (both DST switches every year, weekends, the seeded holiday and early close), any
    /// print time from three days before the read to the read, any read time in the day.
    function testFuzz_P1_pricedOnlyFromTheSession(uint256 dayN, uint256 printBack, uint256 readSec) public {
        uint256 day = bound(dayN, cal.daysFromCivil(2026, 1, 1), cal.daysFromCivil(2035, 12, 31));
        if (dayN % 7 == 0) day = THANKSGIVING + (dayN % 2); // hit the holiday and the early close often
        // half the reads land within ten minutes of the open (where P1 bites), the rest anywhere in the day
        uint256 readAt = readSec % 2 == 0
            ? cal.openAt(day) + (readSec >> 1) % 10 minutes
            : day * 1 days + bound(readSec, 0, 1 days - 1);
        uint256 printAt = readAt - bound(printBack, 0, 3 days);
        agg.set(612e8, printAt);
        vm.warp(readAt);
        bool priced = !feed.isStale();
        uint256 open = cal.openAt(day);
        bool inSession = cal.isOpen(readAt);
        if (inSession) {
            // openAt is the session's first second: consistent with the calendar the judge checked against the IANA zone
            assertTrue(cal.isOpen(open) && !cal.isOpen(open - 1), "openAt is the open");
        }
        bool fromSession = printAt >= open;
        bool graceRun = readAt >= open + 5 minutes; // MarketHoursFeed.OPEN_GRACE
        if (priced) {
            assertTrue(inSession, "P1: priced outside the session");
            assertTrue(fromSession || graceRun, "P1: priced in the session's first minutes from an answer printed before it");
        } else if (inSession && readAt - printAt <= 25 hours) {
            assertFalse(fromSession || graceRun, "liveness: a fresh in-session answer (or the standing one after the grace) prices");
        }
    }

    /// SGOV's shape (prints only at its 20:00 New York heartbeat): unpriced 09:30-09:35, priced from 09:35 on the 13.5 h old
    /// print; a print in the first minutes prices at once.
    function test_heartbeatOnlyFeedIsPricedAfterTheGrace() public {
        agg.set(612e8, monday + 1 hours); // Sun 20:00 ET
        vm.warp(monday + 14 hours + 34 minutes);
        assertTrue(feed.isStale(), "09:34: not yet");
        vm.warp(monday + 14 hours + 35 minutes);
        assertFalse(feed.isStale(), "09:35: the standing answer prices");
        agg.set(600e8, monday + 14 hours + 31 minutes);
        vm.warp(monday + 14 hours + 31 minutes);
        assertFalse(feed.isStale(), "an in-session print prices at once");
    }
}
