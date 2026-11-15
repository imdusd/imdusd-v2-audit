// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

/// @dev A price leaf with the production PRICE question, a test attester, 1h lifetime, 20% cap (BetaConfig values).
contract W1WayBackLeaf is SwarmPricePolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 3, low): the way back (`_returnAnchor`) let a fresh feed move
/// +50% in one accepted attestation (0.8A -> 1.2A) against the trust model's "at most the cap per epoch". Wave 2 then showed
/// the bound that fixed it made a pushed lock-out permanent. Design C (2026-11-14) deleted the way back: these tests now
/// assert the PROPERTIES on the same sequences: P1 (no epoch moves the stored value more than the cap from its anchor) and
/// P2 (an honest level returning after a push is reached within the bounded number of epochs, never refused).
contract AuditW1WayBackTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    W1WayBackLeaf f;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        f = new W1WayBackLeaf(vm.addr(KEY));
    }

    function _att(uint256 value) internal returns (SwarmFeed.OracleAttestation memory a) {
        uint64 toBlock = uint64(vm.getBlockNumber());
        a.requestId = bytes32(++nonce);
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.fromBlock = toBlock - 600;
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
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
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

    function _value() internal view returns (uint256 v) {
        (v,) = f.latestValue();
    }

    /// P1 on the wave-1 sequence: A, 0.8A at minute 59, then a 1.2A target at minute 60. The way back took 1.2A in one
    /// step (+50%); now the new epoch anchors at the stored 0.8A and the value stops at 0.96A (the cap).
    function test_W1_oneStepReturnIsBoundedByTheCap() public {
        uint256 A = 4e15;
        SwarmFeed.OracleAttestation memory first = _att(A);
        f.submitAttestation(first, _sign(first));
        _advance(59 minutes);
        SwarmFeed.OracleAttestation memory lo = _att(A * 80 / 100);
        f.submitAttestation(lo, _sign(lo));
        assertEq(_value(), A * 80 / 100);
        _advance(1 minutes);
        (uint256 anchor,, uint256 allowanceBps) = f.epoch();
        assertEq(anchor, A * 80 / 100, "the next epoch anchors on the stored value");
        assertEq(allowanceBps, 2000);
        SwarmFeed.OracleAttestation memory hi = _att(A * 120 / 100);
        f.submitAttestation(hi, _sign(hi));
        assertEq(_value(), A * 96 / 100, "+20% from the anchor, not +50%");
        assertEq(f.attested(), A * 120 / 100);
        assertFalse(f.converged());
        // P2: the 1.2A target held honestly is reached within ceil(ln 1.5 / ln 1.2) = 3 epochs.
        uint256 epochs = 1;
        while (_value() != A * 120 / 100) {
            _advance(1 hours);
            SwarmFeed.OracleAttestation memory h = _att(A * 120 / 100);
            f.submitAttestation(h, _sign(h));
            ++epochs;
        }
        assertLe(epochs, 3);
        assertTrue(f.converged());
    }

    /// P2 on the pre-publish sequence: a push to 1.2A in the last minute of an epoch anchored at A, then the market at
    /// 0.95A. The honest value is taken at once (it is a target, never refused) and the stored value is at 0.95A within
    /// ceil(ln(1.2 / 0.95) / ln 1.2) = 2 epochs.
    function test_W1_honestFallPastTheLevelAfterAPushIsNotLockedOut() public {
        uint256 A = 4e15;
        SwarmFeed.OracleAttestation memory first = _att(A);
        f.submitAttestation(first, _sign(first));
        _advance(59 minutes);
        SwarmFeed.OracleAttestation memory pushed = _att(A * 120 / 100);
        f.submitAttestation(pushed, _sign(pushed));
        _advance(2 minutes);
        SwarmFeed.OracleAttestation memory honest = _att(A * 95 / 100);
        f.submitAttestation(honest, _sign(honest));
        assertEq(_value(), A * 96 / 100, "taken at once: 1.2A anchors the epoch, the value falls the cap to 0.96A");
        _advance(1 hours);
        honest = _att(A * 95 / 100);
        f.submitAttestation(honest, _sign(honest));
        assertEq(_value(), A * 95 / 100, "the honest level, one epoch later");
        assertTrue(f.converged());
    }
}
