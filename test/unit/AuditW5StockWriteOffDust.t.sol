// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice WAVE 5 (judge, low; job ec9fe0d5): StockVault.totalAssets = min(balance, managedAssets), so while the vault is
/// impaired a donation counts in full. After the issuer burned the whole custody, totalSupply / 1e18 wei of donated stock
/// made convertToAssets(1e18) = 1: `writeOff` then reverted NotWorthless or cleared an armed record, and the type was left to
/// a liquidation at a near-zero price whose shares (and any later reissue) go to the taker (typically the donor) instead of
/// the Treasury.
/// PROPERTY: worthlessness is judged against a material threshold: (a) a donation smaller than 10^-6 of the custody the
/// shares claim (`managedAssets`) neither blocks nor clears a write-off; (b) a write-off never seizes custody that still
/// holds 10^-6 or more of it (a reissue of that size still clears the record).
contract AuditW5StockWriteOffDustTest is StockSystem {
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");
    uint256 id;

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        _open(alice, 100e18, 6_000e18);
        id = _pid(STK, alice);
        stock.adminBurn(address(vault), 100e18); // the whole custody
        ledger.writeOff(id); // arms
    }

    function _donate(uint256 amount) internal {
        stock.mint(griefer, amount);
        vm.prank(griefer);
        stock.transfer(address(vault), amount);
    }

    /// The judge's sequence (ProofWriteOffStickyZero.test_dustDonationBlocksWriteOff): totalSupply / 1e18 + 1 wei donated.
    function test_judgeProof_dustDonationBlocksWriteOff() public {
        _donate(vault.totalSupply() / 1e18 + 1);
        _readOver(id, ledger.WRITEOFF_DELAY());
        assertEq(ledger.debtOf(id), 0, "a dust donation must not keep the custody from being written off");
    }

    /// (a) + (b), fuzzed: a donation of any size before the delay runs out.
    function testFuzz_writeOffJudgedAgainstAMaterialThreshold(uint256 amount, uint256 at) public {
        uint256 managed = vault.managedAssets();
        amount = bound(amount, 1, managed);
        at = bound(at, 0, ledger.WRITEOFF_DELAY() - 10 minutes);
        _readOver(id, at);
        _donate(amount);
        // read on to the delay (a reading that sees value clears the record, after which NotWorthless ends the readings)
        uint256 end = vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY();
        while (vm.getBlockTimestamp() < end && ledger.debtOf(id) != 0) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            (bool ok,) = address(ledger).call(abi.encodeWithSignature("writeOff(uint256)", id));
            if (!ok) break;
        }
        if (amount * 1e6 < managed) assertEq(ledger.debtOf(id), 0, "(a) dust neither blocks nor clears the write-off");
        else assertGt(ledger.debtOf(id), 0, "(b) custody holding 1e-6 or more of its claim is not written off");
    }
}
