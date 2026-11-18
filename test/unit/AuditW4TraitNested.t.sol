// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFeed} from "../utils/Mocks.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";

/// @dev Leaf kinds for the trait reads: one whose traits burn all gas, one whose traits revert WITH data, one that answers
/// false (not converged, not proven: the honest "no").
contract BurnLeaf is MockFeed {
    constructor() MockFeed(1e18) {}

    function converged() external pure returns (bool) {
        while (true) {}
        return true;
    }

    function proven() external pure returns (bool) {
        while (true) {}
        return true;
    }
}

contract RevertLeaf is MockFeed {
    error Broken();

    constructor() MockFeed(1e18) {}

    function converged() external pure returns (bool) {
        revert Broken();
    }

    function proven() external pure returns (bool) {
        revert Broken();
    }
}

contract NoLeaf is MockFeed {
    constructor() MockFeed(1e18) {}

    function converged() external pure returns (bool) {
        return false;
    }
}

contract UnitRate {
    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }
}

/// @dev Stands where the Pricer stands: a top-level FeedTraits reader, called with a chosen gas limit.
contract TraitReader {
    function converged(IFeed f) external view returns (bool) {
        return FeedTraits.converged(f);
    }

    function proven(IFeed f) external view returns (bool) {
        return FeedTraits.proven(f);
    }
}

/// @notice AUDIT WAVE 4 (price design, low C4). PROPERTY: a trait read through any composite graph answers "converged" (or
/// "proven") only if every leaf in the path answered it; a leaf whose trait read fails (out of gas, or a revert with data)
/// makes the top-level read revert, however many composites sit between, whatever gas the caller gives.
contract AuditW4TraitNestedTest is Test {
    TraitReader reader;
    MockFeed plain;
    UnitRate unit;

    function setUp() public {
        reader = new TraitReader();
        plain = new MockFeed(2000e18);
        unit = new UnitRate();
    }

    /// The judge's proof: a product of an out-of-gas leaf, and the RateFeed over it (the sIMD median's shape).
    function test_judgeProof_compositeOverOutOfGasLeafReverts() public {
        BurnLeaf burn = new BurnLeaf();
        vm.expectRevert(abi.encodeWithSelector(FeedTraits.TraitUnreadable.selector, address(burn)));
        reader.converged(IFeed(address(burn))); // control: a direct read
        ProductFeed p = new ProductFeed(IFeed(address(burn)), IFeed(address(plain)));
        vm.expectRevert();
        reader.converged(IFeed(address(p)));
        RateFeed r = new RateFeed(address(unit), UnitRate.convertToAssets.selector, true, IFeed(address(p)), 0);
        vm.expectRevert();
        r.converged();
        vm.expectRevert();
        reader.converged(IFeed(address(r)));
    }

    function _wrap(IFeed leaf, uint256 shape) internal returns (IFeed f) {
        f = leaf;
        uint256 depth = 1 + shape % 3;
        for (uint256 i; i < depth; ++i) {
            if ((shape >> (i + 2)) & 1 == 0) {
                f = (shape >> (i + 6)) & 1 == 0
                    ? IFeed(address(new ProductFeed(f, IFeed(address(plain)))))
                    : IFeed(address(new ProductFeed(IFeed(address(plain)), f)));
            } else {
                f = IFeed(address(new RateFeed(address(unit), UnitRate.convertToAssets.selector, true, f, 0)));
            }
        }
    }

    /// PROPERTY (fuzzed over the leaf kind, 1-3 nested composites of either kind and side, and the caller's gas): the read
    /// either reverts or gives the honest answer; it never reports converged/proven over a leaf that did not say so.
    function testFuzz_neverYesOverAFailedOrNoLeaf(uint8 kind, uint256 shape, uint256 gasSeed, bool askProven) public {
        IFeed leaf;
        kind %= 3;
        if (kind == 0) leaf = IFeed(address(new BurnLeaf()));
        else if (kind == 1) leaf = IFeed(address(new RevertLeaf()));
        else leaf = IFeed(address(new NoLeaf()));
        IFeed f = _wrap(leaf, shape);
        uint256 g = bound(gasSeed, 5_000, 3_000_000);
        bool yes;
        if (askProven) {
            try reader.proven{gas: g}(f) returns (bool v) {
                yes = v;
            } catch {}
        } else {
            try reader.converged{gas: g}(f) returns (bool v) {
                yes = v;
            } catch {}
        }
        assertFalse(yes, "a trait read answered yes over a leaf that failed or said no");
    }

    /// Liveness of the same reads: over honest leaves with enough gas the composites answer (converged over a feed with no
    /// trait = yes, as before).
    function testFuzz_honestGraphStillAnswers(uint256 shape) public {
        IFeed f = _wrap(IFeed(address(new MockFeed(1e18))), shape);
        assertTrue(reader.converged(f));
        assertFalse(reader.proven(f));
    }
}
