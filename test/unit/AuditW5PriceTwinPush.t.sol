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
import {TlRate} from "./AuditW4TwinLag.t.sol";

/// @notice AUDIT WAVE 5 (price re-check, HIGH: the twin rule followed the ATTESTED median at once, so honestly attested
/// pushed pool reads plus one pushed proof set sIMD's `low` to the pushed price in one epoch, with no attester key).
///
/// THE PROPERTY SET the twin rule must hold TOGETHER (legs apart, proven spot fresh; c = the median leaf's per-epoch cap,
/// Pricer.TWIN_STEP; m = stored median, a = attested median, s = proven spot):
///   T1 (P4)        low >= s: a wrong or compromised median alone never liquidates below the proven price;
///   T2 (push)      low >= m x (1 - c): no sequence of attestations (honest reads of a pushed pool, or a key) and proofs moves
///                  `low` more than ONE allowance below the stored median, which itself moves one allowance per epoch;
///   T3 (follow)    if the median is clamped above its target (a < m): low <= max(s, a, m x (1 - c)): a fall both legs show is
///                  followed at once to within one allowance of the stored median (to the market when that is closer);
///   T4             low <= max(m, s): never above the wave-3 rule;
///   T5 (liveness)  after a genuine one-block fall of any size, proved at once and attested honestly once per epoch, low
///                  reaches the market one epoch BEFORE the median does (ceil(ln(market/start) / ln(1 - c)) - 1 deliveries).
/// Deploy-shaped graph: median = rate x (leaf x ETH/USD), spot = rate x (proven x ETH/USD), cap 2,000 bps, 1 h, skew 5%.
contract AuditW5PriceTwinPushTest is System {
    bytes32 constant TWIN = "SIMD";
    uint256 constant SKEW = 0.05e18;
    uint256 constant C = 0.2e18; // the median leaf's cap (DoorLeaf: 2,000 bps), = Pricer.TWIN_STEP
    uint256 constant A = 4e15;

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
        leaf.set(A);
        proven = new MockProven(A);
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

    function _honestMedianOf13(uint256 market, uint256 pushed, uint256 pushedSamples) internal pure returns (uint256) {
        uint256[13] memory s;
        for (uint256 i; i < 13; ++i) s[i] = i < 13 - pushedSamples ? market : pushed;
        for (uint256 i; i < 13; ++i) {
            for (uint256 j = i + 1; j < 13; ++j) {
                if (s[j] < s[i]) (s[i], s[j]) = (s[j], s[i]);
            }
        }
        return s[6];
    }

    /// The judge's proof: no key. The pusher holds pool 0xb07d at P at the end of 7 of the 13 blocks a 300-block window
    /// samples; the honest panel signs the median of the reads (= P); anyone relays it and proves the window's last block.
    /// On 422a337: low = $4.40 = the pushed price in the same epoch. Expected: at most one allowance under the clamped median.
    function test_judgeProof_pusherAloneStaysWithinOneAllowance() public {
        Pricer.Quote memory q0 = pricer.quote(TWIN);
        assertTrue(q0.agree);
        assertEq(q0.low, _usd(A));
        vm.roll(vm.getBlockNumber() + 150);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        uint256 pushed = A / 2;
        uint256 honest = _honestMedianOf13(A, pushed, 7);
        assertEq(honest, pushed);
        leaf.set(honest);
        proven.set(pushed);
        Pricer.Quote memory q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        assertEq(m, _usd(A * 8 / 10), "the median leaf is clamped one allowance down (design C)");
        assertTrue(q.priced);
        assertFalse(q.agree);
        assertGe(q.low, m * 8 / 10, "T2: low left one allowance under the stored median (pushed reads + a pushed proof, no key)");
        assertEq(q.low, Math.mulDiv(m, 1e18 - C, 1e18), "low = one allowance under the clamped median");
    }

    /// C1 (key + one pushed proof): bounded the same way.
    function test_keyPlusPushedProofStaysWithinOneAllowance() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(1); // compromised key: attested 1 wei
        proven.set(1); // a pushed block end (the pool cannot really read 1 wei; the bound does not depend on it)
        (uint256 m,) = median.latestValue();
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertGe(q.low, Math.mulDiv(m, 1e18 - C, 1e18), "T2 with a key");
    }

    /// T1-T4, fuzzed over histories of up to 8 epochs of leaf targets (honest, pushed, 1 wei, huge; same-block bursts; late
    /// deliveries) and a final proven price anywhere (a pushed block end, the market, a stale-looking level).
    function testFuzz_twinPropertySet(uint256 seed, uint8 n, uint256 pSeed, bool provenNearTarget) public {
        for (uint256 i; i < uint256(n) % 9; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + bound(r, 0, 3 hours));
            leaf.set(r % 7 == 0 ? 1 : A * bound(r >> 32, 100, 300_000) / 10_000 + 1);
            if ((r >> 128) % 2 == 0) leaf.set(A * bound(r >> 160, 100, 300_000) / 10_000 + 1); // same block
        }
        vm.warp(vm.getBlockTimestamp() + bound(seed >> 200, 0, 1 hours));
        (uint256 held,) = leaf.latestValue();
        uint256 target = held * bound(seed >> 100, 100, 15_000) / 10_000 + 1;
        leaf.set(target);
        proven.set(
            provenNearTarget ? target * bound(pSeed, 9_000, 11_000) / 10_000 + 1 : A * bound(pSeed, 1, 300_000) / 10_000 + 1
        );
        Pricer.Quote memory q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        (uint256 s,) = spot.latestValue();
        uint256 a = FeedTraits.attested(median);
        if (q.agree || m == 0 || s == 0 || median.isStale()) return;
        assertGe(q.low, s, "T1 (P4): below the proven spot");
        assertGe(q.low, Math.mulDiv(m, 1e18 - C, 1e18), "T2: more than one allowance under the stored median");
        if (a < m) assertLe(q.low, Math.max(s, Math.max(a, Math.mulDiv(m, 1e18 - C, 1e18))), "T3: waited for the clamp");
        assertLe(q.low, Math.max(m, s), "T4: above the wave-3 rule");
    }

    /// T5: a genuine fall of 10-95% in one block, proved at once, the honest median attested once per epoch (its window past
    /// the fall). low reaches the market one delivery before the median does, and never sits below the market.
    function testFuzz_genuineFallFollowedOneAllowanceAhead(uint256 fSeed) public {
        uint256 market = A * bound(fSeed, 5, 90) / 100;
        proven.set(market);
        uint256 medianDeliveries;
        uint256 lowDeliveries;
        for (uint256 k = 1; k <= 20; ++k) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            proven.set(market); // re-proved (on age: a proof is fresh for 6 h)
            leaf.set(market);
            Pricer.Quote memory q = pricer.quote(TWIN);
            assertGe(q.low, _usd(market), "never below the market both legs show");
            if (lowDeliveries == 0 && q.low <= _usd(market) * 1001 / 1000) lowDeliveries = k;
            if (medianDeliveries == 0 && leaf.converged()) medianDeliveries = k;
            if (lowDeliveries != 0 && medianDeliveries != 0) break;
        }
        assertGt(lowDeliveries, 0);
        assertGt(medianDeliveries, 0);
        if (medianDeliveries > 1) assertLe(lowDeliveries, medianDeliveries - 1, "T5: low leads the median by one epoch");
    }

    /// A REVIEW OF THE WAVE-5 FIXES: the same no-key push after a >= 2 h silence of the median. With the stale 2x band the leaf
    /// stepped 2c in one attestation and TWIN_STEP was measured from that widened stored median, so low = the pushed price at
    /// once (held $8.80, stored $5.28, low $4.40). T2 measured against the value HELD before the step: low >= held x (1 - c)^2.
    function test_reviewerProof_pushAfterSilenceStaysWithinTwoAllowancesOfTheHeldMedian() public {
        (uint256 held,) = median.latestValue();
        vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
        vm.roll(vm.getBlockNumber() + 600);
        uint256 pushed = A / 2;
        leaf.set(pushed);
        proven.set(pushed);
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced);
        assertGe(q.low, held * 64 / 100, "T2': low more than (1 - c)^2 under the median held before the step");
    }

    /// T2' fuzzed with silences (0 to 30 h before any delivery, the final one included): whatever the history, the final
    /// delivery plus any proof leaves low >= (median held just before it) x (1 - c)^2, and the median itself >= held x (1 - c).
    function testFuzz_T2_againstTheHeldMedianWithSilences(uint256 seed, uint8 n, uint256 pSeed, uint256 silSeed) public {
        for (uint256 i; i < uint256(n) % 7; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + (r % 3 == 0 ? bound(r >> 8, 2 hours, 30 hours) : bound(r >> 8, 0, 1 hours)));
            leaf.set(A * bound(r >> 32, 1, 300_000) / 10_000 + 1);
        }
        vm.warp(vm.getBlockTimestamp() + bound(silSeed, 0, 30 hours));
        (uint256 held,) = median.latestValue();
        leaf.set(A * bound(seed >> 64, 1, 300_000) / 10_000 + 1);
        proven.set(A * bound(pSeed, 1, 300_000) / 10_000 + 1);
        Pricer.Quote memory q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        assertGe(m + 1, held * 8 / 10, "the median moved more than one allowance from the value held");
        if (!q.priced || q.agree) return;
        assertGe(q.low + 1, held * 64 / 100, "T2': low more than (1 - c)^2 under the median held before the delivery");
    }

    /// T5 after a genuine SILENCE plus fall (the median unbought for 2-30 h, then the market 5-90% lower): the first honest
    /// delivery prices again and low leads the median by one epoch to the market, as without the silence (no 2x step now).
    function testFuzz_genuineSilenceThenFallFollowed(uint256 fSeed, uint256 silSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(silSeed, 2 hours, 30 hours));
        uint256 market = A * bound(fSeed, 5, 90) / 100;
        uint256 medianDeliveries;
        uint256 lowDeliveries;
        for (uint256 k = 1; k <= 20; ++k) {
            proven.set(market);
            leaf.set(market);
            Pricer.Quote memory q = pricer.quote(TWIN);
            assertTrue(q.priced, "priced again at the first honest delivery");
            assertGe(q.low, _usd(market), "never below the market");
            if (lowDeliveries == 0 && q.low <= _usd(market) * 1001 / 1000) lowDeliveries = k;
            if (medianDeliveries == 0 && leaf.converged()) medianDeliveries = k;
            if (lowDeliveries != 0 && medianDeliveries != 0) break;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        if (medianDeliveries > 1) assertLe(lowDeliveries, medianDeliveries - 1, "low leads the median by one epoch");
        assertGt(lowDeliveries, 0);
    }

    /// T5 under the UP-FIRST schedule (a review of the wave-5 fixes): an adversary relays an up value first in every epoch, the
    /// honest median of a 50% lower market follows; the proof is re-proved each epoch. The median holds at 0.96x per epoch and
    /// low = 0.8x of it: low reaches the market after 12 epochs (3 with no adversary), never below it, and every epoch moves it.
    function test_T5_upFirstScheduleIsBoundedNotStopped() public {
        uint256 market = A / 2;
        uint256 lastLow = type(uint256).max;
        uint256 reached;
        for (uint256 k = 1; k <= 14; ++k) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            (uint256 held,) = leaf.latestValue();
            leaf.set(held * 10); // first in the epoch, up
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            proven.set(market);
            leaf.set(market);
            Pricer.Quote memory q = pricer.quote(TWIN);
            assertGe(q.low, _usd(market));
            assertTrue(q.low < lastLow || q.low == _usd(market), "every epoch moves low toward the market");
            lastLow = q.low;
            if (reached == 0 && q.low == _usd(market)) reached = k;
        }
        assertEq(reached, 12, "12 epochs under the up-first schedule");
    }

    /// A pusher sustaining the attack every epoch (7 pushed samples + one pushed proof each epoch) moves low one allowance per
    /// epoch, one allowance ahead of the median: (1 - c)^(k + 1) after k epochs, never the pushed price at once.
    function test_sustainedPushIsOneAllowancePerEpoch() public {
        uint256 pushed = A / 10;
        for (uint256 k = 1; k <= 3; ++k) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            leaf.set(pushed);
            proven.set(pushed);
            Pricer.Quote memory q = pricer.quote(TWIN);
            uint256 expect = _usd(A);
            for (uint256 j; j <= k; ++j) expect = expect * 8 / 10;
            assertApproxEqRel(q.low, expect, 1e12, "(1 - c)^(k+1)");
        }
    }
}
