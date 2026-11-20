// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice A review of the wave-5 fixes (job ec9fe0d5 follow-up): a hollowed StockVault (impaired, holding
/// under 10^-6 of what its shares claim) reads `worthless()`, so `writeOff` arms; but the type's price feed still priced it
/// at the dust rate (any nonzero share rate is a price). A liquidation then raced the write-off's hour: the taker's
/// `StockJoin.take` redeems the position's shares at the impaired rate, so a later reissue went to the remaining holders,
/// not to the Treasury as writeOff intends.
/// PROPERTY: while the custody reads `worthless()` the type is unpriced (the feed is stale: no new debt, no liquidation, no
/// take); it can only be written off. Above the threshold (custody holding 10^-6 or more of its claim, e.g. after a
/// donation of that size) it is priced at that value, as before.
contract AuditW5StockHollowPricedTest is StockSystem {
    address alice = makeAddr("alice");
    address marker = makeAddr("marker");
    uint256 id;

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        _open(alice, 100e18, 6_000e18);
        id = _pid(STK, alice);
    }

    /// Reproduction: the issuer burns all but a dust remainder (or burns all and dust is donated).
    function test_hollowVaultIsNotLiquidatedAtTheDustRate() public {
        stock.adminBurn(address(vault), 100e18 - 1e11); // 1e11 wei left of ~1e20 claimed: share rate ~1e3, not 0
        assertTrue(vault.worthless(), "hollow");
        assertTrue(price.isStale(), "a worthless custody must read unpriced");
        vm.prank(marker);
        (bool ok,) = address(liquidator).call(abi.encodeWithSignature("liquidate(uint256)", id));
        assertFalse(ok, "no liquidation at the dust rate while a write-off is the path");
        ledger.writeOff(id);
        _readOver(id, ledger.WRITEOFF_DELAY());
        assertEq(ledger.debtOf(id), 0, "written off: the shares (and any reissue) to the Treasury");
    }

    /// Fuzz: any remainder after a burn: priced exactly when the custody is not worthless.
    function testFuzz_pricedIffNotWorthless(uint256 left) public {
        left = bound(left, 1, 100e18);
        stock.adminBurn(address(vault), 100e18 - left);
        assertEq(price.isStale(), vault.worthless(), "unpriced exactly while worthless");
    }
}
