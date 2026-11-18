// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StockVault} from "../../src/stocks/StockVault.sol";

contract W4BurnableStock is ERC20("SPY", "SPY") {
    function mint(address a, uint256 v) external {
        _mint(a, v);
    }

    function adminBurn(address a, uint256 v) external {
        _burn(a, v);
    }
}

/// @notice Audit wave 4 (stocks), high: the hollow-vault guard was lifted by a 1-wei donation after an issuer adminBurn, and a
/// dust deposit then took ~all of the reissue.
/// P2: no donation or deposit lets a depositor take value that belongs to existing shareholders or to a reissue of burned
/// custody.
contract AuditW4StockVaultTest is Test {
    W4BurnableStock t;
    StockVault v;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public {
        t = new W4BurnableStock();
        v = new StockVault(IERC20Metadata(address(t)));
        address[3] memory who = [alice, bob, eve];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            t.approve(address(v), type(uint256).max);
        }
    }

    function _deposit(address who, uint256 amount) internal {
        t.mint(who, amount);
        vm.prank(who);
        v.deposit(amount, who);
    }

    /// The judge's proof, unchanged in substance: burn the whole custody, donate 1 wei, deposit 1,000 wei, reissue.
    function test_judgeProof_oneWeiDonationReopensAHollowVault() public {
        _deposit(alice, 100e18);
        t.adminBurn(address(v), 100e18);
        assertEq(v.maxDeposit(eve), 0, "hollow: deposits closed");
        t.mint(eve, 1001);
        vm.startPrank(eve);
        t.transfer(address(v), 1);
        try v.deposit(1000, eve) {} catch {}
        vm.stopPrank();
        t.mint(address(v), 100e18); // the reissue
        uint256 aliceGets = v.previewRedeem(v.balanceOf(alice));
        uint256 eveGets = v.previewRedeem(v.balanceOf(eve));
        emit log_named_decimal_uint("alice (deposited 100) redeems", aliceGets, 18);
        emit log_named_decimal_uint("eve (deposited 1001 wei) redeems", eveGets, 18);
        assertGt(aliceGets, 99e18, "the reissue belongs to the holders the burn hit");
    }

    /// P2 over a fuzzed history: holders deposit and partly withdraw, the issuer burns any part of the custody, anyone donates
    /// any amount, the attacker tries every way in (deposit, mint), holders may withdraw while impaired, then the issuer
    /// reissues any part of what it burned. The attacker never ends with more than it paid in, and the holders the burn hit
    /// never end with less than they held minus what is still burned (each within rounding).
    function testFuzz_P2_noDepositTakesTheReissue(
        uint96 a,
        uint96 b,
        uint16 burnBps,
        uint96 donation,
        uint96 x,
        uint16 reissueBps,
        uint16 bobOutBps,
        bool useMint
    ) public {
        a = uint96(bound(a, 1e6, 1e27));
        b = uint96(bound(b, 0, 1e27));
        burnBps = uint16(bound(burnBps, 1, 10_000));
        reissueBps = uint16(bound(reissueBps, 0, 10_000));
        bobOutBps = uint16(bound(bobOutBps, 0, 10_000));
        donation = uint96(bound(donation, 0, 1e27));
        x = uint96(bound(x, 1, 1e27));
        _deposit(alice, a);
        if (b != 0) _deposit(bob, b);
        uint256 held = t.balanceOf(address(v));
        uint256 burned = held * burnBps / 10_000;
        if (burned == 0) burned = 1;
        t.adminBurn(address(v), burned);

        // Bob leaves part-way while the vault is impaired (he takes his share of what is left, at the impaired rate).
        uint256 bobOut;
        if (b != 0 && bobOutBps != 0) {
            uint256 sh = v.balanceOf(bob) * bobOutBps / 10_000;
            if (sh != 0) {
                vm.prank(bob);
                bobOut = v.redeem(sh, bob, bob);
            }
        }

        // The attacker: a donation of any size, then a deposit or a mint of any size.
        uint256 paidIn = donation;
        t.mint(eve, uint256(donation) + x);
        vm.startPrank(eve);
        if (donation != 0) t.transfer(address(v), donation);
        if (useMint) {
            uint256 sharesWanted = v.previewDeposit(x);
            if (sharesWanted != 0) {
                try v.mint(sharesWanted, eve) returns (uint256 used) {
                    paidIn += used;
                } catch {}
            }
        } else {
            try v.deposit(x, eve) {
                paidIn += x;
            } catch {}
        }
        vm.stopPrank();

        uint256 reissue = burned * reissueBps / 10_000;
        if (reissue != 0) t.mint(address(v), reissue);

        uint256 eveGets = v.previewRedeem(v.balanceOf(eve));
        assertLe(eveGets, paidIn + 1, "P2: the depositor took value it did not bring");
        // The holders the burn hit keep at least their share of what the custody now holds for them: what they had, minus
        // the part still burned (pro rata), minus what Bob already took out.
        uint256 holders = v.previewRedeem(v.balanceOf(alice)) + v.previewRedeem(v.balanceOf(bob));
        uint256 owed = held - (burned - reissue);
        // Bob's exit at the impaired rate forfeits his claim on the reissue to the holders who stayed, so what he took plus
        // what the holders hold covers it.
        assertGe(holders + bobOut + 4, owed, "P2: holders lost value");
    }

    /// REGRESSION (fixed before audit wave 5; fuzz counterexample, reproduces on the wave-4 code): alice holds 5,460,058 wei,
    /// bob ~9.6e26; a 0.01% burn; bob leaves in full while impaired (forfeiting his claim on the reissue to alice); 0.24% of
    /// the burn is reissued. OZ's 10^6 VIRTUAL shares then held 10^6 / (5.46e12 + 10^6) of the vault, so they took ~4.2e10
    /// wei of the reissue that belongs to alice: value no one can ever redeem. Not a rounding direction: the virtual shares
    /// are a holder in every gain. Fixed by valuing shares over real shares only (StockVault._convertToAssets).
    function test_P2_regression_virtualSharesTookTheForfeitedReissue() public {
        testFuzz_P2_noDepositTakesTheReissue(
            5_460_058, 35_956_330_725_940_681_264_220_864_547, 1, 2290, 24_880_336_962_866_384_324_752_084_260, 24, 10_000, true
        );
    }

    /// P2 for an EMPTY vault: every holder leaves while impaired (each forfeits the reissue), then the issuer reissues. The
    /// orphaned reissue (any part of the burn) belongs to nobody who comes later: the next depositor redeems at most what it
    /// brought; and the empty vault is open again (it never stays closed on a hole nobody holds).
    function testFuzz_P2_orphanedReissueNotTakenByTheNextDepositor(uint96 a, uint16 burnBps, uint16 reissueBps, uint96 x)
        public
    {
        a = uint96(bound(a, 1e6, 1e27));
        burnBps = uint16(bound(burnBps, 1, 10_000));
        reissueBps = uint16(bound(reissueBps, 1, 10_000));
        x = uint96(bound(x, 1, 1e27));
        _deposit(alice, a);
        uint256 burned = uint256(a) * burnBps / 10_000;
        if (burned == 0) burned = 1;
        t.adminBurn(address(v), burned);
        uint256 sh = v.balanceOf(alice);
        vm.prank(alice);
        v.redeem(sh, alice, alice);
        assertEq(v.totalSupply(), 0);
        t.mint(address(v), burned * reissueBps / 10_000 == 0 ? 1 : burned * reissueBps / 10_000);
        t.mint(eve, x);
        assertFalse(v.impaired(), "an empty vault is never closed");
        vm.prank(eve);
        v.deposit(x, eve);
        assertEq(v.totalAssets(), x, "the leftover is uncounted, like a donation");
        assertLe(v.previewRedeem(v.balanceOf(eve)), uint256(x) + 1, "P2: the next depositor took the orphaned reissue");
    }
}
