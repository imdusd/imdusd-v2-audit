// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "../../src/feeds/SwarmFeeds.sol";

/// @dev The production PRICE question binding, a test signer, the beta's 1 h lifetime and the cap under test.
contract PropLeaf is SwarmPricePolicy {
    constructor(address att, uint256 cap) SwarmFeed(att, address(0), 1, 3, 1 hours, cap) {}
}

/// @notice Signs and relays real attestations (signature, bound question, advancing recent window, fresh issue time),
/// so every relay the handler makes is a VALID attestation and the feed's whole submit path runs.
abstract contract Relayer is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal nonce;

    function _advance(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
    }

    /// @dev A valid attestation of `value` for `f` now: toBlock advances past the last accepted window by one block (so
    /// several land in one block) and stays within the feed's recency bound; if it cannot, the chain moves one block.
    function _att(SwarmFeed f, uint256 value) internal returns (SwarmFeed.OracleAttestation memory a, bytes memory sig) {
        uint256 bn = vm.getBlockNumber();
        uint256 toBlock = uint256(f.lastToBlock()) + 1;
        if (toBlock + 290 < bn) toBlock = bn - 290;
        if (toBlock > bn) {
            _advance(12);
            bn = vm.getBlockNumber();
        }
        a.requestId = bytes32(++nonce);
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.toBlock = uint64(toBlock);
        a.fromBlock = uint64(toBlock - 600);
        a.questionHash = f.expectedQuestionHash(a.fromBlock, a.toBlock);
        a.panelSize = 100;
        a.quorum = 67;
        a.agreed = 67;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h)));
        sig = abi.encodePacked(r, s, v);
    }

    function _dist(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    /// @dev ceil(ln(max / min) / ln(1 + cap)) in 1e18 fixed point: the P2 bound on epochs from `s` to `h`.
    function _epochBound(uint256 s, uint256 h, uint256 capBps) internal pure returns (uint256 k) {
        (uint256 lo, uint256 hi) = s < h ? (s, h) : (h, s);
        uint256 ratio = hi * 1e18 / lo;
        uint256 p = 1e18;
        while (p < ratio) {
            p = p * (10_000 + capBps) / 10_000;
            ++k;
        }
    }
}

