# PackedDurationsLib.pack relies on callers to bound inputs

**Severity:** Informational

## Summary

`pack` ORs `durations[i] << (32 * i)` without masking to 32 bits ([PackedDurationsLib.sol#L24-L30](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/libraries/PackedDurationsLib.sol#L24-L30)). A value at or above 2^32 bleeds into the next slot and silently corrupts the packed durations.

## Finding description

The only caller today, the MidnightAdapter constructor, enforces `_durations[i] <= type(uint32).max` ([MidnightAdapter.sol#L165](https://github.com/morpho-org/vault-v2/blob/bbeda7b27ae80abcf070e0158cb8a31e87bb2286/src/adapters/midnight/MidnightAdapter.sol#L165)), so the audited adapter is safe. The library documents the assumption but does not enforce it, which is a trap for reuse.

## Impact

None in the audited code.

## Recommendation

Mask (`uint32(durations[i])`) or `require(durations[i] <= type(uint32).max)` inside `pack`.
