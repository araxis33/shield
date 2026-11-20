# NVDAc price in its main Aero pool through the weekend of 14-16 Nov, from archive slot0 reads.
import json, time, urllib.request, datetime as dt
RPC = "https://mainnet.base.org"
POOL = "0xf668e21993f0acd7ab00bb1cfbaed0df28a3c8ec"
def rpc(m, p):
    for i in range(8):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
t0 = "0x" + rpc("eth_call", [{"to": POOL, "data": "0x0dfe1681"}, "latest"])[-40:]
t1 = "0x" + rpc("eth_call", [{"to": POOL, "data": "0xd21220a7"}, "latest"])[-40:]
dec = lambda t: int(rpc("eth_call", [{"to": t, "data": "0x313ce567"}, "latest"]), 16)
d0, d1 = dec(t0), dec(t1)
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
latest = int(rpc("eth_blockNumber", []), 16); now = int(rpc("eth_getBlockByNumber", [hex(latest), False])["timestamp"], 16)
def block_at(ts):
    b = latest - (now - ts) * 5
    for _ in range(3):
        bt = int(rpc("eth_getBlockByNumber", [hex(b), False])["timestamp"], 16); b -= (bt - ts) * 5
    return b
rows = []
t = dt.datetime(2026, 11, 13, 20, 0, tzinfo=dt.UTC)
while t <= dt.datetime(2026, 11, 16, 15, 0, tzinfo=dt.UTC):
    b = block_at(int(t.timestamp()))
    s = rpc("eth_call", [{"to": POOL, "data": "0x3850c7bd"}, hex(b)])
    sq = int(s[2:66], 16); p = (sq / 2**96) ** 2 * 10 ** (d0 - d1)  # token1 per token0
    price = p if t0.lower() != USDC else 1 / p  # USDC per NVDAc
    rows.append((t.strftime("%a %d %H:%M"), round(price, 2))); print(rows[-1], flush=True)
    t += dt.timedelta(hours=3)
json.dump(rows, open("pool_weekend.json", "w"))
