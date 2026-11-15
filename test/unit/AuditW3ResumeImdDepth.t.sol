// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import "forge-std/Test.sol";
import {DeployTypes} from "script/DeployConfig.sol";
import {StageGenesis} from "script/deploy/StageGenesis.sol";
import {Parameters} from "src/Parameters.sol";
import {ImdDepth} from "src/feeds/ImdDepth.sol";
import {DepthSampler} from "src/feeds/DepthSampler.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

/// A pool manager whose every pool reads as initialised at price 1 (StateLibrary.getSlot0 reads extsload).
contract RpCode {
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1 << 96));
    }
}

contract RpToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// Stage 4's depth step exactly as the launch runs it, on a deployment record `d`.
contract RpStage is StageGenesis {
    function depthStep(DeployTypes.Config memory cfg, Deployed memory d) external returns (Deployed memory) {
        _stageDepth(cfg, d);
        return d;
    }
}

/// DeployBase's resume rule: a recorded piece with code but other wiring stops the run (Mismatch) for a person to decide.
/// The depth step breaks it: when Parameters already points at ImdDepth A (run 1) and the resumed record carries no (or
/// another) ImdDepth, `_stageDepth` deploys B and calls `setGenesisImdDepth(B)` again, which has no already-set guard
/// (Parameters.sol:116-123). A is orphaned with every low the keeper poked into it, and the depth rule restarts at 0.
contract ProofResumeRepointsImdDepthTest is Test {
    RpStage h;
    address manager;
    address tokenA;
    address tokenB;

    function setUp() public {
        h = new RpStage();
        manager = address(new RpCode());
        (tokenA, tokenB) = (address(new RpToken()), address(new RpToken()));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function _cfg() internal view returns (DeployTypes.Config memory cfg) {
        cfg.poolManager = manager;
        cfg.depth.enabled = true;
        cfg.depth.samplers = new DeployTypes.SamplerSpec[](1);
        DeployTypes.SamplerSpec memory sp = cfg.depth.samplers[0];
        (sp.currency0, sp.currency1, sp.fee, sp.tickSpacing, sp.hooks) = (tokenA, tokenB, 10_000, 200, address(0));
        sp.poolId = keccak256(abi.encode(tokenA, tokenB, uint24(10_000), int24(200), address(0)));
        (sp.feed0, sp.feed1) = (DeployTypes.NO_FEED, DeployTypes.NO_FEED);
        (sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0) = (1_500, 200, 64, true);
    }

    function test_resumeWithoutTheRecordedImdDepthStopsInsteadOfRepointingParameters() public {
        RpStage.Deployed memory d;
        d.params = Modules.newParameters(makeAddr("gov"), address(h));
        d.feeds = new IFeed[](0);
        // Run 1: ImdDepth A deployed, its sampler listed, Parameters wired to A. The run stops later in stage 4.
        d = h.depthStep(_cfg(), d);
        ImdDepth a = d.imdDepth;
        assertEq(address(d.params.imdDepth()), address(a));

        // Resume on a record that lost the ImdDepth entry (the samplers are still recorded).
        RpStage.Deployed memory d2 = d;
        d2.imdDepth = ImdDepth(address(0));
        // Expected (DeployBase's rule, as the sleeves do: "Parameters points at other sleeves"): revert Mismatch.
        vm.expectRevert();
        h.depthStep(_cfg(), d2);
    }

    function test_setGenesisImdDepthCanBeCalledTwice() public {
        Parameters p = Modules.newParameters(makeAddr("gov"), address(this));
        ImdDepth a = new ImdDepth(address(p));
        ImdDepth b = new ImdDepth(address(p));
        p.setGenesisImdDepth(address(a), new address[](0));
        // Expected: a second wiring is refused (BadConfig), as setGenesisBackstops refuses a second call.
        vm.expectRevert();
        p.setGenesisImdDepth(address(b), new address[](0));
    }
}
/// @notice PROPERTY (audit wave 3): once Parameters is wired to an ImdDepth, no resumed stage 4 re-points it: whatever the record
/// carries (no ImdDepth, the wired one, another one built for this Parameters, one for another Parameters; samplers kept or
/// lost), the depth step either stops or leaves Parameters on the ImdDepth it was wired to, listing the same samplers.
contract AuditW3ResumeImdDepthPropertyTest is ProofResumeRepointsImdDepthTest {
    function testFuzz_resumeNeverRepointsParameters(uint8 which, bool keepSamplers) public {
        RpStage.Deployed memory d;
        d.params = Modules.newParameters(makeAddr("gov"), address(h));
        d.feeds = new IFeed[](0);
        d = h.depthStep(_cfg(), d);
        ImdDepth a = d.imdDepth;
        bytes32 listBefore = keccak256(abi.encode(a.samplers()));

        RpStage.Deployed memory d2 = d;
        which %= 4;
        if (which == 0) d2.imdDepth = ImdDepth(address(0));
        else if (which == 2) d2.imdDepth = new ImdDepth(address(d.params));
        else if (which == 3) d2.imdDepth = new ImdDepth(address(Modules.newParameters(makeAddr("gov"), address(h))));
        if (!keepSamplers) d2.samplers = new DepthSampler[](0);
        try h.depthStep(_cfg(), d2) {} catch {}
        assertEq(address(d.params.imdDepth()), address(a), "Parameters stays on the ImdDepth it was wired to");
        assertEq(keccak256(abi.encode(a.samplers())), listBefore, "and that ImdDepth lists the same samplers");
    }
}
