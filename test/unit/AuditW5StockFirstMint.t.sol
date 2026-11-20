// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StockVault} from "src/stocks/StockVault.sol";
import {RateFeed} from "src/feeds/RateFeed.sol";
import {MarketCalendar} from "src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "src/feeds/MarketHoursFeed.sol";
import {RobinhoodConfig} from "script/DeployConfig.sol";

contract W5FmRegistry {
    function paused() external pure returns (bool) {
        return false;
    }

    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

contract W5FmStock is ERC20 {
    address public immutable ACCESS_CONTROLLED_REGISTRY;

    constructor(address r) ERC20("SPY", "SPY") {
        ACCESS_CONTROLLED_REGISTRY = r;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function newUIMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract W5FmAgg {
    int256 public answer;
    uint256 public at;

    constructor(int256 a) {
        answer = a;
        at = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, at, at, 1);
    }
}

/// @notice WAVE 5 (judge, medium; job ec9fe0d5): with no virtual offset, one rounding step on an EMPTY StockVault pinned it
/// at 10^6 x its share rate (mint(1) for 1 wei, or deposit(1) + redeem(999,999) paying 0), and the type's capped RateFeed then
/// valued every later deposit at a millionth (Ledger.open Unhealthy; the 0.1%/day cap needs ~13,800 days).
/// PROPERTY: whatever anyone does to a vault through deposit/mint/withdraw/redeem before an honest deposit, the honest
/// depositor (a) can redeem what it paid in, less at most a wei, and (b) is valued at its worth by the type's price feed as
/// the deploy builds it (RateFeed over convertToAssets with the config's cap, created over the empty vault): rounding cannot
/// move a vault's share rate measurably.
/// Proof sequence = the judge's (ProofStockFirstMint, three specialists); the fuzz runs any short sequence of small calls.
contract AuditW5StockFirstMintTest is Test {
    uint256 constant MON_1400 = 1792418400; // Mon 2026-10-19 14:00 UTC, inside the session
    W5FmStock stock;
    StockVault vault;
    RateFeed price;
    address attacker = address(0xA77);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(MON_1400);
        stock = new W5FmStock(address(new W5FmRegistry()));
        W5FmAgg agg = new W5FmAgg(100e8);
        MarketCalendar cal = new MarketCalendar(address(0xBEEF), new uint32[](0), new uint32[](0));
        vault = new StockVault(IERC20Metadata(address(stock)));
        MarketHoursFeed mhf = new MarketHoursFeed(address(agg), address(stock), address(vault), cal, 25 hours);
        price = new RateFeed(
            address(vault), bytes4(keccak256("convertToAssets(uint256)")), true, mhf, RobinhoodConfig.stocks().rateCap
        );
        stock.mint(attacker, 1e30);
        vm.prank(attacker);
        stock.approve(address(vault), type(uint256).max);
    }

    function _honestDepositIsValued(uint256 amount) internal {
        bool opener = vault.totalSupply() <= vault.DEAD_SHARES(); // never used, or emptied (dead shares only)
        stock.mint(alice, amount);
        vm.startPrank(alice);
        stock.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();
        // less at most a wei, or the dead shares' 10^6 wei when her deposit opens (or reopens) the vault
        assertGe(vault.previewRedeem(shares) + 1 + (opener ? 1e6 : 0), amount, "alice redeems what she paid in");
        assertFalse(price.isStale(), "priced");
        (uint256 perShare,) = price.latestValue();
        uint256 value = shares * perShare / 1e18;
        assertApproxEqRel(value, amount * 100, 0.0001e18, "the deposit is valued at its worth ($100 a token)");
    }

    /// The judge's first route: mint(1) into the empty vault.
    function test_judgeProof_firstMintOfOneShare() public {
        vm.prank(attacker);
        try vault.mint(1, attacker) {} catch {}
        _honestDepositIsValued(100e18);
    }

    /// The judge's second route: deposit(1) then a redeem that rounds to zero assets.
    function test_judgeProof_firstDepositThenZeroAssetRedeem() public {
        vm.startPrank(attacker);
        try vault.deposit(1, attacker) {} catch {}
        try vault.redeem(999_999, attacker, attacker) {} catch {}
        vm.stopPrank();
        _honestDepositIsValued(100e18);
    }

    /// The same two routes after the vault has emptied (every holder left).
    function test_emptiedVaultCannotBePinned() public {
        vm.startPrank(attacker);
        vault.deposit(5e18, attacker);
        vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        try vault.mint(1, attacker) {} catch {}
        try vault.deposit(1, attacker) {} catch {}
        try vault.redeem(vault.balanceOf(attacker) > 1 ? vault.balanceOf(attacker) - 1 : 0, attacker, attacker) {} catch {}
        vm.stopPrank();
        _honestDepositIsValued(100e18);
    }

    /// Fuzz: any 12 small calls (mint, deposit, redeem, withdraw of up to 1e13 units) on the fresh vault, then an honest
    /// deposit of any size.
    function testFuzz_roundingCannotMoveTheShareRate(uint256[12] memory ops, uint256 honest) public {
        vm.startPrank(attacker);
        for (uint256 i; i < ops.length; ++i) {
            uint256 kind = ops[i] % 4;
            uint256 amt = bound(ops[i] >> 8, 1, 1e13);
            if (kind == 0) {
                try vault.mint(amt, attacker) {} catch {}
            } else if (kind == 1) {
                try vault.deposit(amt, attacker) {} catch {}
            } else if (kind == 2) {
                uint256 bal = vault.balanceOf(attacker);
                try vault.redeem(amt < bal ? bal - amt : bal, attacker, attacker) {} catch {}
            } else {
                try vault.withdraw(amt % 3, attacker, attacker) {} catch {}
            }
        }
        vm.stopPrank();
        _honestDepositIsValued(bound(honest, 1e15, 1e24));
    }
}
