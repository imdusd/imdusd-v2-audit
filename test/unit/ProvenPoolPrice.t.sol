// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProvenPoolPrice} from "src/feeds/ProvenPoolPrice.sol";
import {ProvenPoolFixture as F} from "test/fixtures/ProvenPoolFixture.sol";

/// @dev Calls `prove` from memory arrays (the fixture is memory; `prove` takes calldata).
contract ProveCaller {
    function prove(ProvenPoolPrice p, bytes memory h, bytes[] memory a, bytes[] memory s) external returns (uint256) {
        return p.prove(h, a, s);
    }
}

/// @notice ProvenPoolPrice on a REAL mainnet proof (pool 0xb07d's slot0 at the fixture block), and every way of tampering
/// with one: header, block hash, account proof, storage proof, a node added or dropped, a proof of another slot.
contract ProvenPoolPriceTest is Test {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant POOL = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
    uint256 constant MAX_AGE = 120;

    ProvenPoolPrice feed;
    ProveCaller caller;

    function setUp() public {
        vm.etch(MANAGER, hex"00"); // the constructor wants code at the manager; the proofs carry the real state
        feed = new ProvenPoolPrice(MANAGER, POOL, false, MAX_AGE); // IMD is token1 of 0xb07d (DeployConfig _live(..., false))
        caller = new ProveCaller();
        vm.roll(F.BLOCK + 1);
        vm.warp(F.TIMESTAMP + 12);
        vm.setBlockhash(F.BLOCK, F.BLOCK_HASH);
    }

    function _prove() internal returns (uint256) {
        return caller.prove(feed, F.header(), F.accountProof(), F.storageProof());
    }

    function _expected() internal pure returns (uint256) {
        uint256 q = Math.mulDiv(F.SQRT_PRICE_X96, F.SQRT_PRICE_X96, 1 << 64);
        return Math.mulDiv(1e18, 1 << 128, q);
    }

    function test_realProofIsAccepted() public {
        assertTrue(feed.isStale(), "stale before the first proof");
        uint256 v = _prove();
        assertEq(v, _expected(), "LivePoolPrice's formula on the proven sqrtPriceX96");
        (uint256 value, uint64 at) = feed.latestValue();
        assertEq(value, v);
        assertEq(at, F.TIMESTAMP, "dated at the proven block's timestamp");
        assertEq(feed.provenBlock(), F.BLOCK);
        assertFalse(feed.isStale());
        vm.warp(F.TIMESTAMP + MAX_AGE + 1);
        assertTrue(feed.isStale(), "stale after maxAge from the block's timestamp");
    }

    function test_sameOrOlderBlockRefused() public {
        _prove();
        vm.expectRevert(abi.encodeWithSelector(ProvenPoolPrice.NotNewer.selector, F.BLOCK, F.BLOCK));
        _prove();
    }

    function test_blockHashMismatchRefused() public {
        vm.setBlockhash(F.BLOCK, keccak256("another block"));
        vm.expectRevert(ProvenPoolPrice.BadHeader.selector);
        _prove();
    }

    function test_currentBlockRefused() public {
        vm.roll(F.BLOCK); // blockhash(current) is 0
        vm.expectRevert(ProvenPoolPrice.BadHeader.selector);
        _prove();
    }

    function test_blockOutOfRangeRefused() public {
        vm.roll(F.BLOCK + 257); // blockhash reaches 256 back
        vm.setBlockhash(F.BLOCK, bytes32(0));
        vm.expectRevert(ProvenPoolPrice.BadHeader.selector);
        _prove();
    }

    function test_tamperedHeaderRefused() public {
        bytes memory h = F.header();
        for (uint256 i = 4; i < h.length; i += 97) {
            bytes memory t = bytes.concat(h); // copy
            t[i] = bytes1(uint8(t[i]) ^ 0x01);
            vm.expectRevert();
            caller.prove(feed, t, F.accountProof(), F.storageProof());
        }
    }

    function test_tamperedAccountProofRefused() public {
        bytes[] memory a = F.accountProof();
        for (uint256 n; n < a.length; ++n) {
            bytes[] memory t = F.accountProof();
            t[n] = bytes.concat(a[n]);
            t[n][t[n].length / 2] = bytes1(uint8(t[n][t[n].length / 2]) ^ 0x01);
            vm.expectRevert();
            caller.prove(feed, F.header(), t, F.storageProof());
        }
    }

    function test_tamperedStorageProofRefused() public {
        bytes[] memory s = F.storageProof();
        for (uint256 n; n < s.length; ++n) {
            bytes[] memory t = F.storageProof();
            t[n] = bytes.concat(s[n]);
            t[n][t[n].length - 1] = bytes1(uint8(t[n][t[n].length - 1]) ^ 0x01);
            vm.expectRevert();
            caller.prove(feed, F.header(), F.accountProof(), t);
        }
    }

    function test_droppedOrExtraNodeRefused() public {
        bytes[] memory s = F.storageProof();
        bytes[] memory short = new bytes[](s.length - 1);
        for (uint256 i; i < short.length; ++i) short[i] = s[i];
        vm.expectRevert();
        caller.prove(feed, F.header(), F.accountProof(), short);

        bytes[] memory long = new bytes[](s.length + 1);
        for (uint256 i; i < s.length; ++i) long[i] = s[i];
        long[s.length] = s[s.length - 1];
        vm.expectRevert();
        caller.prove(feed, F.header(), F.accountProof(), long);
    }

    function test_proofsSwappedRefused() public {
        // The storage proof offered as the account proof, and the reverse: each must hash to its own root.
        vm.expectRevert();
        caller.prove(feed, F.header(), F.storageProof(), F.accountProof());
    }

    function test_anotherPoolsFeedRefusesThisProof() public {
        ProvenPoolPrice other = new ProvenPoolPrice(MANAGER, keccak256("another pool"), false, MAX_AGE);
        vm.expectRevert(); // the slot key is the feed's own pool: this proof's path does not lead to it
        caller.prove(other, F.header(), F.accountProof(), F.storageProof());
    }

    function test_anotherManagersFeedRefusesThisProof() public {
        address m2 = makeAddr("manager2");
        vm.etch(m2, hex"00");
        ProvenPoolPrice other = new ProvenPoolPrice(m2, POOL, false, MAX_AGE);
        vm.expectRevert(); // the account key is the feed's own manager
        caller.prove(other, F.header(), F.accountProof(), F.storageProof());
    }

    function test_constructorRefusesNoCodeOrZeroAge() public {
        vm.expectRevert(ProvenPoolPrice.InvalidConfig.selector);
        new ProvenPoolPrice(makeAddr("nocode"), POOL, false, MAX_AGE);
        vm.expectRevert(ProvenPoolPrice.InvalidConfig.selector);
        new ProvenPoolPrice(MANAGER, POOL, false, 0);
    }
}
