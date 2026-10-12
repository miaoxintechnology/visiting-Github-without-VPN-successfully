# 不翻墙成功访问 GitHub

> 让你**不翻墙**、**合法地**顺畅访问 GitHub —— 解决 DNS 污染、IP 封锁导致的打不开、加载慢、`git clone` 失败等问题。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)]()

---

## 目录

- [快速开始](#快速开始)
- [问题背景：三种不同的封锁](#问题背景三种不同的封锁)
- [脚本原理](#脚本原理)
- [进阶：GitHub 的 IP 规律（重要）](#进阶github-的-ip-规律重要)
- [不用脚本的手动方案](#不用脚本的手动方案)
- [raw 文件的替代访问](#raw-文件的替代访问)
- [常见问题](#常见问题)
- [恢复原状](#恢复原状)
- [License](#license)

---

## 快速开始

**下载两个文件，放同一个目录，双击运行：**

| 文件 | 说明 |
|---|---|
| [`fix-github-fast.ps1`](fix-github-fast.ps1) | 核心脚本 |
| [`快速修复GitHub.bat`](快速修复GitHub.bat) | 双击它（中文名） |
| [`fix-github.bat`](fix-github.bat) | 同上（英文名，兼容非中文环境） |

**运行步骤：**

1. 双击 `快速修复GitHub.bat`
2. UAC 弹窗点"是"（需管理员权限改 `hosts`）
3. 等待 **60~150 秒**，看到 `完成！` 即可
4. 浏览器按 `Ctrl+F5` 强制刷新

> 手动运行：
> ```powershell
> powershell -ExecutionPolicy Bypass -File fix-github-fast.ps1
> ```

---

## 问题背景：三种不同的封锁

很多人以为"GitHub 被墙了"是一个问题，其实有**三种完全不同的封锁方式**，解法也完全不同：

| 封锁方式 | 现象 | 有效解法 |
|---|---|---|
| **① DNS 污染** | 域名解析到假 IP（常被解析到 Facebook 的 IP） | 改 `hosts` 指定真实 IP ✅ |
| **② IP 封锁** | TCP 能连上，但 TLS 握手被重置（RST） | 换一个没被封的 IP ✅ |
| **③ SNI 阻断** | 换 IP、换端口、换协议都无效，握手即断 | 只能走代理 ❌ |

**本方案解决 ① 和 ②**（覆盖 90% 以上的情况），对 ③ 无效。

### 如何判断自己遇到的是哪种？

```powershell
# 看域名解析到什么 IP
Resolve-DnsName github.com -Type A

# 正常应该解析到 20.205.243.x / 140.82.x.x
# 如果解析到 31.13.x.x / 157.240.x.x（Facebook 段）→ 这就是 DNS 污染
```

---

## 脚本原理

```
① 并行 TCP 探测        →  约 875 个候选 IP 中筛出 TCP 443 可达的（约 6 秒）
② 按服务分别验证        →  用 curl 逐个测试 HTTPS 是否真能通
③ 按 IP 规律优先排序    →  见下方"IP 尾号规律"
④ 写入 hosts + 刷新 DNS →  自动备份原 hosts
⑤ 验证并报告
```

技术要点：

- **并行探测**：用 `TcpClient.ConnectAsync` 批量发起连接，865 个 IP 分批探测，约 6 秒完成（旧方案顺序测要 10 分钟）
- **真实可用性验证**：TCP 通 ≠ HTTPS 通（GFW 常在 TLS 层阻断），所以必须用 `curl` 实测
- **全相对路径**：脚本用 `$PSCommandPath` / `%~dp0` 定位文件，**整个文件夹可随意复制移动到任何位置**
- **自动提权**：检测到非管理员时自动弹出 UAC，无需手动右键
- **自动备份**：每次运行都把 `hosts` 备份为 `hosts.bak-MMdd-HHmmss`

---

## 进阶：GitHub 的 IP 规律（重要）

这是本项目实测总结的**最有价值的部分** —— 掌握了它，手工换 IP 也能很快。

### 规律一：不同 IP 尾号承载不同服务

GitHub 每台前端服务器用**不同 IP 尾号**区分服务：

| IP 尾号 | 承载服务 |
|---|---|
| `.3` `.4` `.19` `.20` `.21` `.22` | `github.com` 网页 |
| `.5` `.6` | `api.github.com` |
| `.9` `.10` | `codeload.github.com` |

**这意味着**：以前给所有域名配同一批 IP 的做法是低效的 —— `api` 需要 `.6` 尾号的 IP，`codeload` 需要 `.9` 尾号的，混用就会时通时断。

### 规律二：不同 IP 段的封锁强度不同

| IP 段 | 归属 | 特点 |
|---|---|---|
| `140.82.112~127.x` | GitHub 自有 | 波动剧烈；**网页常被封**，但 `.6`/`.9` 尾号对 api/codeload 通常可用 |
| `20.205.243.x` | 微软 Azure（亚洲） | 网页相对更稳，**脚本会优先扫描** |
| `20.27.177.x` | 微软 Azure（亚洲） | 同上 |

**实测案例**（同一时刻、同一个 IP）：

```
140.82.116.6  →  api.github.com   ✅ 3/3 通
140.82.116.6  →  github.com       ❌ 0/2 全挂
```

同一个 IP，只是 SNI 不同，结果天差地别 —— 这说明 GFW 会针对**特定域名**做精确阻断，而不是简单封 IP。

### 规律三：封锁会动态轮换

同一个 IP 可能在几分钟内从 3/3 通变成 0/3 全挂。所以：

- **不要指望一次修复永久有效**
- 打不开了就**再运行一次脚本**
- hosts 里配多个 IP 做故障转移能显著提高成功率

---

## 不用脚本的手动方案

如果你不想运行脚本，或者用的是 macOS / Linux，可以手动操作。

### 1. 查真实 IP（用 DoH，绕过污染的本地 DNS）

```bash
# 腾讯 DoH
curl "https://doh.pub/dns-query?name=github.com&type=A" -H "accept: application/dns-json"

# 阿里 DoH
curl "https://dns.alidns.com/resolve?name=github.com&type=A"
```

> ⚠️ 注意：**国内部分 DoH 也会被污染**（实测阿里 DoH 对某些域名返回假 IP）。建议**用两个以上 DoH 交叉验证**，返回结果一致的才可信。

### 2. 写入 hosts

**Windows**：`C:\Windows\System32\drivers\etc\hosts`（需管理员）
**macOS / Linux**：`/etc/hosts`（需 sudo）

```
20.205.243.166 github.com
20.205.243.166 www.github.com
140.82.113.6   api.github.com
140.82.113.9   codeload.github.com
```

### 3. 刷新 DNS 缓存

```powershell
# Windows
ipconfig /flushdns
```
```bash
# macOS
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
# Linux (systemd)
sudo systemd-resolve --flush-caches
```

---

## raw 文件的替代访问

`raw.githubusercontent.com` 走的是 Fastly CDN（`185.199.108~111.133`），**这一整段常年被封**，hosts 方案救不了。需要下载单个原始文件时，把链接换成 jsDelivr 镜像：

```
原始：https://raw.githubusercontent.com/用户名/仓库/分支/文件路径
镜像：https://gcore.jsdelivr.net/gh/用户名/仓库@分支/文件路径
```

**实测可用的 jsDelivr 节点：**

| 节点 | 可用性 |
|---|---|
| `gcore.jsdelivr.net` | ✅ 可用 |
| `fastly.jsdelivr.net` | ⚠️ 常失败 |
| `cdn.jsdelivr.net` | ⚠️ 常失败 |

---

## 常见问题

**Q：脚本报"未找到可用的 IP"怎么办？**
A：说明当前干扰过强（GFW 的封锁强度是波动的）。等 1~2 分钟再运行一次即可。脚本退出不会破坏任何配置。

**Q：修好了，但过一会儿又不行了？**
A：正常现象。GFW 的 IP 封锁名单在快速轮换。重新运行脚本即可。这也是为什么脚本要设计成"60 秒能跑完"。

**Q：为什么第一次打开网页特别慢？**
A：`hosts` 里配了多个 IP 做故障转移，浏览器会依次尝试，前面的 IP 失效时要等超时。连上之后就正常了。

**Q：会有什么副作用吗？**
A：只修改 `hosts` 文件，不改动系统其他设置。每次运行都会自动备份，随时可以还原。GitHub 本身是合法网站，本方案没有任何翻墙行为。

**Q：为什么 `git clone` 有时还是失败？**
A：`git clone` 同时依赖 `github.com`（取 refs）和 `codeload.github.com`（下载 pack），任一不通都会失败。脚本已经为它们分别挑选了合适的 IP，但如果是 SNI 阻断（第三种封锁），就需要代理了。

**Q：macOS / Linux 能用吗？**
A：脚本是 Windows 专用的（PowerShell + hosts 路径）。其他系统可以参考上面的"[手动方案](#不用脚本的手动方案)"。

---

## 恢复原状

删除 `hosts` 文件里 `# === GitHub hosts ===` 到 `# === end GitHub ===` 之间的内容即可。

或者还原脚本自动生成的备份文件：

```powershell
# 列出所有备份
Get-ChildItem C:\Windows\System32\drivers\etc\hosts.bak-*

# 还原指定的备份
Copy-Item C:\Windows\System32\drivers\etc\hosts.bak-1012-153000 C:\Windows\System32\drivers\etc\hosts -Force
```

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带）或更高
- `curl.exe`（Windows 10 1803+ 已内置）

---

## 免责声明

本项目仅供**学习研究与网络诊断**使用，目的是恢复对 GitHub 这一开发者基础设施的正常访问。所有操作仅涉及修改本机 `hosts` 文件，不涉及任何翻墙工具或代理服务。请遵守当地法律法规，使用者自行承担相关责任。

---

## License

[MIT](LICENSE) © miaoxintechnology
