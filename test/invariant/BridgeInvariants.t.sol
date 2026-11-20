// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwoChains} from "../utils/TwoChains.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {MockLzEndpoint} from "../utils/MockLzEndpoint.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Pulse} from "../../src/Pulse.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Positions on two chains, imdUSD crossing between them with messages left in flight, deliveries retried, Pulse
/// gaps (a silent sequencer) and liquidations. Reverts are tolerated; the state after each sequence is what is checked.
contract BridgeHandler is Test {
    bytes32 constant ETH = "ETH";

    struct Lane {
        Ledger ledger;
        Liquidator liquidator;
        ImdUSD usd;
        ImdBridge bridge;
        MockLzEndpoint ep;
        uint32 dstEid;
    }

    Lane[2] chains; // 0 = home, 1 = rh
    Pulse public pulse;
    MockERC20 weth;
    MockFeed ethFeed;
    address[] users;

    uint256 public start;
    uint256 public calls;
    uint256 public ok_open;
    uint256 public ok_repay;
    uint256 public ok_send;
    uint256 public ok_deliver;
    uint256 public ok_liquidate;
    uint256 public ok_claim;
    uint256 public held; // liquidations held by the grace
    uint256 public silences; // passTime calls that left the chain silent past the gap
    uint256 public graceViolations; // a seizure while the grace (or a pending long gap) applied
    uint256 public lineViolations; // rh debt over its chain line right after a borrow
    uint256 public rhSentAt0;

    constructor(Lane memory home_, Lane memory rh_, Pulse pulse_, MockERC20 weth_, MockFeed ethFeed_, address[] memory users_) {
        chains[0] = home_;
        chains[1] = rh_;
        pulse = pulse_;
        weth = weth_;
        ethFeed = ethFeed_;
        users = users_;
        start = vm.getBlockTimestamp();
        vm.deal(address(this), 100 ether);
    }

    function _c(uint256 i) internal view returns (Lane storage) {
        return chains[i % 2];
    }

    function _u(uint256 s) internal view returns (address) {
        return users[s % users.length];
    }

    function open(uint256 ci, uint256 us, uint256 coll, uint256 debt) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        coll = bound(coll, 1e18, 20e18);
        uint256 max = coll * ethFeed.value() / 1e18 * 100 / 150;
        debt = bound(debt, 100e18, max);
        weth.mint(u, coll);
        vm.prank(u);
        try c.ledger.open(ETH, 0, Adjust(int256(coll), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0))) {
            ok_open++;
            if (ci % 2 == 1) {
                (uint128 d,,,, uint128 b) = c.ledger.ilkState(ETH);
                (uint128 d2,,,, uint128 b2) = c.ledger.ilkState("OTHER");
                if (uint256(d) + b + d2 + b2 > 30_000e18) lineViolations++;
            }
        } catch {}
    }

    function repay(uint256 ci, uint256 us, uint256 amount) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        uint256 debt = c.ledger.debtOf(_pid(ETH, u));
        amount = bound(amount, 0, debt < c.usd.balanceOf(u) ? debt : c.usd.balanceOf(u));
        if (amount == 0) return;
        if (debt - amount != 0 && debt - amount < 100e18) amount = debt;
        if (amount > c.usd.balanceOf(u)) return;
        vm.prank(u);
        try c.ledger.open(ETH, 0, Adjust(0, -int256(amount), 0, 0, 0, false, type(uint256).max, address(0))) {
            ok_repay++;
        } catch {}
    }

    function send(uint256 ci, uint256 us, uint256 to, uint256 amount) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        amount = bound(amount, 0, c.usd.balanceOf(u));
        if (amount < 1e12) return;
        SendParam memory p = SendParam(c.dstEid, bytes32(uint256(uint160(_u(to)))), amount, 0, "", "", "");
        MessagingFee memory fee = c.bridge.quoteSend(p, false);
        vm.deal(u, fee.nativeFee);
        vm.prank(u);
        try c.bridge.send{value: fee.nativeFee}(p, fee, u) {
            ok_send++;
        } catch {}
    }

    function deliver(uint256 ci, uint256 idx) external {
        calls++;
        MockLzEndpoint ep = _c(ci).ep;
        uint256 n = ep.packetCount();
        if (n == 0) return;
        if (ep.deliver(idx % n)) ok_deliver++;
    }

    /// Anyone claims what packet idx queued at its destination, once DELAY has run; else a no-op.
    function claim(uint256 ci, uint256 idx) external {
        calls++;
        Lane storage c = _c(ci);
        Lane storage d = _c(ci + 1);
        uint256 n = c.ep.packetCount();
        if (n == 0) return;
        (uint32 dst, bytes32 receiver, bytes32 sender, uint64 nonce,,,,) = c.ep.packets(idx % n);
        bytes32 k = keccak256(abi.encodePacked(nonce, c.ep.eid(), sender, dst, receiver));
        try d.bridge.claim(c.ep.eid(), k) {
            ok_claim++;
        } catch {}
    }

    /// Time passes; with `silent` the rh sequencer produces nothing (nobody can poke), up to 3 hours.
    function passTime(uint256 dt, bool silent) external {
        calls++;
        if (silent) {
            dt = bound(dt, 16 minutes, 3 hours);
            silences++;
            vm.warp(vm.getBlockTimestamp() + dt);
        } else {
            dt = bound(dt, 1 minutes, 12 hours);
            uint256 end = vm.getBlockTimestamp() + dt;
            while (vm.getBlockTimestamp() < end) {
                vm.warp(vm.getBlockTimestamp() + 10 minutes > end ? end : vm.getBlockTimestamp() + 10 minutes);
                pulse.poke();
            }
        }
        ethFeed.set(ethFeed.value());
    }

    function movePrice(uint256 p) external {
        calls++;
        ethFeed.set(bound(p, 1200e18, 2600e18));
    }

    function liquidate(uint256 ci, uint256 us) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        uint256 debt = c.ledger.debtOf(_pid(ETH, u));
        if (debt == 0) return;
        // the liquidator's imdUSD comes out of circulation: borrow it from a user who holds enough (no unbacked mint)
        address payer;
        for (uint256 i; i < users.length; ++i) {
            if (users[i] != u && c.usd.balanceOf(users[i]) >= debt) payer = users[i];
        }
        if (payer == address(0)) return;
        vm.prank(payer);
        c.usd.transfer(address(this), debt);
        // seen from the rh Pulse before the call: a long gap pending, or a grace running
        bool mustHold = ci % 2 == 1 && (vm.getBlockTimestamp() - pulse.lastPulse() > pulse.gap() || vm.getBlockTimestamp() < pulse.graceUntil());
        try c.liquidator.liquidate(_pid(ETH, u)) returns (uint256 repaid, uint256 seized, uint256) {
            if (repaid + seized == 0) held++;
            else ok_liquidate++;
            if (mustHold && repaid + seized != 0) graceViolations++;
        } catch {}
        uint256 left = c.usd.balanceOf(address(this));
        if (left != 0) c.usd.transfer(payer, left);
    }

    function rhSent() external view returns (uint256) {
        return chains[1].bridge.sent();
    }
}

