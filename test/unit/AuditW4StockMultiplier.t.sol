// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";

/// @notice Audit wave 4 (stocks), low: MarketHoursFeed.frozen()'s multiplier rule unfroze on the first answer stamped after
/// `effectiveAt` whatever session it came from, froze on a no-op schedule, and missed a backdated step.
/// PROPERTY: after the token's multiplier changes, the type is unpriced until an answer printed after the change was seen on
/// chain; a schedule that does not change the multiplier never freezes it. (The session an answer comes from is P1's rule.)
contract AuditW4StockMultiplierTest is StockSystem {
    function setUp() public {
        _deployStocks(100_000e18, 50_000e18); // Mon 2026-10-19 14:00 UTC, in session; last round at 14:00
    }

    /// The judge's (b): a no-op schedule (next == current) froze the type at once.
    function test_judgeProof_noopScheduleDoesNotFreeze() public {
        stock.scheduleMultiplier(1e18, vm.getBlockTimestamp() + 1 hours);
        assertFalse(mhf.frozen(), "pending no-op: not frozen");
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertFalse(mhf.frozen(), "a no-op that took effect: not frozen");
    }

    /// The judge's (c): a 2x step whose effectiveAt is set before the feed's last round was not frozen.
    function test_judgeProof_backdatedStepFreezes() public {
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        stock.scheduleMultiplier(2e18, vm.getBlockTimestamp() - 1 days);
        assertTrue(mhf.frozen(), "a 2x step the feed has not priced must freeze");
    }

    /// PROPERTY: a fuzzed history of schedules (ahead, at the moment, backdated, no-op), prints and syncs, read every step.
    function testFuzz_multiplierFreezesUntilAnAnswerAfterTheChange(uint256 seed) public {
        uint256 lastChange; // when the multiplier the token reports last changed (the test's ghost)
        uint256 prevMult = stock.uiMultiplier();
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + 1 + seed % 40 minutes);
            uint256 action = (seed >> 16) % 6;
            uint256 cur = stock.uiMultiplier();
            if (action == 0) stock.scheduleMultiplier(cur + 1e15, vm.getBlockTimestamp() + (seed >> 32) % 2 hours); // ahead
            else if (action == 1) stock.scheduleMultiplier(cur + 1e15, vm.getBlockTimestamp()); // at the moment
            else if (action == 2) stock.scheduleMultiplier(cur + 1e15, vm.getBlockTimestamp() - 1 - (seed >> 32) % 1 days); // backdated
            else if (action == 3) stock.scheduleMultiplier(cur, vm.getBlockTimestamp() + (seed >> 32) % 2 hours); // no-op
            else if (action == 4) _price(100e8);
            else _sync();
            // ghost: a change becomes visible when the token starts reporting it
            uint256 nowMult = stock.uiMultiplier();
            if (nowMult != prevMult) {
                lastChange = vm.getBlockTimestamp();
                prevMult = nowMult;
            }
            _readCheck(lastChange);
            // walk on a little, letting scheduled steps take effect between reads
            vm.warp(vm.getBlockTimestamp() + (seed >> 64) % 30 minutes);
            nowMult = stock.uiMultiplier();
            if (nowMult != prevMult) {
                // it took effect at its effectiveAt, sometime in the walk: the earliest it could be is the walk's start
                lastChange = stock.effectiveAt();
                prevMult = nowMult;
            }
            _readCheck(lastChange);
            if ((seed >> 80) % 3 == 0) _sync();
            if ((seed >> 96) % 3 == 0) {
                vm.warp(vm.getBlockTimestamp() + 1);
                _price(100e8);
            }
            _readCheck(lastChange);
        }
    }

    function _sync() internal {
        (bool ok,) = address(mhf).call(abi.encodeWithSignature("sync()")); // low-level: the suite also runs on the old code
        ok;
    }

    function _readCheck(uint256 lastChange) internal view {
        if (mhf.frozen()) return;
        (, uint64 at) = mhf.latestValue();
        assertGt(at, lastChange, "priced from an answer printed before the multiplier changed");
        assertEq(stock.uiMultiplier(), stock.newUIMultiplier(), "priced with a step pending");
    }

    /// Liveness: an honest step (scheduled ahead, as SGOV's dividends) unfreezes after a sync and the next print.
    function test_stepUnfreezesAfterSyncAndPrint() public {
        stock.scheduleMultiplier(1.002e18, vm.getBlockTimestamp() + 1 hours);
        assertTrue(mhf.frozen(), "pending step");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertTrue(mhf.frozen(), "took effect, not yet seen");
        _sync();
        assertTrue(mhf.frozen(), "seen, the feed has not re-priced");
        vm.warp(vm.getBlockTimestamp() + 1);
        _price(100.2e8);
        assertFalse(mhf.frozen(), "re-priced after the step was seen");
    }
}
