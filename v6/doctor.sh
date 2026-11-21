#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · 体检（Linux / macOS，只读）
#
# 不做任何修改，只报告链路是否完整。
# 用法：./doctor.sh          （普通用户即可）
#       sudo ./doctor.sh     （会额外检查系统 CA / hosts 可读性）
# ============================================================
set -uo pipefail

V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export V6_DIR
# shellcheck source=/dev/null
. "$V6_DIR/common.sh"

NO_PAUSE=0
[ "${1:-}" = '--no-pause' ] && NO_PAUSE=1

exec bash "$V6_DIR/fix-github.sh" --doctor ${NO_PAUSE:+--no-pause}
