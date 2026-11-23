// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {ShieldVault, ISpoke, IGiver, IERC20, ISugarHelper, IAaveOracle, ICLFactory} from "../src/ShieldVault.sol";

interface ISpokeW {
    function setUserPositionManager(address positionManager, bool approve) external;
    function liquidationCall(uint256 collateralReserveId, uint256 debtReserveId, address user, uint256 debtToCover, bool receiveShares)
        external;
}

/// Acceptance tests of CONTRACT_SPEC.md (Revision 2) on a Base mainnet fork with a real Aave V4 borrower.
contract ShieldVaultTest is Test {
    ISpoke constant SPOKE = ISpoke(0x17905Db0e4A3514467539956c084180616AE7B8D);
    IGiver constant GIVER = IGiver(0x9E81c2fDE4E34CAB3AB1667ca3c932dBAED95F08);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ISugarHelper constant SUGAR = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    address constant PROXY = 0xCc780DdE33f56f55dE778D42c930959374a4a068;
    ICLFactory constant FACTORY = ICLFactory(0x9CB220581b91b0C83223012FE69688b92aD07a76);
    uint256 constant FORK_BLOCK = 61249290; // Mon 23 Nov 2026, borrower 0x01db…a362 HF 1.4548
    bytes4 constant HF_NOT_BELOW = bytes4(keccak256("HealthFactorNotBelowThreshold()"));
    uint256 constant USDC_RESERVE = 7;

    address[8] POOLS = [
        0xF5FCB9CDAFcE67d50AfEf298F88E709d2B946BA6,
        0x532e0F46d1e528507FC9454d5847C231f23bDDf6,
        0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3,
        0xd072410fa13D242e1d53721Bcf7AF02e3455DC96,
        0x2740C0faAb738F6e346e545fDE02aEF9B1A01ee7,
        0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC,
        0x7A33000372f3F028f074182CCb9d16cBEEfBF920,
        0x880dB7Dda4407D99508574E680d067D1164B3cFE
    ];

    address user;
    address rvm;
    IAaveOracle oracle;
    ShieldVault vault;
    uint256 coll; // largest collateral reserve = the pilot's feed
    uint256[] reserves;
    address[] pools;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")), vm.envOr("FORK_BLOCK", FORK_BLOCK));
        user = vm.envOr("BORROWER", address(0x01DBDB9748ECf71B1fFbb62f5cB41318531bA362));
        rvm = makeAddr("reactiveVM");
        oracle = IAaveOracle(SPOKE.ORACLE());
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            if (r == USDC_RESERVE) continue;
            address stock = SPOKE.getReserve(r).underlying;
            for (uint256 i; i < 8; ++i) {
                (bool ok0, bytes memory a) = POOLS[i].staticcall(abi.encodeWithSignature("token0()"));
                (bool ok1, bytes memory b) = POOLS[i].staticcall(abi.encodeWithSignature("token1()"));
                require(ok0 && ok1);
                if (abi.decode(a, (address)) == stock || abi.decode(b, (address)) == stock) {
                    reserves.push(r);
                    pools.push(POOLS[i]);
                }
            }
        }
        coll = largestCollateral();
        assertEq(pools.length, 8, "all eight stock pools matched to reserves");
        vault = new ShieldVault(SPOKE, GIVER, USDC, SUGAR, FACTORY, PROXY, rvm, user, coll, 1e12, reserves, pools);
        setOpen();
    }

    // ---------------------------------------------------------------- helpers

    function largestCollateral() internal view returns (uint256 best) {
        uint256 bestVal;
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            if (r == USDC_RESERVE) continue;
            (bool c,) = SPOKE.getUserReserveStatus(r, user);
            if (!c) continue;
            uint256 v = SPOKE.getUserSuppliedAssets(r, user) * oracle.getReservePrice(r);
            if (v > bestVal) (bestVal, best) = (v, r);
        }
    }

    function hf() internal view returns (uint256) {
        return SPOKE.getUserAccountData(user).healthFactor;
    }

    function debt() internal view returns (uint256) {
        return SPOKE.getUserTotalDebt(USDC_RESERVE, user);
    }

    function setOpenAt(uint256 ts) internal {
        vm.mockCall(
            oracle.getReserveSource(coll),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(oracle.getReservePrice(coll)), ts, ts, uint80(1))
        );
    }

    /// Feed of the pilot stock printed just now.
    function setOpen() internal {
        vm.mockCall(
            oracle.getReserveSource(coll),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(oracle.getReservePrice(coll)), block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Next Saturday 12:00 UTC, feed asleep since Friday evening.
    function goWeekend() internal {
        uint256 t = block.timestamp;
        uint256 day = (t / 1 days + 4) % 7;
        uint256 toSat = (6 + 7 - day) % 7;
        if (toSat == 0) toSat = 7;
        uint256 sat = (t / 1 days + toSat) * 1 days + 12 hours;
        vm.warp(sat);
        vm.mockCall(
            oracle.getReserveSource(coll),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(oracle.getReservePrice(coll)), sat - 15 hours, sat - 15 hours, uint80(1))
        );
        assertEq(vault.marketState(), 1, "closed");
    }

    /// Monday 01:00 UTC after the current weekend: every feed prints `bps` lower and is fresh again.
    function mondayPrint(uint256 bps) internal {
        uint256 t = vm.getBlockTimestamp();
        uint256 day = (t / 1 days + 4) % 7;
        uint256 toMon = (1 + 7 - day) % 7;
        uint256 mon = (t / 1 days + toMon) * 1 days + 1 hours;
        vm.warp(mon);
        gapAave(bps);
        setOpenAt(mon);
        assertEq(vault.marketState(), 0, "open again");
    }

    /// Every stock feed prints `bps` lower (the reopen print after a bad weekend).
    function gapAave(uint256 bps) internal {
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            if (r == USDC_RESERVE) continue;
            address src = oracle.getReserveSource(r);
            int256 p = int256(oracle.getReservePrice(r));
            vm.mockCall(src, abi.encodeWithSignature("latestAnswer()"), abi.encode(p * int256(10_000 - bps) / 10_000));
        }
    }

    /// Every Aero pool's 60-min TWAP sits `bps` under Aave's price (what the weekend pools showed before a bad Monday).
    function gapPools(uint256 bps) internal {
        uint256 usdcPrice = oracle.getReservePrice(USDC_RESERVE);
        for (uint256 i; i < reserves.length; ++i) {
            uint256 p = oracle.getReservePrice(reserves[i]) * (10_000 - bps) / 10_000;
            vm.mockCall(address(vault), abi.encodeCall(vault.poolPriceUSD, (pools[i], usdcPrice)), abi.encode(p));
        }
    }

    function fund(uint256 amount, bool approveGiver) internal {
        if (approveGiver) {
            vm.prank(user);
            ISpokeW(address(SPOKE)).setUserPositionManager(address(GIVER), true);
        }
        deal(address(USDC), user, USDC.balanceOf(user) + amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function activate(uint256 trigger, uint256 target, uint256 maxRepay, uint256 maxAero, uint256 budget_) internal {
        ShieldVault.Rule memory r = ShieldVault.Rule({
            triggerHF: uint64(trigger),
            targetHF: uint64(target),
            cooldown: 15 minutes,
            haircutBps: 0,
            maxRepay: uint128(maxRepay),
            maxAeroRepay: uint128(maxAero)
        });
        vm.prank(user);
        vault.activate(r, budget_);
    }

    function liquidate(uint256 c) internal returns (bool ok) {
        (ok,) = liquidateWhy(c);
    }

    function liquidateWhy(uint256 c) internal returns (bool ok, bytes4 why) {
        // Coinbase stock tokens are chain built-ins (code 0xef); a fork cannot run them, so only their transfer is simulated.
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            address token = SPOKE.getReserve(r).underlying;
            if (token.code.length == 1) vm.mockCall(token, abi.encodeWithSelector(0xa9059cbb), abi.encode(true));
        }
        address liq = makeAddr("liquidator");
        deal(address(USDC), liq, 10_000_000e6);
        vm.startPrank(liq);
        USDC.approve(address(SPOKE), type(uint256).max);
        bytes memory ret;
        (ok, ret) = address(SPOKE).call(
            abi.encodeCall(ISpokeW.liquidationCall, (c, USDC_RESERVE, user, type(uint256).max, false))
        );
        if (!ok && ret.length >= 4) why = bytes4(ret);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 0. the math matches Aave

    function test_stressEqualsAaveHFWhenOpen() public view {
        ShieldVault.Stress memory s = vault.stress();
        console2.log("Aave HF x1e6", hf() / 1e12, "ours x1e6", s.stressHF / 1e12);
        assertApproxEqRel(s.stressHF, hf(), 1e14, "our HF = Aave's within 0.01%");
        assertEq(s.stressHF, s.aaveOnlyHF, "open market: no pool stress");
    }

    function test_poolPriceNearAave() public view {
        uint256 usdcPrice = oracle.getReservePrice(USDC_RESERVE);
        for (uint256 i; i < pools.length; ++i) {
            uint256 pool = vault.poolPriceUSD(pools[i], usdcPrice);
            uint256 aave = oracle.getReservePrice(reserves[i]);
            console2.log(reserves[i], aave, pool);
            assertApproxEqRel(pool, aave, 0.03e18, "pool TWAP within 3% of Aave");
        }
    }

    // ---------------------------------------------------------------- 1. repay reaches target, accounting exact

    function test_protectRepaysToTarget() public {
        uint256 h = hf();
        fund(100_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 100_000e6, 0, 100_000e6);
        uint256 d0 = debt();
        uint256 r0 = vault.reserve();
        uint256 spent = vault.protect();
        assertGt(spent, 0);
        assertEq(r0 - vault.reserve(), spent, "reserve drop = spent");
        assertEq(USDC.balanceOf(address(vault)), vault.reserve(), "vault balance = reserve");
        assertApproxEqAbs(d0 - debt(), spent, 2, "debt drop = spent");
        assertGe(vault.stress().stressHF, h + 0.2e18 - 1e12, "back at target");
        assertGe(hf(), h + 0.2e18 - 1e12, "native HF at target");
        assertEq(vault.budget(), 100_000e6 - spent);
        console2.log("spent USDC", spent, "HF after x1e4", hf() / 1e14);
    }

    // ---------------------------------------------------------------- 2. cooldown and budget

    function test_cooldownAndBudget() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.3e18, h + 0.5e18, 100e6, 0, 150e6);
        uint256 t = vm.getBlockTimestamp(); // own clock: block.timestamp can read stale after vm.warp under via-ir
        assertEq(vault.protect(), 100e6, "capped by maxRepay");
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Cooldown));
        vault.protect();
        vm.warp(t + 15 minutes - 1);
        setOpenAt(t + 15 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Cooldown));
        vault.protect();
        vm.warp(t + 15 minutes);
        setOpenAt(t + 15 minutes);
        assertEq(vault.protect(), 50e6, "capped by the rest of the budget");
        vm.warp(t + 30 minutes);
        setOpenAt(t + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.NothingToRepay));
        vault.protect();
        assertEq(vault.reserve(), 850e6);
    }

    // ---------------------------------------------------------------- 3. healthy: nothing moves

    function test_healthyNothingMoves() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(1.0001e18 > h - 0.05e18 ? 1.0001e18 : h - 0.05e18, h + 0.1e18, 100e6, 0, 1_000e6);
        uint256 d0 = debt();
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Healthy));
        vault.protect();
        assertEq(vault.reserve(), 1_000e6);
        assertEq(debt(), d0);
        assertEq(vault.lastProtect(), 0);
    }

    // ---------------------------------------------------------------- 4. weekend: three branches, one Monday print

    function _killingGap() internal view returns (uint256 bps) {
        bps = 10_000 - (10_000 * 1e18) / hf() + 200; // under HF 1 with 2 points to spare
    }

    function test_weekendNoShieldGetsLiquidated() public {
        uint256 g = _killingGap();
        uint256 before = SPOKE.getUserSuppliedAssets(coll, user);
        goWeekend();
        gapPools(g); // the pools see it on Saturday ...
        mondayPrint(g); // ... Aave only at the Monday print
        assertLt(hf(), 1e18);
        assertTrue(liquidate(coll), "liquidated");
        assertLt(SPOKE.getUserSuppliedAssets(coll, user), before, "collateral taken");
    }

    function test_weekendShieldRepaysFromPoolSignalAndSurvives() public {
        uint256 g = _killingGap();
        uint256 h = hf();
        fund(200_000e6, true);
        // target: survive this gap at HF 1.05 -> stress HF (pools already down g) >= 1.0501
        activate(1.05e18, 1.0501e18, 200_000e6, 200_000e6, 200_000e6);
        goWeekend();
        gapPools(g);
        ShieldVault.Stress memory s = vault.stress();
        assertLt(s.stressHF, 1e18, "pools say: under 1 on Monday");
        assertGe(s.aaveOnlyHF, h - 1e15, "Aave still asleep at Friday's price");
        uint256 spent = vault.protect();
        console2.log("Saturday repay USDC", spent);
        mondayPrint(g);
        console2.log("HF after the print x1e4", hf() / 1e14);
        // target 1.05 was set on Saturday; ~1.5 days of interest until the print shave a little off it
        assertGt(hf(), 1.04e18, "alive after the print, close to target");
        (bool ok, bytes4 why) = liquidateWhy(coll);
        assertFalse(ok, "liquidation must fail");
        assertEq(why, HF_NOT_BELOW, "Aave refuses: health factor not below threshold");
    }

    function test_weekendLateRepayIsTooLate() public {
        uint256 g = _killingGap();
        uint256 before = SPOKE.getUserSuppliedAssets(coll, user);
        fund(200_000e6, true);
        activate(1.05e18, 1.0501e18, 200_000e6, 200_000e6, 200_000e6);
        goWeekend();
        mondayPrint(g); // the print lands before the vault acted (no pool signal reached it)
        assertTrue(liquidate(coll), "liquidator first");
        uint256 left = SPOKE.getUserSuppliedAssets(coll, user);
        assertLt(left, before, "collateral taken");
        (bool acted,) = address(vault).call(abi.encodeCall(vault.protect, ())); // the vault wakes up after the print
        console2.log("vault acted after the liquidation", acted);
        assertEq(SPOKE.getUserSuppliedAssets(coll, user), left, "collateral does not come back");
    }

    // ---------------------------------------------------------------- 5. exit always works, stop means stop

    function test_exitWithEverythingBroken() public {
        fund(500e6, true);
        activate(1.5e18, 2e18, 100e6, 0, 500e6);
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getReservePrice(uint256)"), "oracle down");
        vm.prank(user);
        ISpokeW(address(SPOKE)).setUserPositionManager(address(GIVER), false);
        uint256 b0 = USDC.balanceOf(user);
        vm.prank(user);
        vault.stopAndWithdraw();
        assertEq(USDC.balanceOf(user) - b0, 500e6, "all back");
        assertEq(vault.reserve(), 0);
        vm.clearMockedCalls();
        setOpen();
        fund(100e6, false); // top-up after stop does not switch it back on
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Inactive));
        vault.protect();
    }

    // ---------------------------------------------------------------- 6. Giver not approved: clean failure

    function test_giverNotApprovedNothingLost() public {
        uint256 h = hf();
        vm.prank(user);
        ISpokeW(address(SPOKE)).setUserPositionManager(address(GIVER), false);
        fund(1_000e6, false);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 0, 1_000e6);
        assertEq(uint8(vault.stress().status), uint8(ShieldVault.Status.Repaid), "would act");
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.GiverFailed));
        vault.protect();
        assertEq(USDC.allowance(address(vault), address(GIVER)), 0, "no allowance left");
        assertEq(vault.reserve(), 1_000e6);
        assertEq(vault.lastProtect(), 0);
        // the Reactive path swallows it and only logs
        vm.expectEmit(address(vault));
        emit ShieldVault.Skipped(ShieldVault.Status.GiverFailed);
        vm.prank(PROXY);
        vault.protectByReactive(rvm);
        assertEq(USDC.allowance(address(vault), address(GIVER)), 0, "no allowance left after the callback");
        assertEq(vault.reserve(), 1_000e6);
        assertEq(USDC.balanceOf(address(vault)), 1_000e6);
    }

    // ---------------------------------------------------------------- 7. who can do what

    function test_reactiveCallbackRepays() public {
        uint256 h = hf();
        fund(100_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 100_000e6, 0, 100_000e6);
        vm.prank(PROXY);
        vault.protectByReactive(rvm);
        assertGt(vault.lastProtect(), 0, "repaid via Reactive");
    }

    function test_forgedCallbacksRejected() public {
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", address(this), PROXY));
        vault.protectByReactive(rvm); // not the proxy
        address other = makeAddr("someoneElse");
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSignature("CallbackNotAuthorized(address,address)", other, rvm));
        vault.protectByReactive(other); // proxy, wrong Reactive contract

    }

    function test_strangersCannotTouchMoney() public {
        fund(100e6, true);
        address x = makeAddr("stranger");
        vm.startPrank(x);
        vm.expectRevert(ShieldVault.NotUser.selector);
        vault.withdraw(1);
        vm.expectRevert(ShieldVault.NotUser.selector);
        vault.stop();
        vm.expectRevert(ShieldVault.NotUser.selector);
        vault.stopAndWithdraw();
        vm.stopPrank();
        assertEq(vault.reserve(), 100e6);
    }

    function test_weekendWindow() public view {
        assertTrue(vault.inWeekendWindow(1795384800)); // Sun 22 Nov 2026 22:00 UTC
        assertTrue(vault.inWeekendWindow(1795222800)); // Sat 21 Nov 01:00
        assertTrue(vault.inWeekendWindow(1795204800)); // Fri 20 Nov 20:00
        assertFalse(vault.inWeekendWindow(1795204799)); // Fri 19:59:59
        assertTrue(vault.inWeekendWindow(1795397399)); // Mon 01:29:59
        assertFalse(vault.inWeekendWindow(1795397400)); // Mon 01:30
    }

    // ---------------------------------------------------------------- 8. edges Codex asked for

    function test_brokenFeedIsFaultNotWeekend() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 1_000e6, 1_000e6);
        goWeekend();
        address src = oracle.getReserveSource(coll);
        vm.mockCall(src, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(1), uint256(0), uint256(0), uint80(1)));
        assertEq(vault.marketState(), 2, "updatedAt 0 = fault");
        vm.mockCall(src, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(1), vm.getBlockTimestamp() + 1, vm.getBlockTimestamp() + 1, uint80(1)));
        assertEq(vault.marketState(), 2, "future time = fault");
        vm.mockCall(src, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(0), vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1)));
        assertEq(vault.marketState(), 2, "zero price = fault");
        vm.mockCallRevert(src, abi.encodeWithSignature("latestRoundData()"), "down");
        assertEq(vault.marketState(), 2, "unreadable = fault");
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.DataFault));
        vault.protect();
        assertEq(vault.reserve(), 1_000e6);
    }

    function test_staleInSessionIsFault() public {
        uint256 t = vm.getBlockTimestamp(); // fork block is a Monday afternoon, in session
        assertFalse(vault.inWeekendWindow(t));
        setOpenAt(t - 3 hours);
        assertEq(vault.marketState(), 2);
    }

    function test_noDebtIsHealthyEvenWithBrokenFeed() public {
        vm.mockCall(address(SPOKE), abi.encodeWithSignature("getUserTotalDebt(uint256,address)", USDC_RESERVE, user), abi.encode(uint256(0)));
        vm.mockCallRevert(oracle.getReserveSource(coll), abi.encodeWithSignature("latestRoundData()"), "down");
        assertEq(uint8(vault.stress().status), uint8(ShieldVault.Status.Healthy));
    }

    function test_usdcCollateralOrOtherDebtIsUnsupported() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 0, 1_000e6);
        vm.mockCall(address(SPOKE), abi.encodeWithSignature("getUserReserveStatus(uint256,address)", USDC_RESERVE, user), abi.encode(true, true));
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Unsupported));
        vault.protect();
        vm.clearMockedCalls();
        setOpen();
        vm.mockCall(address(SPOKE), abi.encodeWithSignature("getUserReserveStatus(uint256,address)", coll, user), abi.encode(true, true));
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Unsupported));
        vault.protect();
    }

    function test_triggerEqualsStressIsHealthy() public {
        uint256 h = vault.stress().stressHF;
        fund(1_000e6, true);
        activate(h, h + 0.1e18, 1_000e6, 0, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Healthy));
        vault.protect();
    }

    function test_poolOnlySignalCappedByMaxAeroRepay() public {
        uint256 g = _killingGap();
        fund(200_000e6, true);
        activate(1.05e18, 1.0501e18, 200_000e6, 500e6, 200_000e6);
        goWeekend();
        gapPools(g);
        assertEq(vault.protect(), 500e6, "pool-only signal: at most maxAeroRepay");
    }

    function test_thinPoolFallsBackToAave() public {
        goWeekend();
        ShieldVault.Stress memory s0 = vault.stress();
        assertLt(s0.stressHF, s0.aaveOnlyHF, "control: the real pools are read and price a little under Aave");
        for (uint256 i; i < pools.length; ++i) {
            vm.mockCall(pools[i], abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1)));
        }
        ShieldVault.Stress memory s = vault.stress();
        assertEq(s.stressHF, s.aaveOnlyHF, "thin pools ignored");
    }

    function test_reactivateKeepsCooldown() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.3e18, h + 0.5e18, 100e6, 0, 1_000e6);
        vault.protect();
        activate(h + 0.3e18, h + 0.5e18, 100e6, 0, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.NotProtected.selector, ShieldVault.Status.Cooldown));
        vault.protect();
    }

    function test_badPoolRejectedAtDeploy() public {
        address[] memory p = new address[](1);
        uint256[] memory r = new uint256[](1);
        r[0] = reserves[0];
        p[0] = pools[1]; // another stock's pool
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.BadPool.selector, r[0]));
        new ShieldVault(SPOKE, GIVER, USDC, SUGAR, FACTORY, PROXY, rvm, user, coll, 1e12, r, p);
    }

    function test_giverAmountMismatchRevertsEverything() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 0, 1_000e6);
        // Giver claims it repaid without taking any USDC
        vm.mockCall(address(GIVER), abi.encodeWithSignature("repayOnBehalfOf(address,uint256,uint256,address)"), abi.encode(uint256(1), uint256(5e6)));
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.GiverMismatch.selector, uint256(0), uint256(5e6)));
        vault.protect();
        assertEq(vault.reserve(), 1_000e6);
        assertEq(vault.budget(), 1_000e6);
        assertEq(vault.lastProtect(), 0);
        assertEq(USDC.allowance(address(vault), address(GIVER)), 0);
        assertEq(USDC.balanceOf(address(vault)), 1_000e6);
    }

    function test_allowanceZeroAfterRepay() public {
        uint256 h = hf();
        fund(100_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 100_000e6, 0, 100_000e6);
        vault.protect();
        assertEq(USDC.allowance(address(vault), address(GIVER)), 0);
    }

    function test_zeroLiquidityFloorRejected() public {
        vm.expectRevert(abi.encodeWithSelector(ShieldVault.BadPool.selector, uint256(0)));
        new ShieldVault(SPOKE, GIVER, USDC, SUGAR, FACTORY, PROXY, rvm, user, coll, 0, reserves, pools);
    }

    function test_callbackAfterStopAndTopUpDoesNothing() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 0, 1_000e6);
        vm.prank(user);
        vault.stop();
        fund(500e6, false);
        vm.expectEmit(address(vault));
        emit ShieldVault.Skipped(ShieldVault.Status.Inactive);
        vm.prank(PROXY);
        vault.protectByReactive(rvm);
        assertEq(vault.reserve(), 1_500e6);
    }
}
