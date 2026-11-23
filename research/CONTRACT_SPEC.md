# Shield automaton — contract spec and expected results (block 2, draft for Codex, 23 Nov 2026)

Goal: a borrower on the Aave V4 Equities Spoke (Base) leaves a USDC reserve in our contract once. The contract, woken by Reactive (and by a backup bot), repays part of their USDC debt **before** a gap reaches the oracle — including weekends, when the Aave/Chainlink stock feeds are frozen but the Aero pools keep trading. The user can stop and take everything back at any time.

## Facts it relies on (checked on chain / in source)
- Spoke `0x17905Db0…7B8D`, USDC reserve id 7, 8 stock collateral reserves; HF = Σ(supplied_i · price_i · CF_i[user dynamicConfigKey]) / debt — our formula matched Aave to 4 decimals on all borrowers (hf_check.py).
- A third party can only repay for a user through an active position manager. GiverPositionManager `0x9e81c2fd…5f08`: `repayOnBehalfOf(spoke, reserveId, amount, onBehalfOf)` pulls USDC from `msg.sender`, caps at the user's debt, forbids max-uint. The user must once call `Spoke.setUserPositionManager(Giver, true)`. Fork test already passed this path.
- Feeds freeze from Friday ~21:00 UTC to Monday 01:00 UTC. Aero USDC pools of all 8 stocks trade 24/7 (tickSpacing 10, have `observe`). Pools exist only since ~23 Oct → 5 weekends of history.
- Stock tokens are chain built-ins (code 0xef); a fork cannot move them. The repay path never moves stock tokens, so it runs fully real on a fork.

## Contract `ShieldVault` (Base)
State per user: `reserve` (USDC held for them), `rule {triggerBps, targetBps, maxRepay, cooldown, weekendHaircutBps}`, `lastProtect`, `active`.

| Function | Who | Does |
|---|---|---|
| `deposit(amount)` | user | pulls USDC into the user's reserve |
| `setRule(trigger, target, maxRepay, cooldown, haircut)` | user | trigger < target, target ≤ 3.0, haircut ≤ 20% |
| `withdraw(amount)` | user | returns reserve USDC, any time, even when paused |
| `stopAndWithdraw()` | user | `active=false` + returns the whole reserve |
| `protect(user)` | anyone (Reactive callback, backup bot) | see below; reverts if nothing to do |
| `checkAll(start, n)` | Reactive callback only | loops active users, `protect` on those under trigger, never reverts the batch |

### `protect(user)`
1. `stressHF` = HF with each collateral price = **min(Aave price, Aero 60-min TWAP)**; during the freeze window (Fri 21:00 – Mon 01:00 UTC, by timestamp) each price additionally × (1 − haircut). Collateral without a pool: Aave price × (1 − haircut) in the window.
2. If `stressHF ≥ trigger` → revert `Healthy`.
3. If `block.timestamp < lastProtect + cooldown` → revert `Cooldown`.
4. `repay = debt − Σ(stress collateral value)/target`, capped by `reserve`, `maxRepay`, and the actual debt. Zero → revert.
5. `reserve -= repay`; approve Giver exactly `repay`; `Giver.repayOnBehalfOf(spoke, 7, repay, user)`; refund any part not taken back to the reserve; emit `Protected(user, repay, stressHF_before, HF_after)`.
- Funds can only ever move: user → vault → Giver → the user's own debt, or vault → user. No owner withdraw, no admin over user money.

## Reactive (Reactive mainnet → Base)
Cron timer like lp-guard v1.1 (`Cron1000`-type topic) → callback `checkAll` every ~10 min on weekends, ~30 min on weekdays (cost check: lp-guard hourly ≈ 1.2 REACT/day). Has `withdraw(REACT)` and `stop()` from day one (lesson of lp-guard v1.0). Backup executor: a tiny script anyone can run that calls `protect(user)`.

