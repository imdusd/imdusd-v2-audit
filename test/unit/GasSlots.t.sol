// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";

/// @notice GAS REVIEW: storage slots each user action CREATES (zero -> non-zero) and UPDATES. Under Glamsterdam's
/// repricing (EIP-8037/8038, not final) a new slot costs 110,020 gas (now 22,100) and an update 12,100 (now 5,000), so the
/// slot count is the line item that grows most. Logs `slots <action> new <n> updated <m>`; nothing is asserted beyond
/// the action succeeding: the counts are the measurement.
contract GasSlotsTest is System {
    bytes32 constant ETH = "ETH";
    MockERC20 weth;
    MockFeed ethMedian;
    MockFeed ethSpot;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        params.seal();
        for (uint256 i; i < 2; ++i) {
            address u = [alice, bob][i];
            weth.mint(u, 1000e18);
            vm.prank(u);
            weth.approve(address(ledger), type(uint256).max);
        }
    }

    function _open(address u, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, rate);
        vm.prank(u);
        ledger.open(ETH, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    /// @dev Count slots first seen at zero and left non-zero (new), and other written slots that changed (updated).
    function _count(string memory what) internal returns (uint256 created) {
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 updated;
        // A slot may be touched several times: judge it by its first previous value and its last new value.
        bytes32[] memory keys = new bytes32[](512);
        bytes32[] memory first = new bytes32[](512);
        bytes32[] memory last = new bytes32[](512);
        address[] memory acct = new address[](512);
        bytes32[] memory slotOf = new bytes32[](512);
        uint256 k;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].reverted) continue;
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = acc[i].storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                bytes32 key = keccak256(abi.encode(s.account, s.slot));
                uint256 at = type(uint256).max;
                for (uint256 m; m < k; ++m) {
                    if (keys[m] == key) {
                        at = m;
                        break;
                    }
                }
                if (at == type(uint256).max) {
                    (keys[k], first[k], acct[k], slotOf[k]) = (key, s.previousValue, s.account, s.slot);
                    at = k++;
                }
                last[at] = s.newValue;
            }
        }
        for (uint256 m; m < k; ++m) {
            if (first[m] == bytes32(0) && last[m] != bytes32(0)) {
                ++created;
                console2.log(string.concat("  new slot in ", _name(acct[m])), vm.toString(slotOf[m]));
            }
            else if (first[m] != last[m]) ++updated;
        }
        console2.log(string.concat("slots ", what, " new"), created);
        console2.log(string.concat("slots ", what, " updated"), updated);
        console2.log(string.concat("slots ", what, " extra gas at Glamsterdam prices"), created * (110_020 - 22_100) + updated * (12_100 - 5_000));
    }

    function _name(address a) internal view returns (string memory) {
        if (a == address(ledger)) return "Ledger";
        if (a == address(usd)) return "ImdUSD";
        if (a == address(sorted)) return "SortedPositions";
        if (a == address(treasury)) return "Treasury";
        if (a == address(params)) return "Parameters";
        if (a == address(weth)) return "WETH";
        if (a == address(ledger.nft())) return "PositionNFT";
        return vm.toString(a);
    }

    function test_slots_userPaths() public {
        _open(bob, 100e18, 50_000e18, 0.05e18); // someone already in the list

        vm.startStateDiffRecording();
        _open(alice, 10e18, 10_000e18, 0.06e18);
        // Pinned (gas review): 9 before (sorted node rate/exists slot, Ledger ilkOf slot). Now: Ledger position 2,
        // PositionNFT 2 (owner, balance), SortedPositions node 2, ImdUSD balance 1.
        assertEq(_count("open (first position)"), 7, "an open creates 7 storage slots");

        uint256 id = ledger.positionId(alice, ETH, 0);
        vm.startStateDiffRecording();
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        _count("borrow more");

        vm.warp(vm.getBlockTimestamp() + 8 days);
        ethMedian.set(2000e18);
        ethSpot.set(2000e18);
        vm.startStateDiffRecording();
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, -500e18, 0, 0, 0, false, type(uint256).max, address(0)));
        _count("repay part");

        vm.startStateDiffRecording();
        vm.prank(alice);
        usd.transfer(makeAddr("newHolder"), 100e18);
        _count("imdUSD transfer to a new holder");
    }

    /// Audit wave 3 (info): `version` shared slot 3 with `yieldMark`, so once a type's riskVersion was non-zero every open on a
    /// non-yield type created an 8th slot. Pinned: an open at riskVersion 1 creates the same 7 slots as at genesis.
    function test_slots_openAtRiskVersionOne() public {
        _open(bob, 100e18, 50_000e18, 0.05e18);
        ParametersBase.Risk memory r = params.storedRisk(ETH);
        r.chop = r.chop + 0.01e18; // harsher: a new liquidation-risk version
        uint8 kind = params.SET_RISK();
        bytes memory payload = abi.encode(kind, ETH, r);
        vm.prank(governor);
        params.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        ethMedian.set(2000e18);
        ethSpot.set(2000e18);
        params.applyPending(kind);
        assertEq(params.riskVersion(ETH), 1);
        // Accrue today's interest first (the Treasury's revenue meter opens today's bucket: not the open's slot).
        uint256 bobId = ledger.positionId(bob, ETH, 0);
        vm.prank(bob);
        ledger.adjust(bobId, Adjust(0, 1e18, 0, 0, 0, false, type(uint256).max, address(0)));

        vm.startStateDiffRecording();
        _open(alice, 10e18, 10_000e18, 0.06e18);
        assertEq(_count("open at riskVersion 1"), 7, "an open at riskVersion 1 creates 7 storage slots, as at genesis");
        assertEq(ledger.position(ledger.positionId(alice, ETH, 0)).version, 1);
    }

    /// The type of a position lives in its record (ilkIndex); the sorted list reads the Ledger's rate.
    function test_ilkOfAndListRateFollowTheLedger() public {
        bytes32 BTC = "BTC";
        MockERC20 wbtc = new MockERC20("WBTC", 18);
        MockFeed f = new MockFeed(50_000e18);
        // A second type after the seal goes through governance; here a fresh system is simpler: reuse ETH for two
        // positions and check the index is shared, then an unknown id reads 0.
        _open(alice, 10e18, 10_000e18, 0.06e18);
        _open(bob, 10e18, 10_000e18, 0.04e18);
        uint256 a = ledger.positionId(alice, ETH, 0);
        uint256 b = ledger.positionId(bob, ETH, 0);
        assertEq(ledger.ilkOf(a), ETH);
        assertEq(ledger.ilkOf(b), ETH);
        assertEq(ledger.ilkOf(uint256(keccak256("nobody"))), bytes32(0), "no such position");
        assertEq(sorted.first(ETH), b, "lower rate first");
        assertEq(sorted.rateOf(ETH, a), 0.06e18);
        assertTrue(sorted.contains(ETH, a) && sorted.contains(ETH, b));
        // Alice moves under Bob: the list reorders, and its rate is the Ledger's.
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, 0.03e18);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        ethMedian.set(2000e18);
        ethSpot.set(2000e18);
        vm.prank(alice);
        ledger.setRate(a, 0.03e18, p, n);
        assertEq(sorted.first(ETH), a);
        assertEq(sorted.rateOf(ETH, a), ledger.rateOf(a));
        assertEq(sorted.rateOf(ETH, a), 0.03e18);
        // Repaid to zero: off the list, and the type is still known.
        vm.prank(bob);
        usd.transfer(alice, 1_000e18); // the interest and upfront fee on top of what she borrowed
        int256 owed = int256(ledger.debtOf(a));
        vm.prank(alice);
        ledger.adjust(a, Adjust(0, -owed, 0, 0, 0, false, type(uint256).max, address(0)));
        assertFalse(sorted.contains(ETH, a));
        assertEq(sorted.rateOf(ETH, a), 0);
        assertEq(ledger.ilkOf(a), ETH, "a repaid position keeps its type");
        (wbtc, f, BTC); // silence
    }
}
