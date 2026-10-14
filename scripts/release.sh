#!/bin/bash
# 发版：测试 → 写入版本号 → 编译通用二进制（Apple 芯片 + Intel）→ Developer ID 签名
#   → Apple 公证 app 并钉入票据 → 打 DMG → 签名并公证 DMG → 打标签、推送、创建 GitHub Release。
#
#   ./scripts/release.sh <x.y.z> <发版说明文件>
#
# 需要：钥匙串里的 Developer ID Application 证书，以及 notarytool 的钥匙串配置（默认名 sweep-notary）：
#   xcrun notarytool store-credentials sweep-notary --apple-id <Apple ID> --team-id <团队号> --password <App 专用密码>
# 可用 SWEEP_SIGNING_IDENTITY、SWEEP_NOTARY_PROFILE 覆盖默认值；设置 COMMIT_TRAILER 时会附加到版本号提交的说明末尾。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: ./scripts/release.sh <x.y.z> <发版说明文件>}"
NOTES="${2:?需要一份发版说明文件}"
IDENTITY="${SWEEP_SIGNING_IDENTITY:-Developer ID Application: JIWEI LI (7XHZ9ZRCBQ)}"
PROFILE="${SWEEP_NOTARY_PROFILE:-sweep-notary}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本号格式应为 x.y.z"; exit 1; }
[ -f "$NOTES" ] || { echo "找不到发版说明: $NOTES"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "工作区有未提交的改动，先提交"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION 已存在"; exit 1; fi
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || { echo "钥匙串里找不到证书: $IDENTITY"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "公证凭据 $PROFILE 不可用，见脚本开头的说明"; exit 1; }

# 提交给 Apple 公证并等待结果；没通过就打印日志并中止
notarize() {
    local file="$1" out id
    out=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait 2>&1) || true
    echo "$out" | grep -E "id:|status:" | head -3
    if ! echo "$out" | grep -q "status: Accepted"; then
        id=$(echo "$out" | awk '/^ *id:/{print $2; exit}')
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        echo "公证没有通过: $file"
        exit 1
    fi
}

swift test

# 写入版本号：显示版本用 x.y.z，构建号用提交数
plutil -replace CFBundleShortVersionString -string "$VERSION" scripts/Info.plist
plutil -replace CFBundleVersion -string "$(( $(git rev-list --count HEAD) + 1 ))" scripts/Info.plist
git commit -q -am "chore: 发布 v$VERSION${COMMIT_TRAILER:+

$COMMIT_TRAILER}"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
OUT="build/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
./scripts/bundle.sh "$BIN" "$OUT/Sweep.app"

# 签名：先签内层的命令行，再签 app。公证要求启用 hardened runtime 并带时间戳。
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/Sweep.app/Contents/Helpers/sweep"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/Sweep.app"
codesign --verify --deep --strict "$OUT/Sweep.app"

# 公证 app，把票据钉进去：用户把 app 拖出 DMG 后离线也能通过检查
ditto -c -k --keepParent "$OUT/Sweep.app" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple "$OUT/Sweep.app"

# DMG：里面放 app 和一个指向「应用程序」的快捷方式，拖过去即可安装
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$OUT/Sweep.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Sweep-$VERSION.dmg"
hdiutil create -volname "Sweep $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 用 Gatekeeper 的标准检查确认：下载下来能直接打开
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess -vv "$OUT/Sweep.app"

git tag -a "v$VERSION" -m "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" "$DMG" --title "v$VERSION" --notes-file "$NOTES"
