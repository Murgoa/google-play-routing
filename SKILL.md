---
name: google-play-routing
description: 编写与排查 Google Play 商店/下载分流规则（sing-box、mihomo、Xray、Surge、Egern）。当出现 Play 更新转圈、下载卡 0%、应用商店连不上、或需要为 dl.google.com / gvt1.com / xn--ngstr-lra8j.com / googlevideo.com 编写分流与 DNS 规则时使用。
---

# Google Play 分流规则

## 一句话结论

**Play 的「下载」走直连，「商店 API」走代理。** 反过来会稳定复现"转圈 + 0 字节"。

## 域名分三组，不要一把梭

| 组 | 域名 | 走向 | 理由 |
|---|---|---|---|
| **下载 CDN** | `dl.google.com`、`dl-ssl.google.com`、`*.xn--ngstr-lra8j.com`、`*.gvt1.com`、`*.gvt2.com`、`*.gvt3.com`、`*.googlevideo.com` | **DIRECT** | 国内有 GGC 节点（联通 58.254.x / 114.250.x），60ms、4MB/s+ |
| **商店 API** | `play.googleapis.com`、`play-fe.googleapis.com`、`android.clients.google.com`、`*.googleapis.com` | **PROXY** | 无国内节点，必须出墙 |
| **资源/图片** | `*.gstatic.com`、`*.ggpht.com`、`*.googleusercontent.com` | PROXY（gstatic 可直连） | 图标、封面、静态资源 |

> `xn--ngstr-lra8j.com` 是 punycode，解码为 `ångströ.com`（Google 的 Angstrom CDN），**必须原样写 punycode**，写 `ångströ` 或 `angstrom` 都匹配不上。它和 `gvt1.com` 是同一套下载基础设施的两种域名形态，两个都要写。

## 为什么下载必须直连（实测）

| 路径 | 结果 |
|---|---|
| 本地直连 `dl.google.com` | **4.2–4.4 MB/s** |
| 经海外代理下载同一文件 | 1.05 MB/s（受中转 CPU/线路限制） |
| 直连 `rr4---sn-xxx.xn--ngstr-lra8j.com` | **404 / 0.06s**（正常响应） |
| 把该域名送海外代理 | **000 / 20s 超时，down=0** |

根因：这些域名在国内解析出的是**国内 GGC IP**。请求送到海外节点后，是"美国服务器去回连中国联通 CDN"，必然超时。所以不是节点坏了、不是协议问题，是**方向错了**。

## 三个必踩的坑

**坑 1：`domain_suffix: google.com → PROXY` 一把梭。**
`dl.google.com` 也命中 `google.com` 后缀，于是下载被一起送走 → 转圈。必须把下载域名规则放在**代理规则之前**。

**坑 2：对下载域名做"远程 DNS 重解析"（sing-box 的 `resolve` / mihomo 的 `nameserver-policy` 指到海外 DoH）。**
`googlevideo.com` 需要这么做（本地 DNS 被投毒），但 `dl.google.com` **绝对不能**——远程 DNS 会按出口所在地返回境外 IP，此时直连照样挂。

**坑 3：只看域名规则，不看 DNS。**
`googlevideo.com` 在国内会被投毒成假 IP（实测出现 `108.160.165.9`（Dropbox 段）、`31.13.112.9`（Facebook 段）、`199.59.148.96`（Twitter 段））。客户端连的是假 IP，规则写成 DIRECT 也是超时。要么用加密 DNS 解析，要么在代理内做 `resolve` 重解析。

## DNS 怎么做才既不泄露又不出错

| 域名 | DNS 选择 | 原因 |
|---|---|---|
| 国内域名 | 国内 DNS（223.5.5.5 等） | 快 |
| `dl.google.com` / `dl-ssl.google.com` | **国内 DNS**（明文或加密均可，但必须是国内视角/中国 ECS） | 只有国内视角才返回国内 GGC |
| `googlevideo.com` / `gvt1-3` / `xn--ngstr` | **加密 DNS（经代理）** | 防投毒；实测经代理解析仍返回国内 GGC，可用 |
| 其余境外域名 | 加密 DNS（经代理） | 防泄露 + 防投毒 |

给终端设备（手机/电脑）省事的做法：把设备的 53 端口整体劫持进代理内核（sing-box `dns-in` + iptables REDIRECT 到 5335），由内核按上表分流解析，设备侧不再产生明文 DNS。

## 各客户端写法

- [sing-box](references/sing-box.md)：`route.rules` 顺序 + `action: resolve` + `default_domain_resolver`
- [mihomo / Clash.Meta](references/mihomo.md)：`rules` + `nameserver-policy`
- [Xray](references/xray.md)：`routing.rules` 的 `domain:` 前缀 + sniffer + `dns`
- [Surge](references/surge.md)：`[Rule]` 顺序 + `dns-server`/`encrypted-dns-server`
- [Egern](references/egern.md)：`rules` 的 `domain_suffix.match` + `dns.forward`

可直接改用的完整示例在 [examples/](examples/)。

## 落地顺序（照做即可）

1. 先加**下载域名 → DIRECT** 的规则，放在所有 `google.com` 代理规则之前。
2. 再加**API 域名 → PROXY**。
3. 处理 DNS：下载域名国内视角解析，`googlevideo`/`gvt*` 用加密 DNS。
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
| 转圈 0%，`down=0` | `/connections` 里这条连接的 `chains` | 下载域名走了代理 |
| 转圈但 `down` 有少量字节 | 该连接的目的 IP | DNS 返回了假 IP（投毒）或境外 IP |
| 规则明明写了 DIRECT 还是不通 | 域名是否命中更靠前的后缀规则 | 规则顺序错，`google.com` 先匹配了 |
| 只有 Play 不解，浏览器正常 | 是否只改了 TCP 规则、QUIC 被丢 | 透明代理下 UDP/443 用 REJECT 而非 DROP |
| 改完没变化 | 客户端 DNS 缓存 / 内核未重启 | 重连 Wi-Fi、重启内核 |

细节与实测数据见 [references/troubleshooting.md](references/troubleshooting.md)。
