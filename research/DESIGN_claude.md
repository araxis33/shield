# Shield — design, Claude's draft (20 Nov 2026)

## 1. Who loses money and when
Borrower on the Aave V4 Equities Hub on Base: c-stock collateral, USDC debt. 308 such borrowers now, 49 of them at HF < 1.25 (~$990K debt, 19.11).

Three moments:
1. **Monday reopen print.** All 8 feeds freeze from Friday ~21:00 UTC to Monday 01:00 UTC. The first print can jump 2.5 % in one block (NVDA, SPCX on 16 Nov). Liquidators backrun that print. A borrower asleep in Europe/Asia loses 5.5–6.5 % of the liquidated slice.
2. **Weekday slide.** Most of the 35 liquidations happened Wed–Thu in US hours: a steady fall the user didn't watch.
3. **Rescue that comes too late.** By the time the user sees the price, the only manual fix is to buy USDC and repay. That costs a swap, and on a weekend there is no reference price to judge it.

## 2. What the page shows (read-only, mainnet, no money needed)
Paste an address (or connect a wallet):
- per collateral: amount, oracle price, **frozen?** (time since last update), Base pool price now, gap pool vs oracle in %;
- **HF now** (Spoke `getUserAccountData`) and **HF at the reopen**: recompute the position with each collateral repriced at its Base pool price (TWAP of the last hour, not spot) → "if the market opened at the Base price, your HF would be 1.04";
- **distance to liquidation per stock**: how far each stock alone may fall before HF = 1. Plus the "everything falls together" number. Exact maths from the collateral mix and each reserve's collateral factor, not 1 − 1/HF;
- **cost of fixing now**: USDC to repay to get back to a target HF (e.g. 1.25), and the same as "sell X NVDAc";
- a "Monday board" for the whole market: borrowers whose reopen-HF < 1 at current Base prices, total debt at risk. This is public data, so it's real on mainnet from day one and makes a strong video and post.

## 3. Protective actions (from weakest to strongest)
a) **Alert** (Telegram bot / page notification) when reopen-HF or live HF crosses the user's line. No permissions. Fails if the user sleeps.
b) **Buffer repay**: the user deposits USDC into the Shield vault (theirs, withdrawable any time). When the trigger fires, the vault calls `Giver.repayOnBehalfOf(spoke, USDC reserve, amount, user)`. Permissions: the user approves Giver as position manager on the Spoke (Giver can only pay *in*: supply/repay from the caller's funds; it can't take anything). Worst case if our vault is buggy: it repays the user's debt too early or too much. That's the user's own money paying the user's own debt, so no loss, just less flexibility. Cost: gas only. **This is the safe flagship.**
c) **Atomic deleverage** (no buffer needed): flash-borrow USDC from Morpho Blue (free, $186.7M USDC on Base) → `Giver.repayOnBehalfOf` → `Taker.withdrawOnBehalfOf(spoke, collateral reserve, amount, user)` (collateral comes to our contract) → sell on the Aero pool with a min-out → repay flash, any USDC left goes to the user. Permissions: user approves Giver + Taker as managers and calls `Taker.approveWithdraw(spoke, reserveId, shield, cap)` with a **cap**. Worst case if our contract is malicious: it can withdraw up to the cap and sell it badly. So the cap, a min-out tied to the oracle (and the pool TWAP on weekends), a max-slice per call, and a "only when HF < trigger" check enforced in the contract. Cost: pool fee (0.015–0.17 %) + slippage. In the top pools ($0.4–1.5M) a slice of a few thousand dollars costs well under 1 %, against a 5.5 % bonus. Fails when the pool is thin or the slice too large → split into slices over several calls.

## 4. Who triggers, and the honest timing
- A protective tx **cannot reliably beat liquidators inside the reopen block**: the feed update lands, liquidators backrun it in the same block, our Reactive callback arrives seconds later. So Shield must act **before** the reopen: on Sunday evening, when the 24/7 Base pool already shows where the print will land (the 16 Nov pool was +2.7 % at 23:00 UTC vs the +2.55 % print at 01:00).
- During the freeze the Spoke still values collateral at Friday's price, so both buffer repay and deleverage work on the weekend (withdraw passes the health check at the frozen price, we sell at the real weekend price).
- Weekday: trigger on live HF from the feed's AnswerUpdated events.
- Triggers via Reactive (our stack: Cron for the Sunday window + subscriptions to the feeds and pool Swaps). Also a public `protect(user)` anyone can call: it only works when the on-chain condition holds, so keepers and the user themself are a fallback.

## 5. MVP by 5 Dec, nobody's money
- **Mainnet, real:** the page (section 2) and the Monday board over all real borrowers. The Shield contract deployed on Base: `protect` with buffer repay (b), and deleverage (c) if it passes Codex + fork tests. Reactive trigger on mainnet.
- **Fork (anvil, Base mainnet state):** impersonate a real borrower, approve managers, push the NVDA feed to the reopen print (a mocked aggregator answer), show: without Shield → liquidated, −5.5 %; with Shield → deleverage on Sunday 23:00 at pool price, HF back to 1.3, liquidation impossible. Failure case: thin pool → min-out reverts, Shield splits into slices; feed stale + pool gap > X % → Shield refuses to act at a bad price and only alerts.
- **Loom < 3 min:** Monday board on mainnet → one real borrower's reopen-HF → fork replay of the weekend: with vs without Shield → the failure case → "works today, read-only for everyone, protection for those who opt in".
- Waits until after 5 Dec: Telegram alerts for all users, fees, multi-slice routing across several pools, the borrow-allowance side of Taker.

## 6. Verify on-chain first (kills or confirms the design)
1. A real user can approve Giver and Taker on this Spoke and `withdrawOnBehalfOf` delivers collateral to our contract: fork test with a real borrower.
2. Spoke `withdraw` during the weekend freeze: health check at the frozen price passes (fork at a Saturday block).
3. More weekends: does the Base pool lead the reopen print every time, and by how much? (13–16 Nov is one sample; take 4–6 weekends, all 8 stocks.)
4. Liquidation bonus V4 depends on HF ("bonus V4 depends on HF and reserve settings"): compute the real loss per liquidation from the 35 events, not 5.5 % flat.
5. Pool depth for MSFTc, SPCXc, TSLAc (GeckoTerminal returned nothing) and slippage for $1K/$10K/$50K slices in each top pool.

## 7. Money
Read-only page free (and the reason people come). Protection: a fee only when it acts, e.g. 0.5 % of the repaid slice, which is ten times cheaper than the 5.5 % bonus the user would lose. Paid by the deleverage itself, nothing upfront.
