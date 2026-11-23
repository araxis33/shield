// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title ShieldReactive
/// @notice Lives on Reactive Network and is the Shield's clock (same design as the lp-guard clock that has run on
///         mainnet since 19 Nov). On a Reactive Cron tick it asks the ShieldVault on Base to check the borrower
///         (`protectByReactive`): often while the stock market is closed for the weekend, rarely on weekdays.
///         The vault decides whether anything is repaid; this contract only wakes it.
///
///         It never holds user funds. Its deployer can point it at a new vault, switch the clock on or off,
///         and take back the REACT it holds.
contract ShieldReactive is AbstractReactive {
    address public constant CRON = 0x0000000000000000000000000000000000fffFfF;
    /// @notice Gas for one check: measured on a Base fork 0.34M (nothing to do) to 0.49M (repay through Giver); 4x headroom.
    uint64 public constant CHECK_GAS = 2_000_000;

    uint256 public immutable originChainId;
    address public immutable deployer;
    address public vault;
    uint256 public cronTopic;
    uint32 public weekendEvery; // seconds between checks, Fri 20:00 - Mon 01:30 UTC
    uint32 public weekdayEvery; // seconds between checks otherwise
    uint64 public lastCheck;

    event VaultSet(address vault);
    event ClockStarted(uint256 cronTopic, uint32 weekendEvery, uint32 weekdayEvery);
    event ClockStopped();
    event CheckRequested(uint64 at, bool weekend);
    event Withdrawn(address to, uint256 amount);

    error NotDeployer();
    error VaultNotSet();
    error ClockRunning();
    error BadPeriod();

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert NotDeployer();
        _;
    }

    constructor(uint256 originChainId_) payable {
        originChainId = originChainId_;
        deployer = msg.sender;
    }

    function setVault(address vault_) external onlyDeployer {
        if (vault_ == address(0)) revert VaultNotSet();
        vault = vault_;
        lastCheck = 0; // a new vault is checked on the next tick
        emit VaultSet(vault_);
    }

    function start(uint256 cronTopic_, uint32 weekendEvery_, uint32 weekdayEvery_) external onlyDeployer {
        if (vault == address(0)) revert VaultNotSet();
        if (cronTopic != 0) revert ClockRunning();
        if (cronTopic_ == 0 || weekendEvery_ == 0 || weekdayEvery_ < weekendEvery_) revert BadPeriod();
        cronTopic = cronTopic_;
        weekendEvery = weekendEvery_;
        weekdayEvery = weekdayEvery_;
        lastCheck = 0; // first tick after start always checks
        SYSTEM.subscribe(block.chainid, CRON, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ClockStarted(cronTopic_, weekendEvery_, weekdayEvery_);
    }

    function stop() external onlyDeployer {
        uint256 topic = cronTopic;
        if (topic == 0) return;
        cronTopic = 0;
        SYSTEM.unsubscribe(block.chainid, CRON, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ClockStopped();
    }

    function withdraw(address payable to, uint256 amount) external onlyDeployer {
        _coverDebt();
        _pay(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Same window as ShieldVault.inWeekendWindow.
    function inWeekendWindow(uint256 ts) public pure returns (bool) {
        uint256 day = (ts / 1 days + 4) % 7;
        uint256 sec = ts % 1 days;
        if (day == 6 || day == 0) return true;
        if (day == 5) return sec >= 20 hours;
        if (day == 1) return sec < 1 hours + 30 minutes;
        return false;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != block.chainid || log_.contractAddress != CRON || cronTopic == 0 || log_.topic0 != cronTopic) return;
        uint64 now_ = uint64(block.timestamp);
        bool weekend = inWeekendWindow(now_);
        // the weekend pace also covers the first weekday tick, so the Monday reopen is not left to an hourly wait
        uint32 every = weekend || inWeekendWindow(lastCheck) ? weekendEvery : weekdayEvery;
        if (now_ < lastCheck + every) return;
        lastCheck = now_;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: vault,
                gasLimit: CHECK_GAS,
                payload: abi.encodeWithSignature("protectByReactive(address)", address(0))
            })
        );
        emit CheckRequested(now_, weekend);
    }
}
