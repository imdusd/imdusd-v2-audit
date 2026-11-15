// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy, SwarmNhiPolicy} from "../../src/feeds/SwarmFeeds.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";

/// @dev A real clamp leaf (production question binding) with a TEST-ONLY door to `_accept`, so a target is set without a
/// signature. The clamp, the epoch and the traits are the production code.
contract DoorLeaf is SwarmPricePolicy {
    constructor() SwarmFeed(address(1), address(0), 1, 3, 1 hours, 2000) {}

    function set(uint256 target) external {
        _accept(target, uint64(block.timestamp));
    }
}

contract DoorNhiLeaf is SwarmNhiPolicy {
    constructor() SwarmFeed(address(1), address(0), 1, 3, 1 days, 2000) {}

    function set(uint256 target) external {
        _accept(target, uint64(block.timestamp));
    }
}

/// @dev Stands in for ProvenPoolPrice's value; the trait is the one ProvenPoolPrice reports.
contract MockProven is MockFeed {
    constructor(uint256 v) MockFeed(v) {}

    function proven() external pure returns (bool) {
        return true;
    }
}

/// @dev A feed whose `converged()` burns all the gas it is given: FeedTraits must revert, not read "converged".
contract GasBurner is MockFeed {
    constructor(uint256 v) MockFeed(v) {}

    function converged() external pure returns (bool) {
        while (true) {}
        return true;
    }
}

