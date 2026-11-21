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
/// DEAD SHARES (audit wave 5, medium). With no virtual offset, one rounding step on a vault with no shares moved its share rate
/// by any factor: mint(1) into the empty vault cost 1 wei for 1 share (10^6 x the opening rate), as did deposit(1) then
/// redeem(999,999) (paying 0); the type's capped RateFeed, built over the empty vault, then valued every later deposit at a
/// millionth. Now the first deposit into a never-used vault also mints `DEAD_SHARES` (10^12, i.e. 10^6 wei of stock at the
/// opening rate) to `DEAD`, paid by that depositor (it receives 10^12 fewer shares, or pays 10^6 wei more for a mint). The
/// supply never falls below `DEAD_SHARES` again, so no single deposit, mint, withdraw or redeem moves the rate by more than
/// about 1 wei over the >= 10^6 wei the dead shares stand for. A vault whose only shares are the dead ones is EMPTY in every
/// rule above (never impaired; the next deposit restarts `managedAssets` and, like the first, pays for the dead shares again
/// (a review before wave 5b): the reset leaves them standing for no stock, and a restart priced at the bare opening rate
/// against them (a 1 wei restart) pinned the rate at 10^-6 of the opening rate for every later depositor. So an emptied
/// vault restarts exactly like a never-used one (same shares, same rate; a restart under 10^6 wei + 1 reverts NoShares),
/// minting no more dead shares).
/// Cost: the dead shares are a holder like any other, so they keep DEAD_SHARES / supply of a reissue forfeited to the
/// stayers (10^-14 at 100 tokens; a real share of it only when the stayers are themselves dust) and ~10^6 wei of a restart.
contract StockVault is ERC4626 {
    /// @notice Shares minted to `DEAD` by the first deposit into a never-used vault; nobody can move them.
    uint256 public constant DEAD_SHARES = 1e12;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice `worthless()` below 1 / WORTHLESS_DIVISOR of the claimed stock.
    uint256 public constant WORTHLESS_DIVISOR = 1e6;

    /// @notice The stock the vault's shares claim: deposits in, withdrawals out. Never raised by a transfer in.
    uint256 public managedAssets;

    error NoShares();

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
        return totalSupply() > DEAD_SHARES && IERC20(asset()).balanceOf(address(this)) < managedAssets;
    }

    /// @notice What `Ledger.writeOff` reads (audit wave 5, low): the vault holds under 1 / WORTHLESS_DIVISOR of the stock its
    /// shares claim. A material threshold rather than a zero share rate: while the vault is impaired a donation counts in
    /// full, so dust (totalSupply / 1e18 wei) lifted the rate off zero, blocking or clearing a write-off and leaving the type
    /// to a near-zero liquidation whose shares (and any reissue) went to the taker. A write-off at this threshold seizes at
    /// most 10^-6 of what the positions' custody was worth.
    function worthless() external view returns (bool) {
        return impaired() && IERC20(asset()).balanceOf(address(this)) * WORTHLESS_DIVISOR < managedAssets;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return impaired() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return impaired() ? 0 : type(uint256).max;
    }

    /// @notice Into a never-used or emptied (dead shares only) vault: the opening rate less the `DEAD_SHARES` the deposit
    /// also pays for (minted to DEAD on first use; re-backed on a restart).
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (totalSupply() > DEAD_SHARES) return super.previewDeposit(assets);
        uint256 shares = assets * 10 ** _decimalsOffset();
        return shares > DEAD_SHARES ? shares - DEAD_SHARES : 0;
    }

    /// @notice Into a never-used or emptied vault: the opening rate for `shares` plus the `DEAD_SHARES`, rounded up.
    function previewMint(uint256 shares) public view override returns (uint256) {
        if (totalSupply() > DEAD_SHARES) return super.previewMint(shares);
        return Math.ceilDiv(shares + DEAD_SHARES, 10 ** _decimalsOffset());
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        uint256 supply = totalSupply();
        if (shares == 0) revert NoShares(); // a deposit that mints nothing is a counted donation
        // into an empty vault: whatever `managedAssets` still counts (a reissue every holder forfeited) is nobody's
        uint256 managed = supply <= DEAD_SHARES ? 0 : managedAssets;
        super._deposit(caller, receiver, assets, shares);
        if (supply == 0) _mint(DEAD, DEAD_SHARES);
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
