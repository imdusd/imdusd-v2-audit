// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";

/// @dev A REMOTE price leaf: deployed on a chain whose block.number is not Ethereum's (Sepolia id), data chain 1.
contract RemoteLeafA is SwarmFeed {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}

    function questionPolicy() internal pure override returns (bytes memory, uint64, uint64) {
        return (bytes('{"q":"price","window":{"fromBlock":'), 1, 100_000);
    }
}

/// SwarmFeed._tickClock: the upper bound `most` is measured from the first value's origin at ONE block per 12 s, but
/// Ethereum misses ~1% of its slots, so `most` runs ahead of the honest head by 1% of the blocks since the origin.
/// ONE future-dated window at `most` moves the clock there; the slow projection then runs at 31/32 and honest heads
/// (0.99 per slot) need ~0.47 x the feed's age to overtake it: with the feed 30 days old, honest windows are refused
/// `WindowBehindClock` for ~14 days. Fails on this commit (the honest window 7 days later reverts); passes once the
/// bound follows the heads the feed has actually seen (or the clock is not moved past the honest head by one window).
contract ProofRemoteClockOneWindowTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 constant A = 1e18;
    uint64 constant B0 = 26_000_000;
    uint256 nonce;
    uint256 t0;
    RemoteLeafA f;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        t0 = block.timestamp;
        f = new RemoteLeafA(vm.addr(KEY));
    }

    function _att(uint256 value, uint64 toBlock) internal returns (SwarmFeed.OracleAttestation memory a) {
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
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
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

    /// @dev Ethereum's honest head: one block per 12 s less 1% missed slots.
    function _head() internal view returns (uint64) {
        return B0 + uint64((block.timestamp - t0) / 12 * 99 / 100);
    }

    function _push(uint256 value, uint64 toBlock) internal {
        SwarmFeed.OracleAttestation memory a = _att(value, toBlock);
        f.submitAttestation(a, _sign(a));
    }

    function test_oneFutureWindowLocksHonestWindowsOutForDays() public {
        _push(A, B0); // the first value fixes the origin (B0, t0)
        // 30 days of honest hourly windows; each lands at the honest head.
        for (uint256 h = 1; h <= 30 * 24; ++h) {
            vm.warp(t0 + h * 1 hours);
            _push(A, _head());
        }
        // One window dated at the bound `most` (honest head + ~2,460 blocks: 1% of 216,000 slots + PARENT_SLACK).
        uint64 most = B0 + uint64((block.timestamp - t0) / 12) + uint64(f.PARENT_SLACK());
        _push(A, most);
        // Seven days later an honest window is still refused as behind the clock.
        vm.warp(block.timestamp + 7 days);
        SwarmFeed.OracleAttestation memory a = _att(A, _head());
        bytes memory sig = _sign(a);
        f.submitAttestation(a, sig); // reverts WindowBehindClock on this commit
    }
}