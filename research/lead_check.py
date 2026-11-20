# Does the 24/7 Base pool price before the oracle restart predict the first oracle print? 4 weekends.
import json, time, urllib.request, datetime as dt
RPC_LOGS = "https://base-rpc.publicnode.com"; RPC_ARCH = "https://mainnet.base.org"
TOPIC = "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
STOCKS = {  # feed proxy, main Aero pool
  "NVDA": ("0x04689a41629776563E6822F76f2e57D148d28513", "0xf668e21993f0acd7ab00bb1cfbaed0df28a3c8ec"),
  "META": ("0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D", "0xd072410fa13d242e1d53721bcf7af02e3455dc96"),
  "AAPL": ("0x787f13dEa48Db0897CbCDD985de77809D837F988", "0xf5fcb9cdafce67d50afef298f88e709d2b946ba6"),
  "SPCX": ("0x6A634B235903C4ad6376892180d6fF8612e3Fa68", "0x880db7dda4407d99508574e680d067d1164b3cfe")}
def rpc(url, m, p):
    for i in range(8):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
ts_of = lambda b: int(rpc(RPC_ARCH, "eth_getBlockByNumber", [hex(b), False])["timestamp"], 16)
latest = int(rpc(RPC_ARCH, "eth_blockNumber", []), 16)
def block_at(ts):  # bisection: block time changed on 5 Nov
    lo, hi = latest - 9_000_000, latest
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ts_of(mid) <= ts: lo = mid
        else: hi = mid
    return lo
def pool_price(pool, b):
    t0 = "0x" + rpc(RPC_ARCH, "eth_call", [{"to": pool, "data": "0x0dfe1681"}, "latest"])[-40:]
    t1 = "0x" + rpc(RPC_ARCH, "eth_call", [{"to": pool, "data": "0xd21220a7"}, "latest"])[-40:]
    d0 = int(rpc(RPC_ARCH, "eth_call", [{"to": t0, "data": "0x313ce567"}, "latest"]), 16); d1 = int(rpc(RPC_ARCH, "eth_call", [{"to": t1, "data": "0x313ce567"}, "latest"]), 16)
    sq = int(rpc(RPC_ARCH, "eth_call", [{"to": pool, "data": "0x3850c7bd"}, hex(b)])[2:66], 16)
    p = (sq / 2**96) ** 2 * 10 ** (d0 - d1)
    return p if t0.lower() != USDC else 1 / p
def feed_logs(feed, b0, b1):
    agg = "0x" + rpc(RPC_ARCH, "eth_call", [{"to": feed, "data": "0x245a7bfc"}, hex(b1)])[-40:]
    out = []; b = b0
    while b <= b1:
        e = min(b + 49_999, b1)
        for l in rpc(RPC_LOGS, "eth_getLogs", [{"address": agg, "fromBlock": hex(b), "toBlock": hex(e), "topics": [TOPIC]}]):
            out.append((int(l["data"][2:66], 16), int(l["topics"][1], 16) / 1e8))
        b = e + 1
    return sorted(out)
rows = []
for fri in [dt.datetime(2026, 10, 23, tzinfo=dt.UTC), dt.datetime(2026, 10, 30, tzinfo=dt.UTC), dt.datetime(2026, 11, 6, tzinfo=dt.UTC), dt.datetime(2026, 11, 13, tzinfo=dt.UTC)]:
    b0 = block_at(int((fri + dt.timedelta(hours=19)).timestamp())); b1 = block_at(int((fri + dt.timedelta(days=3, hours=4)).timestamp()))
    for s, (feed, pool) in STOCKS.items():
        try:
            lg = feed_logs(feed, b0, b1)
            gaps = [(lg[i + 1][0] - lg[i][0], i) for i in range(len(lg) - 1)]
            g, i = max(gaps)
            last_fri, first_mon = lg[i], lg[i + 1]
            pb = block_at(first_mon[0] - 3600)
            pool_1h = pool_price(pool, pb)
            pool_fri = pool_price(pool, block_at(last_fri[0]))
            r = dict(weekend=fri.strftime("%d %b"), sym=s, fri=last_fri[1], mon=first_mon[1], restart=dt.datetime.fromtimestamp(first_mon[0], dt.UTC).strftime("%a %H:%M"),
                     jump=round((first_mon[1] / last_fri[1] - 1) * 100, 2), pool_fri_vs_oracle=round((pool_fri / last_fri[1] - 1) * 100, 2),
                     pool_1h_before_vs_fri=round((pool_1h / last_fri[1] - 1) * 100, 2), miss=round((pool_1h / first_mon[1] - 1) * 100, 2))
        except Exception as e:
            r = dict(weekend=fri.strftime("%d %b"), sym=s, error=str(e)[:80])
        rows.append(r); print(r, flush=True)
json.dump(rows, open("lead_check.json", "w"))
