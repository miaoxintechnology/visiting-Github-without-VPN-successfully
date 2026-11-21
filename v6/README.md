# GitHub 加速器 v6（Windows / Linux / macOS）

> 适用：Windows 10/11、Linux（systemd 系）、macOS，在中国大陆网络下访问 `github.com` 遇到 **SNI 阻断 / DNS 污染** 的场景。
> 本目录是 v6；旧版 v5 位于仓库的 [`../v5/`](../v5/README.md)，文件原样保留，随时可以退回去。

---

## 一、v6 改了什么

| 项目 | v5 | v6 |
|---|---|---|
| 每域名 IP 数 | 2 个，写死在 hosts / config | 默认 **5 个**，扫描验证后写入，代理内按健康度排序、自动故障转移、记住上次成功的 IP |
| 开机自启 | 无（重启后 hosts 指向 127.0.0.1，代理没起来 = GitHub 全挂） | **计划任务 `GitHubAcceleratorV6`**：登录后 20 秒启动，失败自动重试 5 次，随任务运行 |
| 证书私钥 | 口令硬编码 `localproxy`，PFX 与配置明文放在桌面，私钥还留在「个人」证书存储 | **40 位随机口令**，DPAPI 加密保存（仅当前用户+本机可解），PFX/口令文件 ACL 仅当前用户+SYSTEM，**私钥只存在于加密 PFX**，有效期 2 年 |
| 上游证书校验 | `rejectUnauthorized: false`，完全不校验 | 默认 **strict**：校验证书链（Node 内置根）+ 主机名；只有全部 IP 都校验失败时才降级，并写 `SECURITY` 日志 |
| 代理服务范围 | 任意 Host 都能转发（本地开放转发），还会用 DoH 解析任意域名 | **allowlist**：只服务配置里的 `github.com`，其他 Host 一律 `403`，不做任何外部 DNS 查询 |
| 上游全挂时 | 返回 `200` + 纯文本 `all upstreams failed`（客户端 JSON 解析失败，表现为“登录失败/响应不可读”） | 返回 **`502` + JSON**，并带 `retry-after`，错误语义正确 |
| 慢 IP 处理 | 顺序重试 2 个 IP，每个超时 25 秒，客户端常先超时 | 幂等请求 **多 IP 并发竞速**（默认 4 路 / 单次 4.5 秒），第一个成功者胜出；非幂等请求顺序重试，避免重复提交 |
| 压缩 | 强行给所有请求加 `accept-encoding`，导致不支持解压的客户端（curl 等）收到乱码 | **不再替客户端加**；客户端自己要求压缩就原样透传（浏览器 / Copilot 客户端都自带） |
| 安装顺序 | 先改 hosts，再起代理 | **先起代理并严格验证，再改 hosts**；代理起不来就不动 hosts（不会把网搞断），并尝试恢复 v5 遗留代理 |
| 回滚 | 只删 `CN=Local*` 证书，**删不掉 `CN=github.com`** | 按 install-state 指纹 + 自签 `CN=github.com` + 旧 FriendlyName **全部删除**，并验证删干净 |
| 日志 | 完整 URL 落盘（OAuth `code`/token 可能进日志） | **query string 一律不落盘**；日志 2MB 自动轮转 |
| 运维 | 无 | `-DryRun` 预览、`体检.bat` 自检、`install-state.json` 记录状态 |

---

## 二、原理（以及为什么必须装根证书）

```
浏览器 / Copilot / git
        │  https://github.com  (DNS/hosts 解析到 127.0.0.1)
        ▼
127.0.0.1:443  ── proxy.js：用本工具自签的证书完成 TLS，解密出 HTTP
        │  再用「不带 SNI」的 TLS 连接 GitHub 的真实 IP（140.82.x.x:443）
        ▼
GitHub 边缘节点（按 Host 头返回 github.com 的内容）
```

GFW 对 `github.com` 这个 **SNI** 做针对性阻断，而对「不带 SNI」的连接放行。所以上游连接必须不发 SNI。
不发 SNI 时，上游返回的证书无法按常规方式校验主机名（这也是 v5 干脆 `rejectUnauthorized: false` 的原因），因此链路变成：

