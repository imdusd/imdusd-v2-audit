// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";
import {DeployTypes} from "script/DeployConfig.sol";
import {StageFeeds} from "script/deploy/StageFeeds.sol";
import {DoorLeaf, MockProven} from "./PricerTwin.t.sol";

contract PpUnit {
    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }
}

/// @dev Exposes the deploy graph's rule.
contract PpDeploy is StageFeeds {
    function provenAtDeploy(DeployTypes.FeedNode[] memory nodes, uint256 i) external pure returns (bool) {
        return _provenAtDeploy(nodes, i);
    }
}

/// @notice AUDIT WAVE 4 (price design, low C5). PROPERTY: a feed reports `proven` only if a proven pool price is in its path
/// and no attester is (no swarm leaf anywhere below it); the deploy graph's `_provenAtDeploy` says the same of a node, so the
/// launch check `FeedTraits.proven(feed) == _provenAtDeploy` holds only when both are true or both false.
contract AuditW4ProvenProductTest is System {
    bytes32 constant TWIN = "TWIN";
    MockFeed eth;
    PpUnit unit;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        eth = new MockFeed(2000e18);
        unit = new PpUnit();
    }

    /// The judge's proof: proven x swarm leaf (clamped) reported proven; with it as spot the Pricer used the twin rule and a
    /// pushed swarm factor raised `low` above the median.
    function test_judgeProof_productOfProvenAndSwarmIsNotProven() public {
        DoorLeaf leaf = new DoorLeaf();
        leaf.set(1e18);
        leaf.set(10e18); // same epoch: clamped to 1.2e18, not converged
        MockProven pp = new MockProven(100e18);
        ProductFeed p = new ProductFeed(IFeed(address(pp)), IFeed(address(leaf)));
        RateFeed r = new RateFeed(address(unit), PpUnit.convertToAssets.selector, true, IFeed(address(p)), 0);
        assertFalse(FeedTraits.proven(IFeed(address(p))), "an attester is in the path");
        assertFalse(FeedTraits.proven(IFeed(address(r))), "an attester is in the path (through RateFeed)");

        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        ParametersBase.Risk memory rk = _risk(1.7e18, 10_000_000e18);
        rk.skew = 0.05e18;
        _addIlk(
            TWIN,
            address(new MockERC20("T", 18)),
            IFeed(address(new MockFeed(100e18))),
            IFeed(address(p)),
            IFeed(address(0)),
            address(0),
            address(0),
            true,
            rk
        );
        Pricer.Quote memory q = pricer.quote(TWIN);
        assertTrue(q.priced);
        assertFalse(q.agree);
        assertEq(q.low, 100e18, "median rule: a spot with an attester in its path gets no twin rule");
    }

    /// Leaves: 0 proven pool price, 1 swarm leaf (attester), 2 Chainlink-like (no traits).
    function _leaf(uint256 kind) internal returns (IFeed f, bool isProven, bool hasAttester) {
        if (kind == 0) return (IFeed(address(new MockProven(1e18))), true, false);
        if (kind == 1) {
            DoorLeaf l = new DoorLeaf();
            l.set(1e18);
            return (IFeed(address(l)), false, true);
        }
        return (IFeed(address(new MockFeed(1e18))), false, false);
    }

    /// @dev A random tree of up to 4 leaves under products and rate feeds; returns whether any leaf is proven / an attester.
    function _tree(uint256 seed, uint256 depth) internal returns (IFeed f, bool anyProven, bool anyAttester) {
        if (depth == 0 || seed % 4 == 0) return _leaf((seed >> 2) % 3);
        if (seed % 4 == 1) {
            (IFeed u, bool p, bool a) = _tree(seed >> 4, depth - 1);
            return (IFeed(address(new RateFeed(address(unit), PpUnit.convertToAssets.selector, true, u, 0))), p, a);
        }
        (IFeed x, bool px, bool ax) = _tree(uint256(keccak256(abi.encode(seed, 1))), depth - 1);
        (IFeed y, bool py, bool ay) = _tree(uint256(keccak256(abi.encode(seed, 2))), depth - 1);
        return (IFeed(address(new ProductFeed(x, y))), px || py, ax || ay);
    }

    /// PROPERTY (fuzzed over feed trees): proven => a proven leaf in the path and no attester in it.
    function testFuzz_provenOnlyWithoutAnAttester(uint256 seed) public {
        (IFeed f, bool anyProven, bool anyAttester) = _tree(seed, 3);
        if (FeedTraits.proven(f)) {
            assertTrue(anyProven, "proven without a proven leaf");
            assertFalse(anyAttester, "proven with an attester in the path");
        }
    }

    /// Liveness: the deployed sIMD spot shape (rate x (proven x Chainlink), either side) still reads proven.
    function test_deployShapeStillProven() public {
        IFeed pp = IFeed(address(new MockProven(1e18)));
        IFeed ch = IFeed(address(eth));
        assertTrue(FeedTraits.proven(IFeed(address(new ProductFeed(pp, ch)))));
        assertTrue(FeedTraits.proven(IFeed(address(new ProductFeed(ch, pp)))));
        IFeed prod = IFeed(address(new ProductFeed(pp, ch)));
        IFeed rate = IFeed(address(new RateFeed(address(unit), PpUnit.convertToAssets.selector, true, prod, 0)));
        assertTrue(FeedTraits.proven(rate));
        assertTrue(FeedTraits.proven(IFeed(address(new ProductFeed(prod, ch)))));
    }

    /// The deploy rule mirrors the contract (fuzzed over node kinds of a product): proven(a) x b and a x proven(b).
    function testFuzz_deployRuleMirrorsTheContract(uint8 kindA, uint8 kindB) public {
        PpDeploy d = new PpDeploy();
        uint8[4] memory kinds = [DeployTypes.PROVEN_POOL, DeployTypes.SWARM_PRICE, DeployTypes.CHAINLINK, DeployTypes.LIVE_POOL];
        uint8 ka = kinds[kindA % 4];
        uint8 kb = kinds[kindB % 4];
        DeployTypes.FeedNode[] memory n = new DeployTypes.FeedNode[](3);
        n[0].kind = ka;
        n[1].kind = kb;
        n[2].kind = DeployTypes.PRODUCT;
        n[2].a = 0;
        n[2].b = 1;
        bool hasProven = ka == DeployTypes.PROVEN_POOL || kb == DeployTypes.PROVEN_POOL;
        bool hasAttester = ka == DeployTypes.SWARM_PRICE || kb == DeployTypes.SWARM_PRICE;
        assertEq(d.provenAtDeploy(n, 2), hasProven && !hasAttester);
    }
}