## Expected results ("done" for block 2) — all on a Base fork with a real borrower
1. Under trigger → one `protect` lowers the user's debt and our reserve by the same amount; HF after ≥ target (or reserve exhausted).
2. A second `protect` inside the cooldown reverts; after cooldown, if still under trigger, it repays again but never more than `maxRepay`.
3. Above trigger → `protect` reverts, nothing moves.
4. Weekend gap scenario: freeze the Aave feed (mock), move the Aero pool down by X% with a real swap on the fork, wake `protect` on Sunday → repay happens; then Monday print with the same gap → liquidation fails (HealthFactorNotBelowThreshold). Same gap without the vault → liquidation succeeds.
5. `stopAndWithdraw` returns exactly the remaining reserve; after it `protect` does nothing.
6. User never approved Giver → `protect` reverts cleanly, reserve intact.
7. Archive (weekend_archive.json): for 5 weekends × 8 stocks, how often the TWAP 1 h / 3 h before the print points the right way for moves >1 % → sets the default haircut.

## Revision 1 after Codex (23 Nov) — these override the draft above
1. **Units.** `D` = live USDC debt (drawn + premium) read inside `protect`; `P` = Aave price of 1 USDC unit (oracle, capped); `C` = Σ stress value × CF of the user's *enabled* collateral, each with its own `dynamicConfigKey`. `D_allowed = floor(C·10_000 / (T·P))`, `repay = min(max(0, D − D_allowed), reserve, maxRepay, budgetLeft)`. Users with any debt outside reserve 7 are skipped. With stress off, our HF must equal Aave's (test).
2. **Stress price = min(Aave × (1 − haircut), Aero TWAP in USD)** — haircut is a scenario from the last Aave print, not stacked on the pool. Aero USDC quote → USD with Aave's USDC price. Negative-tick TWAP rounds down. Haircut applies only in the "scheduled closure" state; it is a user parameter (default 0 until validated — the 5-weekend archive is research, not a default).
3. **Spending limits.** Deposit is separate from `activate(rule, budget)`; `budget` = total the automaton may spend until the user re-confirms. Minimum repay (e.g. $1), minimum cooldown (≥ 15 min). Deposit after `stop` does not re-activate.
4. **Pool safety.** A pool is accepted only from the Aero factory, right pair, `observe` covering 60 min, in-range liquidity ≥ a floor. Bad pool data → Aero branch off for that stock, Aave branch stays; one Aero-only signal may spend at most `maxRepay`.
5. **Closure state per feed:** open / scheduled closure (from Friday's last print until the next fresh print of that feed) / data fault (stale in session) — fault = no haircut, event emitted.
6. **Giver call:** `forceApprove(Giver, repay)` → call → `forceApprove(Giver, 0)`; `spent = balBefore − balAfter`; require `spent == repaidAmount` and `0 < spent ≤ repay`; reserve and budget reduced by `spent`; `lastProtect` set only after a positive payment.
7. **Invariants:** fixed immutable Spoke / USDC / Giver / reserve 7; no arbitrary calls, no admin sweep; `nonReentrant`; `USDC.balanceOf(vault) ≥ Σ reserve`; `withdraw` touches nothing but the user's own balance (works with oracle, Giver, Reactive all broken). Callback = `checkBatch(address rvmId, uint256 n)` — checks proxy as `msg.sender` **and** our Reactive contract in `rvmId`.
8. **Batch:** cap active users for the pilot (≤ 20), persistent cursor, each user in `try this.protectFor(...)` with a gas limit, prices read once per batch; gas measured healthy / 8-collateral worst case / repay / failure.
9. **Reactive cadence:** what the Cron topics really give (Cron1000 ≈ 17 min?) — read the docs, measure REACT per tick and Base ETH per callback before choosing; `stop()` and REACT `withdraw` separate from user funds.
10. **Setup path:** user signs `Spoke.setUserPositionManager(Giver, true)`, `USDC.approve(vault)`, `deposit`, `activate`. A minimal setup page is only the switch for the automaton, not the product; exit must also work straight from the verified contract on Basescan.
11. **Scope to 5 Dec:** fork demo with all branches + one live pilot on Base with the owner's small position + one real Reactive → Base callback. Later: public deposits, Taker/flash loans, other markets, default haircut.

### Acceptance tests (replace the 7 above)
1. Spent USDC = reserve drop = Giver's `repaidAmount`; debt delta matches within Aave precision; `stressHF_after ≥ target` or a stated limiter (reserve / maxRepay / budget / rounding).
2. Partial repay leaves the user under trigger → second call inside cooldown reverts (`cooldown − 1` and exact boundary, same block), after cooldown repays again, stops at budget.
3. `stressHF == trigger`, `D = 0`, dust, zero reserve → nothing moves (balances, allowance, `lastProtect`).
4. One position, one Monday print, three branches: early repay → liquidation reverts `HealthFactorNotBelowThreshold`; no repay → liquidation succeeds (stock transfer simulated, said so in the video); late repay → liquidated anyway.
5. Exit: exact withdraw with pause, revoked Giver, broken oracle; after stop nothing runs (manual, batch, after top-up).
6. Giver not approved / revoked / Giver call reverts → reserve, allowance, cooldown unchanged; next user in the batch still processed.
7. Two users + balance invariant; pull ≠ repay mismatch reverts; `observe` too short → Aero branch off; mixed collateral; closure boundary; forged callback rejected; worst-case gas.
8. Live: one real Reactive → Base callback hash; one real autonomous repay hash on the owner's position; withdraw of the remainder hash.

## Revision 2 after Codex round 2 (23 Nov) — final for coding
- **One seat for the 5 Dec pilot.** No batch, no cursor, no self-call: Reactive callback `protectByReactive(address rvmId)` acts on the single configured user; `protect()` (anyone) runs the same math. Batch over many users waits until after the contest.
- **Units fixed.** `D` in USDC base units (6 dec); prices from the Spoke oracle (`getReservePrice`, 8-dec USD); values in Aave's 1e26-per-$ scale exactly as hf_check.py; `D == 0` → exit before any math; all divisions round **against** repaying (floor `D_allowed` → ceil `repay` to 1 unit only if > 0).
- **Pool quote:** token order and decimals read once in the constructor and stored; USD = USDC-quote × Aave USDC price.
- **Closure state (pilot):** one feed. Closed = feed `updatedAt` older than `staleAfter` (default 2 h) **and** now inside a hard-coded window Fri 20:00 – Mon 01:30 UTC; in session and stale = **fault → no repay at all** (not "no haircut"); open = Aave price only, no Aero signal needed. DST/holidays: pilot window covers the next 2 weekends only; logged as a known limit.
- **Aero-only cap:** a repay driven only by the pool price (Aave price alone would not trigger) is capped by `maxAeroRepay` (small, e.g. 25% of budget).
- **Deposit credits actual received USDC** (`balanceAfter − balanceBefore`). `Protected(user, spent, stressBefore, nativeHFAfter)` reports the real `spent`.
- **activate(rule, budget)** replaces the remaining budget, keeps `lastProtect`, validates the rule; there is no separate `setRule`.
- `stopAndWithdraw` is not front-run-proof: an allowed repay already in the mempool can land first (said on the setup page).
- Deployment manifest checked by RPC before deploy: reserve 7 underlying = USDC, Giver registered + active on the Spoke, pool factory + pair, callback proxy `0xCc780DdE…4a068`, our Reactive address. Runtime size measured with `forge build --sizes`.
- Reactive: measure one empty and one working tick on mainnet (REACT + Base ETH), choose cadence after that; top-up threshold = 3 days of measured spend.

## Open questions for review
- Is a permissionless `protect` safe (griefing = repaying someone's debt with their own reserve only when the rule says so)?
- Freeze window by timestamp vs by "feed not updated for N hours" (holidays, early closes)?
- TWAP manipulation on a $0.4–1.5M pool: worst case is a *lower* price → early repay with the user's own money (no theft path). Acceptable?
