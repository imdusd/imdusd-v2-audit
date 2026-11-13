// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {ImdDepth} from "src/feeds/ImdDepth.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract PaStub {}

contract PaJoin {
    address public token;
    address public ledger;

    constructor(address t, address l) {
        (token, ledger) = (t, l);
    }
}

/// A stand-in exit-pool sampler: ImdDepth only reads manager() and poolId() when listing.
contract PaSampler {
    address public manager;
    bytes32 public poolId;

    constructor(address m, bytes32 id) {
        (manager, poolId) = (m, id);
    }
}

/// Wave 2 says propose refuses what apply would fail on. These still pass propose, wait 48h and always revert at
/// apply, holding their slot (and every kind they lock) until the Safe cancels.
contract AuditW2ProposeAtApplyTest is Test {
    Parameters params;
    ImdDepth depth;
    address gov = makeAddr("gov");
    address ledger;
    address sampler;
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = new Parameters(gov, address(this));
        ledger = address(new PaStub());
        params.wire(ledger, address(new PaStub()));
        _add(ETH, 1_000_000e18);
        _add(SIMD, 0);
        params.setGenesisDepthRule(SIMD, 1e18, 0, 0, 0);
        depth = new ImdDepth(address(params));
        sampler = address(new PaSampler(address(0xBEEF), bytes32(uint256(1))));
        address[] memory list = new address[](1);
        list[0] = sampler;
        params.setGenesisImdDepth(address(depth), list);
        params.seal();
    }

    function _risk(uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: 1.5e18, chop: 0.1e18, cut: 0.1e18, chip: 0.01e18, rateFloor: 0.005e18, yieldFee: 0, skew: 0.02e18,
            pegFloor: 0, line: line, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 4, redeemCap: 0
        });
    }

    function _cfg() internal returns (ParametersBase.Config memory c) {
        c.token = address(new PaStub());
        c.join = address(new PaJoin(c.token, ledger));
        c.median = IFeed(address(new PaStub()));
        c.spot = c.median;
        c.redeemable = true;
    }

    function _add(bytes32 ilk, uint128 line) internal {
        params.addGenesisIlk(ilk, _cfg(), _risk(line));
    }

    /// ADD_DEPTH_SAMPLER of a sampler ImdDepth already lists: _validate checks only that it has code.
    /// Audit wave 2 (low), adopted from the judge's proof: refused at propose (ImdDepth.canAdd), not queued to fail at apply.
    function test_addListedSamplerRefusedAtPropose() public {
        bytes memory p = abi.encode(params.ADD_DEPTH_SAMPLER(), sampler);
        vm.prank(gov);
        vm.expectRevert(ParametersBase.OutOfBounds.selector); // (p is built before: no call between)
        params.propose(p);
    }

    /// A BATCH adding the same new type twice: the second item fails only because of the first, so the batch is refused.
    function test_batchDuplicateAddIlkRefusedAtPropose() public {
        bytes[] memory items = new bytes[](2);
        bytes memory add = abi.encode(params.ADD_ILK(), bytes32("WSTETH"), _cfg(), _risk(1_000e18));
        (items[0], items[1]) = (add, add);
        uint8 b = params.BATCH();
        vm.prank(gov);
        vm.expectRevert(ParametersBase.BadConfig.selector);
        params.propose(abi.encode(b, items));
        // One of them alone is fine.
        bytes[] memory one = new bytes[](1);
        one[0] = add;
        vm.prank(gov);
        params.propose(abi.encode(b, one));
    }
}