/// @notice Drives one leaf with a random interleaving of honest attestations (the market level) and attacker attestations
/// (pushed values 0.05x-20x of the market, at epoch boundaries, after silences, several in one block, last in an epoch),
/// checking every delivery against an INDEPENDENT model of the rule, and counting violations for the invariants.
contract LegHandler is Relayer {
    PropLeaf public immutable f;
    uint256 public immutable cap;
    uint256 public market;

    // ghost model of the epoch: when it opened, and the signature/relay time of the stored value
    uint256 public openAt;
    uint256 public lastSignedAt;
    uint256 public lastRelayAt;

    uint256 public accepted;
    uint256 public refused; // P3/P2: a valid attestation must never be refused
    uint256 public p1Violations; // stored value outside its epoch's band
    uint256 public modelViolations; // anchor/allowance not the ones the rule says (anchor = stored value at open; 2x only after silence)
    uint256 public awayMoves; // P3: a delivery moved the stored value AWAY from its target
    uint256 public notClosest; // P2: a delivery left the value short of the closest point of the band to its target
    uint256 public traitViolations; // attested()/converged() disagree with the delivery
    uint256 public livenessViolations; // P2 bound missed in the honest phase
    uint256 public maxEpochsSeen;

    constructor(PropLeaf f_, uint256 market_) {
        f = f_;
        cap = f_.maxDeviationBps();
        market = market_;
        _relay(market_); // the first value (no bound on chain: the operator relays it)
    }

    // ------------------------------------------------------------------------------------------------ actions

    function honest(uint256 dtSeed) external {
        _advance(bound(dtSeed, 0, 3 hours));
        _relay(market);
    }

    function attack(uint256 dtSeed, uint256 factorSeed) external {
        _advance(bound(dtSeed, 0, 3 hours));
        _relay(_pushed(factorSeed));
    }

    /// Lands one value in the last second of the live epoch and the next right after the boundary (one or two blocks).
    function boundaryAttack(uint256 factorSeed, uint256 gapSeed) external {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 end = openAt + 1 hours;
        if (end > now_ + 1) _advance(end - now_ - 1);
        _relay(_pushed(factorSeed));
        _advance(bound(gapSeed, 1, 24));
        _relay(_pushed(factorSeed >> 32));
    }

    /// Several relays in ONE block, honest and pushed mixed (the block builder's ordering).
    function burst(uint256 nSeed, uint256 orderSeed, uint256 factorSeed) external {
        uint256 n = bound(nSeed, 2, 6);
        for (uint256 i; i < n; ++i) {
            _relay(((orderSeed >> i) & 1) == 0 ? market : _pushed(factorSeed >> (8 * i)));
        }
    }

    function silence(uint256 dtSeed) external {
        _advance(bound(dtSeed, 1 hours, 30 hours));
    }

    function moveMarket(uint256 factorSeed) external {
        uint256 m = market * bound(factorSeed, 5_000, 20_000) / 10_000;
        market = m < 1e12 ? 1e12 : (m > 1e24 ? 1e24 : m);
    }

    // ------------------------------------------------------------------------------------------------ P2 (after the run)

    /// The attack stops; honest attestations of the market arrive once per epoch. The stored value must be within k wei of
    /// the market after k = ceil(ln(ratio) / ln(1 + cap)) epochs and exactly on it one epoch later (wei rounding).
    function liveness() external {
        (uint256 s,) = f.latestValue();
        uint256 k = _epochBound(s, market, cap);
        if (k > maxEpochsSeen) maxEpochsSeen = k;
        for (uint256 i = 1; i <= k + 1; ++i) {
            _advance(1 hours);
            _relay(market);
            (uint256 v,) = f.latestValue();
            if (i == k && _dist(v, market) > k) ++livenessViolations;
            if (v == market) return;
        }
        ++livenessViolations;
    }

    // ------------------------------------------------------------------------------------------------ internals

    function _pushed(uint256 seed) internal view returns (uint256 v) {
        v = market * bound(seed, 500, 200_000) / 10_000; // 0.05x .. 20x
        if (v == 0) v = 1;
    }

    function _relay(uint256 target) internal {
        (SwarmFeed.OracleAttestation memory a, bytes memory sig) = _att(f, target);
        uint256 now_ = vm.getBlockTimestamp();
        (uint256 before,) = f.latestValue();
        bool hadValue = before != 0;

        // The independent model: which epoch this delivery lands in, its anchor and its allowance.
        bool opens = hadValue && now_ - openAt >= 1 hours;
        uint256 anchor;
        uint256 bps;
        bool wideOpen;
        if (hadValue) {
            (uint256 a0,, uint256 b0) = f.epoch();
            if (opens) {
                bool stale = now_ > lastSignedAt && now_ - lastSignedAt > 1 hours;
                uint256 since = lastRelayAt > lastSignedAt ? lastRelayAt : lastSignedAt;
                bool wide = stale && now_ >= since + 1 hours + 1 hours;
                (anchor, bps) = (before, wide ? 2 * cap : cap);
                wideOpen = wide;
            } else {
                (anchor, bps) = (a0, b0);
            }
            if (a0 != anchor || b0 != bps) ++modelViolations;
        }

        try f.submitAttestation(a, sig) {
            ++accepted;
        } catch {
            ++refused;
            return;
        }
        if (!hadValue || opens) openAt = now_;
        (lastSignedAt, lastRelayAt) = (a.issuedAt, now_);

        (uint256 v,) = f.latestValue();
        if (f.attested() != target || f.converged() != (v == target)) ++traitViolations;
        if (!hadValue) {
            if (v != target) ++traitViolations;
            return;
        }
        uint256 d = anchor * bps / 10_000;
        uint256 lo = d >= anchor ? 0 : anchor - d;
        uint256 hi = anchor + d;
        if (v > hi || v < lo) ++p1Violations;
        uint256 closest = target > hi ? hi : (target < lo ? lo : target);
        if (v != closest) ++notClosest;
        if (_dist(v, target) > _dist(before, target)) ++awayMoves;
        (uint256 a1, uint64 o1, uint256 b1) = f.epoch();
        // The wide band is one step: an epoch opened wide re-anchors at what its first delivery stored, at the cap.
        (uint256 ea, uint256 eb) = wideOpen ? (v, cap) : (anchor, bps);
        if (a1 != ea || b1 != eb || o1 != openAt) ++modelViolations;
    }
}

