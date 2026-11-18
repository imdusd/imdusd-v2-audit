// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {W4Bridge} from "../utils/W4Bridge.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";

/// @notice Wave 4 LOW (audit 34e546c2): _checkUln refuses optionalDVNCount = NIL (255), so every config this bridge can set
/// (optional count 0) inherits LayerZero's default optional DVNs (ULN302 merges them on 0; fork proof).
/// PROPERTY: every ULN config the bridge sets is fully its own: no field falls back to the library default.
contract AuditW4BridgeOptionalNilTest is W4Bridge {
    function setUp() public {
        _setUpW4();
        _openBoth(10_000e18);
    }

    function _cfg(uint8 optCount) internal view returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(HOME, 2, abi.encode(UlnConfig(20, 3, optCount, 0, _dvns(0x7000), new address[](0))));
        return abi.encode(uint8(2), rhRecvLib, p);
    }

    function test_optionalNilAccepted() public {
        _govern(rh, _cfg(255));
    }

    function test_optionalZeroMeaningDefaultRefused() public {
        vm.prank(safe);
        vm.expectRevert();
        rh.propose(_cfg(0));
    }
}
