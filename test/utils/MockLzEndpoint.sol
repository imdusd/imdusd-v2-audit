// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MessagingParams, MessagingReceipt, MessagingFee, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {ILayerZeroReceiver} from "layerzero-v2/protocol/interfaces/ILayerZeroReceiver.sol";

/// @notice A LayerZero EndpointV2 stand-in for two chains in one EVM: `send` queues a packet and the (honest) DVNs verify it
/// at the destination at once; `deliver` executes it there as EndpointV2.lzReceive does (permissionless). A reverting
/// delivery leaves the payload stored, retryable.
/// @dev Wave 4 (audit 34e546c2): the INBOUND CHANNEL now follows EndpointV2's MessagingChannel, checked against the real
/// endpoint 0x1a44…728c on a mainnet fork (test/fork/AuditW4BridgeEndpoint.t.sol), where the old mock disagreed:
///  - nonces are per path (sender, dstEid, receiver); executing nonce n needs every nonce in (lazyInboundNonce, n) to hold
///    a payload hash, and moves lazyInboundNonce to n;
///  - `verify` is allowed for any nonce above lazyInboundNonce, or at/below it while a hash is stored, and OVERWRITES the
///    stored hash (so a forged payload can replace a waiting honest one, and an executed nonce can never be verified again);
///  - `nilify` stores NIL (0xff..ff), which stays verifiable: the DVNs (honest or compromised) can verify any payload there
///    again; `burn` needs a stored, non-empty hash at a nonce <= lazyInboundNonce; `skip` only the nonce after
///    `inboundNonce` (the first with no hash);
///  - pinning the library already pinned reverts (LZ_SameValue).
/// Not modelled: DVN signatures and ULN configs (recorded, not enforced), the executor, real fees, receive-library grace.
contract MockLzEndpoint {
    struct Packet {
        uint32 dstEid;
        bytes32 receiver;
        bytes32 sender;
        uint64 nonce;
        bytes32 guid;
        bytes message;
        bytes options;
        bool delivered;
    }

    uint32 public immutable eid;
    uint256 public constant FEE = 0.0001 ether;
    bytes32 public constant NIL_PAYLOAD_HASH = bytes32(type(uint256).max);

    mapping(uint32 eid => MockLzEndpoint) public remotes;
    Packet[] public packets;
    /// @notice The nonce of the last packet queued here (sent or forged).
    uint64 public nonce;
    /// @notice Source side: the last nonce sent on each path, and the last nonce a forger claimed on it.
    mapping(bytes32 sender => mapping(uint32 dstEid => mapping(bytes32 receiver => uint64))) public sentNonce;
    mapping(bytes32 sender => mapping(uint32 dstEid => mapping(bytes32 receiver => uint64))) public forgedNonce;

    // destination side: EndpointV2's MessagingChannel
    mapping(address receiver => mapping(uint32 srcEid => mapping(bytes32 sender => uint64))) public lazyInboundNonce;
    mapping(address receiver => mapping(uint32 srcEid => mapping(bytes32 sender => mapping(uint64 => bytes32)))) public
        inboundPayloadHash;

    // what the OApp configured through `setConfig` & co (recorded, not enforced)
    mapping(address oapp => uint256) public configCalls;
    mapping(address oapp => mapping(uint32 eid => address)) public sendLibrary;
    mapping(address oapp => mapping(uint32 eid => address)) public receiveLibrary;
    mapping(address oapp => mapping(uint32 eid => uint256)) public receiveGrace;

    error InsufficientFee();
    error NotRemote();
    error LZ_InvalidNonce(uint64 nonce);
    error LZ_PayloadHashNotFound(bytes32 expected, bytes32 actual);
    error LZ_SameValue();
    error LZ_InvalidPayloadHash();

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function link(MockLzEndpoint other) external {
        remotes[other.eid()] = other;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(FEE, 0);
    }

    function send(MessagingParams calldata p, address refund) external payable returns (MessagingReceipt memory r) {
        if (msg.value < FEE) revert InsufficientFee();
        bytes32 sender = bytes32(uint256(uint160(msg.sender)));
        uint64 n = ++sentNonce[sender][p.dstEid][p.receiver];
        nonce = n;
        bytes32 guid = keccak256(abi.encodePacked(n, eid, sender, p.dstEid, p.receiver)); // GUID.generate
        packets.push(Packet(p.dstEid, p.receiver, sender, n, guid, p.message, p.options, false));
        // the honest DVNs verify it at the destination (fails if a forged packet already executed at this nonce)
        remotes[p.dstEid].verify(Origin(eid, sender, n), _addr(p.receiver), keccak256(abi.encodePacked(guid, p.message)));
        if (msg.value > FEE) {
            (bool ok,) = refund.call{value: msg.value - FEE}("");
            ok;
        }
        r = MessagingReceipt(guid, n, MessagingFee(FEE, 0));
    }

    /// @notice A packet a compromised DVN set verified: claims to come from `sender` on this endpoint's chain, at the first
    /// nonce above both what the real sender has sent and what was forged before on the path (test stand-in).
    function forge(uint32 dstEid, bytes32 receiver, bytes32 sender, bytes calldata message) external returns (uint256 i) {
        uint64 s = sentNonce[sender][dstEid][receiver];
        uint64 f = forgedNonce[sender][dstEid][receiver];
        i = forgeAt(dstEid, receiver, sender, message, (s > f ? s : f) + 1);
    }

    /// @notice The same at a chosen nonce (e.g. one an honest packet is waiting at: the forged hash overwrites it).
    function forgeAt(uint32 dstEid, bytes32 receiver, bytes32 sender, bytes calldata message, uint64 n)
        public
        returns (uint256 i)
    {
        if (n > forgedNonce[sender][dstEid][receiver]) forgedNonce[sender][dstEid][receiver] = n;
        nonce = n;
        bytes32 guid = keccak256(abi.encodePacked("forged", n, sender, dstEid, receiver, message));
        packets.push(Packet(dstEid, receiver, sender, n, guid, message, "", false));
        i = packets.length - 1;
        remotes[dstEid].verify(Origin(eid, sender, n), _addr(receiver), keccak256(abi.encodePacked(guid, message)));
    }

    /// @notice The DVNs verify packet `i` again (after a nilify, or over a forged overwrite). False if not verifiable.
    function reverify(uint256 i) external returns (bool) {
        Packet storage p = packets[i];
        return remotes[p.dstEid].verify(
            Origin(eid, p.sender, p.nonce), _addr(p.receiver), keccak256(abi.encodePacked(p.guid, p.message))
        );
    }

    /// @notice Execute packet `i` at its destination (EndpointV2.lzReceive, permissionless). False (state unchanged) if the
    /// receiver reverted or the channel refused it.
    function deliver(uint256 i) external returns (bool ok) {
        Packet storage p = packets[i];
        if (p.delivered) return true;
        try remotes[p.dstEid].lzReceive(Origin(eid, p.sender, p.nonce), _addr(p.receiver), p.guid, p.message, "") {
            p.delivered = true;
            ok = true;
        } catch {}
    }

    function payloadHashOf(uint256 i) external view returns (bytes32) {
        return keccak256(abi.encodePacked(packets[i].guid, packets[i].message));
    }

    function originOf(uint256 i) external view returns (Origin memory) {
        return Origin(eid, packets[i].sender, packets[i].nonce);
    }

    // ---------------------------------------------------------------- destination: EndpointV2 + MessagingChannel

    /// @notice A receive library's commit (EndpointV2.verify), for DVN stand-ins: false where the real one reverts.
    function verify(Origin calldata o, address receiver, bytes32 payloadHash) public returns (bool) {
        if (payloadHash == bytes32(0)) revert LZ_InvalidPayloadHash();
        uint64 lazy = lazyInboundNonce[receiver][o.srcEid][o.sender];
        if (lazy == 0 && !ILayerZeroReceiver(receiver).allowInitializePath(o)) return false; // LZ_PathNotInitializable
        if (!_verifiable(o, receiver, lazy)) return false; // LZ_PathNotVerifiable
        inboundPayloadHash[receiver][o.srcEid][o.sender][o.nonce] = payloadHash;
        return true;
    }

    function verifiable(Origin calldata o, address receiver) external view returns (bool) {
        return _verifiable(o, receiver, lazyInboundNonce[receiver][o.srcEid][o.sender]);
    }

    function _verifiable(Origin calldata o, address receiver, uint64 lazy) internal view returns (bool) {
        return o.nonce > lazy || inboundPayloadHash[receiver][o.srcEid][o.sender][o.nonce] != bytes32(0);
    }

    /// @notice EndpointV2.lzReceive: clear the payload (lazy nonce rules), then call the receiver; any revert undoes both.
    function lzReceive(Origin calldata o, address receiver, bytes32 guid, bytes calldata message, bytes calldata extra)
        external
        payable
    {
        _clearPayload(receiver, o.srcEid, o.sender, o.nonce, abi.encodePacked(guid, message));
        ILayerZeroReceiver(receiver).lzReceive{value: msg.value}(o, guid, message, msg.sender, extra);
    }

    function _clearPayload(address receiver, uint32 srcEid, bytes32 sender, uint64 n, bytes memory payload) internal {
        uint64 current = lazyInboundNonce[receiver][srcEid][sender];
        if (n > current) {
            for (uint64 j = current + 1; j < n; ++j) {
                if (inboundPayloadHash[receiver][srcEid][sender][j] == bytes32(0)) revert LZ_InvalidNonce(j);
            }
            lazyInboundNonce[receiver][srcEid][sender] = n;
        }
        bytes32 expected = inboundPayloadHash[receiver][srcEid][sender][n];
        bytes32 actual = keccak256(payload);
        if (expected != actual) revert LZ_PayloadHashNotFound(expected, actual);
        delete inboundPayloadHash[receiver][srcEid][sender][n];
    }

    function inboundNonce(address receiver, uint32 srcEid, bytes32 sender) public view returns (uint64 n) {
        n = lazyInboundNonce[receiver][srcEid][sender];
        while (inboundPayloadHash[receiver][srcEid][sender][n + 1] != bytes32(0)) ++n;
    }

    function skip(address oapp, uint32 srcEid, bytes32 sender, uint64 n) external {
        if (msg.sender != oapp) revert NotRemote();
        if (n != inboundNonce(oapp, srcEid, sender) + 1) revert LZ_InvalidNonce(n);
        lazyInboundNonce[oapp][srcEid][sender] = n;
    }

    function nilify(address oapp, uint32 srcEid, bytes32 sender, uint64 n, bytes32 payloadHash) external {
        if (msg.sender != oapp) revert NotRemote();
        bytes32 cur = inboundPayloadHash[oapp][srcEid][sender][n];
        if (cur != payloadHash) revert LZ_PayloadHashNotFound(cur, payloadHash);
        if (n <= lazyInboundNonce[oapp][srcEid][sender] && cur == bytes32(0)) revert LZ_InvalidNonce(n);
        inboundPayloadHash[oapp][srcEid][sender][n] = NIL_PAYLOAD_HASH;
    }

    function burn(address oapp, uint32 srcEid, bytes32 sender, uint64 n, bytes32 payloadHash) external {
        if (msg.sender != oapp) revert NotRemote();
        bytes32 cur = inboundPayloadHash[oapp][srcEid][sender][n];
        if (cur != payloadHash) revert LZ_PayloadHashNotFound(cur, payloadHash);
        if (cur == bytes32(0) || n > lazyInboundNonce[oapp][srcEid][sender]) revert LZ_InvalidNonce(n);
        delete inboundPayloadHash[oapp][srcEid][sender][n];
    }

    // ---------------------------------------------------------------- packet views

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    /// @notice Amount (18 decimals) in packet `i`, from the OFT message (`bytes32 to ‖ uint64 amountSD`).
    function amountOf(uint256 i) external view returns (uint256) {
        bytes memory m = packets[i].message;
        uint64 sd;
        assembly {
            sd := shr(192, mload(add(m, 64)))
        }
        return uint256(sd) * 1e12;
    }

    function isDelivered(uint256 i) external view returns (bool) {
        return packets[i].delivered;
    }

    function _addr(bytes32 b) private pure returns (address) {
        return address(uint160(uint256(b)));
    }

    // ---------------------------------------------------------------- libraries + config

    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external {
        if (msg.sender != oapp) revert NotRemote();
        configCalls[oapp]++;
        for (uint256 i; i < params.length; ++i) {
            configs[oapp][lib][params[i].eid][params[i].configType] = params[i].config;
        }
    }

    // ---- default libraries: an OApp with no pinned library follows the endpoint owner's default, and config
    // is stored PER LIBRARY, so a default move leaves such an OApp on a library where it has no config of its own.

    mapping(uint32 eid => address) public defaultSendLibrary;
    mapping(uint32 eid => address) public defaultReceiveLibrary;
    mapping(address oapp => mapping(address lib => mapping(uint32 eid => mapping(uint32 configType => bytes)))) internal configs;

    /// @notice Test stand-in for LayerZero's owner-only `setDefaultSendLibrary`/`setDefaultReceiveLibrary`.
    function setDefaultLibraries(uint32 eid_, address sendLib, address receiveLib) external {
        defaultSendLibrary[eid_] = sendLib;
        defaultReceiveLibrary[eid_] = receiveLib;
    }

    function getSendLibrary(address oapp, uint32 eid_) external view returns (address lib) {
        lib = sendLibrary[oapp][eid_];
        if (lib == address(0)) lib = defaultSendLibrary[eid_];
    }

    function getReceiveLibrary(address oapp, uint32 eid_) public view returns (address lib, bool isDefault) {
        lib = receiveLibrary[oapp][eid_];
        if (lib == address(0)) (lib, isDefault) = (defaultReceiveLibrary[eid_], true);
    }

    function getConfig(address oapp, address lib, uint32 eid_, uint32 configType) external view returns (bytes memory) {
        return configs[oapp][lib][eid_][configType];
    }

    /// @notice The ULN config that verifies `oapp`'s inbound packets from `eid_` right now (empty = the library's defaults).
    function effectiveReceiveConfig(address oapp, uint32 eid_) external view returns (bytes memory) {
        (address lib,) = getReceiveLibrary(oapp, eid_);
        return configs[oapp][lib][eid_][2];
    }

    function setSendLibrary(address oapp, uint32 eid_, address lib) external {
        if (msg.sender != oapp) revert NotRemote();
        if (sendLibrary[oapp][eid_] == lib) revert LZ_SameValue();
        sendLibrary[oapp][eid_] = lib;
    }

    function setReceiveLibrary(address oapp, uint32 eid_, address lib, uint256 grace) external {
        if (msg.sender != oapp) revert NotRemote();
        if (receiveLibrary[oapp][eid_] == lib) revert LZ_SameValue();
        receiveLibrary[oapp][eid_] = lib;
        receiveGrace[oapp][eid_] = grace;
    }
}

/// @notice A stand-in message library (only its code matters: ImdBridge refuses a library address with no code).
contract MockMessageLib {
    function messageLibType() external pure returns (uint8) {
        return 2;
    }
}
