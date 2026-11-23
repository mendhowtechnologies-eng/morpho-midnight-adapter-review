// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../MidnightAdapterTest.sol";

/// @notice J3 check on the real VaultV2: a depositor who enters right before an
///         adapter operation and exits right after it, in the same block, must not
///         profit. Operations: a sale above book value (gain), a sale below book
///         value (shortfall absorbed by rate cuts), and an in-kind redemption.
contract RealVaultSandwichTest is MidnightAdapterTest {
    using MathLib for uint256;

    address internal jit = makeAddr("jit");

    function _setup(uint256 seed) internal returns (Offer[3] memory offers) {
        setUpRealVault();
        address lp = makeAddr("lp");
        deal(address(loanToken), lp, 3_000_000e18);
        vm.startPrank(lp);
        SafeERC20Lib.safeApprove(address(loanToken), address(realVault), type(uint256).max);
        realVault.deposit(3_000_000e18, lp);
        vm.stopPrank();

        deal(storedCollaterals[0].token, address(this), 10_000_000e18);
        deal(storedCollaterals[1].token, address(this), 10_000_000e18);
        deal(address(loanToken), taker, 10_000_000e18);
        deal(address(loanToken), address(this), 10_000_000e18);
        // The IKR caller pays the vault's forceDeallocate penalty in shares.
        realVault.deposit(2_000_000e18, address(this));

        uint256[3] memory durs = [uint256(7 days), 30 days, 90 days];
        for (uint256 i; i < 3; i++) {
            uint256 assets = bound(uint256(keccak256(abi.encode(seed, i))), 10e18, 500_000e18);
            offers[i] = _buyWellCollateralized(durs[i], assets);
        }
        skip(bound(seed >> 128, 1 hours, 5 days));
        realVault.accrueInterest();

        deal(address(loanToken), jit, 1_000_000e18);
        vm.prank(jit);
        SafeERC20Lib.safeApprove(address(loanToken), address(realVault), type(uint256).max);
    }

    /// @dev Same as buyOnRealVault but with 2x collateral so the borrower stays healthy for any size.
    function _buyWellCollateralized(uint256 duration, uint256 assets) internal returns (Offer memory offer) {
        offer = makeBuyOffer(duration, assets, MAX_TICK);
        offer.maker = address(adapter);
        offer.callback = address(adapter);
        offer.ratifier = address(adapter);
        midnight.supplyCollateral(offer.market, 0, assets, taker);
        midnight.supplyCollateral(offer.market, 1, assets, taker);
        take(offer);
    }

    function _jitIn(uint256 amount) internal returns (uint256 shares) {
        vm.prank(jit);
        shares = realVault.deposit(amount, jit);
    }

    function _jitOut(uint256 shares) internal returns (uint256 assets) {
        vm.prank(jit);
        assets = realVault.redeem(shares, jit, jit);
    }

    /// forge-config: default.isolate = true
    function testFuzzSandwichSale(uint256 seed, uint256 jitAmount, uint256 tickChoice) public {
        Offer[3] memory offers = _setup(seed);
        jitAmount = bound(jitAmount, 1e18, 1_000_000e18);
        Market memory market = offers[seed % 3].market;
        uint256 credit = adapter.marketData(_marketId(market)).netCredit;
        uint256 units = bound(seed >> 64, credit / 100 + 1, credit);
        uint256[3] memory ticks = [MAX_TICK / 2, MAX_TICK * 9 / 10, MAX_TICK];

        uint256 shares = _jitIn(jitAmount);
        Offer memory offer = makeSellOffer(market, units, ticks[tickChoice % 3]);
        try this.takeWithAccrual(offer, "", taker, address(0)) {} catch {}
        uint256 out = _jitOut(shares);

        assertLe(out, jitAmount, "J3 depositor profited from sandwiching a sale");
    }

    /// forge-config: default.isolate = true
    function testFuzzSandwichInKind(uint256 seed, uint256 jitAmount, uint256 ikrFraction) public {
        Offer[3] memory offers = _setup(seed);
        jitAmount = bound(jitAmount, 1e18, 1_000_000e18);
        Market memory market = offers[seed % 3].market;
        uint256 credit = adapter.marketData(_marketId(market)).netCredit;
        uint256 assets = bound(ikrFraction, 1, credit / 10 + 1);

        uint256 shares = _jitIn(jitAmount);
        forceDeallocateOnRealVault(market, assets);
        uint256 out = _jitOut(shares);

        assertLe(out, jitAmount, "J3 depositor profited from sandwiching an in-kind redemption");
    }

    /// @dev Coverage: a sale above book value must actually execute (no try/catch).
    /// forge-config: default.isolate = true
    function testFuzzGainSaleExecutes(uint256 seed, uint256 jitAmount) public {
        Offer[3] memory offers = _setup(seed);
        jitAmount = bound(jitAmount, 1e18, 1_000_000e18);
        Market memory market = offers[seed % 3].market;
        uint256 credit = adapter.marketData(_marketId(market)).netCredit;
        uint256 units = bound(seed >> 64, credit / 100 + 1, credit);
        uint256 shares = _jitIn(jitAmount);
        uint256 realBefore = adapter.realAssets();
        this.takeWithAccrual(makeSellOffer(market, units, MAX_TICK), "", taker, address(0));
        uint256 out = _jitOut(shares);
        emit log_named_uint("realAssets before", realBefore);
        emit log_named_uint("jit in", jitAmount);
        emit log_named_uint("jit out", out);
        assertLe(out, jitAmount, "J3 depositor profited from a gain sale");
    }

    /// @dev Same as above with the vault's maxRate lifted: shows what protects depositors.
    /// forge-config: default.isolate = true
    function testGainSaleWithMaxRateLifted() public {
        Offer[3] memory offers = _setup(7);
        vm.prank(signerAllocator);
        realVault.setMaxRate(200e16 / uint256(365 days)); // MAX_MAX_RATE
        Market memory market = offers[1].market;
        uint256 credit = adapter.marketData(_marketId(market)).netCredit;
        uint256 shares = _jitIn(1_000_000e18);
        this.takeWithAccrual(makeSellOffer(market, credit, MAX_TICK), "", taker, address(0));
        uint256 out = _jitOut(shares);
        emit log_named_uint("jit in", 1_000_000e18);
        emit log_named_uint("jit out", out);
        assertLe(out, 1_000_000e18, "J3 profit even at MAX_MAX_RATE");
    }
}

