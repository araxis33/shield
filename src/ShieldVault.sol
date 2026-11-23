// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {MulDiv} from "./lib/MulDiv.sol";

interface ISpoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    struct UserPosition {
        uint120 drawnShares;
        uint120 premiumShares;
        int200 premiumOffsetRay;
        uint120 suppliedShares;
        uint32 dynamicConfigKey;
    }

    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    function ORACLE() external view returns (address);
    function getReserveCount() external view returns (uint256);
    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function getDynamicReserveConfig(uint256 reserveId, uint32 key) external view returns (DynamicReserveConfig memory);
    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory);
    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool, bool);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);
    function getUserAccountData(address user) external view returns (UserAccountData memory);
}

interface IAaveOracle {
    function getReservePrice(uint256 reserveId) external view returns (uint256);
    function getReserveSource(uint256 reserveId) external view returns (address);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IGiver {
    function repayOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256, uint256);
}

interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
    function factory() external view returns (address);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

interface ISugarHelper {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

/// @title Shield — one-seat automaton that repays an Aave V4 stock-loan before a weekend gap reaches the oracle.
/// @notice The borrower keeps a USDC reserve here. When the position's health under stress (while the stock market is
///         closed: each stock at the lower of Aave's price and the 60-min TWAP of its Aero pool on Base, with an
///         optional extra haircut) falls under the borrower's trigger, the vault repays part of the USDC debt through
///         Aave's GiverPositionManager, back up to the borrower's target. Reactive Network wakes it on a timer;
///         anyone may also call `protect()`, which only ever spends the borrower's reserve on the borrower's own debt.
///         Money can only move vault -> Giver -> this borrower's debt, or vault -> borrower. No admin, no sweep.
///         Top up only through `deposit`: USDC sent straight to the vault is not credited.
contract ShieldVault is AbstractCallback {
    using MulDiv for uint256;

    struct Rule {
        uint64 triggerHF; // WAD; act when stress HF is below this
        uint64 targetHF; // WAD; repay back up to this
        uint32 cooldown; // seconds between two repays
        uint16 haircutBps; // extra stress on Aave's price while the market is closed
        uint128 maxRepay; // USDC units per repay
        uint128 maxAeroRepay; // USDC units per repay when only the pool price calls for it
    }

    enum Status {
        Repaid,
        Inactive,
        DataFault,
        Unsupported, // debt outside USDC, or USDC enabled as collateral
        Healthy,
        Cooldown,
        NothingToRepay,
        GiverFailed
    }

    struct Stress {
        Status status; // Repaid here means "the rule calls for a repay" (caps, reserve, budget, cooldown not applied)
        uint8 market; // 0 open, 1 closed, 2 data fault, 3 not checked (no debt)
        uint256 debt; // USDC units, drawn + premium
        uint256 stressHF; // WAD
        uint256 aaveOnlyHF; // WAD, same but without the pool prices
        uint256 repay; // USDC units that bring stress HF to target (before caps); rounded up by at most 1 unit
    }

    uint256 public constant USDC_RESERVE = 7;
    uint32 public constant TWAP_WINDOW = 3600;
    uint256 public constant MIN_REPAY = 1e6; // $1
    uint32 public constant MIN_COOLDOWN = 15 minutes;
    uint256 public constant STALE_AFTER = 2 hours;
    uint256 internal constant FEED_GAS = 100_000;
    uint256 internal constant POOL_GAS = 250_000;
    uint256 internal constant HF_GAS = 400_000;
    uint256 internal constant GIVER_GAS = 700_000; // measured repay path ~0.15M
    uint256 internal constant FINISH_GAS = 120_000; // allowance reset, bookkeeping, event, lock release

    ISpoke public immutable SPOKE;
    IAaveOracle public immutable ORACLE;
    IGiver public immutable GIVER;
    IERC20 public immutable USDC;
    ISugarHelper public immutable SUGAR;
    address public immutable USER; // the one seat
    uint256 public immutable FEED_RESERVE; // stock whose feed tells open / closed / fault
    uint128 public immutable MIN_POOL_LIQUIDITY; // in-range liquidity below this: pool ignored, Aave price only

    mapping(uint256 reserveId => address pool) public poolOf;
    mapping(address pool => bool usdcIsToken0) internal usdc0;
    mapping(address pool => uint8 stockDecimals) internal stockDec;

    uint256 public reserve; // USDC held for USER
    uint256 public budget; // USDC the automaton may still spend before USER re-confirms
    uint256 public lastProtect;
    bool public active;
    Rule public rule;
    uint256 private locked = 1;

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Activated(Rule rule, uint256 budget);
    event Stopped();
    event Protected(address indexed user, uint256 spent, uint256 stressHFBefore, uint256 nativeHFAfter, bool aeroDriven);
    event Skipped(Status status);

    error NotUser();
    error BadRule();
    error NotProtected(Status status);
    error GiverMismatch(uint256 spent, uint256 repaid);
    error TransferFailedUSDC();
    error Reentrancy();
    error BadPool(uint256 reserveId);
    error Insufficient();

    modifier onlyUser() {
        if (msg.sender != USER) revert NotUser();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    /// @param factory_ Aero Slipstream factory; every pool must be its pool for (USDC, stock, tickSpacing).
    /// @param pools_ Aero USDC pool of each stock reserve in `reserves_`; zero = no pool, Aave price only.
    constructor(
        ISpoke spoke_,
        IGiver giver_,
        IERC20 usdc_,
        ISugarHelper sugar_,
        ICLFactory factory_,
        address callbackProxy_,
        address reactive_,
        address user_,
        uint256 feedReserve_,
        uint128 minPoolLiquidity_,
        uint256[] memory reserves_,
        address[] memory pools_
    ) payable AbstractCallback(IPayable(payable(callbackProxy_)), reactive_) {
        SPOKE = spoke_;
        ORACLE = IAaveOracle(spoke_.ORACLE());
        GIVER = giver_;
        USDC = usdc_;
        SUGAR = sugar_;
        USER = user_;
        FEED_RESERVE = feedReserve_;
        MIN_POOL_LIQUIDITY = minPoolLiquidity_;
        if (minPoolLiquidity_ == 0 && pools_.length != 0) revert BadPool(0);
        if (spoke_.getReserve(USDC_RESERVE).underlying != address(usdc_) || spoke_.getReserve(USDC_RESERVE).decimals != 6) {
            revert BadPool(USDC_RESERVE);
        }
        for (uint256 i; i < reserves_.length; ++i) {
            address p = pools_[i];
            if (p == address(0)) continue;
            ISpoke.Reserve memory res = spoke_.getReserve(reserves_[i]);
            address t0 = ICLPool(p).token0();
            address t1 = ICLPool(p).token1();
            bool u0 = t0 == address(usdc_);
            if (
                (!(u0 && t1 == res.underlying) && !(t0 == res.underlying && t1 == address(usdc_)))
                    || ICLPool(p).factory() != address(factory_) || factory_.getPool(t0, t1, ICLPool(p).tickSpacing()) != p
            ) revert BadPool(reserves_[i]);
            poolOf[reserves_[i]] = p;
            usdc0[p] = u0;
            stockDec[p] = res.decimals;
        }
    }

    // ------------------------------------------------------------------ borrower

    /// @notice Add USDC to the reserve. Credits what actually arrived. Does not switch the automaton on.
    function deposit(uint256 amount) external onlyUser nonReentrant {
        uint256 before = USDC.balanceOf(address(this));
        if (!USDC.transferFrom(msg.sender, address(this), amount)) revert TransferFailedUSDC();
        uint256 got = USDC.balanceOf(address(this)) - before;
        reserve += got;
        emit Deposited(got);
    }

    /// @notice Take USDC back. Touches nothing but this balance: works with the oracle, Giver or Reactive broken.
    function withdraw(uint256 amount) external onlyUser nonReentrant {
        _withdraw(amount);
    }

    /// @notice Switch the automaton on (or re-confirm) with a rule and a total spending budget.
    ///         Replaces the remaining budget; keeps the cooldown clock.
    function activate(Rule calldata r, uint256 budget_) external onlyUser nonReentrant {
        if (
            r.triggerHF < 1e18 || r.targetHF <= r.triggerHF || r.targetHF > 3e18 || r.cooldown < MIN_COOLDOWN
                || r.haircutBps > 2000 || r.maxRepay < MIN_REPAY || r.maxAeroRepay > r.maxRepay
        ) revert BadRule();
        rule = r;
        budget = budget_;
        active = true;
        emit Activated(r, budget_);
    }

    function stop() external onlyUser nonReentrant {
        _stop();
    }

    /// @notice Switch off and take the whole reserve back. A repay already sent to the network may still land first.
    function stopAndWithdraw() external onlyUser nonReentrant {
        _stop();
        _withdraw(reserve);
    }

    function _stop() internal {
        active = false;
        emit Stopped();
    }

    function _withdraw(uint256 amount) internal {
        if (amount > reserve) revert Insufficient();
        if (amount == 0) return;
        reserve -= amount;
        if (!USDC.transfer(USER, amount)) revert TransferFailedUSDC();
        emit Withdrawn(amount);
    }

    // ------------------------------------------------------------------ automaton

    /// @notice Anyone may call. Repays only when the borrower's own rule says so, only from the borrower's reserve.
    ///         Reverts with the reason when there is nothing to do.
    function protect() external nonReentrant returns (uint256 spent) {
        Status st;
        (st, spent) = _run();
        if (st != Status.Repaid) revert NotProtected(st);
    }

    /// @notice Reactive Network timer. A quiet tick logs why it did nothing instead of reverting.
    function protectByReactive(address rvm) external onlyServiceProvider onlyCallbackSender(rvm) nonReentrant {
        (Status st,) = _run();
        if (st != Status.Repaid) emit Skipped(st);
    }

    function _run() internal returns (Status, uint256) {
        if (!active) return (Status.Inactive, 0);
        Stress memory s = stress();
        if (s.status != Status.Repaid) return (s.status, 0);
        Rule memory r = rule;
        if (block.timestamp < lastProtect + r.cooldown) return (Status.Cooldown, 0);

        bool aeroDriven = s.aaveOnlyHF >= r.triggerHF;
        uint256 amount = s.repay;
        uint256 cap = aeroDriven ? r.maxAeroRepay : r.maxRepay;
        if (amount > cap) amount = cap;
        if (amount > reserve) amount = reserve;
        if (amount > budget) amount = budget;
        if (amount < MIN_REPAY) return (Status.NothingToRepay, 0);

        if (gasleft() < GIVER_GAS + HF_GAS + 2 * FINISH_GAS) return (Status.GiverFailed, 0); // not enough gas to finish cleanly
        uint256 before = USDC.balanceOf(address(this));
        if (!USDC.approve(address(GIVER), amount)) revert TransferFailedUSDC();
        uint256 repaid;
        try GIVER.repayOnBehalfOf{gas: GIVER_GAS}(address(SPOKE), USDC_RESERVE, amount, USER) returns (uint256, uint256 rep) {
            repaid = rep;
        } catch {
            if (!USDC.approve(address(GIVER), 0)) revert TransferFailedUSDC();
            return (Status.GiverFailed, 0);
        }
        if (!USDC.approve(address(GIVER), 0) || USDC.allowance(address(this), address(GIVER)) != 0) {
            revert TransferFailedUSDC();
        }
        uint256 spent = before - USDC.balanceOf(address(this));
        if (spent != repaid || spent == 0 || spent > amount) revert GiverMismatch(spent, repaid);

        reserve -= spent;
        budget -= spent;
        lastProtect = block.timestamp;
        uint256 hfAfter; // 0 = could not be read; never undoes the repay
        try SPOKE.getUserAccountData{gas: HF_GAS}(USER) returns (ISpoke.UserAccountData memory d) {
            hfAfter = d.healthFactor;
        } catch {}
        emit Protected(USER, spent, s.stressHF, hfAfter, aeroDriven);
        return (Status.Repaid, spent);
    }

    // ------------------------------------------------------------------ views

    /// @notice 0 open (Aave price is live), 1 closed (feed asleep in the weekend window), 2 data fault
    ///         (feed unreadable, zero / future time, non-positive price, or asleep in session).
    function marketState() public view returns (uint8) {
        address src;
        try ORACLE.getReserveSource{gas: FEED_GAS}(FEED_RESERVE) returns (address a) {
            src = a;
        } catch {
            return 2;
        }
        try IFeed(src).latestRoundData{gas: FEED_GAS}() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return 2;
            if (block.timestamp - updatedAt <= STALE_AFTER) return 0;
            return inWeekendWindow(block.timestamp) ? 1 : 2;
        } catch {
            return 2;
        }
    }

    /// @notice Friday 20:00 UTC to Monday 01:30 UTC (pilot window; DST and holidays are not handled).
    function inWeekendWindow(uint256 ts) public pure returns (bool) {
        uint256 day = (ts / 1 days + 4) % 7; // 0 Sunday .. 6 Saturday
        uint256 sec = ts % 1 days;
        if (day == 6 || day == 0) return true;
        if (day == 5) return sec >= 20 hours;
        if (day == 1) return sec < 1 hours + 30 minutes;
        return false;
    }

    /// @notice Health under stress and the repay that brings it back to target. With the market open this is
    ///         Aave's own HF (same formula; checked against getUserAccountData on a fork).
    function stress() public view returns (Stress memory s) {
        s.debt = SPOKE.getUserTotalDebt(USDC_RESERVE, USER);
        if (s.debt == 0) {
            s.status = Status.Healthy;
            s.market = 3;
            return s;
        }
        s.market = marketState();
        if (s.market == 2) {
            s.status = Status.DataFault;
            return s;
        }
        uint256 usdcPrice = ORACLE.getReservePrice(USDC_RESERVE);
        uint256 haircut = s.market == 1 ? rule.haircutBps : 0;
        // Pools only while the market is closed: on weekdays they trade a little under Chainlink and would trigger for nothing.
        (uint256 cStress, uint256 cAave, bool ok) = _collateral(usdcPrice, haircut, s.market == 1);
        if (!ok) {
            s.status = Status.Unsupported;
            return s;
        }
        uint256 debtValue = s.debt * usdcPrice * 1e12; // 6-dec USDC to the 1e26-per-$ scale
        s.stressHF = cStress.mulDiv(1e18, debtValue);
        s.aaveOnlyHF = cAave.mulDiv(1e18, debtValue);
        if (s.stressHF >= rule.triggerHF) {
            s.status = Status.Healthy;
            return s;
        }
        uint256 allowed = cStress.mulDiv(1e18, uint256(rule.targetHF) * usdcPrice * 1e12); // floor
        if (s.debt > allowed) s.repay = s.debt - allowed; // so the repay rounds up, by at most 1 unit
        s.status = Status.Repaid;
    }

    /// @dev Σ supplied × price × CF over the user's enabled collateral, in Aave's 1e26-per-$ value scale.
    ///      `ok` is false for a position this pilot does not handle (debt outside USDC, USDC as collateral).
    function _collateral(uint256 usdcPrice, uint256 haircutBps, bool usePools)
        internal
        view
        returns (uint256 cStress, uint256 cAave, bool ok)
    {
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            (bool collateral, bool borrowing) = SPOKE.getUserReserveStatus(r, USER);
            if (r == USDC_RESERVE) {
                if (collateral) return (0, 0, false);
                continue;
            }
            if (borrowing) return (0, 0, false);
            if (!collateral) continue;
            uint256 amt = SPOKE.getUserSuppliedAssets(r, USER);
            if (amt == 0) continue;
            uint256 cf = SPOKE.getDynamicReserveConfig(r, SPOKE.getUserPosition(r, USER).dynamicConfigKey).collateralFactor;
            uint256 scale = 10 ** (18 - uint256(SPOKE.getReserve(r).decimals));
            uint256 pAave = ORACLE.getReservePrice(r) * (10_000 - haircutBps) / 10_000;
            uint256 p = pAave;
            address pool = poolOf[r];
            if (usePools && pool != address(0)) {
                try this.poolPriceUSD{gas: POOL_GAS}(pool, usdcPrice) returns (uint256 pPool) {
                    if (pPool != 0 && pPool < p) p = pPool;
                } catch {} // thin pool or short history: this stock on Aave's price only
            }
            cStress += amt * p * scale * cf / 10_000;
            cAave += amt * pAave * scale * cf / 10_000;
        }
        ok = true;
    }

    /// @notice 60-min TWAP of the stock in its Aero USDC pool, in 8-dec USD (USDC quote × Aave's USDC price).
    ///         Reverts when the pool is thinner than MIN_POOL_LIQUIDITY or has no 60-min history.
    function poolPriceUSD(address pool, uint256 usdcPrice) external view returns (uint256) {
        if (ICLPool(pool).liquidity() < MIN_POOL_LIQUIDITY) revert BadPool(0);
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        (int56[] memory cum,) = ICLPool(pool).observe(ago);
        if (cum.length != 2) revert BadPool(0);
        int56 delta = cum[1] - cum[0];
        int24 tick = int24(delta / int56(uint56(TWAP_WINDOW)));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) tick--;
        uint256 sq = SUGAR.getSqrtRatioAtTick(tick);
        uint256 x = sq.mulDiv(sq, 1 << 64); // price × 2^128
        uint256 k = 10 ** (uint256(stockDec[pool]) + 2); // to 8-dec USDC per whole stock (USDC has 6)
        uint256 inUsdc = usdc0[pool] ? (uint256(1) << 128).mulDiv(k, x) : x.mulDiv(k, 1 << 128);
        return inUsdc * usdcPrice / 1e8;
    }
}