- 本机：代理必须能解密 TLS → 需要一张本机受信任的证书（**这就是根证书存在的原因**）
- 上游：v6 仍然做严格校验 —— 实测 GitHub 在无 SNI 时返回的是 `CN=github.com`（SAN 含 `github.com`/`www.github.com`）的合法 Sectigo 证书，链能验到 Node 内置根，主机名校验也通过。校验失败才降级。

> 本质：这是**本机 TLS 中间人**。安全性取决于私钥是否泄露，以及你是否信任这台机器/这个网络。v6 把私钥保护做到了这类工具能做到的较高水平，但它仍然是中间人架构 —— 详见第七节。

---

## 三、文件清单

### Windows

| 文件 | 作用 |
|---|---|
| `快速修复GitHub.bat` / `fix-github.ps1` | 安装：扫描 IP → 建证书 → 写配置 → 装计划任务 → 起代理并验证 → 改 hosts → 端到端验证 |
| `只启动代理.bat` / `start-proxy.ps1` | 代理没起来时快速拉起（不重扫、不改 hosts） |
| `一键回滚.bat` / `uninstall.ps1` | 停代理、删计划任务、**删证书（含 v5 的 `CN=github.com`）**、清 hosts、删文件并验证 |
| `体检.bat` / `doctor.ps1` | 只读体检：Node、安装状态、任务、端口、代理健康度、严格 TLS 探测、证书、hosts、DNS |
| `run-proxy.ps1` | 计划任务调用的启动器：DPAPI 解口令 → 校验 PFX 指纹 → 前台跑 `proxy.js` |
| `proxy.js` | 本地 HTTPS 代理（详见文件头注释） |
| `common.ps1` | 公共库（日志、证书、hosts、计划任务、网络探测） |

### Linux / macOS

| 文件 | 作用 |
|---|---|
| `fix-github.sh` | 安装/修复（对应 `fix-github.ps1`） |
| `start-proxy.sh` | 代理没起来时快速拉起 |
| `uninstall.sh` | 一键回滚：停服务、删系统 CA、清 hosts、删文件并验证 |
| `doctor.sh` | 只读体检 |
| `install-desktop.sh` | 安装桌面启动器（4 个 .desktop：修复/启代理/体检/回滚） |
| `common.sh` | 公共库（对应 `common.ps1`） |

### 跨平台

| 文件 | 作用 |
|---|---|
| `proxy.js` | 本地 HTTPS 代理，两平台共用（Windows 用 PFX，Linux/macOS 用 PEM） |

运行期生成（回滚会删）：`proxy-config.json`、`proxy-cert.pfx`、`proxy-cert.cer`、`proxy-pass.dat`、`install-state.json`、`proxy.log`、`proxy-state.json`、`logs\`。

---

## 四、快速开始

1. 双击 **`快速修复GitHub.bat`**，在 UAC 弹窗点「是」。
2. 等它跑完（首次约 1~5 分钟，取决于扫描和验证）。成功会打印：
   - 代理 `https://127.0.0.1:443` 仅服务 `github.com`
   - 各域名保留的备用 IP
   - 开机自启已启用
   - 四项服务验证通过
3. 浏览器 `Ctrl+Shift+R` 强刷；GitHub Copilot / `gh` / git 客户端**完全退出后重开**。

失败时：
- **hosts 不会被改坏**（安装顺序是先验证后改 hosts）。
- 会自动尝试恢复 v5 遗留代理，GitHub 保持可用。
- 把报错发我，或先跑一次 `体检.bat`。

### Linux / macOS 快速开始

```bash
cd v6
chmod +x *.sh

# 1) 先预览，不做任何修改
sudo ./fix-github.sh --dry-run

# 2) 正式安装
sudo ./fix-github.sh

# 3) 可选：装桌面启动器（4 个图标：修复/启代理/体检/回滚）
./install-desktop.sh
```

其它命令：

```bash
sudo ./fix-github.sh --no-proxy      # 只做 hosts 直连（不装代理）
sudo ./fix-github.sh --ips 8         # 每域名保留 8 个备用 IP
sudo ./fix-github.sh --rounds 0      # 不达标时无限重试
./start-proxy.sh                     # 代理掉了，快速拉起
./doctor.sh                          # 只读体检
sudo ./uninstall.sh                  # 一键回滚
```

