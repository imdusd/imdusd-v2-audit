// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";

struct Uln {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

struct SetDefaultUlnConfigParam {
    uint32 eid;
    Uln config;
}

interface IReceiveUln302 {
    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external;
    function commitVerification(bytes calldata packetHeader, bytes32 payloadHash) external;
    function getUlnConfig(address oapp, uint32 remoteEid) external view returns (Uln memory);
    function setDefaultUlnConfigs(SetDefaultUlnConfigParam[] calldata params) external;
    function owner() external view returns (address);
}

interface IEndpointFull {
    function getReceiveLibrary(address receiver, uint32 eid) external view returns (address lib, bool isDefault);
    function isValidReceiveLibrary(address receiver, uint32 eid, address lib) external view returns (bool);
    function setReceiveLibrary(address oapp, uint32 eid, address lib, uint256 grace) external;
    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external;
    function verifiable(Origin calldata origin, address receiver) external view returns (bool);
    function inboundPayloadHash(address receiver, uint32 srcEid, bytes32 sender, uint64 nonce) external view returns (bytes32);
    function lazyInboundNonce(address receiver, uint32 srcEid, bytes32 sender) external view returns (uint64);
    function lzReceive(Origin calldata origin, address receiver, bytes32 guid, bytes calldata message, bytes calldata extra)
        external
        payable;
    function inboundNonce(address receiver, uint32 srcEid, bytes32 sender) external view returns (uint64);
    function nilify(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash) external;
}

interface IReceiveUlnLookup {
    function hashLookup(bytes32 headerHash, bytes32 payloadHash, address dvn) external view returns (bool submitted, uint64 conf);
}

contract ForkTok {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external returns (bool) {
        balanceOf[to] += a;
        totalSupply += a;
        return true;
    }

    function burn(address from, uint256 a) external returns (bool) {
        balanceOf[from] -= a;
        totalSupply -= a;
        return true;
    }
}

/// @dev For the real-ImdUSD gas measure (fixed before audit wave 5): the governor and Treasury views ImdUSD.checkBridge reads, and the
/// one-time SET_BRIDGE call (Parameters' role) on a token wired on the fork.
contract ForkSetter {
    address public governor;
    address public treasury;

    constructor(address g, address t) {
        (governor, treasury) = (g, t);
    }

    function setBridge(ImdUSD u, address b) external {
        u.setBridge(b);
    }

    function mint(ImdUSD u, address to, uint256 a) external {
        u.mint(to, a);
    }
}

/// @notice Wave 4 bridge claims (audit 34e546c2) on the REAL LayerZero EndpointV2 and ReceiveUln302 of a mainnet fork, not
/// the mock: P2-P4, P6, C1, C3, C6, C7. An ImdBridge is deployed on the fork as Ethereum's side of the 4663 path (eid
/// 30416); "compromised DVNs" are three addresses this OApp's own config names (verify is called as them), the LayerZero
/// default DVN is the library's real default for 30416. Each test asserts the PROPERTY, so it fails on 67eadea.
/// Needs MAINNET_RPC_URL (archive).
contract AuditW4BridgeEndpointForkTest is Test {
    IEndpointFull constant EP = IEndpointFull(0x1a44076050125825900e736c501f859c50fE728c);
    address constant SEND_ULN = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    IReceiveUln302 constant RECV_ULN = IReceiveUln302(0xc02Ab410f0734EFa3F14628780e6e695156024C2);
    address constant BLOCKED_LIB = 0x1ccBf0db9C192d969de57E25B3fF09A25bb1D862; // LayerZero's registered BlockedMessageLib
    address constant EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    uint32 constant RH = 30416;
    uint32 constant LOCAL = 30101;
    uint256 constant FORK_BLOCK = 26_418_627;
    uint256 constant L = 10_000e18;

    address safe = makeAddr("safe");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    bytes32 peer = bytes32(uint256(uint160(makeAddr("rh bridge"))));
    ForkTok tok;
    ImdBridge bridge;
    uint64 guidSeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
        tok = new ForkTok();
        bridge = new ImdBridge(
            ILayerZeroEndpointV2(address(EP)), IMintableBurnable(address(tok)), safe, makeAddr("treasury")
        );
    }