contract BridgeInvariantsTest is TwoChains {
    BridgeHandler handler;
    address[] users;

    function setUp() public {
        _setUpChains();
        _open();
        // the rh -> home path charges the highest fee, so every send exercises the fee mint
        vm.prank(safe);
        rh.bridge.propose(abi.encode(uint8(7), HOME_EID, uint256(25)));
        _warp(48 hours);
        rh.bridge.applyPending();
        for (uint256 i; i < 4; ++i) {
            address u = makeAddr(string(abi.encodePacked("user", i)));
            users.push(u);
            vm.startPrank(u);
            weth.approve(address(home.ledger), type(uint256).max);
            weth.approve(address(rh.ledger), type(uint256).max);
            vm.stopPrank();
        }
        BridgeHandler.Lane memory h = BridgeHandler.Lane(home.ledger, home.liquidator, home.usd, home.bridge, homeEp, RH_EID);
        BridgeHandler.Lane memory r = BridgeHandler.Lane(rh.ledger, rh.liquidator, rh.usd, rh.bridge, rhEp, HOME_EID);
        handler = new BridgeHandler(h, r, rh.pulse, weth, ethFeed, users);
        targetContract(address(handler));
    }

    function invariant_supplyPerChain() public {
        _assertChainSupply(home);
        _assertChainSupply(rh);
    }

    /// Σ supply + in flight == Σ ledger terms: imdUSD is never created or lost in transit.
    function invariant_supplyAcrossChains() public {
        _assertGlobalSupply();
    }

    function invariant_noSeizureDuringGrace() public view {
        assertEq(handler.graceViolations(), 0, "seized during a Pulse grace");
    }

    function invariant_chainLineHeld() public view {
        assertEq(handler.lineViolations(), 0, "rh debt over its chain line after a borrow");
    }

    /// A decaying limiter lets at most limit + limit x elapsed / window through in `elapsed`.
    function invariant_outboundLimit() public view {
        uint256 elapsed = vm.getBlockTimestamp() - handler.start();
        assertLe(handler.rhSent(), OUT_LIMIT + OUT_LIMIT * elapsed / 1 days, "rh exported more than its limit allows");
    }

    /// Non-hollow: the handler's actions do succeed (one deterministic sequence through every path).
    function test_handlerActionsSucceed() public {
        handler.open(1, 0, 10e18, 13_000e18);
        handler.open(0, 1, 10e18, 13_000e18);
        handler.send(1, 0, 2, 7_000e18); // above the instant cap after the fee: queued at home
        handler.send(0, 1, 3, 2_000e18);
        invariant_supplyAcrossChains();
        handler.deliver(1, 0);
        handler.deliver(0, 0);
        invariant_supplyAcrossChains(); // the 7,000 (less the fee) waits as a claim (> DELAY_THRESHOLD): in flight
        handler.repay(0, 1, 1_000e18);
        // a second holder on rh, whose imdUSD pays the liquidator: opened BEFORE the silence (fixed before audit wave 5: new debt waits
        // out the grace, so this borrow after the silence would be refused)
        handler.open(1, 2, 20e18, 15_000e18);
        handler.passTime(1 hours, true); // a silent sequencer
        handler.movePrice(1300e18);
        handler.liquidate(1, 0); // held by the grace its own poke starts
        handler.passTime(2 hours, false);
        handler.passTime(home.bridge.DEFAULT_DELAY() - 2 hours, false); // DELAY has run
        handler.claim(1, 0); // the queued rh -> home transfer, by anyone
        invariant_supplyPerChain();
        invariant_supplyAcrossChains();
        handler.movePrice(1300e18);
        handler.liquidate(1, 0); // seized
        handler.open(0, 3, 20e18, 15_000e18);
        handler.liquidate(0, 1); // mainnet-shaped: seized at once
        assertGt(handler.ok_open(), 1);
        assertGt(handler.ok_send(), 1);
        assertGt(handler.ok_deliver(), 1);
        assertGt(handler.ok_repay(), 0);
        assertGt(handler.held(), 0);
        assertGt(handler.ok_liquidate(), 1);
        assertEq(handler.ok_claim(), 1);
        invariant_supplyPerChain();
        invariant_supplyAcrossChains();
        invariant_noSeizureDuringGrace();
        invariant_outboundLimit();
    }
}

