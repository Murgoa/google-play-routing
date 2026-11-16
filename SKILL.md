---
name: google-play-routing
description: 编写与排查 Google Play 商店/下载分流规则（sing-box、mihomo、Xray、Surge、Egern）。当出现 Play 更新转圈、下载卡 0%、应用商店连不上、YouTube 视频黑屏/转圈、或需要为 dl.google.com / gvt1.com / xn--ngstr-lra8j.com / googlevideo.com 编写分流与 DNS 规则时使用。
---

# Google Play 分流规则

## 一句话结论

**Play 的「下载」走直连，「商店 API」走代理。** 反过来会稳定复现"转圈 + 0 字节"。

## 域名分组，不要一把梭

| 组 | 域名 | 走向 | 理由 |
|---|---|---|---|
| **下载 CDN** | `dl.google.com`、`*.xn--ngstr-lra8j.com`、`*.gvt1.com`、`*.gvt2.com`、`*.gvt3.com` | **DIRECT** | 国内有 GGC 节点（联通 58.254.x / 114.250.x），60ms、4MB/s+ |
| **`dl-ssl.google.com`** | 名字像下载域名，实际在境外 | **PROXY** | 直连必挂（实测 000/7s），走代理 204/0.67s |
| **视频流（混合体）** | `*.googlevideo.com` | **按 IP 分流** | `rrN---sn-*` 是国内 GGC（只能直连），`redirector` 在境外（只能代理） |
| **商店 API** | `play.googleapis.com`、`play-fe.googleapis.com`、`android.clients.google.com`、`*.googleapis.com` | **PROXY** | 无国内节点，必须出墙 |
| **资源/图片** | `*.gstatic.com`、`*.ggpht.com`、`*.googleusercontent.com` | PROXY（gstatic 可直连） | 图标、封面、静态资源 |
| **YouTube 页面** | `youtube.com`、`youtu.be`、`*.ytimg.com`、`youtubei.googleapis.com` | PROXY | 页面/封面/播放接口 |

