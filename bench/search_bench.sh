#!/bin/bash
# 检索与列表延迟基准。驱动真实的 ClipflowStore，不复刻实现，所以不会和代码漂移。
#   用法: bench/search_bench.sh [数据目录]   不给目录就压 5 万条合成数据
set -e
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
CLI=./.build/release/clipflow

ROOT="$1"
if [ -z "$ROOT" ]; then
  ROOT=$(mktemp -d)/bench
  mkdir -p "$ROOT"
  echo "灌入 50000 条合成数据到 $ROOT …"
  $CLI --root "$ROOT" seed 50000 | tail -1
fi

med() {  # 跑 7 次取中位
  for _ in 1 2 3 4 5 6 7; do "$@" 2>&1 | tail -1; done \
    | grep -oE "[0-9.]+ms" | sort -g | sed -n 4p
}

echo
printf "%-22s %10s\n" "查询" "中位延迟"
for q in "订单支付" "handlePay" "单" "andlePa" "zzzznotfound" "select"; do
  printf "%-22s %10s\n" "$q" "$(med $CLI --root "$ROOT" search "$q" -n 50)"
done
printf "%-22s %10s\n" "list -n 200" "$(med $CLI --root "$ROOT" list -n 200)"
echo
$CLI --root "$ROOT" stats | head -5
