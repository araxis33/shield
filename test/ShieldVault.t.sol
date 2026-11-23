// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {ShieldVault, ISpoke, IGiver, IERC20, ISugarHelper, IAaveOracle} from "../src/ShieldVault.sol";

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
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
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
        vault = new ShieldVault(SPOKE, GIVER, USDC, SUGAR, PROXY, rvm, user, coll, reserves, pools);
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
        (ok,) = address(SPOKE).call(
            abi.encodeCall(ISpokeW.liquidationCall, (c, USDC_RESERVE, user, type(uint256).max, false))
        );
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
        vm.expectRevert(ShieldVault.Cooldown.selector);
        vault.protect();
        vm.warp(t + 15 minutes - 1);
        setOpenAt(t + 15 minutes - 1);
        vm.expectRevert(ShieldVault.Cooldown.selector);
        vault.protect();
        vm.warp(t + 15 minutes);
        setOpenAt(t + 15 minutes);
        assertEq(vault.protect(), 50e6, "capped by the rest of the budget");
        vm.warp(t + 30 minutes);
        setOpenAt(t + 30 minutes);
        vm.expectRevert(ShieldVault.NothingToRepay.selector);
        vault.protect();
        assertEq(vault.reserve(), 850e6);
    }

    // ---------------------------------------------------------------- 3. healthy: nothing moves

    function test_healthyNothingMoves() public {
        uint256 h = hf();
        fund(1_000e6, true);
        activate(1.0001e18 > h - 0.05e18 ? 1.0001e18 : h - 0.05e18, h + 0.1e18, 100e6, 0, 1_000e6);
        uint256 d0 = debt();
        vm.expectRevert(ShieldVault.Healthy.selector);
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
        gapAave(g); // ... Aave only at the Monday print
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
        gapAave(g); // Monday print
        console2.log("HF after the print x1e4", hf() / 1e14);
        assertGe(hf(), 1.05e18, "alive after the print");
        assertFalse(liquidate(coll), "liquidation must fail");
    }

    function test_weekendLateRepayIsTooLate() public {
        uint256 g = _killingGap();
        uint256 before = SPOKE.getUserSuppliedAssets(coll, user);
        fund(200_000e6, true);
        activate(1.05e18, 1.0501e18, 200_000e6, 200_000e6, 200_000e6);
        goWeekend();
        gapAave(g); // the print lands before anyone acted
        assertTrue(liquidate(coll), "liquidator first");
        assertLt(SPOKE.getUserSuppliedAssets(coll, user), before);
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
        vm.expectRevert(ShieldVault.Inactive.selector);
        vault.protect();
    }

    // ---------------------------------------------------------------- 6. Giver not approved: clean failure

    function test_giverNotApprovedNothingLost() public {
        uint256 h = hf();
        fund(1_000e6, false);
        activate(h + 0.1e18, h + 0.2e18, 1_000e6, 0, 1_000e6);
        vm.expectRevert();
        vault.protect();
        assertEq(vault.reserve(), 1_000e6);
        assertEq(vault.lastProtect(), 0);
        // the Reactive path swallows it and only logs
        vm.prank(PROXY);
        vault.protectByReactive(rvm);
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
        vm.expectRevert();
        vault.protectByReactive(rvm); // not the proxy
        vm.prank(PROXY);
        vm.expectRevert();
        vault.protectByReactive(makeAddr("someoneElse")); // proxy, wrong Reactive contract
        vm.expectRevert(ShieldVault.NotUser.selector);
        vault.protectSelf();
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
}
