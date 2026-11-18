// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {IPulse} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice FIXED BEFORE AUDIT WAVE 5 (Aave's sequencer sentinel). On a chain with a Pulse (4663) seizure and
/// redemption wait out the sequencer grace, but new debt did not: a borrower the outage favoured (or an attacker who
/// censored the sequencer) could draw against prices nobody could act on.
/// PROPERTY: while the chain is down (a silence longer than the gap that no poke has ended) or inside the grace after it,
/// nothing the Pricer's `borrowable` gates executes (a borrow, a withdrawal that leaves debt behind, a charged rate
/// change); repayment, deposits and debt-free withdrawals always do. Outside the grace, everything works as before.
contract AuditW5BorrowGraceTest is System {
    bytes32 constant ETH = "ETH";
    uint256 constant GAP = 15 minutes; // RobinhoodConfig: Pulse gap
    uint256 constant GRACE = 1 hours; // RobinhoodConfig: Pulse grace

    MockERC20 weth;
    MockFeed ethFeed;
    Pulse pulse;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 id;

    function _pulse() internal override returns (IPulse) {
        pulse = new Pulse(GAP, GRACE);
        return IPulse(address(pulse));
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2000e18);
        ethFeed.setMaxAge(365 days); // about the Pulse, not feed age
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        params.seal();
        weth.mint(alice, 1_000_000e18);
        weth.mint(bob, 1_000_000e18);
        vm.prank(alice);
        weth.approve(address(ledger), type(uint256).max);
        vm.prank(bob);
        weth.approve(address(ledger), type(uint256).max);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(int256(100e18), int256(50_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        id = _pid(ETH, alice);
        vm.prank(bob);
        ledger.open(ETH, 0, Adjust(int256(10e18), 0, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function _alive(uint256 len) internal {
        while (len != 0) {
            uint256 s = len < 10 minutes ? len : 10 minutes;
            vm.warp(vm.getBlockTimestamp() + s);
            pulse.poke();
            len -= s;
        }
    }

    function _try(address who, uint256 pid, int256 dColl, int256 dDebt) internal returns (bool ok) {
        vm.prank(who);
        try ledger.adjust(pid, Adjust(dColl, dDebt, 0, 0, 0, false, type(uint256).max, address(0))) {
            ok = true;
        } catch {}
    }

    /// PROPERTY (fuzzed): outage length, a poke in the first block after it or not, when the actions are tried.
    function testFuzz_newDebtWaitsOutTheGrace(uint256 lead, uint256 len, bool poked, uint256 after_) public {
        _alive(bound(lead, 0, 3 hours));
        uint256 l = bound(len, 1, 6 hours);
        uint256 d = bound(after_, 0, 3 hours);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + l);
        if (poked) pulse.poke();
        vm.warp(t0 + l + d);
        bool held = poked ? ((l > GAP && d < GRACE) || d > GAP) : (l + d > GAP);
        assertEq(pulse.inGrace(), held, "model");
        uint256 snap = vm.snapshotState();
        // gated by `borrowable`: refused exactly while held
        assertEq(_try(alice, id, 0, 1_000e18), !held, "a borrow");
        vm.revertToState(snap);
        assertEq(_try(alice, id, -1e18, 0), !held, "a withdrawal that leaves debt");
        vm.revertToState(snap);
        // never gated
        assertTrue(_try(alice, id, 0, -1_000e18), "a repayment");
        vm.revertToState(snap);
        assertTrue(_try(alice, id, 1e18, 0), "a deposit");
        vm.revertToState(snap);
        assertTrue(_try(bob, _pid(ETH, bob), -1e18, 0), "a debt-free withdrawal");
    }

    /// The first block after an outage, before anyone pokes: the borrower's own transaction ends the silence and is held.
    function test_firstBlockAfterAnOutageRefusesABorrow() public {
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        assertFalse(_try(alice, id, 0, 1_000e18));
        // the refused borrow reverted, so its poke did not persist: the keeper's poke opens the grace
        pulse.poke();
        assertTrue(pulse.inGrace());
        _alive(GRACE);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(_try(alice, id, 0, 1_000e18), "after the grace");
    }
}
