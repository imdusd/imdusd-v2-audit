// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";
import {FeedTraits} from "./FeedTraits.sol";

/// @notice Prices a yield-bearing share (ERC-4626, or wstETH) from its exchange rate and a feed for the
/// underlying, with the exchange rate's GROWTH capped.
/// @dev v1's SharePriceFeed trusts `convertToAssets` outright, which is right for StakedIMD and wrong for
/// a third-party vault: a donation can lift a vault's rate within one block, which would let a borrower
/// mint against value that does not exist. Here the rate may rise at most `maxGrowthPerSecond` (1e18 =
/// 100%) since the last checkpoint; a FALL is taken in full at once, because a loss must never be hidden.
/// Anyone may `poke` to move the checkpoint up to the capped rate; the cap is enforced in the view too,
/// so an un-poked feed is still capped (its allowance simply grows with elapsed time).
///
/// The capped rate is also what the Ledger harvests yield against, so a donation cannot be
/// harvested either.
contract RateFeed is IFeed {
    address public immutable rateSource;
    /// @dev `convertToAssets(uint256)` (called with 1e18) or a zero-argument getter such as wstETH's
    /// `stEthPerToken()`; both return underlying raw units per 1e18 raw share units.
    bytes4 public immutable selector;
    bool public immutable passOneE18;
    IFeed public immutable underlying;
    uint256 public immutable maxGrowthPerSecond;
    /// @notice `maxGrowthPerSecond` meaning NO growth cap: the rate is the live rate (audit wave 5, medium). For a source
    /// whose rate cannot be lifted without real value behind it (StockVault: donations are not counted unless they refill an
    /// impairment, dead shares bound rounding, a reissue is the issuer's), where a cap only withheld value the shares redeem
    /// for (a reissue forfeited to the holders who stayed through a burn).
    uint256 public constant UNCAPPED = type(uint256).max;

    uint192 public checkpointRate;
    uint64 public checkpointAt;
    /// @notice The highest rate ever accepted (capped). A return to it is not new value, so the cap does not apply to it
    /// (audit wave 1: a poke during a transient dip re-based the checkpoint there, and the honest return was then
    /// rate-limited for months). A fall is still taken in full: `rate` is never above the live rate.
    uint192 public highRate;

    error InvalidFeed();
    error RateUnavailable();

    event Poked(uint256 rate);

    constructor(address rateSource_, bytes4 selector_, bool passOneE18_, IFeed underlying_, uint256 maxGrowthPerSecond_)
    {
        if (rateSource_.code.length == 0 || address(underlying_).code.length == 0) revert InvalidFeed();
        rateSource = rateSource_;
        selector = selector_;
        passOneE18 = passOneE18_;
        underlying = underlying_;
        maxGrowthPerSecond = maxGrowthPerSecond_;
        (uint256 r, bool ok) = liveRate();
        if (!ok || r == 0) revert InvalidFeed();
        checkpointRate = uint192(r);
        checkpointAt = uint64(block.timestamp);
        highRate = uint192(r);
    }

    /// @notice The exchange rate as the source reports it, uncapped.
    function liveRate() public view returns (uint256 rate, bool ok) {
        bytes memory call_ = passOneE18 ? abi.encodeWithSelector(selector, uint256(1e18)) : abi.encodeWithSelector(selector);
        (bool success, bytes memory data) = rateSource.staticcall(call_);
        if (!success || data.length < 32) return (0, false);
        return (abi.decode(data, (uint256)), true);
    }

    /// @notice min(live rate, max(checkpoint grown at the cap, highest rate accepted)); the live rate when UNCAPPED. Zero if
    /// the source stops answering.
    function rate() public view returns (uint256) {
        (uint256 live, bool ok) = liveRate();
        if (!ok) return 0;
        if (maxGrowthPerSecond == UNCAPPED) return live;
        uint256 ck = checkpointRate;
        uint256 ceiling = ck + ck * maxGrowthPerSecond * (block.timestamp - checkpointAt) / 1e18;
        uint256 high = highRate;
        if (high > ceiling) ceiling = high;
        return live < ceiling ? live : ceiling;
    }

    /// @notice Move the checkpoint to the capped rate. REVERTS when the source cannot be read (it reverted, returned short
    /// data or zero, or the call ran out of gas), so a poke can never succeed as a silent no-op: an under-gassed transaction
    /// (an `eth_estimateGas` landing just where the source's staticcall runs out under EIP-150's 63/64 rule) fails and is
    /// retried with more gas, instead of mining with the checkpoint unchanged. Readers keep the view semantics: `rate()`
    /// and `latestValue()` still return 0 (unpriced, fail closed) on a failed read.
    function poke() external {
        uint256 r = rate();
        if (r == 0) revert RateUnavailable();
        checkpointRate = uint192(r);
        checkpointAt = uint64(block.timestamp);
        if (r > highRate) highRate = uint192(r);
        emit Poked(r);
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        uint256 r = rate();
        (uint256 u, uint64 at) = underlying.latestValue();
        if (r == 0 || u == 0) return (0, 0);
        return (r * u / 1e18, at);
    }

    function isStale() external view returns (bool) {
        return underlying.isStale() || rate() == 0;
    }

    /// @notice Both inputs hold what their sources attested: the underlying, and the rate source (an ERC-4626 vault or wstETH
    /// answers no `converged()` and counts as converged: nothing clamps it). Audit wave 5, low: a swarm leaf read as the rate
    /// source (its `latestValue`) was invisible here, so a clamped rate read as converged.
    function converged() external view returns (bool) {
        return FeedTraits.converged(underlying) && FeedTraits.converged(IFeed(rateSource));
    }

    /// @notice The underlying is a proven pool price (or a product over one) AND the rate source has no attester in its path
    /// (FeedTraits.attesterFree: a vault, wstETH, a proven price). Audit wave 5, low: as ProductFeed requires of its other
    /// input since wave 4 (C5); a swarm leaf as the rate source makes the feed not proven, so the Pricer uses the median rule.
    function proven() external view returns (bool) {
        return FeedTraits.proven(underlying) && FeedTraits.attesterFree(IFeed(rateSource));
    }

    /// @notice The capped rate times the underlying's attested value (FeedTraits.attested): what this feed would read with
    /// no clamp on the underlying. The rate is read live, as in `latestValue`.
    function attested() external view returns (uint256) {
        return rate() * FeedTraits.attested(underlying) / 1e18;
    }

    function maxAge() external view returns (uint256) {
        return underlying.maxAge();
    }
}
