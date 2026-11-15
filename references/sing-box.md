# sing-box

适用版本：1.11+（本文按 1.12/1.14 新语法写；1.11 之前 `dns` 段结构不同）。

## 核心结构

```
dns.servers        本地 DNS + 加密 DNS（后者 detour 到代理）
dns.rules          按域名选 DNS（顺序即优先级）
route.rules        按域名/IP 选出站（顺序即优先级）
route.default_domain_resolver   1.12+ 必写，否则 FATAL
```

## 关键写法

### 1. 出站规则（顺序是重点）

```json
{
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"},

      {"domain_suffix": ["dl.google.com", "dl-ssl.google.com",
                         "xn--ngstr-lra8j.com", "gvt1.com", "gvt2.com",
                         "gvt3.com"],
       "outbound": "direct"},

      {"domain_suffix": ["googlevideo.com"],
       "action": "resolve", "server": "remote"},

      {"domain_suffix": ["googlevideo.com", "youtube.com", "youtu.be",
                         "ytimg.com", "youtube-nocookie.com"],
       "outbound": "proxy"},

      {"domain_suffix": ["google.com", "googleapis.com", "gstatic.com",
                         "googleusercontent.com", "ggpht.com",
                         "android.com"],
       "outbound": "proxy"},

      {"rule_set": ["cn", "cncidr"], "outbound": "direct"}
    ],
    "final": "proxy"
  }
}
```

要点：

