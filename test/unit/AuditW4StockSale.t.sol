// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {Vm} from "forge-std/Vm.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Audit wave 4 (stocks), medium: `StockJoin.take` withheld the full chop in units on a shortfall or thin-band sale,
/// so the Ledger booked reserve-backed imdUSD the Treasury's USDG did not cover, and bad debt was understated.
/// PROPERTY: on every sale the USDG the Treasury receives covers the imdUSD booked as reserve-backed, and the part of the debt
/// it does not cover is booked as bad debt.
contract AuditW4StockSaleTest is StockSystem {
    address alice = makeAddr("alice");
    address taker = makeAddr("taker");

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        usdg.mint(taker, 10_000_000e6);
        vm.prank(taker);
        usdg.approve(address(sjoin), type(uint256).max);
    }

    function _sell() internal returns (uint256 usdgIn, uint256 backed, uint256 debtBefore, uint256 bad) {
        uint256 id = _pid(STK, alice);
        liquidator.liquidate(id);
        debtBefore = ledger.debtOf(id);
        uint256 r0 = ledger.reserveBacked();
        uint256 u0 = usdg.balanceOf(address(treasury));
        (,,,, uint128 b0) = ledger.ilkState(STK);
        uint256 cover0 = usd.balanceOf(address(treasury));
        vm.prank(taker);
        sjoin.take(id, type(uint256).max);
        usdgIn = (usdg.balanceOf(address(treasury)) - u0) * 1e12;
        backed = ledger.reserveBacked() - r0;
        (,,,, uint128 b1) = ledger.ilkState(STK);
        // bad debt booked by the sale, including any part the Treasury covered at once from its imdUSD
        bad = uint256(b1) - b0 + (cover0 - usd.balanceOf(address(treasury)));
    }

    /// The judge's shortfall case: 100 stock at $50 against 6,000 of debt.
    function test_judgeProof_shortfallSale() public {
        _open(alice, 100e18, 6_000e18);
        _price(50e8);
        (uint256 usdgIn, uint256 backed,,) = _sell();
        assertGe(usdgIn, backed, "reserve-backed imdUSD not backed by USDG");
    }

    /// The judge's thin-band case: $62, CR 103%, inside 1 + chop.
    function test_judgeProof_thinBandSale() public {
        _open(alice, 100e18, 6_000e18);
        _price(62e8);
        (uint256 usdgIn, uint256 backed,,) = _sell();
        assertGe(usdgIn, backed, "reserve-backed imdUSD not backed by USDG");
    }

    /// PROPERTY over prices, debts and the point in the auction the take lands at.
    function testFuzz_saleBacksWhatItBooks(uint256 debt, uint256 px, uint256 wait) public {
        debt = bound(debt, 100e18, 6_600e18);
        // unhealthy at 150%: px < debt x 1.5 / 100 tokens
        uint256 maxPx = debt * 15 / 1e3 / 1e10; // in 1e8 units
        px = bound(px, 1e8, maxPx > 1e8 ? maxPx - 1 : 1e8);
        wait = bound(wait, 0, 1 hours);
        _open(alice, 100e18, debt);
        _price(int256(px));
        uint256 id = _pid(STK, alice);
        (bool ok,) = ledger.healthy(id);
        vm.assume(!ok);
        liquidator.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + wait);
        _price(int256(px));
        uint256 debtBefore = ledger.debtOf(id);
        uint256 r0 = ledger.reserveBacked();
        uint256 u0 = usdg.balanceOf(address(treasury));
        vm.recordLogs();
        vm.prank(taker);
        sjoin.take(id, type(uint256).max);
        uint256 bad = _takenBad();
        uint256 usdgIn = (usdg.balanceOf(address(treasury)) - u0) * 1e12;
        uint256 backed = ledger.reserveBacked() - r0;
        assertGe(usdgIn, backed, "USDG covers the reserve-backed imdUSD");
        assertGe(usdgIn + bad, debtBefore, "the debt the USDG does not cover is booked as bad debt");
        assertEq(backed + bad, debtBefore, "the whole debt is booked: reserve-backed or bad");
    }

    function _takenBad() internal returns (uint256 bad) {
        bytes32 topic = keccak256("Taken(uint256,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(sjoin) && logs[i].topics[0] == topic) {
                (,,, bad) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }
}
