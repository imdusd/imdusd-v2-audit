// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";

/// @notice The queue circuit breaker's no-action bound, written
/// against the delay's surface only (deliver, claim, balances), so it compiles and FAILS on the bridge without a breaker:
/// there a forger who queues under the 50,000/day limit claims everything 12 h later.
///  B1 With no human action, what a forged stream makes spendable on a path in any 72 h (HOLD_TIME, the weekend the Safe may
///     take) is at most the instant part, C x (1 + 72 h / 1 day) = 4C, plus QUEUE_BREAKER: however the forger splits, times
///     and claims. With QUEUE_BREAKER 50,000 (whales) that is 70,000, above the 4663 line by decision.
///  B4 With the Safe acting within DELAY (cancelling every queued forgery), what is spendable is the instant part only,
///     C x (1 + DELAY / 1 day) = 7,500, within the 4663 chain line (30,000): the bound that holds the line.
/// C = DELAY_THRESHOLD and B = QUEUE_BREAKER are read from the bridge; without them the decided values (5,000; 50,000) stand
/// in.
contract AuditW5BridgeBreakerPropsTest is W4Bridge {
    uint256 constant L = 50_000e18; // the launch limit per path
    uint256 C;
    uint256 B;
    uint256[] keys; // packet indexes of forged messages, claimed by the forger as soon as they can be

    function setUp() public {
        _setUpW4();
        _openBoth(L);
        C = _const("DEFAULT_INSTANT_CAP()", 5_000e18);
        B = _const("DEFAULT_QUEUE_BREAKER()", 50_000e18);
    }

    function _const(string memory sig, uint256 decided) internal view returns (uint256) {
        (bool ok, bytes memory r) = address(rh).staticcall(abi.encodeWithSignature(sig));
        return ok && r.length == 32 ? abi.decode(r, (uint256)) : decided;
    }

    /// @dev The forger claims every matured claim it can (a claim that reverts is skipped).
    function _claimAll() internal {
        for (uint256 k; k < keys.length; ++k) {
            bytes32 key = _claimKey(homeEp, keys[k]);
            vm.prank(attacker);
            (bool ok,) = address(rh).call(abi.encodeWithSignature("claim(uint32,bytes32)", HOME, key));
            ok;
        }
    }

    function _forgeAndRun(uint256 amount) internal {
        uint256 i = _forge(amount / 1e12 * 1e12);
        if (homeEp.deliver(i)) keys.push(i);
    }

    /// B1, the patient forger: the instant allowance as it refills (C / 24 an hour) and, once a day, one queued message just
    /// under B (a breaker on a 1-day window never trips), claiming everything the moment it matures, for 72 h.
    function test_patientForgerWithinTheNoActionBound() public {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 h; h <= 72; ++h) {
            if (h % 24 == 0) _forgeAndRun(B - 1e18);
            _forgeAndRun(h == 0 ? C : C / 24);
            _claimAll();
            if (h < 72) vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        assertEq(vm.getBlockTimestamp(), t0 + 72 hours);
        assertLe(rhTok.balanceOf(attacker), 4 * C + B, "forged stream spendable in 72 h past 4C + QUEUE_BREAKER");
    }

    /// B1 fuzzed: random sizes (up to the limit), random gaps, the forger claims after every step; the bound holds at every
    /// step of the 72 h.
    function testFuzz_forgedStreamWithinTheNoActionBound(uint256 seed) public {
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 k; k < 40; ++k) {
            seed = uint256(keccak256(abi.encode(seed)));
            vm.warp(vm.getBlockTimestamp() + seed % 4 hours);
            if (vm.getBlockTimestamp() > t0 + 72 hours) break;
            uint256 cap = (seed >> 32) % 4 == 0 ? L / 4 : B / 2;
            _forgeAndRun(10e18 + (seed >> 64) % cap);
            _claimAll();
            assertLe(rhTok.balanceOf(attacker), 4 * C + B, "forged stream spendable in 72 h past 4C + QUEUE_BREAKER");
        }
        vm.warp(t0 + 72 hours);
        _claimAll();
        assertLe(rhTok.balanceOf(attacker), 4 * C + B, "forged stream spendable in 72 h past 4C + QUEUE_BREAKER");
    }

    /// B4: the forger floods the path (instant allowance as it refills, and as much as the limit lets queue each hour); the
    /// Safe cancels every queued claim just before it matures (within DELAY). Over 72 h the forger spends only the instant
    /// part, and within any DELAY span at most C x (1 + DELAY / 1 day), within the 4663 line.
    function test_safeWithinDelayHoldsTheLine() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 cancelled;
        for (uint256 h; h <= 72; ++h) {
            _forgeAndRun(h == 0 ? C : C / 24);
            _forgeAndRun(L / 24);
            // the Safe: cancel every claim queued 11 h ago or more (DELAY is 12 h)
            for (; cancelled < keys.length; ++cancelled) {
                bytes32 key = _claimKey(homeEp, keys[cancelled]);
                (,, uint40 queuedAt,) = rh.claims(HOME, key);
                if (queuedAt == 0) continue; // minted at once: not a claim
                if (uint256(queuedAt) + rh.DEFAULT_DELAY() > vm.getBlockTimestamp() + 1 hours) break;
                vm.prank(safe);
                rh.cancelClaim(HOME, key);
            }
            _claimAll();
            if (h < 72) vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        assertEq(vm.getBlockTimestamp(), t0 + 72 hours);
        uint256 spent = rhTok.balanceOf(attacker);
        assertLe(spent, 4 * C, "with the Safe cancelling within DELAY only the instant part is spendable");
        assertLe(C + C * rh.DEFAULT_DELAY() / 1 days, RobinhoodConfig.CHAIN_LINE, "the instant part within DELAY is within the 4663 line");
    }
}
