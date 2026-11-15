// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import "forge-std/Test.sol";
import {DeployTypes} from "script/DeployConfig.sol";
import {StageGenesis} from "script/deploy/StageGenesis.sol";
import {Parameters} from "src/Parameters.sol";
import {ImdDepth} from "src/feeds/ImdDepth.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

/// A pool manager whose every pool reads as initialised at price 1 (StateLibrary.getSlot0 reads extsload).
contract RsCode {
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1 << 96));
    }
}

contract RsToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// Stage 4's depth step exactly as the launch runs it, on a deployment record `d`.
contract RsStage is StageGenesis {
    function depthStep(DeployTypes.Config memory cfg, Deployed memory d) external returns (Deployed memory) {
        _stageDepth(cfg, d);
        return d;
    }
}

/// A resumed stage 4 that rebuilds a sampler (the recorded one is from another config) never lists the new one:
/// Parameters already points at the recorded ImdDepth, so `setGenesisImdDepth` is skipped and ImdDepth keeps measuring
/// the depth of the OLD samplers, which nothing compares with the config.
contract AuditW2ResumeSamplersTest is Test {
    RsStage h;
    address manager;
    address tokenA;
    address tokenB;

    function setUp() public {
        h = new RsStage();
        manager = address(new RsCode());
        (tokenA, tokenB) = (address(new RsToken()), address(new RsToken()));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function _spec(DeployTypes.SamplerSpec memory sp, uint24 fee, int24 spacing) internal view {
        (sp.currency0, sp.currency1, sp.fee, sp.tickSpacing, sp.hooks) = (tokenA, tokenB, fee, spacing, address(0));
        sp.poolId = keccak256(abi.encode(tokenA, tokenB, fee, spacing, address(0)));
        (sp.feed0, sp.feed1) = (DeployTypes.NO_FEED, DeployTypes.NO_FEED);
        (sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0) = (1_500, 200, 64, true);
    }

    /// `n` exit pools: the first is the same pool and spec in every config.
    function _cfg(uint256 n) internal view returns (DeployTypes.Config memory cfg) {
        cfg.poolManager = manager;
        cfg.depth.enabled = true;
        cfg.depth.samplers = new DeployTypes.SamplerSpec[](n);
        _spec(cfg.depth.samplers[0], 10_000, 200);
        if (n > 1) _spec(cfg.depth.samplers[1], 3_000, 60);
    }

    function test_resumedDepthStepListsTheSamplersItKeeps() public {
        RsStage.Deployed memory d;
        d.params = Modules.newParameters(makeAddr("gov"), address(h));
        d.feeds = new IFeed[](0);
        // Run 1 lists one exit pool's sampler A in ImdDepth (the run then stops later in stage 4, before the seal).
        d = h.depthStep(_cfg(1), d);
        address a = address(d.samplers[0]);
        assertEq(d.imdDepth.samplers()[0], a);
        // Resumed with the same config: everything is kept, nothing redeployed.
        RsStage.Deployed memory same = h.depthStep(_cfg(1), d);
        assertEq(address(same.samplers[0]), a, "the recorded sampler is kept");
        // The config gains a second exit pool and stage 4 is resumed on the same record: ImdDepth already lists A alone,
        // so the resume stops (audit wave 2, low) instead of recording samplers the depth rule never reads.
        RsStage.Deployed memory d2 = d;
        vm.expectRevert();
        h.depthStep(_cfg(2), d2);
    }
}
