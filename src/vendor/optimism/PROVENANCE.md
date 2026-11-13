# Vendored from ethereum-optimism/optimism

Tag `op-contracts/v9.0.0`, path `packages/contracts-bedrock/src/libraries/`, MIT. These are the libraries OptimismPortal
uses to verify withdrawal storage proofs on L1.

| File | Upstream path | sha256 upstream |
|---|---|---|
| RLPReader.sol | rlp/RLPReader.sol | 12384103fca56202... |
| RLPErrors.sol | rlp/RLPErrors.sol | c775036bad8a0e00... |
| MerkleTrie.sol | trie/MerkleTrie.sol | 9ce13ec201485c87... |
| SecureMerkleTrie.sol | trie/SecureMerkleTrie.sol | 755f79cb43e84d30... |
| Bytes.sol | Bytes.sol | 235a1dcaf00fb7ee... |

The only change: `import ... from "src/libraries/..."` rewritten to relative paths (`./X.sol`). Code otherwise byte-identical.
Used only by `src/feeds/ProvenPoolPrice.sol`.
