#!/bin/bash
# 卸载 Sweep 的 app、命令行和定时任务。配置、标记名单和日志保留，需要的话手动删除：
#   ~/Library/Application Support/Sweep  ~/Library/Logs/Sweep
set -uo pipefail

LABEL=com.jacklee.sweep.daily

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x Sweep 2>/dev/null
rm -rf /Applications/Sweep.app
rm -f "$HOME/.local/bin/sweep"

echo "已卸载。「登录项」里如果还有 Sweep，可在 系统设置 › 通用 › 登录项 中移除。"
