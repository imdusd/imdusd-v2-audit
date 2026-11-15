// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IFeed} from "../interfaces/IFeed.sol";
import {RLPReader} from "../vendor/optimism/RLPReader.sol";
import {SecureMerkleTrie} from "../vendor/optimism/SecureMerkleTrie.sol";

/// @title ProvenPoolPrice
/// @notice A Uniswap v4 pool's price AS IT STOOD AT THE END OF A RECENT BLOCK, proven from Ethereum's state: the block's
/// header (checked against `blockhash`), the PoolManager's account proof against the header's state root, and the storage
/// proof of the pool's `slot0` against the account's storage root. Same unit as `LivePoolPrice`: quote raw units per 1e18
/// raw units of `base`, 1e18-scaled.
/// @dev WHY (audit wave 1, finding 3-oracles-depth; wave 2, 2-prices Q5). The depth samplers measure a band around a
/// reference price; read live (LivePoolPrice), a push of the pool, a sample and a push back in ONE transaction or bundle
/// moved the reference and deflated the reading for the pool fee both ways. A price proven at the end of an earlier block
/// cannot be moved inside the sampling transaction: distorting it needs the pool pushed at a block's end and held there into
/// the next one, open to every arbitrageur (or one party building two consecutive blocks). An "arm in one block, sample in
/// the next" reference does not achieve this: the attacker arms inside a push and pushes again in the next block.
/// TRUST: none beyond Ethereum's own commitments. The trie code is OptimismPortal's (src/vendor/optimism, PROVENANCE.md).
/// Every proof node must hash up to the header's state root and the header to `blockhash`, and the keys are hashes this
/// contract computes (the PoolManager's address and the pool's slot), so a proof cannot name another account or slot.
/// LIMITS: `blockhash` reaches 256 blocks back; a proven value is fresh for `maxAge` seconds from its block's timestamp and
/// only a newer block replaces it. A future change of Ethereum's state trie (binary/Verkle) ends these proofs: the depth
/// sampler then reads stale (zero depth, fail closed) until the Safe swaps the samplers (REMOVE/ADD_DEPTH_SAMPLER).
/// The sampler keeps its own check that the live pool is within `maxDeviationTicks` of this reference.
contract ProvenPoolPrice is IFeed {
    /// @dev Header fields (Ethereum block header RLP list): 3 stateRoot, 8 number, 11 timestamp.
    uint256 internal constant H_STATE_ROOT = 3;
    uint256 internal constant H_NUMBER = 8;
    uint256 internal constant H_TIMESTAMP = 11;
    /// @dev Account RLP list: [nonce, balance, storageRoot, codeHash].
    uint256 internal constant A_STORAGE_ROOT = 2;

    address public immutable manager;
    PoolId public immutable poolId;
    /// @notice True when the priced token is the pool's currency0 (then price = sqrtP^2 / 2^192).
    bool public immutable baseIsToken0;
    /// @notice Seconds a proven value stays fresh, counted from its block's timestamp.
    uint256 public immutable maxAge;
    /// @dev The storage key of `pools[poolId].slot0` in the PoolManager (v4 StateLibrary).
    bytes32 internal immutable slot0Key;

    uint256 internal _value;
    /// @notice The block whose end-of-block price is held (0 before the first proof).
    uint64 public provenBlock;
    uint64 internal _provenAt;

    error InvalidConfig();
    error BadHeader();
    error BadAccount();
    error EmptySlot();

    event Proven(uint256 indexed blockNumber, uint160 sqrtPriceX96, uint256 value);

    constructor(address manager_, bytes32 poolId_, bool baseIsToken0_, uint256 maxAge_) {
        if (manager_.code.length == 0 || maxAge_ == 0) revert InvalidConfig();
        manager = manager_;
        poolId = PoolId.wrap(poolId_);
        baseIsToken0 = baseIsToken0_;
        maxAge = maxAge_;
        slot0Key = StateLibrary._getPoolStateSlot(PoolId.wrap(poolId_));
    }

    // ---------------------------------------------------------------- IFeed

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        return (_value, _provenAt);
    }

    /// @notice Stale before the first proof and once the proven block is older than `maxAge`.
    function isStale() external view returns (bool) {
        return _provenAt == 0 || block.timestamp > uint256(_provenAt) + maxAge;
    }

    /// @notice The price is proven from Ethereum state, no attester in its path (FeedTraits.proven; the Pricer's twin rule).
    function proven() external pure returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------- prove

    /// @notice Prove the pool's price at the end of the block `header` describes. Anyone; the block must be one of the last
    /// 256. The keeper calls this right before `DepthSampler.sample()` in the same bundle.
    /// A block no newer than the one held is a NO-OP that returns the held value (audit wave 3, info: it reverted `NotNewer`,
    /// so anyone proving the same block first made the keeper's atomic [prove, sample] bundle lose its hour). Nothing is
    /// written and the proof is not read: the held block is the same or newer, so the price can never move backwards.
    function prove(bytes calldata header, bytes[] calldata accountProof, bytes[] calldata storageProof)
        external
        returns (uint256 value)
    {
        bytes memory h = header;
        RLPReader.RLPItem[] memory fields = RLPReader.readList(h);
        if (fields.length <= H_TIMESTAMP) revert BadHeader();
        uint256 number = _toUint(RLPReader.readBytes(fields[H_NUMBER]));
        // blockhash is 0 for the current block and for blocks more than 256 back: either fails here.
        bytes32 bh = blockhash(number);
        if (bh == bytes32(0) || bh != keccak256(h)) revert BadHeader();
        if (number <= provenBlock) return _value;
        bytes32 stateRoot = _toBytes32(RLPReader.readBytes(fields[H_STATE_ROOT]));
        uint256 timestamp = _toUint(RLPReader.readBytes(fields[H_TIMESTAMP]));

        RLPReader.RLPItem[] memory account =
            RLPReader.readList(SecureMerkleTrie.get(abi.encodePacked(manager), _mem(accountProof), stateRoot));
        if (account.length != 4) revert BadAccount();
        bytes32 storageRoot = _toBytes32(RLPReader.readBytes(account[A_STORAGE_ROOT]));

        // The trie holds the slot's word RLP-encoded with leading zeros stripped; an empty slot has no leaf (get reverts).
        uint256 word = _toUint(
            RLPReader.readBytes(SecureMerkleTrie.get(abi.encodePacked(slot0Key), _mem(storageProof), storageRoot))
        );
        uint160 sqrtP = uint160(word); // slot0 packs sqrtPriceX96 in its low 160 bits
        value = _price(sqrtP);
        if (value == 0) revert EmptySlot();

        _value = value;
        provenBlock = uint64(number);
        _provenAt = uint64(timestamp);
        emit Proven(number, sqrtP, value);
    }

    // ---------------------------------------------------------------- internals

    /// @dev LivePoolPrice's formula: q = sqrtP^2 / 2^64; token0 base: q * 1e18 / 2^128, token1 base: 1e18 * 2^128 / q.
    function _price(uint160 sqrtP) internal view returns (uint256) {
        if (sqrtP == 0) return 0;
        uint256 q = Math.mulDiv(sqrtP, sqrtP, 1 << 64);
        if (q == 0) return 0;
        if (baseIsToken0) return Math.mulDiv(q, 1e18, 1 << 128);
        return Math.mulDiv(1e18, 1 << 128, q);
    }

    function _toUint(bytes memory b) internal pure returns (uint256 v) {
        if (b.length > 32) revert BadHeader();
        for (uint256 i; i < b.length; ++i) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    function _toBytes32(bytes memory b) internal pure returns (bytes32 v) {
        if (b.length != 32) revert BadHeader();
        assembly ("memory-safe") {
            v := mload(add(b, 32))
        }
    }

    function _mem(bytes[] calldata a) internal pure returns (bytes[] memory m) {
        m = new bytes[](a.length);
        for (uint256 i; i < a.length; ++i) {
            m[i] = a[i];
        }
    }
}
