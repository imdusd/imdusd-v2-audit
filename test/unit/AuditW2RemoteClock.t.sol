// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

/// A remote price leaf (attests Ethereum, deployed on another chain): the TIME CLOCK branch of SwarmFeed.
contract RemoteLeaf is SwarmPricePolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 1 hours, 2_000) {}
}

/// The wave-1 fix bounds a window from above by `clockBlock + elapsed/12 + PARENT_SLACK`: relative to the CLOCK, which
/// the accepted window itself then moves to. So the slack compounds: n future-dated windows, each one block of time
/// apart, put the clock and lastToBlock ~301 x n blocks past the real head. Every honest window is then refused
/// (WindowNotAdvancing until the head passes lastToBlock, then WindowBehindClock until the 1/32 drift closes the gap).
contract AuditW2RemoteClockTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    RemoteLeaf f;
    uint64 constant HEAD0 = 26_000_000;
    uint256 T0;

    function setUp() public {
        vm.chainId(8453); // not the data chain, not an Arbitrum-stack chain: the time clock alone bounds windows
        vm.roll(1);
        vm.warp(1_800_000_000);
        T0 = 1_800_000_000;
        f = new RemoteLeaf(vm.addr(KEY));
    }

    function _att(uint64 toBlock, uint256 value) internal returns (SwarmFeed.OracleAttestation memory a) {
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

    function _sig(SwarmFeed.OracleAttestation memory a) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer),
                    a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, s, v);
    }

    function _realHead() internal view returns (uint64) {
        return HEAD0 + uint64((vm.getBlockTimestamp() - T0) / 12);
    }

    /// Audit wave 2 (low), adopted from the judge's proof: the upper bound is measured from the first value's fixed origin, so a
    /// run of future windows can reach PARENT_SLACK past the origin's projection once, not 300 more each time.
    function test_futureWindowsCannotRatchetTheClock() public {
        SwarmFeed.OracleAttestation memory a = _att(HEAD0, 3e15);
        f.submitAttestation(a, _sig(a));

        // The first future window, at the most the old rule admitted, is within the origin bound: accepted.
        vm.warp(vm.getBlockTimestamp() + 12);
        a = _att(f.clockBlock() + 1 + 300, 3e15);
        f.submitAttestation(a, _sig(a));
        // The next one, again 301 past the moved clock, is past the origin bound: refused.
        vm.warp(vm.getBlockTimestamp() + 12);
        a = _att(f.clockBlock() + 1 + 300, 3e15);
        bytes memory sig = _sig(a);
        vm.expectRevert();
        f.submitAttestation(a, sig);
        assertLe(f.clockBlock(), _realHead() + 302, "the clock is at most PARENT_SLACK ahead of the data chain");

        // A day later an honest window ending at the real head, signed now, is accepted.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        a = _att(_realHead(), 3e15);
        f.submitAttestation(a, _sig(a));
    }
}
