# Zia RH Hook

Isolated Foundry project for `ZiaFeeHook`, a Uniswap v4 dynamic-fee hook intended for Robinhood Chain (chain ID 4663).

Status: candidate code only. It has not been deployed. This README describes behavior and test evidence; it does not assert that a security assessment has been completed.

## Canonical dependency

The deployment script only permits Robinhood Chain and hardcodes the canonical PoolManager:

`0x8366a39CC670B4001A1121B8F6A443A643e40951`

Compiler and optimizer settings are pinned in `foundry.toml`. Dependency revisions are recorded in `DEPENDENCIES.md`.

## Contract scope

`src/ZiaFeeHook.sol` is the only application contract in this project. It is non-upgradeable and has no owner, proxy, pause, rescue function, or arbitrary call path. It accepts no custom fee data from swaps.

It has two immutable operational addresses:

- `keeper`: updates bounded, per-pool fee parameters;
- `treasury`: receives collected underlying fee assets.

Neither address can be changed after deployment.

The hook declares exactly three permissions:

| Bit | Permission | Value |
| ---: | --- | ---: |
| 13 | `BEFORE_INITIALIZE_FLAG` | `0x2000` |
| 7 | `BEFORE_SWAP_FLAG` | `0x0080` |
| 3 | `BEFORE_SWAP_RETURNS_DELTA_FLAG` | `0x0008` |

The complete low-14-bit mask is `0x2088`; every other permission bit is zero.

## Pool initialization and configuration

Pool creation is permissionless. `beforeInitialize` accepts only a PoolKey whose fee is the dynamic-fee sentinel `0x800000`. Configuration is keyed by canonical `PoolId`.

| Parameter | Default | Hard maximum | Units |
| --- | ---: | ---: | --- |
| LP fee | `2_500` (0.25%) | `10_000` (1.00%) | denominator `1_000_000` |
| Hook fee | `5` (0.05%) | `25` (0.25%) | basis points; denominator `10_000` |

The keeper has only two privileged entrypoints:

- `setLpFee(poolId, fee)`: bounds check, storage write, event;
- `setHookFee(poolId, bps)`: bounds check, storage write, event.

Unknown pools and values above the hardcoded ceilings revert.

## Specified-currency fee math

For either swap type:

```text
specifiedAmount = abs(amountSpecified)
hookFee = floor(specifiedAmount * hookFeeBps / 10_000)
```

`FullMath.mulDiv` provides full-precision multiplication with downward rounding. If the configured rate or computed fee is zero, the hook returns zero delta and does not call `take(0)`.

| Swap | Direction | Fee currency |
| --- | --- | --- |
| exact input | currency0 → currency1 | currency0 input |
| exact input | currency1 → currency0 | currency1 input |
| exact output | currency0 → currency1 | currency1 output |
| exact output | currency1 → currency0 | currency0 output |

### Exact input

For a specified input of `S` and fee `F`, the hook returns positive specified delta `F`. Pool math receives `S - F`; the trader settles `S`; and the hook mints `F` input-currency ERC-6909 claims.

### Exact output

For requested output `S` and fee `F`, the hook returns positive specified delta `F`. Pool math produces `S + F`; the trader receives `S`; and the hook mints `F` output-currency ERC-6909 claims.

Exact-output fees are intentionally denominated on requested output, not realized input. There is no nested swap, self-call, price conversion, partial-fill reconciliation, or cross-swap scratch state.

The implementation verifies the relevant signed-128-bit bounds before returning `BeforeSwapDelta`.

## LP fee override: no synchronization

The hook never calls `updateDynamicLPFee`.

- `beforeInitialize` records the configured default.
- `setLpFee` changes only hook storage.
- Every `beforeSwap` returns `config.lpFee | OVERRIDE_FEE_FLAG`.
- A keeper update therefore takes effect on the next swap without an external synchronization call.
- PoolManager's stored dynamic fee can remain zero and is not the effective fee source for these pools.

Integrators should read `poolConfigs(poolId)` or use a quote path that executes the hook callback rather than treating PoolManager slot state as the active LP fee.

## Fee collection

Hook fees initially exist as PoolManager ERC-6909 claims owned by the hook. `collectFees(currency)` is permissionless, but its recipient is fixed:

1. Read the hook's full claim balance for the currency.
2. Return `0` silently when the balance is zero—no unlock and no event.
3. Mark collection active and call `PoolManager.unlock`.
4. In the PoolManager-only callback, burn the claims to create a positive transient delta.
5. Take the same amount of real ERC-20 or native currency directly to immutable treasury.
6. Return with zero transient delta, clear the active marker, and emit `FeesCollected`.

Treasury receives underlying assets, never claim tokens. A caller cannot select the amount or recipient.

If treasury is a contract and native-currency pools are supported, treasury must accept a plain native transfer. An EOA satisfies this requirement; a contract treasury must be checked before its immutable address is used for salt mining.

Claims aggregate by currency. Two pools charging the same currency contribute to one hook-owned ERC-6909 balance, while their configuration remains isolated by `PoolId`.

