import json, time, urllib.request, datetime as dt
RPC = "https://mainnet.base.org"
def rpc(m, p):
    for i in range(8):
        try:
            time.sleep(0.1)
            r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
SYM = {0: "AAPL", 1: "AMZN", 2: "GOOGL", 3: "META", 4: "MSFT", 5: "NVDA", 6: "TSLA", 7: "USDC", 8: "SPCX"}
logs = json.load(open("aave_logs.json"))["logs"]
rows = []
for l in [x for x in logs if x["ev"] == "Liq"]:
    ts = int(rpc("eth_getBlockByNumber", [hex(l["block"]), False])["timestamp"], 16)
    d = l["data"][2:]; w = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
    cr = int(l["topics"][1], 16)
    debt = w[2] / 1e6
    t = dt.datetime.fromtimestamp(ts, dt.UTC)
    rows.append({"t": t.isoformat(), "dow": t.strftime("%a"), "hhmm": t.strftime("%H:%M"), "coll": SYM[cr], "debt_usdc": round(debt, 2), "user": "0x" + l["topics"][3][-40:], "tx": l["tx"], "block": l["block"]})
rows.sort(key=lambda r: r["t"])
json.dump(rows, open("liq_times.json", "w"), indent=1)
for r in rows: print(r["t"][:16], r["dow"], r["coll"], r["debt_usdc"], r["user"][:10])
