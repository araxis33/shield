# Shield

**How close is an Aave stock loan on Base to liquidation, and how much USDC saves it?**

Page: **https://araxis33.github.io/shield/**

Aave V4 on Base lets people borrow USDC against tokenized stocks (the Coinbase Equities Hub: AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc, SPCXc). The stock price feeds stop over the weekend and on US holidays, then print the move all at once. A loan that looked safe on Friday can open below health factor 1 on Monday, and a liquidator takes collateral in that same block.

Shield is one static page, no backend:

1. Paste any borrower address. The page reads the position from the Spoke at one block: health factor, USDC debt, every collateral with its own collateral factor.
2. **Stress line.** Each stock is also priced from its Aero pool on Base (30-minute TWAP), which keeps trading while the feed is frozen. The page uses the lower of the two prices.
3. **Per stock:** how far that one stock may fall before the health factor reaches 1.
4. **Survive a gap.** Pick a gap (3 / 5 / 10 / 15 %). The page shows the health factor after it and the exact USDC to repay now to stay at 1.05 or above.
5. **Repay** from the borrower's own wallet: approve exactly that amount (plus 0.5 % for interest that accrues while signing), then `Spoke.repay`. The page never holds funds.

## What is checked

- Reads: live Base mainnet (Spoke `0x17905Db0e4A3514467539956c084180616AE7B8D`). The health factor maths matches the Spoke to 4 decimals on every borrower (`research/hf_check.py`).
- Repay path, on a local fork of Base with a real borrower: approve + repay 171.74 USDC took the health factor from 1.02 to 1.10; a partial repay with only 50 USDC in the wallet; a repay larger than the debt takes exactly the debt; a second repay is blocked while the first is unconfirmed (across tabs and reloads; released by the receipt or when the wallet replaced the transaction).
- Fork demo (`script/demo.sh`): the same borrower, the same 4 % gap. Without Shield the liquidator takes the AAPLc; after a $151.60 repay through the page the liquidation is refused (`HealthFactorNotBelowThreshold`). The fork replaces the built-in stock tokens with stubs (`src/demo`), because a local fork cannot run Base's native token code.
- Research behind it: `research/FACTS.md` (feeds frozen every weekend, Base pools lead the Monday print on large moves, 35 liquidations since September).

## Limits

- Only USDC debt on this Spoke; the page refuses other positions.
- A stock without an Aero pool, or whose pool is more than 15 % away from Aave, is stressed at Aave's price only; the page says so next to the amount.
- The stress line is a scenario, not a forecast. Not financial advice.
- The public RPC (`mainnet.base.org`) can be busy; reads retry, a failed read shows nothing rather than a wrong number.

## Run locally

```
cd web && python -m http.server 8612
```

Fork demo: `script/demo.sh up`, then open `http://127.0.0.1:8612/?rpc=http://127.0.0.1:8547` (the `rpc` parameter only works on localhost).

MIT License.
