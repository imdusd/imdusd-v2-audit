// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Migrator} from "../../src/Migrator.sol";
import {Join} from "../../src/Join.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {FeeNotes} from "../../src/peg/FeeNotes.sol";
import {PegLPVault} from "../../src/earn/PegLPVault.sol";
import {LoopVault} from "../../src/earn/LoopVault.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {FeedTraits} from "../../src/feeds/FeedTraits.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {Allocator} from "../../src/peg/Allocator.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {PegShareFeed} from "../../src/earn/PegShareFeed.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {PegPositionZap} from "../../src/earn/PegPositionZap.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {SeatFeed, SeatSpotLeg} from "../../src/feeds/SeatFeed.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundLens} from "../../src/dex/CompoundLens.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pulse} from "../../src/Pulse.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {StockVault} from "../../src/stocks/StockVault.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {DeployTypes, MainnetConfig, BetaConfig, RobinhoodConfig} from "../DeployConfig.sol";
import {DeployBase} from "../deploy/DeployBase.sol";

/// @notice What every launch script shares: the deployment record (deploy/mainnet/out/<config>.json, or LAUNCH_RECORD),
/// the config selection (by script entry: `...Beta` / `...Full`, never an environment variable), and the post-check of
/// each stage. A stage counts as landed only when its check passes on chain: code at every recorded address and the
/// wiring the stage makes. The record is written during forge's simulation, BEFORE anything is broadcast, so a record
/// alone proves nothing (v1, 2026-10-11: a refused broadcast still wrote its record).
///
/// The record holds addresses, the deployer, mined CREATE2 salts and block numbers only: nothing secret.
abstract contract LaunchBase is DeployBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant EIP7825_CAP = 16_777_216;

    struct Rec {
        bool exists;
        address deployer;
        uint256 startNonce;
    }

    function config() public pure virtual returns (DeployTypes.Config memory);

    function configName() public pure virtual returns (string memory);

    function recordPath() public view returns (string memory) {
        return vm.envOr("LAUNCH_RECORD", string.concat("deploy/mainnet/out/", configName(), ".json"));
    }

    function _configHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(config()));
    }

    // ---------------------------------------------------------------- record

    function _load() internal returns (Deployed memory d, Rec memory r) {
        DeployTypes.Config memory cfg = config();
        if (block.chainid != cfg.chain.chainId) revert WrongChain(cfg.chain.chainId, block.chainid);
        string memory path = recordPath();
        if (!vm.exists(path)) return (d, r);
        string memory j = vm.readFile(path);
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "record: another chain");
        require(keccak256(bytes(vm.parseJsonString(j, ".config"))) == keccak256(bytes(configName())), "record: another config");
        require(vm.parseJsonBytes32(j, ".configHash") == _configHash(), "record: the config changed since it was written");
        r.exists = true;
        r.deployer = vm.parseJsonAddress(j, ".deployer");
        r.startNonce = vm.parseJsonUint(j, ".startNonce");
        d.usd = ImdUSD(_a(j, "usd"));
        d.params = Parameters(_a(j, "params"));
        d.pricer = Pricer(_a(j, "pricer"));
        d.treasury = Treasury(_a(j, "treasury"));
        d.ledger = Ledger(_a(j, "ledger"));
        d.redeemer = Redeemer(_a(j, "redeemer"));
        d.liquidator = Liquidator(_a(j, "liquidator"));
        d.migrator = Migrator(_a(j, "migrator"));
        address[] memory f = _as(j, "feeds");
        d.feeds = new IFeed[](f.length);
        for (uint256 i; i < f.length; ++i) d.feeds[i] = IFeed(f[i]);
        address[] memory jn = _as(j, "joins");
        d.joins = new Join[](jn.length);
        for (uint256 i; i < jn.length; ++i) d.joins[i] = Join(jn[i]);
        d.savings = SavingsVault(_a(j, "savings"));
        d.notes = FeeNotes(_a(j, "notes"));
        d.hook = PegHook(_a(j, "pegHook"));
        d.pegLP = PegLPVault(_a(j, "pegLPVault"));
        d.seatJoin = SeatJoin(_a(j, "seatJoin"));
        d.seatFeed = SeatFeed(_a(j, "seatFeed"));
        d.seatSpot = SeatSpotLeg(_a(j, "seatSpotLeg"));
        d.loop = LoopVault(_a(j, "loopVault"));
        d.dexHook = CompoundHook(_a(j, "dexHook"));
        d.dexLens = CompoundLens(_a(j, "dexLens"));
        d.imdDepth = ImdDepth(_a(j, "imdDepth"));
        address[] memory sm = _as(j, "depthSamplers");
        d.samplers = new DepthSampler[](sm.length);
        for (uint256 i; i < sm.length; ++i) d.samplers[i] = DepthSampler(sm[i]);
        d.backstopOracle = PricerOracle(_a(j, "backstopOracle"));
        d.blue = Backstop(_a(j, "backstopBlue"));
        d.edge = Backstop(_a(j, "backstopEdge"));
        d.allocator = Allocator(_a(j, "allocator"));
        d.pegFeed = PegShareFeed(_a(j, "pegFeed"));
        d.pegJoin = Join(_a(j, "pegJoin"));
        d.pegZap = PegPositionZap(_a(j, "pegZap"));
        d.pegCollateral = PegCollateral(_a(j, "pegCollateral"));
        d.curveLib = _a(j, "compoundCurve");
        // The chain parts (Robinhood) and the mainnet bridge (`launch.sh bridge`): absent from older records.
        d.pulse = Pulse(_a(j, "pulse"));
        d.bridge = ImdBridge(_a(j, "bridge"));
        d.calendar = MarketCalendar(_a(j, "calendar"));
        _loadStocks(d, j);
        d.oracleLib = _a(j, "compoundOracle");
        if (_has(address(d.hook))) d.pegKey = _pegKey(d.hook);
        if (_has(address(d.dexHook))) d.dexKey = _dexKey(d.dexHook);
        if (vm.keyExistsJson(j, ".pegHookSalt")) _pegHookSalt = vm.parseJsonBytes32(j, ".pegHookSalt");
        if (vm.keyExistsJson(j, ".dexHookSalt")) _dexHookSalt = vm.parseJsonBytes32(j, ".dexHookSalt");
    }

    function _loadStocks(Deployed memory d, string memory j) private view {
        address[] memory v = _as(j, "stockVaults");
        address[] memory jn = _as(j, "stockJoins");
        address[] memory f = _as(j, "stockFeeds");
        address[] memory p = _as(j, "stockPrices");
        d.stockVaults = new StockVault[](v.length);
        d.stockJoins = new StockJoin[](jn.length);
        d.stockFeeds = new MarketHoursFeed[](f.length);
        d.stockPrices = new RateFeed[](p.length);
        for (uint256 i; i < v.length; ++i) d.stockVaults[i] = StockVault(v[i]);
        for (uint256 i; i < jn.length; ++i) d.stockJoins[i] = StockJoin(jn[i]);
        for (uint256 i; i < f.length; ++i) d.stockFeeds[i] = MarketHoursFeed(f[i]);
        for (uint256 i; i < p.length; ++i) d.stockPrices[i] = RateFeed(p[i]);
    }

    function _a(string memory j, string memory k) private view returns (address) {
        string memory key = string.concat(".", k);
        return vm.keyExistsJson(j, key) ? vm.parseJsonAddress(j, key) : address(0);
    }

    function _as(string memory j, string memory k) private view returns (address[] memory) {
        string memory key = string.concat(".", k);
        return vm.keyExistsJson(j, key) ? vm.parseJsonAddressArray(j, key) : new address[](0);
    }

    function _save(Deployed memory d, Rec memory r, uint8 stage) internal {
        string memory o = "record";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "config", configName());
        vm.serializeBytes32(o, "configHash", _configHash());
        vm.serializeAddress(o, "governor", config().governor);
        vm.serializeAddress(o, "deployer", r.deployer);
        vm.serializeUint(o, "startNonce", r.startNonce);
        vm.serializeUint(o, "lastStage", stage);
        vm.serializeUint(o, string.concat("stage", vm.toString(stage), "SimulatedAtBlock"), block.number);
        vm.serializeAddress(o, "usd", address(d.usd));
        vm.serializeAddress(o, "params", address(d.params));
        vm.serializeAddress(o, "pricer", address(d.pricer));
        vm.serializeAddress(o, "treasury", address(d.treasury));
        vm.serializeAddress(o, "ledger", address(d.ledger));
        vm.serializeAddress(o, "sortedPositions", _has(address(d.ledger)) ? address(d.ledger.sorted()) : address(0));
        vm.serializeAddress(o, "positionNFT", _has(address(d.ledger)) ? address(d.ledger.nft()) : address(0));
        vm.serializeAddress(o, "redeemer", address(d.redeemer));
        vm.serializeAddress(o, "liquidator", address(d.liquidator));
        vm.serializeAddress(o, "migrator", address(d.migrator));
        address[] memory f = new address[](d.feeds.length);
        for (uint256 i; i < f.length; ++i) f[i] = address(d.feeds[i]);
        vm.serializeAddress(o, "feeds", f);
        address[] memory jn = new address[](d.joins.length);
        for (uint256 i; i < jn.length; ++i) jn[i] = address(d.joins[i]);
        vm.serializeAddress(o, "joins", jn);
        vm.serializeAddress(o, "savings", address(d.savings));
        vm.serializeAddress(o, "notes", address(d.notes));
        vm.serializeAddress(o, "pegHook", address(d.hook));
        vm.serializeBytes32(o, "pegHookSalt", _pegHookSalt);
        vm.serializeAddress(o, "pegLPVault", address(d.pegLP));
        vm.serializeAddress(o, "seatJoin", address(d.seatJoin));
        vm.serializeAddress(o, "seatFeed", address(d.seatFeed));
        vm.serializeAddress(o, "seatSpotLeg", address(d.seatSpot));
        vm.serializeAddress(o, "loopVault", address(d.loop));
        vm.serializeAddress(o, "dexHook", address(d.dexHook));
        vm.serializeBytes32(o, "dexHookSalt", _dexHookSalt);
        vm.serializeAddress(o, "dexLens", address(d.dexLens));
        vm.serializeAddress(o, "compoundCurve", d.curveLib);
        vm.serializeAddress(o, "imdDepth", address(d.imdDepth));
        address[] memory sm = new address[](d.samplers.length);
        for (uint256 i; i < sm.length; ++i) sm[i] = address(d.samplers[i]);
        vm.serializeAddress(o, "depthSamplers", sm);
        vm.serializeAddress(o, "backstopOracle", address(d.backstopOracle));
        vm.serializeAddress(o, "backstopBlue", address(d.blue));
        vm.serializeAddress(o, "backstopEdge", address(d.edge));
        vm.serializeAddress(o, "allocator", address(d.allocator));
        vm.serializeAddress(o, "pegFeed", address(d.pegFeed));
        vm.serializeAddress(o, "pegJoin", address(d.pegJoin));
        vm.serializeAddress(o, "pegZap", address(d.pegZap));
        vm.serializeAddress(o, "pegCollateral", address(d.pegCollateral));
        vm.serializeAddress(o, "pulse", address(d.pulse));
        vm.serializeAddress(o, "bridge", address(d.bridge));
        vm.serializeAddress(o, "calendar", address(d.calendar));
        _saveStocks(o, d);
        string memory out = vm.serializeAddress(o, "compoundOracle", d.oracleLib);
        // Keep earlier stages' simulation blocks (stage 6 = the mainnet bridge, `launch.sh bridge`).
        string memory path = recordPath();
        if (vm.exists(path)) {
            string memory old = vm.readFile(path);
            for (uint8 s = 1; s <= 6; ++s) {
                string memory k = string.concat("stage", vm.toString(s), "SimulatedAtBlock");
                if (s != stage && vm.keyExistsJson(old, string.concat(".", k))) {
                    out = vm.serializeUint(o, k, vm.parseJsonUint(old, string.concat(".", k)));
                }
            }
        }
        vm.writeJson(out, path);
        console2.log("record written (simulation; code on chain is the only proof):", path);
    }

    function _saveStocks(string memory o, Deployed memory d) private {
        address[] memory v = new address[](d.stockVaults.length);
        address[] memory jn = new address[](d.stockJoins.length);
        address[] memory f = new address[](d.stockFeeds.length);
        address[] memory p = new address[](d.stockPrices.length);
        for (uint256 i; i < v.length; ++i) v[i] = address(d.stockVaults[i]);
        for (uint256 i; i < jn.length; ++i) jn[i] = address(d.stockJoins[i]);
        for (uint256 i; i < f.length; ++i) f[i] = address(d.stockFeeds[i]);
        for (uint256 i; i < p.length; ++i) p[i] = address(d.stockPrices[i]);
        vm.serializeAddress(o, "stockVaults", v);
        vm.serializeAddress(o, "stockJoins", jn);
        vm.serializeAddress(o, "stockFeeds", f);
        vm.serializeAddress(o, "stockPrices", p);
    }

    function _pegKey(PegHook h) internal view returns (PoolKey memory) {
        (address c0, address c1) = h.stableIsToken0() ? (h.stable(), h.quote()) : (h.quote(), h.stable());
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), h.BASE_FEE(), h.TICK_SPACING(), IHooks(address(h)));
    }

    function _dexKey(CompoundHook h) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(h.token0())), Currency.wrap(address(h.token1())), h.FEE_PIPS(), h.TICK_SPACING(), IHooks(address(h))
        );
    }

    /// @dev Each stage's own estimate (Deploy._rec) x 1.03 must fit EIP-7825; launch.sh checks the real limits again.
    function _gasCheck(uint8 stage) internal view {
        uint256 total;
        for (uint256 i; i < _gasLog.length; ++i) {
            total += _gasLog[i].gas;
            console2.log(string.concat("  tx ", vm.toString(i + 1), "  ", _gasLog[i].label, "  ~gas"), _gasLog[i].gas);
            require(_gasLog[i].gas * 103 / 100 <= EIP7825_CAP, string.concat("over the EIP-7825 cap: ", _gasLog[i].label));
        }
        console2.log(string.concat("stage ", vm.toString(stage), ": transactions"), _gasLog.length);
        console2.log(string.concat("stage ", vm.toString(stage), ": estimated gas"), total);
    }

    /// @dev Start of every stage: the record (if any) is this chain's, this config's and this deployer's.
    function _begin(uint8 stage) internal returns (Deployed memory d, Rec memory r, address me) {
        (d, r) = _load();
        vm.startBroadcast();
        (, me,) = vm.readCallers();
        if (r.exists) require(r.deployer == me, "record: written by another deployer");
        if (!r.exists) {
            require(stage == 1, "no record: run stage 1 first");
            r.deployer = me;
            r.startNonce = vm.getNonce(me);
        }
        DeployTypes.Config memory cfg = config();
        _checkRecordedCode(cfg, d); // an edited record cannot make a stage adopt a look-alike
        // Earlier stages landed; before stage 3 every feed must also read non-zero (a dead source stops the launch).
        for (uint8 s = 1; s < stage; ++s) _checkStage(cfg, d, r, s, s == 2);
        delete _gasLog;
    }

    function _end(Deployed memory d, Rec memory r, uint8 stage) internal {
        vm.stopBroadcast();
        _save(d, r, stage);
        _gasCheck(stage);
    }

    // ---------------------------------------------------------------- post-checks (a stage has landed)

    /// @notice `strict = false`: the stage LANDED: code at every recorded address and IMMUTABLE wiring only (addresses,
    /// seals, values no act can change), so it stays true for the life of the deployment whatever the Safe does on
    /// purpose (`status`, `go`, `safe` must keep working after the first Safe act). `strict = true` also
    /// checks the values set at genesis (feeds read non-zero, risk, lines, depth rule, samplers, sleeve flags, freezer,
    /// seat limits, the exact type count), which hold right after the deploy and change later through governance (so
    /// `check` reports them as genesis values). A new check on a value governance can change goes under `strict`.
    function _checkStage(DeployTypes.Config memory cfg, Deployed memory d, Rec memory r, uint8 s, bool strict)
        internal
        view
    {
        if (s == 1) _checkCore(cfg, d, r.deployer);
        else if (s == 2) _checkFeeds(cfg, d, strict);
        else if (s == 3) _checkTypes(cfg, d, r.deployer, strict);
        else if (s == 4) _checkGenesis(cfg, d, strict);
        else if (s == 5 && cfg.bridge.enabled) _checkBridge(cfg, d); // Robinhood: stage 5 = the bridge, no modules there
        else if (s == 5) _checkModules(cfg, d, strict);
        else if (s == 6) _checkBridge(cfg, d); // the mainnet bridge (`launch.sh bridge`), after stages 1-4
        else revert("no such stage");
    }

    function _code(address a, string memory what) internal view {
        require(_has(a), string.concat(what, ": no code at the recorded address"));
    }

    function _checkCore(DeployTypes.Config memory cfg, Deployed memory d, address me) internal view {
        _code(address(d.usd), "stage 1 ImdUSD");
        _code(address(d.params), "stage 1 Parameters");
        _code(address(d.pricer), "stage 1 Pricer");
        _code(address(d.treasury), "stage 1 Treasury");
        _code(address(d.ledger), "stage 1 Ledger");
        _code(address(d.redeemer), "stage 1 Redeemer");
        _code(address(d.liquidator), "stage 1 Liquidator");
        _code(address(d.migrator), "stage 1 Migrator");
        require(d.usd.wirer() == me && d.params.wirer() == me && d.treasury.wirer() == me && d.ledger.wirer() == me, "stage 1: wirer is not the deployer");
        require(d.params.governor() == cfg.governor && d.treasury.governor() == cfg.governor, "stage 1: governor is not the Safe");
        require(d.usd.flashCap() == cfg.flashCap, "stage 1: flash cap");
        require(d.pricer.params() == d.params, "stage 1: Pricer");
        require(d.ledger.token() == d.usd && d.ledger.params() == d.params && d.ledger.pricer() == d.pricer, "stage 1: Ledger immutables");
        require(d.ledger.treasury() == address(d.treasury) && address(d.ledger.pulse()) == address(d.pulse), "stage 1: Ledger treasury/pulse");
        if (cfg.chain.pulse) {
            _code(address(d.pulse), "stage 1 Pulse");
            require(d.pulse.gap() == cfg.chain.pulseGap && d.pulse.grace() == cfg.chain.pulseGrace, "stage 1: Pulse gap/grace");
        } else {
            require(address(d.pulse) == address(0), "stage 1: a Pulse in a config without one");
        }
        require(d.redeemer.ledger() == d.ledger && d.liquidator.ledger() == d.ledger, "stage 1: Redeemer/Liquidator");
        require(address(d.migrator.v1()) == cfg.v1 && d.migrator.v2() == d.usd && d.migrator.params() == d.params, "stage 1: Migrator");
        require(d.ledger.redeemer() == address(d.redeemer) && d.ledger.liquidator() == address(d.liquidator), "stage 1: ledger.wire");
        require(
            d.usd.ledger() == address(d.ledger) && d.usd.migrator() == address(d.migrator)
                && d.usd.bridgeSetter() == address(d.params),
            "stage 1: usd.wire"
        );
        require(d.params.ledger() == address(d.ledger) && d.params.token() == address(d.usd), "stage 1: params.wire");
        require(address(d.treasury.ledger()) == address(d.ledger), "stage 1: treasury.wire");
    }

    /// @notice Every feed node is deployed as its node says AND, unless it is empty until a first relay, reads a non-zero
    /// value now (staleness aside; a zero would mean a dead source or a wrong node).
    function _checkFeeds(DeployTypes.Config memory cfg, Deployed memory d, bool strict) internal view {
        require(d.feeds.length == cfg.feeds.length, "stage 2: feed count");
        for (uint256 i; i < cfg.feeds.length; ++i) {
            address f = address(d.feeds[i]);
            string memory what = string.concat("stage 2 feed node ", vm.toString(i));
            _code(f, what);
            if (cfg.feeds[i].kind == DeployTypes.EXISTING) {
                require(f == cfg.feeds[i].source, string.concat(what, ": not the existing feed"));
                require(_allowanceCapped(f), string.concat(what, ": does not prove a capped stale allowance"));
            } else require(_feedIs(cfg.feeds[i], f, d.feeds), string.concat(what, ": not its node"));
            // Design C: the twin trait the Pricer reads is the one the graph says (sIMD's spot proven, its median not).
            require(FeedTraits.proven(IFeed(f)) == _provenAtDeploy(cfg.feeds, i), string.concat(what, ": proven trait"));
            if (!strict) continue;
            // The swarm leaves (and what is priced through them) are deployed empty: first values are bought and relayed after.
            if (_emptyAtDeploy(cfg.feeds, i)) continue;
            (uint256 v,) = IFeed(f).latestValue();
            require(v != 0, string.concat(what, ": reads zero"));
        }
    }

    function _checkTypes(DeployTypes.Config memory cfg, Deployed memory d, address me, bool strict) internal view {
        if (block.chainid == RobinhoodConfig.CHAIN_ID) {
            // Robinhood: capped at its own chain line; stock types only here.
            require(cfg.chain.capped && cfg.chain.chainLine == RobinhoodConfig.CHAIN_LINE, "stage 3: the 4663 chain line");
            _checkStocks(cfg, d, me, strict);
        } else {
            require(cfg.stocks.types.length == 0, "stage 3: a mainnet config has no stocks");
            // Mainnet's chain line: the beta is capped at exactly 300k at genesis; the full config is uncapped.
            require(
                cfg.chain.capped ? cfg.chain.chainLine == BetaConfig.TOTAL_LINES : cfg.chain.chainLine == 0,
                "stage 3: a mainnet chain line is the beta's 300k or none"
            );
        }
        if (cfg.seats.enabled) _checkSeats(cfg, d, me, strict);
        else require(!_has(address(d.seatJoin)), "stage 3: a seat join in a config without seats");
        require(d.joins.length == cfg.ilks.length, "stage 3: join count");
        // Stage 4 adds PEG and the Safe may ADD_ILK later, so "landed" only needs this stage's types, by
        // index, below. The exact count is a genesis value (strict), with or without stage 4's PEG.
        uint256 own = cfg.ilks.length + (cfg.seats.enabled ? 1 : 0) + cfg.stocks.types.length;
        uint256 count = d.params.ilkCount();
        require(count >= own, "stage 3: type count");
        if (strict) {
            require(
                count == own || (cfg.pegPositions.enabled && count == own + 1 && d.params.ilks(own) == cfg.pegPositions.ilk),
                "stage 3: type count"
            );
        }
        for (uint256 i; i < cfg.ilks.length; ++i) {
            DeployTypes.IlkSpec memory s = cfg.ilks[i];
            string memory what = string.concat("stage 3 type ", vm.toString(i));
            _code(address(d.joins[i]), what);
            require(d.joins[i].token() == s.token && d.joins[i].wirer() == me, string.concat(what, ": join"));
            require(d.joins[i].ledger() == address(d.ledger), string.concat(what, ": join.wire"));
            require(d.params.ilks(i) == s.ilk, string.concat(what, ": order"));
            require(
                keccak256(abi.encode(d.params.config(s.ilk))) == keccak256(abi.encode(_ilkConfig(s, address(d.joins[i]), d.feeds))),
                string.concat(what, ": config")
            );
            if (strict) require(keccak256(abi.encode(d.params.storedRisk(s.ilk))) == keccak256(abi.encode(s.risk)), string.concat(what, ": risk"));
        }
        if (!strict) return;
        require(d.params.maxLull() == (cfg.graceOff ? 0 : d.params.MAX_LULL()), "stage 3: liquidation grace cap");
        require(
            d.params.chainCapped() == cfg.chain.capped && d.params.chainLine() == cfg.chain.chainLine, "stage 3: chain line"
        );
        if (cfg.migratorClosed) require(d.params.migratorLine() == 0, "stage 3: migrator line must be 0");
        else require(d.params.migratorLine() >= cfg.migratorLine, "stage 3: migrator line under the floor");
    }

    /// @dev Robinhood: the stock module of stage 3 (StageChain._deployStocks), all immutable wiring; the group under `strict`.
    function _checkStocks(DeployTypes.Config memory cfg, Deployed memory d, address me, bool strict) internal view {
        DeployTypes.StocksSpec memory s = cfg.stocks;
        uint256 n = s.types.length;
        require(
            d.stockVaults.length == n && d.stockJoins.length == n && d.stockFeeds.length == n && d.stockPrices.length == n,
            "stage 3: stock contracts recorded"
        );
        if (n == 0) return;
        _code(address(d.calendar), "stage 3 MarketCalendar");
        require(d.calendar.governor() == cfg.governor, "stage 3: calendar governor");
        uint256 first = cfg.ilks.length + (cfg.seats.enabled ? 1 : 0);
        for (uint256 i; i < n; ++i) {
            DeployTypes.StockSpec memory t = s.types[i];
            string memory what = string.concat("stage 3 stock type ", vm.toString(i));
            _code(address(d.stockVaults[i]), what);
            _code(address(d.stockFeeds[i]), what);
            _code(address(d.stockPrices[i]), what);
            _code(address(d.stockJoins[i]), what);
            require(d.stockVaults[i].asset() == t.stock, string.concat(what, ": vault"));
            MarketHoursFeed f = d.stockFeeds[i];
            require(
                f.aggregator() == t.aggregator && f.stock() == t.stock && f.holder() == address(d.stockVaults[i])
                    && f.calendar() == d.calendar && f.maxAge() == t.maxAge,
                string.concat(what, ": market-hours feed")
            );
            RateFeed p = d.stockPrices[i];
            require(
                p.rateSource() == address(d.stockVaults[i]) && address(p.underlying()) == address(f) && p.passOneE18()
                    && p.maxGrowthPerSecond() == s.rateCap,
                string.concat(what, ": price")
            );
            StockJoin j = d.stockJoins[i];
            require(
                j.ilk() == t.ilk && j.token() == address(d.stockVaults[i]) && address(j.usdg()) == s.usdg && j.wirer() == me
                    && j.auctionTime() == t.auctionTime && j.floor() == t.auctionFloor,
                string.concat(what, ": join")
            );
            require(j.ledger() == address(d.ledger), string.concat(what, ": join.wire"));
            require(d.params.ilks(first + i) == t.ilk, string.concat(what, ": order"));
            ParametersBase.Config memory c = d.params.config(t.ilk);
            require(
                c.token == address(d.stockVaults[i]) && c.join == address(j) && address(c.median) == address(p)
                    && address(c.spot) == address(p) && c.auction && !c.redeemable && address(c.nhi) == address(0),
                string.concat(what, ": config")
            );
            if (strict) {
                require(keccak256(abi.encode(d.params.storedRisk(t.ilk))) == keccak256(abi.encode(t.risk)), string.concat(what, ": risk"));
                (uint8 group, uint256 line) = d.params.groupCap(t.ilk);
                require(group == s.group && line == s.groupLine, string.concat(what, ": group"));
            }
        }
    }

    /// @notice The bridge's LayerZero endpoint: the config's (Robinhood), else Ethereum's (the mainnet bridge).
    function _bridgeEndpoint(DeployTypes.Config memory cfg) internal view returns (address) {
        if (cfg.bridge.enabled) return cfg.bridge.endpoint;
        require(block.chainid == 1, "no LayerZero endpoint for this chain");
        return MAINNET_LZ_ENDPOINT;
    }

    address internal constant MAINNET_LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // EndpointV2, Ethereum

    /// @notice The bridge landed: ImdBridge for this deployment's imdUSD, governed by the Safe, fee to this Treasury. Its paths,
    /// SET_BRIDGE and limits are the Safe's timelocked acts afterwards (script/launch/BridgeBatch.s.sol), so nothing else here.
    function _checkBridge(DeployTypes.Config memory cfg, Deployed memory d) internal view {
        _code(address(d.bridge), "bridge ImdBridge");
        require(
            address(d.bridge.endpoint()) == _bridgeEndpoint(cfg) && address(d.bridge.minterBurner()) == address(d.usd)
                && d.bridge.governor() == cfg.governor && d.bridge.treasury() == address(d.treasury),
            "bridge: endpoint, token, governor or Treasury"
        );
    }

    function _checkSeats(DeployTypes.Config memory cfg, Deployed memory d, address me, bool strict) internal view {
        DeployTypes.SeatSpec memory s = cfg.seats;
        _code(address(d.seatJoin), "stage 3 SeatJoin");
        _code(address(d.seatFeed), "stage 3 SeatFeed");
        _code(address(d.seatSpot), "stage 3 SeatSpotLeg");
        require(address(d.seatJoin.nft()) == s.nft && d.seatJoin.wirer() == me, "stage 3: SeatJoin");
        require(address(d.seatJoin.ledger()) == address(d.ledger), "stage 3: seatJoin.wire");
        if (strict) require(d.seatJoin.maxSeats() == s.maxSeats && d.seatJoin.perBorrower() == s.perBorrower, "stage 3: seat limits"); // SET_SEAT_LIMITS
        require(
            address(d.seatFeed.median()) == address(d.feeds[s.median]) && address(d.seatFeed.spot()) == address(d.feeds[s.spot])
                && address(d.seatFeed.ethUsd()) == address(d.feeds[s.ethUsd]),
            "stage 3: SeatFeed legs"
        );
        require(address(d.seatSpot.feed()) == address(d.seatFeed), "stage 3: SeatSpotLeg");
        ParametersBase.Config memory c = d.params.config(s.ilk);
        require(
            c.join == address(d.seatJoin) && c.token == address(d.seatJoin) && address(c.median) == address(d.seatFeed)
                && address(c.spot) == address(d.seatSpot) && c.auction && !c.redeemable,
            "stage 3: SEAT config"
        );
        if (strict) require(keccak256(abi.encode(d.params.storedRisk(s.ilk))) == keccak256(abi.encode(s.risk)), "stage 3: SEAT risk");
    }

    function _checkGenesis(DeployTypes.Config memory cfg, Deployed memory d, bool strict) internal view {
        _code(address(d.savings), "stage 4 SavingsVault");
        require(d.savings.asset() == address(d.usd), "stage 4: savings asset");
        (address sv, uint256 share) = d.params.savingsSplit();
        require(sv == address(d.savings) && (!strict || share == cfg.savingsShare), "stage 4: setGenesisSavings");
        require(d.params.depthIlk() == cfg.depthIlk, "stage 4: setGenesisDepthRule");
        // k, the posted cap and the other chains' terms move by SET_DEPTH_K, SET_DEPTH (file 1), SET_OTHER_IMD.
        if (strict) {
            require(
                d.params.depthK() == cfg.depthK && d.params.depthCap() == cfg.depthIMD
                    && d.params.otherImdLines() == cfg.otherImdLines && d.params.otherImdChop() == cfg.otherImdChop,
                "stage 4: setGenesisDepthRule values"
            );
        }
        if (cfg.depth.enabled) {
            _code(address(d.imdDepth), "stage 4 ImdDepth");
            require(address(d.params.imdDepth()) == address(d.imdDepth) && d.imdDepth.params() == address(d.params), "stage 4: ImdDepth wiring");
            require(d.samplers.length == cfg.depth.samplers.length, "stage 4: depth samplers recorded");
            for (uint256 i; i < d.samplers.length; ++i) {
                _code(address(d.samplers[i]), "stage 4 DepthSampler");
                require(PoolId.unwrap(d.samplers[i].poolId()) == cfg.depth.samplers[i].poolId, "stage 4: depth sampler pool");
                require(d.samplers[i].bandBps() == cfg.depth.samplers[i].bandBps, "stage 4: depth sampler band");
            }
            // The listing moves by ADD_DEPTH_SAMPLER and removeDepthSampler; the recorded samplers do not.
            if (strict) {
                address[] memory listed = d.imdDepth.samplers();
                require(listed.length == d.samplers.length, "stage 4: depth samplers listed");
                for (uint256 i; i < listed.length; ++i) require(listed[i] == address(d.samplers[i]), "stage 4: depth sampler order");
            }
        } else {
            require(address(d.params.imdDepth()) == address(0), "stage 4: no ImdDepth in this config");
        }
        if (cfg.backstop.enabled) _checkBackstop(cfg, d, strict);
        else require(d.params.blueBackstop() == address(0), "stage 4: no Backstop in this config");
        if (cfg.pegPositions.enabled) _checkPeg(cfg, d);
        _code(address(d.notes), "stage 4 FeeNotes");
        require(address(d.notes.token()) == address(d.usd) && address(d.notes.quote()) == cfg.pegQuote, "stage 4: notes tokens");
        require(address(d.notes.treasury()) == address(d.treasury) && d.notes.params() == address(d.params), "stage 4: notes wiring");
        require(d.treasury.notes() == address(d.notes) && d.params.notes() == address(d.notes), "stage 4: notes wired both ways");
        if (strict) require(d.notes.count() == 0, "stage 4: no note series at launch");
        _code(address(d.hook), "stage 4 PegHook");
        require(d.hook.stable() == address(d.usd) && d.hook.quote() == cfg.pegQuote, "stage 4: hook tokens");
        require(
            d.hook.quoteUsdFeed() == cfg.pegQuoteFeed && d.hook.quoteFeedMaxAge() == cfg.pegQuoteFeedMaxAge,
            "stage 4: hook quote feed"
        );
        require(d.hook.treasury() == address(d.treasury) && address(d.hook.params()) == address(d.params), "stage 4: hook wiring");
        require(d.hook.initialized(), "stage 4: peg pool not initialised");
        // At $1 only at genesis: the first swap in the pool moves slot0 (outside
        // `strict` this broke `launch.sh status/go/safe` for the life of the deployment, so the day-7 file could not
        // be regenerated as the operator runbook, not public, instructs).
        if (strict) {
            (uint160 sp,,,) = IPoolManager(cfg.poolManager).getSlot0(_pegKey(d.hook).toId());
            require(sp == d.hook.pegSqrtPriceX96(), "stage 4: peg pool not at $1");
        }
        require(d.usd.keeper() == address(d.hook), "stage 4: keeper minter");
        if (strict) require(d.params.keeperCap() == 0 && d.params.bufferTarget() == 0 && d.hook.buffer() == 0, "stage 4: keeper cap 0, buffer target 0 and an empty buffer at genesis");
        // Every wirer power is spent.
        require(d.params.sealed_(), "stage 4: Parameters not sealed");
        require(d.usd.ledger() != address(0) && d.params.ledger() != address(0), "stage 4: a wire left");
        require(address(d.treasury.ledger()) != address(0) && d.treasury.notes() != address(0), "stage 4: a Treasury wire left");
        require(d.ledger.redeemer() != address(0), "stage 4: ledger.wire left");
        for (uint256 i; i < d.joins.length; ++i) require(d.joins[i].ledger() != address(0), "stage 4: a join wire left");
        if (strict) require(d.usd.bridge() == address(0), "stage 4: no bridge at launch"); // SET_BRIDGE may land later
        require(d.params.governor() == cfg.governor && d.treasury.governor() == cfg.governor, "stage 4: governor");
        if (cfg.lpVault.enabled) {
            _code(address(d.pegLP), "stage 4 PegLPVault");
            require(address(d.pegLP.hook()) == address(d.hook) && d.pegLP.treasury() == address(d.treasury), "stage 4: PegLPVault wiring");
            require(d.pegLP.tickUpper() - d.pegLP.tickLower() == 2 * cfg.lpVault.band, "stage 4: PegLPVault band");
        } else {
            require(address(d.pegLP) == address(0), "stage 4: PegLPVault is off in this config");
        }
    }

    /// @dev Oracle, both sleeves and the Allocator deployed, wired, listed and sealed; Parameters points at them.
    function _checkBackstop(DeployTypes.Config memory cfg, Deployed memory d, bool strict) internal view {
        _code(address(d.backstopOracle), "stage 4 PricerOracle");
        _code(address(d.blue), "stage 4 Backstop blue");
        _code(address(d.edge), "stage 4 Backstop edge");
        _code(address(d.allocator), "stage 4 Allocator");
        require(d.params.blueBackstop() == address(d.blue) && d.params.edgeBackstop() == address(d.edge), "stage 4: sleeves in Parameters");
        if (strict) require(d.params.edgePremium() == cfg.backstop.edgePremium, "stage 4: edge premium"); // SET_EDGE_PREMIUM, lowerEdgePremium
        require(d.backstopOracle.sealed_() && d.blue.isSealed() && d.edge.isSealed(), "stage 4: oracle + sleeves sealed");
        require(address(d.backstopOracle.pricer()) == address(d.pricer) && d.backstopOracle.params() == address(d.params), "stage 4: oracle wiring");
        Backstop[2] memory sl = [d.blue, d.edge];
        for (uint256 k; k < 2; ++k) {
            require(address(sl[k].oracle()) == address(d.backstopOracle) && address(sl[k].ledger()) == address(d.ledger), "stage 4: sleeve reads");
            require(
                sl[k].liquidator() == address(d.liquidator) && sl[k].params() == address(d.params) && sl[k].seller() == address(d.allocator),
                "stage 4: sleeve wiring"
            );
        }
        require(!d.blue.edge() && d.edge.edge(), "stage 4: sleeve kinds");
        for (uint256 i; i < cfg.backstop.ilks.length; ++i) {
            DeployTypes.SleeveIlk memory si = cfg.backstop.ilks[i];
            address token = d.params.config(si.ilk).token;
            require(d.backstopOracle.ilkOf(token) == si.ilk, "stage 4: oracle maps the type's token");
            (address listed,,, bool on) = (si.edge ? d.edge : d.blue).ilks(si.ilk);
            require(listed == token, "stage 4: type listed in its sleeve");
            if (strict) require(on && d.params.edgeIlk(si.ilk) == si.edge, "stage 4: type on in its sleeve"); // disableSleeveIlk
        }
        require(d.allocator.treasury() == address(d.treasury) && d.allocator.governor() == cfg.governor, "stage 4: Allocator wiring");
        if (strict) require(d.allocator.freezer() == cfg.backstop.freezer, "stage 4: Allocator freezer"); // the Safe (MainnetConfig.GOVERNANCE_SAFE)
    }

    /// @dev The peg-position contracts of stage 4, all immutable wiring.
    function _checkPeg(DeployTypes.Config memory cfg, Deployed memory d) internal view {
        _code(address(d.pegFeed), "stage 4 PegShareFeed");
        _code(address(d.pegJoin), "stage 4 peg Join");
        _code(address(d.pegZap), "stage 4 PegPositionZap");
        _code(address(d.pegCollateral), "stage 4 PegCollateral");
        ParametersBase.Config memory c = d.params.config(cfg.pegPositions.ilk);
        require(
            c.token == address(d.pegCollateral) && c.join == address(d.pegJoin) && address(c.median) == address(d.pegFeed) && !c.redeemable,
            "stage 4: PEG config"
        );
        require(address(d.pegFeed.vault()) == address(d.pegLP) && !d.pegFeed.twoSidedOnly(), "stage 4: PegShareFeed");
        PegShareFeed leg = PegShareFeed(address(c.spot));
        _code(address(leg), "stage 4 PEG spot leg");
        require(address(leg.vault()) == address(d.pegLP) && leg.twoSidedOnly(), "stage 4: PEG spot leg");
        require(
            d.pegJoin.token() == address(d.pegCollateral) && d.pegJoin.ledger() == address(d.ledger) && d.pegJoin.wirer() == d.params.wirer(),
            "stage 4: peg Join"
        );
        require(d.pegZap.ilk() == cfg.pegPositions.ilk && address(d.pegZap.vault()) == address(d.pegLP), "stage 4: PegPositionZap");
        require(
            address(d.pegCollateral.shares()) == address(d.pegLP) && d.pegCollateral.zap() == address(d.pegZap)
                && address(d.pegZap.collateral()) == address(d.pegCollateral),
            "stage 4: PegCollateral"
        );
    }

    // ---------------------------------------------------------------- recorded code

    /// @notice Every contract the record names, if it has code, is THIS build's contract of that name: its runtime code
    /// equals the compiled one except the immutables. Getters alone cannot tell a look-alike from the real one, and the
    /// PegHook a stage adopts becomes the permanent keeper minter. A recorded contract with other code stops the run: a
    /// person decides (the operator runbook, not public). The DEX contracts are not covered: their artifacts carry unlinked library placeholders
    /// (the hook's address commits to its code through the recorded CREATE2 salt, proved by verify.py).
    function _checkRecordedCode(DeployTypes.Config memory cfg, Deployed memory d) internal view {
        _same(address(d.usd), "src/ImdUSD.sol:ImdUSD");
        _same(address(d.params), "src/Parameters.sol:Parameters");
        // The two modules are deployed on their own since audit wave 3: their code is checked like every recorded contract.
        if (_has(address(d.params))) _same(address(d.params.rules()), "src/ParametersRules.sol:ParametersRules");
        if (_has(address(d.ledger))) _same(d.ledger.settlement(), "src/LedgerSettlement.sol:LedgerSettlement");
        _same(address(d.pricer), "src/Pricer.sol:Pricer");
        _same(address(d.treasury), "src/Treasury.sol:Treasury");
        _same(address(d.ledger), "src/Ledger.sol:Ledger");
        _same(address(d.redeemer), "src/Redeemer.sol:Redeemer");
        _same(address(d.liquidator), "src/Liquidator.sol:Liquidator");
        _same(address(d.migrator), "src/Migrator.sol:Migrator");
        for (uint256 i; i < d.feeds.length && i < cfg.feeds.length; ++i) _same(address(d.feeds[i]), _feedArtifact(cfg.feeds[i].kind));
        for (uint256 i; i < d.joins.length; ++i) _same(address(d.joins[i]), "src/Join.sol:Join");
        _same(address(d.seatJoin), "src/seats/SeatJoin.sol:SeatJoin");
        _same(address(d.seatFeed), "src/feeds/SeatFeed.sol:SeatFeed");
        _same(address(d.seatSpot), "src/feeds/SeatFeed.sol:SeatSpotLeg");
        _same(address(d.savings), "src/SavingsVault.sol:SavingsVault");
        _same(address(d.notes), "src/peg/FeeNotes.sol:FeeNotes");
        _same(address(d.hook), "src/peg/PegHook.sol:PegHook");
        _same(address(d.pegLP), "src/earn/PegLPVault.sol:PegLPVault");
        _same(address(d.pegFeed), "src/earn/PegShareFeed.sol:PegShareFeed");
        _same(address(d.pegJoin), "src/Join.sol:Join");
        _same(address(d.pegZap), "src/earn/PegPositionZap.sol:PegPositionZap");
        _same(address(d.pegCollateral), "src/earn/PegCollateral.sol:PegCollateral");
        _same(address(d.imdDepth), "src/feeds/ImdDepth.sol:ImdDepth");
        for (uint256 i; i < d.samplers.length; ++i) _same(address(d.samplers[i]), "src/feeds/DepthSampler.sol:DepthSampler");
        _same(address(d.backstopOracle), "src/backstop/PricerOracle.sol:PricerOracle");
        _same(address(d.blue), "src/backstop/Backstop.sol:Backstop");
        _same(address(d.edge), "src/backstop/Backstop.sol:Backstop");
        _same(address(d.allocator), "src/peg/Allocator.sol:Allocator");
        _same(address(d.loop), "src/earn/LoopVault.sol:LoopVault");
        _same(address(d.pulse), "src/Pulse.sol:Pulse");
        _same(address(d.bridge), "src/bridge/ImdBridge.sol:ImdBridge");
        _same(address(d.calendar), "src/feeds/MarketCalendar.sol:MarketCalendar");
        for (uint256 i; i < d.stockVaults.length; ++i) _same(address(d.stockVaults[i]), "src/stocks/StockVault.sol:StockVault");
        for (uint256 i; i < d.stockFeeds.length; ++i) _same(address(d.stockFeeds[i]), "src/feeds/MarketHoursFeed.sol:MarketHoursFeed");
        for (uint256 i; i < d.stockPrices.length; ++i) _same(address(d.stockPrices[i]), "src/feeds/RateFeed.sol:RateFeed");
        for (uint256 i; i < d.stockJoins.length; ++i) _same(address(d.stockJoins[i]), "src/stocks/StockJoin.sol:StockJoin");
    }

    function _feedArtifact(uint8 kind) internal pure returns (string memory) {
        if (kind == DeployTypes.CHAINLINK) return "src/feeds/ChainlinkFeed.sol:ChainlinkFeed";
        if (kind == DeployTypes.PRODUCT) return "src/feeds/ProductFeed.sol:ProductFeed";
        if (kind == DeployTypes.RATE) return "src/feeds/RateFeed.sol:RateFeed";
        if (kind == DeployTypes.LIVE_POOL) return "src/feeds/LivePoolPrice.sol:LivePoolPrice";
        if (kind == DeployTypes.PROVEN_POOL) return "src/feeds/ProvenPoolPrice.sol:ProvenPoolPrice";
        if (kind == DeployTypes.SWARM_PRICE) return "src/feeds/SwarmFeeds.sol:SwarmPriceFeed";
        if (kind == DeployTypes.SWARM_SPOT) return "src/feeds/SwarmFeeds.sol:SwarmSpotFeed";
        if (kind == DeployTypes.SWARM_NHI) return "src/feeds/SwarmFeeds.sol:SwarmNhiFeed";
        if (kind == DeployTypes.SWARM_SEAT_MEDIAN) return "src/feeds/SwarmFeeds.sol:SwarmSeatMedianFeed";
        if (kind == DeployTypes.SWARM_SEAT_SPOT) return "src/feeds/SwarmFeeds.sol:SwarmSeatSpotFeed";
        return ""; // EXISTING: not ours to compare (stage 2 proves its stale allowance instead)
    }

    /// @dev solc: PUSH32 of 32 zero bytes at every immutable. A test on another compiler's narrower pushes lowers this.
    function _immutableRun() internal view virtual returns (uint256) {
        return 32;
    }

    /// @dev The compiled runtime has zero bytes at each immutable (a run of at least `_immutableRun()` zeros may hold one);
    /// everywhere else the code must match exactly.
    function _same(address a, string memory artifact) internal view {
        if (!_has(a) || bytes(artifact).length == 0) return;
        bytes memory want = vm.getDeployedCode(artifact);
        bytes memory got = a.code;
        if (want.length != got.length) revert Mismatch(string.concat("recorded code is not ", artifact));
        uint256 i;
        while (i < want.length) {
            if (want[i] == got[i]) {
                ++i;
                continue;
            }
            uint256 lo = i;
            while (lo != 0 && want[lo - 1] == 0) --lo;
            uint256 hi = i;
            while (hi < want.length && want[hi] == 0) ++hi;
            if (hi - lo < _immutableRun()) revert Mismatch(string.concat("recorded code is not ", artifact));
            i = hi;
        }
    }

    function _checkModules(DeployTypes.Config memory cfg, Deployed memory d, bool strict) internal view {
        if (cfg.loopVault.enabled) {
            _code(address(d.loop), "stage 5 LoopVault");
            require(d.loop.ledger() == d.ledger && d.loop.ilk() == cfg.loopVault.ilk && d.loop.treasury() == address(d.treasury), "stage 5: LoopVault");
        } else {
            require(address(d.loop) == address(0), "stage 5: LoopVault is off in this config");
        }
        if (cfg.dex.enabled) {
            _code(d.curveLib, "stage 5 CompoundCurve");
            _code(d.oracleLib, "stage 5 CompoundOracle");
            _code(address(d.dexHook), "stage 5 CompoundHook");
            _code(address(d.dexLens), "stage 5 CompoundLens");
            require(d.dexHook.treasury() == address(d.treasury) && d.dexHook.initialized(), "stage 5: CompoundHook");
            if (strict) {
                (uint160 sp,,,) = IPoolManager(cfg.poolManager).getSlot0(_dexKey(d.dexHook).toId());
                require(sp == d.dexHook.initialSqrtPriceX96(), "stage 5: DEX pool not at its opening price");
            }
        } else {
            require(address(d.dexHook) == address(0) && d.curveLib == address(0), "stage 5: the DEX is off in this config");
        }
    }

    /// @notice The stages this config has: 1-4 always, 5 only when a module is on.
    function stageCount() public pure returns (uint8) {
        DeployTypes.Config memory cfg = config();
        // PegLPVault is in stage 4. Robinhood: stage 5 = the bridge (it has no loop or DEX module).
        return cfg.loopVault.enabled || cfg.dex.enabled || cfg.bridge.enabled ? 5 : 4;
    }
}

/// @dev The two mainnet configs, as mixins for every launch script.
abstract contract BetaEntry is LaunchBase {
    function config() public pure override returns (DeployTypes.Config memory) {
        return BetaConfig.get();
    }

    function configName() public pure override returns (string memory) {
        return "beta";
    }
}

abstract contract FullEntry is LaunchBase {
    function config() public pure override returns (DeployTypes.Config memory) {
        return MainnetConfig.get();
    }

    function configName() public pure override returns (string memory) {
        return "full";
    }
}

/// @dev Robinhood Chain (4663): the full 4663 core incl. stock types, stage 5 = its ImdBridge.
abstract contract RobinhoodEntry is LaunchBase {
    function config() public pure override returns (DeployTypes.Config memory) {
        return RobinhoodConfig.get();
    }

    function configName() public pure override returns (string memory) {
        return "robinhood";
    }
}
