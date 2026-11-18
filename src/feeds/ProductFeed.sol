// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";
import {FeedTraits} from "./FeedTraits.sol";

/// @notice `a * b / 1e18`: chains a price with a ratio or a cross rate.
/// @dev Uses: WBTC = BTC/USD (per 1e18 raw at 8 decimals) x WBTC/BTC ratio; IMD in USD = v1's
/// IMD/ETH swarm feed (wei per 1e18 IMD raw) x ETH/USD (USD per 1e18 wei). The result is as old as the
/// older leg and stale if either is.
contract ProductFeed is IFeed {
    IFeed public immutable a;
    IFeed public immutable b;

    error InvalidFeed();

    constructor(IFeed a_, IFeed b_) {
        if (address(a_).code.length == 0 || address(b_).code.length == 0) revert InvalidFeed();
        a = a_;
        b = b_;
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        (uint256 va, uint64 ta) = a.latestValue();
        (uint256 vb, uint64 tb) = b.latestValue();
        if (va == 0 || vb == 0) return (0, 0);
        return (va * vb / 1e18, ta < tb ? ta : tb);
    }

    function isStale() external view returns (bool) {
        return a.isStale() || b.isStale();
    }

    /// @notice Both inputs hold the value their source attested (FeedTraits: an input without the trait counts as converged).
    function converged() external view returns (bool) {
        return FeedTraits.converged(a) && FeedTraits.converged(b);
    }

    /// @notice An input is a proven pool price AND the other has no attester in its path (it is proven too, or answers no
    /// `converged()`: FeedTraits.attesterFree). Audit wave 4, C5: `proven(a) || proven(b)` called a product of a proven
    /// price and a swarm leaf proven, giving the Pricer's twin rule to a spot an attester can hold clamped. The deploy graph
    /// pairs the proven price with Chainlink ETH/USD only (DeployConfig F_IMD_USD_PROVEN; DeployBase._provenAtDeploy mirrors
    /// this rule). Conservative: a product over a composite of attester-free feeds reads not proven (median rule, safe side).
    function proven() external view returns (bool) {
        return (FeedTraits.proven(a) && FeedTraits.attesterFree(b)) || (FeedTraits.proven(b) && FeedTraits.attesterFree(a));
    }

    /// @notice `a * b / 1e18` of the inputs' attested values (FeedTraits.attested): what the product would read with no clamp.
    function attested() external view returns (uint256) {
        uint256 va = FeedTraits.attested(a);
        uint256 vb = FeedTraits.attested(b);
        return va * vb / 1e18;
    }

    function maxAge() external view returns (uint256) {
        uint256 ma = a.maxAge();
        uint256 mb = b.maxAge();
        return ma < mb ? ma : mb;
    }
}
