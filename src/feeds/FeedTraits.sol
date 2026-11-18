// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";

/// @notice Optional: whether a feed's value is the value its source last attested (SwarmFeed clamps a target into its
/// epoch's band, so the stored value can be one nobody attested). A composite reports all its inputs converged.
interface IConverged {
    function converged() external view returns (bool);
}

/// @notice Optional: whether a feed's value is derived from a pool price PROVEN from Ethereum state (ProvenPoolPrice), with
/// no attester in the path. A type whose spot leg reports it gets the Pricer's twin rule (price design C).
interface IProven {
    function proven() external view returns (bool);
}

/// @notice Optional: the value the feed would hold with no clamp: the last attested target (SwarmFeed), or a composite of its
/// inputs' attested values. Equal to `latestValue` whenever the feed is converged. Read by the Pricer's twin rule (audit
/// wave 4): a median clamped ABOVE its own attested target is a value nobody attested.
interface IAttested {
    function attested() external view returns (uint256);
}

/// @notice Reads the optional traits of an IFeed. A feed WITHOUT the function (Chainlink, LivePoolPrice, any feed built
/// before the traits) answers the default: converged (nothing clamps it) and not proven. Price design C, 2026-11-14.
/// @dev The function's absence is told apart from a call that RAN OUT OF GAS (EIP-150 forwards 63/64 of what is left):
/// after a failed call with less than 1/63 of the gas before it remaining, the read reverts instead of answering the
/// default, so a caller cannot under-gas a `converged()` read into reading "converged". A function that is absent reverts
/// at once (empty return data) and leaves almost all the gas. A call that reverts WITH data is never "absent" either: the
/// read reverts too (audit wave 4, C4). That is what carries a failure up through the composites: a composite's own trait
/// read is a FeedTraits read, so when a leaf below it runs out of gas the composite reverts `TraitUnreadable` (with data)
/// and hands back ~1/64 of its gas, which the gas test alone above it would have read as "absent". The answer is read as a
/// word (nonzero = true), so a dirty return never reverts the reader.
library FeedTraits {
    error TraitUnreadable(address feed);

    function converged(IFeed f) internal view returns (bool) {
        (bool answered, uint256 word) = _read(address(f), IConverged.converged.selector);
        return !answered || word != 0;
    }

    function proven(IFeed f) internal view returns (bool) {
        (bool answered, uint256 word) = _read(address(f), IProven.proven.selector);
        return answered && word != 0;
    }

    /// @notice The feed's attested value (IAttested); a feed without the function has no clamp, so its latest value.
    function attested(IFeed f) internal view returns (uint256 v) {
        (bool answered, uint256 word) = _read(address(f), IAttested.attested.selector);
        if (answered) return word;
        (v,) = f.latestValue();
    }

    /// @notice No attester in the feed's path: it is proven, or it does not answer `converged()` at all (every swarm leaf
    /// answers it, and so does every composite, whatever is below it; Chainlink, LivePoolPrice and ProvenPoolPrice do not).
    /// Conservative for a composite with no attester below it (a product of two Chainlink feeds reads not free). Audit wave 4,
    /// C5: what ProductFeed.proven() requires of the input that is not the proven one.
    function attesterFree(IFeed f) internal view returns (bool) {
        if (proven(f)) return true;
        (bool answered,) = _read(address(f), IConverged.converged.selector);
        return !answered;
    }

    /// @dev Whether `f` answered the zero-argument getter, and the word it answered. Absent = reverted with no data and left
    /// at least 1/63 of the gas (see the library note); any other failure reverts `TraitUnreadable`.
    function _read(address f, bytes4 selector) private view returns (bool answered, uint256 word) {
        uint256 g = gasleft();
        (bool ok, bytes memory data) = f.staticcall(abi.encodeWithSelector(selector));
        if (ok && data.length >= 32) return (true, abi.decode(data, (uint256)));
        if ((!ok && data.length != 0) || gasleft() < g / 63) revert TraitUnreadable(f);
    }
}
