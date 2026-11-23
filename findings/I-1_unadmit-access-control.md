# IKRCompatibleEnterGate.unadmit() can be called by anyone

**Severity:** Informational

## Summary

`unadmit()` clears the transient admission with no check on the caller. Correctness of the in-kind redemption flow currently rests on call ordering (no third-party execution between `admit` and Midnight's `canIncreaseCredit` check), not on the gate itself.

## Finding description

`admit` is restricted to adapters from a registered factory ([IKRCompatibleEnterGate.sol#L40-L47](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/gates/IKRCompatibleEnterGate.sol#L40-L47)), but `unadmit` is open ([#L51-L53](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/gates/IKRCompatibleEnterGate.sol#L51-L53)):

```solidity
function unadmit() external {
    admitted = address(0);
}
```

`admitted` is a single transient slot shared by every market (on any Midnight) that uses the gate. Any contract that gets execution inside the same transaction, after `admit` and before Midnight checks `canIncreaseCredit(buyer)`, can clear it and make the in-kind redemption revert with `BuyerGatedFromIncreasingCredit`.

In the current MidnightAdapter flow ([MidnightAdapter.sol#L462](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/MidnightAdapter.sol#L462) then `Midnight.take`) the only external calls in that window are static: `IRatifier.isRatified` and `IEnterGate.canIncreaseCredit` are `view` (the ratifier is the adapter itself and returns early during forceDeallocate), and `_updatePosition` makes no external call. A static call cannot write transient storage, and the buyer callback that runs afterwards is the adapter. So this is not exploitable today. The gate, however, is a standalone contract meant to be reused by other registered factories ("Registered adapter factories are trusted …"), and its safety then depends on every future admitter keeping that window closed.

## Impact

None with the audited adapter. Defense in depth: a future registered adapter, or a gate change that adds a hook, would let an unrelated contract block in-kind redemptions in all markets using the gate for that transaction.

## Proof of concept

`test/poc/GateHardeningPoC.t.sol` (run from the repo root at the audited commit):

```
forge test --match-path test/poc/GateHardeningPoC.t.sol --match-test testAnyoneCanUnadmit -vv
```

A registered adapter admits a shareholder; an unrelated contract then calls `unadmit()` in the same call frame and `canIncreaseCredit(shareholder)` flips from `true` to `false`.

## Recommendation

Record the admitter and require it on `unadmit`:

```solidity
address transient admitted;
address transient admitter;

function admit(address user, address adapterFactory) external {
    // existing checks
    admitted = user;
    admitter = msg.sender;
}

function unadmit() external {
    require(msg.sender == admitter, Unauthorized());
    admitted = address(0);
    admitter = address(0);
}
```
