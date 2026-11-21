// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {Uln, IReceiveUln302, IEndpointFull, ForkTok} from "./AuditW4BridgeEndpoint.t.sol";

/// @notice The inbound delay on the REAL LayerZero EndpointV2 + ReceiveUln302 of
/// a mainnet fork (AuditW4BridgeEndpoint.t.sol's set-up, in its own file): an ImdBridge as Ethereum's side of the 4663 path,
/// "compromised DVNs" = the three addresses its own config names. Properties:
///  - a large forged message, verified and run by anyone at once, is QUEUED: its nonce is spent, nothing mints;
///  - the Safe cancels it (instant) and it never mints; a pause stops every claim on the path;
///  - an honest large message is claimable after DELAY by anyone, minted to its recipient;
///  - a forgery split into sub-threshold messages mints at once only the instant allowance;
///  - past QUEUE_BREAKER queued the path trips: no claim runs until the timelocked RESET_BREAKER;
///  - gas: lzReceive on the queue path stays under the enforced 250,000 (DeployConfig LZ_RECEIVE_GAS).
/// Needs MAINNET_RPC_URL (archive).
contract BridgeInboundDelayEndpointForkTest is Test {
    IEndpointFull constant EP = IEndpointFull(0x1a44076050125825900e736c501f859c50fE728c);
    address constant SEND_ULN = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    IReceiveUln302 constant RECV_ULN = IReceiveUln302(0xc02Ab410f0734EFa3F14628780e6e695156024C2);
    address constant EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    uint32 constant RH = 30416;
    uint32 constant LOCAL = 30101;
    uint256 constant FORK_BLOCK = 26_418_627;
    uint256 constant L = 50_000e18; // per path, the launch value
    uint256 constant ENFORCED_GAS = 250_000;

    address safe = makeAddr("safe");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    bytes32 peer = bytes32(uint256(uint160(makeAddr("rh bridge"))));
    ForkTok tok;
    ImdBridge bridge;
    uint256 C; // DELAY_THRESHOLD, read from the bridge
    uint256 big; // above C: always queued

    struct Pkt {
        uint64 nonce;
        bytes32 guid;
        bytes message;
        bytes32 hash;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
        tok = new ForkTok();
        bridge = new ImdBridge(ILayerZeroEndpointV2(address(EP)), IMintableBurnable(address(tok)), safe, makeAddr("treasury"));
        _launch();
        C = bridge.DEFAULT_INSTANT_CAP();
        big = C + 1_000e18;
    }

    // ---------------------------------------------------------------- helpers (AuditW4BridgeEndpoint's)

    function _dvns(uint160 base) internal pure returns (address[] memory d) {
        d = new address[](3);
        (d[0], d[1], d[2]) = (address(base + 1), address(base + 2), address(base + 3));
    }

    function _uln(uint160 base) internal pure returns (bytes memory) {
        return abi.encode(Uln(20, 3, 255, 0, _dvns(base), new address[](0)));
    }

    function _launch() internal {
        bytes[] memory items = new bytes[](5);
        items[0] = abi.encode(uint8(1), RH, peer, L, uint256(1 days), L, uint256(1 days), bytes(""));
        items[1] = abi.encode(uint8(3), RH, SEND_ULN);
        items[2] = abi.encode(uint8(4), RH, address(RECV_ULN), uint256(0));
        SetConfigParam[] memory s = new SetConfigParam[](2);
        s[0] = SetConfigParam(RH, 1, abi.encode(uint32(10_000), EXECUTOR));
        s[1] = SetConfigParam(RH, 2, _uln(0xD000));
        items[3] = abi.encode(uint8(2), SEND_ULN, s);
        SetConfigParam[] memory r = new SetConfigParam[](1);
        r[0] = SetConfigParam(RH, 2, _uln(0xC000));
        items[4] = abi.encode(uint8(2), address(RECV_ULN), r);
        _govern(abi.encode(uint8(6), items));
        // a review before wave 5b: the instant allowance starts EMPTY at the path's opening (token accepted); start from a day later (full)
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function _govern(bytes memory payload) internal {
        vm.prank(safe);
        bridge.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        bridge.applyPending();
    }

    function _header(uint64 n) internal view returns (bytes memory) {
        return abi.encodePacked(uint8(1), n, RH, peer, LOCAL, bytes32(uint256(uint160(address(bridge)))));
    }

    /// @dev The LayerZero GUID of nonce `n` on this path (GUID.generate): an honest packet's guid, and the claim key.
    function _guid(uint64 n) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(n, RH, peer, LOCAL, bytes32(uint256(uint160(address(bridge))))));
    }

    /// @dev `forged`: the packet's guid field is arbitrary (the compromised DVNs sign whatever they are given).
    function _pkt(uint64 n, address to, uint256 amount, bool forged) internal view returns (Pkt memory p) {
        p.nonce = n;
        p.guid = forged ? keccak256(abi.encode("forged", n)) : _guid(n);
        p.message = abi.encodePacked(bytes32(uint256(uint160(to))), uint64(amount / 1e12));
        p.hash = keccak256(abi.encodePacked(p.guid, p.message));
    }

    function _verify(Pkt memory p) internal {
        address[] memory dvns = _dvns(0xC000);
        for (uint256 i; i < dvns.length; ++i) {
            vm.prank(dvns[i]);
            RECV_ULN.verify(_header(p.nonce), p.hash, 20);
        }
        RECV_ULN.commitVerification(_header(p.nonce), p.hash);
    }

    /// @dev EndpointV2.lzReceive by a stranger (permissionless), with the gas the executor would forward.
    function _exec(Pkt memory p) internal returns (bool ok) {
        vm.prank(makeAddr("anyone"));
        try EP.lzReceive(Origin(RH, peer, p.nonce), address(bridge), p.guid, p.message, "") {
            ok = true;
        } catch {}
    }

    function _claim(uint64 n) internal {
        vm.prank(makeAddr("stranger"));
        bridge.claim(RH, _guid(n));
    }

    // ---------------------------------------------------------------- properties

    /// A forged transfer above the cap runs the moment it is verified (anyone runs it), spends its nonce, and mints NOTHING; the Safe cancels
    /// it inside DELAY and it never mints, even a month later.
    function test_fork_largeForgeryQueuesAndTheSafeCancelsIt() public {
        Pkt memory f = _pkt(1, attacker, big, true);
        _verify(f);
        assertTrue(_exec(f), "executes at once, as before the delay");
        assertEq(tok.balanceOf(attacker), 0, "a large forgery is spendable the moment it is verified");
        assertEq(EP.inboundPayloadHash(address(bridge), RH, peer, 1), bytes32(0), "the nonce is spent at the endpoint");
        assertEq(bridge.queued(), big);
        (address to,, uint40 queuedAt, uint8 state) = bridge.claims(RH, _guid(1));
        assertEq(to, attacker);
        assertEq(state, 1);
        assertEq(queuedAt, vm.getBlockTimestamp(), "claimable at queuedAt + the path's delay");
        vm.warp(vm.getBlockTimestamp() + 2 hours); // the watcher saw Queued; the Safe signs
        vm.prank(safe);
        bridge.cancelClaim(RH, _guid(1));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert();
        _claim(1);
        assertEq(tok.balanceOf(attacker), 0);
        assertEq(tok.totalSupply(), 0);
    }

    /// An honest transfer above the cap waits DELAY, then anyone mints it to the recipient.
    function test_fork_honestLargeTransferClaimableByAnyoneAfterDelay() public {
        Pkt memory h = _pkt(1, alice, big, false);
        _verify(h);
        assertTrue(_exec(h));
        assertEq(tok.balanceOf(alice), 0);
        vm.warp(vm.getBlockTimestamp() + bridge.DEFAULT_DELAY() - 1);
        vm.expectRevert();
        _claim(1);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 g = gasleft();
        _claim(1);
        g -= gasleft();
        console2.log("claim gas (stranger, cold-ish):", g);
        assertEq(tok.balanceOf(alice), big);
        assertEq(bridge.received(), big);
        assertEq(bridge.queued(), 0);
    }

    /// One pause stops every claim on the path (forged and honest); after the timelocked UNPAUSE the honest one claims. (An
    /// honest C first uses the instant allowance, so both below queue: all the inbound limit leaves, L - C, under
    /// QUEUE_BREAKER, so the breaker stays open and only the pause stops the claims.)
    function test_fork_pauseStopsEveryClaim() public {
        Pkt memory i = _pkt(1, alice, C, false);
        Pkt memory h = _pkt(2, alice, big, false);
        Pkt memory f = _pkt(3, attacker, L - C - big, true);
        _verify(i);
        _verify(h);
        _verify(f);
        assertTrue(_exec(i));
        assertTrue(_exec(h));
        assertTrue(_exec(f));
        (,, bool tripped,,,,) = bridge.breakers(RH);
        assertFalse(tripped);
        vm.prank(safe);
        bridge.pause(RH);
        vm.warp(vm.getBlockTimestamp() + bridge.DEFAULT_DELAY());
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathPaused.selector, RH));
        _claim(3);
        vm.prank(safe);
        bridge.cancelClaim(RH, _guid(3));
        _govern(abi.encode(uint8(5), RH));
        _claim(2);
        assertEq(tok.balanceOf(alice), C + big);
        vm.expectRevert();
        _claim(3);
    }

    /// The queue breaker: an honest and a forged large transfer queue past QUEUE_BREAKER, so the path
    /// trips in the forger's own lzReceive; with nobody acting, no claim runs, even 30 days on. The Safe cancels the
    /// forgery; RESET_BREAKER (48h, not earlier) releases the trip and the honest claim runs; the forgery stays dead.
    /// QUEUE_BREAKER (50,000) equals the inbound limit L, so the forgery comes as two messages 12 h apart
    /// (half the limit refilled, the same breaker window).
    function test_fork_trippedPathStopsClaimsUntilTimelockedReset() public {
        uint256 rest = bridge.DEFAULT_QUEUE_BREAKER() - 6_000e18 + 1e18; // with h, one unit past the breaker
        uint256 first = rest / 2 / 1e18 * 1e18;
        Pkt memory h = _pkt(1, alice, 6_000e18, false);
        Pkt memory f1 = _pkt(2, attacker, first, true);
        Pkt memory f = _pkt(3, attacker, rest - first, true);
        _verify(h);
        _verify(f1);
        _verify(f);
        assertTrue(_exec(h));
        assertTrue(_exec(f1));
        (,, bool open,,,,) = bridge.breakers(RH);
        assertFalse(open, "under the breaker so far");
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        uint256 g = gasleft();
        assertTrue(_exec(f), "the message still queues: only claims stop");
        g -= gasleft();
        console2.log("endpoint.lzReceive gas, queued and tripping:", g);
        assertLt(g, ENFORCED_GAS);
        (, uint16 trips, bool tripped,,,,) = bridge.breakers(RH);
        assertTrue(tripped);
        assertEq(trips, 1);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.Tripped.selector, RH));
        _claim(1);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.Tripped.selector, RH));
        _claim(2);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.Tripped.selector, RH));
        _claim(3);
        assertEq(tok.totalSupply(), 0, "nothing spendable from the queue while nobody acts");
        vm.prank(safe);
        bridge.cancelClaim(RH, _guid(2));
        vm.prank(safe);
        bridge.cancelClaim(RH, _guid(3));
        // audit wave 5: a reset only on a paused path, reopened in the same BATCH
        vm.prank(safe);
        bridge.pause(RH);
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (abi.encode(uint8(14), RH, uint256(1)), abi.encode(uint8(5), RH));
        vm.prank(safe);
        bridge.propose(abi.encode(uint8(6), items));
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        bridge.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        bridge.applyPending();
        _claim(1);
        assertEq(tok.balanceOf(alice), 6_000e18);
        vm.expectRevert();
        _claim(2);
        vm.expectRevert();
        _claim(3);
        assertEq(tok.balanceOf(attacker), 0);
    }

    /// The split: six forged C / 2s mint at once only the instant allowance C; the rest waits as cancellable claims.
    function test_fork_splitForgeryMintsOnlyTheInstantAllowance() public {
        for (uint64 n = 1; n <= 6; ++n) {
            Pkt memory f = _pkt(n, attacker, C / 2, true);
            _verify(f);
            assertTrue(_exec(f));
        }
        assertEq(tok.balanceOf(attacker), C);
        assertEq(bridge.queued(), 2 * C);
    }

    /// Gas on the real endpoint (cold): the instant path and the queue path both stay under the enforced lzReceive gas.
    function test_fork_lzReceiveGasBothPaths() public {
        Pkt memory a = _pkt(1, alice, 100e18, false);
        Pkt memory b = _pkt(2, alice, big, false);
        _verify(a);
        _verify(b);
        uint256 g = gasleft();
        assertTrue(_exec(a));
        g -= gasleft();
        console2.log("endpoint.lzReceive gas, instant (cold):", g);
        assertLt(g, ENFORCED_GAS);
        g = gasleft();
        assertTrue(_exec(b));
        g -= gasleft();
        console2.log("endpoint.lzReceive gas, queued (cold claim slot):", g);
        assertLt(g, ENFORCED_GAS);
    }
}
