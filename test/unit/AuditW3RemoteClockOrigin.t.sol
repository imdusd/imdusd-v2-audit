// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

contract RemoteLeafB is SwarmPricePolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 1 hours, 2_000) {}
}

/// @notice SwarmFeed._tickClock (src/feeds/SwarmFeed.sol:445-457): the upper bound `most` is measured from the FIRST
/// value's (toBlock, issuedAt). The first value has no bound of its own. A first window that closed more than PARENT_SLACK
/// blocks before its signature (an old window signed fresh: the buyer chooses the window) fixes an origin behind the
/// data chain, and every honest window after it (toBlock = the real head) is refused WindowInFuture: the bound grows at
/// one block per 12 s, the honest head at most that fast, so the gap never closes. Not reachable in the beta (mainnet
/// feeds take the same-chain branch); a Robinhood feed (after the beta) whose first relay is won by an old window is bricked
/// until the Safe re-points it.
contract ProofRemoteClockOriginTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    RemoteLeafB f;
    uint64 constant HEAD0 = 26_000_000;
    uint256 T0;

    function setUp() public {
        vm.chainId(8453);
        vm.roll(1);
        vm.warp(1_800_000_000);
        T0 = 1_800_000_000;
        f = new RemoteLeafB(vm.addr(KEY));
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

    function test_oldFirstWindowBricksEveryHonestWindowAfterIt() public {
        // The first relay: a window that closed 2 days (14,400 blocks) before it was signed, now.
        // (Adapted after the fix: the first value of a remote feed with no block clock is the deployment's. A stranger's
        // relay of the old window is refused; the deployment then relays an honest first window.)
        SwarmFeed.OracleAttestation memory a = _att(HEAD0 - 14_400, 3e15);
        bytes memory oldSig = _sig(a);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(SwarmFeed.FirstValueNotDeployer.selector);
        f.submitAttestation(a, oldSig);
        a = _att(HEAD0, 3e15);
        f.submitAttestation(a, _sig(a));
        // Honest windows ending at the real head, signed now, tried hourly for 30 days: every one refused.
        uint256 refused;
        for (uint256 i; i < 24 * 30; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            a = _att(_realHead(), 3e15);
            bytes memory sig = _sig(a);
            try f.submitAttestation(a, sig) {} catch { ++refused; }
        }
        emit log_named_uint("honest hourly windows refused in 30 days", refused);
        assertEq(refused, 0, "an honest window at the real head is refused for good (WindowInFuture)");
    }
}