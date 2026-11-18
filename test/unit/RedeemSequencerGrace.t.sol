// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {IPulse} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

/// @notice 12-07: redemption respects the sequencer grace on a chain with a Pulse (4663).
/// PROPERTY: no redemption executes while the type's chain is down (a silence longer than the Pulse's gap that no poke
/// has ended yet) or inside the grace that follows the poke ending it. Outside those, redemption works as before. A chain
/// with no Pulse (Ethereum) is unchanged.
/// On the pre-fix code (the Redeemer did not read the Pulse) the fuzz test fails: a redemption in the first block after a
/// silence, or inside the grace, goes through while liquidations are held.
contract RedeemSequencerGraceTest is System {
    bytes32 constant ETH = "ETH";
    uint256 constant GAP = 15 minutes; // RobinhoodConfig: Pulse gap
    uint256 constant GRACE = 1 hours; // RobinhoodConfig: Pulse grace

    MockERC20 weth;
    MockFeed ethFeed;
    Pulse pulse;
    bool withPulse = true;

    address alice = makeAddr("alice");
    address dave = makeAddr("dave");

    function _pulse() internal override returns (IPulse) {
        if (!withPulse) return IPulse(address(0));
        pulse = new Pulse(GAP, GRACE);
        return IPulse(address(pulse));
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        _build();
    }

    function _build() internal {
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2000e18);
        ethFeed.setMaxAge(365 days); // the test is about the Pulse, not feed age
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        ParametersBase.Risk memory er = _risk(1.4e18, 100_000_000e18);
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, er);
        params.seal();
        weth.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(int256(10_000e18), int256(5_000_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        usd.transfer(dave, 5_000_000e18);
        vm.stopPrank();
    }

    /// @dev Walk forward with the chain alive: the keeper pokes more often than the gap.
    function _alive(uint256 len) internal {
        while (len != 0) {
            uint256 s = len < 10 minutes ? len : 10 minutes;
            vm.warp(vm.getBlockTimestamp() + s);
            pulse.poke();
            len -= s;
        }
    }

    function _tryRedeem() internal returns (bool ok) {
        vm.prank(dave);
        try redeemer.redeem(ETH, 1_000e18, 0.05e18, 10, 0) returns (uint256 r, uint256) {
            ok = r != 0;
        } catch {
            ok = false;
        }
    }

    /// PROPERTY (fuzzed): outage start, outage length, whether anyone pokes in the first block after it, and when the
    /// redemption is tried (with the keeper keeping the chain alive in between, or not).
    /// - silence <= gap: never a grace, redemption works.
    /// - silence > gap: refused from the first block after the outage until `poke that ended it + grace`; works once
    ///   the grace has run out (if the chain was poked meanwhile).
    function testFuzz_noRedemptionWhileDownOrInGrace(
        uint256 before,
        uint256 silence,
        uint256 tryAfter,
        bool pokedAtReturn,
        bool keeperAlive
    ) public {
        before = bound(before, 0, 3 hours);
        silence = bound(silence, 1, 6 hours);
        tryAfter = bound(tryAfter, 0, 3 hours);

        _alive(before);
        // The sequencer is down: no block at all for `silence` seconds.
        vm.warp(vm.getBlockTimestamp() + silence);
        uint256 back = vm.getBlockTimestamp();
        bool longSilence = silence > GAP;

        // In the first block back, a redemption (maybe after someone's poke in the same block).
        if (pokedAtReturn) pulse.poke();
        bool ok0 = _tryRedeem();
        if (longSilence) assertFalse(ok0, "redeemed in the first block after a long silence");
        else assertTrue(ok0, "a short silence must not stop redemption");

        // Later, with or without the keeper's pokes in between.
        if (keeperAlive) _alive(tryAfter);
        else vm.warp(vm.getBlockTimestamp() + tryAfter);
        uint256 t = vm.getBlockTimestamp();
        bool ok1 = _tryRedeem();

        // Whatever happened, a success implies: no pending silence and outside any grace.
        if (ok1) {
            assertFalse(pulse.inGrace(), "redeemed while the Pulse reads a grace");
            if (longSilence) {
                assertTrue(pokedAtReturn || keeperAlive, "redeemed while the silence was never ended");
                assertGe(t, back + GRACE, "redeemed inside the grace after the outage");
            }
        }
        // Liquidations and redemption agree exactly: redemption is refused iff the Pulse holds seizing (no other reason
        // to refuse here), so the grace ends for both at once and redemption reopens.
        assertEq(ok1, !pulse.inGrace(), "redemption and the liquidation hold disagree");
        // With the chain kept alive and the grace run out, redemption has reopened.
        if (keeperAlive && longSilence && t >= pulse.graceUntil() && tryAfter != 0) assertTrue(ok1, "did not reopen");
        if (keeperAlive && !longSilence) assertTrue(ok1, "a short silence must not stop redemption");
    }

    /// The direct case: inside the grace a redemption reverts with SequencerGrace, after it it works.
    function test_graceRefusesThenReopens() public {
        vm.warp(vm.getBlockTimestamp() + 2 hours); // sequencer down for 2 h
        vm.prank(dave);
        vm.expectRevert(Redeemer.SequencerGrace.selector);
        redeemer.redeem(ETH, 1_000e18, 0.05e18, 10, 0);
        pulse.poke(); // the chain is back: the grace starts now
        _alive(GRACE - 1);
        vm.prank(dave);
        vm.expectRevert(Redeemer.SequencerGrace.selector);
        redeemer.redeem(ETH, 1_000e18, 0.05e18, 10, 0);
        _alive(1);
        assertTrue(_tryRedeem(), "reopens when the grace ends");
    }

    /// Ethereum (no Pulse): unchanged, a long quiet period does not stop redemption.
    function test_noPulseUnchanged() public {
        withPulse = false;
        _build();
        assertEq(address(redeemer.pulse()), address(0));
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        assertTrue(_tryRedeem(), "no Pulse: redemption unaffected");
    }
}
