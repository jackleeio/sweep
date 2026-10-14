#!/bin/bash
# 把编译产物组装成 Sweep.app。安装脚本和发版脚本共用。
#   ./scripts/bundle.sh <编译产物目录> <输出的 Sweep.app 路径>
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:?缺少编译产物目录}"
APP="${2:?缺少输出路径}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/SweepApp" "$APP/Contents/MacOS/Sweep"
# 命令行不能和 app 同放在 MacOS 目录：文件系统不区分大小写，sweep 和 Sweep 会撞名
cp "$BIN/sweep" "$APP/Contents/Helpers/sweep"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/LaunchAgent.plist "$APP/Contents/Library/LaunchAgents/com.jacklee.sweep.daily.plist"
