// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParametersBase} from "../ParametersBase.sol";
import {Parameters} from "../Parameters.sol";
import {Pricer} from "../Pricer.sol";
import {IBackstopOracle} from "./IBackstop.sol";

/// @notice A Backstop sleeve's prices: imdUSD per 1e18 raw units of a collateral token, read from the Pricer quote
/// of the type that pays out that token (low = the quote's `low`, high = its `high`, ok = `priced` and a `high` the median
/// supports: see `priceOf`). One type per token, set
/// by the deployer for every genesis token a sleeve covers, then sealed. After the seal only Parameters may map a NEW token
/// (its timelocked ADD_SLEEVE_ILK, for a type listed after launch). Nothing can ever repoint a token.
contract PricerOracle is IBackstopOracle {
    Pricer public immutable pricer;
    address public immutable deployer;
    /// @notice Parameters: the only mapper after the seal (new tokens only).
    address public immutable params;
    bool public sealed_;
    mapping(address token => bytes32) public ilkOf;

    error Unauthorized();
    error Sealed();
    error Exists();

    constructor(Pricer pricer_, address params_) {
        pricer = pricer_;
        params = params_;
        deployer = msg.sender;
    }

    function setIlk(address token, bytes32 ilk) external {
        if (sealed_ ? msg.sender != params : msg.sender != deployer) revert Unauthorized();
        if (ilkOf[token] != bytes32(0) || ilk == bytes32(0)) revert Exists();
        ilkOf[token] = ilk;
    }

    function seal() external {
        if (msg.sender != deployer) revert Unauthorized();
        sealed_ = true;
    }

    /// @dev A token with no type, or a quote that reverts, reads as unpriced (ok = false): the sleeve then refuses to value it.
    /// A VALUE ONLY ONE LEG SHOWS reads as unpriced too (audit wave 5, medium): while the legs disagree, the Pricer's twin
    /// rule sets low = high = the proven spot when it is above the median, with no upper bound (one pushed-up proven block
    /// end does it, no key). That only shelters a loan until a newer block is proved, but `nav()` values held collateral at
    /// `high` and conversions mint shares at that nav. So `ok` also needs `high <= median x (1 + skew)`: always true in
    /// agreement, and true for every disagreeing quote that collapses to the median or below it (the median rule, the twin's
    /// down arm), so only the one-leg-above shape fails closed (nav waits, a sale or auction reverts as unpriced).
    function priceOf(address token) external view returns (uint256 low, uint256 high, bool ok) {
        bytes32 ilk = ilkOf[token];
        if (ilk == bytes32(0)) return (0, 0, false);
        try pricer.quote(ilk) returns (Pricer.Quote memory q) {
            if (!q.priced || q.low == 0) return (q.low, q.high, false);
            // The prices stay in the answer (ok = false): `Backstop.retire` refuses any token whose type still has a price, so
            // a pushed-up proof cannot open a retirement window (a review of the wave-5 fixes). Every value reader checks `ok` first.
            if (!q.agree && !_medianSupports(ilk, q.high)) return (q.low, q.high, false);
            return (q.low, q.high, true);
        } catch {
            return (0, 0, false);
        }
    }

    /// @dev `high <= median x (1 + skew)`; false if the median or the risk cannot be read.
    function _medianSupports(bytes32 ilk, uint256 high) private view returns (bool) {
        Parameters p = pricer.params();
        try p.config(ilk) returns (ParametersBase.Config memory c) {
            try c.median.latestValue() returns (uint256 m, uint64) {
                return high <= m + Math.mulDiv(m, p.storedRisk(ilk).skew, 1e18);
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @notice The redemption payout price of `token`'s type (`Pricer.Quote.payout`: max of the attested `high` and the type's
    /// live pool leg where it has one); 0 when unmapped or the quote reverts. Read by the Allocator's collateral auction as
    /// the top of a run, so a market above a lagging attested pair is still asked for. Never used to value or floor a sale.
    function payoutOf(address token) external view returns (uint256) {
        bytes32 ilk = ilkOf[token];
        if (ilk == bytes32(0)) return 0;
        try pricer.quote(ilk) returns (Pricer.Quote memory q) {
            return q.payout;
        } catch {
            return 0;
        }
    }

    /// @dev The legs `Pricer.quote` needs for `priced`: the median and any NHI. A leg that reverts reads as never updated.
    function pricedAt(address token) external view returns (uint256 at) {
        bytes32 ilk = ilkOf[token];
        if (ilk == bytes32(0)) return 0;
        ParametersBase.Config memory c = pricer.params().config(ilk);
        try c.median.latestValue() returns (uint256, uint64 t) {
            at = t;
        } catch {
            return 0;
        }
        if (address(c.nhi) == address(0)) return at;
        try c.nhi.latestValue() returns (uint256, uint64 t) {
            if (t < at) at = t;
        } catch {
            return 0;
        }
    }
}
