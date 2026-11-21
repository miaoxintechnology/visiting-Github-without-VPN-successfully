# ============================================================
# GitHub 加速器 v6 · 体检
#
# 只读检查，不修改任何系统设置：
#   Node.js / 安装状态 / 计划任务 / 端口监听 / 代理健康度 /
#   严格 TLS 探测 / 证书存储 / hosts / DNS 解析
#
# 用法：双击「体检.bat」，或
#   powershell -ExecutionPolicy Bypass -File doctor.ps1
# ============================================================
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host ''
Write-Host ('=' * 62) -ForegroundColor Cyan
Write-Host ("  GitHub 加速器 v{0} · 体检（只读）" -f $script:DshAccelVersion) -ForegroundColor White
Write-Host ('=' * 62) -ForegroundColor Cyan

Show-Doctor

if (-not $NoPause) { Read-Host '按回车关闭窗口' }