依赖（**都会自动处理**）：
- `bash` 4+ / `curl` —— 系统自带
- `openssl` —— 缺了会用包管理器装
- **Node.js** —— 没有会自动装（`apt`/`dnf`/`yum`/`pacman`/`zypper`，失败再下便携版到 `.tools/`）
- **curl 版本**：老版 curl 不支持 `--parallel` 时会自动降级（Windows 版的 `-Z` 兼容问题已修）

> Linux 与 Windows 的差异：
> - 私钥用 **PEM + chmod 600**（对应 Windows 的 DPAPI 加密 PFX）
> - 开机自启用 **systemd 服务**（macOS 用 launchd）
> - 证书装到 `/usr/local/share/ca-certificates/`（RHEL 系用 `/etc/pki/ca-trust/`）
> - hosts 是 `/etc/hosts`

---

## 五、日常使用

- **开机自启**：计划任务 `GitHubAcceleratorV6`，登录后 20 秒启动；代理进程退出会自动重启（最多 5 次）。
- **代理没起来**：双击 `只启动代理.bat`（不需要管理员）。
- **排查问题**：双击 `体检.bat`，会给出链路是否完整。
- **改了网络/DNS/换 IP 段**：重新跑一次 `快速修复GitHub.bat` 即可（会复用证书，只重扫 IP、重写配置和 hosts）。
- **启动图标**：每次执行前会先打印一个猫形 ASCII 图标（64 列）；设置环境变量 `GH_ACCEL_NO_ICON=1` 可关闭（便于自动化解析输出）。

---

## 六、回滚

双击 **`一键回滚.bat`**（需要管理员），它会：

1. 停止代理（含 v5 遗留的 `node proxy.js`）
2. 删除计划任务
3. **删除受信任根里的所有本工具证书** —— 按 `install-state.json` 指纹、自签 `CN=github.com`、旧 FriendlyName 三种方式匹配，并验证删干净（v5 的回滚漏掉了 `CN=github.com`，这里是修好的）
4. 从 hosts 删除 v5/v6 的配置段与残留映射行（保留其他行，如 `127.0.0.1 local.id.seewo.com`）
5. 删除生成的证书/口令/配置/日志
6. 刷新 DNS 并逐项验证

可选参数：

```powershell
# 先看会做什么，不修改系统
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -DryRun

# 同时清掉 v5 目录里遗留的证书/配置（含明文口令 localproxy 的旧文件）
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -CleanLegacy
```

> 回滚后 GitHub 会恢复为「无法直连」的原始状态，这是预期行为。
>
> 说明：Windows 保护「用户级受信任根存储」，若某张证书是**用户级**安装的（不在机器级），任何程序都无法静默删除，回滚会明确列出并提示用 `certmgr.msc` 手动删。本机经检查证书在机器级，可自动清理。

---

## 七、安全设计（威胁模型）

### 做了什么

| 风险 | 处置 |
|---|---|
| 根证书私钥泄露 → 可伪造任意 HTTPS 站点 | 每次安装生成 **40 位随机口令**；口令用 **DPAPI**（绑定当前用户+本机）加密存 `proxy-pass.dat`；PFX 与口令文件 **ACL 去掉继承，仅当前用户与 SYSTEM 可读**；私钥不再留在「个人」证书存储，只存在于加密 PFX；证书有效期从 10 年缩到 **2 年** |
| 代理变成任意域名转发器 | Host **allowlist**，只服务 `github.com`；不认识的 Host 直接 `403`；不再用 DoH 解析任意域名；仍只监听 `127.0.0.1` |
| 上游被中间人替换证书 | 默认 **strict** 校验（链 + 主机名）；失败才降级，并在日志写 `SECURITY 降级`，`体检.bat` 会把它标红 |
| OAuth code/token 进日志 | 日志只记录 path，**query string 一律丢弃**；日志 2MB 轮转 |
| 上游全挂时给客户端错误响应 | 返回 `502` + JSON，不再用 `200` + 纯文本 |
| 回滚删不干净 | 指纹 + 自签 subject + FriendlyName 三重匹配，删除后复查；`-DryRun` 可预览 |
| 计划任务权限过大 | 以当前用户 `RunLevel Limited` 运行，只监听本地端口，不需要管理员常驻 |

