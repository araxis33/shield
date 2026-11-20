# Shield — fact pack (20 Nov 2026)

Everything below was read on Base mainnet or in the Aave V4 source (github.com/aave/aave-v4, commit 4885a7a, 13 Nov 2026) in this session unless marked "19.11".

## The market
- Aave V4 "Equities Hub" on Base. Spoke `0x17905Db0e4A3514467539956c084180616AE7B8D`. 9 reserves: AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc, SPCXc (collateral) + USDC (borrowed). CF 55–79 %, liquidation bonus 5.5 % (SPCXc 6.5 %).
- 19.11 scan: 547 borrowers ever, 308 with debt now, $7.73M debt / $16.9M collateral, 126 with debt >= $1K. HF < 1.11: 11 users, ~$9K debt. HF 1.11–1.25: 38 users, ~$981K debt (one whale HF 1.18, $201K debt). 35 liquidations of 31 users since 25 Sep. Liquidations mostly on weekdays in US hours; only 3 of 35 on a Monday. "1 - 1/HF" is only a rough distance-to-liquidation; real distance needs each user's collateral mix.

## Oracle (read today)
- Spoke ORACLE `0xaBaf048fD7675Ea34a84332371ffd5D55E322A47`, per-reserve sources: "Coinbase AAPL" 0x787f…F988, "Coinbase AMZN" 0x06A8…B295, "Coinbase GOOGL" 0x5bF4…34F2, "Coinbase META" 0x6526…b27D, "Coinbase MSFT" 0xeB10…b18c, "Coinbase NVDA" 0x0468…8513 (aggregator 0xF72B…9675), "Coinbase TSLA" 0xFaf8…DCb4, "Coinbase SPCX" 0x6A63…3Fa68, USDC "Capped USDC/USD".
- Feeds update on deviation (~0.5 % steps) during market hours. Weekend 13–16 Nov: **zero updates** on all 8 feeds between Friday ~21:00–23:40 UTC and Monday 01:00 UTC (Sunday 20:00 ET).
- First print Monday 01:00 UTC vs last Friday print: AAPL +0.60 %, AMZN +0.62 %, META +0.78 %, MSFT +0.52 %, NVDA +2.55 %, SPCX +2.56 %, TSLA +0.88 %. Lowest point by Monday 20:30 UTC vs Friday: NVDA −3.23 %, AMZN −2.92 %, TSLA −2.75 %, META −2.42 %.
- One weekend only. Liquidations at the reopen print happen in the first block that has the new price.

## Base pools trade 24/7 — the early signal
- NVDAc main Aero pool `0xf668e21993f0acd7ab00bb1cfbaed0df28a3c8ec` (~$1.7M liquidity, ~$16.9M volume/day on 19.11), archive slot0 every 3 h: Fri 20:00 162.97 · Sat 17:00 159.45 · Sun 02:00 158.02 (−1.7 % vs Friday oracle) · Sun 20:00 163.78 · **Sun 23:00 165.13 (+2.7 %)** → oracle first print Mon 01:00 = **164.86 (+2.55 %)**. Pool led the reopen print by ~2 h in this one weekend.
- 18.11 (earlier session): 10 big c-stocks traded 0.3–0.65 % below Chainlink in pools on a weekday.

