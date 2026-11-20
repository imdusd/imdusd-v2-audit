// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {W4SessAggregator, W4SessRegistry, W4SessStock} from "./AuditW4StockSession.t.sol";

/// @notice Audit wave 4 (stocks), low: with maxAge 25 h a heartbeat-only feed (SGOV: prints at 20:00 New York, almost never in
/// session) is unpriced for a whole session when one heartbeat is skipped, although the feed is alive.
/// PROPERTY: a live heartbeat-only feed that misses one weekday heartbeat still prices the next session (after P1's open
/// grace); a feed silent for two heartbeats in a row reads stale.
contract AuditW4StockHeartbeatTest is Test {
    MarketCalendar cal;
    W4SessAggregator agg;
    W4SessStock stock;
    uint256 wed; // Wed 2026-11-18 00:00 UTC (EST)

    function setUp() public {
        cal = new MarketCalendar(address(0xBEEF), new uint32[](0), new uint32[](0));
        agg = new W4SessAggregator();
        stock = new W4SessStock(address(new W4SessRegistry()));
        vm.warp(1_790_000_000);
        agg.set(100e8, block.timestamp);
        wed = cal.daysFromCivil(2026, 11, 18) * 1 days;
    }

    function _sgovMaxAge() internal pure returns (uint256 age) {
        DeployTypes.StocksSpec memory s = RobinhoodConfig.stocks();
        for (uint256 i; i < s.types.length; ++i) {
            if (s.types[i].ilk == "SGOV") return s.types[i].maxAge;
        }
    }

    /// The judge's case: Monday 20:00 printed, Tuesday 20:00 skipped; Wednesday's whole session.
    function testFuzz_judgeProof_missedHeartbeatPricesNextSession(uint256 readAt) public {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, _sgovMaxAge());
        agg.set(100e8, wed - 1 days - 3 hours); // Mon 2026-11-16 20:00 New York (Tue 01:00 UTC)
        readAt = bound(readAt, wed + 14 hours + 35 minutes, wed + 21 hours - 1); // Wed 09:35-15:59:59 New York
        vm.warp(readAt);
        assertFalse(feed.isStale(), "a live heartbeat-only feed that missed one heartbeat is unpriced all session");
    }

    /// A dead feed reads stale. Wave 5 (AuditW5StockSgovWeekend): SGOV's maxAge is 5 days so one heartbeat missed after a
    /// weekend (plus a Monday holiday) still prices; two missed weekday heartbeats now price too, a feed silent past 5 days
    /// reads stale.
    function test_deadFeedIsStale() public {
        MarketHoursFeed feed = new MarketHoursFeed(address(agg), address(stock), address(0xCAFE), cal, _sgovMaxAge());
        agg.set(100e8, wed - 1 days - 3 hours); // Mon 20:00 New York; nothing after
        vm.warp(wed + 5 days + 14 hours + 35 minutes); // the next Monday 09:35
        assertTrue(feed.isStale(), "a week silent: a dead feed");
    }
}
