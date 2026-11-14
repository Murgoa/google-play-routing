#!/usr/bin/env bash
# verify-play-cdn.sh —— 验证 Google Play 下载域名是否真的走了直连
#
# 用法:
#   ./verify-play-cdn.sh                        # 直连 vs 探测，不指定代理
#   ./verify-play-cdn.sh 127.0.0.1:7890         # 经本地代理内核测试
#   CLASH_API=http://127.0.0.1:9090 ./verify-play-cdn.sh 127.0.0.1:7890
#
# 判据:
#   1) 下载域名直接请求应返回 200/301/404，耗时 < 1s
#   2) 经代理时，sing-box/mihomo 的 /connections 里 chains 应为 direct
#   3) 测速：直连通常 2~20MB/s；若掉到 1MB/s 量级，多半被送去代理了

set -u
PROXY="${1:-}"
CF_URL="https://speed.cloudflare.com/__down?bytes=10000000"
DL_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
CDN_HOST="rr4---sn-j5o76n7z.googlevideo.com"
CURL=(curl -s -m 12 -o /dev/null)

p() { printf '%-46s %s\n' "$1" "$2"; }
hr() { printf '%s\n' "------------------------------------------------------------"; }

echo "== 1. DNS 是否被投毒（应返回国内 GGC，如 58.254.x / 114.250.x）"
for h in "$CDN_HOST" dl.google.com; do
  ip=$(dig +short +time=3 +tries=1 "$h" 2>/dev/null | tail -1)
  [ -z "$ip" ] && ip="(解析失败)"
  p "$h" "$ip"
done
echo "   假 IP 特征: 108.160.x / 31.13.x / 199.59.x -> 被投毒"
hr

echo "== 2. 直连下载域名（不经代理）"
p "dl.google.com" "$("${CURL[@]}" -w '%{http_code} %{time_total}s' "$DL_URL")"
p "$CDN_HOST" "$("${CURL[@]}" -w '%{http_code} %{time_total}s' "https://$CDN_HOST/")"
hr

if [ -n "$PROXY" ]; then
  echo "== 3. 经代理 $PROXY 下载（应仍是 direct 链，速度不应低于直连太多）"
  p "dl.google.com" "$("${CURL[@]}" -x "http://$PROXY" -w '%{http_code} %{time_total}s' "$DL_URL")"
  p "$CDN_HOST" "$("${CURL[@]}" -x "http://$PROXY" -w '%{http_code} %{time_total}s' "https://$CDN_HOST/")"
  hr

  echo "== 4. 速度对比（10MB）"
  d=$(curl -s -m 30 -o /dev/null -w '%{speed_download}' "$CF_URL")
  q=$(curl -s -x "http://$PROXY" -m 30 -o /dev/null -w '%{speed_download}' "$CF_URL")
  p "直连 speed.cloudflare.com" "$(awk -v v="$d" 'BEGIN{printf "%.2f MB/s", v/1048576}')"
  p "经代理 speed.cloudflare.com" "$(awk -v v="$q" 'BEGIN{printf "%.2f MB/s", v/1048576}')"
  hr

  if [ -n "${CLASH_API:-}" ]; then
    echo "== 5. 路由链检查（clash_api）"
    ( curl -s -x "http://$PROXY" --limit-rate 200k -m 5 -o /dev/null "$DL_URL" >/dev/null 2>&1 & )
    sleep 3
    curl -s "$CLASH_API/connections" 2>/dev/null \
      | tr '}' '\n' | grep -i "dl.google.com" | grep -o '"chains":\[[^]]*\]' | head -3 \
      || echo "   (未取到连接，检查 clash_api 地址)"
    echo "   期望: [\"direct\"]；若出现节点名说明规则没生效"
  fi
fi

echo
echo "完成。判定要点："
echo "  - 直连能返回 200/301/404 且 < 1s = CDN 可达"
echo "  - 经代理后变得明显更慢或 000 超时 = 下载域名被送进代理（规则顺序问题）"
