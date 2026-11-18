// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoChains} from "../utils/TwoChains.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {MockLzEndpoint} from "../utils/MockLzEndpoint.sol";

/// @notice FIXED BEFORE AUDIT WAVE 5 (SET_BRIDGE named any contract with code). ImdUSD.setBridge is one-time and
/// the bridge mints without a cap of its own, so a mistaken or compromised Safe could name any minter for good.
/// PROPERTY: imdUSD's bridge minter can only be an ImdBridge wired to THIS chain's imdUSD, LayerZero endpoint, governor (the
/// Safe that governs Parameters) and Treasury; anything else is refused at propose AND at apply.
contract AuditW5SetBridgeTest is TwoChains {
    function setUp() public {
        _setUpChains();
    }

    function _refused(address candidate) internal {
        vm.prank(safe);
        vm.expectRevert();
        rh.params.propose(abi.encode(uint8(4), candidate));
        vm.prank(address(rh.params));
        vm.expectRevert();
        rh.usd.setBridge(candidate);
        assertEq(rh.usd.bridge(), address(0));
    }

    function test_arbitraryContractRefused() public {
        _refused(address(weth));
        _refused(address(rh.treasury));
    }

    function test_bridgeOfAnotherTokenRefused() public {
        // the HOME chain's bridge: a real ImdBridge, wired to the other imdUSD and Treasury
        _refused(address(home.bridge));
    }

    function test_wronglyWiredBridgesRefused() public {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(address(rhEp));
        IMintableBurnable usd = IMintableBurnable(address(rh.usd));
        address t = address(rh.treasury);
        _refused(address(new ImdBridge(ep, usd, makeAddr("notTheSafe"), t))); // governor
        _refused(address(new ImdBridge(ep, usd, safe, makeAddr("notTheTreasury")))); // treasury
        _refused(address(new ImdBridge(ep, IMintableBurnable(address(home.usd)), safe, t))); // token
    }

    function test_wrongEndpointRefusedOnRealChains() public {
        // On Ethereum and Robinhood Chain the endpoint must be LayerZero's EndpointV2 there.
        MockLzEndpoint other = new MockLzEndpoint(30_416);
        ImdBridge b = new ImdBridge(ILayerZeroEndpointV2(address(other)), IMintableBurnable(address(rh.usd)), safe, address(rh.treasury));
        vm.chainId(4663);
        _refused(address(b));
        vm.chainId(1);
        _refused(address(b));
    }

    function test_correctlyWiredBridgeAccepted() public {
        vm.prank(safe);
        rh.params.propose(abi.encode(uint8(4), address(rh.bridge)));
        _warp(48 hours);
        rh.params.applyPending();
        assertEq(rh.usd.bridge(), address(rh.bridge));
        assertTrue(rh.usd.isMinter(address(rh.bridge)));
    }
}
