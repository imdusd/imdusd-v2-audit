// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IERC20Metadata, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The pooled custody of one Robinhood stock token. Ownerless ERC-4626; its shares are the type's collateral.
/// @dev Why a vault and not the raw token: the issuer can `adminBurn` any holder's balance, and that holder is our custody.
/// A burn from a pool of raw tokens would leave the Ledger recording collateral that no longer exists, with no fair way to say
/// whose. Here the burn lands on the vault, so every share loses the same fraction at once: `convertToAssets` falls, the
/// type's price (`RateFeed` over this rate x the market-hours feed) takes the fall in full, and positions are marked down
/// pro rata with no Ledger change. A position left worth less than its debt is liquidated (debt the sale cannot cover becomes
/// the type's bad debt); one left worth nothing (a share redeems for zero) is written off (`Ledger.writeOff`).
/// MANAGED ASSETS (audit wave 4, high): the vault counts the stock its depositors brought (`managedAssets`: deposits in,
/// withdrawals out), not its balance, and values shares at min(balance, managedAssets). So:
///  - a donation (stock sent without a deposit) changes no share's value: it can neither inflate a first deposit nor lift
///    the guard below (it sits in the vault, counted by nobody);
///  - a burn lowers the balance below `managedAssets` and every share takes the loss at once (a fall is never hidden);
///  - while the vault is IMPAIRED (balance < managedAssets: burned custody not yet reissued) it takes no deposit or mint,
///    so the reissue, which can only lift the value back up to `managedAssets`, belongs wholly to the shares that were
///    there when the burn hit (a holder who leaves while impaired takes the impaired value and leaves its claim on the
///    reissue to those who stay: `managedAssets` falls by what it took, the hole stays the same size).
/// The guard audited in wave 4 keyed on `totalAssets == 0` exactly, which one wei of donated stock lifted.
/// NO VIRTUAL SHARES IN THE VALUE (fixed before audit wave 5). OZ's offset counts 10^6 virtual shares as a holder in
/// every conversion, so they took O / (supply + O) of any gain: after holders forfeit a reissue (leaving while impaired) to
/// a small remaining supply, the virtual shares kept part of it for good (4.2e10 wei in the regression). A share is now
/// worth totalAssets x shares / totalSupply, rounded against the caller (down on deposit and redeem, up on mint and
/// withdraw), so the real shares hold every unit and every rounding favours the holders who stay. The offset's job (a
/// donation cannot inflate the price) is done by `managedAssets`; the 10^6 share scale stays (first deposit: 10^6 shares per
/// unit). An EMPTY vault's leftover (a reissue every holder forfeited) restarts as uncounted, like a donation: the first
/// deposit into it sets `managedAssets` to that deposit, so the next depositor never takes it.
contract StockVault is ERC4626 {
    /// @notice The stock the vault's shares claim: deposits in, withdrawals out. Never raised by a transfer in.
    uint256 public managedAssets;

    constructor(IERC20Metadata stock_)
        ERC20(string.concat("imdUSD custody ", stock_.symbol()), string.concat("c", stock_.symbol()))
        ERC4626(stock_)
    {}

    /// @dev 10^6 virtual shares per asset unit (OZ's documented mitigation). Shares carry 6 more decimals than the
    /// stock; the RateFeed reads `convertToAssets(1e18)` and the Ledger values shares x that rate, so prices per share scale
    /// down by the same 10^6 and values are unchanged.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Real shares only, rounded against the caller; an empty vault prices at the 10^6 offset's scale.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets * 10 ** _decimalsOffset();
        uint256 held = totalAssets();
        // hollow (every unit burned): deposits are closed (impaired); a view prices no asset in and any asset out at infinity
        if (held == 0) return assets == 0 || rounding == Math.Rounding.Floor ? 0 : type(uint256).max;
        return Math.mulDiv(assets, supply, held, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return Math.mulDiv(shares, 1, 10 ** _decimalsOffset(), rounding);
        return Math.mulDiv(shares, totalAssets(), supply, rounding);
    }

    /// @notice min(balance, managedAssets): a burn is taken in full, a donation is not counted.
    function totalAssets() public view override returns (uint256) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        uint256 managed = managedAssets;
        return held < managed ? held : managed;
    }

    /// @notice True while burned custody is not yet reissued to the shares it hit: deposits and mints are closed. An empty
    /// vault is never impaired (the hole is nobody's: the first deposit restarts `managedAssets`), so it never stays closed.
    function impaired() public view returns (bool) {
        return totalSupply() != 0 && IERC20(asset()).balanceOf(address(this)) < managedAssets;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return impaired() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return impaired() ? 0 : type(uint256).max;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // into an empty vault: whatever `managedAssets` still counts (a reissue every holder forfeited) is nobody's
        uint256 managed = totalSupply() == 0 ? 0 : managedAssets;
        super._deposit(caller, receiver, assets, shares);
        managedAssets = managed + assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        managedAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
