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

      {"domain_suffix": ["googlevideo.com", "xn--ngstr-lra8j.com",
                         "gvt1.com", "gvt2.com", "gvt3.com"],
       "action": "resolve", "server": "remote"},

      {"domain_suffix": ["dl.google.com", "dl-ssl.google.com",
                         "xn--ngstr-lra8j.com", "gvt1.com", "gvt2.com",
                         "gvt3.com", "googlevideo.com"],
       "outbound": "direct"},

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
