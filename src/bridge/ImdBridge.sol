// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governed} from "../Governed.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam, OFTReceipt} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {OFTMsgCodec} from "layerzero-v2/oft/libs/OFTMsgCodec.sol";

/// @dev LayerZero ULN302's `UlnConfig` (configType 2), decoded to enforce the floors below.
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

interface IMintableBurnable {
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
}

/// @notice imdUSD's LayerZero V2 path: LayerZero's MintBurnOFTAdapter pattern (burn on send, mint on receive, through
/// the token's one bridge minter), with every Ownable power of the OApp moved behind a 48h `Governed` timelock. No `owner()`.
/// @dev Wire format = OFT's (OFTMsgCodec: `bytes32 to ‖ uint64 amountSD`, 6 shared decimals), and the OApp receiver surface the
/// endpoint calls (`allowInitializePath`, `nextNonce`, `lzReceive`) is OApp v1/v2's, so a standard OFT peer interoperates.
///
/// AUTHORITY.
///  - The governor (the chain's Safe) proposes; anyone applies after 48h. Through it: peers, rate limits and enforced options
///    per path (`SET_PATH`), the endpoint's message-library config for this OApp (`SET_CONFIG`: DVNs, confirmations, executor),
///    send/receive libraries, and unpausing a path. `BATCH` applies several in one proposal (one pending slot).
///  - No endpoint delegate is ever set: only this contract configures itself at the endpoint, and only from `_apply`, so DVN
///    config is as slow as a peer change.
///  - LIBRARIES ARE PINNED AND CONFIGURED (audit wave 4). A path carries value only while both its libraries are
///    pinned (`SET_SEND_LIBRARY`, `SET_RECEIVE_LIBRARY`) AND each holds a floor-checked ULN config this OApp set
///    (`configured[lib][eid]`, recorded by `SET_CONFIG`, never cleared): `send` and `lzReceive` refuse otherwise, and no
///    SET_PATH or library pin is accepted unless, after its BATCH, both pins exist and are configured. So neither a SET_PATH
///    alone nor a library move without its config can leave the path on LayerZero's default ULN config (on mainnet for
///    30416: one DVN, 5 confirmations). `SET_CONFIG` refuses a library that is not the pinned one for each param's eid (pins
///    in the same BATCH count). A LayerZero library deprecation is one 48h BATCH: SET_RECEIVE_LIBRARY (new lib, grace) +
///    SET_SEND_LIBRARY + SET_CONFIG on the new libs.
///  - DVN FLOORS IN SOURCE. `SET_CONFIG` decodes every ULN config and refuses fewer than MIN_REQUIRED_DVNS
///    required DVNs (or NIL), a DVN list that does not match its count, is unsorted, repeats or holds zero, fewer block
///    confirmations than the source chain's floor, and an optional DVN count of 0 (ULN302 would merge LayerZero's DEFAULT
///    optional DVNs: "none" is NIL, 255; audit wave 4); only executor (on a send library) and ULN config types pass. A compromised
///    or careless Safe cannot propose a Kelp-style 1-of-1 downgrade at all.
///  - NO GUARDIAN: the governor (the Safe) is the only account with instant powers, and every one of them
///    can only CLOSE or DELAY: `pause` a path, `hold` one inbound message, `voidPayload` one payload hash. Everything that
///    opens or releases is timelocked: UNPAUSE, RELEASE (end a hold early), UNVOID (closable fast, reopened slowly).
///    A paused path refuses sends and leaves inbound messages at the endpoint, retryable once reopened.
///  - SUSPECT INBOUND MESSAGES ARE HELD HERE, NOT AT THE ENDPOINT (audit wave 4).
///    When lzReceive reverts, EndpointV2 keeps the packet verified (its DVN proofs were already consumed into the stored
///    hash), anyone may retry it later, and later nonces still execute (lazy nonces: a stored hash below them is enough).
///    So stopping execution never needs the endpoint:
///     - `hold(srcEid, nonce)` (governor, instant) binds the payload hash the endpoint stores at that nonce and refuses it for
///       HOLD_TIME (72h). ONE hold per (srcEid, sender, nonce) EVER: it cannot be renewed. When it expires the message runs
///       for anyone, with no DVN and no governance act, IF the endpoint still stores the hash that was held; a payload that
///       replaced it while held (a forged re-verify) never auto-releases: the held one must be verified back, or the
///       timelock's RELEASE names the payload it lets through.
///     - `voidPayload(payloadHash)` (governor, instant) refuses a payload hash for good, whatever the endpoint or the DVNs
///       hold later; only the timelock's UNVOID (48h) lifts it, and the honest message then runs with the proof the endpoint
///       kept (no DVN re-verification).
///    The endpoint acts (ENDPOINT_NILIFY/BURN/SKIP, timelocked) stay as clean-ups and are NEVER needed to stop a forgery: a
///    NIL nonce stays verifiable on EndpointV2 and the nilify itself leaves the DVNs' proofs gone (they were reclaimed when
///    the packet was committed), so a mistaken nilify makes an honest message wait for every required DVN to sign again.
///    Kelp sequence: pause; void every forged payload (both instant, one Safe signature round each); fix the DVN config
///    (48h); then unpause (48h, its own proposal: UNPAUSE may not share a BATCH with a path, library or config change for
///    that eid, so nothing verified under the old DVNs can run in the block the path reopens), without changing the peer.
///    INCIDENT RULE, THE VOID SWEEP (a review before wave 5b): before ANY reopening (UNPAUSE, a SET_PATH, a SET_DELAY raising C, and
///    SET_BRIDGE: the launch opening), and
///    after the DVN fix has applied, refuse every payload the endpoint stores for the path that does not equal the peer's
///    `Sent` AT ITS NONCE (the nonces above lazyInboundNonce, and any the watcher saw verified). PER NONCE, two acts:
///    a hash that equals no honest `Sent` at all -> `voidPayload` (by hash); a hash that equals an honest `Sent` at
///    ANOTHER nonce (a replay of an honest payload) -> `hold` that nonce + RELEASE it with hash 0 (a DROP), never a void
///    (it would refuse the honest twin). The bridge cannot tell a stockpile
///    verified while the path was closed from an honest packet; missed, it runs after the reopening in pieces that fit
///    the refilling allowance: instant Received, no Queued, at most C per day. A `hold` is only a delay: the held
///    payload queues when it runs, and that claim must be cancelled within D.
///
/// LIMITS. Per path, an outbound and an inbound limit in LayerZero RateLimiter's form: the amount in flight
/// decays linearly at limit/window, so at most `limit` passes at once and at most limit + limit x t / window in ANY interval
/// of length t: up to (just under) 2 x `limit` inside one window, not `limit` (audit wave 4; size limits with that bound).
/// Outbound bounds how much a failure on this chain can export; inbound
/// is the mint limit under a forged message. A path with no limit set refuses everything. An inbound message over the limit
/// reverts and stays at the endpoint (retry later); nothing is lost while it is within the limit itself: an inbound limit
/// must stay at or above the peer's outbound limit, so it is lowered only on a PAUSED path (audit wave 4; operator procedure: lower the
/// peer's outbound first, let its in-flight land, pause, lower, unpause). Bounds are in source.
/// A MINIMUM TRANSFER (audit wave 4: 10 imdUSD). On EndpointV2 an executed nonce can never be verified again,
/// so a forged packet that executes destroys the honest packet the peer sends at that nonce (its burn on the source is then
/// lost). A send delivers at least MIN_AMOUNT, and an inbound message for less reverts (it stays at the endpoint, where the
/// honest packet verifies over it, so a forged dust packet consumes no nonce). Every executed message is then metered at its
/// real amount and at least MIN_AMOUNT, so at most 2 x limit / MIN_AMOUNT nonces per window can be consumed (2,000 a day at a
/// 10,000 limit), and an honest transfer never counts for more than it moves. RESIDUAL: a compromised DVN set can still
/// consume up to that many honest nonces, and overwrite a waiting honest payload, until the SOURCE path is paused; the
/// watcher matches `Received` nonces here against `Sent` nonces there.
/// WATCHER: an off-chain watcher alerts the Safe signers (no key; it only alerts, the Safe acts).
///
/// INBOUND DELAY (after Wormhole Governor's large-transfer delay). EndpointV2.lzReceive is
/// permissionless, so a forged packet runs the moment it is verified and the Safe's hold/void act on nothing: without a
/// delay a forgery is spendable at once, bounded only by the inbound limit. So per path at most its INSTANT CAP C a day,
/// decaying like the limiter (`instantIn`), mints at once; an inbound message that does not fit (any single message above
/// C always) is metered against the inbound limit as before, but QUEUED instead of minted: a pending claim
/// (`claims[srcEid][guid]`, guid = the LayerZero GUID of (nonce, srcEid, sender, this chain, this bridge), unique because
/// EndpointV2 executes a nonce once) that ANYONE can `claim` for the recipient once the path's CLAIM DELAY D has run since
/// it queued, forever (no expiry): the mint happens then. During the delay the governor can `cancelClaim` (instant, like
/// hold/void: it only delays) and a paused path refuses claims; only the timelock's UNCANCEL (48h) restores a cancelled
/// claim. `Queued` is emitted when the message is received, so the watcher sees a forgery before it is spendable. A cap on
/// what mints at once per DAY, not per message, is what makes the delay hold against a forger who splits (a compromised
/// DVN set signs any number of messages): a split forgery mints at once at most C x (1 + t / 1 day) in any interval t.
/// QUEUE BREAKER. The delay protects only if the Safe acts within D; a Safe that takes a weekend would
/// otherwise let the inbound limit's worth of queued forgeries mature. So per path, once more than its QUEUE BREAKER B has
/// been queued within the current UTC day and the BREAKER_DAYS - 1 days before it (`breakerBuckets`, four day buckets),
/// the path TRIPS: no claim on it runs (receipts, instant mints and queueing go on) until the timelock's RESET_BREAKER
/// (48h) names that trip; the governor may also trip it instantly. Any HOLD_TIME span of queue times lies inside one such
/// window, so with no human action a forged stream makes at most B spendable through claims in any 72 h, on top of the
/// instant 4C. A tripped path loses no claim (no expiry).
/// GOVERNABLE PER PATH (no bound on the cap or the breaker: millions in volume a day). C, D and B are
/// per-path values (`instantIn.capSD`, `breakers.delay`, `breakers.breakerSD`). A path's first SET_PATH writes the launch
/// values (DEFAULT_*: C 5,000/day, D 12h, B 50,000), so no open path is ever without a delay; SET_DELAY (48h) sets any C
/// and B the 64-bit shared-decimals fields hold (~1.8e13 imdUSD) and D within [MIN_DELAY 1h, MAX_DELAY 7d] (a zero delay
/// would remove the Safe's window). LOOSENING (raise C or B, shorten D) only through the timelock; TIGHTENING (lower C or
/// B, lengthen D) also instantly by the governor (`tighten`), which bumps the path's settings version: a SET_DELAY
/// names the version it was proposed against, so one proposed before a tightening is refused when applied. A claim is claimable at queuedAt + the path's D AT CLAIM TIME: a
/// lengthening applies to claims already queued (it never shortens a wait), and a shortening, being timelocked, applies
/// to them only after 48h. A lowered C stops instant mints at once (what was used still counts). NOTHING THAT UNBLOCKS A
/// PACKET FREES INSTANT ROOM (audit wave 5; a review before wave 5b: the class, by lzReceive's revert reasons): every path-level block is
/// lifted only by a timelocked path act, and each of them restarts the allowance EMPTY (refilling at C per day): UNPAUSE
/// (PathPaused), ANY SET_PATH on a set path (OnlyPeer; RateLimited at a closed, lowered or shortened limit), a SET_DELAY
/// raising C (the cap); every payload-level block is a Safe act, and a payload the Safe held (at its expiry or RELEASE)
/// or voided (after UNVOID) always QUEUES for D, never mints at once. So in the t after any change that unblocks a packet
/// at most C x t / 1 day mints at once. The TOKEN's block (a review before wave 5b: ImdUSD.mint refuses the bridge until Parameters'
/// SET_BRIDGE applies) is lifted by another contract's act, so the meter does not START until the token has accepted this
/// bridge: a meter not started is EMPTY, and it starts empty at the first act or message after acceptance (until then a
/// message queues, and claims revert in the mint), whatever the order of SET_BRIDGE and the path. Not a block:
/// RateLimited at an unchanged limit (the limiter's own refill: the
/// instant cap's normal rate applies); Unconfigured cannot return after launch; ZeroAmount/BelowMinimum never pass. `tighten` never reverts on a set path (audit wave 5): each field lands at the tighter of its argument and what stands,
/// so no one can make the Safe's signed act fail by applying a matured SET_DELAY first; a breaker lowered below what its
/// window holds trips the path (audit wave 5). The window counts what QUEUED, cancelled claims included (a cancel refunds
/// nothing, like the inbound limit), so a lowered B may trip on claims the Safe already cancelled (a review of the wave-5 fixes).
/// INCIDENT ACTS NEVER REVERT ON A STRANGER (a review of the wave-5 fixes): `pause`, `tighten`, `tripBreaker`, `voidPayload`, `cancel`
/// (nothing pending), `cancelClaim` (claim no longer pending) and `hold` (nonce executed, empty or held before) all land
/// whatever another account did first, so the Safe may batch them in one MultiSend; read the events to see what each did.
/// BULK CANCEL. A compromised DVN set signs any number of forged messages; cancelling them one by one
/// costs the Safe a transaction per claim. A per-path cutoff (`breakers.cancelledFrom`, set by `tighten`, instant) cancels
/// in O(1) every pending claim queued at or after it, and every claim queued later (checked at claim time). Nothing is
/// lost: the claims stay pending (and in `queued`); a timelocked SET_DELAY (48h) lifts the cutoff or moves it later,
/// after the Safe has cancelled the forged ones one by one at leisure (or paused the path). The instant route only moves
/// the cutoff earlier, and bumps the settings version, so a pending SET_DELAY is refused when applied.
/// AT THE LAUNCH VALUES: no human action over a 72 h weekend, 4C + B = 20,000 + 50,000 = 70,000, ABOVE the 4663 chain line
/// (30,000), accepted for whales; the bound that holds the line is the Safe acting within D (12h),
/// which cancels every queued forgery before it matures, leaving only the instant part, C x (1 + D / 1 day) = 7,500 <=
/// 30,000, PROVIDED the Safe also does the void sweep before any reopening (a review before wave 5b; without it each reopening adds up
/// to C x (1 + D' / 1 day), D' = its time to answer the first forged Received after the reopening). The breaker is the
/// backstop for a Safe that takes longer, not the line's guarantee; a larger C or B, or a shorter D, widens both bounds
/// (the Safe decides it in public, 48h ahead).
///
/// FEE. Per destination, `feeBps[eid]` of each send (0 until the timelock sets it, at most MAX_FEE_BPS).
/// The sender is burned the whole amount; the destination receives the amount less the fee (and less the dust below 1e-6
/// the fee leaves); the fee is minted here to the Treasury. `sent` counts only what is delivered, so the fee never leaves
/// the chain and the supply equation below is unchanged.
///
/// SUPPLY. `received` (minted here, at receipt or at claim) and `sent` (burned here, net of the fee re-minted to the
/// Treasury) are cumulative, so on each chain (a queued claim is not supply until claimed: `queued` counts what waits)
///   token.totalSupply() == Σ debt + Σ bad debt + reserveBacked + migrated + keeper + received − sent.
contract ImdBridge is Governed, TransientReentrancyGuard {
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    /// @dev A hold on one inbound nonce: the endpoint's payload hash when it was placed, and when it ends (0 = never held;
    /// after a RELEASE, 1 with the released hash).
    struct HoldRecord {
        bytes32 payloadHash;
        uint64 until;
    }

    /// @dev A queued inbound transfer (one slot): amount in shared decimals (<= MAX_LIMIT / 1e12 < 2^48: it passed the
    /// inbound limit), when it was queued, and its state (CLAIM_*). Claimable from queuedAt + the path's delay AT CLAIM TIME
    /// (the delay is governable; a change applies to pending claims too, see `Breaker.delay`).
    struct Claim {
        address to;
        uint48 amountSD;
        uint40 queuedAt;
        uint8 state;
    }

    /// @dev What minted at once on a path, decaying at the path's instant cap per INSTANT_WINDOW, and that cap (shared
    /// decimals: up to 2^64 / 1e6 ~ 1.8e13 imdUSD). One slot, the one lzReceive reads for every message.
    struct Meter {
        uint128 used;
        uint64 lastUpdated;
        uint64 capSD;
    }

    /// @dev A path's delay settings and queue breaker state (one slot; claim reads it): the last UTC day the queue was
    /// counted, the trip counter and state, the breaker (shared decimals, up to ~1.8e13 imdUSD), the claim delay (seconds),
    /// the bulk-cancel cutoff (0 = none), and the version of these settings: every instant tightening bumps it, and a
    /// timelocked loosening names the version it was proposed against, so one proposed before a tightening can never apply
    /// after it. The day buckets live in `breakerBuckets`.
    struct Breaker {
        uint40 day;
        uint16 trips;
        bool tripped;
        uint64 breakerSD;
        uint32 delay;
        uint40 cancelledFrom;
        uint16 version;
    }

    struct Limit {
        uint128 limit; // most in any window; 0 = closed
        uint32 window; // seconds
        uint128 inFlight; // at `lastUpdated`, decays at limit/window per second
        uint64 lastUpdated;
    }

    uint8 internal constant SET_PATH = 1; // (eid, peer, outLimit, outWindow, inLimit, inWindow, enforcedOptions)
    uint8 internal constant SET_CONFIG = 2; // (lib, SetConfigParam[])
    uint8 internal constant SET_SEND_LIBRARY = 3; // (eid, lib)
    uint8 internal constant SET_RECEIVE_LIBRARY = 4; // (eid, lib, gracePeriod)
    uint8 internal constant UNPAUSE = 5; // (eid): a paused path only (a review of the wave-5 fixes)
    uint8 internal constant BATCH = 6; // (bytes[] payloads), none of them a BATCH
    uint8 internal constant SET_FEE = 7; // (eid, bps)
    /// @notice Endpoint channel acts for a PAUSED path: drop a verified inbound payload so it can never execute.
    /// Validated against EndpointV2's state at proposal and at application (audit wave 4): SKIP only the first nonce with no
    /// payload; BURN only a stored payload at or below lazyInboundNonce (the head nonce of a paused path is NOT burnable:
    /// `voidPayload` refuses it here for good instead), and a NIL one also on an open path.
    uint8 internal constant ENDPOINT_SKIP = 8; // (srcEid, sender, nonce): skip a nonce that was never verified
    /// Never needed to stop a forgery (`hold`/`voidPayload` do, keeping the endpoint's proof): clean-ups only.
    uint8 internal constant ENDPOINT_NILIFY = 9; // (srcEid, sender, nonce, payloadHash): void a verified payload (re-verifiable)
    uint8 internal constant ENDPOINT_BURN = 10; // (srcEid, sender, nonce, payloadHash): void it for good
    /// @notice Lift the bridge's void on a payload hash (audit wave 4): an honest payload voided by mistake.
    uint8 internal constant UNVOID = 11; // (payloadHash)
    /// @notice End a hold before HOLD_TIME, or let through a payload other than the one held: the held
    /// nonce then runs only with `payloadHash` (and never anything else), as a claim. `payloadHash` 0 DROPS the held payload
    /// (a review before wave 5b): it never runs at that nonce, and any other payload verified there later does (the response to a forged
    /// replay of an honest payload: a void by hash would refuse the honest twin too).
    uint8 internal constant RELEASE = 12; // (srcEid, sender, nonce, payloadHash)
    /// @notice Restore a claim the governor cancelled: pending again, claimable at queuedAt + the path's
    /// delay (usually long run). No early release exists: a claim waits its delay or this 48h timelock. Applied only to a
    /// claim still cancelled (a repeat in one BATCH does nothing; audit wave 5).
    uint8 internal constant UNCANCEL = 13; // (srcEid, guid)
    /// @notice Release a tripped queue breaker: claims on the path run again and its day buckets restart
    /// at zero. Names the trip (`trips` when it tripped), so a reset proposed before a trip can never release a later one.
    /// Accepted only on a PAUSED path, at proposal and at application (audit wave 5): nothing queues unseen between the
    /// Safe's last cancelClaim and the reset, and what runs after the reopening counts in the fresh window. Procedure:
    /// pause, cancel the forged claims, propose BATCH[RESET_BREAKER, UNPAUSE] (one 48h wait).
    uint8 internal constant RESET_BREAKER = 14; // (srcEid, trip)
    /// @notice Set a path's inbound delay settings (governable per path, no bound on the cap or the
    /// breaker, the delay within [MIN_DELAY, MAX_DELAY]) and its bulk-cancel cutoff (0 = none): any direction, through the
    /// 48h timelock, naming the settings version it was proposed against. Tightening also has an instant governor route,
    /// `tighten`. Amounts in 18 decimals, whole multiples of 1e12 (shared decimals). Lifting or moving the cutoff later
    /// RESTORES the claims it held (claims the governor cancelled one by one stay cancelled: UNCANCEL each).
    uint8 internal constant SET_DELAY = 15; // (srcEid, instantCap, delay, queueBreaker, cancelFrom, version)

    /// @notice Highest per-path limit (for millions a day): 250,000,000 imdUSD per window, so a message
    /// (<= the inbound limit) always fits a claim's 48-bit shared-decimals amount (2^48 / 1e6 ~ 281,474,976 imdUSD).
    uint256 internal constant MAX_LIMIT = 250_000_000e18;
    /// @notice How long a `hold` refuses a message: long enough for the Safe's signers to meet over a weekend
    /// and void a forgery for good; the honest message then runs by itself. Constant: no act can lengthen a hold.
    uint256 internal constant HOLD_TIME = 72 hours;
    /// @notice The launch values of a path's delay settings, written at its first SET_PATH so no
    /// open path is ever without a delay; SET_DELAY (48h) and `tighten` (instant) change them per path afterwards.
    /// Instant cap: most imdUSD a path mints at once per INSTANT_WINDOW (decaying), so the largest single message that can
    /// (Wormhole Governor); the rest waits the delay as a claim.
    uint256 public constant DEFAULT_INSTANT_CAP = 5_000e18;
    uint256 internal constant INSTANT_WINDOW = 1 days;
    /// @notice Claim delay: how long a queued inbound transfer waits before anyone may claim it, the Safe's window to pause
    /// the path or cancel a forgery before it is spendable.
    uint256 public constant DEFAULT_DELAY = 12 hours;
    /// @notice Queue breaker: most imdUSD a path may queue within its breaker window (the current UTC day and the
    /// BREAKER_DAYS - 1 before) before its claims stop (raised 10,000 -> 50,000 for whales): with the
    /// instant 4 x cap a 72 h no-action weekend can lose 70,000, above the 4663 chain line (30,000) by decision; the line
    /// holds only if the Safe acts within the delay.
    uint256 public constant DEFAULT_QUEUE_BREAKER = 50_000e18;
    /// @notice Bounds on a path's claim delay: a zero delay would remove the Safe's window; 7 days caps how
    /// long honest transfers can be made to wait. No bound on the cap or the breaker beyond their 64-bit shared-decimals
    /// fields (~1.8e13 imdUSD).
    uint256 internal constant MIN_DELAY = 1 hours;
    uint256 internal constant MAX_DELAY = 7 days;
    /// @notice The breaker window in UTC days: any HOLD_TIME (72 h) span of queue times falls inside BREAKER_DAYS days.
    uint256 internal constant BREAKER_DAYS = 4;
    uint8 internal constant CLAIM_PENDING = 1;
    uint8 internal constant CLAIM_CLAIMED = 2;
    uint8 internal constant CLAIM_CANCELLED = 3;
    uint256 internal constant MIN_WINDOW = 1 hours;
    uint256 internal constant MAX_WINDOW = 7 days;
    /// @notice The least a send delivers and an inbound message may carry (audit wave 4): a forged dust packet
    /// reverts instead of consuming an honest nonce, and at most 2 x limit / MIN_AMOUNT nonces per window can be consumed.
    uint256 internal constant MIN_AMOUNT = 10e18;
    /// @notice Most blocks the OLD receive library keeps verifying after a SET_RECEIVE_LIBRARY (audit wave 4): ~7 days of
    /// Ethereum blocks (far less on a fast chain, which only shortens it).
    uint256 internal constant MAX_RECEIVE_GRACE = 50_400;
    uint8 internal constant SHARED_DECIMALS = 6;
    uint256 internal constant CONVERSION = 1e12; // 18 local decimals -> 6 shared
    /// @notice Highest per-destination fee: 0.25%, the peg pools' no-surcharge band. A larger fee would let one chain's
    /// price sit outside the band before moving imdUSD between chains pays, so the bridge would stop tying the pegs together.
    uint256 internal constant MAX_FEE_BPS = 25;
    /// @notice Least required DVNs on any ULN config (3, following LayerZero's post-Kelp
    /// guidance): the launch set is LayerZero Labs + Twinstake + P2P, so no single operator (LayerZero's own included) is
    /// one of only two. Raising it is a redeploy of the bridge.
    uint8 public constant MIN_REQUIRED_DVNS = 3;
    /// @notice Least block confirmations by SOURCE chain. Ethereum: 15 = LayerZero's default for Ethereum and
    /// the IMD OFT's mainnet -> 4663 value (~3 min; a deeper reorg is bounded by the 4663 inbound limit). Any other source
    /// (4663, an Arbitrum Orbit chain with one sequencer): 20 = LayerZero's default for Arbitrum-family sources; the IMD OFT's
    /// 5 is ~1-2 s of soft confirmations.
    uint64 internal constant MIN_CONFIRMATIONS_FROM_ETHEREUM = 15;
    /// @dev A block count, not time (audit wave 4, info): on 4663 (~0.1-0.25 s blocks, one sequencer) 20 is a few seconds of soft
    /// confirmations before batch posting; a sequencer reorg deeper than that after the DVNs sign leaves a mint on Ethereum
    /// whose burn is gone, bounded by Ethereum's inbound limit from 4663 (2 x 10,000 per window).
    uint64 internal constant MIN_CONFIRMATIONS_FROM_OTHER = 20;
    uint32 internal constant ETHEREUM_EID = 30101;
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN = 2;
    uint8 internal constant NIL_DVN_COUNT = 255;
    /// @dev EndpointV2's NIL payload hash (a nilified nonce).
    bytes32 internal constant NIL_PAYLOAD_HASH = bytes32(type(uint256).max);

    ILayerZeroEndpointV2 public immutable endpoint;
    IMintableBurnable public immutable minterBurner;
    /// @notice Where the per-destination fee is minted (this chain's Treasury).
    address public immutable treasury;
    /// @dev This chain's eid and this bridge as bytes32: the receiver half of an inbound GUID.
    uint32 internal immutable localEid;

    mapping(uint32 eid => bytes32) public peers;
    mapping(uint32 eid => bytes) public enforcedOptions;
    mapping(uint32 eid => bool) public paused;
    mapping(uint32 eid => Limit) public outbound;
    mapping(uint32 eid => Limit) public inbound;
    mapping(uint32 eid => uint16) public feeBps;
    /// @notice The library pinned for each path; zero until the launch BATCH pins it.
    mapping(uint32 eid => address) public sendLibrary;
    mapping(uint32 eid => address) public receiveLibrary;

    /// @notice A floor-checked ULN config this OApp set on `lib` for `eid` (audit wave 4). Set by SET_CONFIG, never cleared:
    /// the endpoint keeps an OApp's config per (lib, eid) for good, and only a checked one can be set.
    mapping(address lib => mapping(uint32 eid => bool)) public configured;
    /// @notice Payload hashes (keccak256(guid ‖ message), EndpointV2's) voided by `voidPayload`, ENDPOINT_NILIFY or
    /// ENDPOINT_BURN: never executed here until UNVOID (audit wave 4).
    mapping(bytes32 payloadHash => bool) public voided;
    /// @dev Payload hashes an UNVOID lifted (a review before wave 5b): such a payload queues for D when it runs, never mints at once.
    mapping(bytes32 payloadHash => bool) internal unvoided;
    /// @notice Holds by path (srcEid, sender = the peer when placed) and nonce; at most one per nonce, ever.
    mapping(uint32 srcEid => mapping(bytes32 sender => mapping(uint64 nonce => HoldRecord))) public holds;
    /// @notice The receive library still valid at the endpoint after a re-pin with grace, and the block it stops (audit wave 4).
    mapping(uint32 eid => address) public receiveGraceLibrary;
    mapping(uint32 eid => uint256) public receiveGraceUntil;

    /// @notice Cumulative imdUSD minted by inbound messages / burned by sends, here.
    uint256 public received;
    uint256 public sent;
    /// @notice Cumulative fee minted to the Treasury.
    uint256 public fees;
    /// @notice Queued inbound transfers by source path and GUID.
    mapping(uint32 srcEid => mapping(bytes32 guid => Claim)) public claims;
    /// @notice What each path minted at once, and its instant cap.
    mapping(uint32 srcEid => Meter) public instantIn;
    /// @notice imdUSD waiting in pending claims (received, metered, not yet minted): in flight for the cross-chain supply.
    uint256 public queued;
    /// @notice Each path's delay settings and queue breaker.
    mapping(uint32 srcEid => Breaker) public breakers;
    /// @notice Each path's breaker day buckets: imdUSD queued (shared decimals, 63 bits each: a day's queue at MAX_LIMIT on
    /// a 1 h window is ~6.25e15 < 2^63) per UTC day, bucket day % BREAKER_DAYS at bit 63 x bucket; bit 255 is a sentinel,
    /// set at SET_PATH and kept by RESET_BREAKER, so a queued message never pays a zero-to-nonzero write.
    mapping(uint32 srcEid => uint256) public breakerBuckets;

    error OnlyEndpoint();
    error OnlyPeer(uint32 eid, bytes32 sender);
    error NoPeer(uint32 eid);
    error PathPaused(uint32 eid);
    error RateLimited(uint32 eid, uint256 amount, uint256 available);
    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error ComposeUnsupported();
    error LzTokenUnsupported();
    error BadPayload();
    error OutOfBounds();
    error UnpinnedLibrary(uint32 eid, address lib);
    /// @notice A SET_CONFIG param below the floors. reason: 1 config type (unknown, or executor on a receive library),
    /// 2 zero executor, 3 required DVN count < MIN_REQUIRED_DVNS or NIL, 4 DVN list length != count, 5 a DVN list not strictly
    /// ascending (zero, repeated or unsorted), 6 confirmations below the source's floor (or NIL), 7 optional DVNs: count 0
    /// (= LayerZero's default set), NIL with a list or threshold, or a count/threshold that does not match the list.
    error WeakConfig(uint8 reason);
    error PathOpen(uint32 eid);
    error NotEnoughNative(uint256 msgValue);
    error ZeroAmount();
    error BelowMinimum(uint256 amount, uint256 minimum);
    /// @notice A path whose send or receive library is not pinned with this OApp's own checked ULN config (audit wave 4).
    error Unconfigured(uint32 eid);
    error PayloadVoided(bytes32 payloadHash);
    /// @notice An ENDPOINT_SKIP/NILIFY/BURN that EndpointV2 would refuse in its current state (audit wave 4).
    error InfeasibleEndpointAct();
    /// @notice UNPAUSE in one BATCH with a path, library or config change for the same eid (audit wave 4).
    error UnpauseWithChange(uint32 eid);
    /// @notice UNPAUSE while an old receive library can still verify for the path (audit wave 4).
    error GraceRunning(uint32 eid, uint256 untilBlock);
    error DuplicateInBatch(uint8 kind, uint32 eid);
    error SameLibrary(uint32 eid, address lib);
    /// @notice The message at (srcEid, nonce) is held until `until` (or for good, if the endpoint's payload changed).
    error OnHold(uint32 srcEid, uint64 nonce, uint256 until);
    /// @notice No pending claim there (none, claimed or cancelled), or not yet claimable (`claimableAt` in the future).
    error NotClaimable(uint32 srcEid, bytes32 guid, uint256 claimableAt);
    /// @notice The path's queue breaker is tripped: claims wait for RESET_BREAKER.
    error Tripped(uint32 srcEid);
    /// @notice `tighten` on a path whose settings were never set (audit wave 5); otherwise it clamps, never reverts (audit wave 5).
    error NotTighter();
    /// @notice The claim was queued at or after the path's bulk-cancel cutoff: it waits for a timelocked SET_DELAY that
    /// lifts the cutoff or moves it later.
    error CancelledSince(uint32 srcEid, uint256 cutoff);

    /// @dev Both carry the path nonce (audit wave 4): the watcher matches a `Received` here to the peer's `Sent` by nonce (and
    /// guid); a Received nonce the peer never sent is a forgery, and the response is pausing the SOURCE path as well.
    event Sent(bytes32 indexed guid, uint32 indexed dstEid, address indexed from, bytes32 to, uint256 amount, uint64 nonce);
    event Received(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount, uint64 nonce);
    event PathSet(uint32 indexed eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow);
    event Paused(uint32 indexed eid, address by);
    event Unpaused(uint32 indexed eid);
    event FeeSet(uint32 indexed eid, uint256 bps);
    /// @dev kind 0 = the governor's instant `voidPayload` (no nonce: the hash is voided wherever it is verified).
    event Voided(uint8 indexed kind, uint32 indexed srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash);
    event Unvoided(bytes32 indexed payloadHash);
    event HoldPlaced(uint32 indexed srcEid, bytes32 sender, uint64 indexed nonce, bytes32 payloadHash, uint256 until);
    event HoldReleased(uint32 indexed srcEid, bytes32 sender, uint64 indexed nonce, bytes32 payloadHash);
    /// @dev An inbound transfer received (metered) but not minted: claimable by anyone after `claimableAt`.
    event Queued(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount, uint64 nonce, uint256 claimableAt);
    event Claimed(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount);
    /// @dev Not `Cancelled`: Governed's proposal event has that name.
    event ClaimCancelled(bytes32 indexed guid, uint32 indexed srcEid);
    event ClaimRestored(bytes32 indexed guid, uint32 indexed srcEid);
    /// @dev `by` = this bridge when the queue (or a breaker lowered below it, audit wave 5) tripped it, the governor otherwise;
    /// `trip` names it for RESET_BREAKER.
    event BreakerTripped(uint32 indexed srcEid, uint256 trip, address by);
    event BreakerReset(uint32 indexed srcEid, uint256 trip);
    /// @dev A path's delay settings changed (SET_DELAY, `tighten`, or the launch values at its first SET_PATH). `cancelFrom`
    /// is the bulk-cancel cutoff: every claim on the path queued at or after it (and every one queued later) is cancelled
    /// until a SET_DELAY lifts it (0 = none).
    event DelaySet(uint32 indexed srcEid, uint256 instantCap, uint256 delay, uint256 queueBreaker, uint256 cancelFrom);

    constructor(ILayerZeroEndpointV2 endpoint_, IMintableBurnable token_, address governor_, address treasury_)
        Governed(governor_)
    {
        if (address(endpoint_).code.length == 0 || address(token_).code.length == 0 || treasury_ == address(0)) {
            revert BadPayload();
        }
        endpoint = endpoint_;
        minterBurner = token_;
        treasury = treasury_;
        localEid = endpoint_.eid();
    }

    // ================================================================ OFT surface

    function token() external view returns (address) {
        return address(minterBurner);
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    /// @notice OFT's interface id and version (MintBurnOFTAdapter reports the same).
    function oftVersion() external pure returns (bytes4, uint64) {
        return (0x02e49c2c, 1);
    }

    function oAppVersion() external pure returns (uint64 senderVersion, uint64 receiverVersion) {
        return (1, 2);
    }

    /// @notice The endpoint fee for a send of `p`.
    function quoteSend(SendParam calldata p, bool payInLzToken) external view returns (MessagingFee memory) {
        if (payInLzToken) revert LzTokenUnsupported();
        (, uint256 delivered) = _split(p.dstEid, p.amountLD);
        (bytes memory message, bytes memory options) = _build(p, delivered);
        return endpoint.quote(MessagingParams(p.dstEid, _peer(p.dstEid), message, options, false), address(this));
    }

    /// @notice What a send of `amountLD` to `dstEid` burns from the sender and delivers (OFT's `quoteOFT` receipt).
    function quoteOFT(SendParam calldata p) external view returns (OFTReceipt memory) {
        (uint256 burned, uint256 delivered) = _split(p.dstEid, p.amountLD);
        return OFTReceipt(burned, delivered);
    }

    /// @notice Burn `amountLD` (less dust below 1e-6) from the caller and send it, less the destination's fee, to `p.to` on
    /// `p.dstEid`. `minAmountLD` bounds what is delivered.
    function send(SendParam calldata p, MessagingFee calldata fee, address refundAddress)
        external
        payable
        nonReentrant
        returns (MessagingReceipt memory receipt, OFTReceipt memory oft)
    {
        if (fee.lzTokenFee != 0) revert LzTokenUnsupported();
        // exactly the declared fee (OAppSender's rule), so nothing is stranded here for the next sender to spend
        if (msg.value != fee.nativeFee) revert NotEnoughNative(msg.value);
        if (paused[p.dstEid]) revert PathPaused(p.dstEid);
        if (!configured[sendLibrary[p.dstEid]][p.dstEid]) revert Unconfigured(p.dstEid);
        (uint256 amount, uint256 delivered) = _split(p.dstEid, p.amountLD);
        if (delivered == 0) revert ZeroAmount(); // a zero send is log spam and used to snap the window
        if (delivered < MIN_AMOUNT) revert BelowMinimum(delivered, MIN_AMOUNT);
        if (delivered < p.minAmountLD) revert SlippageExceeded(delivered, p.minAmountLD);
        _consume(outbound[p.dstEid], p.dstEid, delivered);
        sent += delivered;
        minterBurner.burn(msg.sender, amount);
        if (amount != delivered) {
            fees += amount - delivered;
            minterBurner.mint(treasury, amount - delivered);
        }
        (bytes memory message, bytes memory options) = _build(p, delivered);
        receipt = endpoint.send{value: fee.nativeFee}(
            MessagingParams(p.dstEid, _peer(p.dstEid), message, options, false), refundAddress
        );
        oft = OFTReceipt(amount, delivered);
        emit Sent(receipt.guid, p.dstEid, msg.sender, p.to, delivered, receipt.nonce);
    }

    // ================================================================ OApp receiver surface

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return peers[origin.srcEid] == origin.sender && origin.sender != bytes32(0);
    }

    /// @notice Unordered delivery (OApp default).
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    /// @notice The endpoint delivers a verified packet. Reverting leaves it stored at the endpoint, retryable.
    /// @dev Payable as OApp's receiver is; native value an executor forwards (a sender's lzReceive value option) stays here
    /// with no way out (audit wave 4, info: dust; `send` never spends it).
    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        bytes32 peer = peers[origin.srcEid];
        if (peer == bytes32(0) || peer != origin.sender) revert OnlyPeer(origin.srcEid, origin.sender);
        if (paused[origin.srcEid]) revert PathPaused(origin.srcEid);
        // a packet verified under anything but this OApp's own config stays at the endpoint (audit wave 4)
        if (!configured[receiveLibrary[origin.srcEid]][origin.srcEid]) revert Unconfigured(origin.srcEid);
        // audit wave 4: a voided payload never executes, even after the DVNs verify it again over the endpoint's NIL
        bytes32 payloadHash = keccak256(abi.encodePacked(guid, message));
        if (voided[payloadHash]) revert PayloadVoided(payloadHash);
        // a held nonce waits out HOLD_TIME, and then runs only with the payload that was held (or released)
        HoldRecord storage hd = holds[origin.srcEid][origin.sender][origin.nonce];
        uint64 until = hd.until;
        // a review before wave 5b: until == 2 is a DROP (RELEASE with hash 0): only the held payload is refused there, any other runs
        if (until != 0 && (until == 2 ? hd.payloadHash == payloadHash : block.timestamp < until || hd.payloadHash != payloadHash)) {
            revert OnHold(origin.srcEid, origin.nonce, until);
        }
        uint256 amount = uint256(message.amountSD()) * CONVERSION;
        // audit wave 4: a zero-amount message never executes (no peer of ours sends one), so it consumes no honest nonce
        if (amount == 0) revert ZeroAmount();
        // A peer of ours never sends under MIN_AMOUNT, so a smaller message is forged: it reverts and consumes no nonce.
        if (amount < MIN_AMOUNT) revert BelowMinimum(amount, MIN_AMOUNT);
        _consume(inbound[origin.srcEid], origin.srcEid, amount);
        address to = message.sendTo().bytes32ToAddress();
        if (to == address(0)) to = address(0xdead); // OFT's rule: _mint(0) is not allowed
        // what does not fit the path's instant allowance waits the path's delay as a claim
        Meter storage mt = instantIn[origin.srcEid];
        (uint256 used, uint256 capSD) = _instantUsed(mt);
        // a review before wave 5b: the meter STARTS, empty, at the first message the path receives once the token has accepted this bridge
        // (SET_BRIDGE applied), so whatever the order of SET_BRIDGE and the path, nothing mints at once before C x t / 1
        // day has refilled since the path could first mint; until then everything queues (and claims revert in mint)
        if (mt.lastUpdated == 0 && _accepted()) (mt.used, mt.lastUpdated) = (uint128(capSD * CONVERSION), uint64(block.timestamp));
        // a review before wave 5b: a payload the Safe blocked (held, at its expiry or RELEASE, or voided then UNVOIDed) never mints at once
        if (used + amount > capSD * CONVERSION || until != 0 || unvoided[payloadHash]) {
            _queue(origin, to, amount);
            return;
        }
        (mt.used, mt.lastUpdated) = (uint128(used + amount), uint64(block.timestamp));
        received += amount;
        // A compose payload (our peers never send one) is ignored: the tokens are credited, nothing is called.
        minterBurner.mint(to, amount);
        emit Received(guid, origin.srcEid, to, amount, origin.nonce);
    }

    // ================================================================ delayed inbound transfers

    /// @notice Mint a queued transfer to its recipient once the path's delay has run since it queued (anyone).
    /// Refused while the path is paused or tripped or the claim was cancelled; never expires.
    function claim(uint32 srcEid, bytes32 guid) external nonReentrant {
        Claim storage c = claims[srcEid][guid];
        Breaker storage b = breakers[srcEid];
        uint256 at = uint256(c.queuedAt) + b.delay;
        if (c.state != CLAIM_PENDING || block.timestamp < at) revert NotClaimable(srcEid, guid, at);
        if (paused[srcEid]) revert PathPaused(srcEid);
        if (b.tripped) revert Tripped(srcEid);
        uint256 cut = b.cancelledFrom;
        if (cut != 0 && c.queuedAt >= cut) revert CancelledSince(srcEid, cut);
        c.state = CLAIM_CLAIMED;
        (address to, uint256 amount) = (c.to, uint256(c.amountSD) * CONVERSION);
        queued -= amount;
        received += amount;
        minterBurner.mint(to, amount);
        emit Claimed(guid, srcEid, to, amount);
    }

    /// @notice Refuse a pending claim (governor, instant): it never mints until the timelock's UNCANCEL.
    /// A claim that is not pending (claimed by anyone, already cancelled, or none) is left as it is, without a revert
    /// (a review of the wave-5 fixes): a stranger's claim just before cannot revert the Safe's incident batch [cancelClaim, pause].
    function cancelClaim(uint32 srcEid, bytes32 guid) external onlyGovernor {
        Claim storage c = claims[srcEid][guid];
        if (c.state != CLAIM_PENDING) return;
        c.state = CLAIM_CANCELLED;
        queued -= uint256(c.amountSD) * CONVERSION;
        emit ClaimCancelled(guid, srcEid);
    }

    /// @notice What `srcEid` may still mint at once now; a message larger than this is queued.
    /// @notice Trip a path's queue breaker now (governor, instant): it only stops claims; RESET_BREAKER (48h) releases.
    function tripBreaker(uint32 srcEid) external onlyGovernor {
        Breaker storage b = breakers[srcEid];
        if (!b.tripped) _trip(b, srcEid, msg.sender);
    }

    function availableInstant(uint32 srcEid) external view returns (uint256) {
        (uint256 used, uint256 capSD) = _instantUsed(instantIn[srcEid]);
        uint256 cap = capSD * CONVERSION;
        return cap > used ? cap - used : 0;
    }

    /// @notice Tighten a path's delay settings now (governor, instant, like pause/hold). Each field lands at
    /// the TIGHTER of what it names and what stands (audit wave 5): the lower cap and breaker, the longer delay (at most
    /// MAX_DELAY), the earlier non-zero bulk-cancel cutoff. It never reverts on a path whose settings exist, so nobody can
    /// make the Safe's signed act fail by applying a matured SET_DELAY just before it (applyPending is permissionless).
    /// A longer delay applies to the claims already queued too (they become claimable at queuedAt + the new delay).
    /// BULK CANCEL: `cancelFrom` = T cancels, in O(1), EVERY pending claim on the path queued at or after T and every claim
    /// queued later (checked at claim time; they stay pending and in `queued`, never lost, until a SET_DELAY lifts the
    /// cutoff or moves it later). Bumps the path's settings version, so a SET_DELAY proposed before (naming the old
    /// version) is refused when applied: it cannot undo the tightening. Refused (NotTighter) only on a path whose settings
    /// were never set (audit wave 5): an instant act never writes settings a timelocked one could not. The clamp is SILENT
    /// (a review of the wave-5 fixes): an argument looser than what stands (a wrong one too) is replaced without a revert, so read the
    /// values that landed back from the `DelaySet` event (or `instantIn` / `breakers`).
    function tighten(uint32 srcEid, uint256 instantCap, uint256 delay, uint256 queueBreaker, uint40 cancelFrom)
        external
        onlyGovernor
    {
        Breaker storage b = breakers[srcEid];
        // audit wave 5: a path never set has no settings to tighten (its first SET_PATH writes the launch values)
        if (b.delay == 0) revert NotTighter();
        uint256 v = uint256(instantIn[srcEid].capSD) * CONVERSION;
        if (instantCap > v) instantCap = v;
        v = uint256(b.breakerSD) * CONVERSION;
        if (queueBreaker > v) queueBreaker = v;
        if (delay > MAX_DELAY) delay = MAX_DELAY;
        if (delay < b.delay) delay = b.delay;
        uint40 cut = b.cancelledFrom;
        if (cut != 0 && (cancelFrom == 0 || cancelFrom > cut)) cancelFrom = cut;
        ++b.version;
        _setDelay(srcEid, instantCap, delay, queueBreaker, cancelFrom);
    }

    // ================================================================ limits, pause

    /// @notice What may be sent to (or received from) `eid` right now.
    function availableOut(uint32 eid) external view returns (uint256) {
        return _available(outbound[eid]);
    }

    function availableIn(uint32 eid) external view returns (uint256) {
        return _available(inbound[eid]);
    }

    /// @notice Net imdUSD this bridge has put into circulation on this chain: received − sent (the supply equation's term).
    /// It counts a forged mint like an honest one, so the per-chain supply equation still holds after a forgery: it cannot
    /// detect one (audit wave 4). Detection is CROSS-CHAIN: received here (per nonce, `Received`) <= sent at the peer (`Sent`)
    /// plus what is in flight.
    function netMinted() external view returns (int256) {
        return int256(received) - int256(sent);
    }

    /// @notice Close a path now (governor only; no guardian). Only the timelock's UNPAUSE reopens it.
    function pause(uint32 eid) external onlyGovernor {
        paused[eid] = true;
        emit Paused(eid, msg.sender);
    }

    /// @notice Hold the inbound message the endpoint stores at `nonce` from `srcEid`'s peer for HOLD_TIME (governor, instant;
    /// no guardian). Binds the stored payload hash; nothing at the endpoint changes, so the DVNs' proof is kept and the
    /// message runs for anyone once the hold ends, if the endpoint still stores that hash. Once per nonce, ever.
    function hold(uint32 srcEid, uint64 nonce) external onlyGovernor {
        bytes32 sender = peers[srcEid];
        HoldRecord storage h = holds[srcEid][sender][nonce];
        // a review of the wave-5 fixes: a nonce held before, or with nothing executable stored (executed by anyone, empty, NIL, no peer),
        // is left as it is without a revert, so a stranger's execute cannot revert the Safe's batch [hold, pause]; the
        // HoldPlaced event is the Safe's confirmation that a hold was placed
        if (h.until != 0) return;
        bytes32 stored = endpoint.inboundPayloadHash(address(this), srcEid, sender, nonce);
        if (sender == bytes32(0) || stored == bytes32(0) || stored == NIL_PAYLOAD_HASH) return;
        uint64 until = uint64(block.timestamp + HOLD_TIME);
        (h.payloadHash, h.until) = (stored, until);
        emit HoldPlaced(srcEid, sender, nonce, stored, until);
    }

    /// @notice Refuse `payloadHash` here for good (governor, instant), whatever the endpoint or the DVNs
    /// hold later. Only the timelock's UNVOID lifts it; the endpoint keeps the packet, so an honest one then runs as it is.
    /// The void is by hash on every path and nonce (audit wave 5): a forged REPLAY of an honest (guid, message) at another
    /// nonce has the honest message's hash, so voiding it refuses the honest one too. For a replay use the nonce-scoped
    /// DROP instead (a review before wave 5b): `hold(srcEid, forgedNonce)`, then RELEASE that nonce with hash 0: the held payload never
    /// runs at that nonce, the honest twin at its own nonce is untouched (it runs, at once if it fits), and the honest
    /// peer's next message at that nonce runs (as a claim) with no further act. TIMING (a review of the wave-5 fixes): the RELEASE must be
    /// PROPOSED within 24 h of the hold (72 h hold - 48 h timelock) with the slot free; if the hold ends first, the replay
    /// runs as a CLAIM (a review before wave 5b), to be cancelled within D.
    function voidPayload(bytes32 payloadHash) external onlyGovernor {
        voided[payloadHash] = true;
        emit Voided(0, 0, bytes32(0), 0, payloadHash);
    }

    // ================================================================ internals

    function _peer(uint32 eid) private view returns (bytes32 peer) {
        peer = peers[eid];
        if (peer == bytes32(0)) revert NoPeer(eid);
    }

    /// @dev (burned, delivered): the dust-free amount and what is left after the fee, itself dust-free (the fee takes the dust).
    function _split(uint32 eid, uint256 amountLD) private view returns (uint256 amount, uint256 delivered) {
        amount = _removeDust(amountLD);
        delivered = _removeDust(amount - amount * feeBps[eid] / 10_000);
    }

    function _removeDust(uint256 amountLD) private pure returns (uint256) {
        uint256 sd = amountLD / CONVERSION;
        if (sd > type(uint64).max) revert OutOfBounds();
        return sd * CONVERSION;
    }

    function _build(SendParam calldata p, uint256 amount) private view returns (bytes memory message, bytes memory options) {
        if (p.composeMsg.length != 0 || p.oftCmd.length != 0) revert ComposeUnsupported();
        (message,) = OFTMsgCodec.encode(p.to, uint64(amount / CONVERSION), "");
        options = _combine(enforcedOptions[p.dstEid], p.extraOptions);
    }

    /// @dev OAppOptionsType3.combineOptions: enforced options first, then the caller's type-3 options without their 2-byte header.
    function _combine(bytes memory enforced, bytes calldata extra) private pure returns (bytes memory) {
        if (enforced.length == 0) return extra;
        if (extra.length == 0) return enforced;
        if (extra.length < 2 || uint16(bytes2(extra[:2])) != 3) revert BadPayload();
        return bytes.concat(enforced, extra[2:]);
    }

    /// @dev The path's instant allowance in use now (decayed at its cap per INSTANT_WINDOW), and the cap (shared decimals).
    /// After an instant lowering `used` may exceed the cap: nothing mints at once until it decays below.
    /// @dev The token has made this bridge its minter (ImdUSD.bridge() == this; a token without `bridge()` counts as accepted).
    function _accepted() private view returns (bool yes) {
        address t = address(minterBurner);
        assembly ("memory-safe") {
            mstore(0, 0xe78cea92) // bridge()
            let ok := staticcall(gas(), t, 28, 4, 0, 32)
            yes := or(or(iszero(ok), lt(returndatasize(), 32)), eq(mload(0), address()))
        }
    }

    function _instantUsed(Meter storage mt) private view returns (uint256 used, uint256 capSD) {
        Meter memory m = mt;
        capSD = m.capSD;
        // a review before wave 5b: a meter not started yet (no message since this token accepted the bridge) is EMPTY
        if (m.lastUpdated == 0) return (capSD * CONVERSION, capSD);
        uint256 decayed = capSD * CONVERSION * (block.timestamp - m.lastUpdated) / INSTANT_WINDOW;
        used = m.used > decayed ? m.used - decayed : 0;
    }

    /// @dev Record an inbound transfer as a pending claim, keyed by the GUID EndpointV2 gives (nonce, srcEid, sender) on this
    /// path (GUID.generate), not the packet's own guid field, which a forger chooses: a forged packet cannot take the key of
    /// an honest message at another nonce. EndpointV2 executes each (srcEid, sender, nonce) once, so the key is never reused.
    function _queue(Origin calldata origin, address to, uint256 amount) private {
        bytes32 guid = keccak256(
            abi.encodePacked(origin.nonce, origin.srcEid, origin.sender, localEid, bytes32(uint256(uint160(address(this)))))
        );
        Claim storage c = claims[origin.srcEid][guid];
        if (c.state != 0) revert BadPayload(); // unreachable on EndpointV2 (one execution per nonce)
        Breaker storage b = breakers[origin.srcEid];
        (c.to, c.amountSD, c.queuedAt, c.state) = (to, uint48(amount / CONVERSION), uint40(block.timestamp), CLAIM_PENDING);
        queued += amount;
        emit Queued(guid, origin.srcEid, to, amount, origin.nonce, block.timestamp + b.delay);
        // the breaker: add to today's bucket (buckets of days that fell out of the window restart at zero) and sum the window
        uint256 day = block.timestamp / 1 days;
        (uint256 bk, uint256 sum) = _window(b, origin.srcEid, day);
        bk += (amount / CONVERSION) << (63 * (day % BREAKER_DAYS)); // a day's queue < 2^63 units (see breakerBuckets)
        breakerBuckets[origin.srcEid] = bk;
        b.day = uint40(day);
        if (sum + amount / CONVERSION > b.breakerSD && !b.tripped) _trip(b, origin.srcEid, address(this));
    }

    /// @dev The path's breaker buckets as of UTC `day` (the buckets of days that fell out of the window since `b.day`
    /// cleared) and their sum, in shared decimals.
    function _window(Breaker storage b, uint32 srcEid, uint256 day) private view returns (uint256 bk, uint256 sum) {
        bk = breakerBuckets[srcEid];
        uint256 mask = (1 << 63) - 1;
        for (uint256 d = uint256(b.day) + 1; d <= day && d <= uint256(b.day) + BREAKER_DAYS; ++d) {
            bk &= ~(mask << (63 * (d % BREAKER_DAYS)));
        }
        for (uint256 i; i < BREAKER_DAYS; ++i) {
            sum += (bk >> (63 * i)) & mask;
        }
    }

    function _trip(Breaker storage b, uint32 srcEid, address by) private {
        uint16 trip = b.trips + 1;
        (b.tripped, b.trips) = (true, trip);
        emit BreakerTripped(srcEid, trip, by);
    }

    function _available(Limit storage l) private view returns (uint256) {
        uint256 decayed = l.window == 0 ? 0 : uint256(l.limit) * (block.timestamp - l.lastUpdated) / l.window;
        uint256 inFlight = l.inFlight > decayed ? l.inFlight - decayed : 0;
        return l.limit > inFlight ? l.limit - inFlight : 0;
    }

    /// @dev Meters `amount` (at least MIN_AMOUNT: smaller messages are refused before, at send and in lzReceive).
    function _consume(Limit storage l, uint32 eid, uint256 amount) private {
        uint256 available = _available(l);
        if (amount > available) revert RateLimited(eid, amount, available);
        l.inFlight = uint128(l.limit - available + amount);
        l.lastUpdated = uint64(block.timestamp);
    }

    // ================================================================ governance (48h)

    function _validate(bytes memory payload) internal view override {
        if (abi.decode(payload, (uint8)) == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            if (items.length == 0) revert BadPayload();
            for (uint256 i; i < items.length; ++i) {
                uint8 kind = abi.decode(items[i], (uint8));
                if (kind == BATCH) revert BadPayload();
                // audit wave 4: one SET_PATH / pin per eid and kind, so a BATCH's net effect is what its items say (two
                // SET_PATHs, limit 0 then back, used to erase what was in flight while reading as a no-op)
                if (kind == SET_PATH || kind == SET_SEND_LIBRARY || kind == SET_RECEIVE_LIBRARY) {
                    (, uint32 eid) = abi.decode(items[i], (uint8, uint32));
                    for (uint256 j; j < i; ++j) {
                        if (abi.decode(items[j], (uint8)) != kind) continue;
                        (, uint32 e) = abi.decode(items[j], (uint8, uint32));
                        if (e == eid) revert DuplicateInBatch(kind, eid);
                    }
                }
                _check(items[i], items);
            }
        } else {
            _check(payload, new bytes[](0));
        }
    }

    /// @dev One item; `batch` = the whole BATCH it belongs to (empty alone), whose library pins count for SET_CONFIG.
    function _check(bytes memory payload, bytes[] memory batch) private view {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == SET_PATH) {
            (, uint32 eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow, bytes memory opts) =
                abi.decode(payload, (uint8, uint32, bytes32, uint256, uint256, uint256, uint256, bytes));
            if (eid == 0 || eid == localEid || peer == bytes32(0)) revert BadPayload();
            if (outLimit > MAX_LIMIT || inLimit > MAX_LIMIT) revert OutOfBounds();
            if (outWindow < MIN_WINDOW || outWindow > MAX_WINDOW || inWindow < MIN_WINDOW || inWindow > MAX_WINDOW) {
                revert OutOfBounds();
            }
            // audit wave 4: a message above a LOWERED inbound limit could never pass (amount > limit in every block). Lower an
            // inbound limit only on a paused path, after lowering the peer's outbound and letting its in-flight land.
            if (inLimit < inbound[eid].limit && !paused[eid]) revert PathOpen(eid);
            if (opts.length != 0 && (opts.length < 2 || uint16(bytes2(opts)) != 3)) revert BadPayload();
            // P6: after this BATCH both libraries are pinned and configured by this OApp
            if (
                !_configuredAfter(_pinned(SET_SEND_LIBRARY, eid, batch), eid, batch)
                    || !_configuredAfter(_pinned(SET_RECEIVE_LIBRARY, eid, batch), eid, batch)
            ) revert Unconfigured(eid);
        } else if (kind == SET_CONFIG) {
            (, address lib, SetConfigParam[] memory params) = abi.decode(payload, (uint8, address, SetConfigParam[]));
            if (lib.code.length == 0) revert BadPayload();
            for (uint256 i; i < params.length; ++i) {
                uint32 eid = params[i].eid;
                bool isSend = lib == _pinned(SET_SEND_LIBRARY, eid, batch);
                // a receive library: the pinned one, or the old one while it still verifies in its grace (audit wave 4)
                if (
                    !isSend && lib != _pinned(SET_RECEIVE_LIBRARY, eid, batch)
                        && !(lib == receiveGraceLibrary[eid] && block.number < receiveGraceUntil[eid])
                ) revert UnpinnedLibrary(eid, lib);
                uint32 t = params[i].configType;
                if (t == CONFIG_TYPE_ULN) {
                    // confirmations are counted on the SOURCE chain: this one for a send library, `eid` for a receive one
                    _checkUln(params[i].config, (isSend ? localEid : eid) == ETHEREUM_EID);
                } else if (t == CONFIG_TYPE_EXECUTOR && isSend) {
                    (, address executor) = abi.decode(params[i].config, (uint32, address));
                    if (executor == address(0)) revert WeakConfig(2);
                } else {
                    revert WeakConfig(1);
                }
            }
        } else if (kind == SET_SEND_LIBRARY || kind == SET_RECEIVE_LIBRARY) {
            (, uint32 eid, address lib) = abi.decode(payload, (uint8, uint32, address));
            if (lib.code.length == 0 || eid == 0 || eid == localEid) revert BadPayload();
            if (!_configuredAfter(lib, eid, batch)) revert Unconfigured(eid); // P6: never onto a library without our config
            // audit wave 4: EndpointV2 reverts LZ_SameValue on the pinned library, which would fail the whole BATCH after 48h
            if (lib == (kind == SET_SEND_LIBRARY ? sendLibrary[eid] : receiveLibrary[eid])) revert SameLibrary(eid, lib);
            if (kind == SET_RECEIVE_LIBRARY) {
                (,,, uint256 grace) = abi.decode(payload, (uint8, uint32, address, uint256));
                // audit wave 4: the old library keeps verifying for `grace` blocks: bounded, and only one of ours
                if (grace > MAX_RECEIVE_GRACE) revert OutOfBounds();
                if (grace != 0 && !configured[receiveLibrary[eid]][eid]) revert Unconfigured(eid);
            }
        } else if (kind == SET_FEE) {
            (, uint32 eid, uint256 bps) = abi.decode(payload, (uint8, uint32, uint256));
            if (eid == 0 || eid == localEid) revert BadPayload();
            if (bps > MAX_FEE_BPS) revert OutOfBounds();
        } else if (kind == ENDPOINT_SKIP) {
            (, uint32 eid, bytes32 sender, uint64 nonce) = abi.decode(payload, (uint8, uint32, bytes32, uint64));
            if (eid == 0 || eid == localEid) revert BadPayload();
            if (!paused[eid]) revert PathOpen(eid);
            // EndpointV2 skips only the first nonce with no payload (audit wave 4)
            if (nonce != endpoint.inboundNonce(address(this), eid, sender) + 1) revert InfeasibleEndpointAct();
        } else if (kind == ENDPOINT_NILIFY || kind == ENDPOINT_BURN) {
            (, uint32 eid, bytes32 sender, uint64 nonce, bytes32 h) =
                abi.decode(payload, (uint8, uint32, bytes32, uint64, bytes32));
            if (eid == 0 || eid == localEid) revert BadPayload();
            // EndpointV2's own rules, checked here so an act it would refuse never takes the pending slot (audit wave 4)
            bytes32 cur = endpoint.inboundPayloadHash(address(this), eid, sender, nonce);
            bool atOrBelowLazy = nonce <= endpoint.lazyInboundNonce(address(this), eid, sender);
            if (cur != h) revert InfeasibleEndpointAct();
            if (kind == ENDPOINT_NILIFY) {
                if (atOrBelowLazy && cur == bytes32(0)) revert InfeasibleEndpointAct();
                if (!paused[eid]) revert PathOpen(eid);
            } else {
                if (cur == bytes32(0) || !atOrBelowLazy) revert InfeasibleEndpointAct();
                // burning an already nilified (NIL) nonce removes nothing executable: allowed with the path open
                if (!paused[eid] && cur != NIL_PAYLOAD_HASH) revert PathOpen(eid);
            }
        } else if (kind == UNVOID) {
            (, bytes32 h) = abi.decode(payload, (uint8, bytes32));
            if (!voided[h]) revert BadPayload();
        } else if (kind == RELEASE) {
            (, uint32 eid, bytes32 sender, uint64 nonce, bytes32 h) =
                abi.decode(payload, (uint8, uint32, bytes32, uint64, bytes32));
            // only a nonce that was held; the released payload is a real one (never NIL), or 0 = DROP (a review before wave 5b)
            if (holds[eid][sender][nonce].until == 0 || h == NIL_PAYLOAD_HASH) revert BadPayload();
        } else if (kind == UNCANCEL) {
            (, uint32 eid, bytes32 guid) = abi.decode(payload, (uint8, uint32, bytes32));
            if (claims[eid][guid].state != CLAIM_CANCELLED) revert BadPayload();
        } else if (kind == RESET_BREAKER) {
            (, uint32 eid, uint256 trip) = abi.decode(payload, (uint8, uint32, uint256));
            // checked again at application: only the trip it names, and only while that trip stands
            Breaker storage b = breakers[eid];
            if (!b.tripped || trip != b.trips) revert BadPayload();
            // audit wave 5: only on a PAUSED path, so nothing can queue between the Safe's last look and the reset (a claim
            // queued in the reset's block would be released uncounted); reopen in the same BATCH (UNPAUSE) or after
            if (!paused[eid]) revert PathOpen(eid);
        } else if (kind == SET_DELAY) {
            (, uint32 eid, uint256 cap, uint256 delay, uint256 breaker,, uint256 version) =
                abi.decode(payload, (uint8, uint32, uint256, uint256, uint256, uint40, uint256));
            // checked again at application: a tightening in between bumped the version (no stale loosening)
            if (eid == 0 || eid == localEid || version != breakers[eid].version) revert BadPayload();
            if (
                delay < MIN_DELAY || delay > MAX_DELAY || cap % CONVERSION != 0 || breaker % CONVERSION != 0
                    || cap / CONVERSION > type(uint64).max || breaker / CONVERSION > type(uint64).max
            ) revert OutOfBounds();
        } else if (kind == UNPAUSE) {
            (, uint32 eid) = abi.decode(payload, (uint8, uint32));
            // a review of the wave-5 fixes: only a paused path (an UNPAUSE of an open one reopens nothing and would empty its allowance)
            if (!paused[eid]) revert PathOpen(eid);
            if (block.number < receiveGraceUntil[eid]) revert GraceRunning(eid, receiveGraceUntil[eid]);
            for (uint256 i; i < batch.length; ++i) {
                if (_changesPath(batch[i], eid)) revert UnpauseWithChange(eid);
            }
        } else {
            revert BadPayload();
        }
    }

    function _checkUln(bytes memory config, bool fromEthereum) private pure {
        UlnConfig memory u = abi.decode(config, (UlnConfig));
        if (u.requiredDVNCount < MIN_REQUIRED_DVNS || u.requiredDVNCount == NIL_DVN_COUNT) revert WeakConfig(3);
        if (u.requiredDVNs.length != u.requiredDVNCount) revert WeakConfig(4);
        _ascending(u.requiredDVNs);
        uint64 floor_ = fromEthereum ? MIN_CONFIRMATIONS_FROM_ETHEREUM : MIN_CONFIRMATIONS_FROM_OTHER;
        if (u.confirmations < floor_ || u.confirmations == type(uint64).max) revert WeakConfig(6);
        // optional DVNs (audit wave 4): ULN302 reads a count of 0 as "the library's DEFAULT optional set" and merges it in, so
        // 0 is refused; NIL (255) with no list and threshold 0 means none; otherwise an explicit set with a threshold.
        if (u.optionalDVNCount == NIL_DVN_COUNT) {
            if (u.optionalDVNs.length != 0 || u.optionalDVNThreshold != 0) revert WeakConfig(7);
        } else if (
            u.optionalDVNCount == 0 || u.optionalDVNs.length != u.optionalDVNCount
                || u.optionalDVNThreshold > u.optionalDVNCount || u.optionalDVNThreshold == 0
        ) {
            revert WeakConfig(7);
        }
        _ascending(u.optionalDVNs);
    }

    /// @dev Strictly ascending from above zero: no zero address, no repeat (a repeat would count one DVN twice).
    function _ascending(address[] memory dvns) private pure {
        address prev;
        for (uint256 i; i < dvns.length; ++i) {
            if (dvns[i] <= prev) revert WeakConfig(5);
            prev = dvns[i];
        }
    }

    /// @dev The library `kind` (SET_SEND_LIBRARY / SET_RECEIVE_LIBRARY) pins for `eid` once `batch` is applied: the last such
    /// item in the batch, else what is pinned now.
    function _pinned(uint8 kind, uint32 eid, bytes[] memory batch) private view returns (address lib) {
        lib = kind == SET_SEND_LIBRARY ? sendLibrary[eid] : receiveLibrary[eid];
        for (uint256 i; i < batch.length; ++i) {
            if (abi.decode(batch[i], (uint8)) != kind) continue;
            (, uint32 e, address l) = abi.decode(batch[i], (uint8, uint32, address));
            if (e == eid) lib = l;
        }
    }

    /// @dev `item` sets the path, a library pin or a config param for `eid`.
    function _changesPath(bytes memory item, uint32 eid) private pure returns (bool) {
        uint8 kind = abi.decode(item, (uint8));
        if (kind == SET_PATH || kind == SET_SEND_LIBRARY || kind == SET_RECEIVE_LIBRARY) {
            (, uint32 e) = abi.decode(item, (uint8, uint32));
            return e == eid;
        }
        if (kind == SET_CONFIG) {
            (,, SetConfigParam[] memory params) = abi.decode(item, (uint8, address, SetConfigParam[]));
            for (uint256 j; j < params.length; ++j) {
                if (params[j].eid == eid) return true;
            }
        }
        return false;
    }

    /// @dev `lib` holds (or gets in `batch`) a floor-checked ULN config of this OApp for `eid`. Every SET_CONFIG in `batch`
    /// is validated by `_check` with the rest, so a ULN item there is one that passed the floors.
    function _configuredAfter(address lib, uint32 eid, bytes[] memory batch) private view returns (bool) {
        if (lib == address(0)) return false;
        if (configured[lib][eid]) return true;
        for (uint256 i; i < batch.length; ++i) {
            if (abi.decode(batch[i], (uint8)) != SET_CONFIG) continue;
            (, address l, SetConfigParam[] memory params) = abi.decode(batch[i], (uint8, address, SetConfigParam[]));
            if (l != lib) continue;
            for (uint256 j; j < params.length; ++j) {
                if (params[j].eid == eid && params[j].configType == CONFIG_TYPE_ULN) return true;
            }
        }
        return false;
    }

    function _apply(bytes memory payload) internal override {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            for (uint256 i; i < items.length; ++i) {
                _apply(items[i]);
            }
        } else if (kind == SET_PATH) {
            (, uint32 eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow, bytes memory opts) =
                abi.decode(payload, (uint8, uint32, bytes32, uint256, uint256, uint256, uint256, bytes));
            peers[eid] = peer;
            enforcedOptions[eid] = opts;
            _setLimit(outbound[eid], outLimit, outWindow);
            _setLimit(inbound[eid], inLimit, inWindow);
            // the first SET_PATH writes the launch delay settings (no open path is ever without a delay) and the breaker's
            // slots, so no inbound message ever pays their zero-to-nonzero writes
            Breaker storage b = breakers[eid];
            if (b.delay == 0) {
                b.day = uint40(block.timestamp / 1 days);
                breakerBuckets[eid] = 1 << 255;
                _setDelay(eid, DEFAULT_INSTANT_CAP, DEFAULT_DELAY, DEFAULT_QUEUE_BREAKER, 0);
            } else {
                // a review before wave 5b (the class): ANY SET_PATH on a set path can unblock packets (a peer back, a limit raised or its
                // window shortened, after a close), so the instant allowance restarts empty, as at UNPAUSE
                _meter(eid, instantIn[eid].capSD, true);
            }
            emit PathSet(eid, peer, outLimit, outWindow, inLimit, inWindow);
        } else if (kind == SET_CONFIG) {
            (, address lib, SetConfigParam[] memory params) = abi.decode(payload, (uint8, address, SetConfigParam[]));
            endpoint.setConfig(address(this), lib, params);
            for (uint256 i; i < params.length; ++i) {
                if (params[i].configType == CONFIG_TYPE_ULN) configured[lib][params[i].eid] = true;
            }
        } else if (kind == SET_SEND_LIBRARY) {
            (, uint32 eid, address lib) = abi.decode(payload, (uint8, uint32, address));
            sendLibrary[eid] = lib;
            endpoint.setSendLibrary(address(this), eid, lib);
        } else if (kind == SET_RECEIVE_LIBRARY) {
            (, uint32 eid, address lib, uint256 grace) = abi.decode(payload, (uint8, uint32, address, uint256));
            (receiveGraceLibrary[eid], receiveGraceUntil[eid]) = grace == 0 ? (address(0), 0) : (receiveLibrary[eid], block.number + grace);
            receiveLibrary[eid] = lib;
            endpoint.setReceiveLibrary(address(this), eid, lib, grace);
        } else if (kind == SET_FEE) {
            (, uint32 eid, uint256 bps) = abi.decode(payload, (uint8, uint32, uint256));
            feeBps[eid] = uint16(bps);
            emit FeeSet(eid, bps);
        } else if (kind == ENDPOINT_SKIP) {
            (, uint32 eid, bytes32 sender, uint64 nonce) = abi.decode(payload, (uint8, uint32, bytes32, uint64));
            endpoint.skip(address(this), eid, sender, nonce);
            emit Voided(kind, eid, sender, nonce, bytes32(0));
        } else if (kind == ENDPOINT_NILIFY || kind == ENDPOINT_BURN) {
            (, uint32 eid, bytes32 sender, uint64 nonce, bytes32 h) =
                abi.decode(payload, (uint8, uint32, bytes32, uint64, bytes32));
            if (kind == ENDPOINT_NILIFY) endpoint.nilify(address(this), eid, sender, nonce, h);
            else endpoint.burn(address(this), eid, sender, nonce, h);
            voided[h] = true;
            emit Voided(kind, eid, sender, nonce, h);
        } else if (kind == UNVOID) {
            (, bytes32 h) = abi.decode(payload, (uint8, bytes32));
            voided[h] = false;
            unvoided[h] = true; // a review before wave 5b: it runs as a claim (waits D), never at once
            emit Unvoided(h);
        } else if (kind == RELEASE) {
            (, uint32 eid, bytes32 sender, uint64 nonce, bytes32 h) =
                abi.decode(payload, (uint8, uint32, bytes32, uint64, bytes32));
            // ended (1, never 0: the nonce stays "held once") and bound to the released payload; h == 0 DROPS the held one
            // (a review before wave 5b: 2 = only the payload that was held is refused at that nonce, for good; any other runs, as a claim)
            HoldRecord storage r = holds[eid][sender][nonce];
            (r.payloadHash, r.until) = h == bytes32(0) ? (r.payloadHash, uint64(2)) : (h, uint64(1));
            emit HoldReleased(eid, sender, nonce, h);
        } else if (kind == UNCANCEL) {
            (, uint32 eid, bytes32 guid) = abi.decode(payload, (uint8, uint32, bytes32));
            Claim storage c = claims[eid][guid];
            // audit wave 5: restored once (a BATCH may name a claim twice: the second item is a no-op, so `queued` counts it
            // once and the proposal still applies)
            if (c.state == CLAIM_CANCELLED) {
                c.state = CLAIM_PENDING;
                queued += uint256(c.amountSD) * CONVERSION;
                emit ClaimRestored(guid, eid);
            }
        } else if (kind == RESET_BREAKER) {
            (, uint32 eid, uint256 trip) = abi.decode(payload, (uint8, uint32, uint256));
            breakers[eid].tripped = false;
            breakerBuckets[eid] = 1 << 255;
            emit BreakerReset(eid, trip);
        } else if (kind == SET_DELAY) {
            (, uint32 eid, uint256 cap, uint256 delay, uint256 breaker, uint40 cancelFrom,) =
                abi.decode(payload, (uint8, uint32, uint256, uint256, uint256, uint40, uint256));
            if (breakers[eid].day == 0) breakers[eid].day = uint40(block.timestamp / 1 days);
            if (breakerBuckets[eid] == 0) breakerBuckets[eid] = 1 << 255;
            _setDelay(eid, cap, delay, breaker, cancelFrom);
        } else {
            (, uint32 eid) = abi.decode(payload, (uint8, uint32));
            paused[eid] = false;
            // audit wave 5: a reopened path's instant allowance starts EMPTY and refills at its cap per INSTANT_WINDOW, so
            // packets verified but not executed while it was closed (a forged stockpile) queue as visible claims when
            // they run at the reopening instead of minting a fresh cap at once
            _meter(eid, instantIn[eid].capSD, true);
            emit Unpaused(eid);
        }
    }

    /// @dev Write a path's delay settings (validated by the caller). The instant meter is CHECKPOINTED first (audit wave 5): what
    /// was used decays to now at the cap that held until now, so the time before a change never decays at the new cap. A
    /// lowered cap then takes effect at once; a RAISED one frees nothing at once (audit wave 5): the allowance restarts EMPTY
    /// and refills at the new cap's rate over INSTANT_WINDOW, like a reopened path (a C restored after the Safe's C = 0,
    /// and a forged stockpile run at that moment, queues instead of minting). Not at a path's first settings (the launch
    /// values): nothing was ever open there.
    function _setDelay(uint32 eid, uint256 cap, uint256 delay, uint256 breaker, uint40 cancelFrom) private {
        uint256 capSD = cap / CONVERSION;
        Breaker storage b = breakers[eid];
        _meter(eid, capSD, capSD > instantIn[eid].capSD && b.delay != 0);
        (b.breakerSD, b.delay, b.cancelledFrom) = (uint64(breaker / CONVERSION), uint32(delay), cancelFrom);
        // audit wave 5: a breaker lowered below what the window already holds trips the path now (the queued claims wait for
        // RESET_BREAKER), as if the queue had grown past it
        (, uint256 sum) = _window(b, eid, block.timestamp / 1 days);
        if (sum > breaker / CONVERSION && !b.tripped) _trip(b, eid, address(this));
        emit DelaySet(eid, cap, delay, breaker, cancelFrom);
    }

    /// @dev Checkpoint a path's instant meter at `capSD` (what was used decays to now at the cap that held); `empty` restarts
    /// the allowance empty (used at least the cap), so it refills at the cap's rate (audit wave 5).
    function _meter(uint32 eid, uint256 capSD, bool empty) private {
        Meter storage m = instantIn[eid];
        // a review before wave 5b: a meter not started (the token has not accepted this bridge yet) stays not started; one that starts here
        // (a path's first settings once the token accepts) starts EMPTY
        if (m.lastUpdated == 0) {
            if (!_accepted()) {
                m.capSD = uint64(capSD);
                return;
            }
            empty = true;
        }
        (uint256 used,) = _instantUsed(m);
        if (empty && used < capSD * CONVERSION) used = capSD * CONVERSION;
        (m.used, m.lastUpdated, m.capSD) = (uint128(used), uint64(block.timestamp), uint64(capSD));
    }

    /// @dev A new limit keeps what is in flight (decayed to now), so changing a limit cannot reset the window. LOWERING it
    /// scales what is in flight by new/old: the FRACTION of the window used is kept, so a full window stays full
    /// for one window at the new rate instead of old/new windows (a 50x cut used to shut the path for 50 days). Raising keeps
    /// the absolute amount (the extra room is the point of a raise). CLOSING (limit 0) keeps it unscaled and, at rate 0, it
    /// does not decay, so a reopening starts where the path closed (audit wave 4); with one SET_PATH per eid in a BATCH, a
    /// proposal frees at most what its own raise openly adds.
    function _setLimit(Limit storage l, uint256 limit, uint256 window) private {
        uint256 decayed = l.window == 0 ? 0 : uint256(l.limit) * (block.timestamp - l.lastUpdated) / l.window;
        uint256 inFlight = l.inFlight > decayed ? l.inFlight - decayed : 0;
        if (limit < l.limit && limit != 0) inFlight = inFlight * limit / l.limit;
        l.inFlight = uint128(inFlight);
        l.lastUpdated = uint64(block.timestamp);
        l.limit = uint128(limit);
        l.window = uint32(window);
    }
}