/// @notice P1-P3 as invariants over random interleavings (forge invariant runs x depth; foundry.toml: 128 x 64).
contract SwarmFeedInvariants is StdInvariant, Test {
    LegHandler h;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        PropLeaf f = new PropLeaf(vm.addr(0xA11CE), 2000); // BetaConfig: 1 h, 2,000 bps
        h = new LegHandler(f, 4e15);
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](6);
        s[0] = LegHandler.honest.selector;
        s[1] = LegHandler.attack.selector;
        s[2] = LegHandler.boundaryAttack.selector;
        s[3] = LegHandler.burst.selector;
        s[4] = LegHandler.silence.selector;
        s[5] = LegHandler.moveMarket.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    /// P3 / no lock-out: no valid attestation is ever refused, whatever was relayed before.
    function invariant_P3_noValidAttestationRefused() public view {
        assertEq(h.refused(), 0);
    }

    /// P1: the stored value is always inside its epoch's band around the anchor.
    function invariant_P1_storedWithinEpochBand() public view {
        assertEq(h.p1Violations(), 0);
    }

    /// P1: the anchor is the stored value when the epoch opened, never a remembered or attested one; 2x only after silence.
    function invariant_P1_epochModel() public view {
        assertEq(h.modelViolations(), 0);
    }

    /// P2/P3: every delivery leaves the value at the closest point of the band to its target, never further from it.
    function invariant_P3_progressTowardTheTarget() public view {
        assertEq(h.awayMoves(), 0);
        assertEq(h.notClosest(), 0);
    }

    function invariant_traits() public view {
        assertEq(h.traitViolations(), 0);
    }

    /// P2: after every run, honest attestations once per epoch reach the market within the epoch bound.
    function afterInvariant() external {
        h.liveness();
        assertEq(h.livenessViolations(), 0, "P2: the honest level was not reached within the epoch bound");
        assertEq(h.refused(), 0);
    }
}

