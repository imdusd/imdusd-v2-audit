// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Parameters} from "../../src/Parameters.sol";
import {DeployTypes, BetaConfig, MainnetConfig, DepthMath} from "../DeployConfig.sol";
import {LaunchBase, BetaEntry, FullEntry} from "./LaunchBase.sol";

/// @notice The governance Safe's post-deploy acts, as Safe Transaction Builder files, each SIMULATED
/// FROM THE SAFE first, in order, on the chain the RPC serves (mainnet or a fork): nothing is broadcast, the run's
/// state changes stay in forge's local simulation.
///
///   forge script script/launch/SafeBatch.s.sol:SafeBatch<Beta|Full> --rpc-url <rpc>      (launch.sh safe)
///
/// Files (deploy/mainnet/out/safe/<config>/, or LAUNCH_SAFE_DIR), each named with its earliest date (UTC):
///   0  deploy day       Parameters.propose(SET_BUFFER_TARGET, 5,000 USDC); applyPending() by anyone 48 h later
///   1  day 7            beta: ONE Parameters.propose(BATCH, [SET_DEPTH(cap), SET_KEEPER_CAP 50k]): the peg keeper opens, the sIMD
///                       line stays 0; written whatever the sIMD legs read, and D1 must hold. full: Parameters.propose(SET_KEEPER_CAP,
///                       250k). applyPending() by anyone 48 h later. The cap is LAUNCH_IMD_DEPTH (USD, whole dollars; default the
///                       config's genesis depth).
///   6  no date (beta)   Parameters.propose(SET_RISK, SIMD, line), line = min(50k, D1's room on min(cap, ImdDepth.depth() now)), after
///                       file 1 applies. ONLY once the sIMD and NHI legs are seeded and checked (`_legsChecked`):
///                       until then it is not written and the line stays 0. A run warps past the keeper's pokes, so the simulation holds
///                       the measured depth at that figure. REGENERATE ON THE DAY.
///   2  day 14 (beta)    Parameters.propose(SET_RISK, ETH, line x2); applyPending() 48 h later
///   3  2027-01-16 04:00 (beta) Parameters.propose(SET_MIGRATOR_LINE, max(150k, 2 x v1 supply)); apply from 01-18 04:00
///   4  deploy day       Allocator.propose(ADD_KEEPER, LAUNCH_ALLOCATOR_KEEPER); applyPending() 48 h later. The
///                       Allocator has its own pending slots, one per kind: its targets, limits and feeds follow
///                       (the operator runbook, not public). Written only when the config has a backstop. THE BETA LEAVES
///                       LAUNCH_ALLOCATOR_KEEPER UNSET: the rule-driven actions need no keeper role.
///   5  deploy day + 48h Allocator.propose(SET_FREEZER, GUARDIAN) after file 4 applies; applyPending() 48 h later. The freezer is
///                       the Safe from genesis and there is no guardian key: written only if a different freezer is ever wanted.
/// The timelocked acts are simulated in sequence, never stacked. A RERUN WRITES ONLY WHAT IS STILL TO DO: a file whose act has
/// applied, or whose kind a proposal on chain still holds, is left out and the run says which.
/// Regenerate file 3 on the day: its line is computed from v1's supply at the block simulated.
abstract contract SafeBatch is LaunchBase {
    uint256 internal constant BETA_KEEPER_CAP = 50_000e18; // file 1 (beta); a constant, not an argument: _batch is near solc's stack limit
    uint256 internal constant BUFFER_TARGET = 5_000e6; // keeper profit kept as the below-peg buyer, USDC
    uint256 internal constant MIGRATION_PROPOSE_AT = 1800072000; // Sat 2027-01-16 04:00 UTC
    uint256 internal constant MIGRATION_FLOOR = 150_000e18;

    struct Tx {
        address to;
        bytes data;
    }

    /// @notice What the operator gives on the day (zero = default / skip).
    struct Inputs {
        uint256 depthUsd; // LAUNCH_IMD_DEPTH, whole dollars
        address allocatorKeeper; // LAUNCH_ALLOCATOR_KEEPER
        address guardian; // GUARDIAN
        bool assumeLegsChecked; // LAUNCH_REHEARSAL_ASSUME_LEGS_CHECKED, rehearsals only (FORK=1): file 6 is marked DO NOT SIGN
    }

    function run() external virtual {
        (Deployed memory d, Rec memory r) = _load();
        require(r.exists, "no record");
        DeployTypes.Config memory cfg = config();
        for (uint8 s = 1; s <= stageCount(); ++s) _checkStage(cfg, d, r, s, false);
        string memory dir = vm.envOr("LAUNCH_SAFE_DIR", string.concat("deploy/mainnet/out/safe/", configName()));
        vm.createDir(dir, true);
        _batch(
            cfg,
            d,
            dir,
            Inputs(
                vm.envOr("LAUNCH_IMD_DEPTH", uint256(0)),
                vm.envOr("LAUNCH_ALLOCATOR_KEEPER", address(0)),
                vm.envOr("GUARDIAN", address(0)),
                vm.envOr("FORK", uint256(0)) == 1 && vm.envOr("LAUNCH_REHEARSAL_ASSUME_LEGS_CHECKED", false)
            )
        );
        console2.log("Safe batch files written to", dir);
    }

    /// @notice The cap to post and the depth a line is sized on, and the measured depth held at that figure for
    /// the rest of the simulation. ImdDepth reads 0 past a day with no recorded low and the simulation's warps are exactly
    /// that, so `measured` must be read BEFORE any warp (in `_batch`). Live reading: sized on min(cap, measured), what D1
    /// will admit. None yet (no full week of pokes): sized on the cap, and the note says to regenerate.
    function _holdDepth(DeployTypes.Config memory cfg, Deployed memory d, uint256 capUsd, uint256 measured, bool keeperOpen)
        internal
        returns (uint256 cap_, uint256 sized)
    {
        // Once file 1 has applied, the cap on chain is the then-current one unless the operator names another.
        cap_ = capUsd != 0 ? capUsd * 1e18 : (keeperOpen ? d.params.depthCap() : cfg.depthIMD);
        sized = measured != 0 && measured < cap_ ? measured : cap_;
        if (measured == 0) console2.log("depth: ImdDepth has no full week yet, sized on the posted cap: regenerate on the day");
        if (address(d.imdDepth) != address(0)) vm.mockCall(address(d.imdDepth), abi.encodeWithSignature("depth()"), abi.encode(sized));
    }

    /// @notice Beta. File 1 = the keeper (depth cap + keeper cap, line still 0), written whatever the sIMD legs read: the peg
    /// keeper does not price from them. File 6 = the sIMD line, written only once the legs are seeded and checked.
    /// Sequential, never stacked.
    function _keeperAndLineFiles(
        DeployTypes.Config memory cfg,
        Deployed memory d,
        string memory dir,
        Tx[] memory t,
        Inputs memory inputs,
        uint256 at,
        uint256 measured,
        uint256 flags // bit 0 keeperOpen, bit 1 legsChecked: one stack slot (solc via-IR ran out with two bools)
    ) internal {
        (uint256 depth, uint256 sized) = _holdDepth(cfg, d, inputs.depthUsd, measured, flags & 1 != 0);
        if (flags & 1 != 0) {
            console2.log("file 1 not written: the keeper cap has moved from genesis (file 1 applied, or the Safe set it): decide any change by hand");
        } else if (_held(d, _bit(d.params.BATCH()) | _bit(d.params.SET_DEPTH()) | _bit(d.params.SET_KEEPER_CAP()))) {
            // File 6 is sized on what file 1 leaves: it waits for file 1 too.
            return console2.log("files 1 and 6 not written: a proposal on chain holds the keeper cap or the depth. Rerun once it is applied or cancelled (an expired one must be cancelled)");
        } else {
            _keeperFile(d, dir, t, cfg.governor, at, depth);
        }
        _simdLineFile(cfg, d, dir, t, inputs, depth, sized, flags & 1 != 0, flags & 2 != 0);
    }

    /// @dev File 1 (beta), on its own: inline in `_keeperAndLineFiles` it ran solc via-IR out of stack slots.
    function _keeperFile(Deployed memory d, string memory dir, Tx[] memory t, address safe, uint256 at, uint256 depth)
        internal
    {
        vm.warp(at);
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(d.params.SET_DEPTH(), depth);
        items[1] = abi.encode(d.params.SET_KEEPER_CAP(), BETA_KEEPER_CAP);
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.BATCH(), items)));
        _exec(safe, t);
        _applyAfterTimelock(d, d.params.BATCH());
        require(d.params.keeperCap() == BETA_KEEPER_CAP && d.params.storedRisk("SIMD").line == 0, "simulated: keeper file");
        (bool holds,,) = d.params.depthRule();
        require(holds, "simulated: D1 holds after the keeper file");
        _write(
            dir,
            1,
            at,
            string.concat("Peg keeper cap 0 -> ", vm.toString(BETA_KEEPER_CAP / 1e18), ", sIMD line stays 0"),
            string.concat(
                "Parameters.propose(BATCH: SET_DEPTH ", vm.toString(depth / 1e18), " USD, SET_KEEPER_CAP). ",
                "The sIMD line is file 6. Anyone calls Parameters.applyPending() 48 h after it executes."
            ),
            safe,
            t
        );
    }

    function _simdLineFile(
        DeployTypes.Config memory cfg,
        Deployed memory d,
        string memory dir,
        Tx[] memory t,
        Inputs memory inputs,
        uint256 depth,
        uint256 sized,
        bool keeperOpen,
        bool legsChecked
    ) internal {
        ParametersBase.Risk memory sr = d.params.storedRisk("SIMD");
        if (sr.line != 0) return console2.log("file 6 not written: the sIMD line is already open");
        if (!legsChecked) {
            return console2.log("file 6 NOT written: the sIMD and NHI legs are not seeded and checked. The sIMD line stays 0 (the operator runbook, not public).");
        }
        if (_held(d, _bit(d.params.SET_DEPTH()) | _bit(d.params.SET_RISK()))) {
            return console2.log("file 6 not written: a proposal on chain holds SET_RISK or the depth. Rerun once it is applied or cancelled (an expired one must be cancelled)");
        }
        sr.line = DepthMath.fit(
            BetaConfig.SIMD_LINE_TARGET, d.params.depthK(), sized, sr.chop, sr.redeemCap, d.params.otherImdLines(), d.params.otherImdChop()
        );
        if (sr.line == 0) return console2.log("file 6 NOT written: D1 leaves no room for an sIMD line at this depth");
        bytes memory setRisk = abi.encode(d.params.SET_RISK(), bytes32("SIMD"), sr);
        bytes memory payload = setRisk;
        if (keeperOpen && depth != d.params.depthCap()) {
            // A new cap named after file 1 has applied goes in the same proposal: the line is sized on it.
            bytes[] memory items = new bytes[](2);
            items[0] = abi.encode(d.params.SET_DEPTH(), depth);
            items[1] = setRisk;
            payload = abi.encode(d.params.BATCH(), items);
            if (_held(d, _bit(d.params.BATCH()))) return console2.log("file 6 not written: a BATCH proposal is pending on chain. Rerun once it is applied or cancelled");
        }
        uint256 at = vm.getBlockTimestamp();
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", payload));
        _exec(cfg.governor, t);
        _applyAfterTimelock(d, abi.decode(payload, (uint8)));
        require(d.params.storedRisk("SIMD").line == sr.line, "simulated: sIMD line");
        (bool holds,,) = d.params.depthRule();
        require(holds, "simulated: D1 holds after the sIMD line");
        _write(
            dir,
            6,
            at,
            string.concat(inputs.assumeLegsChecked ? "REHEARSAL, DO NOT SIGN: " : "", "sIMD line 0 -> ", vm.toString(uint256(sr.line) / 1e18)),
            string.concat(
                "Parameters.propose(SET_RISK SIMD line). Sized on ", vm.toString(sized / 1e18),
                " USD (min of the cap and ImdDepth.depth() when generated), which the simulation holds. ",
                "REGENERATE WHILE THE LEGS ARE FRESH: the apply fails if ImdDepth measures less 48 h later. Anyone calls Parameters.applyPending() 48 h after it executes."
            ),
            cfg.governor,
            t
        );
    }

    /// @notice Whether the v2-native sIMD and NHI legs are seeded and checked NOW: the median and NHI leaves and the proven
    /// spot (price design C: sIMD's spot is pool 0xb07d's proven end-of-block price, no swarm leaf) hold a fresh value, the
    /// median and the spot sit within a quarter of the cap of the live pool (nothing on chain bounds a leaf's first value:
    /// v1's verifySeeded rule), NHI is an index, and the Pricer prices sIMD with agreeing, converged legs. The operator also
    /// compares the attested windows with an own rerun (the operator runbook, not public): that part cannot be read from chain.
    function _legsChecked(Deployed memory d) internal view returns (bool) {
        (uint256 median,) = d.feeds[MainnetConfig.F_IMD_MEDIAN].latestValue();
        (uint256 spot,) = d.feeds[MainnetConfig.F_IMD_PROVEN].latestValue();
        (uint256 nhi,) = d.feeds[MainnetConfig.F_NHI].latestValue();
        (uint256 live,) = d.feeds[MainnetConfig.F_IMD_LIVE].latestValue();
        if (median == 0 || spot == 0 || nhi == 0 || nhi > 1e18 || live == 0) return false;
        if (
            d.feeds[MainnetConfig.F_IMD_MEDIAN].isStale() || d.feeds[MainnetConfig.F_IMD_PROVEN].isStale()
                || d.feeds[MainnetConfig.F_NHI].isStale()
        ) return false;
        uint256 band = live * MainnetConfig.SWARM_CAP_BPS / 4 / 10_000;
        if (median + band < live || median > live + band || spot + band < live || spot > live + band) return false;
        Pricer.Quote memory q = d.pricer.quote("SIMD");
        return q.priced && q.agree && q.borrowable;
    }

    function _batch(DeployTypes.Config memory cfg, Deployed memory d, string memory dir, Inputs memory inputs) internal {
        // Read before any warp: the simulation below moves past every feed's lifetime.
        bool legsChecked = inputs.assumeLegsChecked || (cfg.migratorClosed && _legsChecked(d));
        uint256 measured = address(d.imdDepth) == address(0) ? 0 : d.imdDepth.depth();
        // File 1 is written only while the keeper cap is still at genesis (0): once the Safe has moved it, by file 1 or by hand
        // (lowerKeeperCap), a regenerated file 1 would undo that.
        bool keeperOpen = cfg.migratorClosed && d.params.keeperCap() != 0;
        address safe = cfg.governor;
        uint256 day0 = vm.getBlockTimestamp(); // not block.timestamp: via-IR may re-read TIMESTAMP after a warp

        Tx[] memory t = new Tx[](1);
        _bufferFile(d, dir, day0, safe, t);

        // 4 and 5 depend on nothing in 1-3 (day-0 acts, the Allocator's own slot): written first so a later file's
        // simulation can never hold them back.
        if (cfg.backstop.enabled) _allocatorFiles(d, dir, day0, safe, t, inputs);

        // 1. Keeper cap, after a week of TWAP history.
        if (cfg.migratorClosed) {
            _keeperAndLineFiles(cfg, d, dir, t, inputs, day0 + 7 days, measured, (keeperOpen ? 1 : 0) | (legsChecked ? 2 : 0));
            _ethLineFile(cfg, d, dir, day0 + 14 days, safe, t);
            _migrationFile(cfg, d, dir, safe, t);
        } else {
            _fullKeeperFile(d, dir, t, safe, day0 + 7 days);
        }
    }

    /// @dev File 1 (full config): the keeper cap alone. Its own function: inline, `_batch` ran solc via-IR out of stack slots.
    function _fullKeeperFile(Deployed memory d, string memory dir, Tx[] memory t, address safe, uint256 at) internal {
        uint256 cap = 250_000e18;
        if (d.params.keeperCap() != 0) {
            console2.log("file 1 not written: the keeper cap has moved from genesis (file 1 applied, or the Safe set it): decide any change by hand");
        } else if (_held(d, _bit(d.params.SET_KEEPER_CAP()))) {
            console2.log("file 1 not written: a proposal on chain holds SET_KEEPER_CAP");
        } else {
            vm.warp(at);
            t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.SET_KEEPER_CAP(), cap)));
            _exec(safe, t);
            _applyAfterTimelock(d, d.params.SET_KEEPER_CAP());
            require(d.params.keeperCap() == cap, "simulated: keeper cap");
            _write(dir, 1, at, string.concat("Peg keeper cap 0 -> ", vm.toString(cap / 1e18)), "Parameters.propose(SET_KEEPER_CAP). Anyone calls Parameters.applyPending() 48 h after it executes.", safe, t);
        }
    }

    /// @dev 0. Buffer target: the keeper keeps its profit as a below-peg buyer up to 5,000 USDC. No money moves.
    function _bufferFile(Deployed memory d, string memory dir, uint256 day0, address safe, Tx[] memory t) internal {
        // Only while still at genesis (0): a regenerated file 0 must not undo a target the Safe has moved since.
        if (d.params.bufferTarget() != 0) return console2.log("file 0 not written: the buffer target has moved from genesis: decide any change by hand");
        if (_held(d, _bit(d.params.SET_BUFFER_TARGET()))) return console2.log("file 0 not written: a proposal on chain holds SET_BUFFER_TARGET");
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.SET_BUFFER_TARGET(), BUFFER_TARGET)));
        _exec(safe, t);
        _applyAfterTimelock(d, d.params.SET_BUFFER_TARGET());
        require(d.params.bufferTarget() == BUFFER_TARGET, "simulated: buffer target");
        _write(dir, 0, day0, "Peg hook buffer target 0 -> 5,000 USDC", "Parameters.propose(SET_BUFFER_TARGET, 5000e6). Anyone calls Parameters.applyPending() 48 h after it executes. Moves no money: it lets the keeper keep its profit.", safe, t);
    }

    /// @dev 2. First ceiling step: ETH line x2 after two weeks with no incident.
    function _ethLineFile(DeployTypes.Config memory cfg, Deployed memory d, string memory dir, uint256 at, address safe, Tx[] memory t) internal {
        ParametersBase.Risk memory rk = d.params.storedRisk("ETH");
        uint128 before_ = rk.line;
        // Rerun for file 3 after this step: doubling again would be a raise nobody decided.
        if (before_ != _genesisLine(cfg, "ETH")) return console2.log("file 2 not written: the ETH line has already moved from genesis");
        if (_held(d, _bit(d.params.SET_RISK()))) return console2.log("file 2 not written: a proposal on chain holds SET_RISK. Rerun once it is applied or cancelled (an expired one must be cancelled)");
        vm.warp(at);
        rk.line = 2 * before_;
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.SET_RISK(), bytes32("ETH"), rk)));
        _exec(safe, t);
        _applyAfterTimelock(d, d.params.SET_RISK());
        require(d.params.storedRisk("ETH").line == 2 * before_, "simulated: ETH line");
        _write(dir, 2, at, string.concat("ETH debt ceiling ", vm.toString(before_ / 1e18), " -> ", vm.toString(rk.line / 1e18)), "Parameters.propose(SET_RISK, ETH, the current risk with line x2). REGENERATE ON THE DAY (launch.sh safe): it carries every ETH risk field as read when written, and refuses once the line has moved. Anyone applies 48 h later.", safe, t);
    }

    /// @dev 3. Migration opens at Season 1's end.
    function _migrationFile(DeployTypes.Config memory cfg, Deployed memory d, string memory dir, address safe, Tx[] memory t) internal {
        if (d.params.migratorLine() != 0) return console2.log("file 3 not written: the migrator line has already opened");
        if (_held(d, _bit(d.params.SET_MIGRATOR_LINE()))) return console2.log("file 3 not written: a proposal on chain holds SET_MIGRATOR_LINE");
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 at = nowTs > MIGRATION_PROPOSE_AT ? nowTs : MIGRATION_PROPOSE_AT;
        uint256 twice = 2 * IERC20(cfg.v1).totalSupply();
        uint256 line = twice > MIGRATION_FLOOR ? twice : MIGRATION_FLOOR;
        vm.warp(at);
        t[0] = Tx(address(d.params), abi.encodeWithSignature("propose(bytes)", abi.encode(d.params.SET_MIGRATOR_LINE(), line)));
        _exec(safe, t);
        _applyAfterTimelock(d, d.params.SET_MIGRATOR_LINE());
        require(d.params.migratorLine() == line, "simulated: migrator line");
        _write(dir, 3, at, string.concat("Open migration: v1 -> v2 line ", vm.toString(line / 1e18)), "Parameters.propose(SET_MIGRATOR_LINE, max(150k, 2 x v1 supply)). Propose Sat 2027-01-16 04:00 UTC; anyone applies from Mon 2027-01-18 04:00 UTC. REGENERATE ON THE DAY (v1 supply moves).", safe, t);
    }

    function _bit(uint8 kind) internal pure returns (uint256) {
        return uint256(1) << kind;
    }

    /// @dev A proposal on chain holds one of these kinds. Applied or cancelled it lets go; expired it still holds (the Safe cancels it).
    function _held(Deployed memory d, uint256 kinds) internal view returns (bool) {
        return d.params.locked() & kinds != 0;
    }

    function _genesisLine(DeployTypes.Config memory cfg, bytes32 ilk) internal pure returns (uint128) {
        for (uint256 i; i < cfg.ilks.length; ++i) {
            if (cfg.ilks[i].ilk == ilk) return cfg.ilks[i].risk.line;
        }
        revert("no such type in the config");
    }

    function _allocatorFiles(Deployed memory d, string memory dir, uint256 day0, address safe, Tx[] memory t, Inputs memory inputs) internal {
        // The Allocator holds one pending proposal per kind (GovernedByKind): only ADD_KEEPER and SET_FREEZER matter here.
        uint256 mine = _bit(d.allocator.ADD_KEEPER()) | _bit(d.allocator.SET_FREEZER()) | _bit(d.allocator.BATCH());
        if (d.allocator.locked() & mine != 0) {
            return console2.log("files 4 and 5 not written: an Allocator proposal on chain holds ADD_KEEPER or SET_FREEZER. Rerun once it is applied or cancelled");
        }
        // 4. The Allocator's keeper (the sleeves' seller acts only through a keeper). Its own timelock, its own slot.
        address keeper = inputs.allocatorKeeper;
        if (keeper == address(0)) {
            console2.log("file 4 skipped: set LAUNCH_ALLOCATOR_KEEPER (the Allocator keeper's key)");
        } else if (d.allocator.isKeeper(keeper)) {
            console2.log("file 4 not written: already the Allocator's keeper");
        } else {
            vm.warp(day0);
            t[0] = Tx(address(d.allocator), abi.encodeWithSignature("propose(bytes)", abi.encode(d.allocator.ADD_KEEPER(), keeper)));
            _exec(safe, t);
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            d.allocator.applyPending(d.allocator.ADD_KEEPER());
            require(d.allocator.isKeeper(keeper), "simulated: allocator keeper");
            _write(dir, 4, day0, "Allocator keeper", "Allocator.propose(ADD_KEEPER, keeper). Anyone calls Allocator.applyPending() 48 h after it executes. Then the targets, limits and feeds, one proposal at a time (the operator runbook, not public).", safe, t);
        }
        // 5. The Allocator's freezer. Genesis makes it the Safe (audit wave 1; no guardian key), so
        // this file is only written if env GUARDIAN names a different freezer. Proposed after file 4 applies: one pending slot.
        address guardian = inputs.guardian;
        if (guardian == address(0)) {
            console2.log("file 5 skipped: the freezer stays the Safe (set env GUARDIAN only to name another)");
        } else if (d.allocator.freezer() == guardian) {
            console2.log("file 5 not written: already the Allocator's freezer");
        } else {
            vm.warp(vm.getBlockTimestamp() + 1);
            t[0] = Tx(address(d.allocator), abi.encodeWithSignature("propose(bytes)", abi.encode(d.allocator.SET_FREEZER(), guardian)));
            _exec(safe, t);
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            d.allocator.applyPending(d.allocator.SET_FREEZER());
            require(d.allocator.freezer() == guardian, "simulated: allocator freezer");
            _write(dir, 5, vm.getBlockTimestamp() - 48 hours, "Allocator freezer (guardian)", "Allocator.propose(SET_FREEZER, guardian) once file 4 has applied. Anyone calls Allocator.applyPending() 48 h later.", safe, t);
        }
    }

    function _exec(address safe, Tx[] memory t) internal {
        for (uint256 i; i < t.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory ret) = t[i].to.call(t[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    /// @dev 48 h later anyone applies (a stranger here, not the Safe); one block later than allowed is refused first. By kind:
    /// another kind may be waiting on chain beside it.
    function _applyAfterTimelock(Deployed memory d, uint8 kind) internal {
        (, uint256 eta) = d.params.pendingOf(kind);
        vm.warp(eta - 1);
        (bool early,) = address(d.params).call(abi.encodeWithSignature("applyPending(uint8)", kind));
        require(!early, "simulated: applied before the timelock");
        vm.warp(eta);
        vm.prank(address(0xdead));
        d.params.applyPending(kind);
    }

    function _write(
        string memory dir,
        uint256 n,
        uint256 notBefore,
        string memory name,
        string memory description,
        address safe,
        Tx[] memory t
    ) internal virtual {
        string memory txs;
        for (uint256 i; i < t.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(t[i].to),
                '","value":"0","data":"',
                vm.toString(t[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory date = _date(notBefore);
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(vm.unixTime()),
            ',"meta":{"name":"',
            name,
            '","description":"',
            string.concat(description, " Earliest: ", date, " (unix ", vm.toString(notBefore), "). Simulated from the Safe in order."),
            '","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":""},"transactions":[',
            txs,
            "]}"
        );
        string memory path = string.concat(dir, "/", vm.toString(n), "-", date, ".json");
        vm.writeFile(path, json);
        console2.log(string.concat("  wrote ", path, "  ", name));
    }

    /// @dev YYYY-MM-DD (UTC) from a unix time (Hinnant's days-to-civil).
    function _date(uint256 ts) internal pure returns (string memory) {
        int256 z = int256(ts / 1 days) + 719468;
        int256 era = z / 146097;
        int256 doe = z - era * 146097;
        int256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int256 mp = (5 * doy + 2) / 153;
        int256 day = doy - (153 * mp + 2) / 5 + 1;
        int256 month = mp < 10 ? mp + 3 : mp - 9;
        int256 year = yoe + era * 400 + (month <= 2 ? int256(1) : int256(0));
        return string.concat(vm.toString(uint256(year)), "-", _two(uint256(month)), "-", _two(uint256(day)));
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}

contract SafeBatchBeta is SafeBatch, BetaEntry {}

contract SafeBatchFull is SafeBatch, FullEntry {}
