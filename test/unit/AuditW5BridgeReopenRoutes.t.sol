// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice A review of the wave-5 fixes (of the empty-allowance fix): that fix emptied the instant allowance on UNPAUSE
/// and on a cap raise only. Two other routes also reopen a path to packets that could not run before: a SET_PATH raising
/// the inbound limit from 0 (a close), and a SET_PATH putting back a peer that had been swapped away. Both reopened with a
/// full allowance, so a stockpile verified meanwhile minted C at once.
/// PROPERTY (the empty allowance, every route): after ANY act that lets inbound packets run again (UNPAUSE, a cap raise, an inbound limit
/// raise, a peer change), what mints at once in the t after it is at most C x t / 1 day.
contract AuditW5BridgeReopenRoutesTest is W5Bridge {
    function setUp() public {
        _setUpW5();
        // one honest message so the path's lazy nonce is above 0 (packets then verify whatever the peer is set to)
        assertTrue(homeEp.deliver(_send(alice, 100e18)));
        _warp(1 days);
    }

    function _stock(uint256 k) internal returns (uint256[] memory s) {
        s = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            s[j] = _forge(2_500e18);
        }
    }

    function _runAll(uint256[] memory s) internal {
        for (uint256 j; j < s.length; ++j) {
            homeEp.deliver(s[j]);
        }
    }

    /// The reviewer's sequence: inbound closed by SET_PATH(in 0) (paused for it), reopened by UNPAUSE, stockpile verified,
    /// a day later the inbound limit is raised back: nothing mints at once.
    function test_inLimitReopenStartsEmpty() public {
        vm.prank(safe);
        rh.pause(HOME);
        _governRh(_path(HOME, _b32(address(home)), LIM, 0));
        _governRh(abi.encode(uint8(5), HOME));
        uint256[] memory s = _stock(4);
        assertFalse(homeEp.deliver(s[0]), "cannot run while the inbound limit is 0");
        _warp(1 days);
        _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        _runAll(s);
        assertEq(rhTok.balanceOf(attacker), 0, "a stockpile minted at once at an inbound-limit reopening");
        assertEq(rh.queued(), 10_000e18);
    }

    /// Peer swapped away (open path), a stockpile under the real peer verified meanwhile, the peer put back a day later.
    function test_peerRestoreStartsEmpty() public {
        _governRh(_path(HOME, _b32(address(0xBEEF)), LIM, LIM));
        uint256[] memory s = _stock(4);
        assertFalse(homeEp.deliver(s[0]), "not the peer");
        _warp(1 days);
        _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        _runAll(s);
        assertEq(rhTok.balanceOf(attacker), 0, "a stockpile minted at once at a peer restore");
    }

    /// A SET_PATH that changes neither the peer nor raises the inbound limit (here: the outbound limit) keeps the honest
    /// instant allowance.
    function test_unrelatedSetPathKeepsTheAllowance() public {
        _governRh(_path(HOME, _b32(address(home)), LIM / 2, LIM));
        assertEq(rh.availableInstant(HOME), C);
    }

    /// Property, fuzzed over the route and the time after it.
    function testFuzz_everyReopeningOpensAtTheRate(uint8 route, uint256 t) public {
        route = uint8(bound(route, 0, 3));
        t = bound(t, 0, 2 days);
        uint256[] memory s;
        if (route == 0) {
            vm.prank(safe);
            rh.pause(HOME);
            s = _stock(8);
            _warp(1 days);
            _governRh(abi.encode(uint8(5), HOME));
        } else if (route == 1) {
            vm.prank(safe);
            rh.tighten(HOME, 0, D, B, 0);
            s = _stock(8);
            _warp(1 days);
            _governRh(_setDelayP(C, D, B, 0));
        } else if (route == 2) {
            vm.prank(safe);
            rh.pause(HOME);
            _governRh(_path(HOME, _b32(address(home)), LIM, 0));
            _governRh(abi.encode(uint8(5), HOME));
            s = _stock(8);
            _warp(1 days);
            _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        } else {
            _governRh(_path(HOME, _b32(address(0xBEEF)), LIM, LIM));
            s = _stock(8);
            _warp(1 days);
            _governRh(_path(HOME, _b32(address(home)), LIM, LIM));
        }
        _warp(t);
        _runAll(s);
        uint256 cap = t >= 1 days ? C : C * t / 1 days;
        assertLe(rhTok.balanceOf(attacker), cap, "instant mints after a reopening above C x t / 1 day");
    }
}
