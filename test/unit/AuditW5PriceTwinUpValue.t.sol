// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {ILedgerCover, IBackstopOracle} from "../../src/backstop/IBackstop.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {DoorLeaf, MockProven} from "./PricerTwin.t.sol";
import {TlRate} from "./AuditW4TwinLag.t.sol";

/// @notice AUDIT WAVE 5 (price re-check, medium: the twin rule's `: s` arm). With the legs apart and the proven spot ABOVE
/// the median, the Pricer sets low = high = payout = the spot, with no upper bound: one pushed-UP proven block end (no key)
/// does it. That is accepted for liquidation health (it only shelters, until a newer block is proved), but PricerOracle
/// handed the same number to the Backstop as a GOOD price: `nav()` values every held token at `high`, and `_convert` mints a
/// matured deposit bucket's shares at that nav, so a pushed-up proof dilutes the converting buckets.
///
/// PROPERTY (value readers): PricerOracle.priceOf reports `ok` only for a `high` the MEDIAN supports: high <= median x
/// (1 + skew). In agreement that always holds (high = max(median, spot) within skew); a disagreeing type whose only higher
/// value is one leg alone (the proven spot above the median) reads unpriced, so `nav()` fails closed and conversions wait,
/// exactly as for an unpriced token. Liquidation (Pricer.low) is unchanged. The other disagreeing shapes (the median rule,
/// the twin's down arm: high <= median) keep reading as priced, so sales and auctions are not stalled by them.
contract AuditW5PriceTwinUpValueTest is System {
    bytes32 constant TWIN = "SIMD";
    bytes32 constant PLAIN = "PLAIN";
    uint256 constant SKEW = 0.05e18;
    uint256 constant A = 4e15;

    DoorLeaf leaf;
    DoorLeaf plainLeaf;
    MockProven proven;
    MockFeed plainSpot;
    MockFeed eth;
    MockFeed live;
    TlRate vault;
    IFeed median;
    PricerOracle oracle;
    address twinToken;
    address plainToken;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        leaf = new DoorLeaf();
        leaf.set(A);
        plainLeaf = new DoorLeaf();
        plainLeaf.set(A);
        proven = new MockProven(A);
        proven.setMaxAge(6 hours);
        plainSpot = new MockFeed(A);
        plainSpot.setMaxAge(6 hours);
        eth = new MockFeed(2000e18);
        eth.setMaxAge(type(uint64).max);
        live = new MockFeed(type(uint128).max);
        live.setMaxAge(type(uint64).max);
        vault = new TlRate();
        median = IFeed(
            address(new RateFeed(address(vault), TlRate.convertToAssets.selector, true, new ProductFeed(IFeed(address(leaf)), eth), 0))
        );
        IFeed spot = IFeed(
            address(new RateFeed(address(vault), TlRate.convertToAssets.selector, true, new ProductFeed(IFeed(address(proven)), eth), 0))
        );
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        ParametersBase.Risk memory r = _risk(1.7e18, 10_000_000e18);
        r.skew = uint64(SKEW);
        r.redeemCap = 20_000e18;
        twinToken = address(new MockERC20("sIMD", 18));
        plainToken = address(new MockERC20("X", 18));
        _addIlk(TWIN, twinToken, median, spot, IFeed(address(0)), address(0), address(0), live, true, r);
        _addIlk(
            PLAIN,
            plainToken,
            new ProductFeed(IFeed(address(plainLeaf)), eth),
            new ProductFeed(IFeed(address(plainSpot)), eth),
            IFeed(address(0)),
            address(0),
            address(0),
            true,
            r
        );
        params.seal();
        oracle = new PricerOracle(pricer, address(params));
        oracle.setIlk(twinToken, TWIN);
        oracle.setIlk(plainToken, PLAIN);
    }

    /// The judge's proof: one pushed-up proof (10x), no key. On 422a337 PricerOracle reports high = $88 (10x the median) ok.
    function test_judgeProof_pushedUpProofIsNotAValue() public {
        proven.set(10 * A);
        Pricer.Quote memory q = pricer.quote(TWIN);
        (uint256 m,) = median.latestValue();
        assertTrue(q.priced);
        assertFalse(q.agree);
        assertEq(q.high, 10 * m, "the Pricer's `: s` arm (unchanged: liquidation health only)");
        (, uint256 high, bool ok) = oracle.priceOf(twinToken);
        assertFalse(ok && high > m + m * SKEW / 1e18, "a lone pushed-up proof is valued by the Backstop above the median");
        assertFalse(ok);
    }

    /// The property, fuzzed over leaf histories (honest, pushed, keyed, clamped), a proven price anywhere, and the plain type.
    function testFuzz_okOnlyForAValueTheMedianSupports(uint256 seed, uint8 n, uint256 pSeed, uint256 sSeed) public {
        for (uint256 i; i < uint256(n) % 7; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + bound(r, 0, 3 hours));
            leaf.set(A * bound(r >> 32, 1, 300_000) / 10_000 + 1);
            plainLeaf.set(A * bound(r >> 64, 1, 300_000) / 10_000 + 1);
            if ((r >> 128) % 2 == 0) leaf.set(A * bound(r >> 160, 1, 300_000) / 10_000 + 1);
        }
        proven.set(A * bound(pSeed, 1, 300_000) / 10_000 + 1);
        plainSpot.set(A * bound(sSeed, 1, 300_000) / 10_000 + 1);
        _check(TWIN, twinToken);
        _check(PLAIN, plainToken);
    }

    function _check(bytes32 ilk, address token) internal view {
        Pricer.Quote memory q = pricer.quote(ilk);
        (uint256 m,) = params.config(ilk).median.latestValue();
        (uint256 low, uint256 high, bool ok) = oracle.priceOf(token);
        if (ok) {
            assertLe(high, m + Math.mulDiv(m, SKEW, 1e18), "a value above what the median supports reported good");
            assertEq(low, q.low);
            assertEq(high, q.high);
        }
        // Liveness: agreement and every disagreeing shape whose high the median supports stay priced (sales, auctions run).
        if (q.priced && q.low != 0 && q.high <= m + Math.mulDiv(m, SKEW, 1e18)) assertTrue(ok, "refused a supported value");
    }

    /// The twin's down arm (a pushed-down proof under a converged median: low = high = median) and agreement stay priced.
    function test_downArmAndAgreementStayPriced() public {
        (,, bool ok) = oracle.priceOf(twinToken);
        assertTrue(ok, "agreement");
        proven.set(A / 2);
        (, uint256 high, bool ok2) = oracle.priceOf(twinToken);
        (uint256 m,) = median.latestValue();
        assertTrue(ok2, "down arm");
        assertEq(high, m);
    }

    /// A REVIEW OF THE WAVE-5 FIXES: the retire() StillPriced window. While a pushed-up proof makes priceOf refuse sIMD, a pending
    /// RETIRE_SLEEVE_TOKEN (48 h timelock, anyone may apply it) passed Backstop.retire's "refused while priced" check and set
    /// the token at 0 for conversions. PROPERTY: retire refuses whenever the type is PRICED (the oracle reports any price,
    /// ok or refused as a one-leg value); only a type with no price at all (stale median or NHI, no quote) may be retired.
    function test_retireRefusedWhileRefusedForAOneLegValue() public {
        Backstop edge = new Backstop(
            IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), true, "edge", "eBACK"
        );
        edge.wire(address(liquidator), address(this), address(0));
        edge.addIlk(TWIN, twinToken, 0, type(uint128).max, 0);
        edge.seal();
        proven.set(10 * A); // one pushed-up proof: priceOf refuses
        (,, bool ok) = oracle.priceOf(twinToken);
        assertFalse(ok);
        vm.expectRevert(Backstop.StillPriced.selector);
        edge.retire(twinToken, true);
        // a dead feed (median stale) can still be retired
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertFalse(pricer.quote(TWIN).priced);
        edge.retire(twinToken, true);
        assertTrue(edge.retired(twinToken));
    }
}
