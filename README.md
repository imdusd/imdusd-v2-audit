# imdUSD v2: audit snapshot

imdUSD v2 is a modular, over-collateralised CDP stablecoin. One multi-collateral `Ledger` keeps every position. Each
borrower sets their own interest rate, and imdUSD is redeemable against the lowest-rate positions first, in the style of
Liquity v2, with a per-type decaying redemption fee. Collateral is priced by `Pricer` from two legs per type: Chainlink
aggregators (ETH, wstETH, cbBTC/WBTC, stablecoins, ERC-4626 share rates) or swarm-attested feeds (EIP-712 attestations
signed by the IdentityMD oracle network, for IMD/sIMD, the network-health index NHI and NFT seat prices).

What this core adds over a plain CDP:

- **Positions are ERC-721 ids.** `PositionNFT` holds ownership; the position's whole state lives in the `Ledger` under
  its id, so a transfer carries debt, rate, cooldown and premium rate. Ids are counterfactual (`positionId(owner, ilk,
  salt)`), an owner may hold any number per type, and operators hold separate rights (ADD, REPAY, SET_RATE,
  WITHDRAW/BORROW to the owner, WITHDRAW_ANY/BORROW_ANY to any address), granted per position or for all of an owner's
  positions and dropped on transfer. EIP-712 `permitOperator`, `openFor` and `borrowFor` (ERC-1271 accepted) let a key
  with no gas own and borrow; `bumpNonce(n)` cancels a whole pre-signed queue.
- **Size splits.** `Ledger` runs redemption, liquidation and write-off in `LedgerSettlement` by `delegatecall` on its own
  storage (shared layout in `LedgerBase`); `Parameters` runs per-kind validation and application in `ParametersRules` by
  `delegatecall` (shared layout in `ParametersBase`). Both splits keep the contracts under EIP-170/EIP-3860. Each module
  is deployed on its own before its parent, which takes its address and refuses a module that does not serve it.
- **Versioned liquidation risk.** A type's `mat` and `chop` are kept per version. A position stays on the version it last
  took risk under until a newer version reaches its `bindAt`: a change that only lowers mat and chop binds at once, any
  other change binds `RISK_GRACE` (7 days) later. NHI-linked types keep a live `mat` and version only `chop`.
- **One pending proposal per kind** (`GovernedByKind`, used by `Parameters` and `Allocator`): every raise waits 48 hours
  and expires 14 days after its ETA; a proposal locks the kinds it would change; instant lowerings cancel pending
  proposals touching the same field.
- **Backstop sleeves.** Two `Backstop` instances per chain: `blue` (ETH, wstETH, BTC, staked stables) and `edge` (sIMD,
  later edge types). A sleeve is a STANDING BID: when a covered position is liquidated and the sleeve has room for the
  whole debt, it buys the collateral in the liquidation's own transaction at the liquidation price plus the penalty;
  its depositors keep the penalty less the Treasury's cut and the marker's chip. Seats are an auction type: no sleeve
  bids on them, they sell by Dutch auction. The edge sleeve also takes FIRST LOSS on edge types' bad debt before the Treasury, earns a premium (a share
  of edge interest, streamed over 7 days), and bounds the summed edge debt (`edgeCapacity` = max(3 x net vested imdUSD,
  a 60-day bootstrap allowance)). Deposits wait a day bucket, withdrawals queue 7 days and must be claimed within 2.
  `PricerOracle` gives the sleeves their prices from the Pricer's quotes.
- **Partial liquidation to a target.** A fungible type with a target buffer repays only what restores `mat + buffer`.
- **Allocator.** The only way protocol funds move, modelled on Spark's ALM controller: no recipient argument anywhere,
  allowlisted targets, a refilling rate limit per (action, target), slippage bounds from two feeds, and a freezer (the
  Safe) that can stop it. Its four discretionary jobs are RULE-DRIVEN: anyone may call them and the contract picks amount,
  price and route. Seized collateral sells by a descending auction per (sleeve, token) (103% of the sleeve's highest
  price, `max(low, high, redemption payout)`, falling to 98% of `low` over 2 hours, paid in imdUSD straight to the sleeve
  through `Backstop.sell` and never under its floor; collateral that arrives later, once it passes 5% of the sleeve's
  holding, stops the price until anyone restarts the run, which offers all of it from the top; smaller arrivals sell at
  the run's price, never under the floor);
  `rebalanceVault` keeps a Safe-set amount of an asset liquid and deposits the rest in its one approved vault;
  `topUpBuffer` fills the peg buffer to its target; `rebalanceLp` moves protocol-owned `PegLPVault` shares toward a target
  behind a spot-versus-TWAP gate (no target set means no rule). A keeper role still exists for manual actions; the beta
  adds none. At genesis nothing is allowlisted: every Allocator action, collateral sales included, waits until the Safe's
  48-hour setup applies (targets, buckets, auto vault, LP target).
- **PEG positions.** A position type whose collateral is `PegLPVault` shares (the protocol's imdUSD/USDC peg-pool LP
  vault on the `PegHook` pool). `PegPositionZap` takes a user's USDC, flash-mints imdUSD, deposits both in the vault's
  proportion, wraps the shares 1:1 as `PegCollateral` (only the zap can mint it) and borrows exactly the imdUSD placed:
  debt that is peg liquidity. `PegShareFeed` prices a share from the vault's own holdings (imdUSD at $1, USDC at
  min($1, Chainlink)); its spot instance reads 0 while the vault is one-sided, which stops new PEG debt.
- **Measured IMD depth.** The sIMD line obeys `line x (1 + chop) + redeemCap (+ other chains' IMD lines) <= k x depth`.
  `DepthSampler` measures each IMD exit pool's depth to -15% on chain from the pool's own liquidity, in hourly buckets;
  `ImdDepth` sums the samplers and keeps a robust 7-day low, min'd with a swarm-attested depth leg once configured. A
  posted figure is only a ceiling. The band's reference price is IMD/ETH pool 0xb07d's END-OF-BLOCK price, proven from
  Ethereum state (`ProvenPoolPrice`: the block header against `blockhash`, then the PoolManager's account proof and the
  pool's `slot0` storage proof, verified with Optimism's MerkleTrie/RLPReader, vendored in `src/vendor/optimism`), x
  Chainlink ETH/USD; a proven price lives 6 hours and anyone may prove a newer block.
- **Swarm legs follow, they do not reject (price design C).** A swarm-priced leaf accepts every valid attestation as a
  TARGET and moves its stored value toward it by at most the epoch's allowance (the cap, or 2x the cap for the one step
  that opens an epoch after a silence); the epoch anchors at the stored value. `attested()` is the last target and
  `converged()` says whether the stored value is it; composites (`ProductFeed`, `RateFeed`, `SeatFeed`, `SeatSpotLeg`)
  pass both traits through `FeedTraits`. The Pricer treats a leg that has not converged as not agreeing, so a clamped
  leg prices (and liquidates) but lends nothing. sIMD's SPOT leg is the proven pool price (`ProvenPoolPrice` x ETH/USD x
  the share rate), and for a type whose spot is proven the Pricer's liquidation price is `low = agree ? min(median,
  spot) : max(spot, min(median, attestedMedian))`, with `attestedMedian` the median leaf's last attested target (changed
  in wave 4: a median clamped above its target counts at its target): a wrong median cannot liquidate below the proven
  price, and a pushed proven price cannot lower `low` below what the median attested.
- **RateManager.** Optional, outside the core: owners grant it SET_RATE only; a manager key re-rates members within fixed
  bounds, each member's own floor and ceiling, and only outside their 7-day rate cooldown.

Also in place from the earlier core: a Uniswap v4 hook (`PegHook`) on the imdUSD/USDC pool that charges a toll on swaps
that push the price away from $1 and runs a capped peg keeper; `SavingsVault` (sImdUSD), which streams a governed share
of borrower interest to savers; identity.md NFT seats as auction-liquidated collateral through per-seat accounts;
`FeeNotes`; the v1 -> v2 `Migrator`.

All governance goes through `Parameters` (a 2-of-3 Safe as governor). **Launch on 12-07 (changed since the fourth
audit):** the Ethereum beta AND the full Robinhood Chain (chain 4663) core, with stock-token collateral (`src/stocks/`,
`MarketCalendar`, `MarketHoursFeed`), the sequencer grace (`Pulse`) and the LayerZero V2 bridge (`ImdBridge`) on both
chains. Value crosses the bridge only after the Safe's one-time `SET_BRIDGE` on each chain, which the Safe proposes only
once the re-check of this round's bridge findings comes back clean. Not part of the launch: a leveraged loop vault
(`LoopVault`), an AMM of two ERC-4626 tokens (`src/dex/`) and `RateManager`. `script/` holds the deploy scripts the tests
import, plus the four launch files listed under Audit scope (the rest of the launch tooling and the operator runbook are
not public).

## Build and test

Requires Foundry 1.9 (solc 0.8.26, `via_ir`, `bytecode_hash = "none"`). Dependencies are vendored under `lib/`; no
network is needed for the offline suites.

```bash
forge build                                                    # solc via_ir: a clean build takes a long time
forge test --no-match-path 'test/fork/*'                       # offline: unit + invariant suites (1,512 tests)
forge build --use solar && forge test --use solar --no-match-path 'test/fork/*'   # fast dev loop (see below)

