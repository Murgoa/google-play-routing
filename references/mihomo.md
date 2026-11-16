# mihomo / Clash.Meta

## 规则段

```yaml
rules:
  # ---- 下载 CDN：必须直连，且必须排在 google.com 之前 ----
  - DOMAIN-SUFFIX,dl.google.com,DIRECT
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,DIRECT
  - DOMAIN-SUFFIX,gvt1.com,DIRECT
  - DOMAIN-SUFFIX,gvt2.com,DIRECT
  - DOMAIN-SUFFIX,gvt3.com,DIRECT

  # ---- googlevideo 是混合体：只有全局入口在境外，边缘节点都在国内 ----
  #   先精确拦掉境外入口，其余交给直连（fake-ip 模式下也能正确工作）
  - DOMAIN,redirector.googlevideo.com,PROXY
  - DOMAIN-SUFFIX,googlevideo.com,DIRECT
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
- **`dl-ssl.google.com` 不要写 DIRECT**：它解析到境外 IP，实测直连 000/7s，走代理 204/0.67s。
- **`googlevideo.com` 不要写死**：它下面混着国内 GGC 边缘和境外入口两类主机，全直连/全代理都会翻车。
  交给 `GEOIP,CN,DIRECT` 按 IP 落地，并在 `nameserver-policy` 里给它配**经代理的** DoH（否则国内 DNS 返回假 IP）。
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
    # gvt/ngstr 和 dl.google.com 一样，必须国内视角，才能拿到联通 GGC
    "+.gvt1.com": "223.5.5.5"
    "+.gvt2.com": "223.5.5.5"
    "+.gvt3.com": "223.5.5.5"
    "+.xn--ngstr-lra8j.com": "223.5.5.5"
    # googlevideo 必须走「经代理的」加密 DNS：国内 DNS（哪怕加密）返回的是假 IP
    "+.googlevideo.com": ["https://1.1.1.1/dns-query"]
```

要点：

- `+.` 前缀 = 后缀匹配（含自身），写在 `nameserver-policy` 的 key 上。
- **`dl.google.com` / `gvt*` / `xn--ngstr` 不要指向海外 DoH**：会返回境外 IP，直连失效、下载掉到 1MB/s。
- **`googlevideo` 必须指向海外 DoH**：国内 DNS 对它是投毒的（阿里 DoH 也一样，返回 `64.13.192.74` 这种不可用 IP）。
  加密 ≠ 干净，只有墙外的解析器才干净。
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