/// @notice Price design C in the Pricer (P4 = the twin rule, and the convergence rule), on the sIMD-shaped graph the deploy builds: median =
/// clamp leaf x ETH/USD, spot = proven x ETH/USD, NHI = clamp leaf, a live leg. A second type with a swarm-style spot (no
/// proven trait) keeps today's rule.
contract PricerTwinTest is System {
    bytes32 constant TWIN = "SIMD";
    bytes32 constant PLAIN = "PLAIN";
    uint256 constant SKEW = 0.05e18;
    uint256 constant ETHUSD = 2000e18;

    DoorLeaf leaf;
    DoorLeaf plainLeaf;
    DoorNhiLeaf nhi;
    MockProven proven;
    MockFeed plainSpot;
    MockFeed ethFeed;
    MockFeed live;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        leaf = new DoorLeaf();
        plainLeaf = new DoorLeaf();
        nhi = new DoorNhiLeaf();
        proven = new MockProven(4e15);
        plainSpot = new MockFeed(4e15);
        ethFeed = new MockFeed(ETHUSD);
        live = new MockFeed(4e15 * 2000);
        leaf.set(4e15);
        plainLeaf.set(4e15);
        nhi.set(0.98e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        ParametersBase.Risk memory r = _risk(1.7e18, 10_000_000e18);
        r.skew = uint64(SKEW);
        r.redeemCap = 20_000e18; // a type with a live leg is never uncapped
        IFeed eth = IFeed(address(ethFeed));
        _addIlk(
            TWIN,
            address(new MockERC20("sIMD", 18)),
            new ProductFeed(IFeed(address(leaf)), eth),
            new ProductFeed(IFeed(address(proven)), eth),
            IFeed(address(nhi)),
            address(0),
            address(0),
            IFeed(address(live)),
            true,
            r
        );
        _addIlk(
            PLAIN,
            address(new MockERC20("X", 18)),
            new ProductFeed(IFeed(address(plainLeaf)), eth),
            new ProductFeed(IFeed(address(plainSpot)), eth),
            IFeed(address(0)),
            address(0),
            address(0),
            true,
            r
        );
        params.seal();
    }

    function _fresh() internal {
        ethFeed.set(ETHUSD);
        live.set(live.value());
    }

    /// The traits read through the deployed composites: the twin's spot is proven, its median is not; both converged.
    function test_traitsThroughComposites() public view {
        ParametersBase.Config memory c = params.config(TWIN);
        assertTrue(FeedTraits.proven(c.spot));
        assertFalse(FeedTraits.proven(c.median));
        assertTrue(FeedTraits.converged(c.median));
        assertTrue(FeedTraits.converged(c.spot), "a feed without the function counts as converged");
        assertFalse(FeedTraits.proven(params.config(PLAIN).spot));
    }

    /// P4 (fuzzed): whatever the median leaf holds (a compromised or wrong target, clamped or not) and whatever the proven
    /// price, while the proven spot is fresh the liquidation price `low` is never more than `skew` below the proven price,
    /// never more than `skew` below the median, and equals max(median, spot) whenever the legs do not agree. Borrowing only
    /// when they agree AND both legs and NHI are converged.
    function testFuzz_P4_twinRule(uint256 mSeed, uint256 pSeed, uint256 tSeed, bool clampIt, bool spotStale) public {
        uint256 m = bound(mSeed, 1e13, 1e17);
        uint256 p = bound(pSeed, 1e13, 1e17);
        vm.warp(vm.getBlockTimestamp() + 2 hours); // a new epoch on the leaf
        leaf.set(m);
        if (clampIt) leaf.set(m * bound(tSeed, 2, 50)); // inside the same epoch: clamped, not converged
        proven.set(p);
        if (spotStale) proven.setStale(true);
        _fresh();
        (uint256 mv,) = leaf.latestValue();
        uint256 mUsd = mv * ETHUSD / 1e18;
        uint256 pUsd = p * ETHUSD / 1e18;
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced, "a clamped or disagreeing leg still prices");
        assertGe(q.low * 1e18, mUsd * (1e18 - SKEW), "never more than skew below the median");
        if (!spotStale) {
            assertGe(q.low * 1e18, pUsd * (1e18 - SKEW), "P4: never more than skew below the proven price");
            if (!q.agree) assertEq(q.low, mUsd > pUsd ? mUsd : pUsd, "disagreeing legs: the higher leg");
        } else {
            assertEq(q.low, mUsd, "a stale proven spot: the median alone, as today");
            assertFalse(q.agree);
        }
        assertLe(q.low, q.high);
        if (q.borrowable) {
            assertTrue(q.agree);
            assertTrue(leaf.converged(), "borrowing only at an attested median");
        }
        if (!leaf.converged()) assertFalse(q.agree, "a clamped leg never agrees");
    }

    /// A clamped median whose VALUE equals the spot still does not agree: no new debt at a value nobody attested.
    function test_convergedOnlyAgree() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours); // the epoch has run out; the leaf is not yet silent long enough for 2x
        leaf.set(4e15);
        leaf.set(8e15); // clamped to 4.8e15
        (uint256 mv,) = leaf.latestValue();
        assertEq(mv, 4.8e15);
        proven.set(4.8e15);
        live.set(4.8e15 * 2000);
        _fresh();
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced);
        assertFalse(q.agree);
        assertFalse(q.borrowable);
        assertEq(q.low, 4.8e15 * 2000);
        // The next epoch: an honest 4.8e15 converges it, and the pair agrees again.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(4.8e15);
        proven.set(4.8e15);
        _fresh();
        q = pricer.quote(TWIN);
        assertTrue(q.agree && q.borrowable);
    }

    /// An NHI leaf held short of its target stops borrowing (its mat is one nobody attested), not agreement or liquidation.
    function test_unconvergedNhiStopsBorrowingOnly() public {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        nhi.set(0.98e18);
        nhi.set(0.5e18); // clamped to 0.588e18 (2x the cap after the silence)
        assertFalse(nhi.converged());
        _fresh();
        leaf.set(4e15);
        proven.set(4e15);
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced && q.agree);
        assertFalse(q.borrowable);
    }

    /// A type whose spot is not proven keeps today's rule: disagreeing legs collapse to the median.
    function testFuzz_plainTypeKeepsTheMedianRule(uint256 mSeed, uint256 sSeed) public {
        uint256 m = bound(mSeed, 1e13, 1e17);
        uint256 s = bound(sSeed, 1e13, 1e17);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        plainLeaf.set(m);
        (uint256 mv,) = plainLeaf.latestValue();
        plainSpot.set(s);
        _fresh();
        Pricer.Quote memory q = pricer.quote(PLAIN);
        if (!q.agree) assertEq(q.low, mv * ETHUSD / 1e18);
        else assertEq(q.low, (mv < s ? mv : s) * ETHUSD / 1e18);
    }

    /// FeedTraits: a `converged()` that runs out of gas reverts the read instead of answering "converged".
    function test_traitOutOfGasReverts() public {
        GasBurner g = new GasBurner(1);
        vm.expectRevert(abi.encodeWithSelector(FeedTraits.TraitUnreadable.selector, address(g)));
        this.readConverged(IFeed(address(g)));
    }

    function readConverged(IFeed f) external view returns (bool) {
        return FeedTraits.converged(f);
    }
}
