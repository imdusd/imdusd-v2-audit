// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmSpotPolicy} from "src/feeds/SwarmFeeds.sol";
import {Relayer} from "./SwarmFeedProperties.t.sol";

/// @dev The production SPOT question binding, a test signer, the beta's lifetime (1 h) and cap (2,000 bps), as the judge's proofs.
contract W3Leaf is SwarmSpotPolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// @notice Audit wave 3 (2-prices, judge ff9ebb9d), the two SwarmFeed mediums, ported to price design C (2026-11-14):
///  1. "three pushes after a two-hour silence lock the honest level out for good; README says four" (ProofWayBackThreeAfter
///     SilenceTest): the same three pushes now leave the honest level reachable, and reached within the P2 bound.
///  2. "the way back re-records a PUSHED anchor: one attestation per epoch swings the feed +72.8% / -42% for good"
///     (ProofWayBackStepTest): the same alternating attestations now move the stored value at most one allowance per epoch
///     (P1), and nothing pushed is remembered (P3).
/// The judge's measurements of the largest one-step move (+87.5% fresh, +150% after a silence) are re-measured under the
/// rule: at most the cap from the anchor (2x after a silence).
contract AuditW3WayBackTest is Relayer {
    W3Leaf f;
    uint256 constant A = 4e15;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        f = new W3Leaf(vm.addr(KEY));
    }

    function _submit(uint256 value) internal {
        (SwarmFeed.OracleAttestation memory a, bytes memory sig) = _att(f, value);
        f.submitAttestation(a, sig);
    }

    function _value() internal view returns (uint256 v) {
        (v,) = f.latestValue();
    }

    function _stepBps(uint256 before, uint256 after_) internal pure returns (uint256) {
        return _dist(before, after_) * 10_000 / before;
    }

    /// Finding 1: A; silence; 1.4A (wide epoch); 1.68A; 2.016A. Under design C the pushes land as targets and the stored
    /// value reaches 1.4A, 1.68A, 2.016A (each inside its epoch's band). The honest A, tried every ten minutes, is accepted
    /// on every try and reaches A within ceil(ln 2.016 / ln 1.2) = 4 epochs (falls are faster: 3 here).
    function test_W3_threePushesAfterASilenceDoNotLockTheHonestLevelOut() public {
        _submit(A);
        _advance(2 hours + 1);
        (,, uint256 allowance) = f.epoch();
        assertEq(allowance, 4000, "stale allowance");
        _submit(A * 140 / 100);
        _advance(1 hours);
        _submit(A * 168 / 100);
        _advance(1 hours);
        _submit(A * 2016 / 1000);
        assertEq(_value(), A * 2016 / 1000, "three pushes landed");
        uint256 t0 = vm.getBlockTimestamp();
        uint256 bound = _epochBound(_value(), A, 2000);
        assertEq(bound, 4);
        uint256 tries;
        while (_value() != A) {
            _advance(10 minutes);
            _submit(A); // never refused
            ++tries;
            assertLe(tries, 6 * bound, "P2 bound missed");
        }
        emit log_named_uint("minutes until the honest level was the stored value", (vm.getBlockTimestamp() - t0) / 60);
        assertTrue(f.converged());
    }

    /// Finding 2: after the three-push ratchet (A, 1.2A, 1.44A, 1.728A) and the honest return, one attestation per epoch
    /// alternating 1.728A and A swung the feed +72.8% / -42% every hour for good. Under design C every accepted step stays
    /// within the cap of its epoch's anchor (the feed is fresh: no 2x), and the alternation cannot keep the value at either end.
    function test_W3_oneAttestationPerEpochMovesTheFeedAtMostTheCap() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 120 / 100);
        _advance(1 minutes);
        _submit(A * 144 / 100);
        _advance(60 minutes);
        _submit(A * 1728 / 1000);
        _advance(60 minutes);
        _submit(A); // honest: the value falls one cap, to 1.3824A (not back to A in one step: no way back)
        assertEq(_value(), A * 13824 / 10_000);
        for (uint256 i; i < 12; ++i) {
            _advance(60 minutes);
            uint256 before = _value();
            (uint256 anchor,, uint256 bps) = f.epoch();
            assertEq(anchor, before, "each epoch anchors at the stored value, never at a remembered pushed level");
            _submit(i % 2 == 0 ? A * 1728 / 1000 : A);
            uint256 step = _stepBps(before, _value());
            emit log_named_uint("one-step move, bps", step);
            assertLe(step, bps, "P1: one attestation moves the stored value at most the epoch's allowance");
            assertLe(bps, 2000, "the feed is fresh: no stale allowance");
        }
    }

    /// The judge's measurement (fresh feed): A, 0.8A at minute 59, 0.64A at minute 60, then a 1.2A target at minute 120. The
    /// way back took 0.64A -> 1.2A (+87.5%). Now: +20% from the anchor 0.64A.
    function test_W3_largestOneStepMoveFresh() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 80 / 100);
        _advance(1 minutes);
        _submit(A * 64 / 100);
        _advance(60 minutes);
        assertFalse(f.isStale());
        assertEq(f.followOf(A * 120 / 100), A * 64 / 100 * 120 / 100, "+20%, not +87.5%");
        _submit(A * 120 / 100);
        assertEq(_stepBps(A * 64 / 100, _value()), 2000);
    }

    /// The judge's measurement after a silence: A; silence; 0.6A; 0.48A; then a 1.2A target. The way back took 0.48A -> 1.2A
    /// (+150%). Now: +20% (the feed is fresh again when the target lands; the 2x applies only after a silence).
    function test_W3_largestOneStepMoveAfterSilence() public {
        _submit(A);
        _advance(2 hours + 1);
        _submit(A * 60 / 100);
        _advance(1 hours);
        _submit(A * 48 / 100);
        _advance(1 hours);
        _submit(A * 120 / 100);
        assertEq(_stepBps(A * 48 / 100, _value()), 2000, "+20%, not +150%");
    }
}
