// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MainnetConfig, RobinhoodConfig} from "../DeployConfig.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address);
}

interface ISafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function addOwnerWithThreshold(address owner, uint256 threshold) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
}

/// @notice The 4663 governance Safe at THE SAME ADDRESS as the mainnet Safe. SIMULATION ONLY: this script
/// broadcasts nothing; it proves the two transactions below on the chain the RPC serves and prints them for the signers.
///
///   forge script script/launch/Safe4663.s.sol:Safe4663 --rpc-url <4663 rpc>        (launch.sh safe4663)
///
/// How the mainnet Safe 0xbeFd…9C32 was made (tx 0xed5f26b8…8bb7, block 26,156,778, sent by 0x5167…3281): SafeProxyFactory
/// 1.5.0 `createProxyWithNonce(Safe 1.5.0 singleton, initializer, saltNonce 0)`, initializer = `setup(owners [0x5167…3281,
/// 0xa0Bf…0B42], threshold 2, to SafeToL2Setup, data setupToL2(SafeL2 1.5.0), fallback handler 0x3EfC…77f4, no payment,
/// paymentReceiver 0x5afe7A11E7…)`. The third owner 0xd4C4…CCC1 was added later by the Safe itself (tx 0x3916251a…221a,
/// AddedOwner, threshold kept at 2). The proxy address depends only on the factory, the singleton (in the proxy's creation
/// code), keccak(initializer) and the salt nonce: NOT on the sender or the chain. All four contracts exist on 4663 with the
/// same code (keccak checked below), so on 4663:
///   tx 1 (anyone, needs 4663 ETH for gas): the SAME createProxyWithNonce call -> 0xbeFd…9C32 with owners 0x5167 + 0xa0Bf, 2-of-2.
///        On 4663 (chain id != 1) SafeToL2Setup points the proxy at SafeL2 1.5.0 (event-emitting; same storage and owners).
///        Anyone may send it first: the result is the same Safe with the same owners (a front-run only pays our gas).
///   tx 2 (the Safe, signed by 0x5167 AND 0xa0Bf, Safe nonce 0): addOwnerWithThreshold(0xd4C4…CCC1, 2) -> the mainnet Safe's
///        exact owners, in the same order, 2-of-3.
/// After tx 2: put nothing else in it before the launch (the nonce the launch files assume is whatever is current; the files
/// are Transaction Builder batches, not pre-signed).
contract Safe4663 is Script {
    address internal constant FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b; // SafeProxyFactory 1.5.0
    address internal constant SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b; // Safe 1.5.0
    address internal constant SINGLETON_L2 = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e; // SafeL2 1.5.0
    address internal constant TO_L2_SETUP = 0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a; // SafeToL2Setup
    address internal constant FALLBACK = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4; // ExtensibleFallbackHandler 1.5.0
    address internal constant PAYMENT_RECEIVER = 0x5afe7A11E7000000000000000000000000000000;
    address internal constant OWNER_A = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    address internal constant OWNER_B = 0xa0Bf5b240634918c70d4ec9384DbD0111Ef40B42;
    address internal constant OWNER_C = 0xd4C41b75c80B32312000C6b8b4eC05ffAf8aCCC1; // added after creation on mainnet
    /// @dev keccak256 of the mainnet creation tx's initializer (read 2026-11-15): the rebuilt one must equal it.
    bytes32 internal constant INITIALIZER_HASH = 0x7840273fa99cca7dc25d27ecdabc0c14290af4fe46922c54e54f957677d18545;
    /// @dev Runtime code keccak of each contract on mainnet (read 2026-11-15; identical on 4663 that day).
    bytes32 internal constant FACTORY_CODE = 0x967dae4cda22b0c9ef7f31b010bdc1ceb0af9904b0c3dc060b5302e4c18a4529;
    bytes32 internal constant SINGLETON_CODE = 0xdda019cbd7c867a533a2a86e5c53434fdc50b13122b5a5ddb4a8df61b31c20f2;
    bytes32 internal constant SINGLETON_L2_CODE = 0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc;
    bytes32 internal constant TO_L2_SETUP_CODE = 0xf6034d841bcbff8912aa55526b0f1609212536aaf60bb16f5e8a269a4ab38f18;
    bytes32 internal constant FALLBACK_CODE = 0x3c6a85bcf7b563daa624b884b4e9a1b9fa5371edde7be945d998071a48f28bbc;

    function initializer() public pure returns (bytes memory) {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (OWNER_A, OWNER_B);
        return abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            uint256(2),
            TO_L2_SETUP,
            abi.encodeWithSignature("setupToL2(address)", SINGLETON_L2),
            FALLBACK,
            address(0),
            uint256(0),
            PAYMENT_RECEIVER
        );
    }

    function createCall() public pure returns (bytes memory) {
        return abi.encodeCall(ISafeProxyFactory.createProxyWithNonce, (SINGLETON, initializer(), 0));
    }

    function addOwnerCall() public pure returns (bytes memory) {
        return abi.encodeCall(ISafe.addOwnerWithThreshold, (OWNER_C, 2));
    }

    function run() external {
        require(block.chainid == RobinhoodConfig.CHAIN_ID, "Safe4663: not chain 4663");
        address safe = MainnetConfig.GOVERNANCE_SAFE;
        require(RobinhoodConfig.GOVERNANCE_SAFE == safe, "Safe4663: RobinhoodConfig.GOVERNANCE_SAFE is not the mainnet Safe's address");
        require(keccak256(initializer()) == INITIALIZER_HASH, "Safe4663: the rebuilt initializer differs from mainnet's");
        _codeIs(FACTORY, FACTORY_CODE, "SafeProxyFactory 1.5.0");
        _codeIs(SINGLETON, SINGLETON_CODE, "Safe 1.5.0");
        _codeIs(SINGLETON_L2, SINGLETON_L2_CODE, "SafeL2 1.5.0");
        _codeIs(TO_L2_SETUP, TO_L2_SETUP_CODE, "SafeToL2Setup");
        _codeIs(FALLBACK, FALLBACK_CODE, "fallback handler");

        if (safe.code.length != 0) {
            console2.log("SAFE4663: a contract already exists at", safe);
            _report(safe, false);
            return;
        }
        // tx 1, simulated (not broadcast)
        address got = ISafeProxyFactory(FACTORY).createProxyWithNonce(SINGLETON, initializer(), 0);
        require(got == safe, "Safe4663: the factory would create another address");
        require(_singleton(safe) == SINGLETON_L2, "Safe4663: SafeToL2Setup did not switch to SafeL2");
        address[] memory o = ISafe(safe).getOwners();
        require(o.length == 2 && o[0] == OWNER_A && o[1] == OWNER_B && ISafe(safe).getThreshold() == 2, "Safe4663: owners after tx 1");
        console2.log("SAFE4663 tx 1 (send from any funded account on 4663; simulated: creates", safe, "):");
        console2.log("  to   ", FACTORY);
        console2.log("  value 0");
        console2.log(string.concat("  data  ", vm.toString(createCall())));
        _report(safe, true);
    }

    /// @dev tx 2 from the Safe's current state: the hash both owners sign, then the simulated effect.
    function _report(address safe, bool fresh) internal {
        address[] memory o = ISafe(safe).getOwners();
        bool has3 = o.length == 3;
        if (has3) {
            require(o[0] == OWNER_C && o[1] == OWNER_A && o[2] == OWNER_B && ISafe(safe).getThreshold() == 2, "Safe4663: owners differ from mainnet");
            console2.log("SAFE4663: owners and threshold already equal the mainnet Safe's (2 of 3). Nothing to do.");
            return;
        }
        require(o.length == 2 && o[0] == OWNER_A && o[1] == OWNER_B && ISafe(safe).getThreshold() == 2, "Safe4663: unexpected owners");
        uint256 n = ISafe(safe).nonce();
        bytes32 h = ISafe(safe).getTransactionHash(safe, 0, addOwnerCall(), 0, 0, 0, 0, address(0), address(0), n);
        console2.log("SAFE4663 tx 2 (the Safe, signed by 0x5167...3281 AND 0xa0Bf...0B42):");
        console2.log("  to     ", safe);
        console2.log("  value 0, operation 0 (call), safeTxGas 0, baseGas 0, gasPrice 0, gasToken 0, refundReceiver 0");
        console2.log(string.concat("  data    ", vm.toString(addOwnerCall()), "   (addOwnerWithThreshold(0xd4C4...CCC1, 2))"));
        console2.log("  nonce  ", n);
        console2.log(string.concat("  safeTxHash ", vm.toString(h)));
        vm.prank(safe);
        ISafe(safe).addOwnerWithThreshold(OWNER_C, 2);
        o = ISafe(safe).getOwners();
        require(o.length == 3 && o[0] == OWNER_C && o[1] == OWNER_A && o[2] == OWNER_B && ISafe(safe).getThreshold() == 2, "Safe4663: owners after tx 2");
        console2.log(fresh ? "SAFE4663 simulated: tx 1 + tx 2 give" : "SAFE4663 simulated: tx 2 gives", safe);
        console2.log("  owners [0xd4C4...CCC1, 0x5167...3281, 0xa0Bf...0B42], threshold 2 = the mainnet Safe's, same order");
    }

    function _singleton(address safe) internal view returns (address) {
        return address(uint160(uint256(vm.load(safe, bytes32(0)))));
    }

    function _codeIs(address a, bytes32 want, string memory what) internal view {
        require(keccak256(a.code) == want, string.concat("Safe4663: ", what, " is not the mainnet code"));
    }
}
