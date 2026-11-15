# Surge

## [Rule] 段

```ini
[Rule]
# ---- Play 下载 CDN：直连，必须靠前 ----
DOMAIN-SUFFIX,dl.google.com,DIRECT
DOMAIN-SUFFIX,dl-ssl.google.com,DIRECT
DOMAIN-SUFFIX,xn--ngstr-lra8j.com,DIRECT
DOMAIN-SUFFIX,gvt1.com,DIRECT
DOMAIN-SUFFIX,gvt2.com,DIRECT
DOMAIN-SUFFIX,gvt3.com,DIRECT

# ---- YouTube 视频流：必须走代理（国内无 GGC 节点，直连必超时）----
DOMAIN-SUFFIX,googlevideo.com,节点
DOMAIN-SUFFIX,youtube.com,节点
DOMAIN-SUFFIX,youtu.be,节点
DOMAIN-SUFFIX,ytimg.com,节点

# ---- 商店 API：走代理 ----
DOMAIN-SUFFIX,play.googleapis.com,节点
DOMAIN-SUFFIX,play-fe.googleapis.com,节点
DOMAIN-SUFFIX,android.clients.google.com,节点
DOMAIN-SUFFIX,googleapis.com,节点

# ---- 其他 ----
DOMAIN-SUFFIX,ggpht.com,节点
DOMAIN-SUFFIX,googleusercontent.com,节点
GEOIP,CN,DIRECT
FINAL,节点,dns-failed
```

要点：

- Surge 规则**顺序即优先级**，`GEOIP,CN` 之前必须放好下载域名。
- 如果引用了 `RULE-SET,SYSTEM,GOOGLE` 之类，注意该集合通常含 `dl.google.com`，要么把它放在规则集之前，要么用 `no-resolve` 的空规则把它挤掉。
- `FINAL` 建议带 `dns-failed` 兜底参数（`no-resolve` 视策略）。

## [General] / DNS

```ini
[General]
dns-server = 223.5.5.5, 119.29.29.29
encrypted-dns-server = https://1.1.1.1/dns-query
encrypted-dns-follow-outbound-mode = true
```

- `encrypted-dns-follow-outbound-mode = true`：加密 DNS 跟随出站策略（境外解析走代理），既防泄露又防投毒。
- 但注意：**`dl.google.com` 走加密 DNS（尤其经代理）可能返回境外 IP**。若遇到下载掉速，可在 Surge 用 host 映射或局部关闭加密 DNS 验证。

## 验证 `dl.google.com` 走直连

Surge Mac 打开「请求」面板，筛选 `dl.google.com`，看 Policy 列是否为 `DIRECT`；或看日志：

```bash
grep "dl.google.com" ~/Library/Logs/Surge/*.log | tail -5
```

## 常见问题

| 现象 | 原因 |
|---|---|
| 手机上 Play 转圈、电脑上正常 | 手机走蜂窝网络未启用 Surge，或规则集版本旧 |
| 改了规则没生效 | 需要「重新加载配置」，Surge 不会热更新 Rule 段 |
| 下载速度只有 1MB/s | `dl.google.com` 命中代理规则（多为 `RULE-SET` 或 `DOMAIN-SUFFIX,google.com` 在更前面） |
| QUIC 相关 | Surge 默认已处理，无需额外规则 |

完整示例：[examples/surge.conf](../examples/surge.conf)
