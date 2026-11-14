# 排错手册（含实测数据）

## 一、先分清"卡在哪一步"

Play 更新失败通常有四种形态，指向完全不同的原因：

| 形态 | 表现 | 指向 |
|---|---|---|
| A. 列表能刷、点更新转圈 | 商店 API 通，下载不通 | **下载域名走了代理**或 DNS 假 IP |
| B. Play 首页也打不开 | API 都不通 | 规则/节点问题 |
| C. 下载到某个百分比停住 | 部分 CDN 域名没覆盖 | 漏了 `xn--ngstr` 或 `googlevideo` |
| D. 只有 4G/蜂窝网络异常 | 分流只在 Wi-Fi 环境生效 | 客户端未在蜂窝下启用代理 |

## 二、实测数据（2026-11，中国大陆移动宽带）

### 显示"直连 vs 代理"差 4 倍

| 路径 | 速度 |
|---|---|
| 直连 `dl.google.com`（解析到 114.250.63.33） | **4.17–4.37 MB/s** |
| 经海外 hy2 节点下载同一文件 | 1.05 MB/s |
| 直连 `rr4---sn-xxx.xn--ngstr-lra8j.com` | 404 / 0.06s |
| 该域名送海外代理 | **000 / 20s，down=0 字节** |

### DNS 投毒实锤

| 域名 | 本地 DNS（223.5.5.5） | 经代理解析 |
|---|---|---|
| `rr4---sn-j5o76n7z.googlevideo.com` | `108.160.165.9`（Dropbox 段，**假**） | `58.254.149.197`（联通 GGC，**真**） |
| 同上（另一次） | `31.13.112.9`（Facebook 段，**假**） | — |
| 同上（另一次） | `199.59.148.96`（Twitter 段，**假**） | — |
| `dl.google.com` | `114.250.63.33`（联通 GGC，**真**） | 境外 IP（**不可用**） |

三个假 IP 直连全部 000 超时；真 IP 直连 404 / 0.06s。

**结论：`googlevideo.com` 必须加密解析；`dl.google.com` 必须国内解析。两者方向相反，不能一刀切。**

### 节点不影响结论

同一时刻从三个地区（美/澳/新）的节点访问 Play 下载 CDN 全部超时——说明问题与节点质量无关，是"海外回连国内 CDN"这一结构性错误。

## 三、检查顺序（每步都有明确判据）

```bash
# 1. 看真实连接（sing-box）
curl -s http://127.0.0.1:9090/connections | python3 -m json.tool | \
  grep -E '"host"|"chains"|"download"' | head -30
```
判据：下载类域名（`dl.google.com` / `gvt1` / `ngstr` / `googlevideo`）的 `chains` 应为 `["direct"]`。

```bash
# 2. 手工对比直连与代理
curl -s -m 8 -o /dev/null -w 'direct=%{speed_download}\n' \
  https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
curl -s -x http://127.0.0.1:7890 -m 8 -o /dev/null -w 'proxy=%{speed_download}\n' \
  https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
```
判据：`direct` 明显大于 `proxy`（本项目实测 4.2 vs 1.0）。若两者接近且都很低，是线路问题；若 `proxy` 远低于 `direct`，是规则把下载送进了代理。

```bash
# 3. 查 DNS 是否被投毒（sing-box 内置 DNS）
curl -s "http://127.0.0.1:9090/dns/query?name=rr4---sn-j5o76n7z.googlevideo.com&type=A"
```
判据：返回国内 GGC（`58.254.x` / `114.250.x`）为正常；返回 `108.160.x` / `31.13.x` / `199.59.x` 为投毒。

```bash
# 4. 模拟客户端拿到"国内 CDN IP"的场景
curl -s -x http://127.0.0.1:7890 -m 10 -o /dev/null \
  --resolve dl.google.com:443:114.250.63.33 \
  -w '%{http_code} %{time_total}\n' https://dl.google.com/
```
判据：返回 200/301 且 < 1s = 域名规则生效；000 超时 = 还在按 IP 决策。

## 四、六个真实踩过的坑

1. **`domain_suffix: google.com → PROXY` 吞掉了 `dl.google.com`。**
   加上"Google 全量走代理"后 Play 立刻 0 字节。正解：下载域名规则放最前。

2. **对 `dl.google.com` 做远程 DNS 重解析（sing-box `resolve`）。**
   远程 DNS 按出口所在地返回境外 IP → 直连失效 → 速度从 4.3MB/s 掉到 0.97MB/s。

3. **撤掉所有 `resolve` 后 `googlevideo.com` 又挂。**
   因为它被 `default_domain_resolver`（本地 DNS）解析，拿到投毒 IP。正解：`resolve` 只对 `googlevideo` / `gvt*` 生效，`dl.google.com` 排除。

4. **只改 TCP 规则，QUIC 用 `DROP`。**
   客户端要等 20s 超时才回落 TCP，表现为"打开很慢"。正解：`filter FORWARD ... -j REJECT --reject-with icmp-port-unreachable`（`raw`/`mangle` 表不支持 REJECT）。

5. **透明代理的 DNS 劫持被内网 RETURN 规则吃掉。**
   设备的 DNS 目标是网关 IP（`192.168.1.1`），撞上 `-d 192.168.0.0/16 -j RETURN`，劫持规则失效。正解：劫持规则插在该 RETURN 之前。

6. **测试用的 `iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT` 忘删，导致重定向自环。**
   代理内核自己的 DNS 查询也被重定向回自己 → 解析全部超时、`nslookup` 卡死。正解：测 DNS 劫持时用"指定一个内核不使用的 DNS IP 做跳板"（`-d 223.6.6.6 --dport 53`），不要用全量 53 重定向。

## 五、改完仍然转圈

按顺序排除：

1. **客户端 DNS 缓存**：Android 需重连 Wi-Fi / 开关飞行模式；Play 需强行停止再打开。
2. **`Private DNS`（DoT）**：手机会绕过 53 劫持，但本身是加密的（无泄露），此时靠内核的 `sniff` + 域名规则兜底。
3. **规则集版本**：机场/社区规则集会定期把 `dl.google.com` 归到 `google` 类目，订阅更新后可能"自己坏掉"。建议把下载规则写成**本地规则**，不要依赖远程规则集。
4. **内核未重启**：多数内核不热加载 `route` 段。
