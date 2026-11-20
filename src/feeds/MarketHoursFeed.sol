// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChainlinkFeed} from "./ChainlinkFeed.sol";
import {MarketCalendar} from "./MarketCalendar.sol";

/// @notice A Chainlink Robinhood equity feed on 4663, priced only inside the NYSE regular session and frozen by any issuer
/// action on the token.
/// @dev VALUE: the feed's answer per whole token, as `ChainlinkFeed` (USD per 1e18 raw units). The answer ALREADY INCLUDES the
/// token's ERC-8056 `uiMultiplier` (SGOV's feed = share price x 1.00719 to 0.01%, and it stepped with
/// the multiplier at the 2026-10-01 dividend), so collateral is valued `balance x price`, never `balance x uiMultiplier x
/// price` (that would count every dividend twice).
///
/// STALE (no new debt, no liquidation, no redemption; repayment and debt-free withdrawals never read it) when ANY of:
///  - the answer is unreadable or older than `maxAge`. The feeds push on a 0.5% deviation with a 24h heartbeat, measured on
///    chain at 23 updates in 16 days for SPY: an age bound tighter than the heartbeat (e.g. 15 minutes) would leave
///    quiet tickers unpriced most of every session, so the deviation trigger is what keeps a live feed within 0.5% and
///    `maxAge` only detects a dead one (25h);
///  - the NYSE regular session is closed (`MarketCalendar`): weekends, holidays, nights. The feeds also publish in Robinhood's
///    24/5 overnight session, where SGOV printed +1.9% for 13 minutes on 2026-10-20 (a T-bill fund): those hours never price;
///  - the session has run less than `OPEN_GRACE` and the answer was printed before it opened (an overnight or pre-market
///    print does not price the open);
///  - the token is paused (`paused()`, which also reports the registry's global pause, checked again here), the issuer has
///    paused its oracle for a corporate action (`oraclePaused()`, a flag on the TOKEN), or the registry blocklists `holder`
///    (the vault that custodies every unit of the type: a blocked vault can move nothing, so nothing may be priced off it);
///  - the custody is hollow (`holder.worthless()`: an issuer burn left it under 10^-6 of its claim): written off, not sold;
///  - a multiplier change is scheduled (`newUIMultiplier() != uiMultiplier()`), or took effect and either `sync` has not
///    recorded it yet or the feed has not printed since (it has not re-priced the token at its new multiplier: SGOV read 0.2%
///    low for 24h after its October dividend).
/// Any of these reads failing counts as frozen (fail closed).
contract MarketHoursFeed is ChainlinkFeed {
    address public immutable stock;
    address public immutable registry;
    address public immutable holder;
    MarketCalendar public immutable calendar;

    /// @notice The token's multiplier as last recorded by `sync` (at construction: the one then live), and when `sync`
    /// recorded it (0: at construction). A multiplier other than this freezes the type; after a `sync`, only an answer
    /// printed later prices it.
    uint256 public seenMultiplier;
    uint64 public seenAt;

    error MultiplierPending();

    event MultiplierSeen(uint256 multiplier, uint256 at);

    constructor(address aggregator_, address stock_, address holder_, MarketCalendar calendar_, uint256 maxAge_)
        ChainlinkFeed(aggregator_, 18, maxAge_)
    {
        (bool ok, uint256 reg) = _word(stock_, abi.encodeWithSignature("ACCESS_CONTROLLED_REGISTRY()"));
        if (!ok || address(uint160(reg)).code.length == 0 || holder_ == address(0) || address(calendar_).code.length == 0) {
            revert InvalidFeed();
        }
        (bool okM, uint256 m) = _word(stock_, abi.encodeWithSignature("uiMultiplier()"));
        if (!okM) revert InvalidFeed();
        stock = stock_;
        registry = address(uint160(reg));
        holder = holder_;
        calendar = calendar_;
        seenMultiplier = m;
    }

    /// @notice Record the token's multiplier after a change (anyone; the keeper when a type freezes on one). From now on only
    /// an answer printed after this call prices the type. Refused while a change is still scheduled.
    function sync() external {
        (bool ok1, uint256 current) = _word(stock, abi.encodeWithSignature("uiMultiplier()"));
        (bool ok2, uint256 next) = _word(stock, abi.encodeWithSignature("newUIMultiplier()"));
        if (!ok1 || !ok2 || current != next) revert MultiplierPending();
        if (current == seenMultiplier) return;
        seenMultiplier = current;
        seenAt = uint64(block.timestamp);
        emit MultiplierSeen(current, block.timestamp);
    }

    /// @notice How long into the session the standing (pre-session) answer is not believed (audit wave 4, high). Measured on
    /// 4663 (all rounds of the nine deploy-config feeds, Jun-Nov 2026): when the open moved >= 0.6% from the standing
    /// answer the DON printed within seconds to ~1 minute (gaps of 1-3% printed in 0.5-2 min); a first in-session print 5
    /// minutes or more after the open was within 0.5-1.3% of the standing answer, the same spread as any in-session print
    /// after its predecessor (p99 0.56-1.25%). So after this long with no print, the deviation trigger has had regular-session
    /// prices to replace the standing answer and did not: it is as good as any in-session answer.
    uint256 public constant OPEN_GRACE = 5 minutes;

    /// @dev IN-SESSION ANSWER (audit wave 4, high): inside the session the type is priced only from an answer printed in the
    /// CURRENT session, or, once the session has run `OPEN_GRACE` with no such print, from the standing answer. Between the
    /// open and the first in-session print (or `OPEN_GRACE`) it is unpriced: the overnight and pre-market prints (Robinhood
    /// 24/5) no longer price the regular session's first minutes. The session never crosses UTC midnight, so "printed in the
    /// current session" is "printed at or after today's open".
    function isStale() public view override returns (bool) {
        if (super.isStale() || !calendar.isOpen(block.timestamp) || frozen()) return true;
        uint256 open = calendar.openAt(block.timestamp / 1 days);
        (, uint64 at) = latestValue();
        return at < open && block.timestamp < open + OPEN_GRACE;
    }

    /// @notice True while an issuer action holds the type: pause, oracle pause, blocked custody, or a multiplier change the
    /// feed has not caught up with.
    function frozen() public view returns (bool) {
        if (
            _flag(stock, abi.encodeWithSignature("paused()")) || _flag(stock, abi.encodeWithSignature("oraclePaused()"))
                || _flag(registry, abi.encodeWithSignature("paused()"))
                || _flag(registry, abi.encodeWithSignature("isBlocked(address)", holder))
        ) return true;
        // HOLLOW CUSTODY (a review of the wave-5 fixes): while the vault reads `worthless()` (impaired, under 10^-6 of its claim) the
        // type is a write-off (Ledger.writeOff), not a sale at the dust rate: a take would redeem the shares and hand a later
        // reissue to the remaining holders instead of the Treasury. Read only as a true answer: a holder without the view
        // (not a StockVault) is not frozen by it.
        (bool okW, uint256 hollow) = _word(holder, abi.encodeWithSignature("worthless()"));
        if (okW && hollow != 0) return true;
        (bool ok1, uint256 current) = _word(stock, abi.encodeWithSignature("uiMultiplier()"));
        (bool ok2, uint256 next) = _word(stock, abi.encodeWithSignature("newUIMultiplier()"));
        // MULTIPLIER (audit wave 4, low): frozen while a change is scheduled, while the live multiplier is one `sync` has not
        // recorded, and, after a `sync`, until an answer printed after it. Keyed on the multiplier itself, not `effectiveAt`
        // (a schedule that changes nothing froze the type; a step backdated before the feed's last round did not).
        if (!ok1 || !ok2 || current != next || current != seenMultiplier) return true;
        (, uint64 updatedAt) = latestValue();
        return updatedAt <= seenAt;
    }

    /// @dev True unless the call succeeds and returns false.
    function _flag(address target, bytes memory data) private view returns (bool) {
        (bool ok, uint256 v) = _word(target, data);
        return !ok || v != 0;
    }

    function _word(address target, bytes memory data) private view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
