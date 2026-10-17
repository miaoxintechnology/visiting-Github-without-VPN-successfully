# visiting-Github-without-VPN-successfully

不翻墙成功访问 GitHub

> 自动识别三种不同的网络封锁，采用对应方案修复 GitHub 访问。**Windows + Linux/macOS 双平台**。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-blue)]()
[![Shell](https://img.shields.io/badge/shell-PowerShell%20%7C%20Bash-green)]()

---

## 目录

- [快速开始](#快速开始)
- [三种封锁方式（核心）](#三种封锁方式核心)
- [验证标准](#验证标准)
- [工作原理](#工作原理)
- [进阶：GitHub 的 IP 规律](#进阶github-的-ip-规律)
- [文件说明](#文件说明)
- [常见问题](#常见问题)
- [恢复原状](#恢复原状)
- [License](#license)

---

## 快速开始

### Windows

把 `fix-github.ps1`、`proxy.js`、`快速修复GitHub.bat` 放在**同一个文件夹**（任意位置），双击 `快速修复GitHub.bat`。

```powershell
# 或命令行运行（会自动请求管理员权限）
powershell -ExecutionPolicy Bypass -File fix-github.ps1
```

### Linux / macOS

```bash
chmod +x fix-github.sh

# 只做 hosts 直连（推荐，无额外依赖）
sudo ./fix-github.sh

# 启用代理方案（处理 SNI 封锁，需要 Node.js）
sudo ./fix-github.sh --proxy
```

#### 图形界面启动器（可选）

想在桌面双击运行，有两种方式：

**方式 1：一键安装（推荐）**

```bash
chmod +x install-desktop.sh
./install-desktop.sh
```

会自动生成 `.desktop` 启动器并安装到**桌面**和**应用菜单**（Exec 用绝对路径，最可靠）。

> 支持中文路径和空格。如果移动了文件夹，重新运行一次即可。
> 卸载：`./install-desktop.sh --uninstall`

**方式 2：便携版**

直接用仓库里的 `GitHub-自动修复.desktop`，它用 `%k` 自定位，可以随文件夹移动：

```bash
chmod +x GitHub-自动修复.desktop
# GNOME 还需右键 →「允许启动」
```

> ⚠️ 便携版的限制：如果路径含中文或空格，`%k` 会变成 URL 编码格式，可能定位失败。这种情况请用方式 1。

> **依赖**
> - Windows 10/11 + PowerShell 5.1 + `curl.exe`（系统自带）
> - Linux/macOS + `bash` 4+ + `curl`
> - **Node.js（可选）**：只有启用代理方案时才需要。没有 Node 时脚本自动降级为「只做 hosts 直连」。

---

## 三种封锁方式（核心）

很多人以为「GitHub 被墙了」是一个问题，其实有**三种完全不同的封锁**，解法完全不同：

| 封锁方式 | 判断方法 | 有效解法 | 脚本如何处理 |
|---|---|---|---|
| **① DNS 污染** | 域名解析到假 IP（如 `157.240.x.x`、`31.13.x.x`——属于 Facebook 段） | 改 hosts 指定真实 IP | ✅ 自动扫描可用 IP 写入 hosts |
| **② IP 封锁** | TCP 能连但 TLS 握手被 RST；换 IP 后可用 | 换一个没被封的 IP | ✅ 自动找未封锁的 IP |
| **③ SNI 阻断** | **同一 IP 上** `api.github.com` 能通、`github.com` 不通 | 只能「不发 SNI」转发 | ✅ 自动架设本地 SNI 剥离代理 |

### 如何区分 ② 和 ③

这是本项目的**关键诊断技巧**——用同一个 IP，只换 SNI：

```powershell
curl --resolve github.com:443:140.82.121.6        https://github.com       # 不通
curl --resolve api.github.com:443:140.82.121.6    https://api.github.com   # 能通
```

**同一个 IP，某些域名通、某些不通 → 就是 SNI 阻断**（第三种）。换 IP 永远修不好，必须用代理。

实测发现 GFW 精确封堵了 `github.com` 这个 SNI，而 `api` / `codeload` 子域没被封。

---

## 验证标准

脚本对**每个服务**都要求 **≥ 2/3 通过**（连测 3 次至少成功 2 次）才算达标：

| 服务 | 要求 |
|---|---|
| github.com | ≥2/3 |
| www.github.com | ≥2/3 |
| api.github.com | ≥2/3 |
| codeload.github.com | ≥2/3 |

**任何一项不达标 → 自动重新扫描修复**（最多 3 轮）。不够格绝不放行，不会出现「修完反而更糟」的情况。

> 为什么不用「单次测试通过」？因为 GFW 封锁是动态的，单次通过可能只是瞬时可用。多轮验证能筛掉「假可用」的 IP。

---

## 工作原理

```
① 并行 TCP 探测（约 6 秒，扫 800+ 个 IP）
        ↓
② 逐域名判断封锁类型
   ├─ 带 SNI 测试通过        → 直连模式
   └─ 带 SNI 失败 + 无 SNI 通过 → SNI 阻断 → 代理模式
        ↓
③ 应用配置
   ├─ 直连：把可用 IP 写入 hosts
   └─ 代理：生成自签证书 → 导入受信任根 → 写配置 → 启动代理 → hosts 指向 127.0.0.1
        ↓
④ 刷新 DNS 缓存
        ↓
⑤ 严格验证（每服务 ≥2/3），不达标回到 ② 重试
```

### 代理方案的技术要点

| 难点 | 解法 |
|---|---|
| 浏览器拒绝自签证书 | 用 `New-SelfSignedCertificate` 生成含所有域名的证书，自动导入「受信任的根证书颁发机构」 |
| SNI 阻断 | 代理转发上游时**不发送 SNI**（`servername: ''`），GFW 检测不到域名 |
| 无 SNI 被限速（实测 15~20 KB/s） | **启用 gzip 压缩**，572KB 首页压到 117KB，8-10 秒可打开 |
| IP 几分钟就失效 | 代理内置 **IP 池 + 健康度评分 + 自动故障转移** |
| 服务器默认 server block 缺 CORS 头 | 代理层**补齐 CORS 响应头**，否则跨域 JS 会被拦 |
| 反向代理导致重定向死循环 | 代理层**检测「重定向到自身」**并自动切换 IP |
| 大文件上传被截断 | >1MB 的请求走**流式转发**，不缓冲不截断 |

---

## 进阶：GitHub 的 IP 规律

实测总结，掌握后手工换 IP 也很快。

### 规律一：不同 IP 尾号承载不同服务

| IP 尾号 | 承载服务 |
|---|---|
| `.3` `.4` `.19` `.20` `.21` `.22` | `github.com` 网页 |
| `.5` `.6` | `api.github.com` |
| `.9` `.10` | `codeload.github.com` |

以前给所有域名配同一批 IP 是低效的——`api` 要 `.6` 尾号、`codeload` 要 `.9` 尾号，混用就会时通时断。

### 规律二：不同 IP 段封锁强度不同

| IP 段 | 归属 | 特点 |
|---|---|---|
| `140.82.112~127.x` | GitHub 自有 | 波动剧烈；网页常被封，但 `.6`/`.9` 尾号对 api/codeload 通常可用 |
| `20.205.243.x` / `20.27.177.x` | 微软 Azure（亚洲） | **网页相对更稳**，脚本优先扫描这段 |

### 规律三：封锁动态轮换

同一个 IP 可能在**几分钟内**从 3/3 通过变成 0/3 全挂。所以：

- 不要指望一次修复永久有效，打不开了就重新运行脚本
- 代理方案比纯 hosts 更能扛（IP 失效时代理自动切换）

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `fix-github.ps1` | **Windows 主脚本**（SNI 检测 + 自动配代理 + 严格验证） |
| `fix-github.sh` | **Linux/macOS 主脚本** |
| `proxy.js` | 本地 SNI 剥离代理（Node.js，两平台共用） |
| `快速修复GitHub.bat` / `fix-github.bat` | Windows 双击修复启动器（自动提权） |
| **`uninstall.ps1`** / **`一键回滚.bat`** | **Windows 一键回滚**（撤销所有改动） |
| **`uninstall.sh`** | **Linux/macOS 一键回滚** |
| `install-desktop.sh` | Linux 桌面启动器安装脚本（生成 .desktop 到桌面+应用菜单） |
| `GitHub-自动修复.desktop` | Linux 便携版启动器（`%k` 自定位，可随文件夹移动） |
| `LICENSE` | MIT |

---

## 常见问题

**Q：脚本提示「部分服务未达标」怎么办？**
A：说明当时网络干扰过强。直接再运行一次。若用代理模式，IP 失效时代理会自动切换，稍等片刻刷新即可。

**Q：修好了，过一会儿又不行了？**
A：正常现象，GFW 封锁在动态轮换。重新运行脚本即可。

**Q：为什么 github.com 打开要 8-10 秒？**
A：它走代理，而 GFW 对「无 SNI」连接限速到 15-20 KB/s，所以靠 gzip 压缩提速。`api` / `codeload` 走直连，正常 1-2 秒。

**Q：重启电脑后要重新运行吗？**
A：如果脚本为 `github.com` 启用了代理，**需要**。hosts 指向 `127.0.0.1`，代理没启动就打不开。建议把「启动代理」加入开机自启。

**Q：会有什么副作用吗？**
A：只改 `hosts` + 导入一张仅用于本地代理的自签证书 + 启动本地代理。不改动系统其他设置，每次运行都自动备份 `hosts`。

**Q：怎么确认是 SNI 阻断还是 IP 封锁？**
A：用上面的「同一 IP 不同 SNI」测试法。通一个不通另一个就是 SNI 阻断。

---

## 一键回滚（撤销所有改动）

不想用了？运行回滚脚本即可**彻底撤销所有改动**，系统恢复原状：

**Windows**

```powershell
# 双击 一键回滚.bat，或：
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

**Linux / macOS**

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

### 回滚会做什么

| 步骤 | Windows | Linux / macOS |
|---|---|---|
| ① 停止本地代理进程 | ✅ 结束监听 443 的 node | ✅ 同左 |
| ② 删除受信任的证书 | ✅ 从受信任的根证书颁发机构删除 | ✅ 系统 CA 库 + NSS |
| ③ 清理 hosts | ✅ 删除所有 GitHub 相关行（**保留其他配置**） | ✅ 同左 |
| ④ 删除配置文件 | ✅ pfx / cer / 配置 / 日志 | ✅ 同左 |
| ⑤ 删除桌面启动器 | — | ✅ 桌面 + 应用菜单 |
| ⑥ 刷新 DNS 缓存 | ✅ | ✅ |

**特点**

- **只删自己加的东西**——其他 hosts 条目（软件授权、内网域名等）一律保留
- **可重复运行**（幂等），跑两次也不会出问题
- 操作前自动备份 hosts（`hosts.bak-uninstall-MMdd-HHmmss`）
- 完成后自动验证并报告结果

> ⚠️ **回滚后 GitHub 会恢复为「无法访问」的原始状态** —— 这是预期行为，因为所有绕过措施（hosts 映射 + 本地代理 + 证书）都已移除。想再次修复时重新运行 `fix-github.ps1` / `fix-github.sh` 即可。

### 手动回滚（脚本不可用时）

**Windows**

```powershell
# 1. 还原 hosts 备份
Copy-Item C:\Windows\System32\drivers\etc\hosts.bak-1017-153000 C:\Windows\System32\drivers\etc\hosts -Force

# 2. 删除本地代理证书
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq 'CN=Local GitHub Proxy' } | Remove-Item -Force

# 3. 停代理 + 刷 DNS
Get-NetTCPConnection -LocalPort 443 -State Listen | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
ipconfig /flushdns
```

**Linux / macOS**

```bash
sudo cp /etc/hosts.bak-20261017-153000 /etc/hosts
sudo rm -f /usr/local/share/ca-certificates/local-github-proxy.crt && sudo update-ca-certificates --fresh
sudo pkill -f 'proxy.js'
```

---

## 免责声明

本项目仅供**学习研究与网络诊断**使用，目的是恢复对 GitHub 这一开发者基础设施的正常访问。所有操作仅涉及修改本机 `hosts` 文件、导入本机自签证书、运行本地代理，**不涉及任何翻墙工具或境外代理服务**。请遵守当地法律法规，使用者自行承担相关责任。

---

## License

[MIT](LICENSE) © miaoxintechnology