# Fork suites: one file at a time, single-threaded (in parallel, set-up calls hit RPC rate limits)
MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/Deploy.t.sol --threads 1
MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/DeployBeta.t.sol --threads 1
ROBINHOOD_RPC_URL=<rpc> forge test --match-path test/fork/Robinhood.t.sol --threads 1
```

`--use solar` builds in seconds and is fine for iterating, but Solar has accepted syntax that solc rejects; confirm
anything you rely on with solc. Fork suites without their RPC variable skip. The Robinhood suites
(`Robinhood*.t.sol`) need `ROBINHOOD_RPC_URL`; every other fork file needs `MAINNET_RPC_URL` (an archive node for the
files that pin a block).

## Audit history

Every review of v2 so far, oldest first. The public audits are IdentityMD swarm panel audits bought on this repository:
each panel is four specialists (math, permissions, economics, control flow) and a judge who rules on their findings.
Counts below are the **judges'** findings (critical / high / medium / low / info); specialists' raw findings are more
and are folded into the judges'. None of these is a third-party audit firm.

| # | Date | Review | Code | Jobs | Judges' findings (C/H/M/L/I) | Fixes |
|---|---|---|---|---|---|---|
| 0 | 2026-10-30 | In-house adversarial review of the full v2 tree (eleven areas, with PoCs and economic models) | private tree `dd776c7` | in-house | 1 / 4 / 19 / 33 / ~60 | Resolved 2026-10-31 before the first snapshot: the critical, every high and most mediums fixed with regression tests that fail on `dd776c7` (37 fixed, 7 settled by decision, 16 left open with reasons). |
| 1 | 2026-11-10 | Public audit, wave 1: eight panels (ledger and liquidation, treasury and backstop, oracles and depth, governance, peg, seats, deploy, full system) | `2875ffb` | [`59d97f98`](https://explorer.imd.fun/jobs/59d97f98-3694-4e00-9c77-f2195bd39818) [`584aadc2`](https://explorer.imd.fun/jobs/584aadc2-a902-47dd-b639-e46a8223a277) [`bd0ce553`](https://explorer.imd.fun/jobs/bd0ce553-aab0-46da-be9b-00db8049dbd7) [`cd9184ac`](https://explorer.imd.fun/jobs/cd9184ac-e25e-4415-8605-194bf21e3501) [`561e7d5b`](https://explorer.imd.fun/jobs/561e7d5b-d64f-4233-9443-9761bd51546c) [`3d73817d`](https://explorer.imd.fun/jobs/3d73817d-9b86-45c4-b371-4e179fb3bb38) [`17e4edf1`](https://explorer.imd.fun/jobs/17e4edf1-6697-4353-9311-12eb9ca61aab) [`4384ebcc`](https://explorer.imd.fun/jobs/4384ebcc-37f4-4bc3-8e2b-fc48f01f0701) | 0 / 0 / 6 / 31 / 43 | In `5de80a6`; tests `AuditW1*`. 57 of the 58 Foundry proofs reproduced before fixing. |
| 2 | 2026-11-13 | Public audit, wave 2: three panels (money paths, prices, running the system), each re-checking the wave-1 fixes | `5de80a6` | [`5fcd4063`](https://explorer.imd.fun/jobs/5fcd4063-312b-4b6f-aa7b-e848428876a7) [`5a8d427d`](https://explorer.imd.fun/jobs/5a8d427d-7b2d-401b-b11d-86ecf5b96364) [`62b92eb1`](https://explorer.imd.fun/jobs/62b92eb1-7472-440c-ad76-2e55e66a1f65) | 0 / 1 / 3 / 8 / 5 | In `c64ecee`; tests `AuditW2*`. |
| 3 | 2026-11-14 | Public audit, wave 3: three panels re-checking the wave-2 fixes (Allocator, Backstop, imdUSD; SwarmFeed and seats; Parameters and depth); a gas review alongside | `c64ecee` | [`f3a96d58`](https://explorer.imd.fun/jobs/f3a96d58-3fc2-418b-b2e9-cd72c50fd656) [`ff9ebb9d`](https://explorer.imd.fun/jobs/ff9ebb9d-f675-492e-84e4-32cf85c0375a) [`b19b5e0c`](https://explorer.imd.fun/jobs/b19b5e0c-704e-4104-a012-f4a8bfc22b72) | 0 / 0 / 4 / 6 / 7 | In `67eadea`; tests `AuditW3*`, each with a property test that fails on `c64ecee`. |
| 4 | 2026-11-15 | Public audit, wave 4: price design C, the LayerZero bridge, Robinhood stock tokens | `67eadea` | [`0cb1541e`](https://explorer.imd.fun/jobs/0cb1541e-5d63-4866-815a-425703d326e1) [`34e546c2`](https://explorer.imd.fun/jobs/34e546c2-837d-46c9-8a21-0671ec934a8b) [`549dae1c`](https://explorer.imd.fun/jobs/549dae1c-abf5-4fad-9d13-d4571492dd9b) | price 0 / 0 / 2 / 4 / 0; bridge 0 / 2 / 1 / 9 / 2; stocks 0 / 2 / 2 / 4 / 1 | In this snapshot (the fifth commit); tests `AuditW4*`, each with a property test that fails on `67eadea`; the bridge then moved to holds with no guardian (`BridgeHold.t.sol`). |
| 4k | 2026-11-15 | Public audit of the v2 keeper (an off-chain process with no on-chain rights), in [imdusd/imdusd-v2-keeper-audit](https://github.com/imdusd/imdusd-v2-keeper-audit) | `e53d362` | [`ae48df88`](https://explorer.imd.fun/jobs/ae48df88-ca87-40e8-b8c2-5ed739b81de5) | 0 / 2 / 8 / 2 / 1 | Fixed, with the judge's proofs kept as regression tests; published as the keeper repository's second commit. |
| 5 | 2026-11 | Public audit, wave 5: the bridge and its Safe batches, Robinhood Chain core and stocks, a price re-check, the keeper | this snapshot | (to be listed) | | |

The "Known issues" and "What changed since" sections below list, wave by wave, what each audit found that we accept and
what each snapshot changed.

## Audit scope

nSLOC per area: Solidity source lines left after removing `//` and `/* */` comments and blank lines, counted per file
with a small script (the same rule as `cloc`'s code lines; pragma and import lines count). This rule gives slightly
higher figures than the previous snapshot's table (for example 1,049 against 1,014 for the same old core files), so
compare areas within this table, not across snapshots.

**Round 1: what the beta deploys (7,950 nSLOC, plus 349 vendored)**

The beta is `script/DeployBeta.s.sol`, which runs `script/Deploy.s.sol` with `BetaConfig` (`script/DeployConfig.sol`):
the full mainnet config with lower lines, a 300k chain-wide debt cap, seats on, and LoopVault and the DEX off. It
deploys every contract below.

| Area | Contracts | nSLOC |
|---|---|---|
| A. Core | `Ledger`, `LedgerBase`, `LedgerSettlement`, `PositionNFT`, `SortedPositions`, `Join`, `ImdUSD`, `Migrator`, `SavingsVault`, `TransientReentrancyGuard`, `IPositions` | 1,667 |
| B. Liquidation and redemption | `Liquidator`, `Redeemer`, `Pricer`, `Treasury` | 567 |
| C. Feeds | `ChainlinkFeed`, `ProductFeed`, `RateFeed`, `LivePoolPrice`, `SwarmFeed`, `SwarmFeeds`, `IFeed`, `IERC4626Min`, `ProvenPoolPrice`, `FeedTraits` | 812 |
| D. Peg | `PegHook`, `FeeNotes` | 596 |
| E. Governance | `Parameters`, `ParametersBase`, `ParametersRules`, `Governed`, `GovernedByKind` | 1,156 |
| F. Seats | `SeatAccount`, `SeatJoin`, `SeatFeed` | 871 |
| G. Peg LP vault and PEG positions | `PegLPVault`, `PegCollateral`, `PegShareFeed`, `PegPositionZap` | 599 |
| H. Backstop and Allocator | `Backstop`, `IBackstop`, `PricerOracle`, `Allocator` | 1,252 |
| I. Measured depth | `DepthSampler`, `ImdDepth` | 430 |
| Vendored (in scope as used) | `src/vendor/optimism`: `MerkleTrie`, `SecureMerkleTrie`, `RLPReader`, `RLPErrors`, `Bytes` (op-contracts/v9.0.0, imports made relative; PROVENANCE.md) | 349 |

**Round 2: Robinhood Chain and the bridge, launching on 12-07 with the beta (1,843 nSLOC)**

Audited early in wave 4 as "after the beta"; they now launch on 12-07. Robinhood Chain runs the SAME core contracts as
Round 1 (one `Ledger`, `Parameters`, `Pricer`, ... per chain) with its own configuration; the chain-specific pieces are
below. The Robinhood configuration, its deploy scripts and the bridge Safe batches are in scope for the first time.

| Area | Contracts | nSLOC |
|---|---|---|
| Bridge | `src/bridge/ImdBridge.sol` (LayerZero V2 burn and mint; imdUSD's bridge minter, `Parameters`' `SET_BRIDGE` and `ImdUSD.checkBridge`; per-path inbound delay: instant cap, claims, cancels, bulk-cancel cutoff, queue breaker, governable settings; Safe-only pause, hold, void, cancel and tighten, no guardian), `Pulse` (the sequencer grace on a chain with no uptime feed) | 735 |
| Stock tokens | `src/stocks/StockVault.sol`, `src/stocks/StockJoin.sol`, `src/feeds/MarketHoursFeed.sol`, `src/feeds/MarketCalendar.sol` | 351 |
| Robinhood configuration (new in scope) | `library RobinhoodConfig` in `script/DeployConfig.sol` (types, mats, lines incl. the IMD line 0 at genesis and its raise payload, feeds, chain line, Pulse gap/grace, bridge limits and inbound-delay launch values, DVNs, confirmations, enforced `lzReceive` gas) | 303 |
| Robinhood deploy (new in scope) | `script/DeployRobinhood.s.sol`, `script/DeployChain.s.sol`, `script/deploy/StageChain.sol` (Pulse, ImdBridge and the stock module as resumable deploy hooks) | 204 |
| Bridge Safe batches (new in scope) | `script/launch/BridgeBatch.s.sol` (each chain's path BATCH, and the separate, gated `SET_BRIDGE` file), `script/launch/Safe4663.s.sol` (re-creates the mainnet governance Safe at the same address on 4663, simulation only) | 250 |

Compile-only, OUT of scope: `script/launch/LaunchBase.sol` and `script/launch/SafeBatch.s.sol` (1,066 nSLOC), included
only because the bridge batches import them (the deployment record, the stage post-checks and the Safe Transaction
Builder file writer). The rest of the launch tooling (the staged launch scripts, `launch.sh`, rehearsals, the operator
runbook) is not public.

**Other later modules**

| Area | Contracts | nSLOC | This round |
|---|---|---|---|
| Rate manager | `RateManager` | 148 | as before |
| Loop vault | `src/earn/LoopVault.sol` | 510 | out of scope |
| DEX | `src/dex/` | 875 | out of scope |

Out of scope: `test/`, `script/` (except the Round 2 files named above), `lib/`, unless a finding in scope reaches through them. The deploy scripts are worth
reading for the wiring (`script/deploy/Stage*.sol`): what is set at genesis and sealed, and what is left to governance.

## Key invariants

1. **Supply equation.** At rest, `totalSupply == Σ debt + Σ badDebt + reserveBacked + migrator outstanding + peg keeper
   outstanding + bridge received − bridge sent` (see the `LedgerBase` header; a queued inbound bridge transfer counts as
   received when it is claimed, and the bridge's `queued` holds what is pending). Flash-minted amounts exist only inside a
   transaction (`circulating()` is the supply before the transaction's first mint or burn). The edge premium and interest are minted on both sides at once.
2. **Solvency and health.** No action that adds debt or removes collateral leaves a position below its type's liquidation
   ratio at the borrow price (`min(low, cap)`), and none is allowed unless the price is fresh, its two legs agree
   within `skew` and every swarm leg it reads has converged on its last attested value. Repayments and deposits
   need no price. Liquidation health uses the position's BOUND risk version.
3. **Line.** For every type, `debt + badDebt <= line`; on a capped chain the chain-wide sum (and any group cap) holds too.
4. **Edge capacity.** The SUM of every edge type's debt plus bad debt stays within the edge sleeve's `edgeCapacity`, less
   the edge debt under a live liquidation mark. Checked wherever edge debt is created.
5. **Sleeve accounting.** A sleeve's shares are claims on vested imdUSD plus the collateral it holds, per token; exits
   are pro rata in kind; booked but uncovered bad debt on its types is netted out of the imdUSD used to price
   conversions, pay exits, bid and size edge lines; a bid or a cover never spends below `MIN_RESIDUE` (1 imdUSD); a
   deposit converts only after a full day bucket and never while the booked loss exceeds the cover room. Edge bad debt is
   covered by the edge sleeve first, then the Treasury (`Treasury.coverBadDebt`).
6. **Depth rule.** For the IMD-collateral type: `line x (1 + chop) + redeemCap (+ other chains' IMD lines) <= k x
   depthIMD`, with `depthIMD` the measured depth, capped by a posted ceiling.
7. **Timelock.** Every governed raise (lines, risk values, fees, minters, new types, the depth leg, depth ceiling, sleeves, Allocator limits)
   waits 48 hours; lowerings that reduce risk are instant and cancel pending proposals touching the same field; a queued
   proposal expires 14 days after its ETA; one pending slot per kind.
8. **Minters set once.** imdUSD has four minters, each fixed once: `ledger` and `migrator` (wired by the deployer),
   `keeper` (the peg hook, set by the deployer before the seal) and `bridge` (set once through the timelocked
   `Parameters`; on each chain the Safe proposes it only once the bridge re-check is clean, and until it applies the
   bridge mints nothing). The imdUSD token has no owner, upgrade, pause or rescue.

## Trust model

- **Governor:** a 2-of-3 Safe, immutable in each contract. It acts only through the 48-hour timelocks of `Parameters`,
  `Treasury` and `Allocator`, except instant actions: the risk-reducing ones (lowering a line, a cap, a keeper cap, a
  depth ceiling, a bucket; disabling a sleeve listing; freezing the Allocator), unfreezing the Allocator, and
  `Allocator.returnToTreasury` (funds held there back to the Treasury, no bucket), and `Treasury.retireReserve` (burning
  Treasury imdUSD against reserve-backed supply; it was permissionless before wave 2). It cannot move user collateral or
  mint imdUSD directly. It can name one bridge minter, once, through the 48-hour timelock (`SET_BRIDGE`): that minter
  can mint without limit and burn from any holder. `ImdUSD.checkBridge` refuses, at propose and at apply, a candidate
  that does not report itself wired to this chain's imdUSD, LayerZero EndpointV2, Safe and Treasury (it reads the
  candidate's own views, so a contract written to report that wiring passes). On 12-07 it names `ImdBridge` on both chains, once the bridge
  re-check is clean (`script/launch/BridgeBatch.s.sol` refuses to write that file otherwise).
- **Bridge (no guardian):** only the Safe acts on `ImdBridge`. Its instant acts can only close or delay: `pause` a path,
  `hold` one inbound message (72 h, once per nonce, never renewable), `voidPayload` a payload hash for good,
  `cancelClaim` one queued transfer, `tighten` a path's delay settings (lower the instant cap or the queue breaker,
  lengthen the delay, move the bulk-cancel cutoff earlier) and `tripBreaker`. Everything that opens, loosens or releases
  (UNPAUSE, RELEASE, UNVOID, UNCANCEL, RESET_BREAKER, SET_DELAY, paths, libraries, DVN configs, limits) waits 48 hours,
  and once it has waited anyone may apply it. Value relies on the DVN set (3 required: LayerZero Labs, Twinstake, P2P;
  floors in source) and LayerZero's EndpointV2. Against a compromised DVN set the INBOUND DELAY is the bound: per path,
  what mints at once is at most the instant cap C per day (decaying; C + C x t / 1 day over any interval t); anything else
  queues and is claimable by anyone only after the path's delay D, inside which the Safe pauses the path or cancels; with
  no human action at all, at most the queue breaker B queued within 4 UTC days reaches a claim before the path trips
  (launch values per path: C 5,000/day, D 12 h, B 50,000; limits 50,000 per day each way). The minimum transfer (10
  imdUSD) bounds how many honest nonces a forger can consume. An off-chain watcher holds no key: it matches `Received`,
  `Queued` and `PacketVerified` on one chain with `Sent` on the other and alerts the Safe's signers.
- **Robinhood Chain sequencer:** a silence longer than the Pulse gap opens a grace in which liquidations, stock auction
  takes, write-offs, redemptions and new debt (a borrow, a withdrawal that leaves debt, a charged rate change) wait;
  repayment and deposits always run. The Pulse sees only silence: anyone may poke it, so a sequencer that censors but
  still includes a poke opens no grace (accepted).
- **Swarm attester:** swarm-priced feeds (sIMD legs, NHI, seat median and spot, the depth leg) accept an EIP-712
  attestation only from one pinned signer, for one pinned question (bound by hash), with absolute floors (panel of at
  least 100, at least 51 agreeing). Every valid attestation is a target: the stored value moves toward it by at most a
  fixed cap per epoch, and the one step that opens an epoch after a silence (maxAge plus an hour) by at most 2x the cap;
  nothing beyond the live epoch's anchor and the last target is remembered. Relaying is permissionless. A compromised
  attester (or a wrong majority) moves a leg one allowance per epoch for as long as it lasts, and about as many epochs
  of honest attestations undo it; the response is the governor's instant `Parameters.lowerLine(ilk, 0)` (no new debt on
  the type, liquidations continue) and a re-point. sIMD's spot leg is the proven pool price, with no attester in it: a
  wrong sIMD median cannot set the liquidation price below the proven price (less `skew`). NHI and seat legs have no
  such twin. On a remote chain with no block clock only the deployment relays a feed's first value.
- **Chainlink:** aggregators are trusted within staleness bounds; answers at the aggregator's min/max clamp or above a
  sanity cap read as unpriced.
- **Allocator callers:** the rule-driven actions are open to anyone; a caller picks only the MOMENT. Every action draws on
  the same Safe-set targets and refilling buckets, so a bucket is the most an action can move in its window. Rule-driven
  calls emit `Ruled` (and `AuctionStarted` / `Bought`); `Acted` is emitted only for a keeper's or the governor's action.
- **Keeper role:** a key the governor may add to the `Allocator` through its timelock (THE BETA ADDS NONE). It CAN move
  protocol funds held by the Allocator between the Allocator and allowlisted protocol targets only, each within its bucket
  and a two-feed slippage bound; it CANNOT name a recipient, raise a bucket or add a target, move user funds, mint imdUSD
  or change any parameter.
- **Freezer:** the Safe, from genesis (there is no separate freezer key). `freeze()` stops every keeper and rule-driven
  Allocator action; only the governor unfreezes. An operator watches the Allocator's logs and alerts; it holds no key that
  can move or stop protocol funds. Permissionless chores (relaying attestations, sampling `DepthSampler`, poking
  `ImdDepth`, marking and liquidating, starting auctions) anyone may run.
- **Seat claim rules:** `SET_SEAT_CLAIM` refuses a listed set of token-moving selectors (approve, transfer, permit,
  burn, ERC-4626 and Compound-style redeem/withdraw, ERC-6909 operator forms and others). A denylist cannot be complete:
  what a selector does is the target's code, so every claim-rule proposal must be reviewed against the target's ABI and
  code before the Safe signs it.
- **Issuers:** USDC/USDT can blacklist addresses; stock tokens (Robinhood Chain) carry issuer pause, blocklist and `adminBurn`
  keys that the protocol cannot prevent, only cap by debt lines.
- **Relayers and samplers:** permissionless; liveness of swarm-priced types depends on someone buying and relaying
  attestations. Stale prices stop borrowing, not repayment.

## Known issues and accepted risks

Items below are known and do not need to be reported unless you find a materially worse consequence.

- The unbacked-supply brake stops new debt but not the peg keeper's mint, which is bounded only by `keeperCap`.
- Governed raises of lines, depth and `mat` have no per-step size bound beyond the timelock; the migrator line is not
  bounded by v1 supply; re-registering a token as a new type is not refused. (changed: the depth used by the rule is now
  measured on chain, and a raise of the posted figure only raises its ceiling.)
- Migrator: no instant way to lower the migrator line and no v1 redemption path; the first deployment opens with the
  migrator line at 0.
- The sIMD live (redemption payout) leg can be pushed down toward the attested `high` inside a transaction.
- Seat prices rely on the oracle recipe's distinct-seat rule against wash trading; stronger buyer filters are an
  oracle-side change. When the median's fall cap binds, a seat auction's decay does not continue down to the raw spot.
- `setGenesisKeeper` does not check the keeper's stable token.
- One wei of sIMD sent to the shared `Join` in a block makes that block's `viaAsset` unwraps revert (sIMD's one-block
  hold); matters mainly once `LoopVault` is on.
- While a price is stale, borrowing up to the line can use the last attested `low` (bounded by the per-epoch cap).
- An honest large sIMD redemption can hold the sIMD redemption fee at its 5% cap for hours (by design). A type never
  redeemed starts its base rate at 0.5% (fee about 1% at the seal), decaying with a 12 h half-life.
- The redemption fee is sized on the requested amount while the base-rate rise uses the filled amount.
- `PegHook`'s quote feed and max age are immutable; a v4 protocol fee at or above the keeper margin would make small
  keeper trades revert.
- `RateFeed`'s growth cap is measured from the last poke, so headroom accrues while nobody pokes.
- The sIMD price legs bound ETH/USD staleness differently, which can briefly read unpriced.
- Swarm feeds admit two attestations with equal `issuedAt` in either order (bounded by the cap; under clamping the later
  relay is the target).
- If Circle blacklists the Treasury, liquidations of USDC types with a non-zero Treasury cut revert (`treasury` is
  immutable).
- `PegLPVault` has no deposit hold, so just-in-time deposits around known fee or donation arrivals are possible.
- DEX (round 2): IMD outputs require `hookData` naming the recipient; price limits are checked by the hook only;
  deposits and compounding can be delayed at a cost.
- Stock types are priced by a single leg.

### Known issues added 2026-11-07

- **An auction healed by the price alone stays open.** A repayment or deposit that heals a seat (or stock) position ends
  its auction in the same call. One healed by the price stays open until someone calls the permissionless `cancel`; if
  it dips again within the auction's life it sells at the auction's decayed price.
- **Value already in an empty sleeve is locked.** Premium that vested before anyone deposited, or what an exit left
  behind, belongs to the 1e6 offset shares minted to `0x…dEaD` at the first conversion. It stays in the pool and earns
  with it, and nobody can withdraw it.
- **A dead feed's edge mark stops counting after 7 days.** `Liquidator.releaseEdgeMark` drops a mark's debt from the
  edge capacity once its type has been unpriced 7 days (or the position has no debt). The debt itself still counts.
- **The Treasury covers edge bad debt only behind the sleeve.** `Treasury.coverBadDebt` falls through to its own balance
  only when the sleeve refuses with `UnknownIlk` (or covers nothing); any other sleeve revert reverts it, until the
  governor disables that sleeve listing.

### Known issues added in the 2026-11 internal review

Accepted after an internal adversarial review of this core. Dollar figures were measured on mainnet forks of the live
pools in early November 2026 (IMD/ETH v4 pool, sIMD line 24,333 imdUSD unless stated) and move with depth and prices.

**sIMD has no market check on its attested pair** (changed in wave 4: sIMD's spot leg is now the proven pool price, not
an attested leg, and while the two legs disagree the liquidation price is `max(median, spot)`; a wrong or compromised
median can no longer make a book that is healthy at the proven price liquidatable. What still holds below: a wrong NHI,
the live-pool push against the standing bid, and borrowing needs both legs to agree, so a wrong median still stops it.
The text is kept as written for the beta's earlier design.)

sIMD is priced by two attested legs (`low`, `high`) with the live pool in its `liveSpot` slot. The live leg sets the
redemption payout and `agree` only; `borrowable` and `low` do not read it.

- **A wrong pair is accepted.** A wrong attested pair, or a compromised attester key, moves sIMD up to 40% after a silence
  and 20% per epoch, and repeated pairs from a stolen key walk further until someone pauses. Measured at the 24,333 line:
  a -40% pair makes a book that is healthy at the market liquidatable, costing borrowers about $18k with about $15.7k to
  the caller; a +40% pair pays an attacker nothing. **Re-measure before any raise of the sIMD line.**
- **The guard.** `liquidate(id, minSeized)` and `bite(id, minSeized)` revert `SeizedTooLow` if a price update lands ahead of
  the caller. The standing bid path ignores it, and the unguarded forms remain.
- **Pushing the live pool inside a transaction.** The standing bid buys only while the live pool is not below `low` by more
  than `skew`. With a fresh pair stale-high, one transaction can push the pool up into `skew` of the pair and force the bid
  above the market. A push down past `skew` instead sends the liquidation to the caller, who takes the penalty's value;
  the sleeve loses only that bonus. A charged rate change is refused with the pair above the pool; borrowing is not.
- **NHI has no market check.** NHI is attested only; a wrong NHI on an NHI-linked type is bounded by its feed's
  per-epoch cap and lifetime, not by a pool.
- `LoopVault` (off in the beta) reads `low` and `high`; it must be re-reviewed against this risk before it is turned on.

**Backstop sleeves**

- **Exits inside the claim window before a loss.** Holders whose withdrawal requests have matured can leave pro rata,
  inside the 2-day claim window, before a loss is booked (measured: 5,002 of 6,000 left). Queue designs have this; an
  exit is net of anything already booked.
- **`MAX_RATE` stop after repeated wipes.** After about 5 wipes of 1M each, the 6th recapitalisation's conversion waits
  forever (the share price falls under 1/`MAX_RATE` per wei). Deposits stay cancellable and new money is never lost; the
  sleeve then needs a replacement.
- **Cover gas.** A liquidation that books bad debt reverts `CoverGasShort` with under 2M gas left, so a caller cannot
  starve its cover; such a liquidation needs a gas limit above 2M. The cover stays best effort for other failures
  (mid-bid, an empty Treasury); `netVested` still nets the booked debt, and anyone can call the cover afterwards.
- **Booked loss above the room holds every bucket.** While booked bad debt exceeds what the sleeve can cover, every
  bucket waits and edge room stays shut, even for a small residual. Anyone can end it (fund the Treasury and call
  `coverBadDebt`, or call `Ledger.cover`); deposits can be cancelled in full. A deposit that waits past maturity holds a
  free option: it can cancel or convert when the hole closes.
- **Retire residual.** A `RETIRE_SLEEVE_TOKEN` applied at a stale read values that token at 0 for the next conversion:
  the converting deposit A gains `A x T / (C + A)` from the other holders (T the retired token's true value, C the
  sleeve's other value; measured: 10,000 became 13,133 and another holder lost 3,133). The Safe cancels a refused retire
  once the token is priced again, and `realize` clears the flag at the first good read.
- **Global brake beyond sleeve plus Treasury.** A liquidation covers edge bad debt in its own transaction, the edge
  sleeve first and then Treasury imdUSD. Whatever is left beyond both counts in the unbacked-supply brake, which is
  global: an edge loss larger than the sleeve plus the Treasury stops new debt on every type, not only on edge types,
  until someone covers it.

**Measured depth**

- **Depth reference (changed: wave 2 fixed the depth griefing).** The samplers' reference used to be the LIVE pool price,
  and a push, a sample and the push back in one transaction or bundle deflated a bucket for ~2% of the push. It is now
  pool 0xb07d's end-of-block price, proven from state, which nothing inside the sampling transaction can move: a push
  within `maxDeviationTicks` (400) leaves the reading unchanged (the walk counts positions around the reference), a larger
  one is refused `PoolOffReference`. What is left: (1) a push held across a block's END (the attacker exposed to every
  arbitrageur for a block, or one party building two consecutive blocks) is proven like an honest price; (2) the proof may
  be up to 6 hours old, so after a real move the band is measured around the older price (bounded by the 400-tick guard);
  anyone may prove a newer block, and the operator re-proves on drift; (3) a change of Ethereum's state trie
  (binary/Verkle) ends these proofs: the samplers then read stale (zero depth, fail closed) until the Safe swaps them;
  (4) a public sample can still be sandwiched to INFLATE a bucket (+L / sample / -L): the operator samples through private
  relays, an operational defence, not the contract's.
- **Keeper outage closes new sIMD borrowing.** If no sampler is sampled for about 6 hours of a 26-hour window, it reads 0
  depth and the 7-day low holds new sIMD borrowing at 0 for about 8 days. Existing positions are untouched. Fail-closed by
  design.

**PEG positions**

- **Own-USDC leverage.** Zero-USDC loops are gone (PEG collateral comes only through the zap, with real USDC), but real
  USDC equity levered through a USDC flash loan and a sale of the borrowed imdUSD still reaches about `mat`'s bound: at
  `mat` 125%, $1,000 of own USDC carries $3,901 of debt (3.9x debt over own USDC, 4.9x collateral over equity). It is
  solvent at par, a leveraged short of imdUSD, bounded by the PEG line and the two-sided range. Opening CRs inside the
  gate: 134.09% at the floor rate, 131.61% with the average rate at its maximum.
- **Idle imdUSD in the PEG gate.** Idle imdUSD in the vault counts in its value but not in the two-sided gate: in a vault
  one holder owns, 538 USDC backed 80.4k of debt at CR 126%. It needs 20% real equity and is solvent at par.
- **The PEG line can be filled cheaply:** anyone locking about 12.5k fills a 50k line. It uses only PEG's own line.
- **At-mat edge liquidation.** Levering to the limit at the gate's edge and the pool then returning to the centre reads
  124.93% at `mat` 125%: liquidatable at once (a liquidator nets about 268 on 10.7k). The same holds for an off-centre
  borrow at -49 ticks (CR 1.10009 reads 1.09943 at the centre). Both are a borrower's own choice of maximum debt.
- Zap opens are griefable for about $5 per block: a 12-tick push (toll-free) trips the vault's spot-versus-TWAP gate, and
  uncollected fees or donations above the 0.05% share margin make every open revert `Slippage` until someone compounds.

**Rates and governance**

- **Operator rate + 1 wei.** SET_RATE is the owner's grant of trust. An operator's rate change of any size (even 1 wei,
  or none) restarts the 7-day cooldown, and the owner's next change then pays the premium (9.6 imdUSD on 10k measured).
  Grant it only to a manager you trust.
- A hostile `RateManager` key can front-run a member's own `setRate`, `leave` or `setLimits` with a free re-rate, so the
  member's change pays the cooldown premium.
- `RateManager.maxStep` limits the target per call, not a member's move: calls with no ids can walk the target across the
  whole range, then one call moves members by the full range.
- A 3-word `RETIRE_SLEEVE_TOKEN` payload passes `propose` and fails at apply; its slot holds until the governor cancels.

### Known issues added after the first public audit (wave 1, 2875ffb)

- **Seat swap during an auction.** A holder's seats are fungible: a borrower whose position is in auction can swap the
  pledged seat for another seat in the same block, and `take` delivers whichever seats remain. Seats are priced by the
  collection median, so the buyer pays the median-based price for any seat; trait premiums are not priced.
- **Peg TWAP one-block push.** One block with a pushed peg-pool price holds the Allocator's LP actions (spot more than 10
  ticks off the TWAP, keeper and rule-driven alike) and can hold `LoopVault.lever` for about 30 minutes. Griefing only.
- **Peg toll pricing.** The toll is priced on the swap's end price: splitting a push into several swaps pays about a third
  of the toll; a swap that overshoots $1 is tolled on its whole amount; exact-output swaps pay about 4% less at the cap.
- **Backstop conversion moment.** A matured deposit bucket converts at the asset value of the first call after it matures
  (00:00 UTC of day + 2); anyone may call `realize` first.
- **Rate floor 0 + `borrowFor`.** `borrowFor` passes rate 0; on a type with `rateFloor` 0 a borrow on a position whose debt
  reached zero before inclusion would open at 0%. Unreachable in the beta (every floor >= 0.5%).
- **First swarm-feed value.** Nothing on chain checks a leaf's first relayed value; seeding and checking it is the
  operator's duty. (Since wave 4, on a remote chain with no block clock only the deployment may relay it.)
- **Edge bootstrap renewal.** The Safe can renew an edge type's 60-day bootstrap allowance by disabling it (instant) and
  re-listing it (48 h); while disabled, borrowing and the standing bid on it are off.
- **Redemptions ignore the Pulse. RESOLVED in wave 5:** the Redeemer refuses (`SequencerGrace`) while `Pulse.inGrace()`
  reads true, the same condition that holds liquidations.
- **Flash cap is per loan in flight, not per transaction.** Sequential flash loans in one transaction each get the full
  cap; `circulating()` stays correct.
- **`circulating()` and flash loans (superseded in wave 2: now the supply before the transaction's first mint or burn;
  and since wave 4 the redemption fee divides by `feeBase()`, see below).** Inside a native flash loan it reads at least the supply when the outermost loan
  began, so real burns inside the loan (a redemption split in chunks) also read against that supply: second order. The
  fix covers imdUSD's own flash mint only: imdUSD borrowed elsewhere to repay one's own debt, redeem and re-borrow still
  deflates the supply for the redemption, bounded by outside imdUSD liquidity, the upfront fee and the 5% fee cap.
- **The seat figure cap counts attestations, not time.** Each new attestation moves the figure at most -20% / +25% + 1;
  back-to-back attestations (one block apart, each poked) walk it further within minutes, as the median's cap does.
- **The PEG type on a deploy resume.** A resumed stage adopts PEG's registered pieces without comparing its risk, spot leg
  or peg aggregator with the config (the other types are compared).
- **Rule-driven Allocator actions (new since 2875ffb).** A caller picks the moment of each, and where rules share a token
  (the buffer's quote token, the LP vault's tokens and an auto vault's asset can all be USDC) which rule spends it first;
  value only moves between protocol addresses. The collateral auction's top is 103% of the sleeve's highest price
  (`max(low, high, payout)`; the payout follows the type's live pool), its floor 98% of `low`: a type with no live pool
  leg tops at its attested `high`, so in a rally the pair has not caught up with a buyer can pay under market. Anyone may
  restart a run once it reaches its floor (griefing: up to 2 hours per restart before the floor again), or once more than
  5% of the holding has arrived since it started (a buyer who can make the sleeve take 5% of its holding through
  liquidations can reset the run for the chop on that amount).
  `rebalanceVault` deposits at the vault's share price of that moment: only rate-based vaults (sUSDS-like) are meant for
  it; changing the auto vault leaves the old vault's shares to a keeper or the Safe. `rebalanceLp` exits with zero
  minimums behind the spot-versus-TWAP gate. Each is bounded by its bucket, and `freeze()` (the Safe) stops all of them.

### Known issues added after the second public audit (wave 2, 5de80a6)

- **SwarmFeed way back (trade-off). RESOLVED in wave 4:** price design C deleted the way back; see the wave-3 section.
  As written for 5de80a6: After an epoch expires, a value within the cap of the expired epoch's level, its
  anchor or the previous epoch's anchor is accepted in one step, whatever the last value was: a pushed or compromised
  attestation can move the feed back to within the cap of where it stood one to two lifetimes ago in one step (wave 1
  had bounded any one step at 2x the cap). In exchange three boundary-timed pushes (or two after a silence) no longer lock
  the honest level out. A lock-out still needs FOUR boundary-timed pushes in a row with no honest value between them
  (`test_fourBoundaryPushesInARowStillLockOut`); recovery is the Safe re-pointing the leaf (48 h).
- **BATCH proposals are dry-run at propose (changed in wave 4: one linear dry run that skips waiting items; see the
  wave-3 section for the case it does not catch).** An item that fails only because of an earlier item in the same batch is
  refused at propose; an item that would fail on its own (waiting on state: a retire before its feed stops, a line raise
  before depth) is still accepted and fails at apply if the state never arrives, as a single proposal does.
- **Seat auction clock needs both legs (extended in wave 4: also stopped while `SeatFeed` reads 0).** Priced time counts only seconds in which the median leaf and the ETH/USD leg
  were both fresh. ETH/USD fresh at the last tick and fresh now counts as fresh throughout (its heartbeat keeps it so); an
  ETH/USD gap that opened and closed between two ticks is not seen (the operator ticks an auction when its type goes
  unpriced). The median's reconstruction runs slow, never fast.
- **Gas-driven layout (new since 5de80a6).** `SortedPositions` keeps only each node's links: a node's rate is the
  position's recorded rate read from `Ledger.rateOf` (the Ledger lists, re-lists and removes with exactly that rate).
  A position's type is a 16-bit index in its own record (`ilkIndex`; `lastUpdate`/`lastRateChange` are uint40), and
  `ilkOf(id)` a view over it; the first position ever opened on a type registers its index (one-time cost). Samplers
  measure only the side `depth()` reports (the other reads 0) and store readings in whole USD, rounded down.
- **Sleeves hold up to 10 tokens** (was 6); the beta lists 6 on the blue sleeve.

### Known issues added after the third public audit (wave 3, c64ecee)

Residuals of the wave-3 fixes and of price design C. The design-C items are what the design panel of this round is
asked to refute or bound more tightly.

- **Last relayer of an epoch.** A relayer that always lands an attestation LAST in an epoch decides where the stored
  value ends that epoch, within the allowance, for as long as it keeps doing so (one allowance per epoch). Bounded by P1
  in `SwarmFeed`'s header; `testFuzz_residual_lastRelayerMovesOneAllowancePerEpoch`.
- **An attack lasting k epochs takes about k epochs to undo.** A compromised attester, a wrong majority or pushed pool
  reads attested honestly move a leg one allowance per epoch while they last; honest attestations then bring it back at
  the same rate (`ceil(ln(ratio) / ln(1 + cap))` epochs). The way back undid it in one step; that speed needed memory,
  and the memory is what each earlier wave broke. The response to a suspected compromise is `lowerLine(ilk, 0)`.
- **Liquidation after a real fall waits for a proof.** For sIMD, after a genuine fall the median follows down at the
  allowance while the proven spot keeps the old level until a newer block is proved; with the legs apart `low = max(median,
  spot)` keeps an under-water loan healthy until then. Proving is permissionless (a liquidator proves, then bites), and
  the operator proves at once when the legs are apart. A proven spot pushed DOWN within `skew` lowers `low` by up to
  `skew` while that proof stands.
- **The proven spot is a borrowing dependency.** A proven price lives 6 hours: if nobody proves a newer block, sIMD
  borrowing stops (no agreement) and liquidation continues on the median.
- **Redemption fee base window.** `ImdUSD.feeBase()` is the lower of `circulating()` and the lowest supply in the current
  and the previous 1-hour bucket, so debt counts in a redemption's fee only once it has stood 1-2 hours. Debt held
  through the window is indistinguishable from honest debt: a diluter who holds it 1-2 hours pays only the upfront fee
  (7 days at the type's average rate) and the price exposure. Supply that FALLS counts at once: a repay and re-borrow
  raises other redeemers' fees for up to 2 hours (a fee rise, never a loss of funds). Before any supply is recorded the
  base is `circulating()` alone.
- **The seat claim denylist is not an allowlist.** 13 more token-moving selectors are refused (41 in all), but no list
  can be complete: every `SET_SEAT_CLAIM` proposal must be reviewed against its target (Trust model).
- **Remote clock.** k validly signed, future-dated windows can still step a remote feed's clock k x `PARENT_SLACK`
  (bounded by the slow projection's `most`); each needs the attester's signature. Not reachable in the beta (mainnet
  feeds take the same-chain branch).
- **Seat clock between ticks.** A stretch at a 0 figure that begins and ends between two ticks is counted as priced; the
  clock loses up to the time since the last tick when the type falls to 0 (the operator ticks a running auction hourly).
- **BATCH later item.** The propose dry run skips a waiting item, so a later item that only the waiting item (once it can
  apply) would break is not caught at propose: the apply reverts as a whole and the Safe cancels.
- **Wide band after a silence is one step.** The first attestation after a silence may move the value up to 2x the cap;
  the epoch then re-anchors at the stored value at the cap, whoever lands first.
- **A clamped depth leg.** The swarm depth leg is clamped too, so its stored value may be one nobody attested; it is only
  ever min'd with the sampler sum, so it can lower depth, never raise it.

### Known issues added after the fourth public audit (wave 4, 67eadea)

Residuals of the wave-4 fixes and of the bridge hold design. The bridge items are what the bridge panel of this round
is asked to refute or bound more tightly.

Bridge:
- **Response speed is the Safe's.** There is no guardian: every instant act (pause, hold, void) needs a 2-of-3 Safe
  signature round. Between a forgery verifying and the Safe acting, the inbound limit is the bound: about 2 x
  `IN_LIMIT` per window can be minted (10,000 per day each way at launch, so up to ~20,000 inside 24 h, within the
  4663 chain line of 30,000; `test/unit/AuditW4BridgeInLimitLine.t.sol` pins `2 x IN_LIMIT <= CHAIN_LINE`). (changed
  before wave 5: the limits are now 50,000 per day each way and the bound is the inbound delay; that test now pins the
  delay's bounds on the launch values. See the next section.)
- **A hold only helps a message still waiting at the endpoint.** `hold` binds a payload the endpoint stores at a nonce
  that has not executed. A forged message that executes in the block it is verified (inside the limit, path open) is
  minted before any hold; the inbound limit is then the bound. (changed before wave 5: only what fits the path's instant
  cap mints in that call; the rest queues for the delay, where the Safe pauses or cancels.)
- **A compromised DVN set** can still consume up to `2 x limit / MIN_AMOUNT` honest nonces per window (10,000 at the
  50,000 limits; a forged execution spends the nonce even when its claim is later cancelled) and overwrite an
  honest payload waiting at the same nonce, until the SOURCE path is paused; the user's burn on the source chain is then
  lost. A held honest payload overwritten during the hold never auto-releases: it waits for the DVNs to verify it back
  or for the timelock's RELEASE.
- **Detection is off chain and cross-chain.** `netMinted()` cannot show a forgery (the supply equation holds after one);
  the watcher matches `Received` nonces against the peer's `Sent` nonces. Paging the signers is off chain.
- **An honest payload voided by mistake** waits for UNVOID (48 h); the endpoint keeps its proof, so no DVN signs again.
  The timelocked `ENDPOINT_NILIFY` is a clean-up only: after an endpoint nilify every required DVN must sign again.
- **Limits.** Lowering an inbound limit needs a paused path (operator procedure: lower the peer's outbound first and let
  its in-flight land); the two chains are governed separately. Lowering to a tiny non-zero limit and raising it later
  (two 48 h proposals) still frees room. Nothing stops a later `SET_CHAIN_LINE` lowering the 4663 line below 2 x the
  live inbound limit. (changed before wave 5: the 2 x limit rule was replaced by the inbound delay's bounds; `tighten`
  does not lower a limit, so lowering one still needs a paused path.)
- **A library that rejects `setConfig`** (for example LayerZero's BlockedMessageLib) passes the proposal check and
  reverts at application; no value moves. An endpoint act (burn, skip) accepted at proposal can still revert at
  application if the endpoint state changed in the 48 h.
- **20 confirmations from 4663 are seconds** of one sequencer's soft confirmations; a deeper reorg after the DVNs sign
  leaves a mint on Ethereum whose burn is gone, bounded by Ethereum's inbound limit from 4663 (since the inbound delay,
  a transfer above the instant cap waits the delay first).
- **Native value** an executor forwards to `lzReceive` stays in the bridge (dust; `send` never spends it).

Price design:
- **The attested median lags a one-block fall** (a window median reads the pre-fall level for ~2 h): after a real fall
  `low` reaches the market once a median whose window is mostly past the fall is attested and relayed.
- **NHI moves one cap per day** (no wide step after a silence), which still moves mat by more than `skew` from some
  levels (from NHI 0.85 a 20% step moves mat 1.70 -> 1.90); a compromised key reaches about mat 2.0 in two days.
  The response is `lowerLine(ilk, 0)` and a re-point (48 h). (changed before wave 5: NHI is now bounded per window of
  time, not per epoch; see the next section.)
- **A prover chooses among the last 32 end-of-block prices** (`PROVE_WINDOW`), within `skew` of the median.
- **Conservative traits:** a product over a composite of attester-free feeds reads not proven (median rule); a feed whose
  fallback returns success with empty data reads as "absent".

Stock tokens:
- **The standing answer after 5 minutes.** From 09:35 New York a type with no in-session print (SGOV; SPY on quiet days)
  is priced from the overnight or heartbeat answer, trusted only through the feed's deviation trigger. Up to 5 minutes
  of each open are unpriced (no borrow, bite or take; repay and deposit unaffected).
- **Stuck stock.** Stock sent to a `StockVault` outside a deposit (or a reissue above what was burned) is stuck; a
  partial burn with no reissue closes deposits to that type for good (withdrawals, liquidation and write-off keep working).
- **Auction clock bound.** Each span in which nobody could take costs at most `TICK_SPAN` (5 min) of descent; without
  ticks the price falls only 5 min past the last read (the keeper ticks live stock auctions every 5 min).
- **A multiplier step** freezes the type until someone calls `sync()` and the feed prints afterwards.
- **Calendar:** an unscheduled closure needs the Safe on the day (`closeDay`, instant, close only).
- **A real decimals change** of an aggregator leaves the type unpriced until the feed is redeployed.
- **SGOV's 49 h max age:** a dead SGOV feed prices up to 24 h longer than the other types (a T-bill fund moves ~0.02% a day
  against a 15% buffer).
- **After-hours design (the judge's information item):** stock types freeze outside the regular session and every gap
  is taken at the open; measured closed-market gaps Jun-Nov 2026 sit inside each type's buffer. No stricter ratio for
  new debt before long closures is built.

Robinhood configuration:
- **The 4663 IMD type opens at line 0.** Both IMD price legs on 4663 are swarm-attested (no proven leg there); the Safe
  raises the line to 3,000 (48 h) only after the 4663 IMD feeds have been seeded and compared with mainnet for some days.
  The IMD OFT on 4663 is owned by an EOA that can set peers (mint IMD on 4663 with no delay).
- **The 4663 governance Safe** is the mainnet Safe's address re-created on 4663 (`Safe4663.s.sol`); every 4663 deploy
  path refuses a governor with no code. Anyone may send its creation transaction (the result is the same Safe).

### Known issues of the changes made before this audit (since 67eadea)

The bridge's inbound delay and the other changes listed under "What changed since 67eadea" below, with what we accept.
Launch values per path: instant cap C 5,000 imdUSD per day, claim delay D 12 h, queue breaker B 50,000 over 4 UTC days,
limits 50,000 per day each way, 4663 chain line 30,000.

Bridge:
- **No action over a weekend can lose more than the 4663 line (ACCEPTED).** With no human action, a forged stream makes
  spendable on a path in any 72 h (`HOLD_TIME`) at most the instant part 4C plus B through claims: 20,000 + 50,000 =
  70,000, above the 4663 chain line (30,000). This is a decision (B was raised from 10,000 to 50,000 so large honest
  transfers are not tripped); `test/unit/AuditW4BridgeInLimitLine.t.sol` records it. The safety case is the Safe acting
  within D of the first forged `Queued`: pause the path, or `tighten` the cap to 0 with a cutoff at or before that
  `Queued`, cancels everything queued, leaving only the instant part C x (1 + D / 1 day) = 7,500. Paging the signers is
  off chain.
- **A pending loosening applies by anyone.** Every timelocked bridge act (SET_DELAY, UNPAUSE, RESET_BREAKER, UNCANCEL,
  ...) may be applied by anyone once its 48 h has run. In an incident the Safe must also `cancel()` any pending proposal;
  `tighten` bumps the path's settings version, so a SET_DELAY proposed before it is refused when applied, but other kinds
  are not versioned.
- **The delay is read at claim time.** A claim is claimable at `queuedAt` + the path's delay WHEN CLAIMED: an instant
  lengthening applies to every pending claim, and a shortening (48 h, public) to claims already queued once it applies.
  The `Queued` event carries the claimable time as of queueing only.
- **The breaker window is 4 UTC days, not rolling.** More than B queued on a path within the current UTC day and the 3
  before trips it; claims (honest ones included) then wait for a timelocked RESET_BREAKER naming that trip. Nothing
  expires. Receipts, instant mints and queueing go on while tripped.
- **Bulk cancel is a cutoff, not a list.** `tighten(..., cancelFrom)` refuses at claim time every claim queued at or
  after the cutoff (honest ones too) until a timelocked SET_DELAY lifts or moves it; claims cancelled one by one stay
  cancelled until each UNCANCEL (48 h). A cancelled honest claim drops out of `queued` while its burn on the source
  stands, so the cross-chain sum is short until it is restored.
- **Honest users above the instant cap wait.** A transfer that does not fit the path's remaining instant allowance (any
  single transfer above C) waits D and someone must call `claim` (anyone may; the keeper claims matured, matched
  claims). A pause holds every claim on the path until the 48 h UNPAUSE.
- **Governable without a bound.** SET_DELAY (48 h) sets C and B to anything their 64-bit shared-decimals fields hold
  (~1.8e13 imdUSD) and D within [1 h, 7 days]; `MAX_LIMIT` is 250,000,000 imdUSD per window (so a message always fits a
  claim's 48-bit amount). A larger C or B, or a shorter D, widens both bounds above; that is the Safe's public decision
  48 h ahead and is not bounded against the line.
- **`SET_BRIDGE` trusts the candidate's views.** `ImdUSD.checkBridge` reads `token()`, `governor()`, `treasury()` and
  `endpoint()` from the candidate itself; a contract written to report this wiring passes. Its code can only be compared
  with an `ImdBridge` build during the 48 h before it applies. `SET_BRIDGE` is one-time.
- **Enforced `lzReceive` gas 250,000** covers every path today on the real EndpointV2 with the real ImdUSD (worst
  192,275: a path's first message on the token's first mint; `test/fork/AuditW4BridgeEndpoint.t.sol`). At the
  Glamsterdam gas prices as published (not final) a path's first messages need about 466,000-653,000 and a steady path
  about 262,000-270,000: the Safe raises it by SET_PATH (48 h) before that fork. A short message is not lost: it waits
  at the endpoint and anyone retries it with more gas.

Price:
- **NHI is bounded per window of time.** Over any window of one maxAge (1 day) every NHI value stays within one cap of a
  value held in the maxAge before it (an epoch opening less than maxAge after the last move also stays in the previous
  anchor's band). Within one epoch a compromised key can still swing NHI up a cap and back down; honest hourly relays
  after a gap follow at worst one cap per two epochs.
- **The price legs keep wave 4's accepted sliding bound** (only NHI carries its anchor): over a closed maxAge a leg
  moves at most (1+c)^2-1, after a silence (1+2c)(1+c)^2-1. Accepted because sIMD has the proven twin; 4663's IMD type
  has no twin (line 0 at genesis, then 3,000).

Robinhood Chain and stocks:
- **Censorship that still lets a poke through is not detected (ACCEPTED).** The Pulse sees only silence. A sequencer
  that censors borrowers or liquidators but includes one poke within every 15 min gap opens no grace, so borrowing,
  seizure and redemption run normally. Robinhood Chain has no sequencer-uptime feed.
- **New debt and write-offs wait out the grace.** A borrow refused in the first block after an outage reverts, so its
  own poke does not persist; the next poke (or any non-reverting action) opens the grace.
- **The USDG freeze stops the auction clock.** `StockJoin` reads USDG's `paused()` and `isFrozen` at the join and the
  Treasury; if they cannot be read the clock stops and a `tick` reverts. If Paxos removed those views, every auction
  clock would stop (takes only at the opening price until the auction lapses and is re-bitten): a halt, not a loss. A
  frozen taker or borrower is not a hold.
- **StockVault real shares.** A share is worth `totalAssets x shares / totalSupply` (no virtual shares), rounded against
  the caller. After large forfeits a share can be worth so much that a tiny deposit rounds to few or zero shares: the
  loss is the depositor's (at most one share's worth) and favours the holders who stay. The donation guard is
  `managedAssets` alone; an emptied vault restarts its count at the next deposit.

### What changed since the fourth public audit (67eadea)

For the re-check: the fifth commit of this repository is the whole delta. Bridge (wave-4 bridge panel, 2 high, 1 medium,
9 low, 2 info): a path carries value only while both libraries are pinned and hold this OApp's own floor-checked ULN
config (`configured[lib][eid]`; SET_PATH and pins refused otherwise; `send`/`lzReceive` revert `Unconfigured`); a
minimum transfer of 10 imdUSD (`MIN_AMOUNT`), every message metered at no less than it (at most 2 x limit / MIN_AMOUNT
nonces per window); a void is the bridge's
own (`voided[hash]`), never undone by a re-verify, lifted only by UNVOID; endpoint burn/skip checked against EndpointV2's
rules at proposal and application; optional-DVN count NIL accepted and 0 refused; receive-library grace bounded and
UNPAUSE refused while an old library can verify; one SET_PATH/pin per eid in a BATCH and a closed path keeps its
in-flight; an inbound limit lowered only on a paused path; re-pinning the current library refused; `IN_LIMIT` into 4663
10,000 (was 50,000; since back to 50,000 with the inbound delay, below); `Sent`/`Received` carry the path nonce. THE HOLD DESIGN: the guardian is removed (constructor
`(endpoint, token, governor, treasury)`); the instant `nilify` is removed; new governor-instant `hold(srcEid, nonce)`
(72 h, once per nonce) and `voidPayload(hash)`; new timelocked `RELEASE`; `UNPAUSE` may not share a BATCH with a path,
library or config change for that eid. Enforced `lzReceive` gas 250,000 on both paths (`RobinhoodConfig.enforcedOptions`).
Price (wave-4 price panel): the twin rule reads the median's ATTESTED value (`FeedTraits.attested`) when the median is
clamped above it; NHI never widens after a silence (one cap per epoch); the P1 sliding-window bound corrected in
`SwarmFeed`'s header; a trait read that fails below a composite reverts `TraitUnreadable`; `ProductFeed.proven()` needs
one proven input and the other attester-free (and `DeployBase` mirrors it); `ProvenPoolPrice.prove` accepts only the last
`PROVE_WINDOW` (32) blocks. Stocks (wave-4 stocks panel): `MarketHoursFeed` prices the session only from an in-session
answer, or the standing one after `OPEN_GRACE` (5 min); `StockVault` counts `managedAssets` and closes deposits while
impaired; `StockJoin.take` uses the Ledger's own bonus; the auction clock runs on takeable time (`tick`, `TICK_SPAN`);
multiplier freeze keyed on the multiplier itself with `sync()`; `MarketCalendar.closeDay` (instant, close only) and
weekend days refused at propose; `ChainlinkFeed` re-reads decimals; SGOV max age 49 h. 12-07 additions: the Redeemer
respects the Pulse grace; the 4663 IMD line is 0 at genesis (`RobinhoodConfig.imdLineRaise` builds the Safe's raise);
a governor with no code is refused on every 4663 deploy path (`StageCore`); `RobinhoodConfig.GOVERNANCE_SAFE` = the
mainnet Safe's address; `StageChain` (Pulse, ImdBridge and the stock module as resumable deploy steps, shared by
`DeployChain`); the bridge Safe batches (`BridgeBatch.s.sol`, `Safe4663.s.sol`). Each wave-4 fix has a test named
`AuditW4*` (the judges' proofs, adapted, plus a property test that fails on 67eadea); the hold design is tested in
`test/unit/BridgeHold.t.sol` (H1-H4) and `test/invariant/BridgeInvariants.t.sol`; the endpoint facts it relies on are
proven on the real EndpointV2 in `test/fork/AuditW4BridgeEndpoint.t.sol`; the Pulse rule in
`test/unit/RedeemSequencerGrace.t.sol`.

Before this audit, after the wave-4 fixes. BRIDGE INBOUND DELAY (after Wormhole Governor's large-transfer delay): per
path, an inbound transfer mints at once only within the path's INSTANT CAP (`instantIn`, decaying per day: C + C x t / 1
day over any interval t); anything else is metered against the inbound limit and QUEUED as a claim keyed by its origin's
GUID (`claims[srcEid][guid]`, event `Queued`), claimable by ANYONE for the recipient once the path's delay has run since
it queued (read at claim time), forever (no expiry); `received` counts at claim, `queued` holds what is pending. The Safe
cancels one claim instantly (`cancelClaim`; UNCANCEL restores it, 48 h) or every claim queued since a cutoff in one act
(`tighten(srcEid, cap, delay, breaker, cancelFrom)`, instant, only tighter: lower cap or breaker, longer delay, earlier
cutoff; it bumps the path's settings version); a paused path refuses claims. QUEUE BREAKER: more than B queued on a path
within its 4-UTC-day window trips it (claims stop, nothing lost) until a timelocked RESET_BREAKER (kind 14) naming the
trip; the Safe may also trip it instantly (`tripBreaker`). GOVERNABLE: C, D and B are per path, written at a path's first
SET_PATH (`DEFAULT_INSTANT_CAP` 5,000, `DEFAULT_DELAY` 12 h, `DEFAULT_QUEUE_BREAKER` 50,000) and changed by SET_DELAY
(kind 15, 48 h; names the settings version it was proposed on; also lifts or moves the cutoff); D within [`MIN_DELAY`
1 h, `MAX_DELAY` 7 days]. `MAX_LIMIT` 10,000,000 -> 250,000,000 per window. Path limits 50,000 per day both ways
(`RobinhoodConfig.IN_LIMIT` = `OUT_LIMIT`); the launch BATCH also sets the delay values explicitly
(`RobinhoodConfig.INSTANT_CAP`, `CLAIM_DELAY`, `QUEUE_BREAKER`), and `BridgeBatch` builds its signer text from the
payload. SET_BRIDGE: `ImdUSD.checkBridge` (at propose in `ParametersRules` and at apply in `setBridge`) refuses a
candidate not wired to this chain's imdUSD, EndpointV2, Safe and Treasury. Gas: the enforced 250,000 re-measured with
the real ImdUSD (worst 192,275). Price: NHI bounded per window of time (`SwarmFeed._carriesAnchor`, opted in by the NHI
leaf only). Robinhood: new debt (`LedgerBase._quote` sets `borrowable` false in the grace) and `writeOff`'s seizure wait
out the Pulse grace. Stocks: `StockJoin`'s auction clock runs only while USDG can settle (not paused, not frozen at the
join or the Treasury; unreadable = stopped, `tick` reverts `SettlementUnreadable`); `StockVault` values shares with real
shares only (no virtual offset), rounding against the caller, and an emptied vault restarts its count at the next deposit.
Tests: `AuditW5NhiWindow`, `AuditW5StockUsdgFreeze`, `AuditW5SetBridge`, `AuditW5BorrowGrace`, `AuditW5WriteOffGrace`,
`AuditW5BridgeInboundResponse`, `AuditW5BridgeDelayProps` (D1, D5, D6), `AuditW5BridgeDelayLine`,
`AuditW5BridgeBreakerProps`, `AuditW5BridgeBulkCancel`, `AuditW5BridgeGovernableDelay`, `BridgeInboundDelay`,
`BridgeBreaker`, the extended `test/invariant/BridgeInvariants.t.sol`, the StockVault regressions in
`AuditW4StockVault`, and on the real EndpointV2 `test/fork/BridgeInboundDelayEndpoint.t.sol`; the real-USDG freeze in
`test/fork/RobinhoodStocks.t.sol`. Each property test failed on the code before its change.

### What changed since the third public audit (c64ecee)

For the re-check: the fourth commit of this repository is the whole delta. Wave-3 fixes: the redemption fee base
(`ImdUSD.feeBase()`, 1-hour buckets, used by the Redeemer's ramp and base-rate rise); the seat auction clock does not
count while `SeatFeed` reads 0 (`zeroAtTick`); 13 more token-moving claim selectors refused; a remote feed with no block
clock takes its first value from the deployment only, and one window moves its clock at most `PARENT_SLACK` past the
slow projection; the BATCH propose dry run is one linear pass (it re-ran per item: 17M gas for 8 items, now about 6M);
resume guards (Parameters is wired to one ImdDepth once; a recorded live-pool feed must not be a `ProvenPoolPrice`);
`ProvenPoolPrice.prove` of a block no newer than the held one is a no-op returning the held value (was `NotNewer`);
`Position.version` moved into slot 2 (an open creates 7 slots whatever the risk version); `ParametersRules` and
`LedgerSettlement` deployed separately, before their parents, which check them. PRICE DESIGN C: `SwarmFeed` clamps toward
each attestation instead of rejecting it; the way back (`_returnAnchor` and its memory) is removed; the wide band after
a silence is one step; new views `attested()`, `converged()`, `followOf()`; `FeedTraits` carries `converged` and `proven`
through the composites; in the Pricer a non-converged leg does not agree and, where the spot is proven, `low = agree ?
min : max`; sIMD's spot is the proven pool price (the swarm spot leaf and its product are gone: 23 mainnet feed nodes).
Each wave-3 fix has a test named `AuditW3*` (the auditors' proofs, adapted, plus a property test that fails on the
earlier code); design C is tested in `test/unit/SwarmFeedProperties.t.sol` (P1-P3, P5 and the residual as fuzz and
invariant runs), `test/unit/PricerTwin.t.sol` (P4) and the ported `AuditW1WayBack`, `AuditW2Ratchet` and `AuditW3WayBack`
suites; `test/unit/SwarmFeedGas.t.sol` measures an accepted attestation.

### What changed since the second public audit (5de80a6)

For the re-check: the third commit of this repository is the whole delta. Fixes: `SwarmFeed` way back two epochs deep
with no step bound from the last value, and a remote window's upper bound measured from the first value's fixed origin;
the Allocator's auction keyed on `Backstop.collIn` (arrivals, not the holding an in-kind exit lowers) with a 5% restart
threshold; `ImdUSD.circulating()` = supply before the transaction's first mint or burn; the seat auction clock stops while
ETH/USD is stale; claim rules refuse ERC-4626 redeem/withdraw, burn and burnFrom (the denylist is a packed byte scan);
`retireReserve` governor only; a never-redeemed type's base rate starts at 0.5%; `lowerOtherImdLines` removed;
ADD_DEPTH_SAMPLER and SET_DEPTH_LEG checked at propose as at apply; BATCH dry-run at propose; a resumed stage 4 keeps
recorded samplers and stops if ImdDepth lists others. New: the proven depth reference (`ProvenPoolPrice` + vendored
trie/RLP), 10-token sleeves, and a gas review (one-sided samplers with packed buckets; an open creates 7 storage slots,
not 9). Each fix has a test named `AuditW2*` (the auditors' proofs, adapted and made strict) or sits in the existing
suites; `test/fork/GasPaths.fork.t.sol` and `test/unit/GasSlots.t.sol` measure the gas changes.

### What changed since the first public audit (2875ffb)

For the re-check: the second commit of this repository is the whole delta. Fixes: health and liquidation on the
post-harvest state; `circulating()` held at the outermost flash loan's start; the seat auction clock counts from
max(signed, relayed); the seat figure capped per attestation and `SeatFeed` priced 0 until its first poke; deploy resume
compares every kept piece with the config; USDC/USDS feeds 25 h; malformed BATCH items refused at propose; seat-sale bad
debt covered in the same transaction; bounded way-back and remote clock in `SwarmFeed`; `RateFeed` high-water; instant
lowers that could raise refused; the way back after a silence bounded by 2x the cap from the last value as well as the
cap from the level (bounding it to values between the two instead locked out an honest fall for two hours); `Backstop.deposit` for others only into today's slot; `payNote` waits while bad debt is
booked and `retireReserve` keeps notes' face; ledger premium and risk-version lows; `SET_KEEPER`/`SET_BRIDGE` and a full
sleeve refused at propose; `SeatAccount.sync` refuses the seat and its join; two more approval selectors denied. New: the
rule-driven Allocator actions and the Safe as freezer from genesis. Each fix has a test named `AuditW1*` (the auditors'
proofs, adapted) or sits in the existing suites.

## Reporting findings

Report privately to **admin@imdusd.com**; do not open public issues. Include
the affected contract and function, the impact, and a Foundry test that reproduces it (the suites in `test/unit/` show
the set-up helpers in `test/utils/`).
