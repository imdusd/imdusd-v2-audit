// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy, SwarmNhiPolicy} from "../../src/feeds/SwarmFeeds.sol";
import {DoorLeaf, DoorNhiLeaf} from "./PricerTwin.t.sol";

/// @dev The shipped price-leg rule with a configurable cap (the shipped legs use 2,000 bps; seat spot 5,000).
contract CapLeaf is SwarmPricePolicy {
    constructor(uint256 cap) SwarmFeed(address(1), address(0), 1, 3, 1 hours, cap) {}

    function set(uint256 target) external {
        _accept(target, uint64(block.timestamp));
    }
}

/// @notice AUDIT WAVE 5 (price re-check, medium: the epoch band is anchored at the epoch's OPENING value, not the value held).
/// After an honest move inside an epoch, ONE attestation moved the stored value to the opposite edge of the anchor's band:
/// (1+c)/(1-c) - 1 = +50% or 1 - (1-c)/(1+c) = -33% from the value held (NHI 0.85 -> 0.568, mat 1.70 -> 2.00 in one
/// second), and a second one across the boundary a second later +80% / -46.7% (stated: +44% / -36% over a closed maxAge).
///
/// PROPERTY (R1, step from the value held): within one epoch every value the feed stores lies within ONE cap of every
/// other value it stored in that epoch, the anchor included, so one attestation moves the stored value at most one cap
/// from the value held, whatever was relayed before it in the epoch. Consequences: (R2) over any closed window of one
/// maxAge with no silence a price leg moves at most (1+c)^2 - 1 up / 1 - (1-c)^2 down from a value held at its start, and
/// NHI (and mat) at most one cap from the value held per attestation. LIVENESS (P2) is kept: each new epoch opens at the
/// stored value with the full allowance, so honest attestations still reach any level within
/// ceil(ln(ratio) / ln(1 + c)) epochs (SwarmFeedProperties, AuditW5NhiWindow, re-run unchanged).
contract AuditW5PriceEpochRangeTest is Test {
    uint256 clock = 1_800_000_000;

    function setUp() public {
        vm.chainId(1);
        vm.warp(clock);
        vm.roll(26_000_000);
    }

    function _warp(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _val(SwarmFeed f) internal view returns (uint256 v) {
        (v,) = f.latestValue();
    }

    /// Judge's proof (a): NHI honest 0.71 -> 0.78 -> 0.85 inside a day, then ONE attestation of 1 wei a second later.
    /// On 422a337: 0.568 (mat 2.00). Expected: >= 0.68 (one cap from 0.85; mat <= 1.904).
    function test_judgeProof_nhiOneAttestationFromTheHeldValue() public {
        DoorNhiLeaf nhi = new DoorNhiLeaf();
        nhi.set(0.71e18);
        _warp(1 days);
        nhi.set(0.71e18);
        _warp(6 hours);
        nhi.set(0.78e18);
        _warp(6 hours);
        nhi.set(0.85e18);
        assertTrue(nhi.converged());
        _warp(1);
        nhi.set(1);
        assertGe(_val(nhi), 0.68e18, "NHI moved more than one cap from the value it held a second before");
    }

    /// Judge's proof (b): a price leg falls honestly 100 -> 80 in an epoch, then the key at the last
    /// second of the epoch and the first of the next. On 422a337: 120 then 144. Expected: <= 96 then <= 115.2.
    function test_judgeProof_legPlus80InOneSecond() public {
        DoorLeaf leg = new DoorLeaf();
        leg.set(100e18);
        _warp(1 hours);
        leg.set(100e18);
        _warp(20 minutes);
        leg.set(80e18);
        _warp(40 minutes - 1);
        leg.set(type(uint128).max);
        assertLe(_val(leg), 96e18, "one attestation moved the leg more than one cap from the value it held");
        _warp(1);
        leg.set(type(uint128).max);
        assertLe(_val(leg), 115.2e18, "closed maxAge moved more than (1+c)^2 - 1 from the honest level");
    }

    /// The mirror: honest rally 100 -> 120, then 1 wei twice. On 422a337: 80 then 64. Expected: >= 96 then >= 76.8.
    function test_judgeProof_legMinus47InOneSecond() public {
        DoorLeaf leg = new DoorLeaf();
        leg.set(100e18);
        _warp(1 hours);
        leg.set(100e18);
        _warp(20 minutes);
        leg.set(120e18);
        _warp(40 minutes - 1);
        leg.set(1);
        assertGe(_val(leg), 96e18, "one attestation moved the leg more than one cap from the value it held");
        _warp(1);
        leg.set(1);
        assertGe(_val(leg), 76.8e18, "closed maxAge moved more than 1 - (1-c)^2 from the honest level");
    }

    struct Track {
        uint64 opened;
        uint256 lo;
        uint256 hi;
    }

    /// R1, fuzzed: any cap (500-5,000 bps), any history of targets (honest, 1 wei, huge, within or past the band), any
    /// timing (same block, within an epoch, at the boundary, after silences that earn the wide step).
    function testFuzz_R1_oneCapFromEveryValueHeldInTheEpoch(uint256 capSeed, uint256 seed, uint8 n) public {
        uint256 cap = bound(capSeed, 500, 5_000);
        CapLeaf leg = new CapLeaf(cap);
        leg.set(1e18);
        Track memory t;
        (uint256 a0, uint64 o0,) = leg.epoch();
        (t.opened, t.lo, t.hi) = (o0, a0, a0);
        for (uint256 i; i < uint256(n) % 24 + 1; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 dtKind = r % 5;
            if (dtKind == 1) _warp(bound(r >> 8, 1, 30 minutes));
            else if (dtKind == 2) _warp(1 hours - 1);
            else if (dtKind == 3) _warp(1);
            else if (dtKind == 4) _warp(bound(r >> 8, 1 hours, 5 hours));
            uint256 held = _val(leg);
            uint256 kind = (r >> 64) % 4;
            uint256 target = kind == 0 ? 1 : kind == 1 ? type(uint128).max : held * bound(r >> 96, 1, 30_000) / 10_000 + 1;
            leg.set(target);
            uint256 v = _val(leg);
            (uint256 anchor, uint64 opened,) = leg.epoch();
            if (opened != t.opened) {
                // a new epoch: it starts at its anchor (the value held, or the wide step's landing)
                (t.opened, t.lo, t.hi) = (opened, anchor, anchor);
            }
            assertGe(v + 1, t.hi - t.hi * cap / 10_000, "R1: more than one cap under a value held this epoch");
            assertLe(v, t.lo + t.lo * cap / 10_000 + 1, "R1: more than one cap over a value held this epoch");
            if (v < t.lo) t.lo = v;
            if (v > t.hi) t.hi = v;
        }
    }

    /// R1 for NHI (carried anchor, no widening): one attestation moves NHI at most one cap from the value held.
    function testFuzz_R1_nhiOneCapFromTheHeldValue(uint256 seed, uint8 n) public {
        DoorNhiLeaf nhi = new DoorNhiLeaf();
        nhi.set(0.9e18);
        for (uint256 i; i < uint256(n) % 20 + 1; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 dtKind = r % 4;
            if (dtKind == 1) _warp(bound(r >> 8, 1, 12 hours));
            else if (dtKind == 2) _warp(1 days - 1);
            else if (dtKind == 3) _warp(1);
            uint256 held = _val(nhi);
            uint256 kind = (r >> 64) % 3;
            nhi.set(kind == 0 ? 1 : kind == 1 ? 5e18 : held * bound(r >> 96, 1, 30_000) / 10_000 + 1);
            uint256 v = _val(nhi);
            assertGe(v + 1, held - held / 5, "NHI fell more than one cap from the value held");
            assertLe(v, held + held / 5 + 1, "NHI rose more than one cap from the value held");
        }
    }

    /// R2: over any closed window of one maxAge with no silence, a price leg moves at most (1+c)^2 - 1 up / 1 - (1-c)^2 down
    /// from the value held at the window's start, wherever that start falls in an epoch (here: after honest moves inside it).
    function testFuzz_R2_closedWindowFromTheHeldValue(uint256 seed, uint256 hSeed, uint256 offSeed, uint8 n) public {
        DoorLeaf leg = new DoorLeaf();
        leg.set(1e18);
        _warp(1 hours);
        leg.set(1e18); // an epoch opens at 1.0
        // honest moves inside the epoch, then the window starts at the value they left
        uint256 off = bound(offSeed, 1, 1 hours - 1);
        _warp(off / 2);
        leg.set(bound(hSeed, 0.5e18, 1.5e18));
        _warp(off - off / 2);
        uint256 start = clock;
        uint256 startVal = _val(leg);
        uint256 m = uint256(n) % 10 + 1;
        for (uint256 i; i < m; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _warp(bound(r, 0, start + 1 hours - clock));
            uint256 kind = (r >> 64) % 3;
            leg.set(kind == 0 ? 1 : kind == 1 ? type(uint128).max : startVal * bound(r >> 96, 1, 30_000) / 10_000 + 1);
            uint256 v = _val(leg);
            assertLe(v, startVal * 144 / 100 + 1, "R2: over (1+c)^2 - 1 within a closed maxAge");
            assertGe(v + 1, startVal * 64 / 100, "R2: under 1 - (1-c)^2 within a closed maxAge");
        }
    }

    /// A REVIEW OF THE WAVE-5 FIXES: the first-relayer hold, bounded. An adversary (a key, or pushed pool reads attested
    /// honestly) relays ONE value per epoch, FIRST or LAST (its choice, every epoch), the honest relayer delivers the market
    /// (50-95% below) once per epoch. With the range the epoch ends at most (1 + c)(1 - c) = 0.96x the last epoch's value
    /// (or within a cap of the market) WHICHEVER position the adversary takes: the up-first schedule holds a genuine fall to
    /// -4% per epoch, and the up-LAST schedule, which under the anchor-only rule (422a337) ended every epoch at +20%
    /// (a reversal; the stated last-relayer residual), now also ends at -4%. No rule on stored values can do better for the
    /// first-relayer case without reopening the wave-5 medium (a review of the wave-5 fixes).
    function testFuzz_oneRelayAdversaryHoldsAtMostFourPercentPerEpoch(uint256 mSeed, uint256 orderSeed, uint256 upSeed) public {
        DoorLeaf leg = new DoorLeaf();
        uint256 a0 = 1e18;
        leg.set(a0);
        uint256 market = a0 * bound(mSeed, 5, 50) / 100;
        uint256 prev = a0;
        for (uint256 k; k < 12; ++k) {
            _warp(1 hours);
            bool first = (orderSeed >> k) & 1 == 0;
            uint256 up = prev * bound(uint256(keccak256(abi.encode(upSeed, k))), 10_001, 1_000_000) / 10_000;
            if (first) leg.set(up);
            _warp(10 minutes);
            leg.set(market);
            if (!first) {
                _warp(10 minutes);
                leg.set(up);
            }
            uint256 v = _val(leg);
            uint256 bound_ = prev * 96 / 100 > market * 12 / 10 ? prev * 96 / 100 : market * 12 / 10;
            assertLe(v, bound_ + 2, "a one-relay adversary held the epoch above (1+c)(1-c) of the last epoch");
            prev = v;
        }
    }

    /// The view mirrors the store: followOf(target) is what a delivery stores, in a live epoch with a range and at a boundary.
    function testFuzz_followOfMirrorsTheStore(uint256 seed, uint8 n) public {
        DoorLeaf leg = new DoorLeaf();
        leg.set(1e18);
        for (uint256 i; i < uint256(n) % 16 + 1; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 3 == 0) _warp(bound(r >> 8, 1, 3 hours));
            uint256 target = (r >> 64) % 3 == 0 ? 1 : _val(leg) * bound(r >> 96, 1, 30_000) / 10_000 + 1;
            uint256 predicted = leg.followOf(target);
            leg.set(target);
            assertEq(_val(leg), predicted, "followOf");
        }
    }
}
