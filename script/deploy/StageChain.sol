// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Pulse} from "../../src/Pulse.sol";
import {ImdBridge, IMintableBurnable} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {StockVault} from "../../src/stocks/StockVault.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice The chain parts: Pulse, ImdBridge and the stock-token module, as DeployBase's three hooks. Built only into
/// script/DeployChain.s.sol (the one-run deploy every Robinhood test uses) and the Robinhood launch stages (script/launch/,
/// not in this repository), so the mainnet entries never embed this creation code.
///
/// RESUMABLE like every other stage step (DeployBase): a recorded piece with code and the wiring this config builds is kept,
/// one with no code is deployed, one with code but other wiring stops the run (`Mismatch`). A fresh `Deployed` (all zero)
/// runs every step exactly as the one-run deploy did before the launch tooling (same order, same gas-log labels).
abstract contract StageChain is DeployBase {
    function _newPulse(uint64 gap, uint64 grace) internal virtual override returns (Pulse) {
        return new Pulse(gap, grace);
    }

    function _newBridge(address endpoint, address token, address governor, address treasury)
        internal
        virtual
        override
        returns (ImdBridge)
    {
        return new ImdBridge(ILayerZeroEndpointV2(endpoint), IMintableBurnable(token), governor, treasury);
    }

    /// @notice A recorded bridge is this deployment's: its endpoint, token, governor and Treasury.
    function _bridgeIs(ImdBridge b, address endpoint, address token, address governor, address treasury)
        internal
        view
        returns (bool)
    {
        return address(b.endpoint()) == endpoint && address(b.minterBurner()) == token && b.governor() == governor
            && b.treasury() == treasury;
    }

    /// @dev Stock tokens: one MarketCalendar (governed by the Safe), then per stock type a StockVault (custody), its MarketHoursFeed
    /// (holder = the vault), a RateFeed over the vault's share rate (the type's median AND spot: one feed, no skew), and a
    /// StockJoin (auction type, not redeemable), each type registered at genesis and put in the stock debt-cap group.
    function _deployStocks(DeployTypes.Config memory cfg, Deployed memory d, address me) internal virtual override {
        DeployTypes.StocksSpec memory s = cfg.stocks;
        uint256 n = s.types.length;
        uint256 g;
        if (!(_has(address(d.calendar)) && _ok(_calendarIs(d.calendar, cfg), "MarketCalendar"))) {
            g = gasleft();
            d.calendar = new MarketCalendar(cfg.governor, s.closedDays, s.earlyDays);
            _rec("MarketCalendar", g, type(MarketCalendar).creationCode.length + 64 * (2 + s.closedDays.length + s.earlyDays.length));
        }
        _sizeStocks(d, n);
        for (uint256 i; i < n; ++i) _stockType(cfg, d, me, i);
    }

    /// @dev Keep what the record holds (each piece is compared with its spec in `_stockType`), sized to the config.
    function _sizeStocks(Deployed memory d, uint256 n) internal pure {
        if (d.stockVaults.length == n && d.stockJoins.length == n && d.stockFeeds.length == n && d.stockPrices.length == n) {
            return;
        }
        StockVault[] memory v = new StockVault[](n);
        StockJoin[] memory j = new StockJoin[](n);
        MarketHoursFeed[] memory f = new MarketHoursFeed[](n);
        RateFeed[] memory p = new RateFeed[](n);
        for (uint256 i; i < n; ++i) {
            if (i < d.stockVaults.length) v[i] = d.stockVaults[i];
            if (i < d.stockJoins.length) j[i] = d.stockJoins[i];
            if (i < d.stockFeeds.length) f[i] = d.stockFeeds[i];
            if (i < d.stockPrices.length) p[i] = d.stockPrices[i];
        }
        (d.stockVaults, d.stockJoins, d.stockFeeds, d.stockPrices) = (v, j, f, p);
    }

    function _stockType(DeployTypes.Config memory cfg, Deployed memory d, address me, uint256 i) internal {
        DeployTypes.StocksSpec memory s = cfg.stocks;
        DeployTypes.StockSpec memory t = s.types[i];
        uint256 g;
        // A registered type names its vault, join and price: a resume adopts those, never orphan copies (as StagePeg).
        if (d.params.exists(t.ilk)) {
            ParametersBase.Config memory c = d.params.config(t.ilk);
            if (!_has(address(d.stockVaults[i]))) d.stockVaults[i] = StockVault(c.token);
            if (!_has(address(d.stockJoins[i]))) d.stockJoins[i] = StockJoin(c.join);
            if (!_has(address(d.stockPrices[i]))) d.stockPrices[i] = RateFeed(address(c.median));
            if (!_has(address(d.stockFeeds[i])) && _has(address(d.stockPrices[i]))) {
                d.stockFeeds[i] = MarketHoursFeed(address(d.stockPrices[i].underlying()));
            }
        }
        if (!(_has(address(d.stockVaults[i])) && _ok(d.stockVaults[i].asset() == t.stock, "StockVault"))) {
            g = gasleft();
            d.stockVaults[i] = new StockVault(IERC20Metadata(t.stock));
            _rec("StockVault", g, type(StockVault).creationCode.length + 32);
        }
        if (!(_has(address(d.stockFeeds[i])) && _ok(_hoursFeedIs(d.stockFeeds[i], t, address(d.stockVaults[i]), d.calendar), "MarketHoursFeed"))) {
            g = gasleft();
            d.stockFeeds[i] = new MarketHoursFeed(t.aggregator, t.stock, address(d.stockVaults[i]), d.calendar, t.maxAge);
            _rec("MarketHoursFeed", g, type(MarketHoursFeed).creationCode.length + 160);
        }
        if (!(_has(address(d.stockPrices[i])) && _ok(_stockPriceIs(d.stockPrices[i], address(d.stockVaults[i]), d.stockFeeds[i], s.rateCap), "RateFeed (stock)"))) {
            g = gasleft();
            d.stockPrices[i] = new RateFeed(
                address(d.stockVaults[i]), bytes4(keccak256("convertToAssets(uint256)")), true, d.stockFeeds[i], s.rateCap
            );
            _rec("RateFeed (stock)", g, type(RateFeed).creationCode.length + 160);
        }
        if (!(_has(address(d.stockJoins[i])) && _ok(_stockJoinIs(d.stockJoins[i], t, address(d.stockVaults[i]), s.usdg, me), "StockJoin"))) {
            g = gasleft();
            d.stockJoins[i] = new StockJoin(t.ilk, address(d.stockVaults[i]), IERC20(s.usdg), me, t.auctionTime, t.auctionFloor);
            _rec("StockJoin", g, type(StockJoin).creationCode.length + 192);
        }
        if (d.stockJoins[i].ledger() == address(0)) {
            g = gasleft();
            d.stockJoins[i].wire(address(d.ledger));
            _rec("stockJoin.wire", g, CALL_DATA);
        } else if (d.stockJoins[i].ledger() != address(d.ledger)) {
            revert Mismatch("StockJoin wired to another Ledger");
        }
        ParametersBase.Config memory want = _stockConfig(d, i);
        if (!d.params.exists(t.ilk)) {
            g = gasleft();
            d.params.addGenesisIlk(t.ilk, want, t.risk);
            _rec("params.addGenesisIlk (stock)", g, 1_000);
        } else {
            if (keccak256(abi.encode(d.params.config(t.ilk))) != keccak256(abi.encode(want))) {
                revert Mismatch("stock type registered with another config");
            }
            if (keccak256(abi.encode(d.params.storedRisk(t.ilk))) != keccak256(abi.encode(t.risk))) {
                revert Mismatch("stock type registered with other risk");
            }
        }
        (uint8 group, uint256 line) = d.params.groupCap(t.ilk);
        if (group != s.group || line != s.groupLine) {
            if (d.params.sealed_()) revert Mismatch("stock group after the seal");
            g = gasleft();
            d.params.setGenesisGroup(t.ilk, s.group, s.groupLine);
            _rec("params.setGenesisGroup", g, CALL_DATA);
        }
    }

    function _calendarIs(MarketCalendar c, DeployTypes.Config memory cfg) internal view returns (bool) {
        DeployTypes.StocksSpec memory s = cfg.stocks;
        if (c.governor() != cfg.governor) return false;
        for (uint256 i; i < s.closedDays.length; ++i) if (c.dayStatus(s.closedDays[i]) != c.CLOSED()) return false;
        for (uint256 i; i < s.earlyDays.length; ++i) if (c.dayStatus(s.earlyDays[i]) != c.EARLY_CLOSE()) return false;
        return true;
    }

    function _hoursFeedIs(MarketHoursFeed f, DeployTypes.StockSpec memory t, address vault, MarketCalendar cal)
        internal
        view
        returns (bool)
    {
        return f.aggregator() == t.aggregator && f.stock() == t.stock && f.holder() == vault && f.calendar() == cal
            && f.maxAge() == t.maxAge && f.tokenDecimals() == 18;
    }

    function _stockPriceIs(RateFeed p, address vault, MarketHoursFeed f, uint256 cap) internal view returns (bool) {
        return p.rateSource() == vault && p.selector() == bytes4(keccak256("convertToAssets(uint256)")) && p.passOneE18()
            && address(p.underlying()) == address(f) && p.maxGrowthPerSecond() == cap;
    }

    function _stockJoinIs(StockJoin j, DeployTypes.StockSpec memory t, address vault, address usdg, address me)
        internal
        view
        returns (bool)
    {
        return j.ilk() == t.ilk && j.token() == vault && address(j.usdg()) == usdg && j.wirer() == me
            && j.auctionTime() == t.auctionTime && j.floor() == t.auctionFloor;
    }

    function _stockConfig(Deployed memory d, uint256 i) internal pure returns (ParametersBase.Config memory) {
        IFeed price = IFeed(address(d.stockPrices[i]));
        return ParametersBase.Config({
            token: address(d.stockVaults[i]),
            join: address(d.stockJoins[i]),
            median: price,
            spot: price,
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(0),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: true
        });
    }
}