### 不能防什么（重要，别误解）

- **这仍然是本机 TLS 中间人**。根证书能签发任意域名证书，私钥一旦泄露，攻击者就能对你伪造任何 HTTPS 站点。请把 `v6` 目录当成敏感目录，不要把 `proxy-cert.pfx` / `proxy-pass.dat` 拷给别人。
- **链路本身**：上游是「无 SNI + 校验证书」的连接，strict 模式能发现证书不对，但发现后会**降级以保证可用**。如果你的威胁模型更严格，把 `proxy-config.json` 的 `allowDegraded` 改成 `false`，代价是证书异常时 GitHub 直接不可用。
- **同一 Windows 用户下的恶意程序**：DPAPI 与 ACL 的边界是「当前用户」，同一用户下的程序仍可能读取（这是本机工具的通用限制）。
- **隐蔽性**：不隐藏你访问 GitHub 的事实，也不提供 VPN 级流量保护。

---

## 八、参数

`fix-github.ps1`

| 参数 | 默认 | 说明 |
|---|---|---|
| `-IpsPerDomain N` | 5 | 每个域名保留的验证通过 IP 数 |
| `-MaxRounds N` | 3 | 验证不通过时最多重试轮数（0 = 无限） |
| `-ListenPort N` | 443 | 代理监听端口（一般不用改） |
| `-NoProxy` | 关 | 只写 hosts 直连，不装代理 |
| `-DryRun` | 关 | 只扫描并打印计划，不改系统 |
| `-Doctor` | 关 | 体检后退出（等同 `体检.bat`） |
| `-CleanLegacy` | 关 | 安装成功后删除 v5 遗留证书/配置 |
| `-ForceCert` | 关 | 强制重新生成证书 |
| `-NoPause` | 关 | 结束不暂停（自动化） |

`start-proxy.ps1`：`-Restart`（先停再起）、`-NoPause`
`uninstall.ps1`：`-DryRun`、`-KeepNode`、`-CleanLegacy`、`-NoPause`
`doctor.ps1`：`-NoPause`

> 环境变量 `GH_ACCEL_NO_ICON=1`：关闭启动图标。

---

## 九、故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `体检.bat` 显示「严格 TLS 探测失败」 | 证书没被系统信任 / 代理没起。重跑 `快速修复GitHub.bat`；仍失败看 `logs\run-proxy.log` |
| 代理健康接口 502 / `upstream_unavailable` | 配置里的 IP 全挂了。重跑安装重新选 IP；`proxy.log` 里会有每个 IP 的失败原因 |
| `upstream_tls_verification_failed` | 上游证书校验失败且未开降级。检查网络是否有中间人，或把 `allowDegraded` 改回 `true` |
| 出现 `SECURITY 降级` | 上游证书没过校验，代理降级放行了。请检查网络环境；`体检.bat` 会标红 |
| 端口 443 被别的程序占用 | `体检.bat` 会显示 PID 和命令行；先停掉那个程序 |
| 计划任务没跑 | 任务只在该用户登录后触发；确认任务状态是 `Ready`、上次结果 `0x0`；手动跑 `只启动代理.bat` |
| Firefox 打不开 | Firefox 用自己的证书库，不读 Windows 根证书。请用 Edge/Chrome，或在 Firefox 里手动导入 `proxy-cert.cer` |
| Copilot 仍然登录失败 | 先跑 `体检.bat` 确认 github.com 严格 TLS 可通；Copilot 的 device flow 依赖 `github.com/login/*` 与 `api.github.com`。完全退出 Copilot（含托盘）再重开 |
| 证书过期 | 2 年有效期，重跑 `快速修复GitHub.bat`（会检测到期并自动换新） |

---

## 十、本机测试记录（含真机安装）

