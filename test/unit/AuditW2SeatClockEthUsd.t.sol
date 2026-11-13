// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatJoin} from "src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "src/seats/SeatAccount.sol";
import {SeatFeed} from "src/feeds/SeatFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {ParametersBase} from "src/ParametersBase.sol";

contract EthLeaf is IFeed {
    uint256 public value;
    uint64 public updatedAt;
    uint64 public acceptedAt;
    uint256 public figure = 100;
    uint256 public immutable maxAge;

    constructor(uint256 maxAge_) {
        maxAge = maxAge_;
    }

    function set(uint256 v, uint64 at) external {
        value = v;
        updatedAt = at;
        acceptedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external view returns (bool) {
        return value == 0 || block.timestamp > uint256(updatedAt) + maxAge;
    }

    function latestFigure() external view returns (uint256) {
        return figure;
    }
}

contract P {
    ParametersBase.Config internal _c;
    address public governor = address(0xA11CE);

    function setMedian(IFeed m) external {
        _c.median = m;
    }

    function config(bytes32) external view returns (ParametersBase.Config memory) {
        return _c;
    }
}

contract L {
    address public params;
    address public treasury = address(0x33);
    address public token = address(0x44);
    address public liquidator = address(0x11);

    constructor(address p) {
        params = p;
    }
}

/// The seat auction clock pauses only on the median leaf's staleness. With the ETH/USD leg stale (Chainlink ETH/USD,
/// BetaConfig maxAge 1 h 10 min) the type is unpriced (`SeatFeed.isStale`), `take` reverts NotPriced through
/// Liquidator.settle, yet `_elapsed` keeps counting: the sale reaches its 70% floor while nobody could buy.
contract AuditW2SeatClockEthUsdTest is Test {
    uint256 constant T0 = 1_800_000_000;
    EthLeaf median;
    EthLeaf spot;
    EthLeaf eth;
    SeatFeed feed;
    SeatJoin join;

    function setUp() public {
        vm.warp(T0);
        median = new EthLeaf(26 hours); // SEAT_MAX_AGE
        spot = new EthLeaf(26 hours);
        eth = new EthLeaf(1 hours + 10 minutes); // CL ETH/USD in BetaConfig
        median.set(1e18, uint64(T0));
        spot.set(1e18, uint64(T0));
        eth.set(3000e18, uint64(T0));
        feed = new SeatFeed(median, spot, eth);
        P p = new P();
        p.setMedian(IFeed(address(feed)));
        join = new SeatJoin("SEAT", IERC721(address(0x55)), IImdAgentAdapter(address(0x66)), address(this), 25, 3);
        join.wire(address(new L(address(p))));
    }

    function test_clockPausesWhileEthUsdIsStale() public {
        vm.prank(address(0x11));
        join.open(1, address(0x22));
        uint256 start = join.price(1);
        assertEq(start, 3000e18);
        vm.warp(T0 + 1 hours); // one priced hour
        assertEq(join.elapsed(1), 1 hours);
        vm.warp(T0 + 7 hours); // ETH/USD stale since T0 + 70 min: the type is unpriced, no take can settle
        assertTrue(feed.isStale(), "unpriced");
        assertFalse(median.isStale(), "the median leaf alone is fresh");
        // Expected: at most 1 h 10 min of priced time. Actual: 7 h, the price sits at the 70% floor.
        assertLe(join.elapsed(1), 1 hours + 10 minutes, "the clock ran while the type was unpriced");
        assertGt(join.price(1), start * 7 / 10, "sold at the floor while nobody could buy");
    }

    /// After the ETH/USD gap ends (a new round at T0 + 7 h), the gap stays uncounted when the auction was ticked during it
    /// (the keeper ticks an auction whose type goes unpriced), and the clock runs on from there.
    function test_ethUsdGapStaysUncountedAfterARefresh() public {
        vm.prank(address(0x11));
        join.open(1, address(0x22));
        vm.warp(T0 + 3 hours);
        join.tick(1); // in the gap: records that the leg was stale (ETH/USD fresh until T0 + 70 min)
        vm.warp(T0 + 7 hours);
        eth.set(3000e18, uint64(T0 + 7 hours));
        assertEq(join.elapsed(1), 1 hours + 10 minutes, "the gap is not priced time");
        vm.warp(T0 + 8 hours);
        assertEq(join.elapsed(1), 2 hours + 10 minutes, "and the clock runs again");
    }

    /// Chainlink updating hourly with no tick between: every hour counts (the first version of the fix read each unseen
    /// hourly update as a gap, and the clock all but stopped: 2.3 h counted of 25 on the keeper's fork run).
    function test_hourlyEthUpdatesWithoutTicksCountInFull() public {
        vm.prank(address(0x11));
        join.open(1, address(0x22));
        for (uint256 h = 1; h <= 6; ++h) {
            vm.warp(T0 + h * 1 hours);
            eth.set(3000e18, uint64(T0 + h * 1 hours));
        }
        assertEq(join.elapsed(1), 6 hours, "six fresh hours, no tick: six priced hours");
    }
}
