// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {IPulse} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice FIXED BEFORE AUDIT WAVE 5 (the stock auction clock under a USDG freeze). StockJoin's takeable check
/// never looked at the settlement token: Paxos can pause USDG or freeze it at the StockJoin (the taker pays it there) or at
/// the Treasury (the join pays the repaid share there), and every take then reverts while the Dutch factor kept falling, so
/// the first settleable block sold at the floor.
/// PROPERTY: the auction price falls only during time in which a take could settle, the settlement token included (not
/// paused, not frozen at the join or the Treasury); across any span in which none could, it falls at most TICK_SPAN worth.
/// A take never settles while the token is paused or frozen at the join or the Treasury (the premise).
contract AuditW5StockUsdgFreezeTest is StockSystem {
    address alice = makeAddr("alice");
    address taker = makeAddr("taker");
    uint256 id;
    Pulse pulse;

    function _pulse() internal override returns (IPulse) {
        pulse = new Pulse(15 minutes, 1 hours);
        return IPulse(address(pulse));
    }

    function _walk(uint256 len) internal {
        while (len != 0) {
            uint256 s = len < 10 minutes ? len : 10 minutes;
            vm.warp(vm.getBlockTimestamp() + s);
            pulse.poke();
            _price(80e8);
            len -= s;
        }
    }

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        usdg.mint(taker, 10_000_000e6);
        vm.prank(taker);
        usdg.approve(address(sjoin), type(uint256).max);
        _open(alice, 100e18, 6_000e18);
        _price(80e8);
        id = _pid(STK, alice);
        liquidator.liquidate(id);
    }

    enum Hold {
        FreezeJoin,
        FreezeTreasury,
        Pause
    }

    function _hold(Hold h, bool on) internal {
        if (h == Hold.FreezeJoin) usdg.setFrozen(address(sjoin), on);
        else if (h == Hold.FreezeTreasury) usdg.setFrozen(address(treasury), on);
        else usdg.setPaused(on);
    }

    /// The reviewer's case: Paxos freezes USDG at the StockJoin for an hour; the keeper keeps ticking. Was: the first
    /// settleable block sells at the floor.
    function test_freezeAtTheJoinStopsTheClock() public {
        uint256 p0 = sjoin.price(id);
        _hold(Hold.FreezeJoin, true);
        vm.prank(taker);
        vm.expectRevert();
        sjoin.take(id, type(uint256).max); // the premise: no take settles
        for (uint256 i; i < 12; ++i) {
            _walk(5 minutes);
            sjoin.tick(id);
        }
        _hold(Hold.FreezeJoin, false);
        uint256 p1 = sjoin.price(id);
        assertGe(p1, p0 - p0 / 10 * 5 minutes / 1 hours, "fell more than TICK_SPAN while no take could settle");
        vm.prank(taker);
        sjoin.take(id, type(uint256).max);
    }

    /// The premise for the other two holds: a take reverts while USDG is frozen at the Treasury or paused.
    function test_treasuryFreezeAndPauseBlockTakes() public {
        _hold(Hold.FreezeTreasury, true);
        vm.prank(taker);
        vm.expectRevert();
        sjoin.take(id, type(uint256).max);
        _hold(Hold.FreezeTreasury, false);
        _hold(Hold.Pause, true);
        vm.prank(taker);
        vm.expectRevert();
        sjoin.take(id, type(uint256).max);
    }

    /// A frozen TAKER is that taker's problem, not a hold: another taker settles, so the clock runs.
    function test_frozenTakerIsNotAHold() public {
        usdg.setFrozen(taker, true);
        uint256 p0 = sjoin.price(id);
        _walk(5 minutes);
        sjoin.tick(id);
        _walk(5 minutes);
        assertLt(sjoin.price(id), p0, "the clock runs: other takers can settle");
    }

    /// PROPERTY (fuzzed): priced stretches read at any cadence, interleaved with USDG holds of every kind and any length,
    /// ticked or not: at every read the price is never below live x factor(settleable seconds + TICK_SPAN per hold).
    function testFuzz_factorRunsOnlyWhileUsdgSettles(uint256 seed) public {
        uint256 priced;
        uint256 holds;
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 run = seed % 10 minutes;
            uint256 cadence = 1 + (seed >> 32) % 6 minutes;
            uint256 done;
            while (done < run) {
                uint256 stepT = cadence < run - done ? cadence : run - done;
                _walk(stepT);
                done += stepT;
                priced += stepT;
                if ((seed >> 64) % 2 == 0) sjoin.tick(id);
                _check(priced, holds, start);
            }
            Hold h = Hold((seed >> 96) % 3);
            uint256 len = 1 + (seed >> 128) % 30 minutes;
            _hold(h, true);
            if ((seed >> 160) % 2 == 0) sjoin.tick(id);
            uint256 walked;
            while (walked < len) {
                uint256 s = len - walked < 4 minutes ? len - walked : 4 minutes;
                _walk(s);
                walked += s;
                if ((seed >> 192) % 2 == 0) sjoin.tick(id); // the keeper keeps ticking through the hold
            }
            assertEq(sjoin.price(id), 0, "no price while a take cannot settle");
            _hold(h, false);
            holds++;
            _check(priced, holds, start);
        }
    }

    function _check(uint256 priced, uint256 holds, uint256 start) internal view {
        if (vm.getBlockTimestamp() > start + 2 hours) return;
        uint256 p = sjoin.price(id);
        if (p == 0) return;
        uint256 run = priced + holds * sjoin.TICK_SPAN();
        if (run > 1 hours) run = 1 hours;
        uint256 lowest = 80e12 - 80e12 * 0.1e18 / 1e18 * run / 1 hours;
        assertGe(p + 1, lowest, "the factor fell on time in which no take could settle");
    }
}

/// @notice FAIL CLOSED: an unreadable USDG check (the token upgraded without `isFrozen`, or a read starved of gas) stops the
/// clock, refuses a tick that would record the span, and still lets a take try at the clock's current price.
contract AuditW5StockUsdgUnreadableTest is StockSystem {
    address alice = makeAddr("alice");
    address taker = makeAddr("taker");
    uint256 id;

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        usdg.mint(taker, 10_000_000e6);
        vm.prank(taker);
        usdg.approve(address(sjoin), type(uint256).max);
        _open(alice, 100e18, 6_000e18);
        _price(80e8);
        id = _pid(STK, alice);
        liquidator.liquidate(id);
    }

    function test_unreadableStopsTheClockButNotTheTake() public {
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _price(80e8);
        sjoin.tick(id);
        uint256 p0 = sjoin.price(id);
        vm.mockCallRevert(address(usdg), abi.encodeWithSignature("isFrozen(address)", address(sjoin)), "");
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _price(80e8);
        assertEq(sjoin.price(id), p0, "the clock stops while USDG's state is unreadable");
        vm.expectRevert(StockJoin.SettlementUnreadable.selector);
        sjoin.tick(id);
        vm.prank(taker);
        sjoin.take(id, p0);
    }
}
