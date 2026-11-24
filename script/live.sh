#!/usr/bin/env bash
# Live pilot: ShieldVault on Base (8453) <-> ShieldReactive, the clock, on Reactive mainnet (1597).
# One seat: OWNER's Aave V4 position with NVDAc collateral and USDC debt.
# Uses the lp-guard deploy wallet (.env.live with LIVE_PRIVATE_KEY / LIVE_ADDRESS, never committed).
# Set BASE_RPC / REACT_RPC to local forks and STATE to a separate file to rehearse.
# Usage: script/live.sh check | deploy | start | status | stop | withdraw <amount-in-REACT>
#   check  - read-only manifest: every address and the feed, before any money moves
#   deploy - ShieldReactive (Reactive) -> ShieldVault (Base) -> setVault -> callback deposit. Clock stays off.
#   start  - clock on, only after the owner's position, the rule, the reserve and a simulated proxy callback
#            that really repays all check out on chain
# One operator, run commands one at a time. If a deploy transaction lands but the script dies before saving
# its address, add RX= / SV= to the state file by hand before running again, or a second copy gets deployed.
set -euo pipefail
cd "$(dirname "$0")/.."
unset RX SV                                          # state comes from the state file only
ENV_FILE="${ENV_FILE:-../lp-guard/.env.live}"
set -a; . "$ENV_FILE"; set +a
export PATH="/c/Users/User/tools/foundry:$PATH"
BASE_RPC="${BASE_RPC:-https://mainnet.base.org}"
REACT_RPC="${REACT_RPC:-https://mainnet-rpc.rnk.dev/}"
STATE="$(pwd)/${STATE:-.live-state}"

OWNER="${OWNER_OVERRIDE:-0x2ab08a231389fD6c1cb368769aE5Ba3f999209e4}"    # the one seat (owner's main wallet)
SPOKE=0x17905Db0e4A3514467539956c084180616AE7B8D    # Aave V4 Equities Spoke
GIVER=0x9E81c2fDE4E34CAB3AB1667ca3c932dBAED95F08    # GiverPositionManager
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
NVDAC=0xb20000000000000000000078ee7ce2fe4908108c    # NVDAc token (pinned)
SUGAR=0x0AD09A66af0154a84e86F761313d02d0abB6edd5    # Aero SugarHelper
FACTORY=0x9CB220581b91b0C83223012FE69688b92aD07a76  # Aero Slipstream factory
PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068    # Reactive callback proxy on Base mainnet
NVDA_RESERVE=5                                      # NVDAc on the Spoke = feed + collateral
NVDA_POOL=0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC # NVDAc/USDC Aero pool (weekend signal; Aave-only if unusable)
MIN_LIQ=1000000000000                               # pool liquidity floor (as in the fork tests)
SYSTEM=0x8888888888888888888888888888888888888888
CRON1000=0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4   # ~every 17 min
WEEKEND_EVERY=900                                   # every tick in Fri 20:00 - Mon 01:30 UTC
WEEKDAY_EVERY=3600                                  # ~68 min on weekdays (4 ticks)
RX_VALUE="${RX_VALUE:-80ether}"                     # REACT left on ShieldReactive (~42 needed for 10 days)
CB_TARGET=1000000000000000                          # wei: callback reserve on the Base proxy (0.001 ETH)
# the approved pilot rule (owner signs activate with exactly this; start refuses anything else)
RULE="(1700000000000000000, 2200000000000000000, 900, 0, 1500000, 0)"
BUDGET=1500000
CALLBACK_GAS=1900000                                # what is left of the 2,000,000 request after proxy overhead

touch "$STATE"; . "$STATE"
save() { echo "$1=$2" >> "$STATE"; }
read_() { local v; v=$(cast "$@") || { echo "read failed: cast $*" >&2; exit 1; }; [ -n "$v" ] || { echo "empty read: cast $*" >&2; exit 1; }; echo "$v"; }
num() { read_ "$@" | cut -d' ' -f1; }
lc() { tr 'A-F' 'a-f'; }
ok() { grep -E "^status +1" >/dev/null || { echo "transaction failed"; exit 1; }; }
need() { [ "$1" = "$2" ] || { echo "CHECK FAIL: $3 (got $1, want $2)"; exit 1; }; echo "  ok  $3"; }
chain() { local id; id=$(read_ chain-id --rpc-url "$1"); [ "$id" = "$2" ] || { echo "expected chain $2 at $1, got $id"; exit 1; }; }

