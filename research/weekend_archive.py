# Block 2 archive: for every weekend since the stock pools launched (23 Oct) and all 8 stocks, does the 60-min TWAP of the
# main Aero pool before the oracle restart predict the first Aave (Chainlink) print on Monday?
# Signal times checked: 3 h and 1 h before the restart print (the contract must act before it).
import json, time, urllib.request, datetime as dt
RPC_LOGS = "https://base-rpc.publicnode.com"; RPC_ARCH = "https://mainnet.base.org"
TOPIC = "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"  # AnswerUpdated
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
STOCKS = {  # Aave feed proxy, main Aero USDC pool (same as web/index.html)
  "AAPL": ("0x787f13dEa48Db0897CbCDD985de77809D837F988", "0xF5FCB9CDAFcE67d50AfEf298F88E709d2B946BA6"),
  "AMZN": ("0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295", "0x532e0F46d1e528507FC9454d5847C231f23bDDf6"),
  "GOOGL": ("0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2", "0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3"),
  "META": ("0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D", "0xd072410fa13D242e1d53721Bcf7AF02e3455DC96"),
  "MSFT": ("0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c", "0x2740C0faAb738F6e346e545fDE02aEF9B1A01ee7"),
  "NVDA": ("0x04689a41629776563E6822F76f2e57D148d28513", "0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC"),
  "TSLA": ("0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4", "0x7A33000372f3F028f074182CCb9d16cBEEfBF920"),
  "SPCX": ("0x6A634B235903C4ad6376892180d6fF8612e3Fa68", "0x880dB7Dda4407D99508574E680d067D1164B3cFE")}
FRIDAYS = [dt.datetime(2026, 10, 23, tzinfo=dt.UTC) + dt.timedelta(weeks=k) for k in range(5)]  # 23 Oct .. 20 Nov (stock pools on Aero exist only from ~23 Oct)

def rpc(url, m, p):
    for i in range(8):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
call = lambda to, data, b="latest": rpc(RPC_ARCH, "eth_call", [{"to": to, "data": data}, b if b == "latest" else hex(b)])
ts_of = lambda b: int(rpc(RPC_ARCH, "eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)
latest = int(rpc(RPC_ARCH, "eth_blockNumber", []), 16)
_bc = {}
def block_at(ts):  # bisection (block time changed from 2 s to 0.2 s on 5 Nov)
    if ts in _bc: return _bc[ts]
    lo, hi = latest - 12_000_000, latest
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ts_of(mid) <= ts: lo = mid
        else: hi = mid
    _bc[ts] = lo; return lo
_meta = {}
def meta(pool):
    if pool not in _meta:
        t0 = "0x" + call(pool, "0x0dfe1681")[-40:]; t1 = "0x" + call(pool, "0xd21220a7")[-40:]
        _meta[pool] = (t0.lower() == USDC, int(call(t0, "0x313ce567"), 16), int(call(t1, "0x313ce567"), 16))
    return _meta[pool]
def tick_price(pool, tick):
    usdc0, d0, d1 = meta(pool)
    p = 1.0001 ** tick * 10 ** (d0 - d1)
    return 1 / p if usdc0 else p
def twap(pool, b, secs=3600):  # observe([secs, 0]) at block b -> mean tick over the last `secs`
    out = call(pool, "0x883bdbfd" + "%064x" % 32 + "%064x" % 2 + "%064x" % secs + "%064x" % 0, b)
    words = [out[2 + 64 * i: 2 + 64 * (i + 1)] for i in range(len(out[2:]) // 64)]
    n = int(words[2], 16); c = [int(w, 16) for w in words[3:3 + n]]
    c = [x - (1 << 256) if x >= 1 << 255 else x for x in c]
    return tick_price(pool, (c[1] - c[0]) / secs)
def feed_logs(feed, b0, b1):
    agg = "0x" + call(feed, "0x245a7bfc", b1)[-40:]
    out, b = [], b0
    while b <= b1:
        e = min(b + 49_999, b1)
        for l in rpc(RPC_LOGS, "eth_getLogs", [{"address": agg, "fromBlock": hex(b), "toBlock": hex(e), "topics": [TOPIC]}]):
            out.append((int(l["data"][2:66], 16), int(l["topics"][1], 16) / 1e8))
        b = e + 1
    return sorted(out)

rows = []
for fri in FRIDAYS:
    b0 = block_at(int((fri + dt.timedelta(hours=19)).timestamp())); b1 = block_at(int((fri + dt.timedelta(days=3, hours=4)).timestamp()))
    for s, (feed, pool) in STOCKS.items():
        try:
            lg = feed_logs(feed, b0, b1)
            g, i = max((lg[k + 1][0] - lg[k][0], k) for k in range(len(lg) - 1))
            (t_fri, p_fri), (t_mon, p_mon) = lg[i], lg[i + 1]
            pct = lambda x, base: round((x / base - 1) * 100, 2)
            r = dict(weekend=fri.strftime("%d %b"), sym=s, restart=dt.datetime.fromtimestamp(t_mon, dt.UTC).strftime("%a %H:%M"),
                     fri=p_fri, mon=p_mon, jump=pct(p_mon, p_fri))
            for h in (3, 1):
                tw = twap(pool, block_at(t_mon - 3600 * h))
                r[f"twap_{h}h_vs_fri"] = pct(tw, p_fri); r[f"miss_{h}h"] = pct(tw, p_mon)
        except Exception as e:
            r = dict(weekend=fri.strftime("%d %b"), sym=s, error=str(e)[:100])
        rows.append(r); print(r, flush=True)
json.dump(rows, open("weekend_archive.json", "w"), indent=0)
