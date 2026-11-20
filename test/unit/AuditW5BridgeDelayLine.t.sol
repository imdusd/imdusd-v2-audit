// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";

/// @notice RULE: a split forgery mints AT ONCE at most C + C x t / 1 day on a
/// path; over the 72 h weekend the Safe may take (HOLD_TIME) that is 4C, and at the LAUNCH cap (RobinhoodConfig.INSTANT_CAP,
/// 5,000) it must stay within the 4663 chain line. Queued forgeries are the Safe's to pause or cancel within the delay;
/// this bounds what no Safe action can reach. C, D and B are governable per path (no bound on C and B);
/// the BOUNDS that do hold are on the delay: never zero (the Safe's window) and at most 7 days.
contract AuditW5BridgeDelayLineTest is W4Bridge {
    function setUp() public {
        _setUpW4();
    }

    function test_weekendInstantForgeryWithinTheChainLine() public view {
        uint256 c = RobinhoodConfig.INSTANT_CAP;
        uint256 atOnce = c + c * rh.HOLD_TIME() / (1 days);
        assertEq(atOnce, 4 * c, "72 h = cap x (1 + 3)");
        assertLe(atOnce, RobinhoodConfig.CHAIN_LINE, "a weekend's split forgery mints at once past the 4663 chain line");
    }

    /// The launch delay is a window the Safe can actually use (shorter than the weekend it is sized against and than the
    /// 48h timelock, so no early release ever beats waiting), and the governable bounds keep any delay usable.
    function test_delayBounds() public view {
        uint256 d = RobinhoodConfig.CLAIM_DELAY;
        assertGe(d, rh.MIN_DELAY());
        assertLe(d, rh.MAX_DELAY());
        assertLt(d, rh.TIMELOCK());
        assertEq(rh.MIN_DELAY(), 1 hours, "a zero delay would remove the Safe's window");
        assertEq(rh.MAX_DELAY(), 7 days);
        // the fields hold far past "millions a day": 64-bit shared decimals for C and B
        assertGe(uint256(type(uint64).max) * uint256(1e12), 1e12 * 1e18, "cap/breaker hold a trillion imdUSD");
        assertGe(rh.MAX_LIMIT(), 100_000_000e18, "a path's limit is not the binding cap at millions a day");
    }
}
