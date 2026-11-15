// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "../../src/feeds/SwarmFeeds.sol";

contract GasLeaf is SwarmPricePolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// @notice Gas of one accepted attestation (the whole submit path) on the beta's price leaf, by case. Uses only the API both
/// the pre-design-C and the design-C SwarmFeed share, so it runs unchanged on both.
/// Under `isolate = true` each submit is its own transaction: cold storage every time, as on chain.
contract SwarmFeedGasTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    GasLeaf f;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        f = new GasLeaf(vm.addr(KEY));
    }

    function _advance(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
    }

    function _submit(uint256 value) internal returns (uint256 used) {
        SwarmFeed.OracleAttestation memory a;
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
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h)));
        bytes memory sig = abi.encodePacked(r, s, v);
        uint256 g = gasleft();
        f.submitAttestation(a, sig);
        used = g - gasleft();
    }

    function test_gas_acceptedAttestation() public {
        emit log_named_uint("first value", _submit(4e15));
        _advance(10 minutes);
        emit log_named_uint("inside the live epoch (2nd value of the first epoch)", _submit(4.1e15));
        _advance(10 minutes);
        emit log_named_uint("inside the live epoch (3rd value)", _submit(4.2e15));
        _advance(50 minutes);
        emit log_named_uint("opens an epoch (fresh)", _submit(4.3e15));
        _advance(10 minutes);
        emit log_named_uint("inside the live epoch", _submit(4.25e15));
        _advance(3 hours);
        emit log_named_uint("opens an epoch (after a silence, 2x)", _submit(5e15));
        _advance(10 minutes);
        emit log_named_uint("inside a wide epoch", _submit(5.1e15));
    }
}