/// @notice Fuzzed sequences for P2, P5 and the stated residual (the last relayer of an epoch), on several caps.
contract SwarmFeedPropertyFuzz is Relayer {
    PropLeaf f;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
    }

    function _relay(uint256 v) internal {
        (SwarmFeed.OracleAttestation memory a, bytes memory sig) = _att(f, v);
        f.submitAttestation(a, sig);
    }

    function _value() internal view returns (uint256 v) {
        (v,) = f.latestValue();
    }

    /// P5 crash following: from S the market falls to H (up to 100x lower), optionally after a silence; honest attestations
    /// once per epoch. After k epochs the stored value is at most max(H, S x (1 - cap)^k) (plus k wei of rounding), and it
    /// reaches H within the P2 bound + 1.
    function testFuzz_P5_crashIsFollowedAtLeastAtTheAllowance(uint256 sSeed, uint256 fallSeed, uint256 capSeed, bool silent) public {
        uint256 cap = bound(capSeed, 500, 5000);
        f = new PropLeaf(vm.addr(KEY), cap);
        uint256 s = bound(sSeed, 1e12, 1e24);
        uint256 h = s * 100 / bound(fallSeed, 101, 10_000); // a fall of 1% .. 100x
        _relay(s);
        _advance(silent ? 5 hours : 1 hours);
        uint256 ceiling = s;
        uint256 k = _epochBound(s, h, cap);
        for (uint256 i = 1; i <= k + 1; ++i) {
            _relay(h);
            ceiling = ceiling * (10_000 - cap) / 10_000;
            uint256 v = _value();
            uint256 limit = ceiling > h ? ceiling : h;
            assertLe(v, limit + i, "P5: the fall is followed at least at the allowance per epoch");
            if (v == h) return;
            _advance(1 hours);
        }
        revert("P2: the fallen level was not reached within the bound");
    }

    /// The wide band is one step: after a silence, once any value lands, every later delivery in that epoch stays within
    /// the cap of what the first one stored, wherever its target is and however many follow in the epoch.
    function testFuzz_wideBandIsOneStep(uint256 sSeed, uint256 firstSeed, uint256 pushSeed, uint256 capSeed, uint8 n) public {
        uint256 cap = bound(capSeed, 500, 5000);
        f = new PropLeaf(vm.addr(KEY), cap);
        uint256 s = bound(sSeed, 1e12, 1e24);
        _relay(s);
        _advance(bound(firstSeed, 2 hours + 1, 30 hours)); // silent past the lifetime and a whole growth period
        (, , uint256 wideBps) = f.epoch();
        assertEq(wideBps, 2 * cap, "the epoch about to open is wide");
        uint256 first = s * bound(firstSeed, 5_000, 20_000) / 10_000; // the first value after the silence (0.5x .. 2x)
        _relay(first);
        uint256 stored = _value();
        (uint256 a1, , uint256 b1) = f.epoch();
        assertEq(a1, stored, "re-anchored at what the first delivery stored");
        assertEq(b1, cap, "at the cap");
        uint256 d = stored * cap / 10_000;
        for (uint256 i; i < uint256(n) % 6 + 1; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 + i); // later in the same epoch
            uint256 target = s * bound(uint256(keccak256(abi.encode(pushSeed, i))), 500, 200_000) / 10_000 + 1;
            _relay(target);
            uint256 v = _value();
            assertLe(v, stored + d + 1, "above the cap of the first stored value");
            assertGe(v + d + 1, stored, "below the cap of the first stored value");
        }
    }

    /// P2 from any pushed state: the attacker relays N values (any order, any timing within epochs), then stops.
    function testFuzz_P2_backWithinTheBoundAfterAnyPush(uint256 seed, uint8 n) public {
        f = new PropLeaf(vm.addr(KEY), 2000);
        uint256 h = 4e15;
        _relay(h);
        for (uint256 i; i < uint256(n) % 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _advance(bound(seed, 0, 3 hours));
            _relay(h * bound(seed >> 64, 500, 200_000) / 10_000);
        }
        _advance(1 hours);
        uint256 k = _epochBound(_value(), h, 2000);
        for (uint256 i = 1; i <= k + 1; ++i) {
            _relay(h);
            if (_value() == h) {
                assertTrue(f.converged());
                return;
            }
            _advance(1 hours);
        }
        revert("P2 bound missed");
    }

    /// The residual, pinned: an attacker relaying LAST in every epoch (after the honest relay of that epoch) moves the stored
    /// value exactly one allowance per epoch while the attack lasts; k epochs of attack take at most k epochs to undo.
    function testFuzz_residual_lastRelayerMovesOneAllowancePerEpoch(uint8 kSeed) public {
        f = new PropLeaf(vm.addr(KEY), 2000);
        uint256 h = 4e15;
        uint256 k = bound(kSeed, 1, 8);
        _relay(h);
        uint256 expected = h;
        for (uint256 i; i < k; ++i) {
            _advance(1 hours); // a new epoch: the honest relay opens it, the attacker lands after it
            _relay(h);
            _advance(50 minutes);
            _relay(h * 100); // pushed far up
            expected = expected * 12_000 / 10_000;
            assertApproxEqAbs(_value(), expected, k, "one allowance per epoch, no more");
        }
        uint256 epochs;
        while (_value() != h) {
            _advance(1 hours);
            _relay(h);
            ++epochs;
        }
        assertLe(epochs, k, "k epochs of attack are undone within k epochs");
    }

    /// P1 over a burst: any number of attestations in ONE block (alternating extremes) leave the value inside the band.
    function testFuzz_P1_manyInOneBlock(uint256 seed, uint8 n) public {
        f = new PropLeaf(vm.addr(KEY), 2000);
        _relay(4e15);
        _advance(bound(seed, 0, 6 hours));
        for (uint256 i; i < 2 + uint256(n) % 20; ++i) {
            uint256 v = i % 2 == 0 ? 4e15 * 20 : 4e15 / 20;
            _relay(uint256(keccak256(abi.encode(seed, i))) % 3 == 0 ? 4e15 : v);
            (uint256 anchor,, uint256 bps) = f.epoch();
            assertLe(_dist(_value(), anchor), anchor * bps / 10_000);
        }
    }
}