    // ---------------------------------------------------------------- helpers

    function _dvns(uint160 base) internal pure returns (address[] memory d) {
        d = new address[](3);
        (d[0], d[1], d[2]) = (address(base + 1), address(base + 2), address(base + 3));
    }

    /// @dev 20 confirmations: the floor for packets FROM 4663 (and above Ethereum's 15 for the send side).
    function _uln(uint160 base, uint8 optCount) internal pure returns (bytes memory) {
        return abi.encode(Uln(20, 3, optCount, 0, _dvns(base), new address[](0)));
    }

    function _recvCfg(address lib, uint160 base, uint8 optCount) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(RH, 2, _uln(base, optCount));
        return abi.encode(uint8(2), lib, p);
    }

    function _sendCfg(uint8 optCount) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](2);
        p[0] = SetConfigParam(RH, 1, abi.encode(uint32(10_000), EXECUTOR));
        p[1] = SetConfigParam(RH, 2, _uln(0xD000, optCount));
        return abi.encode(uint8(2), SEND_ULN, p);
    }

    function _path(uint256 inLimit) internal view returns (bytes memory) {
        return abi.encode(uint8(1), RH, peer, L, uint256(1 days), inLimit, uint256(1 days), bytes(""));
    }

    function _batch(bytes[] memory items) internal pure returns (bytes memory) {
        return abi.encode(uint8(6), items);
    }

    /// @dev Propose; true if accepted. An accepted proposal must also apply (asserted): "accepted => applies".
    function _tryGovern(bytes memory payload) internal returns (bool accepted) {
        vm.prank(safe);
        try bridge.propose(payload) {
            accepted = true;
        } catch {
            return false;
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        try bridge.applyPending() {}
        catch (bytes memory err) {
            console2.logBytes(err);
            assertTrue(false, "an accepted proposal reverted at application");
        }
    }

    function _govern(bytes memory payload) internal {
        assertTrue(_tryGovern(payload), "proposal refused");
    }

    /// @dev Ethereum's launch BATCH for the 4663 path: path, both pins, executor + DVN configs (optional NIL).
    function _launch() internal {
        bytes[] memory items = new bytes[](5);
        items[0] = _path(L);
        items[1] = abi.encode(uint8(3), RH, SEND_ULN);
        items[2] = abi.encode(uint8(4), RH, address(RECV_ULN), uint256(0));
        // optionalDVNCount NIL; W4_OPT=0 reproduces on 67eadea, which refuses NIL
        uint8 opt = uint8(vm.envOr("W4_OPT", uint256(255)));
        items[3] = _sendCfg(opt);
        items[4] = _recvCfg(address(RECV_ULN), 0xC000, opt);
        _govern(_batch(items));
    }

    function _header(uint64 n) internal view returns (bytes memory) {
        return abi.encodePacked(uint8(1), n, RH, peer, LOCAL, bytes32(uint256(uint160(address(bridge)))));
    }

    function _message(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(to))), uint64(amount / 1e12));
    }

    struct Pkt {
        uint64 nonce;
        bytes32 guid;
        bytes message;
        bytes32 hash;
    }

    function _pkt(uint64 n, address to, uint256 amount) internal returns (Pkt memory p) {
        p.nonce = n;
        p.guid = keccak256(abi.encode("guid", ++guidSeed));
        p.message = _message(to, amount);
        p.hash = keccak256(abi.encodePacked(p.guid, p.message));
    }

    /// @dev `dvns` sign the packet on ReceiveUln302 and anyone commits it to the endpoint (reverts if not verifiable).
    function _verify(Pkt memory p, address[] memory dvns, uint64 conf) internal {
        for (uint256 i; i < dvns.length; ++i) {
            vm.prank(dvns[i]);
            RECV_ULN.verify(_header(p.nonce), p.hash, conf);
        }
        RECV_ULN.commitVerification(_header(p.nonce), p.hash);
    }

    function _exec(Pkt memory p) internal returns (bool ok) {
        try EP.lzReceive(Origin(RH, peer, p.nonce), address(bridge), p.guid, p.message, "") {
            ok = true;
        } catch {}
    }

    function _stored(uint64 n) internal view returns (bytes32) {
        return EP.inboundPayloadHash(address(bridge), RH, peer, n);
    }

    // ---------------------------------------------------------------- P6 / C3 / C7: pins + this OApp's own config

    /// HIGH 1 on the real endpoint: a SET_PATH alone, if accepted, leaves the path on ReceiveUln302's DEFAULT config for
    /// 30416, and its one default DVN mints. Property: refused, or nothing mints.
    function test_fork_P6_pathAloneCannotMintThroughTheDefaultDvn() public {
        Uln memory d = RECV_ULN.getUlnConfig(address(bridge), RH);
        console2.log("default required DVNs / confirmations for an unconfigured OApp:", d.requiredDVNCount, d.confirmations);
        assertLt(d.requiredDVNCount, 3, "fork premise: the default is below the floor");
        if (!_tryGovern(_path(L))) return; // P6 holds: refused
        Pkt memory p = _pkt(1, attacker, 9_000e18);
        _verify(p, d.requiredDVNs, d.confirmations);
        _exec(p);
        assertEq(tok.balanceOf(attacker), 0, "minted through LayerZero's default 1-of-1 DVN");
    }

    /// Bare pins, and a path + pins without configs: refused (P6/C7).
    function test_fork_P6_pinsWithoutConfigRefused() public {
        assertFalse(_tryGovern(abi.encode(uint8(4), RH, address(RECV_ULN), uint256(0))), "bare receive pin accepted");
        assertFalse(_tryGovern(abi.encode(uint8(3), RH, SEND_ULN)), "bare send pin accepted");
        bytes[] memory items = new bytes[](3);
        items[0] = _path(L);
        items[1] = abi.encode(uint8(3), RH, SEND_ULN);
        items[2] = abi.encode(uint8(4), RH, address(RECV_ULN), uint256(0));
        assertFalse(_tryGovern(_batch(items)), "path + pins without configs accepted");
    }

    /// The launch BATCH lands on the pinned libraries with this OApp's own config; the default DVN cannot commit (C3).
    function test_fork_C3_launchBatchUsesOwnConfigOnly() public {
        _launch();
        (address lib, bool isDefault) = EP.getReceiveLibrary(address(bridge), RH);
        assertEq(lib, address(RECV_ULN));
        assertFalse(isDefault, "pinned, not following LayerZero's default");
        Uln memory u = RECV_ULN.getUlnConfig(address(bridge), RH);
        assertEq(u.requiredDVNCount, 3);
        assertEq(u.confirmations, 20);
        assertEq(u.optionalDVNCount, 0);
        address dvn = RECV_ULN.getUlnConfig(address(0xdead), RH).requiredDVNs[0];
        Pkt memory p = _pkt(1, attacker, 1_000e18);
        vm.prank(dvn);
        RECV_ULN.verify(_header(1), p.hash, 100);
        vm.expectRevert();
        RECV_ULN.commitVerification(_header(1), p.hash);
    }

    /// EndpointV2's grace: the OLD receive library stays valid for this OApp until block + grace (why UNPAUSE waits it out).
    function test_fork_C7_graceKeepsTheOldLibraryValid() public {
        _launch();
        // the bridge refuses an unbounded grace (and a library it cannot configure) at proposal
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(uint8(4), RH, BLOCKED_LIB, uint256(1) << 200);
        items[1] = _recvCfg(BLOCKED_LIB, 0xC000, 255);
        assertFalse(_tryGovern(_batch(items)), "unbounded grace accepted");
        // EndpointV2 itself (as the OApp): the old library stays valid until block + grace
        vm.prank(address(bridge));
        EP.setReceiveLibrary(address(bridge), RH, BLOCKED_LIB, 100);
        assertTrue(EP.isValidReceiveLibrary(address(bridge), RH, address(RECV_ULN)), "old library valid in grace");
        vm.roll(block.number + 101);
        assertFalse(EP.isValidReceiveLibrary(address(bridge), RH, address(RECV_ULN)));
    }

    // ---------------------------------------------------------------- P2 / P4: zero amounts and nonces

    /// HIGH 2: an executed forged nonce is lost to the honest packet for good (the endpoint semantics behind the finding).
    function test_fork_P4_executedNonceIsUnverifiableForever() public {
        _launch();
        Pkt memory f = _pkt(1, attacker, 100e18);
        _verify(f, _dvns(0xC000), 20);
        assertTrue(_exec(f));
        Pkt memory h = _pkt(1, alice, 100e18);
        assertFalse(EP.verifiable(Origin(RH, peer, 1), address(bridge)), "executed nonce verifiable again");
        for (uint256 i; i < 3; ++i) {
            vm.prank(_dvns(0xC000)[i]);
            RECV_ULN.verify(_header(1), h.hash, 20);
        }
        vm.expectRevert();
        RECV_ULN.commitVerification(_header(1), h.hash);
    }

    /// HIGH 2 property: a zero-amount forged packet does not execute, so its nonce stays for the honest packet.
    function test_fork_P4_zeroAmountForgeryLeavesTheNonceToTheHonestPacket() public {
        _launch();
        Pkt memory f = _pkt(1, attacker, 0);
        _verify(f, _dvns(0xC000), 20);
        assertFalse(_exec(f), "zero-amount forged packet executed");
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20); // the honest DVNs verify over it
        assertTrue(_exec(h));
        assertEq(tok.balanceOf(alice), 100e18);
    }

    /// A forged verify OVERWRITES a waiting honest payload at the same nonce (residual of a DVN compromise).
    function test_fork_P4_forgedVerifyOverwritesAWaitingHonestPayload() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        Pkt memory f = _pkt(1, attacker, 1_000e18);
        _verify(f, _dvns(0xC000), 20);
        assertEq(_stored(1), f.hash);
        assertFalse(_exec(h));
    }

    /// Gas (stub token): lzReceive (endpoint + bridge) stays under the enforced-options gas (RobinhoodConfig.LZ_RECEIVE_GAS).
    function test_fork_lzReceiveGasUnderTheEnforcedOption() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        uint256 g = gasleft();
        assertTrue(_exec(h));
        g -= gasleft();
        console2.log("endpoint.lzReceive gas (cold):", g);
        assertLt(g, RobinhoodConfig.LZ_RECEIVE_GAS);
    }

    // ---------------------------------------------------------------- P2 / C1 / C6: voids, the Kelp sequence (no guardian)

    /// MEDIUM: pause, void, the compromised DVNs verify it again, the Safe fixes the DVNs then unpauses: the forged payload
    /// must still never execute (P2, C1). The Safe's void leaves the endpoint as it was.
    function test_fork_C1_voidedForgedPayloadNeverExecutes() public {
        _launch();
        Pkt memory f = _pkt(1, attacker, 5_000e18);
        _verify(f, _dvns(0xC000), 20);
        vm.startPrank(safe);
        bridge.pause(RH);
        bridge.voidPayload(f.hash);
        vm.stopPrank();
        assertEq(_stored(1), f.hash, "the endpoint is untouched");
        _verify(f, _dvns(0xC000), 20); // compromised DVNs sign again (verify over a stored hash is allowed)
        _govern(_recvCfg(address(RECV_ULN), 0xE000, uint8(vm.envOr("W4_OPT", uint256(255))))); // new DVN set
        _govern(abi.encode(uint8(5), RH));
        assertFalse(_exec(f), "voided forged payload executed after unpause");
        assertEq(tok.balanceOf(attacker), 0);
    }

    /// C6: an honest payload voided by mistake runs once the timelock un-voids it, on the proof the endpoint kept: NO DVN
    /// signs again (contrast test_fork_FACT_nilifyNeedsEveryDvnAgain).
    function test_fork_C6_honestVoidedComesBackThroughTheTimelockWithoutTheDvns() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.voidPayload(h.hash);
        assertFalse(_exec(h), "voided payload executed without the timelock");
        _govern(abi.encode(uint8(11), h.hash));
        assertTrue(_exec(h));
        assertEq(tok.balanceOf(alice), 100e18);
    }

    // ---------------------------------------------------------------- endpoint facts the hold relies on

    /// FACT 1: a reverting lzReceive leaves the packet verified at EndpointV2 (hash stored, lazy nonce unmoved), and anyone
    /// can retry it later with no DVN action.
    function test_fork_FACT_revertLeavesThePacketVerifiedAndRetryable() public {
        _launch();
        Pkt memory p = _pkt(1, alice, 100e18);
        _verify(p, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.pause(RH); // any revert in lzReceive
        assertFalse(_exec(p));
        assertEq(_stored(1), p.hash, "hash kept after the revert");
        assertEq(EP.lazyInboundNonce(address(bridge), RH, peer), 0, "lazy nonce not moved by the revert");
        _govern(abi.encode(uint8(5), RH));
        vm.warp(vm.getBlockTimestamp() + 1 days); // audit wave 5: a reopened path's instant allowance refills over a day
        vm.prank(makeAddr("anyone"));
        EP.lzReceive(Origin(RH, peer, 1), address(bridge), p.guid, p.message, "");
        assertEq(tok.balanceOf(alice), 100e18);
    }

    /// FACT 2 (lazy nonces): a verified nonce that reverts does not block the nonces after it, and still runs later from
    /// below lazyInboundNonce.
    function test_fork_FACT_aRevertingNonceDoesNotBlockLaterNonces() public {
        _launch();
        Pkt memory p1 = _pkt(1, alice, 100e18);
        Pkt memory p2 = _pkt(2, alice, 200e18);
        _verify(p1, _dvns(0xC000), 20);
        _verify(p2, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.hold(RH, 1);
        assertFalse(_exec(p1));
        assertTrue(_exec(p2), "nonce 2 blocked by a held nonce 1");
        assertEq(EP.lazyInboundNonce(address(bridge), RH, peer), 2);
        assertEq(_stored(1), p1.hash, "nonce 1 still stored below lazy");
        vm.warp(vm.getBlockTimestamp() + bridge.HOLD_TIME());
        assertTrue(_exec(p1), "the held nonce below lazy did not run");
        assertEq(tok.balanceOf(alice), 300e18);
    }

    /// FACT 3: what nilify does to the DVN proofs. ReceiveUln302 deletes every DVN's record when the packet is COMMITTED, so
    /// after an endpoint nilify the packet can be committed again only once every required DVN signs again. (The hold never
    /// calls nilify, so it never needs this.)
    function test_fork_FACT_nilifyNeedsEveryDvnAgain() public {
        _launch();
        Pkt memory p = _pkt(1, alice, 100e18);
        _verify(p, _dvns(0xC000), 20);
        bytes32 headerHash = keccak256(_header(1));
        for (uint256 i; i < 3; ++i) {
            (bool submitted,) = IReceiveUlnLookup(address(RECV_ULN)).hashLookup(headerHash, p.hash, _dvns(0xC000)[i]);
            assertFalse(submitted, "DVN record kept after the commit");
        }
        vm.prank(address(bridge)); // the OApp itself (what ENDPOINT_NILIFY does after 48h)
        EP.nilify(address(bridge), RH, peer, 1, p.hash);
        assertEq(_stored(1), bytes32(type(uint256).max), "NIL stored");
        assertTrue(EP.verifiable(Origin(RH, peer, 1), address(bridge)), "NIL stays verifiable");
        vm.expectRevert(); // nobody's proof is left
        RECV_ULN.commitVerification(_header(1), p.hash);
        // two of three DVNs are not enough either
        for (uint256 i; i < 2; ++i) {
            vm.prank(_dvns(0xC000)[i]);
            RECV_ULN.verify(_header(1), p.hash, 20);
        }
        vm.expectRevert();
        RECV_ULN.commitVerification(_header(1), p.hash);
        vm.prank(_dvns(0xC000)[2]);
        RECV_ULN.verify(_header(1), p.hash, 20);
        RECV_ULN.commitVerification(_header(1), p.hash);
        assertTrue(_exec(p), "runs once every required DVN signed again");
    }

    // ---------------------------------------------------------------- H1 / H2 on the real endpoint

    /// H2: an honest message held by mistake runs after HOLD_TIME for anyone, with no DVN and no governance act.
    function test_fork_H2_heldHonestRunsAfterHoldTimeForAnyone() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.hold(RH, 1);
        vm.warp(vm.getBlockTimestamp() + bridge.HOLD_TIME() - 1);
        assertFalse(_exec(h), "ran inside the hold");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(makeAddr("stranger"));
        EP.lzReceive(Origin(RH, peer, 1), address(bridge), h.guid, h.message, "");
        assertEq(tok.balanceOf(alice), 100e18);
    }

    /// H1: a held forgery that the Safe voids never runs, after the hold or after the DVNs re-verify; a forged re-verify
    /// OVER a held honest payload never runs by itself, and the honest one runs once verified back.
    function test_fork_H1_heldForgeryVoidedNeverRuns() public {
        _launch();
        Pkt memory f = _pkt(1, attacker, 5_000e18);
        _verify(f, _dvns(0xC000), 20);
        vm.startPrank(safe);
        bridge.hold(RH, 1);
        assertFalse(_exec(f));
        bridge.voidPayload(f.hash);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertFalse(_exec(f), "voided forgery ran after the hold");
        _verify(f, _dvns(0xC000), 20);
        assertFalse(_exec(f), "voided forgery ran after re-verification");
        assertEq(tok.balanceOf(attacker), 0);
    }

    function test_fork_H1_overwriteDuringAHoldNeverAutoReleases() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.hold(RH, 1);
        Pkt memory f = _pkt(1, attacker, 5_000e18);
        _verify(f, _dvns(0xC000), 20); // compromised DVNs overwrite the waiting honest payload
        assertEq(_stored(1), f.hash);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertFalse(_exec(f), "overwriting forgery ran after the hold");
        _verify(h, _dvns(0xC000), 20); // honest DVNs restore it
        assertTrue(_exec(h));
        assertEq(tok.balanceOf(alice), 100e18);
        assertEq(tok.balanceOf(attacker), 0);
    }

    /// Gas with a hold record read (stub token): lzReceive still under the enforced option after an expired hold.
    function test_fork_lzReceiveGasAfterAnExpiredHold() public {
        _launch();
        Pkt memory h = _pkt(1, alice, 100e18);
        _verify(h, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.hold(RH, 1);
        vm.warp(vm.getBlockTimestamp() + bridge.HOLD_TIME());
        uint256 g = gasleft();
        assertTrue(_exec(h));
        g -= gasleft();
        console2.log("endpoint.lzReceive gas after an expired hold:", g);
        assertLt(g, RobinhoodConfig.LZ_RECEIVE_GAS);
    }

    // ---------------------------------------------------------------- fixed before audit wave 5: the REAL ImdUSD

    /// @dev Replace the stub: a real ImdUSD wired on the fork (ledger, migrator and Parameters stood in by ForkSetter, which
    /// reports the Safe and the Treasury ImdUSD.checkBridge compares), and an ImdBridge set as its minter.
    function _realToken(uint256 preSupply) internal returns (ImdUSD u) {
        address tr = makeAddr("treasury");
        ForkSetter fs = new ForkSetter(safe, tr);
        u = new ImdUSD(address(this), 0);
        u.wire(address(fs), address(fs), address(fs));
        bridge = new ImdBridge(ILayerZeroEndpointV2(address(EP)), IMintableBurnable(address(u)), safe, tr);
        fs.setBridge(u, address(bridge));
        if (preSupply != 0) fs.mint(u, makeAddr("holder"), preSupply); // an existing supply and fee-base bucket
    }

    struct Diff {
        uint256 created;
        uint256 updated;
    }

    /// @dev Unique storage slots the call wrote: created (zero -> nonzero) and updated (nonzero -> other), by first write.
    function _count(Vm.AccountAccess[] memory acc) internal pure returns (Diff memory d) {
        address[64] memory a;
        bytes32[64] memory k;
        uint256 n;
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory x = acc[i].storageAccesses[j];
                if (!x.isWrite || x.reverted) continue;
                bool seen;
                for (uint256 m; m < n && !seen; ++m) seen = a[m] == x.account && k[m] == x.slot;
                if (seen) continue;
                (a[n], k[n]) = (x.account, x.slot);
                ++n;
                if (x.previousValue == x.newValue) continue;
                if (x.previousValue == bytes32(0)) ++d.created;
                else ++d.updated;
            }
        }
    }

    /// @dev Glamsterdam (EIP-8037/8038 as published 2026-11-06, not final): a new slot 22,100 -> 110,020 and an update
    /// 5,000 -> 12,100 (cold included), so each costs +87,920 / +7,100 on today's measured gas. Refunds ignored.
    function _glamsterdam(uint256 g, Diff memory d) internal pure returns (uint256) {
        return g + d.created * 87_920 + d.updated * 7_100;
    }

    function _measure(string memory what, uint256 preSupply, bool hold, uint256 sinceBucket, bool steady)
        internal
        returns (uint256 g, uint256 glam)
    {
        ImdUSD u = _realToken(preSupply);
        _launch();
        uint64 n = 1;
        if (steady) {
            // the path has delivered before (its nonce, limiter and `received` slots exist): the common case
            Pkt memory first = _pkt(1, alice, 100e18);
            _verify(first, _dvns(0xC000), 20);
            assertTrue(_exec(first));
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            n = 2;
        }
        Pkt memory h = _pkt(n, makeAddr(what), 100e18); // a holder that never held imdUSD
        _verify(h, _dvns(0xC000), 20);
        if (hold) {
            vm.prank(safe);
            bridge.hold(RH, n);
            vm.warp(vm.getBlockTimestamp() + bridge.HOLD_TIME());
        }
        vm.warp(vm.getBlockTimestamp() + sinceBucket); // past the fee base's bucket: the low-water slot rolls
        vm.startStateDiffRecording();
        g = gasleft();
        assertTrue(_exec(h), "lzReceive with the real ImdUSD");
        g -= gasleft();
        Diff memory d = _count(vm.stopAndReturnStateDiff());
        assertEq(u.balanceOf(makeAddr(what)), 100e18);
        glam = _glamsterdam(g, d);
        console2.log(what);
        console2.log("  gas today / slots created / updated:", g, d.created, d.updated);
        console2.log("  at Glamsterdam storage prices (estimate):", glam);
    }

    /// FIXED BEFORE AUDIT WAVE 5 (C4): lzReceive on the REAL EndpointV2 with the REAL ImdUSD (fee-base low-water slot,
    /// transient supply mark), the worst paths: the token's first mint ever; a new holder after an expired hold with the
    /// fee-base bucket rolled. Property: the enforced lzReceive gas (RobinhoodConfig.LZ_RECEIVE_GAS, 250,000) covers each,
    /// today AND at Glamsterdam's storage prices (a shortfall only delays: anyone retries with more gas, the message stays).
    function test_fork_lzReceiveGasRealImdUsd() public {
        uint256 snap = vm.snapshotState();
        uint256[2][4] memory r;
        (r[0][0], r[0][1]) = _measure("first message of the path, token's first mint ever", 0, false, 0, false);
        vm.revertToState(snap);
        (r[1][0], r[1][1]) = _measure("first message, new holder, expired hold, new bucket", 1_000_000e18, true, 2 hours, false);
        vm.revertToState(snap);
        (r[2][0], r[2][1]) = _measure("steady path, new holder, same bucket", 1_000_000e18, false, 0, true);
        vm.revertToState(snap);
        (r[3][0], r[3][1]) = _measure("steady path, new holder, expired hold, new bucket", 1_000_000e18, true, 2 hours, true);
        uint256 g;
        uint256 x;
        for (uint256 i; i < 4; ++i) {
            if (r[i][0] > g) g = r[i][0];
            if (r[i][1] > x) x = r[i][1];
        }
        console2.log("worst today / at Glamsterdam (estimate) / enforced:", g, x, uint256(RobinhoodConfig.LZ_RECEIVE_GAS));
        // TODAY the enforced gas covers every path. AT GLAMSTERDAM it does not (the enforced
        // option must be raised by SET_PATH before the fork; a shortfall only delays, the message stays retryable).
        assertLt(g, RobinhoodConfig.LZ_RECEIVE_GAS, "today");
    }

    // ---------------------------------------------------------------- endpoint acts (burn / skip), same pin

    /// LOW: BURN / SKIP of the head nonce of a paused path cannot apply on EndpointV2; the bridge must not accept them.
    function test_fork_P3_infeasibleEndpointActsRefused() public {
        _launch();
        Pkt memory f = _pkt(1, attacker, 20_000e18); // over the limit: waits at the head
        _verify(f, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.pause(RH);
        assertFalse(_tryGovern(abi.encode(uint8(10), RH, peer, uint64(1), f.hash)), "head-nonce burn accepted");
        assertFalse(_tryGovern(abi.encode(uint8(8), RH, peer, uint64(1))), "skip of a verified nonce accepted");
    }

    /// The durable endpoint clean-up: a nilified nonce (timelocked ENDPOINT_NILIFY) passed by a later one is burned, path open.
    function test_fork_P2_burnANilifiedNonceBelowLazy() public {
        _launch();
        Pkt memory f1 = _pkt(1, attacker, 20_000e18);
        _verify(f1, _dvns(0xC000), 20);
        vm.prank(safe);
        bridge.pause(RH);
        _govern(abi.encode(uint8(9), RH, peer, uint64(1), f1.hash));
        _govern(abi.encode(uint8(5), RH));
        Pkt memory f2 = _pkt(2, attacker, 100e18);
        _verify(f2, _dvns(0xC000), 20);
        assertTrue(_exec(f2));
        assertEq(EP.lazyInboundNonce(address(bridge), RH, peer), 2);
        _govern(abi.encode(uint8(10), RH, peer, uint64(1), bytes32(type(uint256).max)));
        assertEq(_stored(1), bytes32(0));
        assertFalse(EP.verifiable(Origin(RH, peer, 1), address(bridge)), "burned nonce verifiable");
    }

    /// LOW: re-pinning the current library: EndpointV2 reverts LZ_SameValue, so the bridge must refuse it at proposal.
    function test_fork_samePinAcceptedImpliesApplied() public {
        _launch();
        _tryGovern(abi.encode(uint8(3), RH, SEND_ULN)); // asserts "accepted => applies"
    }

    // ---------------------------------------------------------------- optional DVNs: NIL vs default

    /// LOW: ULN302 merges the library's default optional DVNs into a config whose optionalDVNCount is 0 (endpoint semantics,
    /// set here directly as the OApp), but not into one with NIL.
    function test_fork_optionalZeroInheritsTheDefaultNilDoesNot() public {
        address oappA = makeAddr("oapp zero");
        address oappB = makeAddr("oapp nil");
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(RH, 2, _uln(0xC000, 0));
        vm.prank(oappA);
        EP.setConfig(oappA, address(RECV_ULN), p);
        p[0] = SetConfigParam(RH, 2, _uln(0xC000, 255));
        vm.prank(oappB);
        EP.setConfig(oappB, address(RECV_ULN), p);
        _moveDefaultOptional();
        assertEq(RECV_ULN.getUlnConfig(oappA, RH).optionalDVNCount, 1, "count 0 merged the default optional DVN");
        assertEq(RECV_ULN.getUlnConfig(oappB, RH).optionalDVNCount, 0, "NIL kept none");
    }

    /// The bridge's own config after a LayerZero default-optional move: unchanged (needs NIL accepted, 0 refused).
    function test_fork_bridgeConfigUnchangedByADefaultOptionalMove() public {
        _launch();
        _moveDefaultOptional();
        assertEq(RECV_ULN.getUlnConfig(address(bridge), RH).optionalDVNCount, 0);
        assertFalse(_tryGovern(_recvCfg(address(RECV_ULN), 0xE000, 0)), "optional count 0 (= default) accepted");
    }

    function _moveDefaultOptional() internal {
        Uln memory d = RECV_ULN.getUlnConfig(address(0xdead), RH);
        address[] memory opt = new address[](1);
        opt[0] = address(0xBEEF);
        d.optionalDVNCount = 1;
        d.optionalDVNThreshold = 1;
        d.optionalDVNs = opt;
        SetDefaultUlnConfigParam[] memory q = new SetDefaultUlnConfigParam[](1);
        q[0] = SetDefaultUlnConfigParam(RH, d);
        vm.prank(RECV_ULN.owner());
        RECV_ULN.setDefaultUlnConfigs(q);
    }
}
