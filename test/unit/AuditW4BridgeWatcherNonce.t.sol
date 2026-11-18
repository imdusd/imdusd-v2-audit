// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice Wave 4 LOW (audit 34e546c2): the operator watcher cannot fire on netMinted(): the supply equation holds by
/// construction after a forged mint. Detection is cross-chain only (received here vs sent there), matched per nonce.
/// PROPERTY: every inbound mint is attributable to the source nonce it consumed (Received carries it), so a watcher can
/// match destination receipts against source sends.
contract AuditW4BridgeWatcherNonceTest is W4Bridge {
    event Received(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount, uint64 nonce);

    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function test_receivedCarriesTheSourceNonce() public {
        uint256 f = _forge(1_000e18);
        (uint64 n,) = _origin(f);
        (,,,, bytes32 guid,,,) = homeEp.packets(f);
        vm.expectEmit(address(rh));
        emit Received(guid, HOME, attacker, 1_000e18, n);
        assertTrue(homeEp.deliver(f));
        // and the equation the threat model watched holds after a forged mint: it cannot tell
        assertEq(int256(rhTok.totalSupply()), rh.netMinted());
    }
}