import {W4Bridge, W4Tok} from "../utils/W4Bridge.sol";
import {MockMessageLib} from "../utils/MockLzEndpoint.sol";

/// @notice Wave 4 (audit 34e546c2) attack handler: honest sends, forged packets (zero, dust, normal, overwriting a waiting
/// honest one), deliveries in any order, the Safe's instant pause / hold / void (no guardian since 2026-11-15),
/// compromised-DVN re-verification, and governance acts (bare path, library pins with and without config, DVN config changes,
/// UNPAUSE alone or batched with a config change, UNVOID, RELEASE) on one path home -> rh with fixed limits.
contract BridgeAttackHandler is Test {
    uint32 constant HOME = 30101;
    uint32 constant RH = 30416;
    uint256 public immutable L;

    BridgeAttackInvariantsTest internal t;
    MockLzEndpoint internal homeEp;
    MockLzEndpoint internal rhEp;
    ImdBridge internal rh;
    W4Tok internal rhTok;
    address internal safe;
    address internal attacker;

    uint256 public start;
    uint256 public forgedMinted;
    uint256 public inboundExecuted;
    uint256 public voidedExecuted; // P2
    uint256 public zeroExecuted; // audit wave 4: zero-amount messages
    uint256 public unconfiguredExecuted; // P6
    uint256 public acceptedNotApplied; // accepted => applies
    uint256 public ok_deliver;
    uint256 public ok_void;
    uint256 public ok_govern;
    // holds (BridgeHold.t.sol's properties H1-H4)
    uint256 public constant T = 72 hours;
    uint256 public heldExecuted; // H1/H3: ran inside its hold, or with a hash the hold never bound
    uint256 public holdRenewed; // H4: a second hold accepted on one nonce, or a hold stored longer than HOLD_TIME
    uint256 public honestLost; // H2: an honest message whose hold ended could not run with every other gate open
    uint256 public ok_hold;
    uint256 public ok_release;
    uint256 public ok_expiredRun;
    mapping(uint64 => uint256) public ghostHoldAt; // nonce -> when its hold was placed (0 = never)
    mapping(uint64 => bytes32) public ghostHoldHash; // the hash it binds (after a RELEASE, the released one)
    mapping(uint64 => bool) public ghostReleased;
    uint64[] internal heldNonces;

    // inbound delay
    uint256 public instantMinted; // D5: minted at receipt (honest + forged)
    uint256 public forgedSpendable; // forged imdUSD minted (at once or by claim)
    uint256 public earlyClaim; // D2: a claim minted before receipt + DELAY
    uint256 public cancelledClaimed; // D3: a cancelled claim minted
    uint256 public pausedClaimed; // D3: a claim minted on a paused path
    uint256 public claimLost; // D4: a pending claim past DELAY on an open path could not be claimed
    uint256 public badCancel; // D3: a cancel accepted on a claim that was not pending
    uint256 public ghostQueued; // D7: Σ pending
    uint256 public ok_claim;
    uint256 public ok_cancel;
    uint256 public ok_uncancel;
    bytes32[] internal claimKeys;
    mapping(bytes32 => uint256) public ghostClaimAt;
    mapping(bytes32 => uint256) public ghostClaimAmount;
    mapping(bytes32 => bool) public ghostClaimForged;
    mapping(bytes32 => uint8) public ghostClaimState; // 1 pending, 2 claimed, 3 cancelled
    bytes32[] internal cancelledKeys;

    // queue breaker
    uint256 public trippedClaimed; // B1: a claim minted while the path's breaker was tripped
    uint256 public ok_trip;
    uint256 public ok_tightenB;
    uint256 public ok_reset;
    uint256 public staleReset; // B3: a RESET_BREAKER naming an earlier trip applied
    uint256[] internal ghostQueueAt; // queue times since the last reset (with amounts)
    // a review of the wave-5 fixes: every reopening (UNPAUSE, a cap raise, an inbound-limit raise) and what minted at once since the last one
    uint256 public reopenAt;
    uint256 public mintedSinceReopen;
    uint256 public reopenings;
    uint256 public ok_tightenC;
    uint256[] internal ghostQueueAmt;

    mapping(bytes32 => bool) public ghostVoided;
    mapping(address => bool) public ghostConfigured; // receive libs this OApp set a ULN config on (for HOME)
    bytes32[] internal voidedHonest;
    mapping(uint256 => bool) internal forged;
    uint160 internal dvnBase = 0x1000;

    constructor(BridgeAttackInvariantsTest t_, MockLzEndpoint homeEp_, MockLzEndpoint rhEp_, ImdBridge rh_, W4Tok rhTok_, address recvLib, uint256 limit) {
        t = t_;
        homeEp = homeEp_;
        rhEp = rhEp_;
        rh = rh_;
        rhTok = rhTok_;
        safe = t_.safeAddr();
        attacker = t_.attackerAddr();
        ghostConfigured[recvLib] = true;
        L = limit;
        start = vm.getBlockTimestamp();
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function send(uint256 amount) external {
        amount = bound(amount, 1e12, L / 2);
        t.honestSend(amount);
    }

    /// kind 0 zero, 1 dust, 2 normal, 3 over a waiting honest packet's nonce
    function forge(uint256 kind, uint256 amount, uint256 idx) external {
        kind = kind % 4;
        uint256 a = kind == 0 ? 0 : kind == 1 ? 1e12 : bound(amount, 1e18, L);
        bytes memory m = abi.encodePacked(_b32(attacker), uint64(a / 1e12));
        uint256 i;
        uint256 n = homeEp.packetCount();
        if (kind == 3 && n != 0) {
            (,,, uint64 nonce,,,, bool delivered) = homeEp.packets(idx % n);
            if (delivered) return;
            i = homeEp.forgeAt(RH, _b32(address(rh)), _b32(address(t.homeAddr())), m, nonce);
        } else {
            i = homeEp.forge(RH, _b32(address(rh)), _b32(address(t.homeAddr())), m);
        }
        forged[i] = true;
    }

    function deliver(uint256 idx) external {
        uint256 n = homeEp.packetCount();
        if (n == 0) return;
        idx %= n;
        if (homeEp.isDelivered(idx)) return;
        bytes32 h = homeEp.payloadHashOf(idx);
        uint256 amount = homeEp.amountOf(idx);
        address lib = rhEp.receiveLibrary(address(rh), HOME);
        (,,, uint64 nonce,,,,) = homeEp.packets(idx);
        uint256 q0 = rh.queued();
        uint256 b0 = rhTok.totalSupply();
        if (!homeEp.deliver(idx)) return;
        ok_deliver++;
        _afterExecute(idx, nonce, amount, q0, b0);
        if (ghostHoldAt[nonce] != 0) {
            bool early = !ghostReleased[nonce] && vm.getBlockTimestamp() < ghostHoldAt[nonce] + T;
            if (early || h != ghostHoldHash[nonce]) heldExecuted++;
        }
        inboundExecuted++;
        if (ghostVoided[h]) voidedExecuted++;
        if (amount == 0) zeroExecuted++;
        if (!ghostConfigured[lib]) unconfiguredExecuted++;
        if (forged[idx]) forgedMinted += amount;
    }

    /// Classify what an execution did: queued (a claim) or minted at once.
    function _afterExecute(uint256 idx, uint64 nonce, uint256 amount, uint256 q0, uint256 b0) internal {
        if (rh.queued() > q0) {
            bytes32 k = keccak256(abi.encodePacked(nonce, HOME, _b32(address(t.homeAddr())), RH, _b32(address(rh))));
            claimKeys.push(k);
            ghostClaimAt[k] = vm.getBlockTimestamp() + rh.DEFAULT_DELAY();
            ghostClaimAmount[k] = amount;
            ghostClaimForged[k] = forged[idx];
            ghostClaimState[k] = 1;
            ghostQueued += amount;
            ghostQueueAt.push(vm.getBlockTimestamp());
            ghostQueueAmt.push(amount);
        } else {
            mintedSinceReopen += rhTok.totalSupply() - b0;
            instantMinted += rhTok.totalSupply() - b0;
            if (forged[idx]) forgedSpendable += amount;
        }
    }

    /// Anyone claims claim i: never early, never cancelled, never on a paused path; always when none of those applies.
    function claim(uint256 i, uint256 who) external {
        if (claimKeys.length == 0) return;
        bytes32 k = claimKeys[i % claimKeys.length];
        uint8 st = ghostClaimState[k];
        (,, bool tripped,,,,) = rh.breakers(HOME);
        bool due = st == 1 && vm.getBlockTimestamp() >= ghostClaimAt[k] && !rh.paused(HOME) && !tripped;
        vm.prank(address(uint160(bound(who, 1, type(uint160).max))));
        try rh.claim(HOME, k) {
            ok_claim++;
            if (vm.getBlockTimestamp() < ghostClaimAt[k]) earlyClaim++;
            if (st == 3) cancelledClaimed++;
            if (rh.paused(HOME)) pausedClaimed++;
            if (tripped) trippedClaimed++;
            if (st == 1) ghostQueued -= ghostClaimAmount[k];
            ghostClaimState[k] = 2;
            if (ghostClaimForged[k]) forgedSpendable += ghostClaimAmount[k];
        } catch {
            if (due) claimLost++;
        }
    }

    /// The Safe cancels claim i (instant).
    function cancelClaim(uint256 i) external {
        if (claimKeys.length == 0) return;
        bytes32 k = claimKeys[i % claimKeys.length];
        uint8 st = ghostClaimState[k];
        vm.prank(safe);
        rh.cancelClaim(HOME, k); // a review of the wave-5 fixes: never reverts; a claim not pending is left as it is
        (,,, uint8 now_) = rh.claims(HOME, k);
        if (st != 1) {
            if (now_ != st) badCancel++;
            return;
        }
        ok_cancel++;
        ghostQueued -= ghostClaimAmount[k];
        ghostClaimState[k] = 3;
        cancelledKeys.push(k);
    }

    /// The Safe lowers the instant cap (instant `tighten`), every other field as it stands (clamped).
    function tightenCap(uint256 c) external {
        vm.prank(safe);
        rh.tighten(HOME, bound(c, 0, 5_000) * 1e18, 0, type(uint256).max, 0);
        ok_tightenC++;
    }

    /// The Safe lowers the queue breaker (instant `tighten`; audit wave 5): every other field as it stands (clamped).
    function tightenBreaker(uint256 b) external {
        vm.prank(safe);
        rh.tighten(HOME, type(uint256).max, 0, bound(b, 0, 60_000) * 1e18, 0);
        ok_tightenB++;
    }

    /// The Safe trips the queue breaker (instant).
    function tripBreaker() external {
        vm.prank(safe);
        rh.tripBreaker(HOME);
        ok_trip++;
    }

    /// Ghost of the breaker's window: imdUSD queued (since the last reset) on the current UTC day and the 3 before it.
    function ghostWindowQueued() external view returns (uint256 sum) {
        uint256 day = vm.getBlockTimestamp() / 1 days;
        for (uint256 i; i < ghostQueueAt.length; ++i) {
            if (ghostQueueAt[i] / 1 days + uint256(4) > day) sum += ghostQueueAmt[i];
        }
    }

    function pause() external {
        vm.prank(safe);
        rh.pause(HOME);
    }

    /// The Safe's instant permanent void of packet idx's payload hash.
    function voidPayload(uint256 idx) external {
        uint256 n = homeEp.packetCount();
        if (n == 0) return;
        idx %= n;
        bytes32 h = homeEp.payloadHashOf(idx);
        if (ghostVoided[h]) return;
        vm.prank(safe);
        rh.voidPayload(h);
        ok_void++;
        ghostVoided[h] = true;
        if (!forged[idx]) voidedHonest.push(h);
    }

    /// The Safe's instant hold on packet idx's nonce (whatever the endpoint stores there).
    function hold(uint256 idx) external {
        uint256 n = homeEp.packetCount();
        if (n == 0) return;
        (,, bytes32 sender, uint64 nonce,,,,) = homeEp.packets(idx % n);
        bytes32 stored = rhEp.inboundPayloadHash(address(rh), HOME, sender, nonce);
        (, uint64 before) = rh.holds(HOME, sender, nonce);
        vm.prank(safe);
        rh.hold(HOME, nonce); // a review of the wave-5 fixes: never reverts; a no-op when held before or nothing executable is stored
        (bytes32 boundHash, uint64 after_) = rh.holds(HOME, sender, nonce);
        if (after_ == before) return; // nothing placed
        if (ghostHoldAt[nonce] != 0 || before != 0) holdRenewed++;
        ok_hold++;
        ghostHoldAt[nonce] = vm.getBlockTimestamp();
        ghostHoldHash[nonce] = stored;
        if (boundHash != stored) holdRenewed++;
        heldNonces.push(nonce);
    }

    /// H2 as a liveness check: an honest packet whose hold has ended runs for anyone when nothing else stops it (path open,
    /// configured, room in the limit, its hash still stored and not voided, every lower nonce above lazy stored).
    function runExpired(uint256 idx) external {
        uint256 n = homeEp.packetCount();
        if (n == 0) return;
        idx %= n;
        if (forged[idx] || homeEp.isDelivered(idx)) return;
        (,, bytes32 sender, uint64 nonce,,,,) = homeEp.packets(idx);
        bytes32 h = homeEp.payloadHashOf(idx);
        if (ghostHoldAt[nonce] == 0 || ghostReleased[nonce] || ghostHoldHash[nonce] != h) return;
        if (vm.getBlockTimestamp() < ghostHoldAt[nonce] + T) return;
        if (rh.paused(HOME) || rh.voided(h) || rhEp.inboundPayloadHash(address(rh), HOME, sender, nonce) != h) return;
        if (!rh.configured(rh.receiveLibrary(HOME), HOME)) return;
        if (rh.availableIn(HOME) < homeEp.amountOf(idx)) return;
        uint64 lazy = rhEp.lazyInboundNonce(address(rh), HOME, sender);
        for (uint64 j = lazy + 1; j < nonce; ++j) {
            if (rhEp.inboundPayloadHash(address(rh), HOME, sender, j) == bytes32(0)) return;
        }
        uint256 q0 = rh.queued();
        uint256 b0 = rhTok.totalSupply();
        vm.prank(address(uint160(uint256(keccak256(abi.encode(idx, nonce))))));
        if (homeEp.deliver(idx)) {
            _afterExecute(idx, nonce, homeEp.amountOf(idx), q0, b0);
            ok_expiredRun++;
            ok_deliver++;
            inboundExecuted++;
        } else {
            honestLost++;
        }
    }

    function heldCount() external view returns (uint256) {
        return heldNonces.length;
    }

    function heldNonceAt(uint256 i) external view returns (uint64) {
        return heldNonces[i];
    }

    /// The (compromised or honest) DVNs verify packet idx again.
    function reverify(uint256 idx) external {
        uint256 n = homeEp.packetCount();
        if (n == 0) return;
        homeEp.reverify(idx % n);
    }

    function passTime(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1 minutes, 36 hours));
    }

    /// 0 bare SET_PATH (same limits), 1 bare receive pin, 2 pin + config, 3 config change, 4 UNPAUSE, 5 [config, UNPAUSE],
    /// 6 UNVOID of an honest payload voided by mistake, 7 RELEASE (early) of the last hold, with the hash it binds,
    /// 8 UNCANCEL of the last cancelled claim, 9 RESET_BREAKER of the current trip, 10 RESET_BREAKER of an earlier trip
    /// 11 SET_DELAY restoring the launch cap (D and B as they stand), 12 SET_PATH closing the inbound side (limit 0, on a
    /// paused path), 13 SET_PATH reopening it (a review of the wave-5 fixes: both reopening routes under the invariant)
    function govern(uint256 what) external {
        what %= 14;
        bytes32 unc;
        uint64 relNonce;
        bytes memory p;
        address newLib;
        if (what == 0) {
            p = abi.encode(uint8(1), HOME, _b32(address(t.homeAddr())), L, uint256(1 days), L, uint256(1 days), bytes(""));
        } else if (what == 1) {
            p = abi.encode(uint8(4), HOME, address(new MockMessageLib()), uint256(0));
        } else if (what == 2) {
            newLib = address(new MockMessageLib());
            p = _two(abi.encode(uint8(4), HOME, newLib, uint256(0)), t.recvCfg(newLib, HOME, ++dvnBase * 16));
        } else if (what == 3) {
            p = t.recvCfg(rhEp.receiveLibrary(address(rh), HOME), HOME, ++dvnBase * 16);
        } else if (what == 4) {
            p = abi.encode(uint8(5), HOME);
        } else if (what == 5) {
            p = _two(t.recvCfg(rhEp.receiveLibrary(address(rh), HOME), HOME, ++dvnBase * 16), abi.encode(uint8(5), HOME));
        } else if (what == 6) {
            if (voidedHonest.length == 0) return;
            p = abi.encode(uint8(11), voidedHonest[voidedHonest.length - 1]);
        } else if (what == 9 || what == 10) {
            (, uint16 trips,,,,,) = rh.breakers(HOME);
            if (what == 10 && trips < 2) return;
            // audit wave 5: a reset only on a paused path: the Safe pauses, then resets and reopens in one BATCH; a review of
            // the wave-5 fixes: pause only for a reset that is proposable (the current trip), so a refused one leaves the path as it was
            (,, bool tripped,,,,) = rh.breakers(HOME);
            if (what == 9 && tripped) {
                vm.prank(safe);
                rh.pause(HOME);
            }
            p = _two(abi.encode(uint8(14), HOME, uint256(what == 9 ? trips : trips - 1)), abi.encode(uint8(5), HOME));
        } else if (what == 11) {
            (,,,, uint32 d,, uint16 v) = rh.breakers(HOME);
            (,,, uint64 bSD,,,) = rh.breakers(HOME);
            p = abi.encode(uint8(15), HOME, rh.DEFAULT_INSTANT_CAP(), uint256(d), uint256(bSD) * 1e12, uint40(0), uint256(v));
        } else if (what == 12) {
            vm.prank(safe);
            rh.pause(HOME);
            p = abi.encode(uint8(1), HOME, _b32(address(t.homeAddr())), L, uint256(1 days), uint256(0), uint256(1 days), bytes(""));
        } else if (what == 13) {
            p = abi.encode(uint8(1), HOME, _b32(address(t.homeAddr())), L, uint256(1 days), L, uint256(1 days), bytes(""));
        } else if (what == 8) {
            if (cancelledKeys.length == 0) return;
            unc = cancelledKeys[cancelledKeys.length - 1];
            if (ghostClaimState[unc] != 3) return;
            p = abi.encode(uint8(13), HOME, unc);
        } else {
            if (heldNonces.length == 0) return;
            relNonce = heldNonces[heldNonces.length - 1];
            p = abi.encode(uint8(12), HOME, _b32(address(t.homeAddr())), relNonce, ghostHoldHash[relNonce]);
        }
        vm.prank(safe);
        try rh.propose(p) {}
        catch {
            return;
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        (bool p0, uint256 in0, uint64 cap0) = _openState();
        try rh.applyPending() {
            ok_govern++;
            (bool p1, uint256 in1, uint64 cap1) = _openState();
            if ((p0 && !p1) || in1 > in0 || cap1 > cap0) {
                (reopenAt, mintedSinceReopen) = (vm.getBlockTimestamp(), 0);
                reopenings++;
            }
            if (what == 2) ghostConfigured[newLib] = true;
            if (what == 6) {
                ghostVoided[voidedHonest[voidedHonest.length - 1]] = false;
                voidedHonest.pop();
            }
            if (what == 7) {
                ghostReleased[relNonce] = true;
                ok_release++;
            }
            if (what == 8) {
                ghostClaimState[unc] = 1;
                ghostQueued += ghostClaimAmount[unc];
                cancelledKeys.pop();
                ok_uncancel++;
            }
            if (what == 9 || what == 10) {
                ok_reset++;
                if (what == 10) staleReset++;
                delete ghostQueueAt;
                delete ghostQueueAmt;
            }
        } catch {
            acceptedNotApplied++;
            vm.prank(safe);
            rh.cancel();
        }
    }

    function _openState() internal view returns (bool paused_, uint256 inLimit, uint64 capSD) {
        paused_ = rh.paused(HOME);
        (uint128 lim,,,) = rh.inbound(HOME);
        inLimit = lim;
        (,, capSD) = rh.instantIn(HOME);
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (a, b);
        return abi.encode(uint8(6), items);
    }
}

