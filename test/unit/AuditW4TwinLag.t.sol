// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";
import {DoorLeaf, MockProven} from "./PricerTwin.t.sol";

contract TlRate {
    uint256 public r = 1.1e18;

    function convertToAssets(uint256 s) external view returns (uint256) {
        return s * r / 1e18;
    }
}

/// @notice AUDIT WAVE 4 (price design, medium: the twin follows the CLAMPED median for k epochs after a fall). PROPERTY:
/// with the legs apart and the proven spot fresh, `low` is never above max(spot, attested median) when the median is
/// clamped above its own attested target (a fall both legs show is followed at once, not one allowance per epoch), while
/// P4 keeps: `low` is never below the proven spot, and never below min(median, attested median) (a pushed spot cannot lower
/// it below what the median attested). Deploy-shaped graph: median = rate x (leaf x ETH/USD), spot = rate x (proven x
/// ETH/USD), cap 2,000 bps, 1 h, skew 5%.
contract AuditW4TwinLagTest is System {
    bytes32 constant TWIN = "SIMD";
    uint256 constant SKEW = 0.05e18;

    DoorLeaf leaf;
    MockProven proven;
    MockFeed eth;
    MockFeed live;
    TlRate vault;
    IFeed median;
    IFeed spot;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        leaf = new DoorLeaf();
        leaf.set(4e15);
        proven = new MockProven(4e15);
        proven.setMaxAge(6 hours);
        eth = new MockFeed(2000e18);
        eth.setMaxAge(type(uint64).max);
        live = new MockFeed(type(uint128).max);
        live.setMaxAge(type(uint64).max);
        vault = new TlRate();
        median = IFeed(
            address(new RateFeed(address(vault), TlRate.convertToAssets.selector, true, new ProductFeed(IFeed(address(leaf)), eth), 0))
        );
        spot = IFeed(
            address(new RateFeed(address(vault), TlRate.convertToAssets.selector, true, new ProductFeed(IFeed(address(proven)), eth), 0))
        );
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        ParametersBase.Risk memory r = _risk(1.7e18, 10_000_000e18);
        r.skew = uint64(SKEW);
        r.redeemCap = 20_000e18;
        _addIlk(TWIN, address(new MockERC20("sIMD", 18)), median, spot, IFeed(address(0)), address(0), address(0), live, true, r);
        params.seal();
    }

    function _usd(uint256 imdEth) internal view returns (uint256) {
        return imdEth * 2000e18 / 1e18 * vault.r() / 1e18;
    }

    /// The judge's sequence: a one-block fall of 60%, proved at once, honest medians once per epoch. Was: low / market =
    /// 2.0, 1.6, 1.28, 1.024, 1.0 over five epochs. Now: at the market from the first honest median after the fall.
    function test_judgeProof_fallFollowedAtTheFirstHonestMedian() public {
        uint256 market = 4e15 * 40 / 100;
        proven.set(market);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(market);
        (uint256 m,) = median.latestValue();
        assertGt(m, _usd(market), "the median leaf is still clamped above the market");
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced);
        assertFalse(q.agree, "no borrowing at the clamped median");
        assertEq(q.low, _usd(market), "low at the market both legs show");
    }

    /// PROPERTY (fuzzed over a history of up to 6 epochs of leaf targets, honest or pushed, clamped or not, a delivery late in
    /// the last epoch, and the proven price): in the twin branch (legs apart, spot fresh)
    ///   low >= spot                                  (P4: a wrong median alone cannot liquidate below the proven price)
    ///   low >= min(median, attested median)          (a pushed spot cannot lower low below what the median attested)
    ///   low <= max(spot, attested median) if the median is clamped above its target  (follow at once)
    ///   low <= max(median, spot)                     (never above the old rule)
    function testFuzz_twinFollowsTheAttestedFall(uint256 seed, uint8 n, uint256 pSeed, bool nearTarget) public {
        uint256 base = 4e15;
        for (uint256 i; i < uint256(n) % 7; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + bound(r, 0, 2 hours));
            leaf.set(base * bound(r >> 32, 500, 300_000) / 10_000 + 1);
            if ((r >> 128) % 2 == 0) leaf.set(base * bound(r >> 160, 500, 300_000) / 10_000 + 1); // same block
        }
        // The last delivery: often a fall past the cap (a genuine one, or a compromised key), within the hour.
        vm.warp(vm.getBlockTimestamp() + bound(seed >> 200, 0, 1 hours));
        (uint256 held,) = leaf.latestValue();
        uint256 target = held * bound(seed >> 100, 500, 15_000) / 10_000 + 1;
        leaf.set(target);
        // The proven price: near that target (the fall both legs show; within +-10%) or anywhere (a pushed or stale-looking one).
        proven.set(nearTarget ? target * bound(pSeed, 9_000, 11_000) / 10_000 + 1 : base * bound(pSeed, 500, 300_000) / 10_000 + 1);
        Pricer.Quote memory q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        (uint256 s,) = spot.latestValue();
        uint256 a = _usd(leaf.attested()); // = FeedTraits.attested(median) on the fixed code
        if (q.agree || m == 0 || s == 0 || median.isStale()) return;
        assertGe(q.low, s, "P4: below the proven spot");
        assertGe(q.low, Math.min(m, a), "below what the median attested");
        if (a < m) assertLe(q.low, Math.max(s, a), "waited for the clamp: above both legs' fall");
        assertLe(q.low, Math.max(m, s), "above the old rule");
    }

    /// P7 (fuzzed over a fall of 10-90% in one block): once the fall is proved and ONE honest median of the fallen level has
    /// landed, low is the market; a lagging honest median (window not yet past the fall) holds low at what it attested.
    function testFuzz_P7_oneMedianAfterTheProofEndsTheShelter(uint256 fSeed, uint256 lagSeed) public {
        uint256 market = 4e15 * bound(fSeed, 10, 90) / 100;
        proven.set(market);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 lagged = market + (4e15 - market) * bound(lagSeed, 0, 100) / 100; // a window median partly past the fall
        leaf.set(lagged);
        Pricer.Quote memory q = pricer.quote(TWIN);
        if (q.agree) return; // a small fall within skew: the agree branch
        assertEq(q.low, _usd(lagged), "low = what the median attested (>= the proven market), not the clamped level");
        assertEq(FeedTraits.attested(median), _usd(lagged));
    }

    /// A wrong or compromised median alone (attested far below, spot honest at the old level) liquidates at the proven price,
    /// never below it (P4); a pushed-down proven price with an honest converged median is held at the median.
    function test_singleLegAttacksKeepP4() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(1); // compromised key: clamped to 0.8 x, attested 1 wei
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertEq(q.low, _usd(4e15), "the proven price, not the attested 1 wei");
        // honest median back (converged), proven pushed down 30%
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(4e15);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(4e15);
        assertTrue(FeedTraits.converged(median));
        proven.set(4e15 * 70 / 100);
        q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        assertEq(q.low, m, "a pushed spot alone cannot lower low below a converged median");
    }
}
