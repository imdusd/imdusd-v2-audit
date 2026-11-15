// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {RLPReader} from "../../src/vendor/optimism/RLPReader.sol";

/// @notice FORK TESTS ONLY (keeper e2e on anvil). A forked anvil cannot produce a proof that verifies against its own block
/// headers (its state root covers only the state it has touched), so the keeper's fork suite swaps ProvenPoolPrice's code
/// for this one (anvil_setCode). SAME ABI, constructor and storage layout as src/feeds/ProvenPoolPrice.sol; `prove` still
/// requires the header to hash to `blockhash` and to be newer, but reads slot0 LIVE instead of verifying the trie proofs (it
/// ignores them). The real verification is tested on real mainnet proofs (test/unit/ProvenPoolPrice.t.sol, the fork test
/// test_W2_provenReferenceIgnoresThePushBetweenUnlocks).
contract ProvenPoolPriceForkStandIn {
    using StateLibrary for IPoolManager;

    address public immutable manager;
    PoolId public immutable poolId;
    bool public immutable baseIsToken0;
    uint256 public immutable maxAge;
    bytes32 internal immutable slot0Key;

    uint256 internal _value;
    uint64 public provenBlock;
    uint64 internal _provenAt;

    error BadHeader();

    event Proven(uint256 indexed blockNumber, uint160 sqrtPriceX96, uint256 value);

    constructor(address manager_, bytes32 poolId_, bool baseIsToken0_, uint256 maxAge_) {
        (manager, poolId, baseIsToken0, maxAge) = (manager_, PoolId.wrap(poolId_), baseIsToken0_, maxAge_);
        slot0Key = StateLibrary._getPoolStateSlot(PoolId.wrap(poolId_));
    }

    function latestValue() external view returns (uint256, uint64) {
        return (_value, _provenAt);
    }

    function isStale() external view returns (bool) {
        return _provenAt == 0 || block.timestamp > uint256(_provenAt) + maxAge;
    }

    function proven() external pure returns (bool) {
        return true;
    }

    function prove(bytes calldata header, bytes[] calldata, bytes[] calldata) external returns (uint256 value) {
        bytes memory h = header;
        RLPReader.RLPItem[] memory fields = RLPReader.readList(h);
        uint256 number = _toUint(RLPReader.readBytes(fields[8]));
        bytes32 bh = blockhash(number);
        if (bh == bytes32(0) || bh != keccak256(h)) revert BadHeader();
        if (number <= provenBlock) return _value; // as the real feed (audit wave 3): a same or older block is a no-op
        (uint160 sqrtP,,,) = IPoolManager(manager).getSlot0(poolId);
        uint256 q = Math.mulDiv(sqrtP, sqrtP, 1 << 64);
        value = baseIsToken0 ? Math.mulDiv(q, 1e18, 1 << 128) : Math.mulDiv(1e18, 1 << 128, q);
        _value = value;
        provenBlock = uint64(number);
        _provenAt = uint64(_toUint(RLPReader.readBytes(fields[11])));
        emit Proven(number, sqrtP, value);
    }

    function _toUint(bytes memory b) internal pure returns (uint256 v) {
        for (uint256 i; i < b.length; ++i) v = (v << 8) | uint8(b[i]);
    }
}
