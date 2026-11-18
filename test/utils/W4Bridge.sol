// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {MockLzEndpoint, MockMessageLib} from "./MockLzEndpoint.sol";
import {ILayerZeroEndpointV2, MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";

/// @notice A bare mint/burn token for the bridge (ImdUSD's bridge-minter surface only).
contract W4Tok {
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

/// @notice Wave-4 bridge harness (audit 34e546c2): two ImdBridges ("home" = Ethereum's eid, "rh" = 4663's) on two
/// MockLzEndpoints with EndpointV2's channel semantics, no Ledger. `_launch` opens a path the way the deploy config does:
/// SET_PATH + both library pins + a floor-checked ULN config on each pinned library, in one BATCH.
abstract contract W4Bridge is Test {
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    uint32 constant HOME = 30101;
    uint32 constant RH = 30416;
    /// @dev optionalDVNCount the harness writes: NIL = none (0 would merge LayerZero's default optional DVNs: refused).
    /// W4_OPT=0 replays the proofs on 67eadea, which refused NIL.
    uint8 internal OPT_COUNT = uint8(vm.envOr("W4_OPT", uint256(255)));

    address safe = makeAddr("safe");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");

    MockLzEndpoint homeEp;
    MockLzEndpoint rhEp;
    W4Tok homeTok;
    W4Tok rhTok;
    ImdBridge home;
    ImdBridge rh;
    address homeSendLib;
    address homeRecvLib;
    address rhSendLib;
    address rhRecvLib;

    function _setUpW4() internal {
        vm.warp(1_800_000_000);
        homeEp = new MockLzEndpoint(HOME);
        rhEp = new MockLzEndpoint(RH);
        homeEp.link(rhEp);
        rhEp.link(homeEp);
        homeTok = new W4Tok();
        rhTok = new W4Tok();
        home = new ImdBridge(
            ILayerZeroEndpointV2(address(homeEp)), IMintableBurnable(address(homeTok)), safe, makeAddr("homeTreasury")
        );
        rh = new ImdBridge(
            ILayerZeroEndpointV2(address(rhEp)), IMintableBurnable(address(rhTok)), safe, makeAddr("rhTreasury")
        );
        homeSendLib = address(new MockMessageLib());
        homeRecvLib = address(new MockMessageLib());
        rhSendLib = address(new MockMessageLib());
        rhRecvLib = address(new MockMessageLib());
        vm.deal(alice, 100 ether);
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _dvns(uint160 base) internal pure returns (address[] memory d) {
        d = new address[](3);
        (d[0], d[1], d[2]) = (address(base + 1), address(base + 2), address(base + 3));
    }

    /// @dev A ULN config passing every floor (20 confirmations clears both sources' floors).
    function _uln(uint160 dvnBase) internal view returns (bytes memory) {
        return abi.encode(UlnConfig(20, 3, OPT_COUNT, 0, _dvns(dvnBase), new address[](0)));
    }

    function _path(uint32 eid, bytes32 peer, uint256 outLimit, uint256 inLimit) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), eid, peer, outLimit, uint256(1 days), inLimit, uint256(1 days), bytes(""));
    }

    function _pinSend(uint32 eid, address lib) internal pure returns (bytes memory) {
        return abi.encode(uint8(3), eid, lib);
    }

    function _pinRecv(uint32 eid, address lib, uint256 grace) internal pure returns (bytes memory) {
        return abi.encode(uint8(4), eid, lib, grace);
    }

    function _sendCfg(address lib, uint32 eid, uint160 dvnBase) internal view returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](2);
        p[0] = SetConfigParam(eid, 1, abi.encode(uint32(10_000), address(0xE0E0)));
        p[1] = SetConfigParam(eid, 2, _uln(dvnBase));
        return abi.encode(uint8(2), lib, p);
    }

    function _recvCfg(address lib, uint32 eid, uint160 dvnBase) internal view returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(eid, 2, _uln(dvnBase));
        return abi.encode(uint8(2), lib, p);
    }

    function _batch(bytes[] memory items) internal pure returns (bytes memory) {
        return abi.encode(uint8(6), items);
    }

    function _b(bytes memory a, bytes memory b_) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (a, b_);
        return _batch(items);
    }

    function _govern(ImdBridge b, bytes memory payload) internal {
        vm.prank(safe);
        b.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        b.applyPending();
    }

    /// @dev The launch BATCH (the deploy config's shape) for `b`'s path to `remote`.
    function _launchBatch(ImdBridge b, uint32 remote, bytes32 peer, uint256 outLimit, uint256 inLimit)
        internal
        view
        returns (bytes memory)
    {
        (address s, address r) = b == home ? (homeSendLib, homeRecvLib) : (rhSendLib, rhRecvLib);
        bytes[] memory items = new bytes[](5);
        items[0] = _path(remote, peer, outLimit, inLimit);
        items[1] = _pinSend(remote, s);
        items[2] = _pinRecv(remote, r, 0);
        items[3] = _sendCfg(s, remote, 0x1000);
        items[4] = _recvCfg(r, remote, 0x1000);
        return _batch(items);
    }

    /// @dev Both paths open: home -> rh `limit` out / `limit` in, mirrored.
    function _openBoth(uint256 limit) internal {
        _govern(home, _launchBatch(home, RH, _b32(address(rh)), limit, limit));
        _govern(rh, _launchBatch(rh, HOME, _b32(address(home)), limit, limit));
    }

    /// @dev An honest send home -> rh of `amount` from `from` (minted to them first).
    function _send(address from, uint256 amount) internal returns (uint256 i) {
        homeTok.mint(from, amount);
        SendParam memory p = SendParam(RH, _b32(from), amount, 0, "", "", "");
        uint256 fee = homeEp.FEE();
        vm.deal(from, fee);
        vm.prank(from);
        home.send{value: fee}(p, MessagingFee(fee, 0), from);
        i = homeEp.packetCount() - 1;
    }

    function _msg(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(_b32(to), uint64(amount / 1e12));
    }

    /// @dev A forged "home -> rh" packet that a compromised DVN set verified; index on homeEp.
    function _forge(uint256 amount) internal returns (uint256 i) {
        i = homeEp.forge(RH, _b32(address(rh)), _b32(address(home)), _msg(attacker, amount));
    }

    /// @dev The key ImdBridge queues packet `i` of `ep` under at its destination: the LayerZero GUID of its origin.
    function _claimKey(MockLzEndpoint ep, uint256 i) internal view returns (bytes32) {
        (uint32 dst, bytes32 receiver, bytes32 sender, uint64 n,,,,) = ep.packets(i);
        return keccak256(abi.encodePacked(n, ep.eid(), sender, dst, receiver));
    }

    /// @dev Metered on rh for the attacker: minted at once plus waiting in claims (all claims in these harnesses).
    function _admitted() internal view returns (uint256) {
        return rhTok.balanceOf(attacker) + rh.queued();
    }

    function _origin(uint256 i) internal view returns (uint64 n, bytes32 sender) {
        (,, sender, n,,,,) = homeEp.packets(i);
    }
}
