#!/bin/bash
# 构建并安装 Sweep：菜单栏 app、命令行工具、每日定时任务。可重复执行，用于升级。
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.jacklee.sweep.daily
APP=/Applications/Sweep.app
CLI="$HOME/.local/bin/sweep"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Sweep"
DOMAIN="gui/$(id -u)"

swift build -c release
BIN=$(swift build -c release --show-bin-path)

# 菜单栏 app：SwiftPM 只产出可执行文件，这里组装成 .app（本机自用，临时签名即可）
STAGE=build/Sweep.app
./scripts/bundle.sh "$BIN" "$STAGE"
codesign --force --sign - "$STAGE/Contents/Helpers/sweep"
codesign --force --sign - "$STAGE"

pkill -x Sweep 2>/dev/null || true
rm -rf "$APP"
cp -R "$STAGE" "$APP"

# 命令行工具
mkdir -p "$(dirname "$CLI")"
install -m 755 "$BIN/sweep" "$CLI"

# 每日定时任务。配置没变且已注册就不重新加载：定时任务调用的是上面装好的命令行，
# 下次运行自然用上新版本；先卸载再注册失败的话（比如在受限的沙箱里），定时清理会一直停到下次登录
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
NEW_PLIST=$(mktemp)
sed -e "s|__CLI__|$CLI|g" -e "s|__LOG_DIR__|$LOG_DIR|g" scripts/launchd.plist > "$NEW_PLIST"
if cmp -s "$NEW_PLIST" "$PLIST" && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    rm -f "$NEW_PLIST"
else
    mv "$NEW_PLIST" "$PLIST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
        echo "⚠️  定时任务没能注册，定时清理会停到下次登录。请在自己的终端里执行："
        echo "    launchctl bootstrap $DOMAIN $PLIST"
    fi
fi

open "$APP"

echo "已安装："
echo "  $APP"
echo "  $CLI"
echo "  $PLIST"
