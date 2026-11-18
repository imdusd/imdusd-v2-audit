// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";

contract W4DecAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(uint8 d, int256 a) external {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Audit wave 4 (stocks), low: ChainlinkFeed cached the aggregator's decimals at construction; the Robinhood SPY and
/// USO feeds changed 18 -> 8 decimals inside one phase (rounds 7 -> 8, 2026-06-23), which would misprice by 1e10.
/// PROPERTY: the feed never reports a value scaled with decimals other than the ones the aggregator reports for that answer;
/// a change from the decimals it was built with reads unpriced.
contract AuditW4StockDecimalsTest is Test {
    /// The judge's case: built at 8, the aggregator answers $73.498 in 18 decimals.
    function test_judgeProof_decimalsChange() public {
        W4DecAggregator agg = new W4DecAggregator(8, 7349800000);
        ChainlinkFeed f = new ChainlinkFeed(address(agg), 18, 1 days);
        agg.set(18, 7349800000000000000);
        (uint256 v,) = f.latestValue();
        emit log_named_uint("value per token (1e18)", v);
        assertTrue(v == 0 || v == 73.498e18, "priced at 1e10 x the price");
    }

    function testFuzz_decimalsChangeNeverMisprices(uint8 d0, uint8 d1, uint64 usdCents) public {
        d0 = uint8(bound(d0, 0, 18));
        d1 = uint8(bound(d1, 0, 18));
        usdCents = uint64(bound(usdCents, 1, 1e12));
        W4DecAggregator agg = new W4DecAggregator(d0, int256(uint256(usdCents) * 10 ** d0 / 100));
        ChainlinkFeed f = new ChainlinkFeed(address(agg), 18, 1 days);
        int256 a = int256(uint256(usdCents) * 10 ** d1 / 100);
        if (a == 0) return;
        agg.set(d1, a);
        (uint256 v,) = f.latestValue();
        uint256 truth = uint256(a) * 1e18 / 10 ** d1;
        assertTrue(v == 0 || v == truth, "scaled with the wrong decimals");
        if (d0 == d1) assertEq(v, truth, "unchanged decimals still price");
        else assertTrue(f.isStale(), "a decimals change reads unpriced");
    }
}
