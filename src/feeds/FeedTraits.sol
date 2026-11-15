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

/// @notice Reads the two optional traits of an IFeed. A feed WITHOUT the function (Chainlink, LivePoolPrice, any feed built
/// before the traits) answers the default: converged (nothing clamps it) and not proven. Price design C, 2026-11-14.
/// @dev The function's absence is told apart from a call that RAN OUT OF GAS (EIP-150 forwards 63/64 of what is left):
/// after a failed call with less than 1/63 of the gas before it remaining, the read reverts instead of answering the
/// default, so a caller cannot under-gas a `converged()` read into reading "converged". A function that is absent reverts
/// at once (empty return data) and leaves almost all the gas. The answer is read as a word (nonzero = true), so a dirty
/// return never reverts the reader.
library FeedTraits {
    error TraitUnreadable(address feed);

    function converged(IFeed f) internal view returns (bool) {
        return _flag(address(f), IConverged.converged.selector, true);
    }

    function proven(IFeed f) internal view returns (bool) {
        return _flag(address(f), IProven.proven.selector, false);
    }

    function _flag(address f, bytes4 selector, bool absent) private view returns (bool) {
        uint256 g = gasleft();
        (bool ok, bytes memory data) = f.staticcall(abi.encodeWithSelector(selector));
        if (ok && data.length >= 32) return abi.decode(data, (uint256)) != 0;
        if (gasleft() < g / 63) revert TraitUnreadable(f);
        return absent;
    }
}
