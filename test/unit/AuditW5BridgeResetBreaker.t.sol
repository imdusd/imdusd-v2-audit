// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W5Bridge} from "../utils/W5Bridge.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";

/// @notice Wave-5 audit 74838ad4, LOW 3 (judge, new): RESET_BREAKER zeroed the window while what queued during the trip stayed
/// pending; a forger who queued in the block the (permissionless) reset applied, after the Safe's last cancelClaim, had it
/// released uncounted, so 2B (100,000) became claimable in one 4-UTC-day window with no trip and no human action.
/// PROPERTY (P2 across a reset): nothing can queue between the Safe's last look at a tripped path and the reset that
/// releases it, so with no human action after a reset at most B becomes claimable through claims queued in one breaker
/// window without a trip. Enforced by accepting RESET_BREAKER only on a PAUSED path (at proposal and at application).
contract AuditW5BridgeResetBreakerTest is W5Bridge {
    function setUp() public {
        _setUpW5();
    }

    function _tripWith(uint256 a, uint256 b) internal returns (uint256 n1, uint256 n2) {
        bool ok;
        (n1, ok) = _forgeRun(a);
        assertTrue(ok);
        _warp(5 hours);
        (n2, ok) = _forgeRun(b);
        assertTrue(ok);
        assertTrue(_tripped(), "tripped");
    }

    /// The judge's sequence, on the open path: the reset is refused, so the same-block queue cannot ride it.
    function test_resetOnAnOpenPathRefused() public {
        (uint256 n1, uint256 n2) = _tripWith(50_000e18, 10_000e18);
        vm.startPrank(safe);
        rh.cancelClaim(HOME, _claimKey(homeEp, n1));
        rh.cancelClaim(HOME, _claimKey(homeEp, n2));
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathOpen.selector, HOME));
        rh.propose(abi.encode(uint8(14), HOME, uint256(1)));
        vm.stopPrank();
    }

    /// The judge's sequence with the fix's procedure: pause, cancel, propose the reset with the UNPAUSE in one BATCH. The
    /// forger cannot queue in the reset's block (paused); what it queues after the reopening counts in the fresh window,
    /// so with no human action from the reset on it gets at most B through claims (and nothing at once in the first day).
    function test_resetWithThePathPausedHoldsB() public {
        (uint256 n1, uint256 n2) = _tripWith(50_000e18, 10_000e18);
        vm.startPrank(safe);
        rh.pause(HOME);
        rh.cancelClaim(HOME, _claimKey(homeEp, n1));
        rh.cancelClaim(HOME, _claimKey(homeEp, n2));
        vm.stopPrank();
        uint256 stock = _forge(50_000e18); // verified, waiting for the reopening
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (abi.encode(uint8(14), HOME, uint256(1)), abi.encode(uint8(5), HOME));
        _proposeRh(_batch(items));
        _warp(48 hours);
        assertFalse(homeEp.deliver(stock), "nothing queues while paused");
        rh.applyPending();
        uint256 resetAt = vm.getBlockTimestamp();
        assertFalse(_tripped());
        assertTrue(homeEp.deliver(stock)); // queues into the fresh window: 50,000 = B, no trip
        vm.warp(resetAt + 12 hours);
        assertTrue(_tryClaim(stock));
        vm.warp(resetAt + 24 hours);
        (uint256 n4, bool ok) = _forgeRun(50_000e18); // window 100,000 > B: trips
        assertTrue(ok);
        vm.warp(resetAt + 36 hours);
        bool claimed4 = _tryClaim(n4);
        uint256 got = rhTok.balanceOf(attacker);
        assertTrue(_tripped() && !claimed4, "the second B in the window tripped the path");
        assertLe(got, B, "P2: more than B became claimable in one 4-UTC-day window with no human action and no trip");
    }

    /// The fix's checks at application too: a reset accepted on a paused path applies (nothing else can unpause it first).
    function test_resetRefusedAtApplicationIfOpen() public {
        _tripWith(50_000e18, 10_000e18);
        vm.prank(safe);
        rh.pause(HOME);
        _governRh(abi.encode(uint8(14), HOME, uint256(1)));
        assertFalse(_tripped());
        assertTrue(rh.paused(HOME), "the reset alone does not reopen");
    }
}
