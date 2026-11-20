# Weekend behaviour of the oracle feeds Aave V4 Equities Spoke reads on Base:
# last update before the Friday close, first updates after the Sunday 20:00 ET restart.
import json, time, urllib.request, datetime as dt
RPC = "https://base-rpc.publicnode.com"
AGG_TOPIC = "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"
FEEDS = {"AAPL": "0x787f13dEa48Db0897CbCDD985de77809D837F988", "AMZN": "0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295",
         "GOOGL": "0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2", "META": "0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D",
         "MSFT": "0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c", "NVDA": "0x04689a41629776563E6822F76f2e57D148d28513",
         "TSLA": "0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4", "SPCX": "0x6A634B235903C4ad6376892180d6fF8612e3Fa68"}
def rpc(m, p):
    for i in range(8):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
def call(to, data): return rpc("eth_call", [{"to": to, "data": data}, "latest"])
agg = {}
for s, f in FEEDS.items():
    agg[s] = "0x" + call(f, "0x245a7bfc")[-40:]  # aggregator()
latest = int(rpc("eth_blockNumber", []), 16)
now = int(rpc("eth_getBlockByNumber", [hex(latest), False])["timestamp"], 16)
start_ts = int(dt.datetime(2026, 11, 13, 18, 0, tzinfo=dt.UTC).timestamp())  # Fri 13 Nov 18:00 UTC
start = latest - (now - start_ts) * 5  # 0.2 s blocks since 5 Nov
inv = {v.lower(): k for k, v in agg.items()}
out = []
b = start
while b <= latest:
    e = min(b + 49_999, latest)
    for l in rpc("eth_getLogs", [{"address": list(agg.values()), "fromBlock": hex(b), "toBlock": hex(e), "topics": [AGG_TOPIC]}]):
        out.append({"sym": inv[l["address"].lower()], "price": int(l["topics"][1], 16) / 1e8, "ts": int(l["data"][2:66], 16), "block": int(l["blockNumber"], 16)})
    b = e + 1
json.dump({"agg": agg, "updates": out}, open("feeds_weekend.json", "w"))
print(len(out), "updates from", dt.datetime.fromtimestamp(min(u["ts"] for u in out), dt.UTC))
