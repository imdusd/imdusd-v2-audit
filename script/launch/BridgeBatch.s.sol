// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {DeployTypes, RobinhoodConfig} from "../DeployConfig.sol";
import {BetaEntry, RobinhoodEntry} from "./LaunchBase.sol";
import {SafeBatch} from "./SafeBatch.s.sol";

/// @notice The Safe's bridge acts on ONE chain, as Safe Transaction Builder files, each SIMULATED FROM THAT
/// CHAIN'S SAFE first and applied in the simulation after its timelock (nothing is broadcast). Two SEPARATE steps:
///
///   forge script script/launch/BridgeBatch.s.sol:BridgeBatch<Beta|Robinhood> --sig "path()" --rpc-url <rpc>
///       (launch.sh bridgepath)  file B2: ImdBridge.propose(BATCH) = SET_PATH (peer = the OTHER chain's ImdBridge, out/in
///       limits 50,000/day each way (RobinhoodConfig OUT_LIMIT / IN_LIMIT, mirrored), enforced lzReceive options) + both
///       library pins (send ULN302, receive ULN302, grace 0)
///       + the executor config + the ULN config on each library: 3 REQUIRED DVNs (LayerZero Labs, Twinstake, P2P, sorted),
///       optional = NIL, 15 confirmations from mainnet / 20 from 4663. Needs LAUNCH_PEER_BRIDGE (the other record's bridge).
///       Reversible: until SET_BRIDGE the bridge mints nothing, and the Safe can pause the path at once.
///
///   forge script script/launch/BridgeBatch.s.sol:BridgeBatch<Beta|Robinhood> --sig "setBridge()" --rpc-url <rpc>
///       (launch.sh setbridge)  file B1: Parameters.propose(SET_BRIDGE, ImdBridge). ImdUSD.setBridge works ONCE
///       (AlreadySet): the bridge contract becomes imdUSD's minter for good, only pausable. Refused unless
///       LAUNCH_WAVE5_RECHECK=clean: write it only after the wave-5 audit re-check of the bridge came back clean.
///
/// Both proposals wait 48 h (Parameters' SET_BRIDGE, ImdBridge's own Governed timelock); anyone applies after. Value can
/// cross only once all four (SET_BRIDGE x2, path x2) have applied on both chains. Files go to LAUNCH_SAFE_DIR/bridge/.
abstract contract BridgeBatch is SafeBatch {
    function run() external pure override {
        revert("BridgeBatch: call path() or setBridge() (two separate steps)");
    }

    /// @notice The path's enforced options: the ONE source is RobinhoodConfig.enforcedOptions() (lzReceive gas LZ_RECEIVE_GAS =
    /// 250,000; the worst path measured with the real ImdUSD today is 192,275, see its note for Glamsterdam), so a path cannot
    /// carry another value.
    function enforcedOptions() public pure returns (bytes memory) {
        return RobinhoodConfig.enforcedOptions();
    }

    /// @dev The other side's eid and this side's whole launch BATCH for it.
    function _remoteEid() internal pure virtual returns (uint32);

    function _pathBatch(bytes32 peer) internal pure virtual returns (bytes memory);

    function _start() internal returns (Deployed memory d, string memory dir) {
        Rec memory r;
        (d, r) = _load();
        require(r.exists, "no record");
        DeployTypes.Config memory cfg = config();
        for (uint8 s = 1; s <= 4; ++s) _checkStage(cfg, d, r, s, false);
        _checkStage(cfg, d, r, cfg.bridge.enabled ? 5 : 6, false); // the bridge landed
        dir = string.concat(vm.envOr("LAUNCH_SAFE_DIR", string.concat("deploy/mainnet/out/safe/", configName())), "/bridge");
        vm.createDir(dir, true);
    }

    /// @notice File B2, the path BATCH (see the contract note).
    function path() external {
        (Deployed memory d, string memory dir) = _start();
        ImdBridge b = d.bridge;
        address peer = vm.envAddress("LAUNCH_PEER_BRIDGE");
        require(peer != address(0) && peer != address(b), "LAUNCH_PEER_BRIDGE: the OTHER chain's ImdBridge");
        uint32 eid = _remoteEid();
        if (b.peers(eid) != bytes32(0)) return console2.log("file B2 not written: the path is already set", vm.toString(b.peers(eid)));
        if (b.pendingEta() != 0) return console2.log("file B2 not written: a proposal is pending on the bridge (apply or cancel it first)");
        bytes32 peer32 = bytes32(uint256(uint160(peer)));
        bytes memory payload = _pathBatch(peer32);
        uint256 at = vm.getBlockTimestamp();
        Tx[] memory t = new Tx[](1);
        t[0] = Tx(address(b), abi.encodeWithSignature("propose(bytes)", payload));
        _exec(config().governor, t);
        _applyBridge(b);
        require(b.peers(eid) == peer32, "simulated: peer");
        require(b.sendLibrary(eid) != address(0) && b.receiveLibrary(eid) != address(0), "simulated: libraries pinned");
        require(b.configured(b.sendLibrary(eid), eid) && b.configured(b.receiveLibrary(eid), eid), "simulated: ULN configs set");
        require(keccak256(b.enforcedOptions(eid)) == keccak256(enforcedOptions()), "simulated: enforced options");
        require(b.availableOut(eid) != 0 && b.availableIn(eid) != 0, "simulated: limits");
        require(!b.paused(eid), "simulated: path open");
        require(_delayIs(b, eid), "simulated: delay settings (instant cap, claim delay, queue breaker)");
        _write(
            dir,
            2,
            at,
            string.concat("Bridge path to eid ", vm.toString(uint256(eid)), ": peer, limits, libraries, 3 DVNs"),
            string.concat(
                "ImdBridge.propose(BATCH: SET_PATH peer ", vm.toString(peer), _limitsAndGas(b, eid),
                "; SET_DELAY instant cap ", vm.toString(RobinhoodConfig.INSTANT_CAP / 1e18), " imdUSD/day, claim delay ",
                vm.toString(RobinhoodConfig.CLAIM_DELAY / 1 hours), " h, queue breaker ", vm.toString(RobinhoodConfig.QUEUE_BREAKER / 1e18),
                " imdUSD over 4 UTC days; pin send + receive ULN302; executor + ULN config, 3 required DVNs, optional NIL). ",
                "Anyone calls ImdBridge.applyPending() 48 h after it executes. Mints nothing until SET_BRIDGE (file B1) applies."
            ),
            config().governor,
            t
        );
    }

    /// @dev What the signers read about the path, built from the SIMULATED bridge (its full windows after apply) and the one
    /// source of the enforced options, so the description cannot drift from the payload (fixed before audit wave 5: it said 200,000
    /// gas while the payload carried 250,000).
    function _limitsAndGas(ImdBridge b, uint32 eid) internal view returns (string memory) {
        return string.concat(
            " limits ", vm.toString(b.availableOut(eid) / 1e18), " imdUSD/day out, ", vm.toString(b.availableIn(eid) / 1e18),
            " imdUSD/day in + enforced lzReceive gas ", vm.toString(uint256(RobinhoodConfig.LZ_RECEIVE_GAS))
        );
    }

    /// @dev The simulated bridge holds the launch delay settings for `eid` (RobinhoodConfig, both paths).
    function _delayIs(ImdBridge b, uint32 eid) internal view returns (bool) {
        (,, uint64 capSD) = b.instantIn(eid);
        (,,, uint64 breakerSD, uint32 delay,,) = b.breakers(eid);
        return uint256(capSD) * 1e12 == RobinhoodConfig.INSTANT_CAP && delay == RobinhoodConfig.CLAIM_DELAY
            && uint256(breakerSD) * 1e12 == RobinhoodConfig.QUEUE_BREAKER;
    }

    /// @notice File B1, SET_BRIDGE (see the contract note): only with LAUNCH_WAVE5_RECHECK=clean.
    function setBridge() external {
        require(
            keccak256(bytes(vm.envOr("LAUNCH_WAVE5_RECHECK", string("")))) == keccak256("clean"),
            "SET_BRIDGE is one-time: set LAUNCH_WAVE5_RECHECK=clean only once the wave-5 re-check of the bridge is clean"
        );
        (Deployed memory d, string memory dir) = _start();
        if (d.usd.bridge() != address(0)) return console2.log("file B1 not written: imdUSD's bridge is already set", d.usd.bridge());
        if (_held(d, _bit(d.params.SET_BRIDGE()) | _bit(d.params.BATCH()))) {
            return console2.log("file B1 not written: a proposal on chain holds SET_BRIDGE");
        }
        uint256 at = vm.getBlockTimestamp();
        Tx[] memory t = new Tx[](1);
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.SET_BRIDGE(), address(d.bridge))));
        _exec(config().governor, t);
        _applyAfterTimelock(d, d.params.SET_BRIDGE());
        require(d.usd.bridge() == address(d.bridge) && d.usd.isMinter(address(d.bridge)), "simulated: SET_BRIDGE");
        _write(
            dir,
            1,
            at,
            string.concat("ONE-TIME, FINAL: imdUSD bridge = ", vm.toString(address(d.bridge))),
            string.concat(
                "Parameters.propose(SET_BRIDGE, ImdBridge ", vm.toString(address(d.bridge)),
                "). ImdUSD.setBridge works once: this bridge becomes imdUSD's minter for good (pausable, never replaceable). ",
                "Written only after the wave-5 audit re-check was declared clean. Anyone calls Parameters.applyPending() 48 h after it executes."
            ),
            config().governor,
            t
        );
    }

    /// @dev 48 h later anyone applies; one second earlier is refused first.
    function _applyBridge(ImdBridge b) internal {
        uint256 eta = b.pendingEta();
        vm.warp(eta - 1);
        (bool early,) = address(b).call(abi.encodeWithSignature("applyPending()"));
        require(!early, "simulated: bridge applied before the timelock");
        vm.warp(eta);
        vm.prank(address(0xdead));
        b.applyPending();
    }
}

/// @dev Mainnet's side (the beta record + `launch.sh bridge`): its path to 4663.
contract BridgeBatchBeta is BridgeBatch, BetaEntry {
    function _remoteEid() internal pure override returns (uint32) {
        return RobinhoodConfig.EID;
    }

    function _pathBatch(bytes32 peer) internal pure override returns (bytes memory) {
        return RobinhoodConfig.launchBatchMainnet(RobinhoodConfig.robinhoodPathOnMainnet(peer));
    }
}

/// @dev 4663's side: its path to mainnet.
contract BridgeBatchRobinhood is BridgeBatch, RobinhoodEntry {
    function _remoteEid() internal pure override returns (uint32) {
        return RobinhoodConfig.MAINNET_EID;
    }

    function _pathBatch(bytes32 peer) internal pure override returns (bytes memory) {
        return RobinhoodConfig.launchBatch4663(RobinhoodConfig.mainnetPath(peer));
    }
}