signer_ok() {
  need "$(cast wallet address --private-key "$LIVE_PRIVATE_KEY" | lc)" "$(echo "$LIVE_ADDRESS" | lc)" "key matches LIVE_ADDRESS"
}

feed_ok() {  # NVDA feed must say open, or closed inside the weekend window; anything else is a fault
  local o src rd ans u now day sec
  o=$(read_ call $SPOKE 'ORACLE()(address)' --rpc-url "$BASE_RPC"); src=$(read_ call "$o" 'getReserveSource(uint256)(address)' $NVDA_RESERVE --rpc-url "$BASE_RPC")
  rd=$(read_ call "$src" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$BASE_RPC")
  ans=$(echo "$rd" | sed -n 2p | cut -d' ' -f1); u=$(echo "$rd" | sed -n 4p | cut -d' ' -f1)
  now=$(num block latest --field timestamp --rpc-url "$BASE_RPC")
  [ "${ans:0:1}" != "-" ] && [ "$ans" != 0 ] && [ "$u" -gt 0 ] && [ "$u" -le "$now" ] || { echo "CHECK FAIL: NVDA feed answer $ans at $u"; exit 1; }
  day=$(( (now / 86400 + 4) % 7 )); sec=$(( now % 86400 ))
  if [ $(( now - u )) -le 7200 ]; then echo "  ok  NVDA feed fresh ($(( (now - u) / 60 )) min): market open"
  elif [ $day = 6 ] || [ $day = 0 ] || { [ $day = 5 ] && [ $sec -ge 72000 ]; } || { [ $day = 1 ] && [ $sec -lt 5400 ]; }; then
    echo "  ok  NVDA feed $(( (now - u) / 60 )) min old inside the weekend window: market closed"
  else echo "CHECK FAIL: NVDA feed $(( (now - u) / 60 )) min old on a weekday: the vault would see a data fault"; return 1; fi
}

manifest() {
  echo "manifest (Base):"
  local raw u0 u1 ts
  raw=$(read_ call $SPOKE 'getReserve(uint256)' $NVDA_RESERVE --rpc-url "$BASE_RPC")
  need "$(echo "0x${raw:26:40}" | lc)" "$(echo $NVDAC | lc)" "reserve $NVDA_RESERVE is NVDAc"
  raw=$(read_ call $SPOKE 'getReserve(uint256)' 7 --rpc-url "$BASE_RPC")
  need "$(echo "0x${raw:26:40}" | lc)" "$(echo $USDC | lc)" "reserve 7 is USDC"
  need "$(read_ call $USDC 'decimals()(uint8)' --rpc-url "$BASE_RPC")" 6 "USDC has 6 decimals"
  need "$(read_ call $SPOKE 'isPositionManagerActive(address)(bool)' $GIVER --rpc-url "$BASE_RPC")" true "Giver active on the Spoke"
  u0=$(read_ call $NVDA_POOL 'token0()(address)' --rpc-url "$BASE_RPC" | lc); u1=$(read_ call $NVDA_POOL 'token1()(address)' --rpc-url "$BASE_RPC" | lc)
  ts=$(num call $NVDA_POOL 'tickSpacing()(int24)' --rpc-url "$BASE_RPC")
  need "$(read_ call $FACTORY 'getPool(address,address,int24)(address)' "$u0" "$u1" "$ts" --rpc-url "$BASE_RPC" | lc)" "$(echo $NVDA_POOL | lc)" "pool registered in the Aero factory"
  { [ "$u0" = "$(echo $USDC | lc)" ] && [ "$u1" = "$(echo $NVDAC | lc)" ]; } || { [ "$u1" = "$(echo $USDC | lc)" ] && [ "$u0" = "$(echo $NVDAC | lc)" ]; } \
    || { echo "CHECK FAIL: pool pair $u0/$u1"; exit 1; }; echo "  ok  pool is NVDAc/USDC"
  echo "  pool liquidity $(num call $NVDA_POOL 'liquidity()(uint128)' --rpc-url "$BASE_RPC") (floor $MIN_LIQ; below it or without 60-min history the vault uses Aave prices only)"
  feed_ok || true
  [ "$(read_ code $PROXY --rpc-url "$BASE_RPC")" != 0x ] || { echo "CHECK FAIL: no code at proxy"; exit 1; }; echo "  ok  callback proxy has code"
  echo "  owner $OWNER: Giver approved = $(read_ call $SPOKE 'isPositionManager(address,address)(bool)' $OWNER $GIVER --rpc-url "$BASE_RPC"), USDC debt = $(num call $SPOKE 'getUserTotalDebt(uint256,address)(uint256)' 7 $OWNER --rpc-url "$BASE_RPC")"
}

pair_ok() {  # saved contracts are ours and point at each other
  need "$(read_ call "$RX" 'deployer()(address)' --rpc-url "$REACT_RPC" | lc)" "$(echo "$LIVE_ADDRESS" | lc)" "ShieldReactive deployed by us"
  need "$(num call "$RX" 'originChainId()(uint256)' --rpc-url "$REACT_RPC")" 8453 "ShieldReactive calls Base"
  need "$(read_ call "$SV" 'USER()(address)' --rpc-url "$BASE_RPC" | lc)" "$(echo $OWNER | lc)" "vault seat = owner"
  need "$(read_ call "$SV" 'SPOKE()(address)' --rpc-url "$BASE_RPC" | lc)" "$(echo $SPOKE | lc)" "vault Spoke"
  need "$(read_ call "$SV" 'GIVER()(address)' --rpc-url "$BASE_RPC" | lc)" "$(echo $GIVER | lc)" "vault Giver"
  need "$(num call "$SV" 'FEED_RESERVE()(uint256)' --rpc-url "$BASE_RPC")" $NVDA_RESERVE "vault feed = NVDAc"
  need "$(read_ call "$SV" '_CALLBACK_SENDER()(address)' --rpc-url "$BASE_RPC" | lc)" "$(echo "$RX" | lc)" "vault accepts callbacks only from our ShieldReactive"
}

case "${1:-status}" in
check) chain "$BASE_RPC" 8453; manifest ;;
deploy)
  chain "$BASE_RPC" 8453; chain "$REACT_RPC" 1597; signer_ok; manifest
  [ -z "${RX:-}" ] && {
    RX=$(forge create src/ShieldReactive.sol:ShieldReactive --broadcast --rpc-url "$REACT_RPC" \
      --private-key "$LIVE_PRIVATE_KEY" --value "$RX_VALUE" --constructor-args 8453 | awk '/Deployed to/{print $3}')
    [ -n "$RX" ] || { echo "ShieldReactive deploy failed"; exit 1; }
    save RX "$RX"; echo "ShieldReactive (Reactive): $RX"; }
  [ -z "${SV:-}" ] && {
    SV=$(forge create src/ShieldVault.sol:ShieldVault --broadcast --rpc-url "$BASE_RPC" --private-key "$LIVE_PRIVATE_KEY" \
      --constructor-args $SPOKE $GIVER $USDC $SUGAR $FACTORY $PROXY "$RX" $OWNER $NVDA_RESERVE $MIN_LIQ "[$NVDA_RESERVE]" "[$NVDA_POOL]" \
      | awk '/Deployed to/{print $3}')
    [ -n "$SV" ] || { echo "ShieldVault deploy failed"; exit 1; }
    save SV "$SV"; echo "ShieldVault (Base): $SV"; }
  pair_ok
  need "$(num call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" 0 "clock is off while wiring"
  cur=$(read_ call "$RX" 'vault()(address)' --rpc-url "$REACT_RPC" | lc)
  if [ "$cur" = 0x0000000000000000000000000000000000000000 ]; then
    cast send "$RX" "setVault(address)" "$SV" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
  fi
  need "$(read_ call "$RX" 'vault()(address)' --rpc-url "$REACT_RPC" | lc)" "$(echo "$SV" | lc)" "ShieldReactive wakes our vault"
  have=$(num call $PROXY 'reserves(address)(uint256)' "$SV" --rpc-url "$BASE_RPC"); owe=$(num call $PROXY 'debts(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")
  add=$(python -c "print(max(0, $CB_TARGET - $have) + $owe)")
  if [ "$add" != 0 ]; then
    cast send $PROXY "depositTo(address)" "$SV" --value "$add" --rpc-url "$BASE_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
    echo "callbacks funded: +$add wei"
  fi
  need "$(num call $PROXY 'debts(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")" 0 "no callback debt"
  echo "clock is OFF. Next: owner approves Giver, deposits 2 USDC, activates $RULE budget $BUDGET; then: script/live.sh start"
  "$0" status
  ;;
