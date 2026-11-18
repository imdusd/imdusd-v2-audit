// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProvenPoolPrice} from "src/feeds/ProvenPoolPrice.sol";
import {ProvenPoolFixture as F} from "test/fixtures/ProvenPoolFixture.sol";

/// @notice AUDIT WAVE 4 (price design, low: prove accepts any block newer than the held one). PROPERTY: a proof that MOVES
/// the held price is of a block at most PROVE_WINDOW behind the head, so a prover chooses among at most PROVE_WINDOW
/// end-of-block prices, not 256; a block at or below the held one stays a no-op at any age (wave 3); the keeper's
/// previous-block proof is always accepted. Real mainnet fixture (pool 0xb07d, block F.BLOCK).
contract AuditW4ProveWindowTest is Test {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant POOL = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;

    ProvenPoolPrice feed;

    function setUp() public {
        vm.etch(MANAGER, hex"00");
        feed = new ProvenPoolPrice(MANAGER, POOL, false, 6 hours);
        vm.warp(F.TIMESTAMP + 12);
    }

    function _proveAt(uint256 head) internal returns (bool ok) {
        vm.roll(head);
        vm.setBlockhash(F.BLOCK, F.BLOCK_HASH);
        try feed.prove(F.header(), F.accountProof(), F.storageProof()) {
            ok = true;
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(ProvenPoolPrice.TooOld.selector, F.BLOCK, head), "refused as too old");
        }
    }

    /// The judge's proof: a block 250 behind the head was accepted and stood for 6 h.
    function test_judgeProof_blockFarBehindHeadIsRefused() public {
        assertFalse(_proveAt(F.BLOCK + 250), "a block 250 behind the head must not be proven");
        assertEq(feed.provenBlock(), 0);
        assertTrue(feed.isStale());
    }

    /// PROPERTY (fuzzed over the head's distance from the proven block, 1-256): the price moves iff the block is within
    /// PROVE_WINDOW of the head; otherwise nothing changes.
    function testFuzz_onlyRecentBlocksMoveThePrice(uint256 dSeed) public {
        uint256 d = bound(dSeed, 1, 256);
        bool ok = _proveAt(F.BLOCK + d);
        assertEq(ok, d <= feed.PROVE_WINDOW(), "accepted iff within the window");
        assertEq(feed.provenBlock(), ok ? F.BLOCK : 0);
    }

    /// The keeper's shape: the previous block, in the next block.
    function test_previousBlockAccepted() public {
        assertTrue(_proveAt(F.BLOCK + 1));
        assertEq(feed.provenBlock(), F.BLOCK);
    }

    /// Wave 3's no-op stands at any age: once F.BLOCK is held, re-proving it far later is a no-op, never TooOld.
    function testFuzz_heldBlockStaysANoOp(uint256 dSeed) public {
        assertTrue(_proveAt(F.BLOCK + 1));
        uint256 d = bound(dSeed, 2, 256);
        vm.roll(F.BLOCK + d);
        uint256 v = feed.prove(F.header(), F.accountProof(), F.storageProof());
        (uint256 held,) = feed.latestValue();
        assertEq(v, held);
        assertEq(feed.provenBlock(), F.BLOCK);
    }
}
