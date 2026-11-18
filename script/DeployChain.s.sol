// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "./Deploy.s.sol";
import {StageChain} from "./deploy/StageChain.sol";
import {DeployBase} from "./deploy/DeployBase.sol";
import {DeployTypes} from "./DeployConfig.sol";
import {Pulse} from "../src/Pulse.sol";
import {ImdBridge} from "../src/bridge/ImdBridge.sol";

/// @notice script/Deploy.s.sol plus the chain parts: Pulse, ImdBridge and the stock-token module. Same `_deploy`, same
/// order; only the chain parts' constructors live here (script/deploy/StageChain.sol, shared with the staged Robinhood
/// launch in script/launch/), so the mainnet entry stays lean (see Deploy's note). Any config that turns on a chain part must
/// be deployed through this contract (DeployRobinhood is one) or the Robinhood launch stages, or Deploy reverts
/// `NeedsDeployChain`.
contract DeployChain is Deploy, StageChain {
    function _newPulse(uint64 gap, uint64 grace) internal override(DeployBase, StageChain) returns (Pulse) {
        return StageChain._newPulse(gap, grace);
    }

    function _newBridge(address e, address t, address g, address tr) internal override(DeployBase, StageChain) returns (ImdBridge) {
        return StageChain._newBridge(e, t, g, tr);
    }

    function _deployStocks(DeployTypes.Config memory cfg, Deployed memory d, address me) internal override(DeployBase, StageChain) {
        StageChain._deployStocks(cfg, d, me);
    }
}
