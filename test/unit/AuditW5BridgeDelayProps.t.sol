// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";

/// @notice The inbound delay's NEW properties, written against the bridge's pre-delay surface only (deliver + balances), so
/// this file compiles and FAILS on the pre-delay bridge, where a verified packet mints in the call that executes it.
/// C = DELAY_THRESHOLD (the instant cap per path per day) and D = DELAY are read from the
/// bridge; the pre-delay bridge has neither, so there the decided values (5,000 and 12 h) stand in.
///  D1 A message above C mints nothing when it executes, nor at any time before D.
///  D5 However a forger splits (a compromised DVN set signs any number of messages), what mints AT ONCE on a path within
///     any interval t is at most C + C x t / 1 day.
///  D6 A transfer that fits the instant allowance mints at once, as before (passes on the pre-delay bridge too).
contract AuditW5BridgeDelayPropsTest is W4Bridge {
    uint256 constant L = 50_000e18; // the harness's limit per path (the launch value)
    uint256 C;
    uint256 D;

    function setUp() public {
        _setUpW4();
        _openBoth(L);
        C = _const("DEFAULT_INSTANT_CAP()", 5_000e18);
        D = _const("DELAY()", 12 hours);
    }

    /// @dev The bridge's constant, or `decided` on a bridge without it (the pre-delay bridge).
    function _const(string memory sig, uint256 decided) internal view returns (uint256) {
        (bool ok, bytes memory r) = address(rh).staticcall(abi.encodeWithSignature(sig));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : decided;
    }

    /// D1: a forged message above the cap executes (its nonce is spent) but mints nothing, still nothing 1 s before D.
    function test_largeForgedMessageMintsNothingBeforeDelay() public {
        uint256 a = C + 1_000e18;
        uint256 i = _forge(a);
        assertTrue(homeEp.deliver(i), "executes: the nonce is consumed and the amount metered");
        assertEq(rhTok.balanceOf(attacker), 0, "a forged large transfer is spendable the moment it is verified");
        assertEq(rh.availableIn(HOME), L - a, "metered at receipt");
        vm.warp(vm.getBlockTimestamp() + D - 1);
        assertEq(rhTok.balanceOf(attacker), 0);
    }

    /// D1 for an honest message too: one transfer over the cap always waits, even with the allowance unused.
    function test_largeHonestMessageWaits() public {
        uint256 i = _send(alice, C + 1e12);
        assertTrue(homeEp.deliver(i));
        assertEq(rhTok.balanceOf(alice), 0);
    }

    /// D6: exactly the cap, then small transfers while the allowance lasts, mint at once.
    function test_smallTransfersStayInstant() public {
        assertTrue(homeEp.deliver(_send(alice, C)));
        assertEq(rhTok.balanceOf(alice), C);
        vm.warp(vm.getBlockTimestamp() + 1 days); // the allowance refills
        assertTrue(homeEp.deliver(_send(alice, C / 4)));
        assertTrue(homeEp.deliver(_send(alice, C / 4)));
        assertEq(rhTok.balanceOf(alice), C + C / 2);
    }

    /// D5, the split attack: many sub-cap forgeries (up to C / 2 each) at random times. Without a per-path instant cap
    /// each would mint at once and the bound would be the inbound limit's (L + L x t / 1 day).
    function testFuzz_splitForgeryMintsAtOnceWithinTheInstantBound(uint256 seed) public {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 k; k < 24; ++k) {
            seed = uint256(keccak256(abi.encode(seed)));
            vm.warp(vm.getBlockTimestamp() + seed % 3 hours);
            uint256 a = 10e18 + (seed >> 64) % (C / 2 - 10e18 + 1);
            homeEp.deliver(_forge(a / 1e12 * 1e12));
            uint256 t = vm.getBlockTimestamp() - t0;
            assertLe(
                rhTok.balanceOf(attacker), C + C * t / 1 days, "split forgery minted at once past the instant bound"
            );
        }
    }

    /// D5, the judge-style burst: ten forgeries of C / 2 in one block mint exactly C at once (the rest is metered).
    function test_splitBurstInOneBlock() public {
        for (uint256 k; k < 10; ++k) {
            assertTrue(homeEp.deliver(_forge(C / 2)));
        }
        assertEq(rhTok.balanceOf(attacker), C, "only the instant allowance minted at once");
        assertEq(rh.availableIn(HOME), L - 5 * C, "the rest was metered (and waits)");
    }
}
