# google-play-routing-skill

> Google Play 商店/下载分流规则的「怎么写、为什么这么写」。
> 适配 **sing-box / mihomo(Clash.Meta) / Xray / Surge / Egern**。

## 这个 Skill 解决什么

Play 更新卡 0%、一直转圈、应用商店能开但装不上——90% 不是节点坏了，是**下载流量被送到了海外代理**。

一句话规则：

```
Play 的「下载」走直连，「商店 API」走代理。
```

## 目录

| 路径 | 内容 |
|---|---|
| [SKILL.md](SKILL.md) | 决策表、域名清单、三个必踩的坑、验证与排错入口 |
| [references/sing-box.md](references/sing-box.md) | `route.rules` 顺序、`action: resolve`、DNS 分流、DNS 劫持 |
| [references/mihomo.md](references/mihomo.md) | `rules` + `nameserver-policy` + `sniffer.override-destination` |
| [references/xray.md](references/xray.md) | `routing.rules` 的 `domain:` 前缀、sniffing 反投毒三件套 |
| [references/surge.md](references/surge.md) | `[Rule]` 顺序、`encrypted-dns-follow-outbound-mode` |
| [references/egern.md](references/egern.md) | `rules` 的 `domain_suffix.match`、`dns.forward` |
| [references/troubleshooting.md](references/troubleshooting.md) | 实测数据、检查顺序、六个真实踩过的坑 |
| [examples/](examples/) | 五个可直接改用的完整示例 |
| [scripts/verify-play-cdn.sh](scripts/verify-play-cdn.sh) | 一键验证：DNS 是否投毒、下载是否真走直连、速度对比 |

## 域名分组（背下来）

| 组 | 域名 | 走向 |
|---|---|---|
| 下载 CDN | `dl.google.com`、`*.xn--ngstr-lra8j.com`、`*.gvt1/2/3.com` | **DIRECT** |
| `dl-ssl.google.com` | 同为下载域名，但解析到境外 IP | **PROXY** |
| 视频流 | `*.googlevideo.com` | **按 IP 分流**（混合体，见下） |
| 商店 API | `play.googleapis.com`、`play-fe.googleapis.com`、`android.clients.google.com`、`*.googleapis.com` | **PROXY** |
| 资源 | `*.gstatic.com`、`*.ggpht.com`、`*.googleusercontent.com` | PROXY |

> ⚠️ `googlevideo.com` 是个**混合体**，全直连或全代理都错：
> - `rrN---sn-XXXX.googlevideo.com`（集群边缘）→ 真实 IP 是**国内联通 GGC**，只能直连
> - `redirector.googlevideo.com`（全局入口）→ 在境外，只能代理
>
> 正解是**先用干净 DNS 解析拿真实 IP，再按 IP 在不在国内分流**。
> 加密 DNS 也不等于干净 DNS——阿里 DoH 一样返回假 IP。
> 详见 [references/sing-box.md 第 4 节](references/sing-box.md#4-googlevideo-既不能一刀切直连也不能一刀切代理)。

`xn--ngstr-lra8j.com` 是 punycode，解码为 `ångströ.com`（Google 的 Angstrom CDN），**必须原样写 punycode**。

## 四条铁律

1. **下载域名规则必须排在 `google.com` 直系规则之前**，否则会被一起送走。
2. **`dl.google.com` 的 DNS 必须是国内视角**；**`googlevideo.com` 必须用「经代理的」加密 DNS**。两者方向相反，不能一刀切。
   注意：加密 ≠ 干净，国内 DoH（如阿里）对 `googlevideo` 一样返回假 IP。
3. **`googlevideo.com` 不要写死 direct 或 proxy**，要用 `resolve` 拿真 IP 后交给 `cncidr` 按 IP 分流。
4. **改完重启内核 + 手机重连 Wi-Fi**（清 Android DNS 缓存）。

## 快速验证

```bash
./scripts/verify-play-cdn.sh 127.0.0.1:7890
```

判据：直连返回 200/301/404 且 < 1s；经代理后明显变慢或超时 = 规则顺序错了。

## 作为 WorkBuddy Skill 使用

把本仓库放进 `~/.workbuddy/skills/google-play-routing/`（或项目的 `.workbuddy/skills/`），WorkBuddy 会在遇到 Play 分流问题时自动加载。

## 实测依据

所有结论来自 2026-11 在中国大陆移动宽带上的实测：

- 直连 `dl.google.com` **4.17–4.37 MB/s**，经海外代理 **1.05 MB/s**（差 4 倍）
- Play 下载 CDN 送海外代理：**000 / 20s，down=0 字节**
- `googlevideo.com` 本地 DNS 被投毒到 `108.160.165.9` / `31.13.112.9` / `199.59.148.96`，真实 GGC 为 `58.254.149.197`、`114.250.63.33`
- `redirector.googlevideo.com`（境外入口）**直连 000 秒断**，走代理 **204 / 0.76s**
- `rr2---sn-j5o76n7s.googlevideo.com`：阿里 DoH 返回 `64.13.192.74`（**000/5.8s 不通**），
  经代理的 DoH 返回 `58.254.137.131`（**204 / 0.03s**）——加密 DNS 在墙内同样被污染
- 该真 IP 从美国出口机直连：**000 / 10s**（所以境外代理永远救不了它）

细节见 [references/troubleshooting.md](references/troubleshooting.md)。

## License

MIT