contract BridgeAttackInvariantsTest is W4Bridge {
    BridgeAttackHandler handler;
    // the 4663 launch limit: at 10,000/day queueing could never pass QUEUE_BREAKER 50,000
    // inside its 4-day window (at most LIM x (1 + 4) = 50,000), and the breaker's B1 would be hollow
    uint256 constant LIM = 50_000e18;

    function setUp() public {
        _setUpW4();
        _openBoth(LIM);
        handler = new BridgeAttackHandler(this, homeEp, rhEp, rh, rhTok, rhRecvLib, LIM);
        targetContract(address(handler));
    }

    // views and an honest send for the handler
    function safeAddr() external view returns (address) {
        return safe;
    }

    function attackerAddr() external view returns (address) {
        return attacker;
    }

    function homeAddr() external view returns (address) {
        return address(home);
    }

    function honestSend(uint256 amount) external {
        _send(alice, amount);
    }

    function recvCfg(address lib, uint32 eid, uint160 base) external view returns (bytes memory) {
        return _recvCfg(lib, eid, base);
    }

    /// P2: a voided payload never executes (until a timelocked UNVOID).
    function invariant_voidedNeverExecutes() public view {
        assertEq(handler.voidedExecuted(), 0, "a voided payload executed");
    }

    /// Audit wave 4: no zero-amount inbound message executes.
    function invariant_noZeroAmountExecutes() public view {
        assertEq(handler.zeroExecuted(), 0, "a zero-amount inbound message executed");
    }

    /// P6: nothing executes on a receive library this OApp has not configured.
    function invariant_onlyConfiguredLibrariesCarryValue() public view {
        assertEq(handler.unconfiguredExecuted(), 0, "executed on an unconfigured receive library");
    }

    /// Audit wave 4: inbound nonces executed are bounded like the amount: <= MAX_MESSAGES x (1 + t / window).
    function invariant_messagesBoundedPerWindow() public view {
        uint256 t = vm.getBlockTimestamp() - handler.start();
        assertLe(handler.inboundExecuted(), 1_000 + 1_000 * t / 1 days, "inbound nonces unbounded");
    }

    /// P1/P2: forged mints within limit + limit x t / window.
    function invariant_forgedMintBounded() public view {
        uint256 t = vm.getBlockTimestamp() - handler.start();
        assertLe(handler.forgedMinted(), LIM + LIM * t / 1 days, "forged mint over the limiter's bound");
    }

    /// H1/H3: no message runs inside its hold, or with a payload the hold (or its RELEASE) did not bind.
    function invariant_heldNeverExecutesEarly() public view {
        assertEq(handler.heldExecuted(), 0, "a held message executed early or with another payload");
    }

    /// H4: one hold per nonce, and none longer than HOLD_TIME (a RELEASE only shortens it).
    function invariant_holdNeverRenewed() public view {
        assertEq(handler.holdRenewed(), 0, "a second hold accepted on a nonce");
        uint256 n = handler.heldCount();
        for (uint256 i; i < n; ++i) {
            uint64 nonce = handler.heldNonceAt(i);
            (, uint64 until) = rh.holds(HOME, _b32(address(home)), nonce);
            assertLe(until, handler.ghostHoldAt(nonce) + 72 hours, "a hold runs past HOLD_TIME");
        }
    }

    /// H2: an honest message whose hold ended always runs, for anyone, when nothing else stops it.
    function invariant_heldHonestNeverLost() public view {
        assertEq(handler.honestLost(), 0, "an honest held message could not run after HOLD_TIME");
    }

    /// D2: no queued transfer mints before receipt + DELAY.
    function invariant_claimNeverEarly() public view {
        assertEq(handler.earlyClaim(), 0, "a claim minted before DELAY");
    }

    /// D3: a cancelled claim never mints (until UNCANCEL), a paused path mints no claim, and only a pending claim cancels.
    function invariant_cancelledAndPausedNeverClaim() public view {
        assertEq(handler.cancelledClaimed(), 0, "a cancelled claim minted");
        assertEq(handler.pausedClaimed(), 0, "a claim minted on a paused path");
        assertEq(handler.badCancel(), 0, "a cancel accepted on a claim that was not pending");
    }

    /// D4/B2: a pending claim past DELAY on an open, untripped path is always claimable, by anyone.
    function invariant_claimNeverLost() public view {
        assertEq(handler.claimLost(), 0, "a due claim could not be claimed");
    }

    /// B1: no claim mints while the path's breaker is tripped, and the breaker is tripped whenever more than QUEUE_BREAKER
    /// was queued (since the last reset) within its window: the current UTC day and the BREAKER_DAYS - 1 before it.
    function invariant_breakerHolds() public view {
        assertEq(handler.trippedClaimed(), 0, "a claim minted on a tripped path");
        assertEq(handler.staleReset(), 0, "B3: a reset released a trip it does not name");
        (,, bool tripped, uint64 breakerSD,,,) = rh.breakers(HOME);
        // audit wave 5: against the path's CURRENT breaker, which the Safe may have lowered since the queue grew
        if (handler.ghostWindowQueued() > uint256(breakerSD) * 1e12) assertTrue(tripped, "over the breaker queued, not tripped");
    }

    /// D5: what mints at once (honest or forged, however split) stays within C + C x t / 1 day (C = DELAY_THRESHOLD).
    function invariant_instantMintBounded() public view {
        uint256 t = vm.getBlockTimestamp() - handler.start();
        uint256 thr = rh.DEFAULT_INSTANT_CAP();
        assertLe(
            handler.instantMinted(), thr + thr * t / (1 days), "instant mints over the per-path allowance"
        );
    }

    /// The empty allowance on every route (a review of the wave-5 fixes): from the last reopening (UNPAUSE, a cap raise, an inbound-limit raise) what mints
    /// at once is at most C x t / 1 day: the allowance restarts empty, so a stockpile cannot mint a fresh C at once.
    function invariant_reopeningStartsEmpty() public view {
        if (handler.reopenAt() == 0) return;
        uint256 t = vm.getBlockTimestamp() - handler.reopenAt();
        assertLe(handler.mintedSinceReopen(), rh.DEFAULT_INSTANT_CAP() * t / 1 days, "a reopening minted a fresh cap at once");
    }

    /// D7: queued == Σ pending claims, and supply == received - sent (token-only harness: no ledger terms).
    function invariant_queuedAccounting() public view {
        assertEq(rh.queued(), handler.ghostQueued(), "queued != pending claims");
        assertEq(rhTok.totalSupply(), rh.received() - rh.sent(), "rh supply != received - sent");
    }

    /// Audit wave 4: a proposal accepted at proposal time applies.
    function invariant_acceptedApplies() public view {
        assertEq(handler.acceptedNotApplied(), 0, "an accepted proposal reverted at application");
    }

    /// Non-hollow: one sequence through the main paths.
    function test_attackHandlerActionsSucceed() public {
        handler.send(100e18);
        handler.forge(2, 500e18, 0);
        handler.deliver(0);
        handler.deliver(1);
        handler.forge(2, 500e18, 0);
        handler.voidPayload(2);
        handler.reverify(2);
        handler.deliver(2);
        handler.govern(3);
        handler.passTime(1 hours);
        assertGt(handler.ok_deliver(), 1);
        assertGt(handler.ok_void(), 0);
        assertGt(handler.ok_govern(), 0);
        invariant_voidedNeverExecutes();
        invariant_heldNeverExecutesEarly();
        invariant_holdNeverRenewed();
        invariant_heldHonestNeverLost();
        invariant_acceptedApplies();
    }

    /// Non-hollow for the inbound delay (C = DELAY_THRESHOLD, D = DELAY, read from the bridge): an
    /// honest C mints at once and uses the allowance; the next honest transfer queues, is refused early, then claimed by a
    /// stranger after D; a forgery above C queues and is cancelled, refused after D, restored by UNCANCEL and claimed.
    function test_delayHandlerActionsSucceed() public {
        uint256 c = rh.DEFAULT_INSTANT_CAP();
        handler.send(c); // packet 0, nonce 1
        handler.deliver(0); // minted at once: the whole allowance
        handler.send(1_000e18); // packet 1, nonce 2
        handler.deliver(1); // does not fit the allowance: queued (claim 0)
        handler.claim(0, 7); // refused: too early (not lost: not due)
        handler.passTime(rh.DEFAULT_DELAY());
        handler.claim(0, 7); // claimed by a stranger
        handler.forge(2, c + 100e18, 0); // packet 2, nonce 3
        handler.deliver(2); // above the cap: queued (claim 1)
        handler.cancelClaim(1);
        handler.passTime(rh.DEFAULT_DELAY());
        handler.claim(1, 9); // refused: cancelled
        handler.govern(8); // UNCANCEL claim 1 (48h)
        handler.claim(1, 9);
        assertEq(handler.ok_claim(), 2);
        assertEq(handler.ok_cancel(), 1);
        assertEq(handler.ok_uncancel(), 1);
        assertEq(handler.instantMinted(), c);
        invariant_claimNeverEarly();
        invariant_cancelledAndPausedNeverClaim();
        invariant_claimNeverLost();
        invariant_instantMintBounded();
        invariant_queuedAccounting();
        invariant_forgedMintBounded();
        invariant_acceptedApplies();
    }

    /// Non-hollow for the queue breaker: queueing past QUEUE_BREAKER trips the path; a due claim is then
    /// refused (not lost: not due while tripped); RESET_BREAKER of the current trip releases it and the claim runs; the Safe
    /// trips it again by hand; a reset naming the earlier trip is refused.
    function test_breakerHandlerActionsSucceed() public {
        handler.forge(2, 30_000e18, 0); // packet 0: above the instant cap, queued (claim 0)
        handler.deliver(0);
        handler.passTime(1 days); // the limit refills; the same 4-day breaker window
        handler.forge(2, 30_000e18, 0); // packet 1: queued (claim 1), 60,000 > QUEUE_BREAKER: tripped
        handler.deliver(1);
        (, uint16 trips, bool tripped,,,,) = rh.breakers(HOME);
        assertTrue(tripped);
        assertEq(trips, 1);
        handler.passTime(rh.DEFAULT_DELAY());
        handler.claim(0, 7); // refused: tripped
        assertEq(handler.ok_claim(), 0);
        handler.govern(9); // RESET_BREAKER(trip 1), 48h
        assertEq(handler.ok_reset(), 1);
        handler.claim(0, 7);
        assertEq(handler.ok_claim(), 1);
        handler.tripBreaker(); // trip 2, by the Safe
        handler.govern(10); // a reset naming trip 1: refused at proposal
        assertEq(handler.ok_reset(), 1);
        handler.claim(1, 7); // refused: tripped
        assertEq(handler.ok_claim(), 1);
        invariant_breakerHolds();
        invariant_claimNeverLost();
        invariant_queuedAccounting();
        invariant_acceptedApplies();
    }

    /// Non-hollow for holds: an honest message held, refused, then run by a stranger after HOLD_TIME; a forged one held,
    /// not renewable, then released early by the timelock (a Safe decision).
    function test_holdHandlerActionsSucceed() public {
        handler.send(100e18); // packet 0, nonce 1
        handler.hold(0);
        handler.deliver(0); // refused: held
        handler.forge(2, 700e18, 0); // packet 1, nonce 2
        handler.hold(1);
        handler.hold(1); // a no-op: no renewal (a review of the wave-5 fixes)
        handler.govern(7); // RELEASE of the last hold (nonce 2), 48h
        handler.deliver(1);
        handler.passTime(36 hours);
        handler.runExpired(0);
        assertEq(handler.ok_hold(), 2);
        assertEq(handler.ok_release(), 1);
        assertEq(handler.ok_expiredRun(), 1);
        assertEq(handler.ok_deliver(), 2);
        invariant_heldNeverExecutesEarly();
        invariant_holdNeverRenewed();
        invariant_heldHonestNeverLost();
        invariant_acceptedApplies();
    }

    /// Non-hollow for the reopening routes (a review of the wave-5 fixes): a cap restore, an inbound close + UNPAUSE, an inbound reopen, each
    /// a reopening, with a stockpile run after each; the invariant holds.
    function test_reopenRoutesHandlerActionsSucceed() public {
        handler.tightenCap(0);
        handler.forge(2, 2_000e18, 0); // packet 0, stockpiled
        handler.forge(2, 2_000e18, 0); // packet 1
        handler.forge(2, 2_000e18, 0); // packet 2
        handler.passTime(1 days);
        handler.govern(11); // C restored: reopening 1
        assertEq(handler.reopenings(), 1);
        handler.deliver(0);
        invariant_reopeningStartsEmpty();
        handler.govern(12); // pause + inbound closed
        handler.govern(4); // UNPAUSE: reopening 2
        assertEq(handler.reopenings(), 2);
        handler.passTime(1 days);
        handler.govern(13); // inbound reopened: reopening 3
        assertEq(handler.reopenings(), 3);
        handler.deliver(1);
        handler.deliver(2);
        assertGt(handler.ok_deliver(), 2);
        invariant_reopeningStartsEmpty();
        invariant_queuedAccounting();
        invariant_acceptedApplies();
    }
}
