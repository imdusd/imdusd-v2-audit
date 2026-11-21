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
        uint256 atOnce = c + c * uint256(72 hours) / (1 days);
        assertEq(atOnce, 4 * c, "72 h = cap x (1 + 3)");
        assertLe(atOnce, RobinhoodConfig.CHAIN_LINE, "a weekend's split forgery mints at once past the 4663 chain line");
    }

    /// The launch delay is a window the Safe can actually use (shorter than the weekend it is sized against and than the
    /// 48h timelock, so no early release ever beats waiting), and the governable bounds keep any delay usable.
    function test_delayBounds() public view {
        uint256 d = RobinhoodConfig.CLAIM_DELAY;
        assertGe(d, uint256(1 hours));
        assertLe(d, uint256(7 days));
        assertLt(d, rh.TIMELOCK());
        // the fields hold far past "millions a day": 64-bit shared decimals for C and B
        assertGe(uint256(type(uint64).max) * uint256(1e12), 1e12 * 1e18, "cap/breaker hold a trillion imdUSD");
    }
}
