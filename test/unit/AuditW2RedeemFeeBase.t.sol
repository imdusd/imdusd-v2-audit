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

contract PdTok is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract PdFeed is IFeed {
    uint256 public value;
    uint64 public at;
    constructor(uint256 v) { value = v; at = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, at); }
    function isStale() external pure returns (bool) { return false; }
    function maxAge() external pure returns (uint256) { return 1 hours; }
}

/// @dev One transaction: borrow `inflate` on a fresh position (real mint), redeem `amount`, repay the borrow and take the
/// collateral back. The borrow exists only inside this transaction, yet it is counted in `circulating()` by both the
/// fee ramp and the base-rate rise of the redemption.
contract PdAttacker {
    ImdUSD immutable usd;
    Ledger immutable ledger;
    Redeemer immutable redeemer;
    constructor(ImdUSD u, Ledger l, Redeemer r) { usd = u; ledger = l; redeemer = r; }

    function run(bytes32 ilk, IERC20 weth, uint256 coll, uint256 inflate, uint256 amount)
        external
        returns (uint256 collateralOut, uint256 feeSeen)
    {
        weth.approve(address(ledger), type(uint256).max);
        usd.approve(address(ledger), type(uint256).max);
        // A high rate: the redemption takes from the lowest rates first, so it visits alice, not this position.
        uint256 id = ledger.open(ilk, 0, Adjust(int256(coll), int256(inflate), 0.5e18, 0, 0, false, type(uint256).max, address(0)));
        feeSeen = redeemer.feeFor(ilk, amount);
        (, collateralOut) = redeemer.redeem(ilk, amount, 1e18, 1, 0);
        ledger.adjust(id, Adjust(-int256(uint256(ledger.position(id).collateral)), -int256(ledger.debtOf(id)), 0, 0, 0, false, type(uint256).max, address(0)));
    }
}

/// @notice `circulating()` is raised by real debt minted earlier in the same transaction, so a redeemer who borrows (PEG zap,
/// any type, repaid before the transaction ends) pays a lower redemption fee and leaves a lower base rate than the supply
/// at rest allows. Expected: the fee and the base-rate rise of a redemption do not depend on debt that exists only inside
/// the redeemer's own transaction.
contract AuditW2RedeemFeeBaseTest is Test {
    bytes32 constant ETH = "ETH";
    ImdUSD usd;
    Ledger ledger;
    Redeemer redeemer;
    PdTok weth;
    address alice = makeAddr("alice");

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
        usd.wire(address(ledger), address(new Migrator(IERC20(address(new PdTok())), usd, params)), address(params));
        params.wire(address(ledger), address(usd));
        treasury.wire(ICoverable(address(ledger)));
        weth = new PdTok();
        Join join = new Join(address(weth), address(this));
        join.wire(address(ledger));
        PdFeed feed = new PdFeed(2000e18);
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
        // The honest book: alice owes 90,000 at 5%. The type's base rate has decayed from its launch value.
        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(100e18, 90_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
    }

    function test_sameTransactionBorrowDoesNotLowerTheFeeOrBaseRate() public {
        uint256 amount = 9_000e18;
        uint256 supplyAtRest = usd.totalSupply();
        uint256 honestFee = redeemer.feeFor(ETH, amount);
        uint256 baseAtRest = redeemer.decayedBaseRate(ETH);
        uint256 honestOut = (amount * 1e18 / 2000e18) * (1e18 - honestFee) / 1e18;

        PdAttacker a = new PdAttacker(usd, ledger, redeemer);
        weth.mint(address(a), 100e18);
        deal(address(usd), address(a), amount + 1_000e18); // the imdUSD to redeem, plus the re-borrow's upfront fee
        (uint256 out, uint256 feeSeen) = a.run(ETH, IERC20(address(weth)), 100e18, 90_000e18, amount);

        // The position is gone again: the supply is back where it was, less the redemption (plus the borrow's upfront fee,
        // under 1%, which was minted to the Treasury).
        assertApproxEqRel(usd.totalSupply(), supplyAtRest - amount, 0.01e18, "nothing of the attacker's borrow is left");
        assertEq(feeSeen, honestFee, "the fee read inside the transaction equals the fee at rest");
        assertLe(out, honestOut, "the redeemer does not receive more collateral than an honest redemption pays");
        (uint192 base,) = redeemer.rates(ETH);
        // (adopted: the judge's line read the decayed rate AFTER the redemption and left out FEE_CAP)
        uint256 honestBase = baseAtRest + (amount * 1e18 / supplyAtRest) / 2;
        if (honestBase > redeemer.FEE_CAP()) honestBase = redeemer.FEE_CAP();
        assertEq(uint256(base), honestBase, "the base rate rose by the redeemed share of the supply at rest");
    }
}