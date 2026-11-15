// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract PbStub {}

contract PbJoin {
    address public token;
    address public ledger;

    constructor(address t, address l) {
        (token, ledger) = (t, l);
    }
}

/// The measured depth, moved by the test (on chain: DepthSampler + ImdDepth.poke).
contract PbDepth {
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

/// Parameters.checkBatch stops at the FIRST item that fails in order and only asks whether THAT item fails alone. An
/// item behind it that fails only because of an earlier item (the wave-2 case: two ADD_ILK of one type) is never dry-run
/// against the items before it. The batch passes propose, locks ADD_ILK and SET_RISK for 48 h, and can never apply:
/// once the waiting item's state arrives (depth), apply reaches the third item and reverts IlkExists.
contract ProofBatchAfterWaitingItemTest is Test {
    Parameters params;
    PbDepth depth;
    address gov = makeAddr("gov");
    address ledger;
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = Modules.newParameters(gov, address(this));
        ledger = address(new PbStub());
        params.wire(ledger, address(new PbStub()));
        params.addGenesisIlk(SIMD, _cfg(), _risk(0));
        params.setGenesisDepthRule(SIMD, 1e18, 0, 0, 0);
        depth = new PbDepth(address(params));
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
        c.token = address(new PbStub());
        c.join = address(new PbJoin(c.token, ledger));
        c.median = IFeed(address(new PbStub()));
        c.spot = c.median;
        c.redeemable = true;
    }

    function test_itemBrokenByAnEarlierItemBehindAWaitingItemIsRefusedAtPropose() public {
        bytes memory add = abi.encode(params.ADD_ILK(), bytes32("WSTETH"), _cfg(), _risk(1_000e18));
        // Fails alone today (measured depth 0: DepthRuleFails) and is meant to wait for depth, as a single proposal may.
        bytes memory line = abi.encode(params.SET_RISK(), SIMD, _risk(1_000e18));
        bytes[] memory items = new bytes[](3);
        (items[0], items[1], items[2]) = (add, line, add);
        uint8 b = params.BATCH();
        bytes memory batch = abi.encode(b, items);

        vm.prank(gov);
        (bool accepted,) = address(params).call(abi.encodeCall(params.propose, (batch)));
        if (accepted) {
            // The depth arrives, the delay runs: the batch still cannot apply, ever. The SAME dry run, re-run at apply with
            // the depth present, now reaches item 3, finds it passes alone, and refuses the batch (BadConfig).
            depth.set(10_000e18);
            vm.warp(block.timestamp + params.TIMELOCK());
            vm.expectRevert(ParametersBase.BadConfig.selector);
            params.applyPending(b);
            assertTrue(params.locked() & (1 << params.ADD_ILK()) != 0, "ADD_ILK stays locked until the Safe cancels");
        }
        assertFalse(accepted, "a batch whose third item fails only because of its first was accepted at propose");
    }
}
/// @notice PROPERTY (audit wave 3): a BATCH passes propose iff, waiting items aside, it can apply: no item is broken by an
/// earlier one, wherever the waiting items sit; an accepted batch applies once the waiting state arrives; and proposing
/// any such batch fits one transaction (EIP-7825). Fuzzed over 1-8 items, each one of: ADD_ILK of one of three new
/// types (a repeat is broken by the earlier one), or the sIMD line raise that waits on measured depth.
contract AuditW3BatchPropertyTest is ProofBatchAfterWaitingItemTest {
    uint256 constant EIP_7825_TX_GAS_CAP = 16_777_216;

    function testFuzz_batchAcceptedIffNoItemBrokenByAnEarlierOne(uint256 seed) public {
        uint256 n = 1 + seed % 8;
        bytes[] memory items = new bytes[](n);
        bool dup;
        bool[3] memory seen;
        bytes[3] memory adds;
        for (uint256 k; k < 3; ++k) {
            adds[k] = abi.encode(params.ADD_ILK(), bytes32(uint256(k + 1)), _cfg(), _risk(1_000e18));
        }
        bytes memory line = abi.encode(params.SET_RISK(), SIMD, _risk(1_000e18));
        for (uint256 i; i < n; ++i) {
            uint256 c = uint256(keccak256(abi.encode(seed, i))) % 4;
            if (c == 3) {
                items[i] = line;
            } else {
                items[i] = adds[c];
                if (seen[c]) dup = true;
                seen[c] = true;
            }
        }
        uint8 b = params.BATCH();
        bytes memory batch = abi.encode(b, items);
        vm.prank(gov);
        uint256 g = gasleft();
        (bool accepted,) = address(params).call{gas: EIP_7825_TX_GAS_CAP}(abi.encodeCall(params.propose, (batch)));
        uint256 used = g - gasleft();
        assertEq(accepted, !dup, "accepted iff no item is broken by an earlier one");
        if (accepted) {
            assertLe(used, EIP_7825_TX_GAS_CAP, "propose fits one transaction");
            depth.set(10_000e18);
            vm.warp(block.timestamp + params.TIMELOCK());
            params.applyPending(b); // applies once the waiting state has arrived
        }
    }

    /// Worst cases for gas: 8 items, 7 ADD_ILK and the waiting item at every position.
    function test_fullBatchGasAtEveryWaitingPosition() public {
        for (uint256 w; w < 8; ++w) {
            uint256 snap = vm.snapshotState();
            bytes[] memory items = new bytes[](8);
            uint256 k;
            for (uint256 i; i < 8; ++i) {
                items[i] = i == w
                    ? abi.encode(params.SET_RISK(), SIMD, _risk(1_000e18))
                    : abi.encode(params.ADD_ILK(), bytes32(uint256(++k)), _cfg(), _risk(1_000e18));
            }
            bytes memory batch = abi.encode(params.BATCH(), items);
            vm.prank(gov);
            uint256 g = gasleft();
            params.propose(batch);
            uint256 used = g - gasleft();
            emit log_named_uint("propose gas, waiting item at", w);
            emit log_named_uint("  gas", used);
            assertLe(used, EIP_7825_TX_GAS_CAP);
            vm.revertToState(snap);
        }
    }
}
