// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {ParametersRules} from "src/ParametersRules.sol";
import {Pricer} from "src/Pricer.sol";
import {Treasury} from "src/Treasury.sol";
import {PositionNFT} from "src/PositionNFT.sol";
import {Ledger} from "src/Ledger.sol";
import {LedgerSettlement} from "src/LedgerSettlement.sol";
import {IPulse} from "src/LedgerBase.sol";
import {SortedPositions} from "src/SortedPositions.sol";
import {StageCore} from "script/deploy/StageCore.sol";

/// @notice PROPERTY (audit wave 3, separate module deploys): Parameters and the Ledger can only be bound to a module that
/// serves them. Parameters refuses a rules module with no code or for another governor. The Ledger refuses a settlement
/// module whose argument-fixed immutables differ from its own (fuzzed over which one differs); the deploy (StageCore)
/// refuses to keep a Ledger whose module was made for another Ledger address or another SortedPositions.
contract AuditW3ModulesTest is Test {
    address gov = makeAddr("gov");
    ImdUSD usd;
    Parameters params;
    Pricer pricer;
    Treasury treasury;
    PositionNFT nft;

    function setUp() public {
        usd = new ImdUSD(address(this), 0);
        params = new Parameters(gov, address(this), new ParametersRules(gov));
        pricer = new Pricer(params);
        treasury = new Treasury(gov, IERC20(address(usd)), address(this));
        nft = new PositionNFT(address(this));
    }

    function test_parametersRefusesARulesModuleThatIsNotItsOwn() public {
        vm.expectRevert(ParametersBase.BadConfig.selector);
        new Parameters(gov, address(this), ParametersRules(address(0x1234)));
        ParametersRules other = new ParametersRules(makeAddr("another governor"));
        vm.expectRevert(ParametersBase.BadConfig.selector);
        new Parameters(gov, address(this), other);
    }

    function testFuzz_ledgerRefusesASettlementWithOtherImmutables(uint8 which) public {
        which %= 7;
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SortedPositions sorted = SortedPositions(vm.computeCreateAddress(next, 1));
        address other = makeAddr("other");
        LedgerSettlement s = new LedgerSettlement(
            which == 0 ? ImdUSD(other) : usd,
            which == 1 ? Parameters(other) : params,
            which == 2 ? Pricer(other) : pricer,
            which == 3 ? other : address(treasury),
            which == 4 ? other : address(this),
            which == 5 ? IPulse(other) : IPulse(address(0)),
            sorted,
            which == 6 ? PositionNFT(other) : nft,
            next
        );
        vm.expectRevert(Ledger.BadSettlement.selector);
        new Ledger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft, s);
    }

    /// The deploy's resume check (StageCore._settlementIs) accepts a Ledger only with a module made for its own address and
    /// its own SortedPositions (the two immutables the Ledger's constructor cannot check).
    function testFuzz_deployCheckRefusesAModuleForAnotherLedgerOrList(uint8 which) public {
        which %= 3;
        StageCoreProbe probe = new StageCoreProbe();
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address wrong = makeAddr("wrong");
        LedgerSettlement s = new LedgerSettlement(
            usd, params, pricer, address(treasury), address(this), IPulse(address(0)),
            SortedPositions(which == 2 ? wrong : vm.computeCreateAddress(next, 1)), nft, which == 1 ? wrong : next
        );
        Ledger l = new Ledger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft, s);
        assertEq(probe.settlementIs(l), which == 0, "kept only with the module made for this Ledger and its list");
    }
}

contract StageCoreProbe is StageCore {
    function settlementIs(Ledger l) external view returns (bool) {
        return _settlementIs(l);
    }
}