start)
  chain "$BASE_RPC" 8453; chain "$REACT_RPC" 1597; signer_ok
  [ -n "${RX:-}" ] && [ -n "${SV:-}" ] || { echo "deploy first"; exit 1; }
  pair_ok
  need "$(read_ call "$RX" 'vault()(address)' --rpc-url "$REACT_RPC" | lc)" "$(echo "$SV" | lc)" "ShieldReactive wakes our vault"
  if [ "$(num call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" != 0 ]; then echo "clock already on"; "$0" status; exit 0; fi
  feed_ok
  need "$(read_ call "$SV" 'active()(bool)' --rpc-url "$BASE_RPC")" true "owner activated the vault"
  need "$(read_ call "$SV" 'rule()(uint64,uint64,uint32,uint16,uint128,uint128)' --rpc-url "$BASE_RPC" | cut -d' ' -f1 | paste -sd, | sed 's/,/, /g; s/^/(/; s/$/)/')" "$RULE" "rule is the approved pilot rule"
  need "$(num call "$SV" 'budget()(uint256)' --rpc-url "$BASE_RPC")" $BUDGET "budget"
  r=$(num call "$SV" 'reserve()(uint256)' --rpc-url "$BASE_RPC"); b=$(num call $USDC 'balanceOf(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")
  [ "$r" -ge 1500000 ] && [ "$b" -ge "$r" ] || { echo "CHECK FAIL: reserve $r, USDC held $b"; exit 1; }; echo "  ok  reserve $r USDC units"
  need "$(read_ call $SPOKE 'isPositionManager(address,address)(bool)' $OWNER $GIVER --rpc-url "$BASE_RPC")" true "owner approved Giver"
  [ "$(num call $SPOKE 'getUserTotalDebt(uint256,address)(uint256)' 7 $OWNER --rpc-url "$BASE_RPC")" -gt 0 ] || { echo "CHECK FAIL: owner has no USDC debt"; exit 1; }
  s=$(read_ call "$SV" 'stress()((uint8,uint8,uint256,uint256,uint256,uint256))' --rpc-url "$BASE_RPC"); echo "  stress $s"
  [ "$(echo "$s" | tr -d '()' | cut -d, -f1 | tr -d ' ')" = 0 ] || { echo "CHECK FAIL: the rule does not call for a repay now (status above)"; exit 1; }
  have=$(num call $PROXY 'reserves(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")
  [ "$have" -ge 500000000000000 ] && [ "$(num call $PROXY 'debts(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")" = 0 ] || { echo "CHECK FAIL: callback reserve $have"; exit 1; }
  # the real callback, simulated: proxy as sender, our RX as the injected sender, the gas the proxy forwards
  d0=$(num call $SPOKE 'getUserTotalDebt(uint256,address)(uint256)' 7 $OWNER --rpc-url "$BASE_RPC")
  cast call "$SV" 'protectByReactive(address)' "$RX" --from $PROXY --gas-limit $CALLBACK_GAS --rpc-url "$BASE_RPC" >/dev/null \
    || { echo "CHECK FAIL: simulated proxy callback reverts"; exit 1; }
  echo "  ok  simulated proxy callback runs (debt now $d0; the vault's Protected event and debt drop are checked after the first real tick)"
  [ "$(num call $SYSTEM 'debt(address)(uint256)' "$RX" --rpc-url "$REACT_RPC")" = 0 ] || { echo "CHECK FAIL: Reactive debt"; exit 1; }
  cast send "$RX" "start(uint256,uint32,uint32)" $CRON1000 $WEEKEND_EVERY $WEEKDAY_EVERY --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
  need "$(read_ call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC" | cut -d' ' -f1)" "$(cast to-dec $CRON1000)" "clock on (Cron1000)"
  echo "clock on at $(date -u '+%F %T') UTC. Watch the first tick: script/live.sh status"
  ;;
status)
  chain "$BASE_RPC" 8453; chain "$REACT_RPC" 1597
  echo "deploy wallet $LIVE_ADDRESS  Base ETH $(read_ balance "$LIVE_ADDRESS" --ether --rpc-url "$BASE_RPC")  REACT $(read_ balance "$LIVE_ADDRESS" --ether --rpc-url "$REACT_RPC")"
  if [ -n "${RX:-}" ]; then
    echo "ShieldReactive $RX  REACT $(read_ balance "$RX" --ether --rpc-url "$REACT_RPC")  debt $(read_ call $SYSTEM 'debt(address)(uint256)' "$RX" --rpc-url "$REACT_RPC")"
    echo "  vault $(read_ call "$RX" 'vault()(address)' --rpc-url "$REACT_RPC")  cron $(read_ call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC" | cut -c1-12)…  lastCheck $(read_ call "$RX" 'lastCheck()(uint64)' --rpc-url "$REACT_RPC")"
  fi
  if [ -n "${SV:-}" ]; then
    echo "ShieldVault $SV  market $(read_ call "$SV" 'marketState()(uint8)' --rpc-url "$BASE_RPC")  (0 open, 1 closed, 2 fault)  active $(read_ call "$SV" 'active()(bool)' --rpc-url "$BASE_RPC")"
    echo "  reserve $(read_ call "$SV" 'reserve()(uint256)' --rpc-url "$BASE_RPC")  budget $(read_ call "$SV" 'budget()(uint256)' --rpc-url "$BASE_RPC")  lastProtect $(read_ call "$SV" 'lastProtect()(uint256)' --rpc-url "$BASE_RPC")"
    echo "  stress (status, market, debt, stressHF, aaveHF, repay) $(cast call "$SV" 'stress()((uint8,uint8,uint256,uint256,uint256,uint256))' --rpc-url "$BASE_RPC" 2>&1 | head -c 200)"
    echo "  callback reserve $(read_ call $PROXY 'reserves(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")  debt $(read_ call $PROXY 'debts(address)(uint256)' "$SV" --rpc-url "$BASE_RPC")"
    echo "  owner USDC debt $(read_ call $SPOKE 'getUserTotalDebt(uint256,address)(uint256)' 7 $OWNER --rpc-url "$BASE_RPC")"
  fi
  ;;
