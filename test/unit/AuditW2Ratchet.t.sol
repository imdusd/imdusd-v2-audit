// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmSpotPolicy} from "src/feeds/SwarmFeeds.sol";

/// @dev The production SPOT question binding, a test signer, the beta's lifetime (1 h) and cap (2,000 bps).
contract RatchetLeaf is SwarmSpotPolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// @notice Audit wave 2 (2-prices, HIGH): three honestly-signed attestations of a pushed pool around two epoch boundaries
/// (1.2A at minute 59, 1.44A at minute 60, 1.728A an hour later) locked the honest level A out for good under the
/// rejection rule; the wave-2 fix (the way back two epochs deep) still locked out with four pushes, and with three after a
/// silence (wave 3). Design C (2026-11-14) takes every attestation as a target and clamps it, so these tests now assert
/// P2 on the same sequences: once only the honest level is relayed, once per epoch, the stored value reaches it within
/// ceil(ln(stored / A) / ln(1 + cap)) epochs, every honest attestation is accepted, and none moves the value away from A.
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
        uint64 toBlock = uint64(vm.getBlockNumber());
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
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
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
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
    }

    function _submit(uint256 value) internal {
        SwarmFeed.OracleAttestation memory a = _att(value);
        f.submitAttestation(a, _sign(a));
    }

    function _value() internal view returns (uint256 v) {
        (v,) = f.latestValue();
    }

    /// @dev Relay the honest A every `gap` seconds until the stored value is A; returns the epochs it took (each relay
    /// opens a new epoch when gap >= maxAge). Asserts every relay is accepted and never moves the value away from A.
    function _honestUntilBack(uint256 gap, uint256 maxRelays) internal returns (uint256 relays) {
        while (_value() != A) {
            uint256 before = _value();
            _advance(gap);
            _submit(A); // reverts the test if refused: P3 (no lock-out)
            uint256 dBefore = before > A ? before - A : A - before;
            uint256 dAfter = _value() > A ? _value() - A : A - _value();
            assertLe(dAfter, dBefore, "an honest attestation never moves the value away from its target");
            ++relays;
            assertLe(relays, maxRelays, "P2 bound exceeded");
        }
        assertTrue(f.converged());
    }

    /// 1.728A back to A: ln(1.728) / ln(1 / 0.8) = 2.45, so at most 3 epochs (the bound with ln 1.2 is 3 too).
    function test_W2_threePushedAttestationsDoNotLockTheHonestLevelOut() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 120 / 100);
        _advance(1 minutes);
        _submit(A * 144 / 100);
        _advance(60 minutes);
        _submit(A * 1728 / 1000);
        assertEq(_value(), A * 1728 / 1000, "the ratchet landed: 1.728A is the stored value");
        assertEq(_honestUntilBack(60 minutes, 3), 3);
    }

    /// The same, but the honest relayer tries every ten minutes (several relays per epoch): still back within 3 epochs.
    function test_W2_honestEveryTenMinutesIsBackWithinThreeEpochs() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 120 / 100);
        _advance(1 minutes);
        _submit(A * 144 / 100);
        _advance(60 minutes);
        _submit(A * 1728 / 1000);
        uint256 t0 = vm.getBlockTimestamp();
        _honestUntilBack(10 minutes, 3 * 6 + 1);
        assertLe(vm.getBlockTimestamp() - t0, 3 hours, "within three epochs of the first honest relay");
    }

    /// After two hours of silence the first push may move 2x the cap (1.4A), then 1.67A an hour later. Back in <= 3 epochs.
    function test_W2_twoPushedAttestationsAfterASilenceDoNotLockTheHonestLevelOut() public {
        _submit(A);
        _advance(2 hours + 1);
        (,, uint256 allowance) = f.epoch();
        assertEq(allowance, 4000, "stale allowance: 2x the cap");
        _submit(A * 140 / 100);
        _advance(1 hours);
        _submit(A * 167 / 100);
        assertEq(_value(), A * 167 / 100);
        assertLe(_honestUntilBack(60 minutes, 3), 3);
    }

    /// The old residual ("four boundary-timed pushes lock out until the Safe re-points") is gone: after four pushes the
    /// stored value is 2.0736A and the honest level is reached within ceil(ln 2.0736 / ln 1.25) = 4 epochs (falls move
    /// by 1/0.8 per epoch).
    function test_W2_fourBoundaryPushesInARowNoLongerLockOut() public {
        _submit(A);
        _advance(59 minutes);
        _submit(A * 120 / 100);
        _advance(1 minutes);
        _submit(A * 144 / 100);
        _advance(60 minutes);
        _submit(A * 1728 / 1000);
        _advance(60 minutes);
        _submit(A * 20736 / 10000);
        assertEq(_value(), A * 20736 / 10000);
        assertLe(_honestUntilBack(60 minutes, 4), 4);
    }
}