| 测试 | 结果 |
|---|---|
| `node --check proxy.js` | 通过 |
| 多 IP 故障转移（首个 IP 死） | HTTP 200 |
| 非 allowlist Host | HTTP 403 |
| 健康检查接口 | HTTP 200 + JSON |
| 全部上游不可用 | `502` + `{"error":"upstream_unavailable"}`（不再返回 200 纯文本） |
| strict 遇到证书主机名不匹配 | `502` + `upstream_tls_verification_failed`（拒绝） |
| strict 失败 + `allowDegraded` | 降级放行并写 `SECURITY 降级` 日志 |
| 6 个 PowerShell 脚本 5.1 语法解析 | 全部通过 |
| DPAPI 口令往返（40 位随机） | 通过；错误口令读取 PFX 被拒绝 |
| PFX 文件 ACL | 仅 `当前用户` + `SYSTEM` 可读（去继承） |
| 证书安装/导入 API（.NET 方式，无 UI 弹窗） | 通过 |
| 计划任务参数（登录延迟 20s / 失败重启 5×1min / Limited） | 构造与注册/注销均通过（用临时任务名验证） |
| `fix-github.ps1 -DryRun` | exit 0，约 99 秒，正确输出 5 个代理 IP / 5 个 api IP / 5 个 codeload IP 与 hosts 预览，未修改系统 |
| `uninstall.ps1 -DryRun` | exit 0，正确识别 v5 证书（Root+My）与 18 行 hosts 映射，未修改系统 |
| `doctor.ps1` / `start-proxy.ps1` / `run-proxy.ps1` 冒烟 | 通过（未安装时给出正确提示） |

> 真机安装（2026-11-21 15:46 / 15:59）已在管理员权限下执行，结果见下。

### 真机安装结果

| 步骤 | 结果 |
|---|---|
| 移除 v5 证书 | `[Root] 7B92462A… CN=github.com`、`[My] 7B92462A…` 均已删除 |
| 生成 v6 证书 | `8F81BB01A83F9E04B0FD397AFA35286989EC65EA`，有效期至 2028-11-21；Root 中无私钥，私钥只在加密 PFX |
| 计划任务 | `GitHubAcceleratorV6` 注册成功，登录后 20 秒启动，失败重启 5×1min，`Limited/Interactive` |
| 选 IP | 自动剔除 `*.actions.githubusercontent.com` 证书的 IP，最终 5 个 IP 均满足「无 SNI 证书覆盖 github.com 且链有效」 |
| 代理自检 | 严格 TLS `HTTP 200`（证书受系统信任） |
| 端到端 | github.com 200、www 200、api 200、codeload 301 |
| v5 遗留清理 | Desktop 下 `proxy-config.json` / `proxy-cert.pfx` / `proxy-cert.cer` 已删除 |
| 开机自启实测 | `Stop-ScheduledTask` + 杀掉 node 后 `Start-ScheduledTask`，30 秒内恢复健康（PID 变化、v6.1.0） |
| 严格模式 | 连续请求 `degraded=0`，无 `SECURITY` 降级日志 |
| 性能（浏览器式 gzip，10 次） | 10/10 返回 200，平均 **1.98s**，最大 3.65s |
| 设备码登录链路 | `POST /login/device/code` 返回 JSON；表单轮询 `/login/oauth/access_token` 返回 `authorization_pending`；`/login/device` 302 |

> 注：不带压缩的 curl（`--compressed` 之外）下载 168KB 页面会被限速到 8~17 秒，这是链路限速所致，浏览器与 Copilot 客户端都带 gzip，不受影响。

---

## 十一、已知限制

- 代理只服务 `github.com`（`www` / `gist` / `collector` 同域），`api.github.com`、`codeload.github.com`、`raw.githubusercontent.com` 仍是 hosts 直连 IP；这几个域名被 SNI 阻断时本工具管不了。
- 上游 IP 从本机访问并不稳定（GFW 限速/干扰），所以幂等请求用竞速；极端情况下仍可能 2~4 秒起步、偶发十几秒。
- 不支持 WebSocket `Upgrade`（v5 也不支持），GitHub 的实时通知会退化为轮询。
- 大请求（上传）走流式转发，失败不重试（v5 同样），失败会返回 `502`。
- 安装/回滚需要管理员；日常运行不需要。
- 证书 2 年有效，到期需重跑安装。
- 若历史上安装过**用户级**根证书，Windows 不允许程序静默删除，回滚时会列出指纹并要求用 `certmgr.msc` 手动删（机器级证书可自动删）。
