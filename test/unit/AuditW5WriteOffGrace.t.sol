// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {IPulse} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {_pid} from "../utils/Pid.sol";

interface ISequencerGrace {
    error SequencerGrace();
}

/// @notice FOUND BEFORE AUDIT WAVE 5: `writeOff` seized a position (its collateral to the Treasury, its debt to
/// bad debt) with no sequencer-grace check, while liquidation (Liquidator) and redemption (Redeemer) wait out the Pulse's
/// grace and new debt waits too (AuditW5BorrowGrace).
/// PROPERTY: on a chain with a Pulse, no seizure runs while the chain is down (a silence longer than the gap that no poke
/// has ended) or inside the grace after it: `writeOff`'s seizing step reverts `SequencerGrace` there and runs as before
/// once the grace is over. Arming (the first worthless reading) only records a time and seizes nothing: it is not held.
contract AuditW5WriteOffGraceTest is StockSystem {
    uint256 constant GAP = 15 minutes; // RobinhoodConfig: Pulse gap
    uint256 constant GRACE = 1 hours; // RobinhoodConfig: Pulse grace
    Pulse pulse;
    address alice = makeAddr("alice");
    uint256 id;

    function _pulse() internal override returns (IPulse) {
        pulse = new Pulse(GAP, GRACE);
        return IPulse(address(pulse));
    }

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        _open(alice, 100e18, 6_000e18);
        id = _pid(STK, alice);
        stock.adminBurn(address(vault), 100e18); // the issuer seizes the whole custody: worthless
        pulse.poke();
        ledger.writeOff(id); // arms (seizes nothing)
        assertEq(ledger.worthlessSince(STK), vm.getBlockTimestamp());
    }

    /// @dev The chain stays alive (a poke every 10 min) for `len`.
    function _alive(uint256 len) internal {
        while (len != 0) {
            uint256 s = len < 10 minutes ? len : 10 minutes;
            vm.warp(vm.getBlockTimestamp() + s);
            pulse.poke();
            len -= s;
        }
    }

    /// Outside any grace the write-off runs as before.
    function test_liveChainWritesOff() public {
        _alive(ledger.WRITEOFF_DELAY());
        ledger.writeOff(id);
        assertEq(ledger.debtOf(id), 0);
    }

    /// An outage (silence > gap) before the second reading: held while the chain is down and through the grace after the
    /// first poke; it runs once the grace is over.
    function test_writeOffWaitsOutTheGrace() public {
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY()); // silent for an hour: the chain is down
        vm.expectRevert(ISequencerGrace.SequencerGrace.selector);
        ledger.writeOff(id);
        pulse.poke(); // the chain is back: the grace runs GRACE from now
        _alive(GRACE - 10 minutes);
        vm.expectRevert(ISequencerGrace.SequencerGrace.selector);
        ledger.writeOff(id);
        assertGt(ledger.debtOf(id), 0, "nothing seized in the grace");
        _alive(10 minutes);
        ledger.writeOff(id);
        assertEq(ledger.debtOf(id), 0);
    }

    /// Fuzzed: whatever the outage, no write-off lands while `inGrace()` reads true.
    function testFuzz_noWriteOffInTheGrace(uint256 lead, uint256 len, uint256 after_) public {
        _alive(bound(lead, ledger.WRITEOFF_DELAY(), 2 hours));
        vm.warp(vm.getBlockTimestamp() + bound(len, 1, 4 hours));
        _alive(bound(after_, 0, 2 hours));
        bool held = pulse.inGrace();
        (bool ok,) = address(ledger).call(abi.encodeWithSignature("writeOff(uint256)", id));
        ok; // a re-arm (record older than WRITEOFF_WINDOW) returns without seizing
        if (held) assertGt(ledger.debtOf(id), 0, "a write-off seized in the grace");
    }
}
