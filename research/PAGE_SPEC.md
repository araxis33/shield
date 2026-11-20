# Shield page — spec for review (20 Nov 2026)

Static single page (HTML+JS, no backend), Base mainnet, reads via public RPC (mainnet.base.org), writes only through the user's own wallet (EIP-1193). English UI, dark theme. Layout approved by the owner.

## Inputs
- Address field (any address, read-only) or "Connect wallet" (fills the address, enables the repay button only when the connected account == the address).

## Reads (all at one pinned block number per refresh)
- Spoke `0x17905Db0e4A3514467539956c084180616AE7B8D`: `getReserveCount`, `getReserve(r)` (underlying, decimals), `getUserAccountData(user)` (HF, totals), per reserve `getUserReserveStatus(r,user)` (collateral?, borrowing?), `getUserPosition(r,user).dynamicConfigKey`, `getDynamicReserveConfig(r,key).collateralFactor`, `getUserSuppliedAssets(r,user)`, `getUserTotalDebt(r,user)`.
- Oracle `ORACLE()` → `getReservePrice(r)`, `getReserveSource(r)` → `latestRoundData()` updatedAt (shows "oracle asleep for N h").
- Base pool price per stock: the stock's main Aero pool vs USDC, 30-min TWAP via `observe([1800,0])` on the CL pool (not spot). Pools: NVDAc 0xf668…c8ec, METAc 0xd072…dc96, AAPLc 0xf5fc…6ba6, SPCXc 0x880d…3cfe, GOOGLc/AMZNc/MSFTc/TSLAc to be found (largest USDC pool with a gauge). If a stock has no usable pool → its scenario price = oracle price and the row says "no Base price".

## Numbers
- value_i = suppliedAssets_i × price_i × 10^(18−dec_i) (price 8 dec; $1 = 1e26); W = Σ value_i × CF_i/1e4 over collateral reserves; D = Σ debtAssets_j × price_j × 10^(18−dec_j). HF = W/D. Verified equal to Spoke HF for 145 borrowers, 0 mismatches. Page shows the Spoke HF and uses own maths only for scenarios.
- HF at Base prices: same formula with price_i replaced by the pool TWAP (USDC price stays oracle).
- Per stock "falls before liquidation": drop_j = (W − D) / (value_j × CF_j) (others unchanged), shown as % and price.
- Repay to survive a gap g (all stocks fall g, chosen 3/5/10 %) with HF target 1.05: repay = D − W×(1−g)/1.05, floored at 0, rounded up, in USDC (6 dec): amount = value / (priceUSDC × 1e12) + 1. Capped at the user's USDC debt.
- Scenario uses the worse of oracle and Base price per stock (conservative).

## Repay flow (connected wallet == address)
1. Check chain 8453, USDC balance >= amount, debt > 0.
2. If USDC allowance(user → Spoke) < amount: `approve(Spoke, amount)` (exact, not unlimited).
3. Simulate `Spoke.repay(7, amount, user)` with eth_call from user; on revert show the reason, send nothing.
4. Send repay; wait receipt; re-read and show new HF.

## Monday board
- Borrower list from Borrow events of the Spoke (scan from block 0x311812e, cached in a JSON file the page loads, refreshed by a scheduled GitHub Action every hour), then per borrower the same reads; show positions whose HF at Base prices < 1 and < 1.1, total debt, top 20 addresses with links. Clearly labelled a scenario, not a forecast.

## Failure states shown to the user
- RPC error → "could not read, nothing shown" (never a partial HF).
- Pool price missing or pool price differs from oracle by > 15 % → ignore pool for that stock, say so.
- Repay simulation reverts → show reason, nothing sent. Wallet on another chain → ask to switch.
