# 排错手册（含实测数据）

## 一、先分清"卡在哪一步"

Play 更新失败通常有四种形态，指向完全不同的原因：

| 形态 | 表现 | 指向 |
|---|---|---|
| A. 列表能刷、点更新转圈 | 商店 API 通，下载不通 | **下载域名走了代理**或 DNS 假 IP |
| B. Play 首页也打不开 | API 都不通 | 规则/节点问题 |
| C. 下载到某个百分比停住 | 部分 CDN 域名没覆盖 | 漏了 `xn--ngstr` |
| D. 只有 4G/蜂窝网络异常 | 分流只在 Wi-Fi 环境生效 | 客户端未在蜂窝下启用代理 |
| E. **YouTube 页面能开、视频黑屏转圈** | 站点通、视频流不通 | `redirector.googlevideo.com` 走了 DIRECT（它在境外） |
| F. **Play 下载卡 0 字节、连接挂在 `googlevideo`** | 页面/API 都正常，就是不下载 | `rrN---sn-*` 被送去代理，**境外出口连不到国内 GGC** |

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

### 加密 DNS 也会被污染（关键）

「换成加密 DNS 就不怕投毒了」是错的——加密只保护「客户端 → 解析器」这一段，
解析器在墙内，上游拿到的就是错数据。

同一个域名 `rr2---sn-j5o76n7s.googlevideo.com`：

| 解析方式 | 返回 | 直连该 IP |
|---|---|---|
| 阿里 DoH `https://223.5.5.5/dns-query`（加密，墙内） | `64.13.192.74`（Akamai 段，**假**） | **000 / 5.8s** ❌ |
| 经代理的 DoH（墙外） | `58.254.137.131`（联通 GGC，**真**） | **204 / 0.03s** ✅ |

反过来 `dl.google.com` 必须用墙内视角：阿里 DoH → `58.254.149.161`（真 GGC）。

**结论：加密不决定对错，「解析器站在哪一边」才决定。**

### 境外出口连不到国内 GGC（用出口机验证）

`rrN---sn-XXXX.googlevideo.com` 是**集群专用主机名**，全球解析都指向同一个国内缓存。
在美国出口机上实测：

```
rr2---sn-j5o76n7s.googlevideo.com → 58.254.137.131    ← 解析正确
从美国机器直连它                  → 000 / 10s 超时    ← 但物理上够不到
```

所以「把 googlevideo 全部送去代理」永远修不好——**必须国内直连**。
但国内直连又会被投毒，于是唯一正解是：干净解析拿真 IP + 按 IP 分流。

### 节点不影响结论

同一时刻从三个地区（美/澳/新）的节点访问 Play 下载 CDN 全部超时——说明问题与节点质量无关，是"海外回连国内 CDN"这一结构性错误。

### `googlevideo.com` 与 `dl.google.com` 方向相反

| 域名 | 国内 DNS（223.5.5.5） | 直连 | 走代理 |
|---|---|---|---|
| `dl.google.com` | `114.250.63.33`（联通 GGC） | **200 / 4.09 MB/s** | 200 / 1.14 MB/s |
| `redirector.googlevideo.com` | `199.96.59.19`（境外） | **000 / 0.01s** | **204 / 0.76s** |
| `rr4---sn-xxx.xn--ngstr-lra8j.com` | 国内 GGC | 204 / 0.18s | — |

**判定法则：国内 DNS 解析出来的 IP 在不在国内。** 在国内 → 直连；在境外 → 必须代理。别靠"是不是 Google CDN"来判断。

## 三、检查顺序（每步都有明确判据）

```bash
# 1. 看真实连接（sing-box）
curl -s http://127.0.0.1:9090/connections | python3 -m json.tool | \
  grep -E '"host"|"chains"|"download"' | head -30
```
判据：Play 下载类域名（`dl.google.com` / `gvt1` / `ngstr`）的 `chains` 应为 `["direct"]`。

**`googlevideo.com` 没有统一的判据**——它是混合体，看主机名：

| 主机 | 期望 chains |
|---|---|
| `rrN---sn-XXXX.googlevideo.com`（国内 GGC 边缘） | `["direct"]`，且应 < 1s |
| `redirector.googlevideo.com`（境外入口） | 应出现节点名 |

关键看**延迟**而不是链名：边缘若 10s+ 或 `download` 恒为 0，就是 IP 不对或方向错了。

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

```bash
# 5. ★ 最后一次「经代理仍超时」时，去出口服务器上看它解析成了什么 IP
ssh root@<出口机>
getent ahostsv4 rr2---sn-j5o76n7s.googlevideo.com | head -1
curl -s -m 10 -o /dev/null -w '%{http_code} %{time_total}\n' \
  https://rr2---sn-j5o76n7s.googlevideo.com/generate_204
```
判据：如果解析结果是**国内 IP**（`58.254.x` / `114.250.x`），那这条路径注定失败——
境外机器永远够不到国内 GGC，必须改成国内直连。

## 四、八个真实踩过的坑

1. **`domain_suffix: google.com → PROXY` 吞掉了 `dl.google.com`。**
   加上"Google 全量走代理"后 Play 立刻 0 字节。正解：下载域名规则放最前。

1b. **把 `googlevideo.com` 混进「下载 CDN → DIRECT」白名单（坑 1 的镜像）。**
   Play 下载一切正常，**但 YouTube 视频全黑、一直转圈**。日志满是
   `dial tcp ...: i/o timeout using outbound/direct`，`chains` 显示 `["direct"]`。
   根因是把它和 `dl.google.com` 当成同类 CDN 写进了一条规则。

1c. **改全代理后，Play 下载又卡 0 字节 —— 于是以为 1b 的结论错了。**
   其实两边都没错：`googlevideo.com` 是**混合体**，
   `rrN---sn-*`（国内 GGC）只能直连，`redirector`（境外）只能代理。
   全直连和全代理都会翻车，唯一正解是 **`resolve` 拿干净 IP + `cncidr` 按 IP 分流**。
   详见 [sing-box.md 第 4 节](sing-box.md#4-googlevideo-既不能一刀切直连也不能一刀切代理)。

2. **对 `dl.google.com` 做远程 DNS 重解析（sing-box `resolve`）。**
   远程 DNS 按出口所在地返回境外 IP → 直连失效 → 速度从 4.3MB/s 掉到 0.97MB/s。

3. **撤掉所有 `resolve` 后 `googlevideo.com` 又挂。**
   因为它被 `default_domain_resolver`（本地 DNS）解析，拿到投毒 IP。
   正解：对 `googlevideo.com` 保留 `resolve`（server 指到经代理的干净 DNS），`dl.google.com` 排除在外。
   注意 `resolve` 只负责「用哪个 DNS 解析」，最终走直连还是代理，仍由后面的 `cncidr` 规则按 IP 决定。

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
