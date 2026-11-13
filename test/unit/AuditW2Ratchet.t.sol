// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmSpotPolicy} from "src/feeds/SwarmFeeds.sol";

/// @dev The production SPOT question binding, a test signer, the beta's lifetime (1 h) and cap (2,000 bps).
contract RatchetLeaf is SwarmSpotPolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// @notice Three honestly-signed attestations of a pushed pool, each within the epoch rule, placed around two epoch
/// boundaries (1.2A in the last minute of epoch 1; 1.44A as the first value of epoch 2; 1.728A as the first value of
/// epoch 3), leave the honest level A outside every allowance the feed will ever offer again while the market stays at
/// A: the live epoch's band is [1.152A, 1.728A], the way back reaches only the cap around 1.44A (the previous epoch's
/// anchor), and once the way back expires the stale allowance is 2x the cap below 1.728A = 1.037A. The feed is halted
/// for good against an honest relayer, with no attester compromise and no market gap: the halt the header accepts only
/// for "the outage-plus-crash case" is bought here by a relayer for three attestations (1.5 IMD) and three pushes of
/// the pool at the recipe's read block.
/// Audit wave 2 (2-prices, high), adopted from the judge's proof: the way back now reaches the cap around the anchor of the
/// epoch before the expired one too, with no step bound from the last value, so the honest level is taken back.
contract AuditW2RatchetTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    RatchetLeaf f;
    uint256 constant A = 4e15; // wei of ETH per 1e18 IMD, the order of the live feed

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        f = new RatchetLeaf(vm.addr(KEY));
    }

    function _att(uint256 value) internal returns (SwarmFeed.OracleAttestation memory a) {
        uint64 toBlock = uint64(block.number);
        a.requestId = bytes32(++nonce);
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.fromBlock = toBlock - 300;
        a.toBlock = toBlock;
        a.questionHash = f.expectedQuestionHash(a.fromBlock, a.toBlock);
        a.panelSize = 100;
        a.quorum = 67;
        a.agreed = 67;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(SwarmFeed.OracleAttestation memory a) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, s, v);
    }

    function _advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
    }

    function _submit(uint256 value) internal {
        SwarmFeed.OracleAttestation memory a = _att(value);
        f.submitAttestation(a, _sign(a));
    }

    function _try(uint256 value) internal returns (bool ok) {
        SwarmFeed.OracleAttestation memory a = _att(value);
        bytes memory sig = _sign(a);
        try f.submitAttestation(a, sig) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function test_threePushedAttestationsDoNotLockTheHonestLevelOut() public {
        // t0: the honest level anchors epoch 1 at A.
        _submit(A);

        // t0 + 59 min: the relayer lands 1.2A (within the cap of A).
        _advance(59 minutes);
        _submit(A * 120 / 100);

        // t0 + 60 min: epoch 1 has expired; the first value of epoch 2 is 1.44A (within the cap of the last value 1.2A).
        _advance(1 minutes);
        _submit(A * 144 / 100);

        // t0 + 120 min: epoch 2 has expired; the first value of epoch 3 is 1.72A (within the cap of 1.44A).
        _advance(60 minutes);
        _submit(A * 172 / 100);
        (uint256 v,) = f.latestValue();
        assertEq(v, A * 172 / 100, "the ratchet landed: 1.72A is the live value");

        // The market never left A. The honest relayer tries every ten minutes for a day. Expected: accepted within a few
        // epochs (the README: "a larger gap is followed at the cap per epoch"). Actual: refused on every attempt.
        bool accepted;
        for (uint256 i; i < 144 && !accepted; ++i) {
            _advance(10 minutes);
            accepted = _try(A);
        }
        emit log_named_uint("hours before the honest level was accepted (145 = never in a day)", (block.timestamp - 1_800_000_000) / 1 hours);
        (uint256 anchor,, uint256 allowance) = f.epoch();
        emit log_named_uint("anchor after a day", anchor);
        emit log_named_uint("allowance bps after a day", allowance);
        assertTrue(accepted, "the honest level is locked out for good: the feed is halted at 1.72A");
    }

    /// The beta's legs are "bought on demand and stale most hours" (DeployConfig). After any two hours of silence the next
    /// value may move 2x the cap. Two attestations then suffice: 1.4A opens a wide epoch (its first value), 1.67A opens the
    /// next one an hour later (within the cap of 1.4A). From there A is below 0.8 x 1.4A (the way back), below 0.8 x 1.4A
    /// (the live band) and below 0.6 x 1.67A (the stale allowance from the last value): refused for good.
    function test_twoPushedAttestationsAfterASilenceDoNotLockTheHonestLevelOut() public {
        _submit(A);
        _advance(2 hours + 1); // the honest level has been stale for a whole hour past its lifetime
        (,, uint256 allowance) = f.epoch();
        assertEq(allowance, 4000, "stale allowance: 2x the cap");
        _submit(A * 140 / 100);
        _advance(1 hours);
        _submit(A * 167 / 100);

        bool accepted;
        for (uint256 i; i < 144 && !accepted; ++i) {
            _advance(10 minutes);
            accepted = _try(A);
        }
        assertTrue(accepted, "two attestations after a silence halt the feed against the honest level");
    }

    /// The residual (README known issues): four boundary-timed pushes in a row walk both remembered anchors more than a cap
    /// from the honest level, and it is refused until the Safe re-points the feed. Pinned so a change to the rule is seen.
    function test_fourBoundaryPushesInARowStillLockOut() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 120 / 100); // last value of epoch 1
        _advance(1 minutes);
        _submit(A * 144 / 100); // first value of epoch 2 (anchored at 1.2A)
        _advance(60 minutes);
        _submit(A * 172 / 100); // first value of epoch 3 (anchored at 1.44A)
        _advance(60 minutes);
        _submit(A * 206 / 100); // first value of epoch 4 (anchored at 1.72A)
        for (uint256 i; i < 144; ++i) {
            _advance(10 minutes);
            assertFalse(_try(A), "documented residual: refused");
        }
    }
}
