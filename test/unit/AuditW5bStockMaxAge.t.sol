// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {W4SessAggregator, W4SessRegistry, W4SessStock} from "./AuditW4StockSession.t.sol";

/// @notice A review before wave 5b: SGOV got a maxAge covering the weekend schedule, the other 8 stock types kept
/// 25 h. The 4663 feeds never print Saturday or Sunday daytime (measured from every
/// round: every ticker's weekend gap 74-81 h, Thursday or Friday 20:0x -> Sunday 20:00 New York), so with Sunday's
/// heartbeat missed a quiet ticker (no 0.5% move by Monday) was unpriced all Monday: no borrow, bite or take. Measured on
/// 108 sessions (2026-06-22..11-20): SPY had no in-session print in 28, its worst in-session age with one print missed is
/// 100.7 h (Labor Day Tuesday 2026-09-08 15:55), AAPL's 70.4 h (Monday 2026-09-21 09:35).
/// PROPERTY: for EVERY stock type of the deploy config, when the one heartbeat after a closure is missed (a weekend, or a
/// weekend plus a Monday holiday; last print Thursday or Friday 20:01 New York) the live feed prices the whole next session
/// after OPEN_GRACE; and every measured one-missed-print age fits the type's maxAge.
contract AuditW5bStockMaxAgeTest is Test {
    MarketCalendar cal;
    W4SessAggregator agg;
    W4SessStock stock;
    DeployTypes.StocksSpec specs;

    /// The measured worst in-session age with one print missed, rounded up to the hour (worst: SPY 100.7 h).
    uint256 constant MEASURED_ONE_MISSED = 101 hours;

    function setUp() public {
        cal = new MarketCalendar(address(0xBEEF), new uint32[](0), new uint32[](0)); // date arithmetic
        uint32[] memory closed = new uint32[](1);
        closed[0] = uint32(cal.daysFromCivil(2026, 9, 7)); // Labor Day
        cal = new MarketCalendar(address(0xBEEF), closed, new uint32[](0));
        agg = new W4SessAggregator();
        stock = new W4SessStock(address(new W4SessRegistry()));
        vm.warp(1_780_000_000);
        DeployTypes.StocksSpec memory s = RobinhoodConfig.stocks();
        for (uint256 i; i < s.types.length; ++i) specs.types.push(s.types[i]);
    }

    function _wholeSessionPriced(uint256 maxAge, uint256 printDay, uint256 readDay, bytes32 ilk) internal {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, maxAge);
        uint256 print = (printDay + 1) * 1 days + 1 minutes; // 20:01 New York (EDT)
        for (uint256 t = readDay * 1 days + 13 hours + 40 minutes; t < readDay * 1 days + 20 hours; t += 15 minutes) {
            vm.warp(print);
            agg.set(100e8, print);
            vm.warp(t);
            if (feed.isStale()) revert(string.concat("unpriced in the session after one missed heartbeat: ", string(abi.encodePacked(ilk))));
        }
    }

    function test_everyTypePricesTheScheduleWithOneMissedHeartbeat() public {
        for (uint256 i; i < specs.types.length; ++i) {
            uint256 m = specs.types[i].maxAge;
            bytes32 ilk = specs.types[i].ilk;
            // Friday print, Sunday missed: Monday 2026-10-26
            _wholeSessionPriced(m, cal.daysFromCivil(2026, 10, 23), cal.daysFromCivil(2026, 10, 26), ilk);
            // Thursday print (Friday quiet), Sunday missed: Monday
            _wholeSessionPriced(m, cal.daysFromCivil(2026, 10, 22), cal.daysFromCivil(2026, 10, 26), ilk);
            // Thursday print, Labor Day Monday with its 20:00 heartbeat missed: Tuesday 2026-09-08
            _wholeSessionPriced(m, cal.daysFromCivil(2026, 9, 3), cal.daysFromCivil(2026, 9, 8), ilk);
        }
    }

    function test_measuredOneMissedAgesFit() public view {
        for (uint256 i; i < specs.types.length; ++i) {
            assertGe(specs.types[i].maxAge, MEASURED_ONE_MISSED, "a measured one-missed-print age would read stale");
        }
    }

    /// A dead feed still reads stale: nothing printed for more than the schedule allows (a whole week).
    function test_deadFeedIsStale() public {
        for (uint256 i; i < specs.types.length; ++i) {
            MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, specs.types[i].maxAge);
            uint256 print = (cal.daysFromCivil(2026, 10, 22) + 1) * 1 days + 1 minutes;
            vm.warp(print);
            agg.set(100e8, print);
            vm.warp(cal.daysFromCivil(2026, 10, 28) * 1 days + 14 hours);
            assertTrue(feed.isStale(), "a dead feed reads stale");
        }
    }
}
