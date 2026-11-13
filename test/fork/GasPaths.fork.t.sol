// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {ProvenPoolPrice} from "../../src/feeds/ProvenPoolPrice.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";
import {ProvenPoolFixture as F} from "../fixtures/ProvenPoolFixture.sol";

/// @dev A feed that stays fresh across warps (Chainlink would read stale).
contract GasFreshFeed is IFeed {
    uint256 public v;

    constructor(uint256 v_) {
        v = v_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (v, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }

    function maxAge() external pure returns (uint256) {
        return 1 hours;
    }
}

interface IAggGas {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice GAS REVIEW: the keeper's recurring costs on REAL mainnet pools (fork at the proof fixture's block):
/// ProvenPoolPrice.prove on a real proof, each of the config's three DepthSamplers sampling its real pool against the proven
/// reference, and ImdDepth.poke. Logs `gas <name> <amount>`; a before/after diff of the logs is the measurement.
contract GasPathsForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function test_gas_keeperRound() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return vm.skip(true);
        vm.createSelectFork(rpc, F.BLOCK);
        (, int256 e8,,,) = IAggGas(CL_ETH_USD).latestRoundData();
        GasFreshFeed eth = new GasFreshFeed(uint256(e8) * 1e10);
        vm.roll(F.BLOCK + 1);
        vm.warp(F.TIMESTAMP + 12);
        vm.setBlockhash(F.BLOCK, F.BLOCK_HASH);

        DeployTypes.Config memory cfg = MainnetConfig.get();
        ProvenPoolPrice proven = new ProvenPoolPrice(address(PM), MainnetConfig.IMD_ETH_POOL_ID, false, MainnetConfig.PROVEN_MAX_AGE);
        IFeed imdUsd = IFeed(address(new ProductFeed(IFeed(address(proven)), IFeed(address(eth)))));
        ImdDepth agg = new ImdDepth(address(this));
        DepthSampler[] memory s = new DepthSampler[](cfg.depth.samplers.length);
        for (uint256 i; i < s.length; ++i) {
            DeployTypes.SamplerSpec memory sp = cfg.depth.samplers[i];
            PoolKey memory key =
                PoolKey(Currency.wrap(sp.currency0), Currency.wrap(sp.currency1), sp.fee, sp.tickSpacing, IHooks(sp.hooks));
            IFeed f0 = sp.feed0 == DeployTypes.NO_FEED ? IFeed(address(0)) : IFeed(address(eth));
            s[i] = new DepthSampler(PM, key, f0, imdUsd, sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0);
            agg.addSampler(address(s[i]));
        }

        bytes memory h = F.header();
        bytes[] memory ap = F.accountProof();
        bytes[] memory sp_ = F.storageProof();
        uint256 g = gasleft();
        proven.prove(h, ap, sp_);
        console2.log("gas prove", g - gasleft());

        uint256 total;
        for (uint256 i; i < s.length; ++i) {
            g = gasleft();
            try s[i].sample() {
                uint256 used = g - gasleft();
                total += used;
                console2.log(string.concat("gas sample ", vm.toString(i)), used);
            } catch (bytes memory err) {
                console2.log(string.concat("sample ", vm.toString(i), " refused"), vm.toString(err));
            }
        }
        console2.log("gas samples total", total);
        g = gasleft();
        agg.poke();
        console2.log("gas poke", g - gasleft());
    }

    /// A full window: 24 hourly samples on the two pools the reference reaches, then a poke and the depth reads an sIMD borrow
    /// makes (Parameters -> ImdDepth.depth() -> each sampler's depth()). The reference is a fixed feed at the proven price so the
    /// hours can be warped (a proof is tied to its block); the gas of a read does not depend on where the reference comes from.
    function test_gas_fullWindowReads() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return vm.skip(true);
        vm.createSelectFork(rpc, F.BLOCK);
        (, int256 e8,,,) = IAggGas(CL_ETH_USD).latestRoundData();
        GasFreshFeed eth = new GasFreshFeed(uint256(e8) * 1e10);
        vm.roll(F.BLOCK + 1);
        vm.warp(F.TIMESTAMP + 12);
        vm.setBlockhash(F.BLOCK, F.BLOCK_HASH);
        ProvenPoolPrice proven = new ProvenPoolPrice(address(PM), MainnetConfig.IMD_ETH_POOL_ID, false, MainnetConfig.PROVEN_MAX_AGE);
        proven.prove(F.header(), F.accountProof(), F.storageProof());
        (uint256 imdEth,) = proven.latestValue();
        IFeed imdUsd = IFeed(address(new GasFreshFeed(imdEth * (uint256(e8) * 1e10) / 1e18)));

        DeployTypes.Config memory cfg = MainnetConfig.get();
        ImdDepth agg = new ImdDepth(address(this));
        DepthSampler[] memory s = new DepthSampler[](2);
        for (uint256 i; i < 2; ++i) {
            DeployTypes.SamplerSpec memory sp = cfg.depth.samplers[i];
            PoolKey memory key =
                PoolKey(Currency.wrap(sp.currency0), Currency.wrap(sp.currency1), sp.fee, sp.tickSpacing, IHooks(sp.hooks));
            s[i] = new DepthSampler(PM, key, IFeed(address(eth)), imdUsd, sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0);
            agg.addSampler(address(s[i]));
        }
        uint256 lastSample;
        uint256 lastPoke;
        for (uint256 h; h < 25; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 g = gasleft();
            s[0].sample();
            lastSample = g - gasleft();
            s[1].sample();
            g = gasleft();
            agg.poke();
            lastPoke = g - gasleft();
        }
        console2.log("gas sample (full window)", lastSample);
        console2.log("gas poke (full window)", lastPoke);
        uint256 g2 = gasleft();
        uint256 d = agg.depth();
        console2.log("gas ImdDepth.depth (2 samplers, full window)", g2 - gasleft());
        console2.log("depth USD", d / 1e18);
    }
}
