// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StockVault} from "src/stocks/StockVault.sol";
import {RateFeed} from "src/feeds/RateFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {RobinhoodConfig} from "script/DeployConfig.sol";

contract W5RcStock is ERC20 {
    constructor() ERC20("Robinhood NVDA", "NVDA") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function adminBurn(address from, uint256 a) external {
        _burn(from, a);
    }
}

contract W5RcAnyCode {}

/// @notice WAVE 5 (judge, medium; job ec9fe0d5): StockVault gives a reissue to the shares that stayed through an impairment
/// (a holder who leaves while impaired, e.g. StockJoin.take's taker or a debt-free unwrap, takes the impaired value). After
/// the reissue the stayers' share rate is above its pre-burn high, and the stock RateFeed (deploy cap 0.1%/day) let that rise
/// through at 0.1% a day: custody priced at 2/3 of its redemption value for ~500 days, a bitten stayer sold at the capped
/// price while the taker redeems at the full rate.
/// PROPERTY: a stock type's RateFeed (as the deploy config builds it) prices a share at what it redeems for: rate() equals
/// the vault's convertToAssets(1e18) after any history of deposits, burns, impaired exits, donations and reissues. (The cap
/// protected nothing here: StockVault's rate cannot be lifted without real stock in the vault: managedAssets ignores a
/// donation unless it refills an impairment, the dead shares bound rounding, and a reissue is the issuer's.)
contract AuditW5StockRateCapTest is Test {
    W5RcStock stock;
    StockVault vault;
    RateFeed feed;
    address a = address(0xA);
    address b = address(0xB);

    function setUp() public {
        stock = new W5RcStock();
        vault = new StockVault(IERC20Metadata(address(stock)));
        for (uint256 i; i < 2; ++i) {
            address w = i == 0 ? a : b;
            vm.prank(w);
            stock.approve(address(vault), type(uint256).max);
        }
        feed = new RateFeed(
            address(vault),
            bytes4(keccak256("convertToAssets(uint256)")),
            true,
            IFeed(address(new W5RcAnyCode())),
            RobinhoodConfig.stocks().rateCap
        );
    }

    function _dep(address w, uint256 amt) internal {
        stock.mint(w, amt);
        vm.prank(w);
        vault.deposit(amt, w);
    }

    /// The judge's sequence (ProofStockRateCapForfeit).
    function test_judgeProof_reissueAfterForfeitIsCappedAway() public {
        _dep(a, 100e18);
        _dep(b, 100e18);
        stock.adminBurn(address(vault), 100e18);
        uint256 sa = vault.balanceOf(a);
        vm.prank(a);
        vault.redeem(sa, a, a); // forfeits its claim on the reissue to b
        stock.mint(address(vault), 100e18);
        vm.warp(block.timestamp + 1 days);
        uint256 live = vault.convertToAssets(1e18);
        feed.poke();
        assertGe(feed.rate() * 100, live * 99, "stock type priced below what its custody redeems for");
    }

    /// Fuzz: two holders, a burn of any part, an impaired exit of any part, any donation, a reissue of any part, read at
    /// any time (poked or not): the feed's rate is the vault's.
    function testFuzz_feedFollowsTheRedeemableRate(
        uint96 da,
        uint96 db,
        uint16 burnBps,
        uint16 exitBps,
        uint96 donation,
        uint16 reissueBps,
        uint32 wait,
        bool pokeFirst
    ) public {
        _dep(a, bound(da, 2e6, 1e27));
        _dep(b, bound(db, 1, 1e27));
        uint256 held = stock.balanceOf(address(vault));
        uint256 burned = held * bound(burnBps, 0, 10_000) / 10_000;
        if (burned != 0) stock.adminBurn(address(vault), burned);
        if (pokeFirst && vault.convertToAssets(1e18) != 0) feed.poke();
        uint256 sh = vault.balanceOf(a) * bound(exitBps, 0, 10_000) / 10_000;
        if (sh != 0) {
            vm.prank(a);
            try vault.redeem(sh, a, a) {} catch {}
        }
        if (donation != 0) stock.mint(address(vault), bound(donation, 0, 1e27));
        uint256 reissue = burned * bound(reissueBps, 0, 10_000) / 10_000;
        if (reissue != 0) stock.mint(address(vault), reissue);
        vm.warp(block.timestamp + bound(wait, 0, 30 days));
        assertEq(feed.rate(), vault.convertToAssets(1e18), "the feed prices a share at what it redeems for");
        if (feed.rate() != 0) {
            feed.poke();
            assertEq(feed.rate(), vault.convertToAssets(1e18), "and after a poke");
        }
    }
}
