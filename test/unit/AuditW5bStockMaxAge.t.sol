// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {W4SessAggregator, W4SessRegistry, W4SessStock} from "./AuditW4StockSession.t.sol";

/// @notice A review before wave 5b: every stock type's maxAge must price the whole NYSE schedule
/// with one missed heartbeat, with a real margin. The 4663 feeds' heartbeat (measured from
/// the feeds' rounds and a calendar walk of their heartbeat schedule): a 24 h timer that only fires inside Robinhood's 24/5 session (20:00 New York on the
/// eve of a trading day to 20:00 on it), plus a print when that session opens; none over a weekend or holiday. So a QUIET
/// ticker's standing answer before a closure is at worst the eve's 20:00 print. Over the config calendar 2026-11-20..
/// 2027-12-31 the worst in-session age with one print missed is 115.9 h (Mon 2026-12-28 15:55, from Wed 12-23 20:00:
/// Christmas Friday; the same at New Year, Good Friday, July 5 and Labor Day 2027); measured to 11-20: SGOV 115.9 h
/// (Tuesday after Labor Day), SPY 100.7 h, AAPL 70.4 h. With two missed: 139.9 h.
/// PROPERTY: for EVERY stock type of the deploy config, the live feed prices the whole session after OPEN_GRACE on each
/// worst case of the schedule with one missed heartbeat (Friday holidays, Monday holidays, Thanksgiving's half day, plain
/// weekends), and maxAge clears the worst one-missed age by at least a whole heartbeat (24 h); a dead feed reads stale.
contract AuditW5bStockMaxAgeTest is Test {
    MarketCalendar cal;
    W4SessAggregator agg;
    W4SessStock stock;
    DeployTypes.StocksSpec specs;

    /// schedule.json worstAgeH["1"]: one heartbeat missed, worst over the config calendar to 2027-12-31.
    uint256 constant WORST_ONE_MISSED = 116 hours;
    uint256 constant MARGIN = 24 hours; // a whole heartbeat period: a late or extra-missed print is not hours of slack

    function setUp() public {
        DeployTypes.StocksSpec memory s = RobinhoodConfig.stocks();
        cal = new MarketCalendar(address(0xBEEF), s.closedDays, s.earlyDays); // the deploy config's calendar
        agg = new W4SessAggregator();
        stock = new W4SessStock(address(new W4SessRegistry()));
        vm.warp(1_780_000_000);
        for (uint256 i; i < s.types.length; ++i) specs.types.push(s.types[i]);
    }

    /// @dev 20:01 New York on `day` (EDT or EST).
    function _eve(uint256 day) internal view returns (uint256) {
        return (day + 1) * 1 days + (cal.isDst(day) ? 0 : 1 hours) + 1 minutes;
    }

    /// @dev Last print at `printDay` 20:01 New York, read every 15 min of `readDay`'s session from OPEN_GRACE + 5 min.
    function _wholeSessionPriced(uint256 maxAge, uint256 printDay, uint256 readDay, bytes32 ilk) internal {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, maxAge);
        uint256 print = _eve(printDay);
        uint256 from = cal.openAt(readDay) + 10 minutes;
        for (uint256 t = from; cal.isOpen(t); t += 15 minutes) {
            vm.warp(print);
            agg.set(100e8, print);
            vm.warp(t);
            if (feed.isStale()) revert(string.concat("unpriced in the session after one missed heartbeat: ", string(abi.encodePacked(ilk))));
        }
    }

    /// The worst cases over the calendar to 2027 (a calendar walk of the feeds' heartbeat schedule), each with the reopening heartbeat missed.
    function test_everyTypePricesTheHolidayScheduleWithOneMissedHeartbeat() public {
        uint256[2][7] memory cases = [
            [cal.daysFromCivil(2026, 12, 23), cal.daysFromCivil(2026, 12, 28)], // Christmas Friday: Wed print -> Mon
            [cal.daysFromCivil(2026, 12, 30), cal.daysFromCivil(2027, 1, 4)], // New Year Friday
            [cal.daysFromCivil(2027, 3, 24), cal.daysFromCivil(2027, 3, 29)], // Good Friday 2027-03-26
            [cal.daysFromCivil(2027, 7, 1), cal.daysFromCivil(2027, 7, 6)], // July 4 observed Monday 07-05
            [cal.daysFromCivil(2027, 9, 2), cal.daysFromCivil(2027, 9, 7)], // Labor Day 2027-09-06
            [cal.daysFromCivil(2026, 11, 24), cal.daysFromCivil(2026, 11, 27)], // Thanksgiving: Tue print -> Fri half day
            [cal.daysFromCivil(2026, 11, 26), cal.daysFromCivil(2026, 11, 30)] // Thanksgiving eve print -> Monday
        ];
        for (uint256 i; i < specs.types.length; ++i) {
            for (uint256 k; k < cases.length; ++k) {
                _wholeSessionPriced(specs.types[i].maxAge, cases[k][0], cases[k][1], specs.types[i].ilk);
            }
        }
    }

    function test_maxAgeClearsTheWorstByAWholeHeartbeat() public view {
        for (uint256 i; i < specs.types.length; ++i) {
            assertGe(specs.types[i].maxAge, WORST_ONE_MISSED + MARGIN, "maxAge clears the one-missed worst by < 24 h");
        }
    }

    /// A dead feed still reads stale: nothing printed for a week.
    function test_deadFeedIsStale() public {
        for (uint256 i; i < specs.types.length; ++i) {
            MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, specs.types[i].maxAge);
            uint256 print = _eve(cal.daysFromCivil(2027, 1, 13));
            vm.warp(print);
            agg.set(100e8, print);
            vm.warp(cal.openAt(cal.daysFromCivil(2027, 1, 20)) + 1 hours);
            assertTrue(feed.isStale(), "a dead feed reads stale");
        }
    }
}
