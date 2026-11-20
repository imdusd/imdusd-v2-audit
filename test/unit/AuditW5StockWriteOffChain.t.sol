// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice WAVE 5 (judge, medium; job ec9fe0d5): `writeOff`'s armed record survived an unreported reissue. A burn armed by
/// anyone and reissued before anyone sent a clearing call left `worthlessSince` set, so a second full burn inside the 7-day
/// window was written off in the block of the burn (before the reissue landed): every position's shares to the Treasury, its
/// debt to bad debt, the borrowers' equity gone.
/// PROPERTY: a write-off at T seizes only custody that was read worthless at readings no more than `WRITEOFF_STEP` apart from
/// some arming at or before T - WRITEOFF_DELAY up to T; so no stretch of value at least `WRITEOFF_STEP` long overlaps
/// [T - WRITEOFF_DELAY, T]. Readings at a keeper's cadence (< WRITEOFF_STEP) still write a worthless type off after the delay.
contract AuditW5StockWriteOffChainTest is StockSystem {
    address alice = makeAddr("alice");
    uint256 id;

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        _open(alice, 100e18, 6_000e18);
        id = _pid(STK, alice);
    }

    function _burnAll() internal returns (uint256 burned) {
        burned = stock.balanceOf(address(vault));
        stock.adminBurn(address(vault), burned);
    }

    function _try() internal returns (bool seized) {
        uint256 before = ledger.debtOf(id);
        (bool ok,) = address(ledger).call(abi.encodeWithSignature("writeOff(uint256)", id));
        seized = ok && before != 0 && ledger.debtOf(id) == 0;
    }

    /// The judge's sequence (ProofWriteOffStickyZero.test_secondBurnWrittenOffAtOnce).
    function test_judgeProof_secondBurnWrittenOffAtOnce() public {
        uint256 b = _burnAll();
        ledger.writeOff(id); // a searcher arms
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        stock.mint(address(vault), b); // reissued; nobody clears
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _burnAll(); // a second full burn ...
        _try(); // ... and a write-off in the same block
        stock.mint(address(vault), b);
        assertEq(ledger.position(id).collateral, 100e24 - vault.DEAD_SHARES(), "alice's position survives a burn reissued at once");
        assertGt(ledger.debtOf(id), 6_000e18, "and keeps its debt");
    }

    /// A review of the wave-5 fixes: the chain is readable: `worthlessSince` (the arming) and `worthlessLast` (the latest
    /// worthless reading), so a keeper knows when its next reading is due and when the write-off lands.
    function test_chainStateIsReadable() public {
        _burnAll();
        ledger.writeOff(id);
        uint256 armed = vm.getBlockTimestamp();
        assertEq(ledger.worthlessSince(STK), armed);
        assertEq(ledger.worthlessLast(STK), armed);
        vm.warp(armed + 10 minutes);
        ledger.writeOff(id);
        assertEq(ledger.worthlessSince(STK), armed, "a reading inside the delay keeps the arming");
        assertEq(ledger.worthlessLast(STK), armed + 10 minutes, "and records itself");
        vm.warp(armed + 10 minutes + ledger.WRITEOFF_STEP() + 1);
        ledger.writeOff(id);
        assertEq(ledger.worthlessSince(STK), vm.getBlockTimestamp(), "a gap over WRITEOFF_STEP re-arms");
        assertEq(ledger.worthlessLast(STK), vm.getBlockTimestamp());
    }

    /// Liveness: a keeper reading every 10 min writes a worthless type off once the delay has run.
    function test_keeperCadenceWritesOff() public {
        _burnAll();
        ledger.writeOff(id);
        uint256 armed = vm.getBlockTimestamp();
        while (vm.getBlockTimestamp() < armed + ledger.WRITEOFF_DELAY()) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            assertEq(_try(), vm.getBlockTimestamp() >= armed + ledger.WRITEOFF_DELAY(), "seized exactly once the delay ran");
        }
        assertEq(ledger.debtOf(id), 0);
    }

    /// Fuzz: any history of burns and reissues (each lasting 1 min to 3 h) with readings at any times. Whenever a write-off
    /// seizes at T, no stretch of value at least WRITEOFF_STEP long overlaps [T - WRITEOFF_DELAY, T].
    function testFuzz_seizesOnlyAChainOfWorthlessReadings(uint256[16] memory steps) public {
        uint256 step = ledger.WRITEOFF_STEP();
        uint256 delay = ledger.WRITEOFF_DELAY();
        uint256[] memory vStart = new uint256[](17);
        uint256[] memory vEnd = new uint256[](17);
        uint256 n = 1;
        vStart[0] = 0; // valued since the open
        bool valued = true;
        uint256 burned;
        for (uint256 i; i < steps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(steps[i] >> 8, 1 minutes, 3 hours));
            uint256 kind = steps[i] % 4; // 0: toggle, 1: read, 2: toggle then read, 3: nothing
            if (kind == 0 || kind == 2) {
                if (valued) {
                    burned = _burnAll();
                    vEnd[n - 1] = vm.getBlockTimestamp();
                } else {
                    stock.mint(address(vault), burned);
                    vStart[n] = vm.getBlockTimestamp();
                    ++n;
                }
                valued = !valued;
            }
            if ((kind == 1 || kind == 2) && _try()) {
                uint256 t = vm.getBlockTimestamp();
                assertFalse(valued, "seized while worth something");
                for (uint256 k; k < n; ++k) {
                    uint256 e = k == n - 1 && valued ? t : vEnd[k];
                    if (e - vStart[k] >= step && e > t - delay) revert("seized across a stretch of value");
                }
                return;
            }
        }
    }
}
