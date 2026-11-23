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
}

interface ISugarHelper {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title Shield — one-seat automaton that repays an Aave V4 stock-loan before a weekend gap reaches the oracle.
/// @notice The borrower keeps a USDC reserve here. When the position's health under stress (each stock priced at the
///         lower of Aave's price and the 60-min TWAP of its Aero pool on Base, with an optional extra haircut while
///         the market is closed) falls under the borrower's trigger, the vault repays part of the USDC debt through
///         Aave's GiverPositionManager, back up to the borrower's target. Reactive Network wakes it on a timer;
///         anyone may also call `protect()`, which only ever spends the borrower's reserve on the borrower's own debt.
///         Money can only move vault -> Giver -> this borrower's debt, or vault -> borrower. No admin, no sweep.
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

    struct Stress {
        uint256 debt; // USDC units, drawn + premium
        uint256 stressHF; // WAD
        uint256 aaveOnlyHF; // WAD, same but without the pool prices
        uint256 repay; // USDC units needed to reach target (before caps)
        uint8 market; // 0 open, 1 closed, 2 data fault
    }

    uint256 public constant USDC_RESERVE = 7;
    uint32 public constant TWAP_WINDOW = 3600;
    uint256 public constant MIN_REPAY = 1e6; // $1
    uint32 public constant MIN_COOLDOWN = 15 minutes;
    uint256 public constant STALE_AFTER = 2 hours;

    ISpoke public immutable SPOKE;
    IAaveOracle public immutable ORACLE;
    IGiver public immutable GIVER;
    IERC20 public immutable USDC;
    ISugarHelper public immutable SUGAR;
    address public immutable USER; // the one seat
    uint256 public immutable FEED_RESERVE; // stock whose feed tells open / closed / fault

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
    event Protected(uint256 spent, uint256 stressHFBefore, uint256 nativeHFAfter, bool aeroDriven);
    event Skipped(bytes4 reason);

    error NotUser();
    error BadRule();
    error Inactive();
    error Healthy();
    error Cooldown();
    error DataFault();
    error NothingToRepay();
    error OtherDebt();
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

