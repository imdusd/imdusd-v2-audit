// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFeed} from "../utils/Mocks.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";
import {DoorLeaf, MockProven} from "./PricerTwin.t.sol";

/// @dev An ERC-4626-shaped rate source with no traits (sIMD's vault, sUSDS, wstETH answer none).
contract RtVault {
    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s * 11 / 10;
    }
}

/// @notice AUDIT WAVE 5 (price re-check, low: RateFeed.proven()/converged() looked only at `underlying`). A RateFeed whose
/// RATE SOURCE is an attested swarm leaf (read through its `latestValue`) reported proven and converged while the leaf was
/// clamped, so a spot built on it got the twin rule and "converged legs only agree" from a value one attester key moves.
/// PROPERTY (P4, P5 of the request): a RateFeed reports `converged` only if its underlying AND its rate source are converged
/// (a source with no trait, an ERC-4626 vault or wstETH, counts as converged: nothing clamps it), and `proven` only if its
/// underlying is proven AND its rate source is attester-free (no `converged()`: no attester in the path), through any
/// composite above it. Shipped graphs (rate source = a vault) read exactly as before.
contract AuditW5PriceRateTraitsTest is Test {
    MockFeed plain;
    RtVault vault;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        plain = new MockFeed(2000e18);
        vault = new RtVault();
    }

    /// The judge's proof: leaf 1e18 then 2e18 in one epoch (stored 1.2e18, attested 2e18) as the RATE SOURCE over a proven
    /// underlying. On 422a337: rf.converged(), rf.proven() and ProductFeed(rf, plain).proven() all true.
    function test_judgeProof_attestedRateSourceIsNeitherProvenNorConverged() public {
        DoorLeaf leaf = new DoorLeaf();
        leaf.set(1e18);
        leaf.set(2e18);
        assertFalse(leaf.converged());
        MockProven pp = new MockProven(4e15);
        RateFeed rf = new RateFeed(address(leaf), IFeed.latestValue.selector, false, IFeed(address(pp)), 1e18);
        assertFalse(FeedTraits.converged(IFeed(address(rf))), "an attested input is clamped: must not read converged");
        assertFalse(FeedTraits.proven(IFeed(address(rf))), "an attester is in the path: must not read proven");
        ProductFeed top = new ProductFeed(IFeed(address(rf)), IFeed(address(plain)));
        assertFalse(FeedTraits.proven(IFeed(address(top))), "nor through a product");
        // once the leaf holds what it attested it is converged, but still not attester-free
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        leaf.set(1.2e18);
        assertTrue(leaf.converged());
        assertTrue(FeedTraits.converged(IFeed(address(rf))));
        assertFalse(FeedTraits.proven(IFeed(address(rf))), "a converged swarm rate source is still an attester");
    }

    /// The shipped shape keeps its traits: rate = vault, underlying = proven x Chainlink (sIMD's spot) is proven and
    /// converged; underlying = swarm leaf x Chainlink (sIMD's median) follows the leaf.
    function test_shippedShapesUnchanged() public {
        MockProven pp = new MockProven(4e15);
        RateFeed spot = new RateFeed(
            address(vault), RtVault.convertToAssets.selector, true, new ProductFeed(IFeed(address(pp)), IFeed(address(plain))), 0
        );
        assertTrue(FeedTraits.proven(IFeed(address(spot))));
        assertTrue(FeedTraits.converged(IFeed(address(spot))));
        DoorLeaf leaf = new DoorLeaf();
        leaf.set(4e15);
        RateFeed med = new RateFeed(
            address(vault), RtVault.convertToAssets.selector, true, new ProductFeed(IFeed(address(leaf)), IFeed(address(plain))), 0
        );
        assertFalse(FeedTraits.proven(IFeed(address(med))));
        assertTrue(FeedTraits.converged(IFeed(address(med))));
        leaf.set(10e15);
        assertFalse(FeedTraits.converged(IFeed(address(med))));
    }

    /// Fuzzed: rate source in {vault, swarm leaf converged, swarm leaf clamped, proven stub}, underlying in {proven, plain,
    /// swarm converged, swarm clamped}, optionally under a ProductFeed with a plain factor. The traits must equal the rule.
    function testFuzz_traitsFollowBothInputs(uint8 srcKind, uint8 undKind, bool wrap) public {
        (address src, bytes4 sel, bool pass, bool srcConv, bool srcFree) = _source(srcKind % 4);
        (IFeed und, bool undConv, bool undProven) = _underlying(undKind % 4);
        RateFeed rf = new RateFeed(src, sel, pass, und, 1e18);
        IFeed top = wrap ? IFeed(address(new ProductFeed(IFeed(address(rf)), IFeed(address(plain))))) : IFeed(address(rf));
        assertEq(FeedTraits.converged(top), srcConv && undConv, "converged = both inputs converged");
        assertEq(FeedTraits.proven(top), undProven && srcFree, "proven = underlying proven and rate source attester-free");
    }

    function _source(uint8 k) internal returns (address, bytes4, bool, bool conv, bool free) {
        if (k == 0) return (address(vault), RtVault.convertToAssets.selector, true, true, true);
        if (k == 3) return (address(new MockProven(1e18)), IFeed.latestValue.selector, false, true, true);
        DoorLeaf leaf = new DoorLeaf();
        leaf.set(1e18);
        if (k == 2) leaf.set(5e18);
        return (address(leaf), IFeed.latestValue.selector, false, k == 1, false);
    }

    function _underlying(uint8 k) internal returns (IFeed, bool conv, bool prov) {
        if (k == 0) return (IFeed(address(new MockProven(4e15))), true, true);
        if (k == 1) return (IFeed(address(new MockFeed(4e15))), true, false);
        DoorLeaf leaf = new DoorLeaf();
        leaf.set(4e15);
        if (k == 3) leaf.set(20e15);
        return (IFeed(address(leaf)), k == 2, false);
    }
}
