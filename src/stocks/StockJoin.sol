// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Join} from "../Join.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {Ledger} from "../Ledger.sol";
import {Liquidator, IPulseView} from "../Liquidator.sol";
import {Parameters} from "../Parameters.sol";
import {Pricer} from "../Pricer.sol";
import {IERC4626Min} from "../interfaces/IERC4626Min.sol";
import {IAuctionJoin} from "../interfaces/IPositions.sol";

/// @notice Custody (a `Join` holding the type's `StockVault` shares) and the USDG Dutch auction that sells a liquidated stock
/// position: SeatJoin's sale generalised from one NFT priced in imdUSD to fungible units paid in
/// the chain's settlement stable.
///
/// SALE. `Liquidator.bite` opens an auction for the whole position. Its price is LIVE: the type's quote (`low`, the price
/// borrowing and health use) times a factor falling linearly from 1 to `floor` over `auctionTime` of TAKEABLE time, so a
/// stale opening price is never sold at after a gap. The auction lapses at 2 x `auctionTime` of wall-clock time (the
/// position, if still unhealthy, is marked and bitten again at a fresh price).
/// CLOCK (audit wave 4, medium): the factor falls only while a take could settle: the type priced (MarketHoursFeed: session
/// open, no pause, oracle pause, blocked custody or multiplier freeze), no Pulse grace, and USDG settleable (not paused, not
/// frozen at this join or the Treasury; fixed before audit wave 5: a Paxos freeze reverted every take while the factor fell). Those states are not all on chain
/// after the fact (a pause leaves no timestamp), so the clock is read forward: each read (`tick`, anyone; `take`; the
/// opening) adds the time since the previous read only if a take could settle NOW, and at most `TICK_SPAN` of it. A span in
/// which nobody could take therefore costs at most `TICK_SPAN` of descent; ticks every `TICK_SPAN` while the type is priced
/// (the keeper, or a taker waiting for its price) keep the descent on wall-clock time. `take` works only while the type is priced: never outside the NYSE session, never while
/// the token or its oracle is paused (MarketHoursFeed), so a market-closed liquidation waits for the open.
///
/// SETTLEMENT (one transaction). The Liquidator settles the position at the taker's price with `reserve = true`: the Ledger
/// seizes every unit, books the debt the sale covers (`repaid`) as reserve-backed supply instead of burning imdUSD, makes any
/// shortfall the type's bad debt, and pays the penalty's cuts IN UNITS (vault shares: never blocklisted) to the Treasury and
/// the marker. The taker pays USDG for the units that are not penalty (`seized - bonus`, the Ledger's bonus: min(worth - repaid,
/// repaid x chop) / price, so nothing on a shortfall and only the excess inside 1 + chop) and
/// receives the stock they redeem for; the units of penalty not cut go to the Treasury; of the USDG, `repaid` (at par,
/// rounded up) goes to the Treasury, which now backs that imdUSD, and the rest is the borrower's, claimable here (`owed`), so
/// a borrower USDG cannot pay (frozen by Paxos) cannot block the sale.
/// A taker the issuer blocklists, or a paused token, makes the stock transfer revert: the whole take reverts and the auction
/// runs on for the next taker.
/// POSITIONS: auctions are keyed by position id; the leftover USDG is owed to the position's owner AT THE
/// SALE (claimed by address with `claim`), so a position sold after a transfer pays its new owner.
contract StockJoin is Join, TransientReentrancyGuard, IAuctionJoin {
    using SafeERC20 for IERC20;

    struct Auction {
        uint64 startAt; // wall clock of the opening: the auction lapses 2 x `auctionTime` after it
        address marker;
        uint32 ran; // takeable seconds counted up to `lastTick` (the Dutch clock)
        uint64 lastTick;
    }

    /// @notice The most a read counts since the previous read (`tick`, `take`, `open`): unpriced moments between two reads are
    /// not on chain, so a span between two reads counts as takeable for at most this long. Ticks at least this often keep
    /// the clock exact; a span with no take possible (and no tick) costs the borrower at most this much descent.
    uint256 public constant TICK_SPAN = 5 minutes;

    bytes32 public immutable ilk;
    IERC20 public immutable usdg;
    /// @notice USDG raw units per 1e18 of a dollar: 10^(18 - decimals).
    uint256 public immutable usdScale;
    /// @notice Seconds for the price factor to fall from 1 to `floor`; the auction lapses at twice this.
    uint256 public immutable auctionTime;
    /// @notice The lowest price factor, 1e18 = 100% of the type's quote.
    uint256 public immutable floor;

    mapping(uint256 id => Auction) public auctions;
    /// @notice USDG a sale owes a borrower (the excess over debt and penalty), claimed with `claim`.
    mapping(address owner => uint256) public owed;

    error BadAuction();
    error AuctionLive();
    error NoAuction();
    error NotPriced();
    error PriceAboveMax();
    error StillUnhealthy();
    /// @notice `tick` while the type is priced but USDG's pause/freeze state cannot be read: not recorded (fixed before audit wave 5).
    error SettlementUnreadable();

    event Opened(uint256 indexed id, address marker);
    event Cancelled(uint256 indexed id);
    event Taken(uint256 indexed id, address indexed taker, uint256 units, uint256 price, uint256 paid, uint256 bad);
    event Claimed(address indexed owner, address to, uint256 amount);

    constructor(bytes32 ilk_, address vault_, IERC20 usdg_, address wirer_, uint256 auctionTime_, uint256 floor_)
        Join(vault_, wirer_)
    {
        uint8 dec = IERC20Metadata(address(usdg_)).decimals();
        if (auctionTime_ == 0 || auctionTime_ > 1 days || floor_ < 0.5e18 || floor_ > 1e18 || dec > 18) revert BadAuction();
        ilk = ilk_;
        usdg = usdg_;
        usdScale = 10 ** (18 - dec);
        auctionTime = auctionTime_;
        floor = floor_;
    }

    // ---------------------------------------------------------------- auction

    /// @notice Liquidator only: put a marked, unhealthy position on sale. A lapsed auction may be replaced.
    function open(uint256 id, address marker) external {
        if (msg.sender != Ledger(ledger).liquidator()) revert Unauthorized();
        Auction memory a = auctions[id];
        if (a.startAt != 0 && block.timestamp <= a.startAt + 2 * auctionTime) revert AuctionLive();
        auctions[id] = Auction({startAt: uint64(block.timestamp), marker: marker, ran: 0, lastTick: uint64(block.timestamp)});
        emit Opened(id, marker);
    }

    /// @notice USD per 1e18 units (vault shares) now; 0 while the type is unpriced or the auction is not live.
    function price(uint256 id) public view returns (uint256) {
        Auction memory a = auctions[id];
        if (a.startAt == 0 || block.timestamp > a.startAt + 2 * auctionTime) return 0;
        (bool live, bool runs, uint256 low) = _takeable();
        if (!live) return 0;
        uint256 elapsed = Math.min(_ran(a, runs), auctionTime);
        return Math.mulDiv(low, 1e18 - Math.mulDiv(1e18 - floor, elapsed, auctionTime), 1e18);
    }

    /// @notice Takeable seconds the auction has run (its Dutch clock; `auctionTime` puts it at the floor).
    function elapsed(uint256 id) external view returns (uint256) {
        Auction memory a = auctions[id];
        if (a.startAt == 0) return 0;
        (, bool runs,) = _takeable();
        return _ran(a, runs);
    }

    /// @notice Record the takeable time run so far. Anyone; the keeper every `TICK_SPAN` while a live auction's type is
    /// priced, and when it goes unpriced.
    function tick(uint256 id) external {
        Auction storage a = auctions[id];
        if (a.startAt == 0) revert NoAuction();
        (bool live, bool runs,) = _takeable();
        // An unreadable USDG check stops the clock but must not let anyone (a caller starving the read of gas) record a
        // span as untakeable: such a tick is refused, and the next readable read counts the span (at most TICK_SPAN).
        if (live && !runs) revert SettlementUnreadable();
        a.ran = uint32(_ran(a, runs));
        a.lastTick = uint64(block.timestamp);
    }

    /// @dev A take could settle now: the type is priced, the Pulse holds no seizure (Liquidator.settle's own checks), and
    /// USDG moves between the parties every take needs (fixed before audit wave 5): not paused, not frozen at this join (the taker
    /// pays here) or at the Treasury (the repaid share goes there). Paxos freezes at an address and pauses the token
    /// (`isFrozen`, `paused` on Robinhood Chain's USDG); a frozen TAKER is not a hold, another taker settles.
    /// `live`: a take may be tried (a price is shown). `runs`: the Dutch clock runs. They differ only when USDG's state
    /// cannot be read (a call that reverts or returns short): FAIL CLOSED for the clock (it stops, so an unreadable check
    /// never sells cheaper), open for the take (a taker may still try at the clock's current price; a frozen token
    /// reverts the take itself).
    function _takeable() private view returns (bool live, bool runs, uint256 low) {
        Ledger l = Ledger(ledger);
        Pricer.Quote memory q = l.pricer().quote(ilk);
        if (!q.priced) return (false, false, 0);
        address pulse = address(l.pulse());
        if (pulse != address(0) && IPulseView(pulse).inGrace()) return (false, false, 0);
        (bool ok1, bool paused) = _flag(abi.encodeWithSignature("paused()"));
        (bool ok2, bool frozenHere) = _flag(abi.encodeWithSignature("isFrozen(address)", address(this)));
        (bool ok3, bool frozenTreasury) = _flag(abi.encodeWithSignature("isFrozen(address)", l.treasury()));
        if (paused || frozenHere || frozenTreasury) return (false, false, 0);
        return (true, ok1 && ok2 && ok3, q.low);
    }

    /// @dev A boolean view on USDG: (read, value). Unread when the call reverts or returns fewer than 32 bytes.
    function _flag(bytes memory data) private view returns (bool ok, bool on) {
        (bool success, bytes memory r) = address(usdg).staticcall(data);
        if (!success || r.length < 32) return (false, false);
        return (true, abi.decode(r, (uint256)) != 0);
    }

    /// @dev `ran` plus, if a take could settle now, the time since the last read, at most `TICK_SPAN`.
    function _ran(Auction memory a, bool live) private view returns (uint256) {
        if (!live) return a.ran;
        return a.ran + Math.min(block.timestamp - a.lastTick, TICK_SPAN);
    }

    /// @notice Buy the position at the current price (at most `maxPrice` per 1e18 units). Approve this contract for the USDG
    /// first; the stock goes to the caller. Returns the units bought and the USDG paid.
    function take(uint256 id, uint256 maxPrice) external nonReentrant returns (uint256 units, uint256 paid) {
        Auction memory a = auctions[id];
        uint256 p = price(id);
        if (p == 0) revert NotPriced();
        if (p > maxPrice) revert PriceAboveMax();
        delete auctions[id];

        Ledger l = Ledger(ledger);
        IERC20 shares = IERC20(token);
        address treasury = l.treasury();
        uint256 before = shares.balanceOf(address(this));
        // The bonus uses the position's BOUND chop, the one the Ledger paid its cuts with.
        (, uint256 chop) = l.params().liqRisk(ilk, l.position(id).version);
        (uint256 repaid, uint256 seized, uint256 bad) = Liquidator(l.liquidator()).settle(id, p, a.marker, true);
        uint256 cuts = before - shares.balanceOf(address(this)); // the Ledger's cut + chip, sent in units
        // The Ledger's own bonus (LedgerSettlement, solvency before penalty; audit wave 4, medium): the penalty comes only out
        // of what the sale is worth above the debt, so units x p >= repaid and the USDG reaching the Treasury is never below
        // the imdUSD just booked as reserve-backed (a shortfall sale withheld the full chop and booked USDG it never paid).
        uint256 worth = Math.mulDiv(seized, p, 1e18);
        uint256 bonus = Math.mulDiv(Math.min(worth - repaid, Math.mulDiv(repaid, chop, 1e18)), 1e18, p);
        units = seized - bonus;
        if (bonus > cuts) shares.safeTransfer(treasury, bonus - cuts);

        paid = Math.ceilDiv(Math.mulDiv(units, p, 1e18), usdScale);
        usdg.safeTransferFrom(msg.sender, address(this), paid);
        uint256 toTreasury = Math.min(paid, Math.ceilDiv(repaid, usdScale));
        if (toTreasury != 0) usdg.safeTransfer(treasury, toTreasury);
        owed[l.nft().ownerOf(id)] += paid - toTreasury;
        if (units != 0) IERC4626Min(token).redeem(units, msg.sender, address(this));
        emit Taken(id, msg.sender, units, p, paid, bad);
    }

    /// @notice An auction whose position is healthy again, or has no debt, is void.
    function cancel(uint256 id) external {
        if (auctions[id].startAt == 0) revert NoAuction();
        Ledger l = Ledger(ledger);
        if (l.debtOf(id) != 0) {
            (bool ok, bool priced) = l.healthy(id);
            if (!priced || !ok) revert StillUnhealthy();
        }
        delete auctions[id];
        emit Cancelled(id);
    }

    /// @notice Collect the USDG your liquidated position's sale left over.
    function claim(address to) external nonReentrant {
        uint256 amount = owed[msg.sender];
        owed[msg.sender] = 0;
        usdg.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }
}
