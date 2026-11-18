// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployChain} from "./DeployChain.s.sol";
import {DeployTypes, RobinhoodConfig} from "./DeployConfig.sol";

/// @notice Robinhood Chain (4663): script/Deploy.s.sol, unchanged, with RobinhoodConfig. The base script
/// refuses any chain but 4663 (`ChainSpec.chainId`); this entry also refuses a governor with no code, so the placeholder
/// (no Safe on 4663 yet) and any EOA are rejected before anything is broadcast. Rehearsed by test/fork/Robinhood.t.sol.
///
///   forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url $ROBINHOOD_RPC_URL --sender <deployer> --broadcast
///
/// After it (the Safe): SET_BRIDGE on Parameters (48h) here and on mainnet; ImdBridge SET_PATH on
/// both = RobinhoodConfig.launchBatch4663 / launchBatchMainnet (peer + limits, both library pins, executor + DVN config; 48h); buy the first IMD price, spot and NHI
/// attestations for the three swarm feeds (consumer chain 4663) and check them against mainnet before any IMD deposit.
/// The bridge has NO GUARDIAN: only the 4663 Safe pauses, holds and voids (instant); the ops watcher alerts
/// the signers when a `Received` nonce here has no `Sent` at the peer (audit wave 4). Paging the signers is an off-chain duty.
contract DeployRobinhood is DeployChain {
    error GovernorNotAContract(address governor);

    function config() public pure override returns (DeployTypes.Config memory) {
        return RobinhoodConfig.get();
    }

    function run() external override returns (Deployed memory d) {
        DeployTypes.Config memory cfg = config();
        if (cfg.governor.code.length == 0) revert GovernorNotAContract(cfg.governor);
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();
    }
}
