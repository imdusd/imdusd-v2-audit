// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {IPulse} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Audit wave 4 (stocks), medium: the StockJoin auction's factor fell on wall-clock time while nobody could take (an
/// oracle or token pause, a blocked custody, a multiplier freeze, the Pulse grace, the session closing), so the first
/// takeable block sold at the floor.
/// PROPERTY: the auction price falls only during time in which a take could settle; across any span in which no take could
/// settle it falls at most `TICK_SPAN` worth (the bound: unpriced moments between two reads are not on chain).
contract AuditW4StockClockTest is StockSystem {
    address alice = makeAddr("alice");
    address taker = makeAddr("taker");
    uint256 id;
    Pulse pulse;

    /// @dev The deploy config's Pulse on 4663: a 15 min silence opens a 1 h grace.
    function _pulse() internal override returns (IPulse) {
        pulse = new Pulse(15 minutes, 1 hours);
        return IPulse(address(pulse));
    }

    /// @dev Walk forward with the chain alive (the keeper pokes the Pulse more often than its gap).
    function _walk(uint256 len) internal {
        while (len != 0) {
            uint256 s = len < 10 minutes ? len : 10 minutes;
            vm.warp(vm.getBlockTimestamp() + s);
            pulse.poke();
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

    /// The judge's proof: a 1 h oracle pause right after the opening.
    function test_judgeProof_oraclePauseRunsTheFactor() public {
        uint256 p0 = sjoin.price(id);
        assertEq(p0, 80e12, "opens at the live quote");
        stock.setOraclePaused(true);
        assertEq(sjoin.price(id), 0, "nobody can take");
        _walk(1 hours);
        stock.setOraclePaused(false);
        _price(80e8);
        uint256 p1 = sjoin.price(id);
        emit log_named_uint("price in first takeable block after 1h pause", p1);
        assertGt(p1, p0 * 99 / 100, "factor fell while nobody could take");
    }

    enum Hold {
        OraclePause,
        TokenPause,
        RegistryPause,
        Blocked,
        Multiplier,
        Pulse
    }

    function _hold(Hold h, bool on) internal {
        if (h == Hold.OraclePause) stock.setOraclePaused(on);
        else if (h == Hold.TokenPause) stock.setPaused(on);
        else if (h == Hold.RegistryPause) reg.setPaused(on);
        else if (h == Hold.Blocked) reg.setBlocked(address(vault), on);
        else if (h == Hold.Multiplier) {
            // a step scheduled ahead holds the type until it takes effect and the feed re-prices after it
            if (on) stock.scheduleMultiplier(stock.uiMultiplier() + 1, vm.getBlockTimestamp() + 365 days);
            else stock.scheduleMultiplier(stock.uiMultiplier(), vm.getBlockTimestamp());
        }
    }

    /// PROPERTY: a fuzzed sequence of priced stretches (with reads/ticks at any cadence) and holds of every kind (issuer flags,
    /// a multiplier step, a sequencer silence and its Pulse grace) of any length. At every priced read the price is never below
    /// live x factor(priced seconds that really passed + TICK_SPAN per hold), and within the wall-clock life.
    function testFuzz_factorRunsOnlyOnTakeableTime(uint256 seed) public {
        uint256 priced; // seconds in which a take could settle
        uint256 holds;
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // a priced stretch, read every `cadence` seconds
            uint256 run = seed % 10 minutes;
            uint256 cadence = 1 + (seed >> 32) % 6 minutes;
            uint256 done;
            while (done < run) {
                uint256 stepT = cadence < run - done ? cadence : run - done;
                _walk(stepT);
                done += stepT;
                priced += stepT;
                _price(80e8);
                if ((seed >> 64) % 2 == 0) sjoin.tick(id);
                _check(priced, holds, start);
            }
            // a hold
            Hold h = Hold((seed >> 96) % 6);
            uint256 len = 1 + (seed >> 128) % 30 minutes;
            if (h == Hold.Pulse) {
                // the sequencer is silent for `len` (no block), then the grace runs; a read in the first block after
                vm.warp(vm.getBlockTimestamp() + len + 15 minutes);
                if ((seed >> 160) % 2 == 0) sjoin.tick(id);
                _price(80e8);
                // during the grace: unpriced for takes; walk through it with reads
                pulse.poke();
                uint256 g = pulse.graceUntil();
                if (g > vm.getBlockTimestamp()) {
                    assertEq(sjoin.price(id), 0, "held by the Pulse grace");
                    _walk(g - vm.getBlockTimestamp());
                    _price(80e8);
                }
            } else {
                _hold(h, true);
                if ((seed >> 160) % 2 == 0) sjoin.tick(id);
                _walk(len);
                assertEq(sjoin.price(id), 0, "held");
                if ((seed >> 192) % 2 == 0) sjoin.tick(id);
                _hold(h, false);
                _walk(1);
                _price(80e8);
            }
            pulse.poke();
            holds++;
            _check(priced, holds, start);
        }
    }

    function _check(uint256 priced, uint256 holds, uint256 start) internal view {
        if (vm.getBlockTimestamp() > start + 2 hours) return; // lapsed (wall-clock life)
        uint256 p = sjoin.price(id);
        if (p == 0) return;
        uint256 run = priced + holds * 5 minutes; // StockJoin.TICK_SPAN
        if (run > 1 hours) run = 1 hours;
        uint256 lowest = 80e12 - 80e12 * 0.1e18 / 1e18 * run / 1 hours;
        assertGe(p + 1, lowest, "the factor fell on time in which no take could settle");
    }
}
