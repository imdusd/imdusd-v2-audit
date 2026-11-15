// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {Parameters} from "../../src/Parameters.sol";
import {ParametersRules} from "../../src/ParametersRules.sol";
import {LedgerSettlement} from "../../src/LedgerSettlement.sol";
import {SortedPositions} from "../../src/SortedPositions.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {Ledger, IPulse} from "../../src/Ledger.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Migrator} from "../../src/Migrator.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 1, the core: (Pulse where the chain needs one,) ImdUSD, Parameters, Pricer, Treasury, Ledger (+ its
/// SortedPositions), Redeemer, Liquidator, Migrator and the four wire calls, in test/utils/System.sol's order.
abstract contract StageCore is DeployBase {
    function _stageCore(DeployTypes.Config memory cfg, Deployed memory d, address me) internal {
        if (cfg.chain.chainId != 0 && block.chainid != cfg.chain.chainId) revert WrongChain(cfg.chain.chainId, block.chainid);
        uint256 g;
        // 0. The sequencer-outage grace, where the chain needs one: the Ledger pokes it on every accrual.
        if (cfg.chain.pulse && !_has(address(d.pulse))) {
            g = gasleft();
            d.pulse = _newPulse(cfg.chain.pulseGap, cfg.chain.pulseGrace);
            _rec("Pulse", g, type(Pulse).creationCode.length + 64);
        }
        // 1. Core, in System.sol order.
        if (!(_has(address(d.usd)) && _ok(d.usd.wirer() == me && d.usd.flashCap() == cfg.flashCap, "ImdUSD"))) {
            g = gasleft();
            d.usd = new ImdUSD(me, cfg.flashCap);
            _rec("ImdUSD", g, type(ImdUSD).creationCode.length + 64);
        }
        if (
            !(_has(address(d.params)) && _ok(d.params.wirer() == me && d.params.governor() == cfg.governor
                    && _rulesAre(d.params.rules(), cfg.governor), "Parameters"))
        ) {
            // The rules module first, by the deployer (audit wave 3): Parameters takes its address. A fresh one for every new
            // Parameters, so a resume never has to adopt a module nothing points at yet.
            g = gasleft();
            ParametersRules rules_ = new ParametersRules(cfg.governor);
            _rec("ParametersRules", g, type(ParametersRules).creationCode.length + 32);
            g = gasleft();
            d.params = new Parameters(cfg.governor, me, rules_);
            _rec("Parameters", g, type(Parameters).creationCode.length + 96);
        }
        if (!(_has(address(d.pricer)) && _ok(d.pricer.params() == d.params, "Pricer"))) {
            g = gasleft();
            d.pricer = new Pricer(d.params);
            _rec("Pricer", g, type(Pricer).creationCode.length + 32);
        }
        if (
            !(_has(address(d.treasury)) && _ok(d.treasury.wirer() == me && d.treasury.governor() == cfg.governor
                    && address(d.treasury.token()) == address(d.usd),
                "Treasury"))
        ) {
            g = gasleft();
            d.treasury = new Treasury(cfg.governor, IERC20(address(d.usd)), me);
            _rec("Treasury", g, type(Treasury).creationCode.length + 96);
        }
        if (
            !(_has(address(d.ledger)) && _ok(d.ledger.token() == d.usd && d.ledger.params() == d.params && d.ledger.pricer() == d.pricer
                    && d.ledger.treasury() == address(d.treasury) && d.ledger.wirer() == me
                    && address(d.ledger.pulse()) == address(d.pulse) && _settlementIs(d.ledger),
                "Ledger"))
        ) {
            g = gasleft();
            PositionNFT nft_ = new PositionNFT(me); // first, so the Ledger's creation code stays under EIP-3860
            _rec("PositionNFT", g, type(PositionNFT).creationCode.length + 32);
            // The settlement module next, by the deployer, for the Ledger this deployer creates right after it and that
            // Ledger's SortedPositions (its first creation) (audit wave 3); the Ledger checks the rest of its immutables.
            address next = vm.computeCreateAddress(me, vm.getNonce(me) + 1);
            g = gasleft();
            LedgerSettlement s_ = new LedgerSettlement(
                d.usd, d.params, d.pricer, address(d.treasury), me, IPulse(address(d.pulse)),
                SortedPositions(vm.computeCreateAddress(next, 1)), nft_, next
            );
            _rec("LedgerSettlement", g, type(LedgerSettlement).creationCode.length + 288);
            g = gasleft();
            d.ledger = new Ledger(d.usd, d.params, d.pricer, address(d.treasury), me, IPulse(address(d.pulse)), nft_, s_);
            _rec("Ledger (+SortedPositions)", g, type(Ledger).creationCode.length + 256);
            require(address(d.ledger) == next && _settlementIs(d.ledger), "Ledger: not at the settlement module's address");
        }
        if (d.ledger.nft().ledger() == address(0)) {
            g = gasleft();
            d.ledger.nft().bind(address(d.ledger));
            _rec("positionNFT.bind", g, CALL_DATA); // in the gas log like every other broadcast (audit wave 1)
        }
        if (!(_has(address(d.redeemer)) && _ok(d.redeemer.ledger() == d.ledger, "Redeemer"))) {
            g = gasleft();
            d.redeemer = new Redeemer(d.ledger);
            _rec("Redeemer", g, type(Redeemer).creationCode.length + 32);
        }
        if (!(_has(address(d.liquidator)) && _ok(d.liquidator.ledger() == d.ledger && d.liquidator.pricer() == d.pricer, "Liquidator")))
        {
            g = gasleft();
            d.liquidator = new Liquidator(d.ledger, d.pricer);
            _rec("Liquidator", g, type(Liquidator).creationCode.length + 64);
        }
        if (d.ledger.redeemer() == address(0)) {
            g = gasleft();
            d.ledger.wire(address(d.redeemer), address(d.liquidator));
            _rec("ledger.wire", g, CALL_DATA);
        } else if (d.ledger.redeemer() != address(d.redeemer) || d.ledger.liquidator() != address(d.liquidator)) {
            revert Mismatch("Ledger wired to another Redeemer/Liquidator");
        }
        if (
            !(_has(address(d.migrator)) && _ok(address(d.migrator.v1()) == cfg.v1 && d.migrator.v2() == d.usd && d.migrator.params() == d.params,
                "Migrator"))
        ) {
            g = gasleft();
            d.migrator = new Migrator(IERC20(cfg.v1), d.usd, d.params);
            _rec("Migrator", g, type(Migrator).creationCode.length + 96);
        }
        if (d.usd.ledger() == address(0)) {
            g = gasleft();
            d.usd.wire(address(d.ledger), address(d.migrator), address(d.params));
            _rec("usd.wire", g, CALL_DATA);
        } else if (
            d.usd.ledger() != address(d.ledger) || d.usd.migrator() != address(d.migrator)
                || d.usd.bridgeSetter() != address(d.params)
        ) {
            revert Mismatch("ImdUSD wired to other contracts");
        }
        if (d.params.ledger() == address(0)) {
            g = gasleft();
            d.params.wire(address(d.ledger), address(d.usd));
            _rec("params.wire", g, CALL_DATA);
        } else if (d.params.ledger() != address(d.ledger) || d.params.token() != address(d.usd)) {
            revert Mismatch("Parameters wired to other contracts");
        }
        if (address(d.treasury.ledger()) == address(0)) {
            g = gasleft();
            d.treasury.wire(ICoverable(address(d.ledger)));
            _rec("treasury.wire", g, CALL_DATA);
        } else if (address(d.treasury.ledger()) != address(d.ledger)) {
            revert Mismatch("Treasury wired to another Ledger");
        }
    }

    /// @dev A Parameters' rules module is this build's ParametersRules serving `governor` (code: LaunchBase._checkRecordedCode).
    function _rulesAre(ParametersRules r, address governor) internal view returns (bool) {
        return _has(address(r)) && r.governor() == governor;
    }

    /// @dev A Ledger's settlement module carries that Ledger's immutables, including the two its address fixes.
    function _settlementIs(Ledger l) internal view returns (bool) {
        LedgerSettlement m = LedgerSettlement(l.settlement());
        return _has(address(m)) && m.ledger() == address(l) && m.sorted() == l.sorted() && m.token() == l.token()
            && m.params() == l.params() && m.pricer() == l.pricer() && m.treasury() == l.treasury() && m.wirer() == l.wirer()
            && m.pulse() == l.pulse() && m.nft() == l.nft();
    }
}
