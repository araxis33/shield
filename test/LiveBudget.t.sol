// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/Test.sol";
import {ShieldVault} from "../src/ShieldVault.sol";
import {ShieldVaultTest, ISpokeW} from "./ShieldVault.t.sol";

/// Block 5 budget: gas of every step of the live pilot on Base, measured on a fork
/// with a real borrower. Rule set the way the pilot will set it: trigger just above
/// the current HF so one small repay (capped at $1.50) happens on its own.
contract LiveBudgetTest is ShieldVaultTest {
    function test_liveBudget() public {
        uint256 g;
        address rv = makeAddr("reactiveVM2");

        g = gasleft();
        ShieldVault v2 = new ShieldVault(SPOKE, GIVER, USDC, SUGAR, FACTORY, PROXY, rv, user, coll, 1e12, reserves, pools);
        console2.log("gas deploy vault", g - gasleft());
        vault = v2;
        rvm = rv;
        setOpen();

        vm.prank(user);
        g = gasleft();
        ISpokeW(address(SPOKE)).setUserPositionManager(address(GIVER), true);
        console2.log("gas setUserPositionManager", g - gasleft());

        deal(address(USDC), user, USDC.balanceOf(user) + 2e6);
        vm.prank(user);
        g = gasleft();
        USDC.approve(address(vault), 2e6);
        console2.log("gas approve", g - gasleft());

        vm.prank(user);
        g = gasleft();
        vault.deposit(2e6);
        console2.log("gas deposit", g - gasleft());

        uint256 h = hf();
        ShieldVault.Rule memory r = ShieldVault.Rule({
            triggerHF: uint64(h + 0.01e18),
            targetHF: uint64(h + 0.2e18),
            cooldown: 15 minutes,
            haircutBps: 0,
            maxRepay: 1.5e6,
            maxAeroRepay: 1.5e6
        });
        vm.prank(user);
        g = gasleft();
        vault.activate(r, 2e6);
        console2.log("gas activate", g - gasleft());

        uint256 d0 = debt();
        vm.prank(PROXY);
        g = gasleft();
        vault.protectByReactive(rv);
        console2.log("gas callback open market, repay", g - gasleft());
        console2.log("repaid (USDC 1e6)", d0 - debt());
        assertEq(d0 - debt(), 1.5e6, "one capped repay");

        // next tick inside cooldown: the cheap 'nothing to do' callback
        vm.warp(block.timestamp + 5 minutes);
        setOpen();
        vm.prank(PROXY);
        g = gasleft();
        vault.protectByReactive(rv);
        console2.log("gas callback cooldown", g - gasleft());

        // weekend tick, healthy: full stress read of the 8 Aero pools
        vm.prank(user);
        vault.activate(ShieldVault.Rule(1.0001e18, 1.0002e18, 15 minutes, 0, 1.5e6, 1.5e6), 0.5e6);
        goWeekend();
        vm.prank(PROXY);
        g = gasleft();
        vault.protectByReactive(rv);
        console2.log("gas callback weekend healthy", g - gasleft());

        vm.prank(user);
        g = gasleft();
        vault.stopAndWithdraw();
        console2.log("gas stopAndWithdraw", g - gasleft());
    }
}
