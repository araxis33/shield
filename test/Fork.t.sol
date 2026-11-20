// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

interface ISpoke {
    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    function getUserAccountData(address user) external view returns (UserAccountData memory);
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool, bool);
    function getReserveCount() external view returns (uint256);
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function liquidationCall(uint256 collateralReserveId, uint256 debtReserveId, address user, uint256 debtToCover, bool receiveShares)
        external;
    function setUserPositionManager(address positionManager, bool approve) external;
    function ORACLE() external view returns (address);
}

interface IAaveOracle {
    function getReserveSource(uint256 reserveId) external view returns (address);
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface IGiver {
    function repayOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// The Monday-gap story on a Base mainnet fork with a real borrower:
/// the same price gap liquidates an untouched position, and leaves one that repaid early alive.
contract ForkTest is Test {
    ISpoke constant SPOKE = ISpoke(0x17905Db0e4A3514467539956c084180616AE7B8D);
    IGiver constant GIVER = IGiver(0x9E81c2fDE4E34CAB3AB1667ca3c932dBAED95F08);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    uint256 constant USDC_RESERVE = 7;
    uint256 constant N_STOCKS = 9; // reserves 0..8, USDC is 7

    address user;
    IAaveOracle oracle;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        user = vm.envAddress("BORROWER");
        oracle = IAaveOracle(SPOKE.ORACLE());
    }

    function hf() internal view returns (uint256) {
        return SPOKE.getUserAccountData(user).healthFactor;
    }

    /// Every stock feed prints `bps` lower (the reopen print after a bad weekend).
    function gap(uint256 bps) internal {
        for (uint256 r; r < N_STOCKS; ++r) {
            if (r == USDC_RESERVE) continue;
            address src = oracle.getReserveSource(r);
            int256 p = int256(oracle.getReservePrice(r));
            vm.mockCall(src, abi.encodeWithSignature("latestAnswer()"), abi.encode(p * int256(10_000 - bps) / 10_000));
        }
    }

    /// Smallest whole-percent gap that takes this borrower below HF 1, plus one point of margin.
    function killingGap() internal view returns (uint256 bps) {
        uint256 h = hf();
        // all collateral falls together: HF scales linearly with prices
        bps = (10_000 - (10_000 * 1e18) / h) + 100;
        bps = ((bps + 99) / 100) * 100;
    }

    function largestCollateral() internal view returns (uint256 best) {
        uint256 bestVal;
        for (uint256 r; r < N_STOCKS; ++r) {
            (bool coll,) = SPOKE.getUserReserveStatus(r, user);
            if (!coll) continue;
            uint256 v = SPOKE.getUserSuppliedAssets(r, user) * oracle.getReservePrice(r);
            if (v > bestVal) (bestVal, best) = (v, r);
        }
    }

    /// USDC that brings HF to `target` (WAD) at current prices: debt - weightedCollateral/target.
    function repayFor(uint256 target) internal view returns (uint256) {
        ISpoke.UserAccountData memory a = SPOKE.getUserAccountData(user);
        // Spoke value units: value = amount * price(8 dec) * 10^(18 - decimals), so $1 = 1e26
        uint256 debt = a.totalDebtValueRay / 1e27;
        uint256 weighted = debt * a.healthFactor / 1e18;
        uint256 need = debt - weighted * 1e18 / target;
        // value -> USDC (6 decimals): amount = value / (price * 10^(18 - 6))
        return need / (oracle.getReservePrice(USDC_RESERVE) * 1e12) + 1;
    }

    function liquidate(uint256 coll) internal returns (bool ok) {
        // Coinbase stock tokens on Base (0xb200…) are built into the chain (their code is the single byte 0xef):
        // real Base nodes run them, a local fork cannot. Only their transfer is simulated here; every Aave check is real.
        for (uint256 r; r < N_STOCKS; ++r) {
            if (r == USDC_RESERVE) continue;
            (bool s, bytes memory d) = address(SPOKE).staticcall(abi.encodeWithSignature("getReserve(uint256)", r));
            require(s, "getReserve");
            address token = abi.decode(d, (address));
            if (token.code.length == 1) vm.mockCall(token, abi.encodeWithSelector(0xa9059cbb), abi.encode(true));
        }
        address liq = makeAddr("liquidator");
        deal(address(USDC), liq, 10_000_000e6);
        vm.startPrank(liq);
        USDC.approve(address(SPOKE), type(uint256).max);
        (ok,) = address(SPOKE).call(
            abi.encodeCall(ISpoke.liquidationCall, (coll, USDC_RESERVE, user, type(uint256).max, false))
        );
        vm.stopPrank();
    }

    function test_report() public view {
        console2.log("HF now (x1e4)", hf() / 1e14);
        console2.log("USDC debt", SPOKE.getUserTotalDebt(USDC_RESERVE, user));
        console2.log("killing gap bps", killingGap());
        console2.log("largest collateral reserve", largestCollateral());
    }

    /// Branch 1: nobody acts before the reopen print. The gap lands, a liquidator takes collateral.
    function test_gapLiquidatesUntouchedPosition() public {
        uint256 coll = largestCollateral();
        uint256 g = killingGap();
        uint256 before = SPOKE.getUserSuppliedAssets(coll, user);
        gap(g);
        assertLt(hf(), 1e18, "gap must take HF below 1");
        assertTrue(liquidate(coll), "liquidation should succeed");
        uint256 taken = before - SPOKE.getUserSuppliedAssets(coll, user);
        console2.log("gap bps", g);
        console2.log("collateral taken (raw units)", taken);
        assertGt(taken, 0);
    }

    /// Branch 2: on Sunday evening the borrower repays enough USDC (straight to the Spoke, from their own wallet).
    /// The same gap lands; the position stays above HF 1 and cannot be liquidated.
    function test_earlyRepaySurvivesSameGap() public {
        uint256 coll = largestCollateral();
        uint256 g = killingGap();
        // target: survive this gap with 5% to spare -> HF_target = 1.05 / (1 - g)
        uint256 target = 1.0501e18 * 10_000 / (10_000 - g); // aim 1 bp above 1.05: Aave rounds repaid shares down
        uint256 amt = repayFor(target);
        deal(address(USDC), user, USDC.balanceOf(user) + amt);
        vm.startPrank(user);
        USDC.approve(address(SPOKE), amt);
        SPOKE.repay(USDC_RESERVE, amt, user);
        vm.stopPrank();
        console2.log("repaid USDC (6 dec)", amt);
        console2.log("HF after repay (x1e4)", hf() / 1e14);
        gap(g);
        console2.log("HF after gap (x1e4)", hf() / 1e14);
        assertGe(hf(), 1.05e18, "calculator target: HF 1.05 after the gap");
        assertFalse(liquidate(coll), "liquidation must fail");
    }

    /// Branch 3: the same early repay, paid by a third party (the future Shield vault) through Aave's GiverPositionManager,
    /// after the borrower approved Giver once.
    function test_giverRepayOnBehalf() public {
        uint256 g = killingGap();
        uint256 target = 1.0501e18 * 10_000 / (10_000 - g); // aim 1 bp above 1.05: Aave rounds repaid shares down
        uint256 amt = repayFor(target);
        vm.prank(user);
        SPOKE.setUserPositionManager(address(GIVER), true);
        address payer = makeAddr("shieldVault");
        deal(address(USDC), payer, amt);
        uint256 debtBefore = SPOKE.getUserTotalDebt(USDC_RESERVE, user);
        vm.startPrank(payer);
        USDC.approve(address(GIVER), amt);
        GIVER.repayOnBehalfOf(address(SPOKE), USDC_RESERVE, amt, user);
        vm.stopPrank();
        assertLt(SPOKE.getUserTotalDebt(USDC_RESERVE, user), debtBefore, "debt must drop");
        gap(g);
        assertGe(hf(), 1.05e18, "calculator target: HF 1.05 after the gap");
        assertFalse(liquidate(largestCollateral()), "liquidation must fail");
    }

    /// Branch 4 (the failure case): reacting AFTER the print is too late. The gap lands, the liquidator goes first
    /// in the same block, and only then the borrower's repay arrives.
    function test_lateRepayIsTooLate() public {
        uint256 coll = largestCollateral();
        uint256 g = killingGap();
        uint256 before = SPOKE.getUserSuppliedAssets(coll, user);
        uint256 target = 1.0501e18 * 10_000 / (10_000 - g); // aim 1 bp above 1.05: Aave rounds repaid shares down
        uint256 amt = repayFor(target); // what the borrower would have needed before the print
        gap(g);
        assertTrue(liquidate(coll), "liquidator goes first");
        uint256 taken = before - SPOKE.getUserSuppliedAssets(coll, user);
        assertGt(taken, 0, "collateral is gone");
        // the borrower's repay lands after the liquidation: it reduces the remaining debt, the collateral does not come back
        deal(address(USDC), user, USDC.balanceOf(user) + amt);
        vm.startPrank(user);
        USDC.approve(address(SPOKE), amt);
        SPOKE.repay(USDC_RESERVE, amt, user);
        vm.stopPrank();
        assertEq(SPOKE.getUserSuppliedAssets(coll, user), before - taken, "late repay does not return collateral");
        console2.log("collateral lost before the late repay (raw)", taken);
    }
}
