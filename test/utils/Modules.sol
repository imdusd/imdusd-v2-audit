// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersRules} from "src/ParametersRules.sol";
import {Pricer} from "src/Pricer.sol";
import {Ledger} from "src/Ledger.sol";
import {LedgerSettlement} from "src/LedgerSettlement.sol";
import {IPulse} from "src/LedgerBase.sol";
import {SortedPositions} from "src/SortedPositions.sol";
import {PositionNFT} from "src/PositionNFT.sol";

/// @dev Tests build Parameters and Ledger as the deploy script does (audit wave 3): each module first, by the same deployer.
/// Internal library functions run in the caller's context, so the caller is the creator of both contracts.
library Modules {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function newParameters(address governor, address wirer) internal returns (Parameters) {
        return new Parameters(governor, wirer, new ParametersRules(governor));
    }

    /// @dev The settlement is made for the Ledger's address (the creator's next nonce after it) and its SortedPositions
    /// (the Ledger's first creation).
    function newLedger(
        ImdUSD token,
        Parameters params,
        Pricer pricer,
        address treasury,
        address wirer,
        IPulse pulse,
        PositionNFT nft
    ) internal returns (Ledger l) {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        LedgerSettlement s = new LedgerSettlement(
            token, params, pricer, treasury, wirer, pulse, SortedPositions(vm.computeCreateAddress(next, 1)), nft, next
        );
        l = new Ledger(token, params, pricer, treasury, wirer, pulse, nft, s);
        require(address(l) == next && address(l.sorted()) == address(s.sorted()), "Modules: predicted Ledger address");
    }
}
