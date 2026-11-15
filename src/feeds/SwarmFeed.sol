// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable attested numeric feed. Attestations are the only way a value is ever set.
/// @dev THERE IS NO REPORTER FALLBACK, and removing it was the point. `report()` let an allowlisted
/// key set the value directly, bounded by `maxDeviationBps` only while the current value was still
/// fresh — past `maxAge` the bound lifted and the next accepted value re-anchored the band to
/// anything. On a testnet that was a convenience. On mainnet it is one key holding custody of every
/// position that consumes this feed, which is not a fallback but a second, weaker price oracle nobody
/// asked for.
///
/// The cost is accepted deliberately: a freshly deployed feed is INERT until its first attestation,
/// and a feed that goes stale cannot be walked back to market without buying one. That is the
/// behaviour mainnet has, so it is the behaviour a testnet should have too — a reporter fallback let
/// us test a protocol we were never going to deploy.
///
/// There is no admin or setter. Values are scaled by 1e18; consumers enforce any application bounds.
/// Zero is rejected: it is never a valid scaled figure.
///
/// HOW A VALUE IS BOUNDED: CLAMP, DO NOT REJECT (price design C, 2026-11-14; replaces the epoch REJECTION rule and its
/// "way back", whose memory three public audit waves each found a new lock-out or laundering hole in). For a feed whose
/// values have magnitude (`_hasMagnitude`, every shipped leaf), every attestation that passes the checks of
/// `submitAttestation` (signature, question binding, panel floors, window rules, freshness, replay) is ACCEPTED, as a
/// TARGET. The stored value moves toward the target by at most the current epoch's allowance around the epoch's ANCHOR:
///   - an epoch opens at the first acceptance after the previous one has run maxAge, and is anchored at the STORED value
///     then (never at a remembered or attested one); it lasts maxAge;
///   - its allowance is maxDeviationBps, or STALE_DEVIATION_MULTIPLE (2) x that when the stored value has been silent for
///     maxAge plus a whole STALE_GROWTH_PERIOD (an hour) when the epoch opens (`_allowanceNow`); never wider;
///   - stored = clamp(target, anchor x (1 - allowance), anchor x (1 + allowance)). `attested()` is the last target and
///     `converged()` says whether the stored value is it. `latestValue()` returns the stored value, dated by the
///     attestation that moved it (consumers that must not act at a value nobody attested read `converged()`: the Pricer
///     does, so a clamped leg prices but does not agree, and lends nothing).
/// The feed remembers nothing beyond the live epoch's anchor and the last target, so what it does next depends only on
/// the stored value, the clock and the next attestation. What that guarantees (test/unit/SwarmFeedProperties.t.sol):
///   P1 STEP BOUND. Within one epoch the stored value stays within the epoch's allowance of its anchor, whoever relays
///      what in whatever order: the stored value moves at most one allowance per epoch (two moves can straddle a
///      boundary a block apart, so over a sliding maxAge it can reach (1 + allowance)^2 - 1 once).
///   P2 LIVENESS. Every accepted attestation leaves the stored value as close to its target as the epoch allows (the
///      closest point of the band), and each new epoch moves it a full allowance toward the target or onto it. So once
///      honest attestations of a level H are the only ones relayed, at least one per epoch, the stored value reaches H
///      within ceil(ln(max(S, H) / min(S, H)) / ln(1 + cap)) epochs from any stored value S, sooner after a silence
///      (the 2x allowance). There is no lock-out: no sequence of earlier attestations can make a later one refused or
///      make it move the value away from its target.
///   P3 NO LAUNDERING. A level the feed held only because of a push is never a reference for refusing anything: the only
///      reference is the live anchor, and it bounds the step, it refuses nothing.
/// THE RESIDUAL, stated plainly: an attack lasting k epochs (a compromised attester, a wrong majority, pushed pool reads
/// attested honestly) moves the value at most one allowance per epoch and takes about k epochs of honest attestations to
/// undo (the way back undid it in one step; that speed is what needed memory, and the memory is what broke). A relayer
/// that always lands LAST in an epoch decides where the stored value ends that epoch, within the allowance, for as long
/// as it keeps doing so. The response to a suspected attester compromise is `Parameters.lowerLine(ilk, 0)` (instant: no
/// new debt on the type, liquidations continue) and a re-point (an operator procedure). The first value ever has no bound on chain:
/// whoever relays first sets it (the relay is permissionless), so the operator relays it first and checks it. A
/// single-step market gap larger than the allowance is followed at the allowance per epoch (a gap is a delay, never a
/// halt). A feed whose values have no magnitude (a Merkle root) keeps no epoch and takes every nonzero attested value.
///
/// HISTORY, briefly (full record in git and the audit folders): v1 bounded the move from the LAST value (six attestations
/// in one block walked a 20% cap 1.0 -> 3.48); then from the epoch anchor with rejection; the stale widening was capped at
/// 2x (it grew to 100x after a long outage); the "way back" (`_returnAnchor`, two epochs deep) was
/// added so a late push could not lock the honest level out, and audit waves 1-3 found that any depth of it either
/// locks out (N+1 timed pushes) or launders a pushed level as a reference. Clamping removes the rejection that made a
/// way back necessary. Silence is measured from the later of the signature and the relay (a held attestation relayed
/// late does not earn the stale base early: final panel audit, oracle, medium).
///
/// ---------------------------------------------------------------------------------------------------------------
/// imdUSD v2 PORT. Copied from the imdUSD v1 source (`src/SwarmFeed.sol`) at tag `mainnet-freeze-2026-10-11`
/// (b2c7afe, the code of the live v1 feeds: panel floors 100/51, the value read from the signed `answer`). Every rule above
/// is unchanged; the interface is v2's byte-identical `IFeed`. ONE ADDITION, the window-freshness rule for a feed that does
/// NOT live on the chain its data is about (a Robinhood Chain feed of the MAINNET IMD price): v1 skipped the recency bound
/// there, which on a production feed would let a buyer have an old window, chosen for its price, signed fresh. Here:
///  1. BLOCK CLOCK. Where `block.number` reports the data chain's blocks (Arbitrum-stack chains settling on Ethereum return
///     the parent's block number: on Robinhood Chain it read 26,245,468 = Ethereum's head, 2026-10-21), v1's bound applies to
///     it, with `PARENT_SLACK` blocks of allowance for the sequencer's lag in syncing that number (a window "in the future"
///     by less than that is an honest window the sequencer has not caught up with).
///  2. TIME CLOCK, always for a remote feed. The attestation's `issuedAt` dates its window: the window existed when it was
///     signed, so `toBlock <= head(issuedAt)`. The feed keeps a clock `(clockBlock, clockAt)` and a SLOW projection of the
///     data chain's head from it, `L(t) = clockBlock + (t - clockAt) / 12 * (1 - 1/CLOCK_DRIFT_DIVISOR)` (Ethereum cannot
///     make more than one block per 12 s and in practice misses ~1% of slots, so honest heads run ahead of L). A window must
///     close within one lifetime of it: `toBlock + maxAge / 12 >= L(issuedAt)`. Each acceptance moves the clock to
///     `(max(L(issuedAt), toBlock), issuedAt)`: never backwards, so a run of laggy windows cannot walk it into the past.
///     After an outage that loses more than the drift allowance, honest heads overtake L again at ~2% of elapsed blocks.
///     The first value sets the clock (as v1, the first value is the deployment's to buy and check).
abstract contract SwarmFeed is IFeed {
    struct OracleAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    error InvalidConfiguration();
    error ZeroValue();
    error InvalidSignature();
    error UnauthorizedRelayer();
    error WrongQuestion(bytes32 expected, bytes32 given);
    error WindowSpanOutOfRange(uint64 span);
    error WindowNotAdvancing(uint64 toBlock, uint64 lastAccepted);
    error InvalidWindow();
    error WindowInFuture(uint64 toBlock, uint256 head);
    error WindowTooOld(uint64 toBlock, uint256 head);
    error WindowBehindClock(uint64 toBlock, uint256 projected);
    /// @notice The first value of a remote feed with no block clock is the deployment's to relay (audit wave 3).
    error FirstValueNotDeployer();
    error UnboundQuestionNeedsRelayer();
    error QuestionNeedsWindowBounds();
    error InvalidAttestationChain();
    error InvalidAnswerType();
    error InvalidTimestamp();
    error ExpiredAttestation();
    error StaleAttestation();
    error ReplayedAttestation();
    error PanelTooSmall();
    error NotEnoughAgreement();
    error InvalidAnswer();
    error AnswerMismatch();

    event ValueUpdated(uint256 value, uint64 updatedAt);
    event AttestationAccepted(bytes32 indexed requestId, bytes32 questionHash);

    /// @notice Smallest panel this feed accepts, read from the signed attestation.
    /// @dev Attestation v2 signs panelSize/quorum/agreed, so the CONSUMER sets the real bar instead of
    /// trusting the request's own quorum. A request may therefore ask for a low quorum so that it
    /// attests at all, while this contract still refuses anything thinner than these floors.
    /// RAISED 2026-10-11 from 25/15 (operator's call, before the vault was deployed): the request's own panel and
    /// quorum are not part of the question, so anyone may buy an answer to this feed's question from a small panel
    /// and relay it; these floors are the whole bar. 100 is the plane's largest paid panel, and 51 a strict
    /// majority of it, so two disagreeing answers can never both clear it. A higher floor would refuse honest
    /// answers: on the first mainnet NHI answer only 20 of 35 members agreed, while 15 read the plane's /swarm
    /// endpoint during a fault and agreed on a wrong figure (request d0203e1a).
    uint16 public constant MIN_PANEL_SIZE = 100;
    /// @notice Smallest number of members that must have given the signed answer: a strict majority of the panel.
    /// A feed whose answers are deterministic may demand more (`minAgreed`); none may demand less.
    uint16 public constant MIN_AGREED = 51;
    /// @notice How much wider an epoch's allowance is when it opens on a stale value. This is also the MOST an
    /// epoch's allowance can ever be: the allowance no longer grows with further silence (it used
    /// to add an eighth of the cap per further hour, up to 100x).
    uint256 public constant STALE_DEVIATION_MULTIPLE = 2;
    /// @notice A value must have been stale for a whole period (an hour, whatever the feed's lifetime) past its
    /// lifetime before an epoch opens on the stale base; the one-day NHI feed earns it an hour after its lifetime
    /// too, so a gap in the index is followed within hours rather than days (review of cc4103f, 2026-10-07).
    uint256 public constant STALE_GROWTH_PERIOD = 1 hours;
    /// @notice The widest allowance the epoch rule can give: STALE_DEVIATION_MULTIPLE x the widest cap the constructor
    /// admits (10,000 bps). Not checked itself: that construction bound is what keeps the allowance under it and the
    /// packed uint24 exact.
    uint256 public constant MAX_ALLOWANCE_BPS = 20_000;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable attester;
    address public immutable relayer;

    /// @notice Closing block of the last accepted attestation window; only ever moves forward.
    uint64 public lastToBlock;
    uint256 public immutable attestationChainId;
    uint8 public immutable attestationAnswerType;
    uint256 public immutable maxAge;
    uint256 public immutable maxDeviationBps;

    mapping(bytes32 requestId => bool consumed) public usedRequests;
    /// @dev The STORED value: the last target moved toward it within the epoch's allowance (`_follow`).
    uint256 private _value;
    uint64 private _updatedAt;
    bool private _hasValue;
    /// @dev The bounding epoch: when it opened and its allowance in bps (at most MAX_ALLOWANCE_BPS, so 24 bits are exact).
    /// An epoch lasts maxAge from its first acceptance; the next acceptance after that opens one at the stored value.
    uint40 private _anchorAt;
    uint24 private _anchorBound;
    /// @dev The block time the stored value was RELAYED (accepted), as opposed to `_updatedAt`, the time its attestation
    /// was signed. Silence is measured from the later of the two: a relayer may hold a signed attestation for up to
    /// maxAge, and measured from the signature a held value arrived already old, so the next epoch earned the stale base
    /// early (final panel audit, oracle, medium). Freshness for consumers still runs from the signature (`isStale`).
    uint40 private _acceptedAt;
    /// @dev The live epoch's anchor (the stored value when it opened) and the last attested target, one slot. A feed with
    /// magnitude refuses a target above 2^128 (`InvalidAnswer`; the shipped figures are below 1e24), so both fit, and the
    /// stored value, always between an anchor and a target, does too. Unused by a feed without magnitude.
    uint128 private _anchorValue;
    uint128 private _attested;

    /// @notice A data chain on which `block.number` here reports its blocks (see the port note), 0 if none.
    uint256 public immutable blockClockChainId;
    /// @notice Who deployed the feed: the only relayer of a remote feed's FIRST value where no block clock can date it.
    address public immutable deployer;
    /// @notice Blocks of the data chain the block clock may lag behind (port note, rule 1).
    uint256 public constant PARENT_SLACK = 300;
    /// @notice The slow projection gives up 1/32 (~3%) of slots to missed blocks (port note, rule 2).
    uint256 public constant CLOCK_DRIFT_DIVISOR = 32;
    /// @notice The time clock of a remote feed: a data-chain block and the signed time it was known to exist by.
    uint64 public clockBlock;
    uint64 public clockAt;
    /// @notice The first value's window end and signature time: the fixed origin the upper bound on a window is measured from.
    uint64 public originBlock;
    uint64 public originAt;

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant ROBINHOOD_CHAIN = 4663; // Arbitrum stack on Ethereum: block.number is Ethereum's

    /// @param relayer_ Sole attestation submitter, or zero for permissionless relay.
    /// @param attestationChainId_ Required data chain in the signed payload, independent of the consumer chain.
    /// @param attestationAnswerType_ Required answer type in the signed payload.
    /// @param maxAge_ Maximum accepted age in seconds, strictly positive.
    /// @param maxDeviationBps_ The per-epoch cap in bps, 0 to 10,000: the stored value stays within this much of the
    /// epoch's ANCHOR for one lifetime from the epoch's start when the epoch opens on a fresh value, 2x when it opens
    /// after a silence (`_follow`, `_allowanceNow`). A target outside that band is taken and clamped to its edge.
    constructor(
        address attester_,
        address relayer_,
        uint256 attestationChainId_,
        uint8 attestationAnswerType_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    ) {
        if (attester_ == address(0) || maxAge_ == 0 || maxDeviationBps_ > 10_000) revert InvalidConfiguration();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
        // The pairing that the HIGH audit finding turned on: a feed that cannot verify WHICH question
        // an attestation answers has only its relayer standing between a bought signature and its
        // price, so it may not be deployed without one. A feed that pins its question needs no
        // relayer, and must pin a window span too — an unbounded span would let the same question be
        // answered over one block or over a month.
        //
        // WHAT THIS CHECK DOES NOT DO, stated because a stronger claim here would be false: it
        // requires a NONZERO relayer, and a relay contract that forwards for EVERYONE (v1's SwarmRelay)
        // is nonzero. That pairing (no pinned question, a permissionless relay) therefore passes
        // construction and is exactly the configuration the HIGH finding describes (v1's
        // PermissionlessRelay test reproduced it). Nothing this repository SHIPS is in that state: every
        // leaf in SwarmFeeds.sol (SwarmPriceFeed, SwarmSpotFeed, SwarmNhiFeed, SwarmSeatMedianFeed,
        // SwarmSeatSpotFeed, SwarmImdDepthFeed) overrides `questionPolicy` with a frozen prefix, so all
        // take the bound branch, and all are built with relayer zero (anyone relays). The hole is a footgun for
        // a FUTURE leaf that forgets the override, and closing it in the constructor needs a sound
        // on-chain test for "a relayer that restricts its callers", which `code.length` is not — a
        // relay contract may perfectly well carry an allowlist. Until such a test exists, the rule is
        // a review rule: a new feed leaf overrides `questionPolicy`, and the absence of an override
        // is the thing to catch.
        (bytes memory prefix_, uint64 minSpan_, uint64 maxSpan_) = questionPolicy();
        if (prefix_.length == 0) {
            if (relayer_ == address(0)) revert UnboundQuestionNeedsRelayer();
        } else if (minSpan_ == 0 || maxSpan_ < minSpan_) {
            revert QuestionNeedsWindowBounds();
        }
        attester = attester_;
        relayer = relayer_;
        attestationChainId = attestationChainId_;
        attestationAnswerType = attestationAnswerType_;
        maxAge = maxAge_;
        maxDeviationBps = maxDeviationBps_;
        blockClockChainId = block.chainid == ROBINHOOD_CHAIN ? ETHEREUM : block.chainid;
        deployer = msg.sender;
    }

    function latestValue() external view override returns (uint256 value, uint64 updatedAt) {
        return (_value, _updatedAt);
    }

    /// @notice When the live value was relayed (block time), as opposed to `latestValue`'s signature time. A consumer that
    /// reconstructs how long the chain held a price (the seat auction's clock) starts the window here.
    function acceptedAt() external view returns (uint64) {
        return _acceptedAt;
    }

    function isStale() external view override returns (bool) {
        return !_hasValue || _tooOld(_updatedAt);
    }

    /// @notice How many members must have given the signed answer for this feed to take it. MIN_AGREED here;
    /// the price and spot feeds, whose answers are deterministic chain reads, demand two thirds of the panel (67). The
    /// NHI, seat and depth leaves keep 51; the depth leaf is also a deterministic read, but it can only lower depth.
    function minAgreed() public pure virtual returns (uint16) {
        return MIN_AGREED;
    }

    /// @notice Accept an IdentityMD EIP-712 attestation through the configured relayer, or anyone if zero.
    /// @dev Uses the signed issue time, so delayed delivery cannot extend freshness. requestId is the
    /// replay nonce. The immutable consumer domain binds the deployment chain and this feed, stopping
    /// cross-feed replay without identifying the question. questionHash binds a changing pinned block
    /// window, so this contract cannot verify WHICH question an attestation answers FROM THE HASH ALONE.
    /// Every value after the first is a TARGET the stored value follows within the current epoch's allowance
    /// (`_follow`); a feed that pins its question document (questionPolicy, every shipped feed) verifies the
    /// question directly. The relayer is not a trust boundary on the shipped feeds:
    /// they are built with relayer zero, so anyone relays. Nothing on chain bounds the FIRST value: the
    /// shipped feeds are deployed empty and whoever relays first sets it, so the operator's procedure, not
    /// this code, must win (or check) the first relay of every leaf.
    /// Payload chainId and answerType must match the configured policy. Zero values revert.
    /// THE VALUE IS THE SIGNED `answer` (32 bytes, a uint256), not `figure`: the plane stopped filling `figure` for
    /// panel-evidence answers (mainnet NHI request d0203e1a, 2026-10-11: answer 0.98699e18, figure 0), and both
    /// fields are covered by the signature. A nonzero `figure` must equal the answer, so the two can never disagree.
    function submitAttestation(OracleAttestation calldata a, bytes calldata sig) external {
        if (relayer != address(0) && msg.sender != relayer) revert UnauthorizedRelayer();
        if (a.chainId != attestationChainId) revert InvalidAttestationChain();
        if (a.panelSize < MIN_PANEL_SIZE) revert PanelTooSmall();
        if (a.agreed < minAgreed() || a.agreed > a.panelSize) revert NotEnoughAgreement();
        if (a.answerType != attestationAnswerType) revert InvalidAnswerType();
        if (block.timestamp > a.expiresAt) revert ExpiredAttestation();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (_tooOld(a.issuedAt) || (_hasValue && a.issuedAt < _updatedAt)) revert StaleAttestation();
        if (usedRequests[a.requestId]) revert ReplayedAttestation();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _attestationHash(a)));
        if (_recover(digest, sig) != attester) revert InvalidSignature();
        usedRequests[a.requestId] = true;
        _requireQuestion(a);
        if (a.answer.length != 32) revert InvalidAnswer();
        uint256 value = abi.decode(a.answer, (uint256));
        _onFigure(a.figure, value);
        _accept(value, a.issuedAt);
        emit AttestationAccepted(a.requestId, a.questionHash);
    }

    /// @notice What the signed `figure` means to this feed. Here (every price and NHI feed): nothing of its own, so a
    /// nonzero figure must equal the answer and the two can never disagree. A leaf whose recipe signs a SECOND number
    /// as the figure (the seat feeds: the distinct seats sold) overrides this to keep it; the figure is covered by the
    /// signature either way.
    function _onFigure(uint256 figure, uint256 value) internal virtual {
        if (figure != 0 && figure != value) revert AnswerMismatch();
    }

    /// @notice The question document this feed accepts answers to, and the window span it allows.
    /// @dev An empty prefix disables question binding, which is only safe behind a trusted relayer —
    /// the constructor enforces that pairing. A production feed overrides this with the canonical
    /// question-document prefix emitted by the plane's question format. It is a SOURCE CONSTANT for the
    /// same reason every other authority here is: whoever controls the question controls the price, so
    /// it must never be a constructor argument a launch manifest could substitute.
    function questionPolicy() internal pure virtual returns (bytes memory prefix, uint64 minSpan, uint64 maxSpan) {
        return ("", 0, 0);
    }

    /// @dev Decimal ASCII of a uint64, because the document the attester hashed is JSON text and the
    /// window's two numbers appear in it as digits. Written here rather than imported: this repository's
    /// OpenZeppelin checkout carries only the few utils it needs, and a string helper is not worth
    /// widening it for.
    function _decimal(uint64 value) private pure returns (bytes memory) {
        if (value == 0) return "0";
        // Word-sized counters (gas review 2026-10-05): the input stays uint64 and every output byte is
        // identical, but the loop skips narrow-integer cleanup — about 5,100 gas per bound attestation,
        // which also widened v1's OracleAsker callback headroom under the Intake's 200,000-gas stipend.
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) ++digits;
        bytes memory out = new bytes(digits);
        for (uint256 v = value; v != 0; v /= 10) out[--digits] = bytes1(uint8(48 + (v % 10)));
        return out;
    }

    /// @notice The questionHash this feed will accept for a given window, or zero if it pins no
    /// question and therefore accepts any.
    /// @dev Public so an operator can check, from the chain, that a feed agrees with the payload they
    /// are about to pay for. Buying a request whose question document differs by one character means
    /// an attestation this feed refuses, and the 0.5 IMD is already spent by then.
    function expectedQuestionHash(uint64 fromBlock, uint64 toBlock) public pure returns (bytes32) {
        (bytes memory prefix,,) = questionPolicy();
        if (prefix.length == 0) return bytes32(0);
        return keccak256(
            abi.encodePacked(prefix, _decimal(fromBlock), ',"toBlock":', _decimal(toBlock), "}}")
        );
    }

    /// @notice Rebuild the control plane's question document and refuse an answer to another question.
    /// @dev The document is canonicalised as an RFC 8785 subset, so its keys are sorted and "window"
    /// sorts last. The only part that differs between two otherwise identical requests is therefore a
    /// SUFFIX, and the attestation carries that suffix's two numbers as SIGNED fields. So the feed
    /// splices them into a pinned prefix and recomputes the very hash the attester signed over.
    ///
    /// Two further bounds, because answering the right question is not yet answering it honestly:
    ///   - the span is bounded, so the question cannot be answered over a single block (a point read
    ///     dressed up as a window median) nor over a month (which smooths away a real move);
    ///   - toBlock must advance past the last accepted window;
    ///   - and, on the chain the data is about, the window must be RECENT: it closed at or before this
    ///     block and no more than one feed lifetime (maxAge, in 12-second blocks) ago. Advancing alone
    ///     was not enough (launch audit, oracle panel, high): after any gap in updates, a buyer could
    ///     have a fresh signature put on a window from hours or days earlier, chosen for its price, and
    ///     it would be accepted and dated now; a window in the future would also have pushed
    ///     lastToBlock past every honest one. A deployment whose data lives on another chain (the
    ///     Sepolia feeds attest mainnet) cannot see that chain's head, so the bound applies only when
    ///     attestationChainId is this chain — which it is for every mainnet feed.
    function _requireQuestion(OracleAttestation calldata a) private {
        (bytes memory prefix, uint64 minSpan, uint64 maxSpan) = questionPolicy();
        if (prefix.length == 0) return;
        if (a.toBlock < a.fromBlock) revert InvalidWindow();
        uint64 span = a.toBlock - a.fromBlock;
        if (span < minSpan || span > maxSpan) revert WindowSpanOutOfRange(span);
        if (a.toBlock <= lastToBlock) revert WindowNotAdvancing(a.toBlock, lastToBlock);
        if (attestationChainId == block.chainid) {
            if (a.toBlock > block.number) revert WindowInFuture(a.toBlock, block.number);
            if (block.number - a.toBlock > maxAge / 12) revert WindowTooOld(a.toBlock, block.number);
        } else {
            if (attestationChainId == blockClockChainId) {
                if (a.toBlock > block.number + PARENT_SLACK) revert WindowInFuture(a.toBlock, block.number);
                if (block.number > a.toBlock && block.number - a.toBlock > maxAge / 12) {
                    revert WindowTooOld(a.toBlock, block.number);
                }
            }
            _tickClock(a.toBlock, a.issuedAt);
        }
        bytes32 expected = expectedQuestionHash(a.fromBlock, a.toBlock);
        if (a.questionHash != expected) revert WrongQuestion(expected, a.questionHash);
        lastToBlock = a.toBlock;
    }

    /// @notice The slow projection of the data chain's head at `t` (port note, rule 2); 0 before the first value.
    function projectedHead(uint64 t) public view returns (uint256) {
        uint256 at = clockAt;
        if (at == 0) return 0;
        uint256 elapsed = t > at ? t - at : 0;
        // elapsed / 12 * (1 - 1/32), rounded DOWN in one division so frequent updates never round the allowance away
        return uint256(clockBlock) + elapsed * (CLOCK_DRIFT_DIVISOR - 1) / (12 * CLOCK_DRIFT_DIVISOR);
    }

    /// @dev Refuse a window older than one lifetime against the time clock, or one ending past the most blocks the data
    /// chain can have made since the ORIGIN (one per 12 s, plus PARENT_SLACK; audit wave 1: a validly signed future-dated
    /// window moved the clock ahead and every honest window after it was refused as behind), then move the clock forward.
    /// The bound is measured from the first value's fixed origin, not from the clock it moves (audit wave 2, low): measured
    /// from the clock, each future window let the next reach ~PARENT_SLACK further, so ten of them locked honest windows out
    /// for ~12 days. Ethereum makes at most one block per 12 s, so the bound is never below the honest head.
    function _tickClock(uint64 toBlock, uint64 issuedAt) private {
        uint256 projected = projectedHead(issuedAt);
        if (clockAt != 0) {
            if (uint256(toBlock) + maxAge / 12 < projected) revert WindowBehindClock(toBlock, projected);
            uint256 most = uint256(originBlock) + (issuedAt > originAt ? issuedAt - originAt : 0) / 12 + PARENT_SLACK;
            if (toBlock > most) revert WindowInFuture(toBlock, most);
        } else {
            // The origin bounds every later window, and nothing here can date the first one (audit wave 3, low: an old first
            // window, signed fresh and relayed by anyone, put the bound behind the honest head for good). Where a block clock
            // exists it has already refused an old window; elsewhere only the deployment relays the first value.
            if (attestationChainId != blockClockChainId && msg.sender != deployer) revert FirstValueNotDeployer();
            (originBlock, originAt) = (toBlock, issuedAt);
        }
        uint256 next = toBlock > projected ? toBlock : projected;
        // One window moves the clock at most PARENT_SLACK past the slow projection (audit wave 3, low: one window dated at the
        // origin bound, which runs ~1% of the slots since the origin ahead of the honest head, moved the clock there and
        // honest windows were refused as behind for ~0.47 x the feed's age). Honest windows still pull a lagging clock up by
        // up to PARENT_SLACK each (an outage loses ~3% of its slots to the projection: one window closes a day's).
        if (clockAt != 0 && next > projected + PARENT_SLACK) next = projected + PARENT_SLACK;
        clockBlock = uint64(next);
        if (issuedAt > clockAt) clockAt = issuedAt;
    }

    /// @dev Split across two `abi.encode` calls and concatenated: every field is a static
    /// single-word type, so this is byte-identical to encoding all sixteen at once, and it keeps the
    /// function off a stack-too-deep without turning on viaIR.
    function _attestationHash(OracleAttestation calldata a) private pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
    }

    /// @notice Refuse a value this feed cannot take as a target: zero, and (a feed with magnitude) one above 2^128, which no
    /// shipped figure comes near (prices ~4e15, NHI <= 1e18, seat prices ~1e18 wei, depth ~1e22 wei). Nothing else is
    /// refused: a value far from the stored one is a TARGET the stored value moves toward (`_follow`). The first value
    /// ever has no bound on chain and whoever relays first sets it (the relay is permissionless): no check in this
    /// repository compares it with the market, so the operator relays it first and checks it (final panel audit, oracle,
    /// low). It anchors the first epoch.
    /// @dev VIRTUAL: a feed whose value has no magnitude (a Merkle root, `_hasMagnitude` false) overrides it and keeps the
    /// zero check; such a feed keeps no epoch and stores every attested value as it is. What it gives up is real: the step
    /// bound is one of the things standing between a wrong figure and the feed's consumers. What remains is question
    /// binding, the attester signature and the panel floors, which (audit c71449d1, high) are what actually guard a feed.
    function _checkValue(uint256 value) internal view virtual {
        if (value == 0) revert ZeroValue();
        if (_hasMagnitude() && value > type(uint128).max) revert InvalidAnswer();
    }

    /// @dev `target` clamped into [anchor x (1 - bps), anchor x (1 + bps)]. The lower edge saturates at zero (a 5,000 bps
    /// cap is 10,000 bps after a silence), and a nonzero target never clamps to zero: below a zero edge it is inside.
    function _clamp(uint256 target, uint256 anchor, uint256 bps) private pure returns (uint256) {
        uint256 d = Math.mulDiv(anchor, bps, 10_000);
        uint256 hi = anchor + d;
        if (target > hi) return hi;
        uint256 lo = d >= anchor ? 0 : anchor - d;
        return target < lo ? lo : target;
    }

    /// @notice The anchor the next value is measured against and the move it may make from it, in bps.
    /// @dev The live epoch while it lasts; otherwise the epoch the next acceptance will open: anchored at the stored value,
    /// with the stale allowance if that value has been silent long enough. Read publicly through `epoch()`.
    function _epoch() private view returns (uint256 anchor, uint256 bound) {
        if (block.timestamp - uint256(_anchorAt) < maxAge) return (_anchorValue, _anchorBound);
        return (_value, _allowanceNow());
    }

    /// @dev The allowance an epoch opened now would carry: the cap on a fresh value, and on one stale for less than a whole
    /// STALE_GROWTH_PERIOD (an hour); after that, STALE_DEVIATION_MULTIPLE times the cap, however long the silence lasts.
    /// At a 2,000 bps cap and a one-hour lifetime: 20% through the first hour stale, 40% after two hours of silence, still
    /// 40% after a day. A one-day feed: 40% at 25 hours of silence. The stale base is earned by silence, never by timing:
    /// measured from one second past the lifetime, a relayer stepping once an hour and a second opened every epoch on it
    /// (second-half review 2026-10-07, medium). It never grows past 2x (it once grew to 100x).
    function _allowanceNow() private view returns (uint256) {
        if (!_tooOld(_updatedAt)) return maxDeviationBps;
        // Silence runs from the later of the signature and the relay (a held attestation is relayed late; final panel
        // audit, oracle, medium). Before the first value there is no relay time and the signature rules.
        uint256 since = _acceptedAt > _updatedAt ? _acceptedAt : _updatedAt;
        if (block.timestamp < since + maxAge + STALE_GROWTH_PERIOD) return maxDeviationBps;
        return maxDeviationBps * STALE_DEVIATION_MULTIPLE;
    }

    /// @notice Whether this feed takes `value` as a target now: any nonzero value (and, with magnitude, one below 2^128).
    /// Taking it is not storing it: `followOf` says what would be stored. Kept so a buyer's existing check keeps working.
    function accepts(uint256 value) external pure returns (bool) {
        return value != 0 && (!_hasMagnitude() || value <= type(uint128).max);
    }

    /// @notice The value a delivery of `target` would STORE if relayed now: the target clamped into the band of the epoch
    /// it would land in (`epoch()`). For a feed without magnitude, or before the first value, the target itself.
    function followOf(uint256 target) external view returns (uint256) {
        if (!_hasMagnitude() || !_hasValue) return target;
        (uint256 anchor, uint256 bound) = _epoch();
        return _clamp(target, anchor, bound);
    }

    /// @notice The last attested value taken as a target (the signed answer), as opposed to `latestValue`, the stored one.
    function attested() external view returns (uint256) {
        return _hasMagnitude() ? _attested : _value;
    }

    /// @notice True when the stored value IS the last attested one: no clamp is holding it short of its target. A consumer
    /// that must not act at a value nobody attested (the Pricer: no new debt) reads this. Always true without magnitude.
    function converged() external view returns (bool) {
        return !_hasMagnitude() || _value == _attested;
    }

    /// @notice The current bounding epoch: its anchor value, when it opened, and the allowance in bps that the stored value
    /// stays within until maxAge after that. An expired epoch is reported as the one the next acceptance would open, so
    /// the figures are always the ones the next delivery is clamped by.
    function epoch() external view returns (uint256 anchor, uint64 openedAt, uint256 allowanceBps) {
        (anchor, allowanceBps) = _epoch();
        openedAt = block.timestamp - uint256(_anchorAt) < maxAge ? uint64(_anchorAt) : uint64(block.timestamp);
    }

    /// @dev INTERNAL rather than private, so a subclass can accept a value without an attestation.
    /// That is a deliberate, narrow door and it is worth being exact about what it does and does not
    /// guarantee. The docstring above says attestations are the only way a value is ever set; with
    /// this visibility that is a property of THE CONTRACTS THIS REPOSITORY SHIPS — the leaves in
    /// SwarmFeeds.sol expose no path to it — rather than a property the
    /// base enforces on every conceivable subclass.
    ///
    /// It exists because the test suite has to set values, and with the reporter fallback gone the
    /// alternative is signing as the pinned attester, whose key is the oracle service's and not ours.
    /// The difference from the fallback it replaces is the one that matters: a reporter was an
    /// authority held by a KEY on a DEPLOYED contract, reachable by whoever held it. This is reachable
    /// only by writing a new subclass and deploying it, which is a code review rather than a
    /// transaction. Any new subclass under src/ must be read with that in mind.
    /// `target` is the attested value; what is stored is `_follow(target)` for a feed with magnitude.
    function _accept(uint256 target, uint64 updatedAt) internal {
        _checkValue(target);
        uint256 value = _hasMagnitude() ? _follow(target) : target;
        _value = value;
        _updatedAt = updatedAt;
        _acceptedAt = uint40(block.timestamp);
        _hasValue = true;
        emit ValueUpdated(value, updatedAt);
    }

    /// @dev Whether this feed's values are quantities the epoch rule can bound. True for every price;
    /// a feed whose value is an identifier (a Merkle root) overrides it to false, and with it overrides
    /// `_checkValue`. No v2 leaf overrides it.
    function _hasMagnitude() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev The epoch bookkeeping and the clamp, before `_value` moves: opens a new epoch at the STORED value once the live
    /// one has run maxAge, records the target, and returns what to store. The first value is stored as attested and
    /// anchors the first epoch at the cap. Bounds are at most MAX_ALLOWANCE_BPS, so uint24 is exact; uint40 holds a
    /// timestamp to year 36812; anchor and target are below 2^128 (`_checkValue`, and the stored value never leaves the
    /// span between an anchor and a target).
    function _follow(uint256 target) private returns (uint256) {
        if (!_hasValue) {
            (_anchorValue, _attested, _anchorAt, _anchorBound) =
                (uint128(target), uint128(target), uint40(block.timestamp), uint24(maxDeviationBps));
            return target;
        }
        uint256 anchor;
        uint256 bound;
        if (block.timestamp - uint256(_anchorAt) >= maxAge) {
            (anchor, bound) = (_value, _allowanceNow());
            if (bound > maxDeviationBps) {
                // THE WIDE BAND IS ONE STEP. After a silence the first delivery may move the stored value up to the stale
                // allowance; the epoch then re-anchors at what it stored, at the cap, so every later delivery this epoch
                // stays within the cap of it. An honest refresh after a silence closes the wide band for everyone after
                // it (review of cc4103f, 2026-10-07: a +55% value was taken an hour after the Treasury's honest refresh).
                // Remembered only for this epoch: the next one anchors at the stored value as always (price design C).
                uint256 first = _clamp(target, anchor, bound);
                (_anchorValue, _attested, _anchorAt, _anchorBound) =
                    (uint128(first), uint128(target), uint40(block.timestamp), uint24(maxDeviationBps));
                return first;
            }
            (_anchorAt, _anchorBound) = (uint40(block.timestamp), uint24(bound));
        } else {
            (anchor, bound) = (_anchorValue, _anchorBound);
        }
        (_anchorValue, _attested) = (uint128(anchor), uint128(target));
        return _clamp(target, anchor, bound);
    }

    function _tooOld(uint64 timestamp) private view returns (bool) {
        return block.timestamp > timestamp && block.timestamp - timestamp > maxAge;
    }
}
