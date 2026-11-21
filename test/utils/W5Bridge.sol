// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "./W4Bridge.sol";
import {Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Wave-5 bridge harness (audit 74838ad4): W4Bridge with both paths open at the launch values (limits 50,000/day each
/// way; C 5,000/day, D 12 h, B 50,000 written by the first SET_PATH) and readers for the path's delay settings.
abstract contract W5Bridge is W4Bridge {
    uint256 constant LIM = 50_000e18;
    uint256 constant C = 5_000e18;
    uint256 constant D = 12 hours;
    uint256 constant B = 50_000e18;

    function _setUpW5() internal {
        _setUpW4();
        _openBoth(LIM);
    }

    /// @dev rh's settings for the path from HOME: cap, delay, breaker (18 decimals), cutoff, version, tripped, trips.
    function _cap() internal view returns (uint256 capSD) {
        (,, uint64 c) = rh.instantIn(HOME);
        capSD = uint256(c) * 1e12;
    }

    function _brk()
        internal
        view
        returns (uint256 breaker, uint256 delay, uint40 cut, uint16 version, bool tripped, uint16 trips)
    {
        uint64 bSD;
        uint32 d;
        (, trips, tripped, bSD, d, cut, version) = rh.breakers(HOME);
        (breaker, delay) = (uint256(bSD) * 1e12, d);
    }

    function _version() internal view returns (uint16 v) {
        (,,, v,,) = _brk();
    }

    function _tripped() internal view returns (bool t) {
        (,,,, t,) = _brk();
    }

    /// @dev SET_DELAY (kind 15) for rh's path from HOME, naming the current version.
    function _setDelayP(uint256 cap, uint256 delay, uint256 breaker, uint40 cutoff) internal view returns (bytes memory) {
        return abi.encode(uint8(15), HOME, cap, delay, breaker, cutoff, uint256(_version()));
    }

    function _proposeRh(bytes memory p) internal {
        vm.prank(safe);
        rh.propose(p);
    }

    function _governRh(bytes memory p) internal {
        _govern(rh, p);
    }

    /// @dev Forge and execute at once; true if it executed (minted or queued).
    function _forgeRun(uint256 amount) internal returns (uint256 i, bool ok) {
        i = _forge(amount);
        ok = homeEp.deliver(i);
    }

    function _tryClaim(uint256 i) internal returns (bool ok) {
        (ok,) = address(rh).call(abi.encodeWithSignature("claim(uint32,bytes32)", HOME, _claimKey(homeEp, i)));
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }
}

/// @notice ImdUSD's bridge-minter gate, for the launch-order tests (a review before wave 5b): mint and burn revert until `setBridge` names a
/// minter (ImdUSD.setBridge, applied by Parameters' SET_BRIDGE), and `bridge()` reports it.
contract GatedTok {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public bridge;

    function setBridge(address b) external {
        bridge = b;
    }

    function mint(address to, uint256 a) external returns (bool) {
        require(msg.sender == bridge, "Unauthorized");
        balanceOf[to] += a;
        totalSupply += a;
        return true;
    }

    function burn(address from, uint256 a) external returns (bool) {
        require(msg.sender == bridge, "Unauthorized");
        balanceOf[from] -= a;
        totalSupply -= a;
        return true;
    }
}
