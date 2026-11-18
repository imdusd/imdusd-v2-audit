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

/// @notice AUDIT WAVE 4 (price design, medium: NHI outside the twin sets mat from an unconverged value). PROPERTY: within
/// any one NHI epoch, whatever the silence before it and whatever sequence of attested targets lands in it, the stored NHI
/// stays within ONE cap of the epoch's anchor (the stored value when it opened), so liquidation mat moves at most
/// _mat(anchor x (1 - cap)) - _mat(anchor) per epoch (one day); and an honest level is still reached within
/// ceil(ln(ratio) / ln(1 + cap)) epochs (no lock-out). Production NHI policy: 1 day, 2,000 bps (DeployConfig).
contract AuditW4NhiMatTest is System {
    bytes32 constant SIMD = "SIMD";
    uint256 constant CAP = 2000;

    DoorNhiLeaf nhi;
    MockFeed price;

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

    function _matOf(uint256 n) internal pure returns (uint256) {
        if (n >= 0.85e18) return 1.7e18;
        if (n <= 0.6e18) return 2e18;
        return 1.7e18 + Math.mulDiv(0.85e18 - n, 0.3e18, 0.25e18, Math.Rounding.Ceil);
    }

    function _stored() internal view returns (uint256 v) {
        (v,) = nhi.latestValue();
    }

    /// @dev Walk the leaf onto `v` with daily attestations, then let the epoch close (the next one anchors at `v`).
    function _settleAt(uint256 v) internal {
        for (uint256 i; i < 40 && (_stored() != v || !nhi.converged()); ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            nhi.set(v);
        }
        assertEq(_stored(), v);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    /// The judge's proof: the daily refresh an hour late, then ONE signed value of 1 wei. Was: stored 0.588, mat 2.0.
    function test_judgeProof_oneAttestationAfterSilence() public {
        assertEq(pricer.quote(SIMD).mat, 1.7e18);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1 hours + 1);
        nhi.set(1);
        assertEq(_stored(), 0.784e18, "one cap, not two");
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertFalse(nhi.converged());
        assertTrue(q.priced);
        assertFalse(q.borrowable, "an unconverged NHI still stops borrowing");
        assertLe(q.mat, 1.785e18, "liquidation mat within skew of 1.7 from 0.98");
    }

    /// PROPERTY (fuzzed over the starting NHI, the silence before the epoch, and up to 8 targets inside the epoch at chosen
    /// times): the stored NHI stays within one cap of the epoch's anchor, and the Pricer's mat within the cap's mat.
    function testFuzz_oneCapPerEpochWhateverTheSilence(uint256 sSeed, uint256 silenceSeed, uint256 seed, uint8 n) public {
        uint256 s0 = bound(sSeed, 0.3e18, 1.2e18);
        _settleAt(s0);
        uint256 anchor = s0; // the next epoch opens at the stored value
        vm.warp(vm.getBlockTimestamp() + bound(silenceSeed, 0, 10 days)); // any further silence, incl. past 25 h
        uint256 t0 = vm.getBlockTimestamp();
        n = uint8(bound(n, 1, 8));
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 target = r % 3 == 0 ? 1 : r % 3 == 1 ? 1e24 : bound(r >> 8, 1, 2e18);
            vm.warp(t0 + bound(r >> 128, 0, 1 days - 1) * i / n); // inside one epoch, nondecreasing
            nhi.set(target);
            uint256 v = _stored();
            uint256 d = anchor * CAP / 10_000;
            assertGe(v, anchor - d, "fell more than one cap in the epoch");
            assertLe(v, anchor + d, "rose more than one cap in the epoch");
            Pricer.Quote memory q = pricer.quote(SIMD);
            assertLe(q.mat, _matOf(anchor - d), "mat moved beyond one cap of NHI");
        }
    }

    /// LIVENESS (fuzzed): from any stored NHI, honest daily attestations of H (some days late) reach H within
    /// ceil(ln(ratio) / ln(1 + cap)) epochs: removing the widening slows a gap after a silence, never stops it.
    function testFuzz_honestLevelReachedWithinTheBound(uint256 sSeed, uint256 hSeed, uint256 lateSeed) public {
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
        for (uint256 i; i <= k + 1; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days + (uint256(keccak256(abi.encode(lateSeed, i))) % 3 hours));
            nhi.set(h);
            if (_stored() == h) return;
        }
        assertTrue(false, "honest NHI not reached within the bound");
    }
}
