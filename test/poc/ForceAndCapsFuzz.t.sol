// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../MidnightAdapterTest.sol";

/// @notice J5 (force-sellable), force-remove and J6 (duration caps), on the mock vault fixture.
contract ForceAndCapsFuzzTest is MidnightAdapterTest {
    using MathLib for uint256;

    Offer[3] internal fo;
    uint256 internal okTotal;

    function _fund() internal {
        deal(address(loanToken), address(parentVault), 10_000_000e18);
        deal(address(loanToken), taker, 10_000_000e18);
        deal(storedCollaterals[0].token, address(this), 10_000_000e18);
        deal(storedCollaterals[1].token, address(this), 10_000_000e18);
    }

    function _book(bytes32 id) internal view returns (uint256) {
        MarketData memory d = adapter.marketData(id);
        uint256 ttm = uint256(d.maturity) > block.timestamp ? d.maturity - block.timestamp : 0;
        return uint256(d.netCredit) * WAD / (WAD + uint256(d.netRate) * ttm);
    }

    function sellExt(Offer memory offer) external {
        this.takeWithAccrual(offer, "", taker, address(0));
    }

    function buyExt(Market memory market, uint256 assets) external {
        buyAdditionalCredit(market, assets);
    }

    // ------------------------------------------------------------ J5 force-sellable

    function testFuzzForceSellable(uint256 seed, uint256 minPrice, uint256 sold, uint256 tickChoice) public {
        _fund();
        uint256[3] memory durs = [uint256(7 days), 30 days, 90 days];
        for (uint256 i; i < 3; i++) {
            fo[i] = buyAtDiscount(durs[i], bound(uint256(keccak256(abi.encode(seed, i))), 1e18, 1_000_000e18));
        }
        skip(bound(seed >> 200, 1 hours, 6 days));
        uint256 k = seed % 3;
        bytes32 id = _marketId(fo[k].market);
        setForceSellable(id);
        minPrice = bound(minPrice, 0, WAD);
        setMinForceSellPrice(id, minPrice);

        // Buys are disabled in a force-sellable market.
        vm.expectRevert();
        this.buyExt(fo[k].market, 1e18);

        uint64[3] memory ratesBefore;
        for (uint256 i; i < 3; i++) ratesBefore[i] = adapter.marketData(_marketId(fo[i].market)).netRate;
        uint256 allowanceBefore = adapter.shortfallAllowance();
        uint256 realBefore = adapter.realAssets();
        uint256 bookBefore = _book(id);
        uint256 idleBefore = loanToken.balanceOf(address(parentVault));

        uint256 credit = adapter.marketData(id).netCredit;
        sold = bound(sold, 1, credit);
        uint256[4] memory ticks = [
            uint256(0),
            TickLib.priceToTick(0.3e18, DEFAULT_TICK_SPACING),
            TickLib.priceToTick(0.8e18, DEFAULT_TICK_SPACING),
            MAX_TICK
        ];
        Offer memory offer = makeSellOffer(fo[k].market, sold, ticks[tickChoice % 4]);
        try this.sellExt(offer) {
            uint256 proceeds = loanToken.balanceOf(address(parentVault)) - idleBefore;
            // Price floor holds on actual proceeds.
            assertGe(proceeds, sold.mulDivUp(minPrice, WAD), "J5 sold below minForceSellPrice");
            // No rate cut anywhere, no shortfall allowance consumed: loss is realized immediately.
            for (uint256 i; i < 3; i++) {
                MarketData memory di = adapter.marketData(_marketId(fo[i].market));
                // A fully exited market is removed and its rate reset; only live markets keep their rate.
                if (di.netCredit == 0) continue;
                assertEq(di.netRate, ratesBefore[i], "J5 rate changed");
            }
            assertEq(adapter.shortfallAllowance(), allowanceBefore, "J5 consumed shortfall allowance");
            // realAssets drops by exactly the book value removed from this market (rounding <= 2 wei).
            uint256 removed = bookBefore - _book(id);
            assertApproxEqAbs(realBefore - adapter.realAssets(), removed, 2, "J5 realAssets mismatch");
        } catch (bytes memory reason) {
            // Only allowed failure: price below the floor.
            assertEq(bytes4(reason), IMidnightAdapterBase.ForceSellPriceTooLow.selector, "J5 unexpected revert");
        }
    }

    // ------------------------------------------------------------ force-remove

    function testFuzzForceRemove(uint256 seed) public {
        _fund();
        uint256[3] memory durs = [uint256(7 days), 30 days, 90 days];
        for (uint256 i; i < 3; i++) {
            fo[i] = buyAtDiscount(durs[i], bound(uint256(keccak256(abi.encode(seed, i))), 1e18, 1_000_000e18));
        }
        skip(bound(seed >> 200, 1 hours, 6 days));
        uint256 k = seed % 3;
        bytes32 id = _marketId(fo[k].market);
        uint256 realBefore = adapter.realAssets();
        uint256 bookK = _book(id);
        (uint128 creditBefore,,) = midnight.updatePositionView(fo[k].market, id, address(adapter));

        forceRemove(id);

        assertApproxEqAbs(realBefore - adapter.realAssets(), bookK, 1, "removed book value");
        assertEq(adapter.marketIdsLength(), 2, "two markets left");
        for (uint256 i; i < adapter.marketIdsLength(); i++) {
            bytes32 other = adapter.marketIds(i);
            assertTrue(other != id, "removed id still tracked");
            assertEq(adapter.marketData(other).index, i, "index consistent");
        }
        (uint128 creditAfter,,) = midnight.updatePositionView(fo[k].market, id, address(adapter));
        assertEq(creditAfter, creditBefore, "Midnight credit untouched");

        vm.expectRevert(IMidnightAdapterBase.ForceRemoved.selector);
        this.buyExt(fo[k].market, 1e18);
        vm.expectRevert();
        this.sellExt(makeSellOffer(fo[k].market, 1, MAX_TICK));
        vm.expectRevert(IMidnightAdapterBase.ForceRemoved.selector);
        forceDeallocate(fo[k].market, 1);
    }

    // ------------------------------------------------------------ J6 duration caps

    function _expectedDurationAllocations() internal view returns (uint256[] memory a) {
        a = new uint256[](allDurations.length);
        for (uint256 m; m < adapter.marketIdsLength(); m++) {
            MarketData memory d = adapter.marketData(adapter.marketIds(m));
            uint256 ttm = uint256(d.maturity) > block.timestamp ? d.maturity - block.timestamp : 0;
            for (uint256 i; i < allDurations.length; i++) {
                if (ttm >= allDurations[i]) a[i] += d.netCredit;
            }
        }
    }

    function testFuzzDurationCaps(uint256 seed) public {
        _fund();
        uint256[] memory caps = new uint256[](allDurations.length);
        for (uint256 i; i < allDurations.length; i++) {
            caps[i] = bound(uint256(keccak256(abi.encode(seed, "cap", i))), 200_000e18, 3_000_000e18);
            VaultV2Mock(address(parentVault)).setAbsoluteCap(keccak256(durationIdData(adapter, allDurations[i])), caps[i]);
        }
        uint256 ok;
        for (uint256 step; step < 12; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            if (r % 3 == 0) {
                skip(bound(r >> 8, 1 hours, 20 days));
            } else {
                uint256 dur = bound(r >> 8, 2 hours, 200 days);
                uint256 assets = bound(r >> 64, 1e18, 300_000e18);
                Offer memory offer = makeBuyOffer(dur, assets, discountTick);
                midnight.supplyCollateral(offer.market, 0, offer.maxUnits, taker);
                midnight.supplyCollateral(offer.market, 1, offer.maxUnits, taker);
                try this.takeWithAccrual(offer, "", taker, address(0)) {
                    ok++;
                } catch (bytes memory reason) {
                    // Only cap rejections are acceptable here.
                    bytes4 sel = bytes4(reason);
                    assertTrue(
                        sel == IMidnightAdapterBase.DurationAbsoluteCapExceeded.selector
                            || sel == IMidnightAdapterBase.DurationRelativeCapExceeded.selector,
                        "J6 unexpected buy revert"
                    );
                }
            }
            uint256[] memory got = adapter.durationAllocations(allDurations.length);
            uint256[] memory exp = _expectedDurationAllocations();
            for (uint256 i; i < allDurations.length; i++) {
                assertEq(got[i], exp[i], "J6 durationAllocations differs from direct recount");
                assertLe(got[i], caps[i], "J6 duration absolute cap exceeded");
            }
        }
        emit log_named_uint("successful buys", ok);
        okTotal += ok;
    }

    function testDurationCapsCoverage() public {
        uint256 total;
        for (uint256 s = 1; s <= 10; s++) {
            uint256 snap = vm.snapshotState();
            testFuzzDurationCaps(s);
            total += okTotal;
            vm.revertToState(snap);
        }
        emit log_named_uint("total successful buys over 10 seeds", total);
        assertGt(total, 20, "duration-cap fuzz barely buys");
    }
}
