# Recompute every borrower's health factor from per-reserve reads and compare with Spoke.getUserAccountData.
import json, sys, time, urllib.request
sys.path.insert(0, r"C:\Users\User\.local\bin")
from keccak import keccak256
RPC = "https://mainnet.base.org"
SPOKE = "0x17905Db0e4A3514467539956c084180616AE7B8D"; ORACLE = "0xaBaf048fD7675Ea34a84332371ffd5D55E322A47"
sel = lambda s: keccak256(s.encode())[:4].hex()
w = lambda v: hex(v)[2:].rjust(64, "0") if isinstance(v, int) else v.lower().replace("0x", "").rjust(64, "0")
def rpc(m, p):
    for i in range(8):
        try:
            time.sleep(0.12)
            r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json", "User-Agent": "curl/8"}), timeout=40))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            err = e; time.sleep(2 + 3 * i)
    raise err
BLOCK = rpc("eth_blockNumber", [])
def call(to, data):
    h = rpc("eth_call", [{"to": to, "data": data}, BLOCK])[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]
logs = json.load(open("aave_logs.json"))["logs"]
users = sorted({"0x" + l["topics"][3][-40:] for l in logs if l["ev"] == "Borrow"})
N = call(SPOKE, "0x" + sel("getReserveCount()"))[0]
res = {}
for r in range(N):
    rv = call(SPOKE, "0x" + sel("getReserve(uint256)") + w(r))
    res[r] = {"underlying": hex(rv[0]), "dec": rv[3], "price": call(ORACLE, "0x" + sel("getReservePrice(uint256)") + w(r))[0]}
out = []
for u in users:
    a = call(SPOKE, "0x" + sel("getUserAccountData(address)") + w(u))
    hf, coll, debt_ray = a[2], a[3], a[4]
    if debt_ray == 0: continue
    W = 0; D = 0; parts = []
    for r in range(N):
        coll_on, borrowing = None, None
        st = call(SPOKE, "0x" + sel("getUserReserveStatus(uint256,address)") + w(r) + w(u))
        is_coll, is_borrow = st[0], st[1]
        if is_coll:
            pos = call(SPOKE, "0x" + sel("getUserPosition(uint256,address)") + w(r) + w(u))
            key = pos[4]
            cf = call(SPOKE, "0x" + sel("getDynamicReserveConfig(uint256,uint32)") + w(r) + w(key))[0]
            amt = call(SPOKE, "0x" + sel("getUserSuppliedAssets(uint256,address)") + w(r) + w(u))[0]
            val = amt * res[r]["price"] / 10 ** res[r]["dec"] / 1e8
            W += val * cf / 1e4; parts.append((r, round(val, 2), cf))
        if is_borrow:
            dbt = call(SPOKE, "0x" + sel("getUserTotalDebt(uint256,address)") + w(r) + w(u))[0]
            D += dbt * res[r]["price"] / 10 ** res[r]["dec"] / 1e8
    mine = W / D if D else 0
    out.append({"user": u, "hf_spoke": hf / 1e18, "hf_mine": mine, "debt": D, "coll": parts})
    print(f"{u[:10]} spoke {hf/1e18:.4f} mine {mine:.4f} debt ${D:,.0f} parts {parts}", flush=True)
json.dump({"block": int(BLOCK, 16), "reserves": res, "users": out}, open("hf_check.json", "w"))
bad = [o for o in out if abs(o["hf_mine"] - o["hf_spoke"]) > 0.001 * o["hf_spoke"]]
print("users with debt", len(out), "mismatch >0.1%:", len(bad))
