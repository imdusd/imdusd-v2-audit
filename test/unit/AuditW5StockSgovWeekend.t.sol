// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {W4SessAggregator, W4SessRegistry, W4SessStock} from "./AuditW4StockSession.t.sol";

/// @notice WAVE 5 (judge, low; job ec9fe0d5): SGOV's feed never prints on Saturday or Sunday daytime: the last print before
/// a weekend is Thursday or Friday 20:0x New York, the next Sunday 20:00 (Monday 20:00 over a Monday holiday). With maxAge
/// 49 h a single skipped Sunday heartbeat left SGOV unpriced the whole Monday session (61.5-85.5 h since the last print).
/// PROPERTY: when the one heartbeat after a closure is skipped (a weekend, or a weekend plus a Monday holiday), the live feed
/// still prices the whole next session (after the open grace); a feed silent for longer than that reads stale.
contract AuditW5StockSgovWeekendTest is Test {
    MarketCalendar cal;
    W4SessAggregator agg;
    W4SessStock stock;

    function setUp() public {
        uint32[] memory closed = new uint32[](1);
        cal = new MarketCalendar(address(0xBEEF), new uint32[](0), new uint32[](0)); // only for its date arithmetic
        closed[0] = uint32(cal.daysFromCivil(2026, 9, 7)); // Mon 2026-09-07, Labor Day
        cal = new MarketCalendar(address(0xBEEF), closed, new uint32[](0));
        agg = new W4SessAggregator();
        stock = new W4SessStock(address(new W4SessRegistry()));
        vm.warp(1_780_000_000);
    }

    function _sgovMaxAge() internal pure returns (uint256 age) {
        DeployTypes.StocksSpec memory s = RobinhoodConfig.stocks();
        for (uint256 i; i < s.types.length; ++i) {
            if (s.types[i].ilk == "SGOV") return s.types[i].maxAge;
        }
    }

    /// @dev Print at `printDay` 20:01 New York (EDT: 00:01 UTC next day), read every 15 min of `readDay`'s session from
    /// 09:40 New York (13:40 UTC) to 15:59.
    function _wholeSessionPriced(uint256 printDay, uint256 readDay) internal {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, _sgovMaxAge());
        uint256 print = (printDay + 1) * 1 days + 1 minutes;
        for (uint256 t = readDay * 1 days + 13 hours + 40 minutes; t < readDay * 1 days + 20 hours; t += 15 minutes) {
            vm.warp(print);
            agg.set(100e8, print);
            vm.warp(t);
            assertFalse(feed.isStale(), "unpriced in the session after one missed heartbeat");
        }
    }

    /// The judge's case: Friday 2026-10-23 20:01 print, the Sunday heartbeat missed: Monday 10-26's whole session.
    function test_judgeProof_missedSundayHeartbeatFridayPrint() public {
        _wholeSessionPriced(cal.daysFromCivil(2026, 10, 23), cal.daysFromCivil(2026, 10, 26));
    }

    /// The usual weekend (11 of 17 measured): last print Thursday 20:0x; Sunday missed: Monday's session.
    function test_missedSundayHeartbeatThursdayPrint() public {
        _wholeSessionPriced(cal.daysFromCivil(2026, 10, 22), cal.daysFromCivil(2026, 10, 26));
    }

    /// A Monday holiday (Labor Day 2026-09-07): last print Thursday 09-03, the Monday 20:00 heartbeat missed: Tuesday.
    function test_missedHeartbeatOverAMondayHoliday() public {
        _wholeSessionPriced(cal.daysFromCivil(2026, 9, 3), cal.daysFromCivil(2026, 9, 8));
    }

    /// A feed silent for more than that (Thursday print, nothing through Wednesday) reads stale.
    function test_aWeekOfSilenceIsStale() public {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, _sgovMaxAge());
        uint256 print = (cal.daysFromCivil(2026, 10, 22) + 1) * 1 days + 1 minutes;
        vm.warp(print);
        agg.set(100e8, print);
        vm.warp(cal.daysFromCivil(2026, 10, 29) * 1 days + 14 hours); // Thursday to Thursday: past STOCK_MAX_AGE (6 days)
        assertTrue(feed.isStale(), "a dead feed reads stale");
    }
}
