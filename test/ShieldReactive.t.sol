// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ShieldReactive} from "../src/ShieldReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Stands in for Reactive's system contract at 0x8888…: records subscriptions and callback requests.
contract MockSystem {
    uint256 public subs;
    uint256 public unsubs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal reqs;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subs++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubs++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external {
        reqs.push(cfg);
    }

    function reqCount() external view returns (uint256) {
        return reqs.length;
    }

    function req(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return reqs[i];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract ShieldReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant BASE = 8453;
    uint256 constant TICK = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4; // Cron1000
    address vault = makeAddr("vault");
    ShieldReactive rx;
    MockSystem sys;
    uint256 clock = 1795132800; // Fri 20 Nov 2026 00:00 UTC (a weekday hour)

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        rx = new ShieldReactive{value: 10 ether}(BASE);
        rx.setVault(vault);
        rx.start(TICK, 15 minutes, 1 hours);
        vm.warp(clock);
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _tick() internal {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        vm.prank(SYSTEM);
        rx.react(l);
    }

    function test_hourlyOnWeekdays_every15minOnWeekends() public {
        _tick();
        assertEq(sys.reqCount(), 1);
        assertEq(sys.req(0).payload, abi.encodeWithSignature("protectByReactive(address)", address(0)));
        assertEq(sys.req(0).recipient, vault);
        assertEq(sys.req(0).chainId, BASE);
        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 1, "weekday: not within the hour");
        _skip(43 minutes);
        _tick();
        assertEq(sys.reqCount(), 2);
        // Saturday 21 Nov 12:00 UTC
        clock = 1795262400;
        vm.warp(clock);
        _tick();
        _skip(17 minutes);
        _tick();
        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 5, "weekend: every Cron1000 tick (~17 min) goes through");
    }

    function test_ignoresOtherEvents() public {
        IReactive.LogRecord memory l;
        l.contractAddress = makeAddr("pool");
        l.topic0 = TICK;
        vm.prank(SYSTEM);
        rx.react(l);
        assertEq(sys.reqCount(), 0);
    }

    function test_onlyTheSystemCanReact() public {
        IReactive.LogRecord memory l;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        vm.expectRevert();
        rx.react(l);
    }

    function test_stop_endsTheTicks_andCanStartAgain() public {
        rx.stop();
        assertEq(sys.unsubs(), 1);
        _tick();
        assertEq(sys.reqCount(), 0);
        rx.start(TICK, 15 minutes, 1 hours);
        _tick();
        assertEq(sys.reqCount(), 1);
    }

    function test_deployerOnly_andWithdraw() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(ShieldReactive.NotDeployer.selector);
        rx.setVault(stranger);
        vm.expectRevert(ShieldReactive.NotDeployer.selector);
        rx.stop();
        vm.expectRevert(ShieldReactive.NotDeployer.selector);
        rx.withdraw(payable(stranger), 1);
        vm.stopPrank();
        address payable me = payable(makeAddr("me"));
        rx.withdraw(me, 4 ether);
        assertEq(me.balance, 4 ether, "REACT comes back");
    }

    function test_weekendWindowMatchesVault() public view {
        assertTrue(rx.inWeekendWindow(1795204800)); // Fri 20:00
        assertFalse(rx.inWeekendWindow(1795204799));
        assertTrue(rx.inWeekendWindow(1795397399)); // Mon 01:29:59
        assertFalse(rx.inWeekendWindow(1795397400));
    }

    function test_restartAndNewVaultCheckOnFirstTick() public {
        _tick();
        assertEq(sys.reqCount(), 1);
        rx.stop();
        rx.start(TICK, 15 minutes, 1 hours);
        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 2, "restart checks at once");
        rx.setVault(makeAddr("vault2"));
        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 3, "new vault checked at once");
        assertEq(sys.req(2).recipient, makeAddr("vault2"));
    }

    function test_mondayReopenNotDelayed() public {
        clock = 1795396800; // Mon 23 Nov 01:20 UTC, inside the window
        vm.warp(clock);
        _tick();
        _skip(17 minutes); // 01:37, window closed, last check was in the weekend
        _tick();
        assertEq(sys.reqCount(), 2, "first weekday tick still at weekend pace");
        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 2, "then hourly");
    }

    function test_wrongChainIgnored() public {
        IReactive.LogRecord memory l;
        l.chainId = 1;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        vm.prank(SYSTEM);
        rx.react(l);
        assertEq(sys.reqCount(), 0);
    }
}
