// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Modules} from "test/utils/Modules.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {Pricer} from "src/Pricer.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {PositionNFT} from "src/PositionNFT.sol";
import {Ledger} from "src/Ledger.sol";
import {IPulse} from "src/LedgerBase.sol";
import {Redeemer} from "src/Redeemer.sol";
import {Liquidator} from "src/Liquidator.sol";
import {Migrator} from "src/Migrator.sol";
import {Join} from "src/Join.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {Adjust} from "src/interfaces/IPositions.sol";

contract PbTok is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract PbFeed is IFeed {
    uint256 public value;
    uint64 public at;
    constructor(uint256 v) { value = v; at = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, at); }
    function isStale() external pure returns (bool) { return false; }
    function maxAge() external pure returns (uint256) { return 1 hours; }
}

/// @notice Wave 2 froze `circulating()` at the TRANSACTION's first mint or burn. The same dilution runs as a bundle of
/// three transactions in one block (foundry `isolate = true`: every top-level call below is its own transaction, so the
/// transient mark clears between them): tx1 borrows 90,000 on a fresh high-rate position, tx2 redeems 9,000 against the
/// inflated supply, tx3 repays and takes the collateral back. The redeemer pays the fee and leaves the base rate that the
/// wave-2 test (AuditW2RedeemFeeBase) says an honest book must not allow. Cost: the borrow's upfront fee (7 days at the
/// type's average rate) and three transactions' gas; no flash loan, no price risk inside a bundle.
contract ProofFeeBaseBundleTest is Test {
    bytes32 constant ETH = "ETH";
    ImdUSD usd;
    Ledger ledger;
    Redeemer redeemer;
    PbTok weth;
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new ImdUSD(address(this), 100_000e18);
        Parameters params = Modules.newParameters(makeAddr("gov"), address(this));
        Pricer pricer = new Pricer(params);
        Treasury treasury = new Treasury(makeAddr("gov"), IERC20(address(usd)), address(this));
        PositionNFT nft = new PositionNFT(address(this));
        ledger = Modules.newLedger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft);
        nft.bind(address(ledger));
        redeemer = new Redeemer(ledger);
        ledger.wire(address(redeemer), address(new Liquidator(ledger, pricer)));
        usd.wire(address(ledger), address(new Migrator(IERC20(address(new PbTok())), usd, params)), address(params));
        params.wire(address(ledger), address(usd));
        treasury.wire(ICoverable(address(ledger)));
        weth = new PbTok();
        Join join = new Join(address(weth), address(this));
        join.wire(address(ledger));
        PbFeed feed = new PbFeed(2000e18);
        params.addGenesisIlk(
            ETH,
            ParametersBase.Config({
                token: address(weth), join: address(join), median: feed, spot: feed, nhi: IFeed(address(0)),
                yieldRate: address(0), pegAggregator: address(0), liveSpot: IFeed(address(0)), redeemable: true,
                auction: false
            }),
            ParametersBase.Risk({
                mat: 1.5e18, chop: 0.1e18, cut: 0.5e18, chip: 0.1e18, rateFloor: 0.01e18, yieldFee: 0, skew: 0.05e18,
                pegFloor: 0, line: 1_000_000e18, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 2, redeemCap: 0
            })
        );
        params.seal();
        // The honest book: alice owes 90,000 at 5%.
        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(100e18, 90_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
    }

    function test_threeTransactionBundleStillDilutesTheFeeAndBaseRate() public {
        uint256 amount = 9_000e18;
        uint256 supplyAtRest = usd.totalSupply();
        uint256 honestFee = redeemer.feeFor(ETH, amount);
        uint256 baseAtRest = redeemer.decayedBaseRate(ETH);
        uint256 honestOut = (amount * 1e18 / 2000e18) * (1e18 - honestFee) / 1e18;
        assertEq(honestFee, 0.05e18, "9,000 on 90,000 at divisor 2 is the 5% cap");

        weth.mint(mallory, 100e18);
        deal(address(usd), mallory, amount + 1_000e18);
        vm.startPrank(mallory);
        weth.approve(address(ledger), type(uint256).max);
        usd.approve(address(ledger), type(uint256).max);
        // tx1 (same block): borrow 90,000 at a high rate so the redemption never visits this position.
        uint256 id = ledger.open(ETH, 0, Adjust(100e18, 90_000e18, 0.5e18, 0, 0, false, type(uint256).max, address(0)));
        uint256 upfront = ledger.debtOf(id) - 90_000e18;
        // tx2 (same block): redeem 9,000. Its first burn marks circulating() at the INFLATED supply.
        uint256 feeSeen = redeemer.feeFor(ETH, amount);
        (, uint256 out) = redeemer.redeem(ETH, amount, 1e18, 1, 0);
        // tx3 (same block): repay and leave. Nothing of the borrow survives the block.
        ledger.adjust(id, Adjust(-100e18, -int256(ledger.debtOf(id)), 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();

        emit log_named_decimal_uint("honest fee (at rest)", honestFee, 18);
        emit log_named_decimal_uint("fee paid by the bundle", feeSeen, 18);
        emit log_named_decimal_uint("extra WETH taken", out - honestOut, 18);
        emit log_named_decimal_uint("cost: upfront fee on the 90,000 borrow", upfront, 18);
        (uint192 base,) = redeemer.rates(ETH);
        uint256 honestBase = baseAtRest + (amount * 1e18 / supplyAtRest) / 2;
        if (honestBase > redeemer.FEE_CAP()) honestBase = redeemer.FEE_CAP();
        emit log_named_decimal_uint("honest base rate after", honestBase, 18);
        emit log_named_decimal_uint("base rate left by the bundle", uint256(base), 18);

        assertApproxEqRel(usd.totalSupply(), supplyAtRest - amount, 0.01e18, "the borrow is gone again");
        assertEq(feeSeen, honestFee, "the fee of a redemption does not depend on debt that lives only inside its block");
        assertLe(out, honestOut, "no more collateral than an honest redemption pays");
        assertEq(uint256(base), honestBase, "the base rate rose by the redeemed share of the supply at rest");
    }
}
/// @notice PROPERTY (audit wave 3): a redemption's fee and its base-rate rise do not count debt opened less than
/// FEE_BASE_WINDOW before it, whatever the sequence: the diluting borrow lands `lead` seconds before the redemption (0 = the
/// same block; 12 = the block before; up to 59 min), in one or two pieces, and is repaid in the redemption's block, a block
/// later, or never. Fee and rise must equal those of the honest book at rest. And honest supply that has stood for two
/// windows counts in full.
contract AuditW3FeeBasePropertyTest is ProofFeeBaseBundleTest {
    function _expected(uint256 amount, uint256 supply, uint256 base) internal view returns (uint256 fee, uint256 rise) {
        uint256 inc = amount * 1e18 / supply / 2;
        fee = 0.005e18 + base + inc;
        if (fee > redeemer.FEE_CAP()) fee = redeemer.FEE_CAP();
        rise = base + inc;
        if (rise > redeemer.FEE_CAP()) rise = redeemer.FEE_CAP();
    }

    function testFuzz_feeIgnoresYoungDebt(uint32 lead, uint96 borrow, uint8 pieces, uint8 repayWhen, uint32 amount) public {
        uint256 w = usd.FEE_BASE_WINDOW();
        lead = uint32(uint256(lead) % w);
        uint256 b = 1_000e18 + uint256(borrow) % 200_000e18;
        uint256 amt = 100e18 + uint256(amount) % 9_000e18;
        // A quiet hour first, so the honest book has stood two whole windows.
        vm.warp(vm.getBlockTimestamp() + 2 * w);
        uint256 supplyAtRest = usd.totalSupply();
        uint256 t = vm.getBlockTimestamp();

        weth.mint(mallory, 1_000e18);
        deal(address(usd), mallory, amt + 1_000e18);
        vm.startPrank(mallory);
        weth.approve(address(ledger), type(uint256).max);
        usd.approve(address(ledger), type(uint256).max);
        vm.stopPrank();
        uint256 n = 1 + pieces % 2;
        uint256 id;
        for (uint256 i; i < n; ++i) {
            vm.warp(t + i * (lead / n)); // the second piece lands later in the lead (still young)
            vm.roll(block.number + 1);
            vm.prank(mallory);
            if (i == 0) id = ledger.open(ETH, 0, Adjust(int256(500e18), int256(b / n), 0.5e18, 0, 0, false, type(uint256).max, address(0)));
            else ledger.adjust(id, Adjust(0, int256(b / n), 0, 0, 0, false, type(uint256).max, address(0)));
        }
        vm.warp(t + lead);
        if (lead != 0) vm.roll(block.number + 1);
        // The honest book's figure, read at the redemption's time on the book at rest.
        (uint256 honestFee, uint256 honestRise) = _expected(amt, supplyAtRest, redeemer.decayedBaseRate(ETH));
        vm.prank(mallory);
        uint256 feeSeen = redeemer.feeFor(ETH, amt);
        vm.prank(mallory);
        redeemer.redeem(ETH, amt, 1e18, 1, 0);
        (uint192 base,) = redeemer.rates(ETH);
        if (repayWhen % 3 != 2) {
            if (repayWhen % 3 == 1) {
                vm.warp(vm.getBlockTimestamp() + 12);
                vm.roll(block.number + 1);
            }
            uint256 debt = ledger.debtOf(id);
            vm.prank(mallory);
            ledger.adjust(id, Adjust(0, -int256(debt), 0, 0, 0, false, type(uint256).max, address(0)));
        }
        assertEq(feeSeen, honestFee, "the fee counted debt younger than the window");
        assertEq(uint256(base), honestRise, "the base-rate rise counted debt younger than the window");
    }

    /// Honest growth that has stood two windows counts in full: the fee is the formula on today's supply.
    function testFuzz_settledSupplyCountsInFull(uint96 borrow, uint32 amount) public {
        uint256 w = usd.FEE_BASE_WINDOW();
        uint256 b = 1_000e18 + uint256(borrow) % 200_000e18;
        uint256 amt = 100e18 + uint256(amount) % 9_000e18;
        weth.mint(mallory, 1_000e18);
        vm.startPrank(mallory);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(int256(500e18), int256(b), 0.5e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 * w);
        (uint256 fee,) = _expected(amt, usd.totalSupply(), redeemer.decayedBaseRate(ETH));
        assertEq(redeemer.feeFor(ETH, amt), fee, "settled supply counts in full");
    }
}