- **`domain` vs `domain_suffix`**：`domain` 精确匹配，`domain_suffix` 含子域。`dl.google.com` 用 `domain_suffix` 写即可（它自身也匹配）。
- **一条规则里的多个字段是 AND，同一字段里的多个值是 OR**。所以"域名 + rule_set"不能合并成一条。
- **`action: "resolve"` 必须排在对应 `outbound` 规则之前**，它只重解析不改去向。
- `{"protocol": "dns", "action": "hijack-dns"}` 一条即可覆盖「指定 inbound 的 DNS」和「mixed 入站的 DNS」，不需要再写 `{"inbound": [...], "action": "hijack-dns"}`（两者重复）。
- ⚠️ **`googlevideo.com` 不能和 `dl.google.com` 放在同一条 direct 规则里。** 两者走向相反（见 [第四节](#4-googlevideo-不能直连一个真实踩到的坑)），合写会直接把 YouTube 视频打死。

### 2. DNS

```json
{
  "dns": {
    "servers": [
      {"tag": "local",  "type": "udp", "server": "223.5.5.5"},
      {"tag": "remote", "type": "udp", "server": "1.1.1.1", "detour": "proxy"}
    ],
    "rules": [
      {"domain": ["dl.google.com", "dl-ssl.google.com"], "server": "local"},
      {"rule_set": ["cn"], "server": "local"}
    ],
    "final": "remote"
  }
}
```

- `detour: remote` 表示这条 DNS 查询走代理，防投毒、防泄露。
- **`dl.google.com` 必须 `local`**：远程 DNS 会按出口所在地返回境外 IP。
- `googlevideo.com` 不写规则也会落到 `final: remote`，所以不需要单独列（除非你的 `cn` 规则集里误含了它）。

### 3. 给终端设备接管 DNS（可选但推荐）

```json
{"type": "direct", "tag": "dns-in", "listen": "0.0.0.0", "listen_port": 5335}
```

```sh
iptables -t nat -A PREROUTING -i br0 -p udp -m mac --mac-source $MAC --dport 53 -j REDIRECT --to-ports 5335
iptables -t nat -A PREROUTING -i br0 -p tcp -m mac --mac-source $MAC --dport 53 -j REDIRECT --to-ports 5335
```

**注意顺序**：这两条要插在同设备的透明代理链（含 `-d 192.168.0.0/16 RETURN`）**之前**，否则内网目标 DNS（网关地址）会被 RETURN 掉，劫持不生效。

### 4. 透明代理（TCP）

```json
{"type": "redirect", "tag": "redirect-in", "listen": "0.0.0.0", "listen_port": 7892}
```

QUIC 处理：`raw` / `mangle` 表**不支持 REJECT**，要立即回落 TCP 就放 `filter FORWARD`：

```sh
iptables -I FORWARD 1 -i br0 -m mac --mac-source $MAC -p udp --dport 443 \
  -j REJECT --reject-with icmp-port-unreachable
```

用 `DROP` 会让客户端等超时，首次打开视频/下载会明显变慢。

## 常见 FATAL

| 报错 | 原因 |
|---|---|
| `default_domain_resolver is required` | 1.12+ 没写 |
| `legacy DNS server format` | 用了 `address: "udp://..."` 老格式 |
| 规则里 `outbound` 指向 urltest tag | urltest 的 tag 写在 `outbounds[].tag`，规则里要用这个 tag |

完整示例：[examples/sing-box.json](../examples/sing-box.json)

---

## 4. `googlevideo.com` 不能直连（一个真实踩到的坑）

> 这一节是踩坑后的复盘，结论与「下载 CDN 全部 DIRECT」的直觉相反，**请务必读完再抄配置**。

### 4.1 现象

YouTube 页面（`www.youtube.com`）能正常打开、列表能刷、封面能出，**但视频黑屏 / 一直转圈**。

日志里的特征非常明确：

```
ERROR ... open connection to [142.250.125.94]:443 using outbound/direct[direct]:
          dial tcp 142.250.125.94:443: i/o timeout
ERROR ... connection download closed: remote error: rejected
```

`clash_api` 里这条连接的 `chains` 是 `["direct"]`。

### 4.2 根因

配置里有一条本该只写 Play 下载域名的 `direct` 规则，`domain_suffix` 里混进了 `googlevideo.com`（以及 `xn--ngstr-lra8j.com`、`gvt1/2/3`）：

```json
// ❌ 错误：把视频流域名塞进了 Play 下载的直连白名单
{
  "domain_suffix": ["dl.google.com", "dl-ssl.google.com",
                    "xn--ngstr-lra8j.com", "gvt1.com", "gvt2.com",
                    "gvt3.com", "googlevideo.com"],
  "outbound": "direct"
}
```

因为 `route.rules` **先匹配先得**，`googlevideo.com` 在这条规则就被判了 `direct`，后面所有代理规则（含 `google.com → proxy`）再也轮不到它。而国内直连 Google 视频 CDN 必然超时。

**play 下载域名和 googlevideo 只是"看起来同类"（都是 Google 的 CDN），实际归属完全相反。**

### 4.3 为什么两者必须分开（实测判定）

| 域名 | 国内 DNS（223.5.5.5）解析 | 国内有无可用节点 | 直连实测 | 走代理实测 | 结论 |
|---|---|---|---|---|---|
| `dl.google.com` | `114.250.63.33`（联通 GGC） | **有** | **200 / 4.09 MB/s** | 200 / 1.14 MB/s | **DIRECT** |
| `rr4---sn-xxx.xn--ngstr-lra8j.com` | 国内 GGC | 有 | 204 / 0.18s | — | **DIRECT** |
| `redirector.googlevideo.com` | `199.96.59.19`（境外） | **无** | **000 / 0.01s 连接重置** | **204 / 0.76s** | **PROXY** |

判据非常干脆：**看国内 DNS 解析出来的 IP 在不在国内**。

- 解析到 `114.250.x` / `58.254.x`（联通 GGC）→ 直连快，代理反而慢（多绕一跳）
- 解析到境外 IP → 直连必挂，只能走代理

所以「Play 下载直连」这条规则**只对 `dl.google.com` / `gvt*` / `xn--ngstr` 成立**，`googlevideo.com` 必须走代理。

### 4.4 正确写法

```json
"rules": [
  {"action": "sniff"},
  {"protocol": "dns", "action": "hijack-dns"},
  {"ip_is_private": true, "outbound": "direct"},

  // ① Play 下载 CDN —— 国内有 GGC，直连
  {"domain_suffix": ["dl.google.com", "dl-ssl.google.com",
                     "xn--ngstr-lra8j.com", "gvt1.com", "gvt2.com", "gvt3.com"],
   "outbound": "direct"},

  // ② YouTube 视频流 —— 必须代理（先 resolve 防投毒，再改去向）
  {"domain_suffix": ["googlevideo.com"], "action": "resolve", "server": "remote"},
  {"domain_suffix": ["googlevideo.com", "youtube.com", "youtu.be",
                     "ytimg.com", "youtube-nocookie.com"],
   "outbound": "proxy"},

  // ③ Google 其余
  {"domain_suffix": ["google.com", "googleapis.com", "gstatic.com",
                     "googleusercontent.com", "ggpht.com", "android.com"],
   "outbound": "proxy"},

  {"rule_set": ["cn", "cncidr"], "outbound": "direct"}
]
```

顺序上要保证：**Play 下载直连规则 排在 YouTube/Google 代理规则之前**，且 `googlevideo` 的 `resolve` 排在它的 `outbound` 之前。

### 4.5 验证

```bash
# 视频流入口：直连会 000/秒断，代理应 204
curl -s -m 8 -o /dev/null -w 'proxy=%{http_code} t=%{time_total}\n' \
  -x http://127.0.0.1:7890 https://redirector.googlevideo.com/generate_204
curl -s -m 6 -o /dev/null -w 'direct=%{http_code} t=%{time_total}\n' \
  https://redirector.googlevideo.com/generate_204

# 确认 googlevideo 真正走了代理：chains 不应是 ["direct"]
curl -s http://127.0.0.1:9090/connections | sed 's/},{/}\n{/g' \
  | grep -i googlevideo | grep -o '"chains":\[[^]]*\]'

# 同时确认 Play 下载没被误伤：仍应 MB/s 量级
curl -s -m 8 -o /dev/null -w 'dl=%{http_code} speed=%{speed_download}\n' \
  https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
```

判据：`googlevideo` 的 `chains` 出现节点名 = 正常；`dl.google.com` 测速仍在 MB/s 级 = 没误伤 Play。

### 4.6 一句话记忆

> **`dl.google.com` / `gvt*` / `xn--ngstr` → 直连（国内 GGC）**
> **`googlevideo.com` → 代理（国内无节点）**
> 两者都是 Google CDN，但方向相反，**绝不能写进同一条规则**。

