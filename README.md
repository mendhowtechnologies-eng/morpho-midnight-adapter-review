# Morpho Midnight Adapter — independent security review

Review of the Morpho Vault V2 Midnight adapter at
[`morpho-org/vault-v2@bbeda7b2`](https://github.com/morpho-org/vault-v2/tree/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight)
(`src/adapters/midnight`, ~1,900 lines), done in November 2026.

**Result:** no High or Medium issue found. Three informational hardening notes, two with
runnable proofs. The rest of this repo is the evidence: what was tested, how, and why each
attack idea failed.

## Findings

| ID | Title | Severity | Proof |
|---|---|---|---|
| [I-1](findings/I-1_unadmit-access-control.md) | `IKRCompatibleEnterGate.unadmit()` can be called by anyone | Informational | `testAnyoneCanUnadmit` |
| [I-2](findings/I-2_rolesetter-single-step.md) | `WhitelistEnterSubGate` role setter changes in a single step | Informational | `testRoleSetterSingleStepLosesControl` |
| [I-3](findings/I-3_packeddurations-no-mask.md) | `PackedDurationsLib.pack` relies on callers to bound inputs | Informational | line reference |

None of them is exploitable with the reviewed code. The two gate contracts did not exist at the
commit covered by the earlier Cantina and TrustSec reviews (`6476e9d9`), so these are not repeats
of those reports.

## What the adapter promises, and what was checked

The review started from the guarantees stated in the adapter's NatSpec and README and tried to
break each one:

| # | Guarantee | How it was attacked |
|---|---|---|
| J1 | A shareholder can always redeem in kind (`forceDeallocate`) | every `require` on the path traced; fuzzed with live credit after losses |
| J2 | Compatible enter gates cannot block in-kind redemptions; admissions cannot be reused | gate built with an arbitrary sub-gate; adapter from the registered factory with a fake parent vault |
| J3 | `realAssets` never overstates the position; no share-price sandwich | same-block deposit / operation / redeem on the real VaultV2, up to `MAX_MAX_RATE` |
| J4 | A sale shortfall moves `realAssets` only by the proceeds | sequence fuzz with shortfall sales; sabotage check |
| J5 | Force-sellable sales are floored by `minForceSellPrice` and realise losses at once | fuzzed price floor, rates, allowance, book value |
| J6 | Duration caps hold against stored net credit | random buys and time skips vs. a direct recount |
| J7 | Timelocked settings cannot be bypassed | calldata keying, ABI decoding of `bytes4`, pending actions |
| J8–J11 | Roles, 250-market bound, ratifier binding, whitelist signatures | code review against each entry point |

## Attack ideas that were ruled out

Each was checked against the code at the reviewed commit:

1. `PackedDurationsLib.pack` without masking: the constructor bounds every duration to `uint32`.
2. Whitelist signature replay: an old nonce is accepted only as a no-op when the status already matches.
3. `forceDeallocate` with a market pointing at another Midnight: `Midnight.take` calls `touchMarket`, which requires `market.midnight == address(this)`.
4. Settlement-fee rounding gap on in-kind redemptions: the adapter and Midnight compute the same `ceil(units·fee/WAD)` in the same block.
5. `setConsumed(bytes32(0), max)` blocking in-kind redemptions: the forced sale is at tick 0, price 0, so it adds nothing to `consumed`.
6. Price ratifier: ratification is keyed by `(maker, root)`, and the leaf binds all 15 `Offer` fields plus the allowed taker.
7. Rate ratifier: the tick is deliberately free, the rate is bound and the price limit is checked at take time.
8. Reading live credit from a callback while the adapter buys: Midnight runs the buyer callback first; the sale lock covers the other direction.
9. Shortfall redistribution drift: bounded by `uint64` rate quantisation, about 3e-5 tokens for 1M tokens over a year.
10. A legitimate adapter with a fake parent vault abusing `admit`: the forced sale is reduce-only on that adapter's own credit, which it cannot obtain without passing the whitelist.
11. Permissionless `unadmit()` mid-take: only static calls run between `admit` and Midnight's gate check (kept as I-1, hardening only).
12. Timelock bypass: execution is keyed on exact calldata; same design as VaultV2.
13. Collateral ordering or duplicates splitting family caps: Midnight requires strictly increasing collateral tokens.
14. Withdrawals after maturity: Midnight sends exactly `units`; the vault pulls exactly that.
15. Fixes for earlier findings (round-trip loss hidden by rate blending, reusable forced-sale offer, missing timelocks, cap checks, foreign ratifiers): all closed in the current design.
16. Zero-value transfer on the price-0 forced sale: excluded by VaultV2's token requirements.

## Machine checks

All tests reuse Morpho's own fixtures (`test/MidnightAdapterTest.sol`).

| File | What it does |
|---|---|
| `SequenceFuzz.t.sol` | random sequences of buys, sales, shortfall sales, in-kind redemptions, syncs, time skips and permissionless bad debt over three markets; 5,000 sequences pass |
| `RealVaultSandwich.t.sol` | same-block sandwich of sales and in-kind redemptions on the real VaultV2; the attacker never ends ahead, even at `MAX_MAX_RATE` |
| `ForceAndCapsFuzz.t.sol` | force-sellable floor and rate behaviour, force removal, duration-cap accounting |
| `GateHardeningPoC.t.sol` | proofs for I-1 and I-2 |

The fuzz harness was validated by sabotage: with the adapter deliberately broken (in-kind
bookkeeping halved, shortfall absorption disabled), the suite fails. A harness that cannot fail
proves nothing.

## Running

```sh
git clone https://github.com/morpho-org/vault-v2 && cd vault-v2
git checkout bbeda7b27ae80abcf070e0158cb8a31e87bb2286
git submodule update --init --recursive
cp -r /path/to/this/repo/test/poc test/
forge build
FOUNDRY_FUZZ_RUNS=3000 forge test --match-path "test/poc/*" \
  --match-test "testFuzzSequence|testSequenceCoverage|testFuzzSandwich|testFuzzGainSale|testGainSaleWithMaxRate|testFuzzForce|testFuzzDurationCaps|testDurationCapsCoverage|testAnyoneCanUnadmit|testRoleSetter"
```

Use `--match-test`: the test contracts inherit Morpho's suite, and one inherited test needs
its `isolate = false` annotation, which does not carry over to child contracts.

## License

GPL-2.0-or-later, matching the Morpho test fixtures these tests build on.
