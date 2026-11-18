// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ImdBridge, IMintableBurnable} from "../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {MainnetConfig} from "./DeployConfig.sol";

/// @notice Ethereum's side of the 4663 path: one ImdBridge for the already-deployed v2 imdUSD,
/// governed by the mainnet Safe, its per-destination fee minted to the v2 Treasury. Not yet a minter: the Safe then proposes
/// SET_BRIDGE on Parameters (48h) and opens the path with RobinhoodConfig.launchBatchMainnet(robinhoodPathOnMainnet(...)) in
/// one BATCH (48h: path, both library pins, executor + DVN config). The deployer holds no power over it.
/// NO GUARDIAN: only the Safe pauses a path, holds one inbound message (72h, once per nonce) or voids a
/// payload, all instant; unpause, release and unvoid are timelocked. The ops watcher holds no key: it alerts the signers when a
/// `Received` nonce has no `Sent` at the peer (cross-chain; netMinted() cannot show a forgery, audit wave 4).
/// Paging the Safe signers from the watcher is an off-chain duty (not in this repository).
///
///   forge script script/DeployMainnetBridge.s.sol:DeployMainnetBridge --sig 'run(address,address)' \
///     <imdUSD v2> <v2 Treasury> --rpc-url $MAINNET_RPC_URL --sender <deployer> --broadcast --verify
contract DeployMainnetBridge is Script {
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // LayerZero EndpointV2, Ethereum

    error WrongChain(uint256 chainId);
    error NotAContract(address a);
    error TreasuryMismatch(address treasury);

    function run(address token, address treasury) external returns (ImdBridge bridge) {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        if (token.code.length == 0) revert NotAContract(token);
        if (treasury.code.length == 0) revert NotAContract(treasury);
        // the v2 Treasury is governed by the same Safe as everything else
        (bool ok, bytes memory g) = treasury.staticcall(abi.encodeWithSignature("governor()"));
        if (!ok || abi.decode(g, (address)) != MainnetConfig.GOVERNANCE_SAFE) revert TreasuryMismatch(treasury);
        vm.startBroadcast();
        bridge = new ImdBridge(
            ILayerZeroEndpointV2(ENDPOINT), IMintableBurnable(token), MainnetConfig.GOVERNANCE_SAFE, treasury
        );
        vm.stopBroadcast();
    }
}
