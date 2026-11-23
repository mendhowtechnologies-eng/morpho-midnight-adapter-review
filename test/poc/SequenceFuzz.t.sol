// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../MidnightAdapterTest.sol";

/// @notice Random sequences of buys, adapter sales (with and without shortfall),
///         in-kind redemptions, syncs and time skips over three markets, with
///         system-level checks after every successful step:
///           C1 book value never exceeds face value (realAssets <= sum of stored net credit)
///           C2 market index bookkeeping stays consistent
///           C3 an in-kind redemption never lowers the vault's total value (idle + realAssets)
///           C4 a sale never lowers the vault's total value beyond the documented rate rounding
///           C5 time passing never lowers realAssets without a loss
contract SequenceFuzzTest is MidnightAdapterTest {
    using MathLib for uint256;

    Offer[3] internal seqOffers;
    uint256 internal okSkip;
    uint256 internal okIkr;
    uint256 internal okSale;
    uint256 internal okShortfallSale;
    uint256 internal okSync;
    uint256 internal okBadDebt;
    uint256 internal okBuy;

    function _vaultTotal() internal view returns (uint256) {
        return loanToken.balanceOf(address(parentVault)) + adapter.realAssets();
    }

    /// @dev Documented tolerance from rate quantisation: sum over markets of credit * ttm / WAD, plus a few wei each.
    function _rateTolerance() internal view returns (uint256 tol) {
        uint256 n = adapter.marketIdsLength();
        for (uint256 i; i < n; i++) {
            MarketData memory d = adapter.marketData(adapter.marketIds(i));
            uint256 ttm = uint256(d.maturity) > block.timestamp ? d.maturity - block.timestamp : 0;
            tol += uint256(d.netCredit) * ttm / WAD + 3;
        }
    }

    function _checkBookAndIndex() internal view {
        uint256 n = adapter.marketIdsLength();
        uint256 face;
        for (uint256 i; i < n; i++) {
            bytes32 id = adapter.marketIds(i);
            MarketData memory d = adapter.marketData(id);
            assertEq(d.index, i, "C2 index");
            assertGt(d.netCredit, 0, "C2 active market has credit");
            face += d.netCredit;
        }
        assertLe(adapter.realAssets(), face, "C1 book value above face value");
    }

    function trySellExt(Offer memory offer) external {
        this.takeWithAccrual(offer, "", taker, address(0));
    }

    function testFuzzSequence(uint256 seed) public {
        _runSequence(seed);
    }

    /// @dev Coverage guard: the checks must actually be exercised, not swallowed by reverts.
    function testSequenceCoverage() public {
        uint256[7] memory total;
        for (uint256 s = 1; s <= 12; s++) {
            uint256 snap = vm.snapshotState();
            _runSequence(s);
            // revertToState also resets this contract's storage, so bank the counts first.
            total[0] += okSkip;
            total[1] += okIkr;
            total[2] += okSale;
            total[3] += okShortfallSale;
            total[4] += okSync;
            total[5] += okBadDebt;
            total[6] += okBuy;
            vm.revertToState(snap);
        }
        emit log_named_uint("skips", total[0]);
        emit log_named_uint("in-kind redemptions", total[1]);
        emit log_named_uint("sales", total[2]);
        emit log_named_uint("shortfall sales", total[3]);
        emit log_named_uint("syncs", total[4]);
        emit log_named_uint("bad debt events", total[5]);
        emit log_named_uint("mid-sequence buys", total[6]);
        assertGt(total[6], 0, "no mid-sequence buy exercised");
        assertGt(total[1], 0, "no in-kind redemption exercised");
        assertGt(total[2], 0, "no sale exercised");
        assertGt(total[3], 0, "no shortfall sale exercised");
    }

    function _runSequence(uint256 seed) internal {
        deal(address(loanToken), address(parentVault), 10_000_000e18);
        deal(address(loanToken), taker, 10_000_000e18);
        deal(address(loanToken), address(this), 10_000_000e18);
        deal(storedCollaterals[0].token, taker, 10_000_000e18);
        deal(storedCollaterals[1].token, taker, 10_000_000e18);
        // supplyCollateral pulls from the caller (this contract), on behalf of the taker.
        deal(storedCollaterals[0].token, address(this), 10_000_000e18);
        deal(storedCollaterals[1].token, address(this), 10_000_000e18);

        uint256[3] memory durs = [uint256(7 days), 30 days, 90 days];
        for (uint256 i; i < 3; i++) {
            uint256 units = bound(uint256(keccak256(abi.encode(seed, "units", i))), 1e18, 1_000_000e18);
            seqOffers[i] = buyAtDiscount(durs[i], units);
        }
        _checkBookAndIndex();

        for (uint256 step; step < 10; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            Market memory market = seqOffers[(r >> 8) % 3].market;
            MarketData memory d = adapter.marketData(_marketId(market));

            if (op == 0) {
                uint256 before = adapter.realAssets();
                skip(bound(r >> 16, 1 hours, 10 days));
                assertGe(adapter.realAssets(), before, "C5 realAssets fell with time");
                okSkip++;
            } else if (op == 1) {
                if (d.netCredit == 0) continue;
                // Bound by the adapter's actual (post-loss) credit on Midnight, not the stored value.
                (uint128 liveCredit,,) = midnight.updatePositionView(market, _marketId(market), address(adapter));
                if (liveCredit == 0) continue;
                uint256 assets = bound(r >> 16, 1, liveCredit);
                uint256 totalBefore = _vaultTotal();
                // J1: with assets <= stored net credit and a funded, authorized taker, IKR must not revert.
                try parentVault.forceDeallocate(address(adapter), abi.encode(market, address(this)), assets, address(this)) {
                    assertGe(_vaultTotal(), totalBefore, "C3 in-kind redemption lowered vault value");
                    okIkr++;
                } catch (bytes memory reason) {
                    emit log_named_bytes("IKR revert reason", reason);
                    emit log_named_uint("assets", assets);
                    emit log_named_uint("stored net credit", d.netCredit);
                    emit log_named_uint("ttm", market.maturity > block.timestamp ? market.maturity - block.timestamp : 0);
                    fail("J1 in-kind redemption blocked");
                }
            } else if (op == 2) {
                if (d.netCredit == 0 || block.timestamp >= market.maturity) continue;
                (uint128 liveCredit,,) = midnight.updatePositionView(market, _marketId(market), address(adapter));
                if (liveCredit == 0) continue;
                uint256 units = bound(r >> 16, 1, liveCredit);
                uint256[3] memory ticks = [MAX_TICK / 2, MAX_TICK * 3 / 4, MAX_TICK];
                Offer memory offer = makeSellOffer(market, units, ticks[(r >> 40) % 3]);
                uint256 totalBefore = _vaultTotal();
                uint256 tol = _rateTolerance();
                uint256 allowanceBefore = adapter.shortfallAllowance();
                try this.trySellExt(offer) {
                    okSale++;
                    if (adapter.shortfallAllowance() < allowanceBefore) okShortfallSale++;
                    assertGe(_vaultTotal() + tol, totalBefore, "C4 sale lowered vault value beyond rounding");
                } catch {}
            } else if (op == 5) {
                // Additional buy mid-sequence (possibly after an unsynced loss).
                if (block.timestamp + 1 >= market.maturity) continue;
                uint256 buyAssets = bound(r >> 16, 1e15, 200_000e18);
                uint256 totalBefore = _vaultTotal();
                try this.buyAdditionalExt(market, buyAssets) {
                    okBuy++;
                    // A buy swaps idle assets for credit at the paid price: vault value must not drop beyond rate rounding.
                    assertGe(_vaultTotal() + _rateTolerance(), totalBefore, "C6 buy lowered vault value beyond rounding");
                } catch {}
            } else if (op == 4) {
                // Permissionless loss: crash collateral prices, liquidate the borrower into bad debt, restore prices.
                if (d.netCredit == 0) continue;
                uint256 crash = bound(r >> 16, 2, 8);
                OracleMock(storedCollaterals[0].oracle).setPrice(ORACLE_PRICE_SCALE / crash);
                OracleMock(storedCollaterals[1].oracle).setPrice(ORACLE_PRICE_SCALE / crash);
                try this.liquidateExt(market) {
                    okBadDebt++;
                } catch {}
                OracleMock(storedCollaterals[0].oracle).setPrice(ORACLE_PRICE_SCALE);
                OracleMock(storedCollaterals[1].oracle).setPrice(ORACLE_PRICE_SCALE);
            } else {
                if (d.netCredit == 0) continue;
                try this.withdrawToVaultExt(market) {
                    okSync++;
                } catch {}
            }
            _checkBookAndIndex();
        }
    }

    function buyAdditionalExt(Market memory market, uint256 assets) external {
        buyAdditionalCredit(market, assets);
    }

    function liquidateExt(Market memory market) external {
        midnight.liquidate(market, 0, 0, 0, taker, false, address(this), address(0), "");
    }

    function withdrawToVaultExt(Market memory market) external {
        withdrawToVault(market, 0);
    }
}
