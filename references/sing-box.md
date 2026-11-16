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

      {"domain_suffix": ["dl.google.com", "xn--ngstr-lra8j.com",
                         "gvt1.com", "gvt2.com", "gvt3.com"],
       "outbound": "direct"},

      {"domain_suffix": ["googlevideo.com"],
       "action": "resolve", "server": "remote"},

      {"domain_suffix": ["google.com", "googleapis.com", "gstatic.com",
                         "googleusercontent.com", "ggpht.com",
                         "android.com", "youtube.com", "youtu.be",
                         "ytimg.com"],
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
- **`action: "resolve"` 必须排在按 IP 决策的规则之前**，它只换解析用的 DNS、不改去向。
- `{"protocol": "dns", "action": "hijack-dns"}` 一条即可覆盖「指定 inbound 的 DNS」和「mixed 入站的 DNS」，不需要再写 `{"inbound": [...], "action": "hijack-dns"}`（两者重复）。
- ⚠️ **`googlevideo.com` 既不要放进 direct 列表，也不要放进 proxy 列表。** 它下面混着国内 GGC 边缘和境外入口两类主机，只能「干净解析 + 按 IP 分流」（见 [第四节](#4-googlevideo-既不能一刀切直连也不能一刀切代理)）。
- ⚠️ **`dl-ssl.google.com` 不要放进 direct 列表**：它解析到境外 IP，直连会挂，交给代理。

### 2. DNS

```json
{
  "dns": {
    "servers": [
      {"tag": "local",  "type": "udp", "server": "223.5.5.5"},
      {"tag": "remote", "type": "udp", "server": "1.1.1.1", "detour": "proxy"}
    ],
    "rules": [
      {"domain_suffix": ["dl.google.com", "xn--ngstr-lra8j.com",
                         "gvt1.com", "gvt2.com", "gvt3.com"], "server": "local"},
      {"rule_set": ["cn"], "server": "local"}
    ],
    "final": "remote"
  }
}
```

- `detour: proxy` 表示这条 DNS 查询走代理。**它是唯一能拿到真实答案的解析器**。
- **Play 下载域名必须 `local`**（国内视角）：
  - `dl.google.com` 走远程 DNS 会按出口所在地返回境外 IP → 直连失效
  - `xn--ngstr` / `gvt*` 用国内视角才能拿到联通 GGC
- **`googlevideo.com` 落到 `final: remote`**，即由代理侧解析——这是**故意**的，因为它国内解析会被投毒。
- ⚠️ **`local` 用加密 DNS（DoH）也一样会被投毒**：加密只保护「你→解析器」这一段，阿里 DNS 在墙内，
  上游拿到的就是错的。实测 `rr2---sn-j5o76n7s.googlevideo.com` 阿里 DoH 返回 `64.13.192.74`（不通），
  经代理的 DoH 返回 `58.254.137.131`（204/0.03s）。**加密不等于干净，「解析器在哪一边」才决定对错。**

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

## 4. `googlevideo.com` 既不能一刀切直连，也不能一刀切代理

> 这一节是两轮踩坑后的复盘。同一个域名后缀下面**混着两类完全不同的主机**，
> 所以「全直连」和「全代理」都是错的，正确解法是**干净解析 + 按 IP 分流**。

### 4.1 两种现象，同一个根

| 现象 | 表现 | 卡在哪 |
|---|---|---|
| A | YouTube 页面能开、视频黑屏转圈 | `redirector.googlevideo.com` 走了直连（境外 IP，连不上） |
| B | Play 下载卡 0 字节、UI 一直转 | `rrN---sn-*.googlevideo.com` 走了代理（国内 GGC，境外连不上） |

两种反向的失败，根因是同一个：**googlevideo 下有两种主机，走向本来就不一样**。

### 4.2 一个域名后缀，两类主机

| 类型 | 例子 | 真实 IP 归属 | 只能怎么走 |
|---|---|---|---|
| **集群边缘（GGC）** | `rr2---sn-j5o76n7s.googlevideo.com`<br>`rr4---sn-j5o7dn7s.googlevideo.com` | **国内联通 GGC**（`58.254.137.x`） | **只能国内直连** |
| **全局入口** | `redirector.googlevideo.com` | 境外（`199.96.59.19` 等） | **只能走代理** |

关键点：`rrN---sn-XXXX` 是**集群专用主机名**，全球解析都指向同一个国内缓存——
在美国服务器上用 `8.8.8.8` 解析，拿到的也是 `58.254.137.131`。

所以「把 googlevideo 全部送去海外代理」这件事，从物理上就不可能成功：
境外机器去连一个只服务中国联通 ISP 的 GGC，必然超时。

### 4.3 实测数据

在**路由器（国内）**上测：

| 主机 | 阿里 DoH（加密）返回 | 干净 DoH（经代理）返回 | 直连真 IP | 走代理 |
|---|---|---|---|---|
| `rr2---sn-j5o76n7s` | `64.13.192.74`（假，Akamai 段）→ 000/5.8s | **`58.254.137.131`** | **204 / 0.03s** | 000 / 12s |
| `rr4---sn-j5o7dn7s` | 假 IP | `58.254.137.197` | 204 | 000 / 12s |
| `redirector` | `199.96.59.19`（境外） | 同 | **000 / 0.01s** | **204 / 0.9s** |

在**出口服务器（美国 dedirock）**上测同一个域名：

```
rr2---sn-j5o76n7s.googlevideo.com → 58.254.137.131   ← 解析是对的
从这台美国机器直连它              → 000 / 10s 超时   ← 但连不上
```

这三组数据说明：

- 直连时 DNS 会被投毒 → 拿到假 IP → 失败
- 走代理时 IP 是对的，但**境外到不了国内 GGC** → 也失败

### 4.4 加密 DNS ≠ 干净 DNS

「用加密 DNS 不就不会被投毒了？」——不行，这是最容易误判的一点。

**加密只保护「客户端 → 解析器」这一段**。解析器本身在墙内，它向上游查询时拿到的就已经是错数据，
加密传输一个错误答案，结果还是错的。

实测同一个域名，两种加密 DNS：

| 加密 DNS | 返回 | 实测 |
|---|---|---|
| 阿里 DoH（`https://223.5.5.5/dns-query`） | `64.13.192.74` | **000 / 5.8s** ❌ |
| 经代理的 DoH（`remote`） | `58.254.137.131` | **204 / 0.03s** ✅ |

反过来，`dl.google.com` 这类域名**必须**用国内视角的加密 DNS，才能拿到国内 GGC：

```
阿里 DoH → dl.google.com = 58.254.149.161   （真·联通 GGC）✅
```

**结论：加密不决定对错，「解析器站在哪一边」才决定。** 两类域名方向相反，要分别用两套 DNS。

### 4.5 正确写法：干净解析 + 按 IP 分流

既然走向取决于**解析出来的 IP 在不在国内**，就让 `cncidr` 规则去判：

```json
"rules": [
  {"action": "sniff"},
  {"protocol": "dns", "action": "hijack-dns"},
  {"ip_is_private": true, "outbound": "direct"},

  // ① googlevideo：先用干净 DNS 拿真实 IP（不决定去向）
  {"domain_suffix": ["googlevideo.com"], "action": "resolve", "server": "remote"},

  // ② Play 下载 CDN —— 国内有 GGC，直连
  {"domain_suffix": ["dl.google.com", "xn--ngstr-lra8j.com",
                     "gvt1.com", "gvt2.com", "gvt3.com"],
   "outbound": "direct"},

  // ③ Google 其余（注意：不要包含 googlevideo.com）
  {"domain_suffix": ["google.com", "googleapis.com", "gstatic.com",
                     "googleusercontent.com", "ggpht.com", "android.com",
                     "youtube.com", "youtu.be", "ytimg.com"],
   "outbound": "proxy"},

  // ④ 按 IP 落地：国内 GGC → 直连；其余 → final(proxy)
  {"rule_set": ["cn", "cncidr"], "outbound": "direct"}
],
"final": "proxy"
```

三条要点：

1. **`resolve` 只改「用哪个 DNS 解析」，不改去向**，必须排在按 IP 决策的规则之前。
2. **`googlevideo.com` 不能出现在 ③ 的代理域名列表里**，否则它在 ③ 就被判走代理，轮不到 ④。
3. `dl-ssl.google.com` **不要**放进 ② 的直连列表——它解析到境外 IP，直连会挂
   （实测路由器直连 000/7s，走代理 204/0.67s）。

### 4.6 验证

```bash
# 边缘节点：应为 204 且很快（走直连）
curl -s -m 8 -o /dev/null -w 'ggc=%{http_code} t=%{time_total}\n' \
  -x http://127.0.0.1:7890 https://rr2---sn-j5o76n7s.googlevideo.com/generate_204

# 全局入口：应为 204（走代理，慢一些是正常的）
curl -s -m 8 -o /dev/null -w 'redirector=%{http_code} t=%{time_total}\n' \
  -x http://127.0.0.1:7890 https://redirector.googlevideo.com/generate_204

# 看实际出口链：边缘应为 ["direct"]，redirector 应出现节点名
curl -s http://127.0.0.1:9090/connections | tr '}' '\n' \
  | grep -i googlevideo | grep -oE '"host":"[^"]*"|"chains":\[[^]]*\]'
```

**排查铁律**：只要「经代理仍然超时」，就 SSH 到**出口服务器**上跑一句
`curl https://<域名>/generate_204`，看它把域名解析成了什么 IP。
这次就是在出口机上发现它解析到国内联通 IP，才定位到本质原因。

### 4.7 一句话记忆

> **googlevideo 是混合体：`rrN---sn-*` 是国内 GGC（只能直连），`redirector` 在境外（只能代理）。**
> 所以不要按域名决定，要**先用干净 DNS 解析，再按 IP 在不在国内决定**。
> 加密 DNS 不等于干净 DNS——解析器的位置才是关键。