> ⚠️ **`googlevideo.com` 既不属于下载 CDN，也不能笼统归为「走代理」。**
> 同一个后缀下混着两类主机：`rrN---sn-XXXX.googlevideo.com` 是**集群专用名，全球解析都指向国内联通 GGC**（如 `58.254.137.131`）；而 `redirector.googlevideo.com` 在境外。
> 于是「全直连」打死 YouTube，「全代理」打死 Play 下载（境外机器永远够不到国内 GGC）。
> **正解：先用干净 DNS 解析拿真实 IP，再按 IP 在不在国内分流。**
> 详见 [references/sing-box.md 第 4 节](references/sing-box.md#4-googlevideo-既不能一刀切直连也不能一刀切代理)。

> `xn--ngstr-lra8j.com` 是 punycode，解码为 `ångströ.com`（Google 的 Angstrom CDN），**必须原样写 punycode**，写 `ångströ` 或 `angstrom` 都匹配不上。它和 `gvt1.com` 是同一套下载基础设施的两种域名形态，两个都要写。

## 为什么下载必须直连（实测）

| 路径 | 结果 |
|---|---|
| 本地直连 `dl.google.com` | **4.2–4.4 MB/s** |
| 经海外代理下载同一文件 | 1.05 MB/s（受中转 CPU/线路限制） |
| 直连 `rr4---sn-xxx.xn--ngstr-lra8j.com` | **404 / 0.06s**（正常响应） |
| 把该域名送海外代理 | **000 / 20s 超时，down=0** |

根因：这些域名在国内解析出的是**国内 GGC IP**。请求送到海外节点后，是"美国服务器去回连中国联通 CDN"，必然超时。所以不是节点坏了、不是协议问题，是**方向错了**。

## 五个必踩的坑

**坑 1：`domain_suffix: google.com → PROXY` 一把梭。**
`dl.google.com` 也命中 `google.com` 后缀，于是下载被一起送走 → 转圈。必须把下载域名规则放在**代理规则之前**。

**坑 1b：把 `googlevideo.com` 当成「一类东西」处理——无论全直连还是全代理都是错的。**
这是最隐蔽的坑，因为它会**分两次咬人**：
- 写进 DIRECT 白名单 → **YouTube 视频全黑**（`redirector` 在境外，直连秒断）
- 改成全部 PROXY → **Play 下载卡 0 字节**（`rrN---sn-*` 是国内 GGC，境外够不到）

正解不是选边，而是**按解析出的 IP 分流**（见下方「坑 4」与 [sing-box.md 第 4 节](references/sing-box.md#4-googlevideo-既不能一刀切直连也不能一刀切代理)）。

**坑 2：对下载域名做"远程 DNS 重解析"（sing-box 的 `resolve` / mihomo 的 `nameserver-policy` 指到海外 DoH）。**
`googlevideo.com` 需要这么做（本地 DNS 被投毒），但 `dl.google.com` **绝对不能**——远程 DNS 会按出口所在地返回境外 IP，此时直连照样挂。

**坑 3：只看域名规则，不看 DNS。**
`googlevideo.com` 在国内会被投毒成假 IP（实测 `rr2---sn-j5o76n7s` → `185.45.7.185`、`rr4---sn-j5o7dn7s` → `108.160.166.62`（Dropbox 段）、历史还出现过 `31.13.112.9`（Facebook 段））。客户端连的是假 IP，规则写成 DIRECT 也是超时。

**坑 4：以为「换成加密 DNS 就干净了」。**
加密只保护「客户端 → 解析器」这一段；解析器本身在墙内，上游拿到的就是错数据。
实测同一个域名：

| 加密 DNS | 返回 | 结果 |
|---|---|---|
| 阿里 DoH `https://223.5.5.5/dns-query` | `64.13.192.74`（假） | **000 / 5.8s** ❌ |
| 经代理的 DoH | `58.254.137.131`（真·联通 GGC） | **204 / 0.03s** ✅ |

反过来，`dl.google.com` **必须**用国内视角的加密 DNS（阿里 DoH 返回 `58.254.149.161` 真 GGC），换境外 DNS 反而拿不到国内节点。
**结论：加密不决定对错，「解析器站在哪一边」才决定。** 两类域名要配两套 DNS。

## DNS 怎么做才既不泄露又不出错

| 域名 | DNS 选择 | 原因 |
|---|---|---|
| 国内域名 | 国内 DNS（223.5.5.5 等） | 快 |
| `dl.google.com` / `gvt1-3` / `xn--ngstr` | **国内视角**（明文或加密都行，但必须是国内/中国 ECS） | 只有国内视角才返回联通 GGC |
| `dl-ssl.google.com` | 加密 DNS（经代理） | 它解析到境外 IP，跟 Play CDN 不是一回事 |
| `googlevideo.com` | **加密 DNS（必须经代理）** | 国内解析是假 IP；且必须拿到**真实** IP 才能判断该直连还是该代理 |
| 其余境外域名 | 加密 DNS（经代理） | 防泄露 + 防投毒 |

> ⚠️ 注意「加密」和「干净」是两件事。阿里 DoH 也是加密的，但它在墙内，对 `googlevideo` 一样返回假 IP（实测 `64.13.192.74`，连不通）。**只有经代理的加密 DNS 才干净。**

给终端设备（手机/电脑）省事的做法：把设备的 53 端口整体劫持进代理内核（sing-box `dns-in` + iptables REDIRECT 到 5335），由内核按上表分流解析，设备侧不再产生明文 DNS。

## 各客户端写法

- [sing-box](references/sing-box.md)：`route.rules` 顺序 + `action: resolve` + `default_domain_resolver`
- [mihomo / Clash.Meta](references/mihomo.md)：`rules` + `nameserver-policy`
- [Xray](references/xray.md)：`routing.rules` 的 `domain:` 前缀 + sniffer + `dns`
- [Surge](references/surge.md)：`[Rule]` 顺序 + `dns-server`/`encrypted-dns-server`
- [Egern](references/egern.md)：`rules` 的 `domain_suffix.match` + `dns.forward`

可直接改用的完整示例在 [examples/](examples/)。

## 落地顺序（照做即可）

1. 先加**下载域名 → DIRECT** 的规则（`dl.google.com` / `gvt*` / `xn--ngstr`，**不含 `dl-ssl`、不含 `googlevideo`**），放在所有 `google.com` 代理规则之前。
2. 再加 **API 域名 → PROXY**；`googlevideo.com` 单独用 `resolve` 拿干净 IP，然后**交给 `cncidr` 规则按 IP 分流**（不要写死 direct 或 proxy）。
3. 处理 DNS：Play CDN 用**国内视角**解析；`googlevideo` 用**经代理的加密 DNS**（只有它才干净）。
4. 重启内核，用 `scripts/verify-play-cdn.sh` 验证（见下）。
5. 手机端**重连一次 Wi-Fi**（清 Android DNS 缓存），再试 Play。

## 验证方法（不看日志就等于瞎猜）

```bash
# 1) 下载域名是否真的直连（应 4MB/s 量级）
curl -x http://127.0.0.1:7890 -m 8 -o /dev/null \
  -w 'speed=%{speed_download}\n' \
  https://dl.google.com/android/repository/platform-tools-latest-darwin.zip

# 2) 模拟"客户端拿到国内 CDN IP"的场景，确认仍按域名走直连
curl -x http://127.0.0.1:7890 -m 10 -o /dev/null --resolve dl.google.com:443:114.250.63.33 \
  -w '%{http_code} %{time_total}\n' https://dl.google.com/

# 3) 看真实命中规则（sing-box clash_api）
curl -s http://127.0.0.1:9090/connections | grep -o '"chains":\[[^]]*\]' | head

# 4) 确认 DNS 没被投毒
curl -s "http://127.0.0.1:9090/dns/query?name=rr4---sn-j5o76n7z.googlevideo.com&type=A"
```

判据：`chains=["direct"]` 且测速在 MB/s 级 = 正常；`chains` 里出现节点名 = 下载还在走代理，规则没生效。

## 排错流程

| 现象 | 先查什么 | 常见原因 |
|---|---|---|
| 转圈 0%，`down=0`，连接还挂在 `googlevideo` | 该连接的目的 IP | **境外出口连不到国内 GGC**（`rrN---sn-*` 被送去了代理） |
| 转圈 0%，`down=0`，连接挂在 `dl.google.com` | `/connections` 里的 `chains` | Play 下载域名走了代理（规则缺失或顺序错） |
| 转圈但 `down` 有少量字节 | 该连接的目的 IP | DNS 返回了假 IP（投毒）或境外 IP |
| 页面能开、媒体全黑 | 媒体域名走了 direct | `redirector.googlevideo.com` 在境外，必须代理 |
| 规则明明写了 DIRECT 还是不通 | 域名是否命中更靠前的后缀规则 | 规则顺序错，`google.com` 先匹配了 |
| 只有 Play 不解，浏览器正常 | 是否只改了 TCP 规则、QUIC 被丢 | 透明代理下 UDP/443 用 REJECT 而非 DROP |
| 改完没变化 | 客户端 DNS 缓存 / 内核未重启 | 重连 Wi-Fi、重启内核 |

细节与实测数据见 [references/troubleshooting.md](references/troubleshooting.md)。
