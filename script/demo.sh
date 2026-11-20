#!/usr/bin/env bash
# The Monday-gap demo on a local fork of Base mainnet, for the video. Nothing here touches Base itself.
#   script/demo.sh up                start the fork on :8547, swap in the stock-token stubs, save snapshot 0
#   script/demo.sh gap <bps>         every stock the borrower holds is printed <bps> lower (500 = 5%)
#   script/demo.sh liquidate         a liquidator takes collateral if the health factor is below 1
#   script/demo.sh fund <usdc>       give the borrower USDC on the fork (whole dollars)
#   script/demo.sh reset             back to snapshot 0 (before any gap)
#   script/demo.sh status            health factor, debt and collateral of the borrower
# The page reads the fork at http://127.0.0.1:8612/?rpc=http://127.0.0.1:8547 (local only).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/c/Users/User/tools/foundry:$PATH"
R=http://127.0.0.1:8547
BORROWER="${BORROWER:-0x0265b91d}" # prefix is resolved below
SPOKE=0x17905Db0e4A3514467539956c084180616AE7B8D
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
MORPHO=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb   # holds USDC on Base; used as a faucet on the fork
LIQ=0x000000000000000000000000000000000000dEaD
STATE=.demo-state
[ -f $STATE ] && . ./$STATE