stop)  # Reactive only; the owner's own exit is stopAndWithdraw() on the vault, signed by the owner
  chain "$REACT_RPC" 1597; signer_ok
  [ -n "${RX:-}" ] || { echo "nothing deployed"; exit 0; }
  need "$(read_ call "$RX" 'deployer()(address)' --rpc-url "$REACT_RPC" | lc)" "$(echo "$LIVE_ADDRESS" | lc)" "ShieldReactive deployed by us"
  if [ "$(num call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" != 0 ]; then
    cast send "$RX" "stop()" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
  fi
  need "$(num call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" 0 "clock off"
  ;;
withdraw)
  chain "$REACT_RPC" 1597; signer_ok
  [ -n "${RX:-}" ] || { echo "nothing deployed"; exit 1; }
  need "$(read_ call "$RX" 'deployer()(address)' --rpc-url "$REACT_RPC" | lc)" "$(echo "$LIVE_ADDRESS" | lc)" "ShieldReactive deployed by us"
  need "$(num call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" 0 "clock is off before withdrawing"
  amt="${2:?amount, e.g. 50ether}"
  before=$(num balance "$LIVE_ADDRESS" --rpc-url "$REACT_RPC")
  cast send "$RX" "withdraw(address,uint256)" "$LIVE_ADDRESS" "$amt" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
  echo "REACT back to $LIVE_ADDRESS: $before -> $(num balance "$LIVE_ADDRESS" --rpc-url "$REACT_RPC") wei"
  ;;
*) echo "usage: $0 check | deploy | start | status | stop | withdraw <amount>"; exit 1 ;;
esac
