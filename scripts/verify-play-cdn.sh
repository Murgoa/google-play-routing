#!/usr/bin/env bash
# verify-play-cdn.sh —— 验证 Google Play 下载域名是否真的走了直连
#
# 用法:
#   ./verify-play-cdn.sh                        # 直连 vs 探测，不指定代理
#   ./verify-play-cdn.sh 127.0.0.1:7890         # 经本地代理内核测试
#   CLASH_API=http://127.0.0.1:9090 ./verify-play-cdn.sh 127.0.0.1:7890
#
# 判据:
#   1) dl.google.com 直接请求应返回 200/301，耗时 < 1s
#   2) 经代理时，sing-box/mihomo 的 /connections 里 dl.google.com 的 chains 应为 direct
#   3) 测速：直连通常 2~20MB/s；若掉到 1MB/s 量级，多半被送去代理了
#   4) googlevideo.com 是混合体：GGC 边缘应直连快(204/<1s)，redirector 应走代理

set -u
PROXY="${1:-}"
CF_URL="https://speed.cloudflare.com/__down?bytes=10000000"
DL_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
GGC_HOST="rr2---sn-j5o76n7s.googlevideo.com"      # 国内联通 GGC 边缘
REDIR_HOST="redirector.googlevideo.com"           # 境外全局入口
CURL=(curl -s -m 12 -o /dev/null)

p() { printf '%-46s %s\n' "$1" "$2"; }
hr() { printf '%s\n' "------------------------------------------------------------"; }

echo "== 1. DNS 是否被投毒"
for h in dl.google.com "$GGC_HOST"; do
  ip=$(dig +short +time=3 +tries=1 "$h" 2>/dev/null | tail -1)
  [ -z "$ip" ] && ip="(解析失败)"
  p "$h" "$ip"
done
echo "   dl.google.com 期望国内 GGC(114.250.x / 58.254.x)"
echo "   GGC 边缘应解析到 58.254.x / 114.250.x；出现 108.160.x/31.13.x/199.59.x = 被投毒"
echo "   注：加密 DNS 也可能被投毒（阿里 DoH 会返回不可用 IP），只有经代理的 DNS 才干净"
hr

echo "== 2. Play 下载域名直连（期望 200 且 MB/s 量级）"
p "dl.google.com" "$("${CURL[@]}" -w '%{http_code} %{time_total}s' "$DL_URL")"
hr

echo "== 2b. googlevideo 混合体：边缘应直连快，redirector 应走代理"
p "GGC 边缘 直连"    "$("${CURL[@]}" -w '%{http_code} %{time_total}s' "https://$GGC_HOST/")"
p "redirector 直连"  "$("${CURL[@]}" -w '%{http_code} %{time_total}s' "https://$REDIR_HOST/")"
if [ -n "$PROXY" ]; then
  p "GGC 边缘 经代理"   "$("${CURL[@]}" -x "http://$PROXY" -w '%{http_code} %{time_total}s' "https://$GGC_HOST/")"
  p "redirector 经代理" "$("${CURL[@]}" -x "http://$PROXY" -w '%{http_code} %{time_total}s' "https://$REDIR_HOST/")"
fi
echo "   期望: 边缘直连 204 且 <1s，经代理会超时(境外够不到国内 GGC)"
echo "         redirector 直连 000，经代理 204"
echo "   若边缘经代理超时但仍被送去代理 = Play 下载会卡 0 字节"
hr

if [ -n "$PROXY" ]; then
  echo "== 3. 经代理 $PROXY 下载（应仍是 direct 链，速度不应低于直连太多）"
  p "dl.google.com" "$("${CURL[@]}" -x "http://$PROXY" -w '%{http_code} %{time_total}s' "$DL_URL")"
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
echo "  - dl.google.com 直连返回 200/301 且 < 1s = Play 下载 CDN 可达"
echo "  - dl.google.com 经代理后明显变慢或 000 = 下载域名被送进代理（规则顺序问题）"
echo "  - GGC 边缘(58.254.x)直连快、经代理超时 = 正常"
echo "  - 边缘被送去代理 = Play 下载会卡 0；边缘直连超时 = DNS 拿到假 IP"
