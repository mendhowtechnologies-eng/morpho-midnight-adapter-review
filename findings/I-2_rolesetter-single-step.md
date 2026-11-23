# WhitelistEnterSubGate role setter changes in a single step

**Severity:** Informational

## Summary

`setRoleSetter` hands a side's role-setter role to any address in one call ([WhitelistEnterSubGate.sol#L40-L44](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/gates/WhitelistEnterSubGate.sol#L40-L44)). A wrong address or `address(0)` loses that side permanently.

## Finding description

The credit-side role setter of the subgate is also the admin of every `IKRCompatibleEnterGate` that uses it: `IKRCompatibleEnterGate.roleSetter()` returns `IEnterSubGate(subGate).roleSetter(true)` ([IKRCompatibleEnterGate.sol#L27-L29](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/gates/IKRCompatibleEnterGate.sol#L27-L29)) and gates `addAdmitterFactory` ([#L32-L36](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/gates/IKRCompatibleEnterGate.sol#L32-L36)).

After a mistaken `setRoleSetter(true, wrong)`:
- nobody can grant or revoke credit-side whitelisters;
- nobody can register a new adapter factory on any IKR gate built on this subgate, so vaults whose adapters come from a new factory can never enter those markets with in-kind redemption guarantees.

## Impact

Operational, permanent loss of the whitelist and gate administration on one side. No direct loss of funds.

## Proof of concept

```
forge test --match-path test/poc/GateHardeningPoC.t.sol --match-test testRoleSetterSingleStepLosesControl -vv
```

The role setter moves to `0xdead`; the previous setter can no longer change it back or call `addAdmitterFactory` on the gate.

## Recommendation

Use a two-step transfer (`pendingRoleSetter` + `acceptRoleSetter`), or at least reject `address(0)`.
