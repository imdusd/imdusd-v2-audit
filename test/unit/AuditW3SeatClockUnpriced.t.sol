// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatJoin} from "src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "src/seats/SeatAccount.sol";
import {SeatFeed} from "src/feeds/SeatFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {ParametersBase} from "src/ParametersBase.sol";

contract Leaf is IFeed {
    uint256 public value;
    uint64 public updatedAt;
    uint64 public acceptedAt;
    uint256 public figure;
    uint256 public immutable maxAge;

    constructor(uint256 maxAge_, uint256 figure_) {
        maxAge = maxAge_;
        figure = figure_;
    }

    function set(uint256 v, uint64 at, uint256 fig) external {
        value = v;
        updatedAt = at;
        acceptedAt = uint64(block.timestamp);
        figure = fig;
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

/// @notice SeatJoin's auction clock (src/seats/SeatJoin.sol:478-519) counts seconds in which the median leaf and the
/// ETH/USD leg are FRESH; the Pricer's `priced` for the seat type is `SeatFeed.latestValue() != 0 && !isStale()`.
/// SeatFeed.latestValue() is median x ETH/USD x factor(), and factor() = liquidity() x trend() where
/// liquidity() = min(1, acceptedFigure / FULL_LIQUIDITY). With the accepted figure (distinct seats sold in 7 days) at 0
/// the type reads 0 = unpriced: `take` reverts NotPriced through Liquidator.settle (_requireUnhealthy), while both legs are
/// fresh and the clock runs. The sale decays to its 70% floor (and voids after 24 h) during hours in which no take can
/// settle: the same impact as wave 2's medium, through the figure instead of the ETH/USD age. Beta values: SEAT_MAX_AGE
/// 26 h, FULL_LIQUIDITY 100, fall cap 20% per update (figure 1 -> 0 is one capped step: 1 x 8000 / 10000 = 0).
contract ProofSeatClockUnpricedFigureTest is Test {
    uint256 constant T0 = 1_800_000_000;
    Leaf median;
    Leaf spot;
    Leaf eth;
    SeatFeed feed;
    SeatJoin join;

    function setUp() public {
        vm.warp(T0);
        median = new Leaf(26 hours, 1); // one distinct seat sold in the last 7 days
        spot = new Leaf(26 hours, 1);
        eth = new Leaf(1 hours + 10 minutes, 0);
        median.set(1e18, uint64(T0), 1);
        spot.set(1e18, uint64(T0), 1);
        eth.set(3000e18, uint64(T0), 0);
        feed = new SeatFeed(median, spot, eth); // records the cap: figureBase 1
        P p = new P();
        p.setMedian(IFeed(address(feed)));
        join = new SeatJoin("SEAT", IERC721(address(0x55)), IImdAgentAdapter(address(0x66)), address(this), 25, 3);
        join.wire(address(new L(address(p))));
    }

    function test_clockRunsWhileTheTypeIsUnpricedByAZeroFigure() public {
        (uint256 v0,) = feed.latestValue();
        assertGt(v0, 0, "priced at the opening");
        vm.prank(address(0x11));
        join.open(1, address(0x22));
        uint256 start = join.price(1);
        assertEq(start, 3000e18, "opened at the fall-capped median (no factor)");

        // T0 + 1 h: a newer, honestly signed median attestation with figure 0 (no distinct seat sold in 7 days); both
        // legs fresh, ETH/USD refreshed hourly.
        vm.warp(T0 + 1 hours);
        median.set(1e18, uint64(T0 + 1 hours), 0);
        eth.set(3000e18, uint64(T0 + 1 hours), 0);
        feed.poke();
        assertEq(feed.acceptedFigure(), 0, "figure 1 -> 0 passes the 20% fall cap");
        (uint256 v,) = feed.latestValue();
        assertEq(v, 0, "SeatFeed reads 0: Pricer.quote(ilk).priced is false, take reverts NotPriced");
        assertFalse(feed.isStale(), "yet both legs are fresh: the clock sees priced time");

        for (uint256 h = 2; h <= 7; ++h) {
            vm.warp(T0 + h * 1 hours);
            eth.set(3000e18, uint64(T0 + h * 1 hours), 0);
        }
        (v,) = feed.latestValue();
        assertEq(v, 0, "still unpriced at T0 + 7 h");
        emit log_named_uint("priced seconds counted", join.elapsed(1));
        emit log_named_uint("price now (start 3000e18)", join.price(1));
        // Expected: at most the 1 h in which the type was priced. Actual: 7 h, the price sits at the 70% floor.
        assertLe(join.elapsed(1), 1 hours, "the clock ran while no take could settle");
        assertGt(join.price(1), start * 7 / 10, "sold at the floor the moment the figure returns");
    }
}
/// @notice PROPERTY (audit wave 3): the auction clock counts only time in which a take could settle, i.e. SeatFeed reads a
/// non-zero value and neither leg is stale. Fuzzed over 60 hourly steps: a median attestation lands or not (figure drawn from
/// {0, 1, 2, 5, 100}, so the accepted figure and with it the type's value fall to 0 and come back through the 20% / 25% caps),
/// the keeper pokes after each landing and ticks when SeatFeed reads 0 and the auction has not recorded it (its rule), and extra ticks land at random. The
/// median can also go stale (sparse landings); the ETH/USD leg is refreshed every hour (its gaps are the wave-2 property, AuditW2SeatClockEthUsd).
///  - never fast: `elapsed` <= the priced seconds of a step-by-step refSecs;
///  - exact when the auction is ticked every hour before the step's events and again after them (the keeper's schedule).
contract AuditW3SeatClockPropertyTest is Test {
    uint256 constant T0 = 1_800_000_000;
    uint256 constant STEPS = 60;
    Leaf median;
    Leaf spot;
    Leaf eth;
    SeatFeed feed;
    SeatJoin join;

    function setUp() public {
        vm.warp(T0);
        median = new Leaf(26 hours, 1);
        spot = new Leaf(26 hours, 1);
        eth = new Leaf(1 hours + 10 minutes, 0);
        median.set(1e18, uint64(T0), 3);
        spot.set(1e18, uint64(T0), 3);
        eth.set(3000e18, uint64(T0), 0);
        feed = new SeatFeed(median, spot, eth);
        P p = new P();
        p.setMedian(IFeed(address(feed)));
        join = new SeatJoin("SEAT", IERC721(address(0x55)), IImdAgentAdapter(address(0x66)), address(this), 25, 3);
        join.wire(address(new L(address(p))));
        vm.prank(address(0x11));
        join.open(1, address(0x22));
    }

    /// @dev mode 0: the keeper's rule (tick when SeatFeed reads 0 unrecorded) plus random ticks; mode 1: also an hourly tick
    /// before the hour's events and a tick after them; mode 2: ticks only right before and right after a median landing
    /// (ETH/USD keeps updating hourly in between, unticked); mode 3: ticks only right before a landing.
    function _run(uint256 seed, uint256 mode) internal returns (uint256 refSecs) {
        uint256[5] memory figures = [uint256(0), 1, 2, 5, 100];
        for (uint256 h = 0; h < STEPS; ++h) {
            uint256 t = T0 + h * 1 hours;
            vm.warp(t);
            uint256 r = uint256(keccak256(abi.encode(seed, h)));
            eth.set(3000e18, uint64(t), 0);
            // Half the seeds land a median every ~3 h, the other half every ~15 h (gaps past its 26 h life: stale stretches).
            bool lands = h != 0 && r % (seed % 2 == 0 ? 3 : 15) == 0;
            if (mode == 1 || (mode >= 2 && lands)) join.tick(1);
            if (lands) {
                median.set(1e18 + (r >> 8) % 1e17, uint64(t), figures[(r >> 80) % 5]);
                feed.poke();
            }
            (,,,,,,, bool recordedZero) = join.auctions(1);
            (uint256 vNow,) = feed.latestValue();
            bool tickNow = mode == 1 || (mode == 2 && lands) || (mode == 0 && ((vNow == 0 && !recordedZero) || (r >> 160) % 4 == 0));
            if (tickNow) join.tick(1);
            // The state now holds for the whole hour (ETH refreshed each hour; the median's 26 h life ends on an hour).
            (uint256 v,) = feed.latestValue();
            (, uint64 mAt) = median.latestValue();
            if (v != 0 && uint256(mAt) + 26 hours >= t + 1 hours) refSecs += 1 hours;
        }
        vm.warp(T0 + STEPS * 1 hours);
    }

    function testFuzz_clockNeverRunsFasterThanPricedTime(uint256 seed) public {
        uint256 refSecs = _run(seed, 0);
        assertLe(join.elapsed(1), refSecs, "the clock counted time in which no take could settle");
    }

    function testFuzz_clockExactWhenTickedEveryStep(uint256 seed) public {
        uint256 refSecs = _run(seed, 1);
        assertEq(join.elapsed(1), refSecs, "ticked hourly and after each event, the clock is exact");
    }

    /// Ticked only around median landings, with ETH/USD heartbeats in between: exact too (a heartbeat after the type is
    /// lifted from 0 must not restart its priced time).
    function testFuzz_clockExactWhenTickedAroundLandings(uint256 seed) public {
        uint256 refSecs = _run(seed, 2);
        assertEq(join.elapsed(1), refSecs, "ticked around each landing, the clock is exact");
    }

    /// Ticked only right before each landing (a stale median recorded at the tick, then ETH/USD heartbeats after the landing):
    /// exact as well. A stale leg at a tick is reconstructed from the legs' times, not treated as a recorded unpriced state.
    function testFuzz_clockExactWhenTickedBeforeLandings(uint256 seed) public {
        uint256 refSecs = _run(seed, 3);
        assertEq(join.elapsed(1), refSecs, "ticked before each landing, the clock is exact");
    }
}
