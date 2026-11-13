// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Allocator} from "src/peg/Allocator.sol";
import {Backstop} from "src/backstop/Backstop.sol";
import {IBackstopOracle, ILedgerCover} from "src/backstop/IBackstop.sol";

contract XTok is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    /// The Ledger's minter burn (the standing bid burns the debt it repays from the sleeve).
    function burnFrom(address from, uint256 a) external {
        _burn(from, a);
    }
}

/// PricerOracle's surface: WETH low 2,000, high 2,100, payout 2,100.
contract XOracle is IBackstopOracle {
    function priceOf(address) external pure returns (uint256, uint256, bool) {
        return (2000e18, 2100e18, true);
    }

    function pricedAt(address) external view returns (uint256) {
        return block.timestamp;
    }

    function payoutOf(address) external pure returns (uint256) {
        return 2100e18;
    }
}

/// No bad debt booked anywhere.
contract XLedger is ILedgerCover {
    function cover(bytes32, uint256) external {}

    function ilkState(bytes32) external pure returns (uint128, uint128, uint256, uint64, uint128) {
        return (0, 0, 0, 0, 0);
    }
}

/// Plays the Liquidator's standing bid in ONE call (the bid's state is transient): openBid, the Ledger burns the repaid
/// debt from the sleeve and the Join sends the seized collateral, closeBid books it (Backstop.sol:571).
contract XLiquidator {
    function bid(Backstop sleeve, bytes32 ilk, XTok usd, XTok weth, uint256 repaid, uint256 seized) external {
        sleeve.openBid(ilk);
        usd.burnFrom(address(sleeve), repaid);
        weth.mint(address(sleeve), seized);
        sleeve.closeBid(ilk, repaid);
    }
}

contract AuditW2AuctionExitTest is Test {
    bytes32 constant ETH = "ETH";
    address gov = address(0x5AFE);
    XLiquidator liquidator;
    address holder = address(0xB0B);
    address other = address(0xA11CE);
    address buyer = address(0xB0E);
    XTok usd;
    XTok weth;
    Backstop sleeve;
    Allocator alloc;

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new XTok("imdUSD");
        weth = new XTok("WETH");
        liquidator = new XLiquidator();
        alloc = new Allocator(gov, address(0x7EA), gov, 100);
        sleeve = new Backstop(IERC20(address(usd)), new XLedger(), new XOracle(), false, "blue", "bBLUE");
        sleeve.wire(address(liquidator), address(0xFA2A), address(alloc));
        sleeve.addIlk(ETH, address(weth), 0, type(uint128).max, type(uint128).max);

        bytes32 sale = alloc.BACKSTOP_SALE();
        vm.startPrank(gov);
        alloc.propose(abi.encode(uint8(2), sale, address(sleeve))); // ADD_TARGET
        alloc.propose(abi.encode(uint8(1), sale, address(sleeve), uint128(1e30), uint128(1e30))); // SET_LIMIT
        vm.stopPrank();

        // Two depositors fund the sleeve; their buckets convert after a full day.
        _deposit(holder, 100_000e18);
        _deposit(other, 300_000e18);
        vm.warp(block.timestamp + 48 hours + 1);
        alloc.applyPending(2);
        alloc.applyPending(1);
        sleeve.realize(holder);
        sleeve.realize(other);
    }

    function _deposit(address who, uint256 a) internal {
        usd.mint(who, a);
        vm.startPrank(who);
        usd.approve(address(sleeve), a);
        sleeve.deposit(a, who);
        vm.stopPrank();
    }

    /// The standing bid exactly as Liquidator.bite drives it: openBid, the Ledger burns the repaid debt from the sleeve and
    /// sends the seized collateral (Join.exit), closeBid books it (Backstop.sol:571 `coll[token] += received`).
    function _standingBid(uint256 repaid, uint256 seized) internal {
        liquidator.bid(sleeve, ETH, usd, weth, repaid, seized);
    }

    function test_collateralLandingAfterAnExitIsOfferedFromTheTop() public {
        // A liquidation lands 100 WETH (debt 190,000 repaid, penalty 5%). Anyone starts the run; it reaches its floor.
        _standingBid(190_000e18, 100e18);
        alloc.startAuction(address(sleeve), address(weth));
        uint256 hs = sleeve.balanceOf(holder);
        assertGt(hs, 0, "holder's bucket converted");
        vm.prank(holder);
        sleeve.requestWithdraw(hs);
        vm.warp(block.timestamp + 7 days);
        assertEq(alloc.auctionPrice(address(sleeve), address(weth)), 1960e18, "run at its floor, 98% of low");

        // The holder's matured exit takes its pro-rata WETH in kind (coll falls), then the next liquidation's standing bid
        // lands the same amount of NEW collateral. coll is back at the run's snapshot, never above it.
        uint256 before = sleeve.coll(address(weth));
        vm.prank(holder);
        sleeve.withdraw(holder);
        uint256 exited = before - sleeve.coll(address(weth));
        assertGt(exited, 24e18);
        _standingBid(exited * 1900, exited); // debt repaid 1,900 per WETH (5% penalty at low 2,000)
        assertEq(sleeve.coll(address(weth)), before);

        // README: "collateral that arrives later stops the price until anyone restarts the run, so it is always offered from
        // the top" (103% x 2,100 = 2,163). EXPECTED: AuctionStale. ACTUAL: the new WETH is for sale at the floor.
        try alloc.auctionPrice(address(sleeve), address(weth)) returns (uint256 p) {
            usd.mint(buyer, 1e24);
            vm.startPrank(buyer);
            usd.approve(address(alloc), type(uint256).max);
            uint256 pay = alloc.buyCollateral(address(sleeve), address(weth), exited, type(uint256).max);
            vm.stopPrank();
            emit log_named_decimal_uint("new WETH landed after the exit", exited, 18);
            emit log_named_decimal_uint("auction price offered for it", p, 18);
            emit log_named_decimal_uint("paid by the buyer", pay, 18);
            emit log_named_decimal_uint("value at the run's top (2,163)", exited * 2163, 18);
            assertTrue(false, "new collateral sold at the decayed floor instead of AuctionStale (offer from the top)");
        } catch (bytes memory err) {
            assertEq(bytes4(err), Allocator.AuctionStale.selector, "new collateral stops the price");
        }
    }
}