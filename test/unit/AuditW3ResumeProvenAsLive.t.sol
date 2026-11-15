// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {DeployTypes} from "script/DeployConfig.sol";
import {StageFeeds} from "script/deploy/StageFeeds.sol";
import {ProvenPoolPrice} from "src/feeds/ProvenPoolPrice.sol";
import {LivePoolPrice} from "src/feeds/LivePoolPrice.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract PaCode {
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1 << 96));
    }
}

/// Stage 2 exactly as the launch runs it, on a deployment record `d`.
contract PaStage is StageFeeds {
    function feedsStep(DeployTypes.Config memory cfg, Deployed memory d) external returns (Deployed memory) {
        _stageFeeds(cfg, d);
        return d;
    }
}

/// DeployBase._feedIs's LIVE_POOL branch reads manager(), poolId() and baseIsToken0(): a ProvenPoolPrice (wave 3's
/// PROVEN_POOL kind) answers all three with the same values for the same pool, so a resumed stage 2 whose record holds a
/// ProvenPoolPrice at a LIVE_POOL node's index keeps it instead of stopping with Mismatch("feed").
contract ProofResumeAdoptsProvenAsLiveTest is Test {
    bytes32 constant POOL = keccak256("pool");

    function test_provenPoolPriceRecordedAtALivePoolNodeIsNotKept() public {
        PaStage h = new PaStage();
        address manager = address(new PaCode());
        DeployTypes.Config memory cfg;
        cfg.feeds = new DeployTypes.FeedNode[](1);
        cfg.feeds[0].kind = DeployTypes.LIVE_POOL;
        cfg.feeds[0].source = manager;
        cfg.feeds[0].poolId = POOL;
        cfg.feeds[0].passOneE18 = false; // base is token1, as BetaConfig's F_IMD_LIVE

        PaStage.Deployed memory d;
        d.feeds = new IFeed[](1);
        d.feeds[0] = IFeed(address(new ProvenPoolPrice(manager, POOL, false, 6 hours)));

        // Expected: the kept piece is compared with the config and the run stops (Mismatch) or a LivePoolPrice is built.
        // Actual: the ProvenPoolPrice is kept as the LIVE_POOL node.
        // (Adapted from the judge's proof: it accepts either outcome; the fixed code stops with Mismatch("feed").)
        try h.feedsStep(cfg, d) returns (PaStage.Deployed memory out) {
            assertTrue(address(out.feeds[0]) != address(d.feeds[0]), "a ProvenPoolPrice must not be kept as a LIVE_POOL node");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSignature("Mismatch(string)", "feed"), "stops with Mismatch(feed)");
        }
    }

    function test_control_livePoolPriceAtAProvenNodeIsRefused() public {
        PaStage h = new PaStage();
        address manager = address(new PaCode());
        DeployTypes.Config memory cfg;
        cfg.feeds = new DeployTypes.FeedNode[](1);
        cfg.feeds[0].kind = DeployTypes.PROVEN_POOL;
        cfg.feeds[0].source = manager;
        cfg.feeds[0].poolId = POOL;
        cfg.feeds[0].maxAge = 6 hours;
        PaStage.Deployed memory d;
        d.feeds = new IFeed[](1);
        d.feeds[0] = IFeed(address(new LivePoolPrice(IPoolManager(manager), POOL, false)));
        vm.expectRevert();
        h.feedsStep(cfg, d);
    }
}
/// @notice PROPERTY (audit wave 3): a resumed stage 2 keeps a recorded pool feed only if it is of its node's kind. Fuzzed over
/// the node's kind (LIVE_POOL / PROVEN_POOL), the recorded contract's kind and its side (base token0 or token1), with every
/// shared getter (manager, pool, side, and the ProvenPoolPrice's maxAge) equal to the node's: the record is kept iff the kinds
/// match; otherwise the run stops (Mismatch) or builds the node's own kind.
contract AuditW3ResumePoolFeedKindPropertyTest is Test {
    bytes32 constant POOL = keccak256("pool");

    function testFuzz_poolFeedKeptOnlyAtItsOwnKind(bool nodeLive, bool recordedLive, bool base0) public {
        PaStage h = new PaStage();
        address manager = address(new PaCode());
        DeployTypes.Config memory cfg;
        cfg.feeds = new DeployTypes.FeedNode[](1);
        cfg.feeds[0].kind = nodeLive ? DeployTypes.LIVE_POOL : DeployTypes.PROVEN_POOL;
        cfg.feeds[0].source = manager;
        cfg.feeds[0].poolId = POOL;
        cfg.feeds[0].passOneE18 = base0;
        cfg.feeds[0].maxAge = 6 hours;
        PaStage.Deployed memory d;
        d.feeds = new IFeed[](1);
        d.feeds[0] = recordedLive
            ? IFeed(address(new LivePoolPrice(IPoolManager(manager), POOL, base0)))
            : IFeed(address(new ProvenPoolPrice(manager, POOL, base0, 6 hours)));
        try h.feedsStep(cfg, d) returns (PaStage.Deployed memory out) {
            bool kept = address(out.feeds[0]) == address(d.feeds[0]);
            assertEq(kept, nodeLive == recordedLive, "kept iff the recorded feed is the node's kind");
            if (!kept) {
                (bool proven,) = address(out.feeds[0]).staticcall(abi.encodeWithSignature("provenBlock()"));
                assertEq(!proven, nodeLive, "a rebuilt node is of its own kind");
            }
        } catch {
            assertTrue(nodeLive != recordedLive, "a matching record is never refused");
        }
    }
}
