// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

contract RemoteLeafP is SwarmPricePolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// @notice PROPERTIES (audit wave 3, remote time clock, a feed with no block clock: consumer chain 8453, data chain 1):
///  P1. an honest window (ending at the real head when signed) is never refused for its block numbers, whatever ONE
///      validly signed window dated anywhere the bound allows did before it; fuzzed over the honest head's missed-slot rate
///      (0-3%), the feed's age before the bad window (0-60 days), the bad window's date (honest head up to `most`), outages
///      of up to two days, and the days after.
///  P2. the first value cannot be relayed by anyone but the deployment (so no stranger can fix an old origin).
contract AuditW3RemoteClockPropertyTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint64 constant HEAD0 = 26_000_000;
    uint256 constant T0 = 1_800_000_000;
    uint256 nonce;
    RemoteLeafP f;
    uint256 missPerMille;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(T0);
        f = new RemoteLeafP(vm.addr(KEY));
    }

    function _head() internal view returns (uint64) {
        uint256 slots = (vm.getBlockTimestamp() - T0) / 12;
        return HEAD0 + uint64(slots - slots * missPerMille / 1000);
    }

    function _att(uint64 toBlock) internal returns (SwarmFeed.OracleAttestation memory a) {
        a.requestId = bytes32(++nonce);
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(uint256(3e15));
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

    /// @dev Submit; true when refused for its block numbers (the clock's errors).
    function _refusedForBlocks(uint64 toBlock) internal returns (bool) {
        SwarmFeed.OracleAttestation memory a = _att(toBlock);
        bytes memory sig = _sig(a);
        try f.submitAttestation(a, sig) {
            return false;
        } catch (bytes memory err) {
            bytes4 e = bytes4(err);
            return e == SwarmFeed.WindowInFuture.selector || e == SwarmFeed.WindowBehindClock.selector;
        }
    }

    function testFuzz_oneBadWindowNeverLocksHonestWindowsOut(
        uint16 miss,
        uint16 daysBefore,
        uint32 badOffset,
        uint8 outageHours,
        uint8 daysAfter
    ) public {
        missPerMille = uint256(miss) % 31; // 0-3% of slots missed
        uint256 before = uint256(daysBefore) % 61;
        assertFalse(_refusedForBlocks(HEAD0), "first value");
        uint256 h;
        for (; h < before * 24; h += 6) {
            vm.warp(T0 + (h + 6) * 1 hours);
            assertFalse(_refusedForBlocks(_head()), "honest window before the bad one");
        }
        // The one bad window: dated anywhere from the honest head to the bound `most`.
        uint256 most = uint256(f.originBlock()) + (vm.getBlockTimestamp() - f.originAt()) / 12 + f.PARENT_SLACK();
        uint64 head = _head();
        uint64 bad = head + uint64(uint256(badOffset) % (most - head + 1));
        vm.warp(vm.getBlockTimestamp() + 60);
        if (bad > _head()) _refusedForBlocks(bad); // may be refused itself; either way the honest ones below must pass
        // An outage, then honest windows every 6 hours.
        vm.warp(vm.getBlockTimestamp() + uint256(outageHours % 49) * 1 hours);
        for (uint256 k; k <= uint256(daysAfter % 15) * 4; ++k) {
            vm.warp(vm.getBlockTimestamp() + 6 hours);
            assertFalse(_refusedForBlocks(_head()), "an honest window was refused for its block numbers");
        }
    }

    function testFuzz_firstValueIsTheDeployments(address stranger, uint32 age) public {
        vm.assume(stranger != address(this));
        uint64 toBlock = HEAD0 - uint64(age % 100_000);
        SwarmFeed.OracleAttestation memory a = _att(toBlock);
        bytes memory sig = _sig(a);
        vm.prank(stranger);
        vm.expectRevert(SwarmFeed.FirstValueNotDeployer.selector);
        f.submitAttestation(a, sig);
    }
}
