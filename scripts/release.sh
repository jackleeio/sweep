#!/bin/bash
# 发版：测试、写入版本号、打包 app 和命令行、打标签、推送并创建 GitHub Release。
#   ./scripts/release.sh <x.y.z> <发版说明文件>
# 设置 COMMIT_TRAILER 时会附加到版本号提交的说明末尾。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: ./scripts/release.sh <x.y.z> <发版说明文件>}"
NOTES="${2:?需要一份发版说明文件}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本号格式应为 x.y.z"; exit 1; }
[ -f "$NOTES" ] || { echo "找不到发版说明: $NOTES"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "工作区有未提交的改动，先提交"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION 已存在"; exit 1; fi

swift test

# 写入版本号：显示版本用 x.y.z，构建号用提交数
plutil -replace CFBundleShortVersionString -string "$VERSION" scripts/Info.plist
plutil -replace CFBundleVersion -string "$(( $(git rev-list --count HEAD) + 1 ))" scripts/Info.plist
git commit -q -am "chore: 发布 v$VERSION${COMMIT_TRAILER:+

$COMMIT_TRAILER}"

swift build -c release
OUT="build/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT/Sweep.app/Contents/MacOS"
cp .build/release/SweepApp "$OUT/Sweep.app/Contents/MacOS/Sweep"
cp scripts/Info.plist "$OUT/Sweep.app/Contents/Info.plist"
codesign --force --sign - "$OUT/Sweep.app"
ditto -c -k --keepParent "$OUT/Sweep.app" "$OUT/Sweep-$VERSION-macos-arm64.zip"
cp .build/release/sweep "$OUT/sweep"
(cd "$OUT" && zip -q "sweep-cli-$VERSION-macos-arm64.zip" sweep)

git tag -a "v$VERSION" -m "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" \
    "$OUT/Sweep-$VERSION-macos-arm64.zip" "$OUT/sweep-cli-$VERSION-macos-arm64.zip" \
    --title "v$VERSION" --notes-file "$NOTES"
