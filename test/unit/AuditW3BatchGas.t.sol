// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract GcStub {}

contract GcJoin {
    address public token;
    address public ledger;

    constructor(address t, address l) {
        (token, ledger) = (t, l);
    }
}

contract GcDepth {
    address public params;
    uint256 public depth;

    constructor(address p) {
        params = p;
    }

    function set(uint256 d) external {
        depth = d;
    }

    function addSampler(address) external {}
}

/// Parameters.checkBatch re-runs the prefix 0..n for every n up to the first failing item (n(n+1)/2 item runs), then the
/// item alone. A full batch (MAX_BATCH = 8) of seven ADD_ILK and one item that waits on state (the sIMD line before depth,
/// which the README says a batch may carry) costs more at propose than EIP-7825's transaction gas cap (16,777,216, in force
/// on mainnet since Fusaka): the Safe cannot propose it at all. The same eight items with none waiting cost 6.65M.
contract ProofBatchGasCapTest is Test {
    uint256 constant EIP_7825_TX_GAS_CAP = 16_777_216;

    Parameters params;
    GcDepth depth;
    address gov = makeAddr("gov");
    address ledger;
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = Modules.newParameters(gov, address(this));
        ledger = address(new GcStub());
        params.wire(ledger, address(new GcStub()));
        params.addGenesisIlk(SIMD, _cfg(), _risk(0));
        params.setGenesisDepthRule(SIMD, 1e18, 0, 0, 0);
        depth = new GcDepth(address(params));
        params.setGenesisImdDepth(address(depth), new address[](0));
        params.seal();
    }

    function _risk(uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: 1.5e18, chop: 0.1e18, cut: 0.1e18, chip: 0.01e18, rateFloor: 0.005e18, yieldFee: 0, skew: 0.02e18,
            pegFloor: 0, line: line, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 4, redeemCap: 0
        });
    }

    function _cfg() internal returns (ParametersBase.Config memory c) {
        c.token = address(new GcStub());
        c.join = address(new GcJoin(c.token, ledger));
        c.median = IFeed(address(new GcStub()));
        c.spot = c.median;
        c.redeemable = true;
    }

    function test_fullBatchWithOneWaitingItemFitsInATransaction() public {
        bytes[] memory items = new bytes[](8);
        for (uint256 i; i < 7; ++i) {
            items[i] = abi.encode(params.ADD_ILK(), bytes32(uint256(i + 1)), _cfg(), _risk(1_000e18));
        }
        // Passes validation, fails at apply alone until depth arrives (DepthRuleFails): allowed in a batch by design.
        items[7] = abi.encode(params.SET_RISK(), SIMD, _risk(1_000e18));
        bytes memory batch = abi.encode(params.BATCH(), items);
        vm.prank(gov);
        uint256 g = gasleft();
        params.propose(batch);
        uint256 used = g - gasleft();
        emit log_named_uint("gas propose (7 ADD_ILK + 1 waiting item)", used);
        assertLe(used, EIP_7825_TX_GAS_CAP, "a legitimate full batch cannot be proposed in one transaction");
    }
}