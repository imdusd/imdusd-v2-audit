// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {DoorNhiLeaf} from "./PricerTwin.t.sol";

/// @notice FIXED BEFORE AUDIT WAVE 5 (NHI bound per TIME, not per epoch). Wave 4 bounded NHI one cap per
/// EPOCH, but epochs abut: an attestation at the last second of one epoch and another at the first second of the next
/// moved NHI two caps one second apart (0.85 -> 0.68 -> 0.544, mat 1.7 -> 2.0).
/// PROPERTY (P-window): over ANY window of one maxAge (half-open, [t, t + maxAge), the NHI leaf's 1 day), every value the
/// feed holds lies within ONE cap of a single value it held during the maxAge before the window, so NHI, and with it
/// liquidation mat, moves at most one cap per maxAge of time, whatever the timing (1 s apart across a boundary, after
/// silences, many in a row).
contract AuditW5NhiWindowTest is System {
    bytes32 constant SIMD = "SIMD";
    uint256 constant CAP = 2000;
    uint256 constant T = 1 days;
    uint256 constant N = 14;

    DoorNhiLeaf nhi;
    MockFeed price;

    uint256[] times;
    uint256[] vals;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
        nhi = new DoorNhiLeaf();
        nhi.set(0.98e18);
        price = new MockFeed(100e18);
        price.setMaxAge(type(uint64).max);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        ParametersBase.Risk memory r = _risk(1.7e18, 10_000_000e18);
        r.skew = 0.05e18;
        _addIlk(
            SIMD,
            address(new MockERC20("sIMD", 18)),
            IFeed(address(price)),
            IFeed(address(price)),
            IFeed(address(nhi)),
            address(0),
            address(0),
            true,
            r
        );
    }

    function _stored() internal view returns (uint256 v) {
        (v,) = nhi.latestValue();
    }

    function _matOf(uint256 n) internal pure returns (uint256) {
        if (n >= 0.85e18) return 1.7e18;
        if (n <= 0.6e18) return 2e18;
        return 1.7e18 + Math.mulDiv(0.85e18 - n, 0.3e18, 0.25e18, Math.Rounding.Ceil);
    }

    /// @dev Walk onto `v` with daily attestations, then let it sit a whole epoch (held, unchanged, for > maxAge).
    function _settleAt(uint256 v) internal {
        for (uint256 i; i < 40 && (_stored() != v || !nhi.converged()); ++i) {
            vm.warp(vm.getBlockTimestamp() + T);
            nhi.set(v);
        }
        assertEq(_stored(), v);
        vm.warp(vm.getBlockTimestamp() + T + 1);
    }

    function _record() internal {
        times.push(vm.getBlockTimestamp());
        vals.push(_stored());
    }

    function _inBand(uint256 v, uint256 r) internal pure returns (bool) {
        uint256 d = Math.mulDiv(r, CAP, 10_000);
        return v + 1 >= r - d && v <= r + d + 1;
    }

    /// @dev The value held just before time `t` (the last record strictly before it); records[0] is held since long ago.
    function _heldBefore(uint256 t) internal view returns (uint256 idx) {
        for (uint256 i; i < times.length && times[i] < t; ++i) idx = i;
    }

    /// @dev P-window for the window starting at `t`: some R held during [t - T, t) bounds every value held in [t, t + T).
    function _windowHolds(uint256 t) internal view returns (bool) {
        uint256 first = _heldBefore(t); // the value held as the window opens
        uint256 rFirst = _heldBefore(t - T); // candidates: held just before t - T, and every record in [t - T, t)
        for (uint256 r = rFirst; r <= first; ++r) {
            bool ok = true;
            for (uint256 j = first; j < times.length && ok; ++j) {
                if (j != first && times[j] >= t + T) break;
                if (j != first && times[j] < t) continue;
                ok = _inBand(vals[j], vals[r]);
            }
            if (ok) return true;
        }
        return false;
    }

    function _checkAllWindows() internal view {
        for (uint256 i = 1; i < times.length; ++i) {
            // windows opening at a change and one second before it (so the value before the change is in the window)
            assertTrue(_windowHolds(times[i]), "NHI moved more than one cap inside one maxAge (window at a change)");
            assertTrue(_windowHolds(times[i] - 1), "NHI moved more than one cap inside one maxAge (window before a change)");
        }
    }

    /// The reviewer's sequence: 0.85 held, one attestation of 1 wei at the epoch's last second, another at the next
    /// epoch's first second. Was: 0.85 -> 0.68 -> 0.544, mat 1.7 -> 2.0 one second apart.
    function test_twoAttestationsStraddlingTheBoundary() public {
        _settleAt(0.85e18);
        nhi.set(0.85e18); // opens an epoch at 0.85 now
        (, uint64 openedAt,) = nhi.epoch();
        vm.warp(uint256(openedAt) + T - 1);
        nhi.set(1);
        assertEq(_stored(), 0.68e18);
        vm.warp(uint256(openedAt) + T);
        nhi.set(1);
        assertEq(_stored(), 0.68e18, "the second attestation, one second later, moves nothing more");
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertLe(q.mat, _matOf(0.68e18), "mat within one cap of NHI over the second");
        // a full maxAge after the last move the next cap is open again (liveness)
        vm.warp(uint256(openedAt) + 2 * T - 1);
        nhi.set(1);
        assertEq(_stored(), 0.68e18, "still inside the window of the 0.68 move");
        vm.warp(uint256(openedAt) + 2 * T);
        nhi.set(1);
        assertEq(_stored(), 0.544e18, "one cap per maxAge, not one per epoch boundary");
    }

    /// PROPERTY (fuzzed): from any settled NHI, up to N attestations at chosen gaps (1 s, minutes, an epoch's last second,
    /// its first second, silences past a day) with any targets: every window of one maxAge stays within one cap of a value
    /// held in the maxAge before it, and the Pricer's mat with it.
    function testFuzz_oneCapPerWindowOfTime(uint256 sSeed, uint256 seed, uint8 n) public {
        uint256 s0 = bound(sSeed, 0.3e18, 1.2e18);
        _settleAt(s0);
        _record();
        n = uint8(bound(n, 2, N));
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 now_ = vm.getBlockTimestamp();
            (, uint64 openedAt,) = nhi.epoch();
            uint256 end = uint256(openedAt) + T; // when the live epoch (or the one a delivery now would open) ends
            uint256 k = r % 8;
            uint256 at = k == 0
                ? now_ + 1
                : k == 1
                    ? now_ + (r >> 8) % 1 hours
                    : k == 2
                        ? (end - 1 > now_ ? end - 1 : now_)
                        : k == 3
                            ? (end > now_ ? end : now_)
                            : k == 4 ? (end + 1 > now_ ? end + 1 : now_) : k == 5 ? now_ + T + (r >> 8) % 3 days : now_ + (r >> 8) % T;
            vm.warp(at);
            uint256 tk = (r >> 64) % 3;
            uint256 target = tk == 0 ? 1 : tk == 1 ? 1e24 : bound(r >> 96, 1, 2e18);
            nhi.set(target);
            _record();
            Pricer.Quote memory q = pricer.quote(SIMD);
            assertGe(q.mat, 1.7e18);
        }
        _checkAllWindows();
    }

    /// LIVENESS (fuzzed): honest attestations of H every hour reach H; the window rule costs at most one extra epoch per
    /// cap (a move inside the last maxAge holds the next epoch inside the previous anchor's band). Bound: 2 x ceil(ln(ratio)
    /// / ln(1 + cap)) + 2 days.
    function testFuzz_honestHourlyReachesTheLevel(uint256 sSeed, uint256 hSeed) public {
        uint256 s0 = bound(sSeed, 0.3e18, 1.2e18);
        uint256 h = bound(hSeed, 0.3e18, 1.2e18);
        _settleAt(s0);
        uint256 hi = s0 > h ? s0 : h;
        uint256 lo = s0 > h ? h : s0;
        uint256 k;
        uint256 x = lo;
        while (x < hi) {
            x = x * (10_000 + CAP) / 10_000;
            ++k;
        }
        for (uint256 i; i <= (2 * k + 2) * 24; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            nhi.set(h);
            if (_stored() == h) return;
        }
        assertTrue(false, "honest NHI not reached");
    }
}
