# Xray

## 路由段

```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "domain:dl.google.com",
          "domain:xn--ngstr-lra8j.com",
          "domain:gvt1.com",
          "domain:gvt2.com",
          "domain:gvt3.com"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "domain:redirector.googlevideo.com",
          "domain:youtube.com",
          "domain:youtu.be",
          "domain:ytimg.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": ["domain:googlevideo.com"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "domain:play.googleapis.com",
          "domain:play-fe.googleapis.com",
          "domain:android.clients.google.com",
          "domain:googleapis.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:cn"],
        "outboundTag": "direct"
      }
    ]
  }
}
```

要点：

- Xray 的 `domain:` 前缀是**子域后缀匹配**（`domain:google.com` 会匹配 `dl.google.com`），`full:` 才是精确匹配。所以下载域名规则必须写在 `geosite:google` 之前。
- `domainStrategy` 建议 `IPIfNonMatch`：域名规则未命中时才解析 IP 做 geoip 判断，减少无谓 DNS。
- **`dl-ssl.google.com` 不要放进 direct**：它解析到境外 IP，实测直连 000/7s、代理 204/0.67s。
- **`googlevideo.com` 不能一刀切**：`rrN---sn-*` 是国内 GGC（只能直连）、`redirector` 在境外（只能代理）。
  上面用「先精确拦 `redirector` → 代理，再让其余 googlevideo → direct」拆开处理。
  注意 Go 的 `domain:` 是后缀匹配，`domain:redirector.googlevideo.com` 只命中该主机本身，正好可以先拦。
- Xray 没有 sing-box 那种"按域名选 DNS 服务器"的能力，投毒问题要靠下面三件套解决：

## 反投毒三件套

### 1. Sniffing（必须开）

```json
{
  "inbounds": [{
    "tag": "socks-in",
    "port": 1080,
    "protocol": "socks",
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": false
    }
  }]
}
```

`destOverride` 会把客户端发来的"目标 IP"替换成嗅探出的域名，规则按域名匹配——这样即使客户端被投毒拿到假 IP，也能被域名规则救回来。

`routeOnly: true` 表示只用于路由判断、不覆盖实际连接目标；若目标是假 IP 且需要重解析，保持 `false` 更稳。

### 2. DNS 出站挂代理

```json
{
  "dns": {
    "servers": [
      {"address": "223.5.5.5", "domains": ["geosite:cn", "domain:dl.google.com"]},
      "https://1.1.1.1/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "outbounds": [
    {"tag": "dns-out", "protocol": "dns", "settings": {"address": "1.1.1.1", "port": 53}, "proxySettings": {"tag": "proxy"}}
  ]
}
```

### 3. hosts 硬编码（应急）

⚠️ **只适用于 Play 下载域名，不要对 `googlevideo.com` 这么做。**

`dl.google.com` 被投毒到失效 IP 时，可以临时写死一个可用的国内 GGC：

```json
{"dns": {"hosts": {"dl.google.com": "114.250.63.33"}}}
```

反之，**`googlevideo.com` 不要写死 IP**——它的边缘节点在国内（`58.254.x`）、`redirector` 在境外，
写死任何一个都会打死另一半。它需要的是**干净解析 + 按 IP/主机名分流**（见上文路由段）。

缺点：CDN 节点会变、主机名会变，只适合临时救火。

## 常见问题

| 现象 | 原因 |
|---|---|
| 规则写了 direct 但仍走代理 | 前面有 `geosite:google`（含 `dl.google.com`）先命中 |
| 嗅探不生效 | inbound 没开 `sniffing`，或客户端用的是 UDP/QUIC（需显式列 `quic`） |
| 改了 hosts 没生效 | Xray 已缓存，需重启 |

完整示例：[examples/xray.json](../examples/xray.json)
