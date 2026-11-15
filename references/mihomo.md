# mihomo / Clash.Meta

## 规则段

```yaml
rules:
  # ---- 下载 CDN：必须直连，且必须排在 google.com 之前 ----
  - DOMAIN-SUFFIX,dl.google.com,DIRECT
  - DOMAIN-SUFFIX,dl-ssl.google.com,DIRECT
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,DIRECT
  - DOMAIN-SUFFIX,gvt1.com,DIRECT
  - DOMAIN-SUFFIX,gvt2.com,DIRECT
  - DOMAIN-SUFFIX,gvt3.com,DIRECT

  # ---- YouTube 视频流：必须走代理（国内无 GGC 节点，直连必超时）----
  - DOMAIN-SUFFIX,googlevideo.com,PROXY
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,youtu.be,PROXY
  - DOMAIN-SUFFIX,ytimg.com,PROXY

  # ---- 商店 API：走代理 ----
  - DOMAIN-SUFFIX,play.googleapis.com,PROXY
  - DOMAIN-SUFFIX,play-fe.googleapis.com,PROXY
  - DOMAIN-SUFFIX,android.clients.google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY

  # ---- 资源 ----
  - DOMAIN-SUFFIX,ggpht.com,PROXY
  - DOMAIN-SUFFIX,googleusercontent.com,PROXY

  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

要点：

- `DOMAIN-SUFFIX,xn--ngstr-lra8j.com` 直接写 punycode 原文即可，mihomo 会自动匹配子域；**不要**写成 `*.xn--ngstr-lra8j.com`。
- 规则是**自上而下首个命中**，所以下载规则必须在 `GEOSITE,google` / `DOMAIN-SUFFIX,google.com` 之前。
- 如果用 `GEOSITE,category-google` 之类的大集合，务必确认它不会把 `dl.google.com` 一起吞掉（多数 geo 集合里 `google` 类目确实包含 `dl.google.com`）。

## DNS 段

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip          # 或 redir-host
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver-policy:
    # 下载域名：国内视角解析，拿到国内 GGC
    "dl.google.com": "223.5.5.5"
    "+.dl.google.com": "223.5.5.5"
    # 防投毒：走加密 DNS（需要代理支持 DoH）
    "+.googlevideo.com": ["https://1.1.1.1/dns-query"]
    "+.gvt1.com": ["https://1.1.1.1/dns-query"]
    "+.gvt2.com": ["https://1.1.1.1/dns-query"]
    "+.gvt3.com": ["https://1.1.1.1/dns-query"]
    "+.xn--ngstr-lra8j.com": ["https://1.1.1.1/dns-query"]
```

要点：

- `+.` 前缀 = 后缀匹配（含自身），写在 `nameserver-policy` 的 key 上。
- **`dl.google.com` 不要指向海外 DoH**：会返回境外 IP，直连失效、下载掉到 1MB/s。
- `fake-ip` 模式下规则匹配用的是域名，不会受"解析出的假 IP"影响；`redir-host` 模式下要特别注意投毒问题。

## 若 DNS 配置不生效

mihomo 的 `nameserver-policy` 只对**由 mihomo 发起**的解析生效。如果客户端自己做 DNS（手机用运营商 DNS），投毒仍在客户端发生，此时只能：

1. 让客户端 DNS 指向 mihomo 的 `dns.listen`；
2. 或在 mihomo 里开 `redir-host` + `sniffer`，用 SNI 覆盖客户端送来的 IP。

`sniffer` 片段：

```yaml
sniffer:
  enable: true
  override-destination: true      # 用嗅探出的域名覆盖目标，规则按域名走
  sniff:
    TLS:
      ports: [443]
    HTTP:
      ports: [80]
```

`override-destination: true` 是解决"客户端拿到假 IP"的关键开关。

完整示例：[examples/mihomo.yaml](../examples/mihomo.yaml)
