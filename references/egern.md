# Egern

Egern 的规则段是「列表 + 首个命中即生效」，字段结构与 Surge/Clash 都不同，写法如下（官方文档 `egernapp.com/docs/configuration/rules`）。

## rules 段

```yaml
rules:
  # ---- Play 下载 CDN：直连，必须靠前 ----
  - domain_suffix:
      match: dl.google.com
    policy: DIRECT
  - domain_suffix:
      match: dl-ssl.google.com
    policy: DIRECT
  - domain_suffix:
      match: xn--ngstr-lra8j.com
    policy: DIRECT
  - domain_suffix:
      match: gvt3.com
    policy: DIRECT

  # ---- YouTube 视频流：必须走代理 ----
  - domain_suffix:
      match: googlevideo.com
    policy: 节点
  - domain_suffix:
      match: youtube.com
    policy: 节点
  - domain_suffix:
      match: youtu.be
    policy: 节点
  - domain_suffix:
      match: ytimg.com
    policy: 节点

  # ---- 商店 API：走代理 ----
  - domain_suffix:
      match: play.googleapis.com
    policy: 节点
  - domain_suffix:
      match: googleapis.com
    policy: 节点
  - domain_suffix:
      match: ggpht.com
    policy: 节点

  - geoip:
      match: CN
    policy: DIRECT

  - default:
      policy: 节点
```

要点：

- 每条规则是 `- <类型>: {match: ..., policy: ...}`，`policy` 取 `DIRECT` / `REJECT` / 节点名 / 策略组名。
- `domain_suffix` 会自动处理子域边界（`google.com` 匹配 `www.google.com`，不匹配 `fakegoogle.com`），所以**不要**再手写 `*.`。
- 支持 `domain_wildcard`（glob，如 `*.google.*`）与 `domain_regex`（`^ads?\.`）。
- 需要多条并列时可用逻辑组合：

```yaml
  - and:
      match:
        - domain_suffix:
            match: googlevideo.com
        - dest_port:
            match: "443"
      policy: 节点
```

## DNS 段

```yaml
dns:
  bootstrap:
    - system
  upstreams:
    ali:
      - 223.5.5.5
      - 119.29.29.29
    cf:
      - https://1.1.1.1/dns-query
  forward:
    # 下载域名：国内视角解析，才能拿到国内 GGC
    - wildcard:
        match: 'dl.google.com'
        value: ali
    - wildcard:
        match: '*.dl.google.com'
        value: ali
    # 防投毒：加密 DNS
    - wildcard:
        match: '*.googlevideo.com'
        value: cf
    - wildcard:
        match: '*.gvt1.com'
        value: cf
    - wildcard:
        match: '*.xn--ngstr-lra8j.com'
        value: cf
    # 国内域名走本地
    - proxy_rule_set:
        match: https://github.com/ACL4SSR/ACL4SSR/raw/master/Clash/ChinaDomain.list
        value: ali
    - wildcard:
        match: '*'
        value: cf
  public_ip_lookup_url: https://ifconfig.me/ip
```

要点：

- `forward` 段按顺序匹配，`value` 是 `upstreams` 里的组名。
- `public_ip_lookup_url` 影响 ECS：Egern 会用它查公网 IP 作为 EDNS Client Subnet 参数传给上游 DNS。**保留这一项**，否则 `dl.google.com` 可能拿不到就近的国内 GGC。
- `bootstrap: [system]` 只用于解析 DoH 服务器自身的域名，不遵循代理规则。

## 常见问题

| 现象 | 原因 |
|---|---|
| 规则不生效 | `default` 之外没写 `policy`，或节点名与实际策略组名不一致 |
| Play 仍转圈 | `domain_suffix: google.com → 节点` 写在下载规则之前 |
| 下载只有 1MB/s | `dl.google.com` 落到了 `value: cf` 的 DoH 上，解析出境外 IP |

完整示例：[examples/egern.yaml](../examples/egern.yaml)
