// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract OlStub {}

contract OlJoin {
    address public token;
    address public ledger;

    constructor(address t, address l) {
        (token, ledger) = (t, l);
    }
}

/// The measured depth, moved by the test (it moves hourly on chain: DepthSampler + ImdDepth.poke).
contract OlDepth {
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

/// Wave 2 refuses lowerOtherImdLines only while the depth line binds NOW. Lowered one block before it binds, the instant
/// act still raises the enforced sIMD line as soon as depth falls: the same raise without the 48h timelock.
contract AuditW2LowerOtherImdTest is Test {
    Parameters params;
    OlDepth depth;
    address gov = makeAddr("gov");
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = Modules.newParameters(gov, address(this));
        address ledger = address(new OlStub());
        params.wire(ledger, address(new OlStub()));
        address t = address(new OlStub());
        ParametersBase.Config memory c;
        c.token = t;
        c.join = address(new OlJoin(t, ledger));
        c.median = IFeed(address(new OlStub()));
        c.spot = c.median;
        c.redeemable = true;
        ParametersBase.Risk memory r = ParametersBase.Risk({
            mat: 1.7e18, chop: 0.2e18, cut: 0.04e18, chip: 0, rateFloor: 0.005e18, yieldFee: 0, skew: 0.02e18,
            pegFloor: 0, line: 10_000e18, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 2, redeemCap: 0
        });
        params.addGenesisIlk(SIMD, c, r);
        // BetaConfig's other-chain term: the Robinhood IMD line 3,000 at chop 20%.
        params.setGenesisDepthRule(SIMD, 1e18, 0, 3_000e18, 0.2e18);
        depth = new OlDepth(address(params));
        params.setGenesisImdDepth(address(depth), new address[](0));
        params.seal();
        depth.set(15_600e18); // depthLine = (15,600 - 3,600) / 1.2 = 10,000 = the stored line: not binding
    }

    function test_lowerOtherImdLinesDoesNotRaiseLineAfterDepthFalls() public {
        assertEq(params.risk(SIMD).line, 10_000e18);
        vm.prank(gov);
        // Audit wave 2: removed. Before, this was accepted while the depth line did not bind.
        (bool ok,) = address(params).call(abi.encodeWithSignature("lowerOtherImdLines(uint256)", uint256(0)));
        assertFalse(ok);
        // One hour later the measured depth falls 23% (a keeper gap or a cheap push, README 'Depth griefing').
        depth.set(12_000e18);
        // With the other chain's 3,000 still counted: (12,000 - 3,600) / 1.2 = 7,000. After the instant act: 10,000.
        assertLe(params.risk(SIMD).line, 7_000e18, "instant act raised the enforced sIMD line");
    }
}