## Callback and reentrancy controls

- `BaseHook` gates `beforeInitialize` and `beforeSwap` to the immutable PoolManager.
- `unlockCallback` is also gated to PoolManager and delegates to a private implementation.
- The private implementation additionally requires an active `collectFees` operation.
- Reentrant collection is rejected by `CollectionInProgress`.
- PoolManager itself rejects starting a second unlock while already unlocked, so collection cannot interleave with a swap unlock.
- State is set before the external unlock and cleared after return. Any failure atomically restores state and claims.
- Swap callbacks make no token calls and no nested swaps.

The project uses the two-stage external-gate/internal-callback structure of `SafeCallback` directly. The vendored `BaseHook` and `SafeCallback` both declare `poolManager` and `onlyPoolManager`, so inheriting both would create conflicting base members.

## Events

- `ZiaPoolInitialized(poolId, currency0, currency1, tickSpacing, sqrtPriceX96)`
- `LPFeeChanged(poolId, oldFee, newFee)`
- `HookFeeChanged(poolId, oldFeeBps, newFeeBps)`
- `FeesCollected(currency, amount)` for nonzero collection only

## Trust assumptions and failure cases

| Actor or condition | Effect | Bound or response |
| --- | --- | --- |
| Compromised keeper | Can reorder and change per-pool fees | Immutable role; 1.00% LP and 0.25% hook ceilings; change events. Quotes may still become stale. |
| Arbitrary pool creator | Can initialize any dynamic PoolKey using this hook | Intended; configuration is keyed by PoolId. Asset selection remains an integration concern. |
| Arbitrary collector | Can trigger redemption | Full balance can only reach immutable treasury. |
| Reentrant treasury/token | Can execute code during underlying transfer | Active guard rejects another collection; PoolManager gate rejects direct callback; failed transfers revert atomically. |
| Non-standard token | Can alter transfer or balance semantics | Not explicitly supported. Asset allowlisting belongs outside this hook. |
| PoolManager failure or incompatibility | Can invalidate delta, override, claim, or unlock assumptions | Canonical PoolManager address and deployed code are critical dependencies. Record its codehash before deployment. |
| Treasury cannot receive native currency | Native collection reverts | Validate treasury receipt behavior before fixing immutable constructor arguments. |
| Contract defect | Cannot be paused or upgraded | Exclude the hook from routing and migrate to new pools under a separate replacement hook. |

## Project layout

```text
src/ZiaFeeHook.sol
test/ZiaFeeHook.t.sol
test/ZiaFeeHookFork.t.sol
test/utils/
script/MineZiaFeeHookAddress.s.sol
script/DeployZiaFeeHook.s.sol
DEPENDENCIES.md
foundry.toml
remappings.txt
```

The tests cover:

- exact input and exact output in both directions, including fee currency;
- zero-rate and rounding-to-zero dust paths;
- maximum fee configuration and mid-lifecycle updates;
- next-swap LP override behavior with no PoolManager fee synchronization;
- two-pool configuration and distinct-currency accounting isolation;
- keeper access control and both ceilings;
- ERC-20 and native claim redemption, silent zero collection, and callback reentrancy attempts;
- permission/address-bit equality, callback gates, initialization requirements, amount bounds, and fuzzed amounts;
- a Robinhood Chain fork using the canonical PoolManager and PositionManager.

Run locally:

```sh
forge fmt --check
forge build --sizes
forge lint
forge test
forge coverage --match-contract ZiaFeeHookTest --report summary
```

Run the live-state fork test without broadcasting:

```sh
RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-contract ZiaFeeHookForkTest -vv
```

Verified results for this isolated package:

| Check | Result |
| --- | --- |
| Local suite | 25 passed, 0 failed; fork test skipped when `RH_RPC_URL` is absent |
| Robinhood Chain fork | 1 passed, 0 failed against the canonical live-state deployments |
| `ZiaFeeHook.sol` coverage | 100% lines (71/71), statements (86/86), branches (21/21), functions (11/11) |
| Lint | clean |
| Optimized size | 7,853-byte runtime; 8,905-byte initcode |
| Deployment-script simulation | passed on a chain-4663 fork; no broadcast |

## CREATE2 mining and deployment script

The final salt depends on both immutable addresses. The read-only miner requires approved `TREASURY` and `KEEPER` values:

```sh
TREASURY=0x... KEEPER=0x... \
  forge script script/MineZiaFeeHookAddress.s.sol:MineZiaFeeHookAddressScript
```

`DeployZiaFeeHook.s.sol` checks chain ID 4663, canonical PoolManager code, CREATE2 factory code, nonzero immutable addresses, and an unused predicted address. Before `startBroadcast`, it reconstructs all 14 flags from `getHookPermissions()` and requires exact equality with both `0x2088` and the predicted address bits. It repeats the permission and address checks after construction.

The script is present for review and simulation. Do not add `--broadcast` until final addresses, dependency revisions, source, compiler settings, and bytecode have been independently approved.

No Robinhood Chain transaction has been sent from this project.
