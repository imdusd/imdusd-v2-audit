// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";

/// @notice Audit wave 4 (stocks), low: MarketCalendar accepted at propose a list `applyPending` can never apply (a weekend
/// day), occupying the one proposal slot for 48 h, and had no path faster than 48 h for a closure announced at short notice.
/// PROPERTIES: (C1) every list accepted at propose applies after the timelock while its days are still in the future;
/// (C2) a closure the exchange announces for today or the next three days can be entered at once by the governor, and that
/// path can only CLOSE a weekday (it never opens a day or moves a close), so it can only freeze, never price.
contract AuditW4StockCalendarTest is StockSystem {
    function setUp() public {
        _deployStocks(100_000e18, 50_000e18); // Mon 2026-10-19
    }

    function _list(uint32 a, uint32 b) internal pure returns (uint32[] memory l) {
        l = new uint32[](2);
        (l[0], l[1]) = (a, b);
    }

    /// The judge's proof: Fri 2026-11-27 + Sat 2026-11-28 passes propose, and apply reverts for the whole list.
    function test_judgeProof_proposeRefusesAWeekendDay() public {
        vm.prank(governor);
        try cal.propose(abi.encode(uint8(1), uint8(1), _list(DAY_AFTER, DAY_AFTER + 1))) {
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            vm.expectRevert();
            cal.applyPending();
            assertTrue(false, "C1: a list propose accepted can never apply");
        } catch {}
    }

    /// C1 over any two days and statuses: accepted at propose => applies after 48 h.
    function testFuzz_C1_acceptedListsApply(uint32 a, uint32 b, uint8 status) public {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        a = uint32(bound(a, today + 3, today + 400));
        b = uint32(bound(b, today + 3, today + 400));
        status = uint8(bound(status, 0, 2));
        vm.prank(governor);
        try cal.propose(abi.encode(uint8(1), status, _list(a, b))) {
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            cal.applyPending();
            assertEq(cal.dayStatus(a), status);
            assertEq(cal.dayStatus(b), status);
        } catch {
            // refused only for a weekend day
            assertTrue((a + 4) % 7 == 0 || (a + 4) % 7 == 6 || (b + 4) % 7 == 0 || (b + 4) % 7 == 6, "refused a valid list");
        }
    }

    /// C2: the fast path closes a weekday from today to three days ahead at once; it can only close.
    function testFuzz_C2_fastCloseOnlyFreezes(uint256 ahead, uint256 secs, address caller) public {
        if (secs % 4 != 0) caller = governor; // mostly the governor, sometimes anyone
        uint256 today = vm.getBlockTimestamp() / 1 days;
        uint32 day = uint32(today + bound(ahead, 0, 6));
        vm.warp(today * 1 days + bound(secs, 0, 1 days - 1)); // any time of day, before or inside the session
        uint256 at = uint256(day) * 1 days + 15 hours; // inside the session in EDT and EST
        bool wasOpen = cal.isOpen(at);
        vm.prank(caller);
        (bool ok,) = address(cal).call(abi.encodeWithSignature("closeDay(uint32)", day));
        if (!ok) {
            bool weekend = (uint256(day) + 4) % 7 == 0 || (uint256(day) + 4) % 7 == 6;
            assertTrue(caller != governor || weekend || day > today + 3, "C2: a valid short-notice closure refused");
            assertEq(cal.isOpen(at), wasOpen, "a refused call changes nothing");
            return;
        }
        assertEq(caller, governor, "only the governor");
        assertLe(day, today + 3);
        assertFalse(cal.isOpen(at), "closed at once");
        assertEq(cal.dayStatus(day), cal.CLOSED());
    }

    /// The fast path cannot reopen or early-close a day (it takes no status).
    function test_fastCloseCannotOpen() public {
        uint32 d = uint32(vm.getBlockTimestamp() / 1 days);
        vm.prank(governor);
        (bool ok,) = address(cal).call(abi.encodeWithSignature("closeDay(uint32)", d));
        assertTrue(ok, "today closes at once");
        assertFalse(cal.isOpen(vm.getBlockTimestamp()));
        vm.prank(governor);
        vm.expectRevert();
        cal.propose(abi.encode(uint8(1), uint8(0), _list(d, d))); // and the timelock path cannot reopen a begun day
    }
}
