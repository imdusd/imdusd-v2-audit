// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProvenPoolPrice} from "src/feeds/ProvenPoolPrice.sol";
import {ProvenPoolFixture as F} from "test/fixtures/ProvenPoolFixture.sol";

/// @dev A keeper's atomic bundle: prove, then read the reference the sampler would read (reverts if the prove reverts).
contract ProveThenRead {
    function run(ProvenPoolPrice p, bytes memory h, bytes[] memory a, bytes[] memory s) external returns (uint256 v) {
        p.prove(h, a, s);
        (v,) = p.latestValue();
    }
}

/// @notice PROPERTY (audit wave 3, 2-prices info): a valid [prove(N), sample] bundle never fails because someone else proved
/// block N or a later one first, and the held price never moves to an older block. On the real feed with the real mainnet
/// fixture block N: fuzzed over whether a griefer proves N first, how many headers of blocks at or below N (any caller, any
/// number, blockhash-valid, no state proof needed for a no-op) land before and after the bundle.
contract AuditW3ProvenNoOpTest is Test {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant POOL = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;

    ProvenPoolPrice feed;
    ProveThenRead keeper;
    ProveThenRead griefer;

    function setUp() public {
        vm.etch(MANAGER, hex"00");
        feed = new ProvenPoolPrice(MANAGER, POOL, false, 6 hours);
        keeper = new ProveThenRead();
        griefer = new ProveThenRead();
        vm.roll(F.BLOCK + 1);
        vm.warp(F.TIMESTAMP + 12);
        vm.setBlockhash(F.BLOCK, F.BLOCK_HASH);
    }

    /// @dev A 12-field header whose only filled field is the number (index 8): enough for the blockhash check.
    function _header(uint256 number) internal returns (bytes memory h) {
        bytes memory n = _rlpUint(number);
        bytes memory body;
        for (uint256 i; i < 12; ++i) body = bytes.concat(body, i == 8 ? n : bytes(hex"80"));
        h = bytes.concat(bytes1(uint8(0xc0 + body.length)), body);
        vm.setBlockhash(number, keccak256(h));
    }

    function _rlpUint(uint256 v) internal pure returns (bytes memory) {
        bytes memory b;
        while (v != 0) {
            b = bytes.concat(bytes1(uint8(v)), b);
            v >>= 8;
        }
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return bytes.concat(bytes1(uint8(0x80 + b.length)), b);
    }

    function testFuzz_bundleLandsWhateverWasProvenFirst(bool grieferFirst, uint8 before, uint8 afterwards, uint256 seed) public {
        if (grieferFirst) griefer.run(feed, F.header(), F.accountProof(), F.storageProof());
        bytes[] memory none = new bytes[](0);
        for (uint256 i; i < before % 6; ++i) {
            uint256 num = F.BLOCK - (uint256(keccak256(abi.encode(seed, i))) % 200);
            if (num == F.BLOCK) continue; // the real header of N is the fixture's
            try griefer.run(feed, _header(num), none, none) {} catch {} // an older block before N is proven: may be proven (no data)
        }
        uint256 v = keeper.run(feed, F.header(), F.accountProof(), F.storageProof());
        assertEq(feed.provenBlock(), F.BLOCK, "the bundle's block is held");
        (uint256 held, uint64 at) = feed.latestValue();
        assertEq(v, held);
        assertEq(at, F.TIMESTAMP);
        for (uint256 i; i < afterwards % 6; ++i) {
            uint256 num = F.BLOCK - (uint256(keccak256(abi.encode(seed, "after", i))) % 200);
            bytes memory h = num == F.BLOCK ? F.header() : _header(num);
            uint256 r = griefer.run(feed, h, none, none); // never reverts: a no-op
            assertEq(r, held, "a same or older block returns the held value");
        }
        assertEq(feed.provenBlock(), F.BLOCK, "never moves to an older block");
        (uint256 v2, uint64 at2) = feed.latestValue();
        assertEq(v2, held);
        assertEq(at2, at);
    }
}
