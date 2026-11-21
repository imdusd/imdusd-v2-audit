// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";

/// @notice A review before wave 5b: the Safe's loss across a reopening, stated honestly.
/// A forged stockpile verified at the endpoint while the path is closed cannot be told apart from honest packets on chain
/// (lzReceive does not know when a packet was verified), so after any reopening it runs in pieces that fit the refilling
/// allowance: instant Received, no Queued. The response is procedural, the VOID SWEEP: before any reopening the Safe voids
/// every forged payload the endpoint stores for the path. A forgery the Safe only HELD now always queues when it runs
/// (a review before wave 5b), so a hold is a delay, not a void: the claim it becomes must be cancelled within D.
/// BOUND (launch C 5,000, D 12 h):
///   Safe acts within D (pause, or C 0 + a cutoff at or before the first forged Queued) AND sweeps before reopening:
///     forged mints <= C x (1 + D / 1 day) = 7,500, across any number of reopenings;
///   without the sweep: + at most C x (1 + D'/ 1 day) per reopening, D' = the Safe's time to answer the first forged
///     Received after it (the allowance restarts empty and holds at most C at any moment);
///   no human action at all: 4C + B in any 72 h (70,000), as before.
contract AuditW5BridgeIncidentBoundTest is W5Bridge {
    uint256[] stock;

    function setUp() public {
        _setUpW5();
        assertTrue(homeEp.deliver(_send(alice, 100e18))); // lazy above 0
        _warp(1 days);
    }

    /// The incident: forged 5,000 runs at once, the Safe pauses within D; a stockpile is verified meanwhile; DVN fix; UNPAUSE.
    function _incident(uint256 pieces, bool sweep) internal {
        (, bool ok) = _forgeRun(5_000e18); // instant: the first forged Received
        assertTrue(ok);
        _warp(D);
        (, ok) = _forgeRun(2_500e18); // within D, still instant (the allowance refilled C x D / 1 day)
        assertTrue(ok);
        vm.prank(safe);
        rh.pause(HOME);
        for (uint256 j; j < pieces; ++j) {
            stock.push(_forge(500e18));
        }
        _governRh(_recvCfg(rhRecvLib, HOME, 0x2000)); // the DVN fix
        if (sweep) {
            for (uint256 j; j < stock.length; ++j) {
                bytes32 h = homeEp.payloadHashOf(stock[j]);
                vm.prank(safe);
                rh.voidPayload(h);
            }
        }
        _governRh(abi.encode(uint8(5), HOME)); // reopened
    }

    /// The forger runs a stockpiled piece only when it fits the refilled allowance (so it mints at once, no Queued), for
    /// 10 days, checking every 2 hours.
    function _drain() internal {
        uint256 next;
        for (uint256 step; step < 120 && next < stock.length; ++step) {
            while (next < stock.length && rh.availableInstant(HOME) >= 500e18) {
                homeEp.deliver(stock[next++]);
            }
            _warp(2 hours);
        }
    }

    function test_withTheSweepTheLossIsTheInstantPart() public {
        _incident(40, true);
        _drain();
        assertLe(rhTok.balanceOf(attacker), C + C * D / 1 days, "loss above C x (1 + D / 1 day) with the sweep");
        assertEq(rh.queued(), 0);
    }

    /// Without the sweep the stockpile runs in pieces at C per day after the reopening, unseen as claims: the residual.
    function test_withoutTheSweepEachDayAddsC() public {
        _incident(40, false);
        uint256 before = rhTok.balanceOf(attacker);
        uint256 t0 = vm.getBlockTimestamp();
        _drain();
        uint256 after_ = rhTok.balanceOf(attacker) - before;
        assertGt(after_, 0, "the residual is real");
        // the reviewer's arithmetic: without the sweep the incident total passes the 7,500 bound (here the whole 20,000)
        assertGt(rhTok.balanceOf(attacker), C + C * D / 1 days, "P3's 7,500 needs the sweep");
        assertLe(after_, C * (vm.getBlockTimestamp() - t0) / 1 days, "faster than C per day after the reopening");
    }

    /// A forgery the Safe only held runs at the hold's end as a claim; cancelled within D it never mints.
    function test_heldForgeryQueuesAtExpiry() public {
        uint256 f = _forge(4_000e18);
        (uint64 n,) = _origin(f);
        vm.prank(safe);
        rh.hold(HOME, n);
        _warp(72 hours);
        assertTrue(homeEp.deliver(f));
        assertEq(rhTok.balanceOf(attacker), 0, "a held forgery minted at once at its expiry");
        bytes32 k = _claimKey(homeEp, f);
        vm.prank(safe);
        rh.cancelClaim(HOME, k);
        _warp(30 days);
        assertFalse(_tryClaim(f));
        assertEq(rhTok.balanceOf(attacker), 0);
    }
}