## How a third party can act on an Aave V4 position (source + chain)
- Spoke functions supply/withdraw/borrow/repay take `onBehalfOf` and require `msg.sender == onBehalfOf` or an **active** position manager the user approved (`_isPositionManager`: `config.active && config.approval[user]`). Activating a manager is admin-only (`updatePositionManager`, restricted). A new contract of ours cannot become a manager.
- Active managers on this Spoke (UpdatePositionManager events, all `active=true`, registered for this Spoke):
  - **GiverPositionManager `0x9e81c2fde4e34cab3ab1667ca3c932dbaed95f08`** — `repayOnBehalfOf(spoke, reserveId, amount, onBehalfOf)` and `supplyOnBehalfOf`: anyone pays from **their own** funds for the user (caps repay at the user's debt, max-uint not allowed).
  - **TakerPositionManager `0x8481204e528735af2f3391ad98f36e757a56d695`** — user calls `approveWithdraw(spoke, reserveId, spender, amount)` (or signs `approveWithdrawWithSig`); then `spender` calls `withdrawOnBehalfOf` and **receives the withdrawn collateral**. Allowance is per reserve, per spender, consumed by the actual change. Also borrow allowances.
  - ConfigPositionManager `0xe90f…daaf`, a signature gateway `0x5d48…05a7`, one more `0xdfc1…b70d`.
- The user must first approve Giver/Taker as their position managers on the Spoke (`setUserPositionManager(manager, true)` or `setSelfAsUserPositionManagerWithSig` via the manager). So far only ~7 addresses ever did (SetUserPositionManager events) — nobody builds on this path yet.
- Spoke `withdraw` checks health after the withdrawal, so pulling collateral first on a weak position fails; repay must come first (own buffer or a flash loan, e.g. Morpho Blue on Base — free flash loans, not yet checked for USDC depth).

## Reactive (our stack, live)
- Our guard already runs on Reactive mainnet → Base callbacks (Cron + callback proxy, ~1.2 REACT/day, hourly checks). Reactive can also subscribe to Base events (feed AnswerUpdated, pool Swap) and call back into a Base contract.

## Contest (Base Stocks Maxxing)
- Deadline 5 Dec 23:59 UTC; Loom video in X tagging @buildonbase + form. Track "Programmable": idea 3.3 "loans against stocks with overnight gaps and transfer pauses"; "Show us" must include the failure case. Testnet allowed and not scored lower. No trading for US residents. Aave V4 has no public Base Sepolia deployment (only a Tenderly fork testnet).
- Competitors seen: afterbook, StoxCredit, ZEUS vault, FrostyFi (lending / vaults) — none protects existing Aave borrowers.
- Our constraints: owner has no money to buy stocks; ~$20 in the LP guard; build-in-public posts with @buildonbase. "Shield" stays private in public posts until the tool exists.

## Verified 20 Nov, day 1
- **Mixed-collateral HF formula matches Aave exactly**: HF = Σ(suppliedAssets_i × price_i × 10^(18−dec_i) × CF_i[user's dynamicConfigKey]) / debtValue; $1 = 1e26 value units. `hf_check.py` recomputes every borrower (see hf_check.log).
- **Manual repay**: `Spoke.repay(7, amount, user)` from the borrower's own wallet; USDC `approve` goes to the **Spoke** (it does `transferFrom(msg.sender → hub)`). No position manager needed.
- **Fork, real borrower 0x01dbdb97…a362 (HF 1.326, $39.3K USDC debt, GOOGLc largest)**, all 4 branches pass (`test/Fork.t.sol`): a 26 % gap liquidates the untouched position (119.6 GOOGLc taken); repaying $2,572 beforehand keeps HF at 1.05 after the same gap and liquidation fails; the same repay through GiverPositionManager by a third party after the borrower approved Giver works; a repay that arrives after the print is too late.
- **Coinbase stock tokens on Base are chain built-ins**: their code is the single byte `0xef` (e.g. GOOGLc 0xb200…58B7). Base nodes run them, Foundry/anvil cannot (OpcodeNotFound on `transfer`). On a fork, anything that moves a stock token (liquidation, withdraw, swap) needs the token transfer simulated; repay paths don't touch stock tokens and run fully real. Selling collateral (option C) cannot be fork-tested honestly → another reason it waits.
- Foundry needs `evm_version = "osaka"` for this fork.
- hf_check: 145 real borrowers (debt >= $1) recomputed before the 30-min run limit, **0 mismatches** (> 0.1 %), $3.38M of debt covered. Market grew since 19.11: borrowers with $997K (HF 1.40), **$587K (HF 1.157)**, $430K (HF 1.39), $236K (HF 1.33) debt.