    /// @param pools_ Aero USDC pool of each stock reserve in `reserves_`; zero = no pool, Aave price only.
    constructor(
        ISpoke spoke_,
        IGiver giver_,
        IERC20 usdc_,
        ISugarHelper sugar_,
        address callbackProxy_,
        address reactive_,
        address user_,
        uint256 feedReserve_,
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
        if (spoke_.getReserve(USDC_RESERVE).underlying != address(usdc_)) revert BadPool(USDC_RESERVE);
        for (uint256 i; i < reserves_.length; ++i) {
            address p = pools_[i];
            if (p == address(0)) continue;
            address stock = spoke_.getReserve(reserves_[i]).underlying;
            address t0 = ICLPool(p).token0();
            address t1 = ICLPool(p).token1();
            bool u0 = t0 == address(usdc_);
            if (!(u0 && t1 == stock) && !(t0 == stock && t1 == address(usdc_))) revert BadPool(reserves_[i]);
            poolOf[reserves_[i]] = p;
            usdc0[p] = u0;
            stockDec[p] = spoke_.getReserve(reserves_[i]).decimals;
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
    function withdraw(uint256 amount) public onlyUser nonReentrant {
        if (amount > reserve) revert Insufficient();
        reserve -= amount;
        if (!USDC.transfer(USER, amount)) revert TransferFailedUSDC();
        emit Withdrawn(amount);
    }

    /// @notice Switch the automaton on (or re-confirm) with a rule and a total spending budget.
    ///         Replaces the remaining budget; keeps the cooldown clock.
    function activate(Rule calldata r, uint256 budget_) external onlyUser {
        if (
            r.triggerHF < 1e18 || r.targetHF <= r.triggerHF || r.targetHF > 3e18 || r.cooldown < MIN_COOLDOWN
                || r.haircutBps > 2000 || r.maxRepay < MIN_REPAY || r.maxAeroRepay > r.maxRepay
        ) revert BadRule();
        rule = r;
        budget = budget_;
        active = true;
        emit Activated(r, budget_);
    }

    function stop() public onlyUser {
        active = false;
        emit Stopped();
    }

    /// @notice Switch off and take the whole reserve back. A repay already sent to the network may still land first.
    function stopAndWithdraw() external {
        stop();
        withdraw(reserve);
    }

    // ------------------------------------------------------------------ automaton

    /// @notice Anyone may call. Repays only when the borrower's own rule says so, only from the borrower's reserve.
    function protect() external nonReentrant returns (uint256 spent) {
        return _protect();
    }

    /// @notice Reactive Network timer. Never reverts on "nothing to do" so a quiet tick costs only gas.
    function protectByReactive(address rvm) external onlyServiceProvider onlyCallbackSender(rvm) {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        try this.protectSelf() {} catch (bytes memory err) {
            emit Skipped(err.length >= 4 ? bytes4(err) : bytes4(0));
        }
        locked = 1;
    }

    /// @dev Only the vault itself (from `protectByReactive`), so the Reactive path can catch a revert.
    function protectSelf() external {
        if (msg.sender != address(this)) revert NotUser();
        _protect();
    }

    function _protect() internal returns (uint256 spent) {
        if (!active) revert Inactive();
        Rule memory r = rule;
        Stress memory s = stress();
        if (s.market == 2) revert DataFault();
        if (s.debt == 0 || s.stressHF >= r.triggerHF) revert Healthy();
        if (block.timestamp < lastProtect + r.cooldown) revert Cooldown();

        bool aeroDriven = s.aaveOnlyHF >= r.triggerHF;
        uint256 amount = s.repay;
        uint256 cap = aeroDriven ? r.maxAeroRepay : r.maxRepay;
        if (amount > cap) amount = cap;
        if (amount > reserve) amount = reserve;
        if (amount > budget) amount = budget;
        if (amount < MIN_REPAY) revert NothingToRepay();

        uint256 before = USDC.balanceOf(address(this));
        USDC.approve(address(GIVER), amount);
        (, uint256 repaid) = GIVER.repayOnBehalfOf(address(SPOKE), USDC_RESERVE, amount, USER);
        USDC.approve(address(GIVER), 0);
        spent = before - USDC.balanceOf(address(this));
        if (spent != repaid || spent == 0 || spent > amount) revert GiverMismatch(spent, repaid);

        reserve -= spent;
        budget -= spent;
        lastProtect = block.timestamp;
        emit Protected(spent, s.stressHF, SPOKE.getUserAccountData(USER).healthFactor, aeroDriven);
    }

    // ------------------------------------------------------------------ views

    /// @notice 0 open (Aave price is live), 1 closed (feed asleep in the weekend window), 2 data fault (asleep in session).
    function marketState() public view returns (uint8) {
        (,,, uint256 updatedAt,) = IFeed(ORACLE.getReserveSource(FEED_RESERVE)).latestRoundData();
        if (block.timestamp - updatedAt <= STALE_AFTER) return 0;
        return inWeekendWindow(block.timestamp) ? 1 : 2;
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

    /// @notice Health under stress and the repay that brings it back to target. Same math as Aave's own HF
    ///         (checked against getUserAccountData when there is no stress).
    function stress() public view returns (Stress memory s) {
        s.market = marketState();
        s.debt = SPOKE.getUserTotalDebt(USDC_RESERVE, USER);
        if (s.debt == 0) return s;
        uint256 usdcPrice = ORACLE.getReservePrice(USDC_RESERVE);
        uint256 haircut = s.market == 1 ? rule.haircutBps : 0;
        // Pools only while the market is closed: on weekdays they trade a little under Chainlink and would trigger for nothing.
        (uint256 cStress, uint256 cAave) = _collateral(usdcPrice, haircut, s.market == 1);
        uint256 debtValue = s.debt * usdcPrice * 1e12; // 6-dec USDC to the 1e26-per-$ scale
        s.stressHF = cStress.mulDiv(1e18, debtValue);
        s.aaveOnlyHF = cAave.mulDiv(1e18, debtValue);
        uint256 target = rule.targetHF;
        if (target == 0) return s;
        uint256 allowed = cStress.mulDiv(1e18, target * usdcPrice * 1e12); // floor: never repay less than needed
        if (s.debt > allowed) s.repay = s.debt - allowed;
    }

    /// @dev Σ supplied × price × CF over the user's enabled collateral, in Aave's 1e26-per-$ value scale.
    function _collateral(uint256 usdcPrice, uint256 haircutBps, bool usePools)
        internal
        view
        returns (uint256 cStress, uint256 cAave)
    {
        uint256 n = SPOKE.getReserveCount();
        for (uint256 r; r < n; ++r) {
            (bool collateral, bool borrowing) = SPOKE.getUserReserveStatus(r, USER);
            if (borrowing && r != USDC_RESERVE) revert OtherDebt();
            if (!collateral || r == USDC_RESERVE) continue;
            uint256 amt = SPOKE.getUserSuppliedAssets(r, USER);
            if (amt == 0) continue;
            uint256 cf = SPOKE.getDynamicReserveConfig(r, SPOKE.getUserPosition(r, USER).dynamicConfigKey).collateralFactor;
            uint256 dec = SPOKE.getReserve(r).decimals;
            uint256 pAave = ORACLE.getReservePrice(r) * (10_000 - haircutBps) / 10_000;
            uint256 p = pAave;
            address pool = poolOf[r];
            if (usePools && pool != address(0)) {
                try this.poolPriceUSD(pool, usdcPrice) returns (uint256 pPool) {
                    if (pPool != 0 && pPool < p) p = pPool;
                } catch {} // no usable history: Aave branch only
            }
            uint256 scale = 10 ** (18 - dec);
            cStress += amt * p * scale * cf / 10_000;
            cAave += amt * pAave * scale * cf / 10_000;
        }
    }

    /// @notice 60-min TWAP of the stock in its Aero USDC pool, in 8-dec USD (USDC quote × Aave's USDC price).
    function poolPriceUSD(address pool, uint256 usdcPrice) external view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        (int56[] memory cum,) = ICLPool(pool).observe(ago);
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