resolve() {
  if [ ${#BORROWER} -ne 42 ]; then
    BORROWER=$(python -I -c "
import json,sys;logs=json.load(open('research/aave_logs.json'))['logs']
u=sorted({'0x'+l['topics'][3][-40:] for l in logs if l['ev']=='Borrow'})
m=[x for x in u if x.startswith('$BORROWER'.lower())];print(m[0] if len(m)==1 else sys.exit('borrower prefix not unique'))")
  fi
}
oracle() { cast call $SPOKE 'ORACLE()(address)' --rpc-url $R; }
coll_reserves() { for r in 0 1 2 3 4 5 6 8; do s=$(cast call $SPOKE 'getUserReserveStatus(uint256,address)(bool,bool)' $r $BORROWER --rpc-url $R | head -1); [ "$s" = "true" ] && echo $r; done; }
hf() { cast call $SPOKE 'getUserAccountData(address)((uint256,uint256,uint256,uint256,uint256,uint256,uint256))' $BORROWER --rpc-url $R | tr -d '()' | cut -d, -f3 | awk '{printf "%.4f\n", $1/1e18}'; }

case "${1:-status}" in
up)
  resolve
  (anvil --fork-url https://mainnet.base.org --auto-impersonate --port 8547 --silent > .demo-anvil.log 2>&1 &)
  for i in $(seq 1 30); do cast block-number --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
  O=$(oracle)
  # stock tokens: copy a stub's runtime code over each built-in token the Spoke lists
  for r in 0 1 2 3 4 5 6 8; do
    T=$(cast call $SPOKE 'getReserve(uint256)(address,address,uint16,uint8,uint24,uint8,uint32)' $r --rpc-url $R | head -1)
    SYM=$(cast call $T 'symbol()(string)' --rpc-url https://mainnet.base.org | tr -d '"')
    DEC=$(cast call $SPOKE 'getReserve(uint256)(address,address,uint16,uint8,uint24,uint8,uint32)' $r --rpc-url $R | sed -n 4p)
    STUB=$(forge create src/demo/StockStub.sol:StockStub --broadcast --rpc-url $R --unlocked --from $LIQ --constructor-args $(cast format-bytes32-string "$SYM") $DEC 2>/dev/null | awk '/Deployed to/{print $3}')
    cast rpc anvil_setCode $T "$(cast code $STUB --rpc-url $R)" --rpc-url $R >/dev/null
  done
  cast rpc anvil_setBalance $BORROWER 0xDE0B6B3A7640000 --rpc-url $R >/dev/null
  cast rpc anvil_setBalance $MORPHO 0xDE0B6B3A7640000 --rpc-url $R >/dev/null
  cast rpc anvil_setBalance $LIQ 0xDE0B6B3A7640000 --rpc-url $R >/dev/null
  SNAP=$(cast rpc evm_snapshot --rpc-url $R | tr -d '"')
  echo "BORROWER=$BORROWER" > $STATE; echo "SNAP=$SNAP" >> $STATE
  echo "fork up, borrower $BORROWER, HF $(hf), snapshot $SNAP"
  ;;
gap)
  BPS=${2:?gap in basis points, e.g. 400}
  O=$(oracle)
  F=$(forge inspect src/demo/MockFeed.sol:MockFeed deployedBytecode)
  for r in $(coll_reserves); do
    SRC=$(cast call $O 'getReserveSource(uint256)(address)' $r --rpc-url $R)
    P=$(cast call $O 'getReservePrice(uint256)(uint256)' $r --rpc-url $R | cut -d' ' -f1)
    NEW=$(python -c "print($P*(10000-$BPS)//10000)")
    cast rpc anvil_setCode $SRC "$F" --rpc-url $R >/dev/null
    cast send $SRC 'set(int256)' $NEW --from $LIQ --unlocked --rpc-url $R >/dev/null
    echo "reserve $r: $P -> $NEW"
  done
  echo "HF after a $(python -c "print($BPS/100)")% gap: $(hf)"
  ;;
liquidate)
  BIG=0; COLL=0
  for r in $(coll_reserves); do
    v=$(cast call $SPOKE 'getUserSuppliedAssets(uint256,address)(uint256)' $r $BORROWER --rpc-url $R | cut -d' ' -f1)
    [ "$(python -c "print(int($v>$BIG))")" = 1 ] && BIG=$v && COLL=$r
  done
  cast send $USDC 'transfer(address,uint256)' $LIQ 100000000000 --from $MORPHO --unlocked --rpc-url $R >/dev/null
  cast send $USDC 'approve(address,uint256)' $SPOKE 100000000000 --from $LIQ --unlocked --rpc-url $R >/dev/null
  if out=$(cast send $SPOKE 'liquidationCall(uint256,uint256,address,uint256,bool)' $COLL 7 $BORROWER 115792089237316195423570985008687907853269984665640564039457584007913129639935 false --from $LIQ --unlocked --rpc-url $R 2>&1); then
    AFTER=$(cast call $SPOKE 'getUserSuppliedAssets(uint256,address)(uint256)' $COLL $BORROWER --rpc-url $R | cut -d' ' -f1)
    echo "LIQUIDATED: reserve $COLL collateral $BIG -> $AFTER, tx $(echo "$out" | grep -E '^transactionHash' | awk '{print $2}')"
  else
    echo "liquidation refused: $(echo "$out" | grep -o 'Error.*' | head -1)"
  fi
  echo "HF now: $(hf)"
  ;;
fund)
  AMT=${2:?USDC in whole dollars}
  cast send $USDC 'transfer(address,uint256)' $BORROWER $((AMT * 1000000)) --from $MORPHO --unlocked --rpc-url $R >/dev/null
  echo "borrower USDC: $(cast call $USDC 'balanceOf(address)(uint256)' $BORROWER --rpc-url $R)"
  ;;
reset)
  cast rpc evm_revert $SNAP --rpc-url $R >/dev/null
  SNAP=$(cast rpc evm_snapshot --rpc-url $R | tr -d '"'); sed -i "s/^SNAP=.*/SNAP=$SNAP/" $STATE
  echo "back to the start, HF $(hf)"
  ;;
status)
  echo "borrower $BORROWER HF $(hf)"
  echo "USDC debt $(cast call $SPOKE 'getUserTotalDebt(uint256,address)(uint256)' 7 $BORROWER --rpc-url $R)"
  for r in $(coll_reserves); do echo "reserve $r collateral $(cast call $SPOKE 'getUserSuppliedAssets(uint256,address)(uint256)' $r $BORROWER --rpc-url $R)"; done
  ;;
down)
  taskkill //F //IM anvil.exe >/dev/null 2>&1 || true; rm -f $STATE; echo "fork stopped"
  ;;
esac
