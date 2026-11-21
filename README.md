# GitHub 免 VPN 加速器（Windows）

不翻墙访问 GitHub 的本地加速工具，按版本分目录保存。

| 版本 | 目录 | 状态 | 说明 |
|---|---|---|---|
| **v6** | [`v6/`](v6/README.md) | **推荐 / 当前使用** | 多 IP 并发竞速、开机自启（计划任务）、私钥保护（随机口令 + DPAPI + ACL）、上游 TLS 严格校验、完整回滚；`v6/快速修复GitHub.bat` 一键安装 |
| v5 | [`v5/`](v5/README.md) | 旧版 / 保留参考 | 最初的 hosts + SNI 剥离代理方案（Windows + Linux/macOS） |

## 原理（两版一致）

`hosts` 把 `github.com` 指向 `127.0.0.1`，本地 HTTPS 代理终结 TLS 后，用**不带 SNI**的 TLS 连接 GitHub 真实 IP，绕过针对 SNI 的阻断。因此本机需要信任一张工具自签的根证书（详见各版本 README 的安全说明）。

## 快速开始

- **v6（推荐）**：进入 [`v6/`](v6/README.md)，双击 `快速修复GitHub.bat`（需要管理员权限）。
- **v5**：进入 [`v5/`](v5/README.md)，双击 `快速修复GitHub.bat`。

## 许可

MIT，见 [LICENSE](LICENSE)。
