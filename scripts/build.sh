#!/bin/zsh
set -euo pipefail
monitor_root="${0:A:h:h}"
monitor_stage="$(mktemp -d "${TMPDIR:-/tmp}/iphone-stock-build.XXXXXX")"
trap '/bin/rm -rf "$monitor_stage"' EXIT
monitor_app="$monitor_stage/iPhone库存监控.app"
mkdir -p "$monitor_stage/Sources" "$monitor_app/Contents/MacOS" "$monitor_root/dist"
# Compile a stable snapshot, including when the checkout is in an iCloud folder.
cp "$monitor_root"/Sources/*.swift "$monitor_stage/Sources/"
cp "$monitor_root/Resources/Info.plist" "$monitor_app/Contents/Info.plist"
MACOSX_DEPLOYMENT_TARGET=13.0 /usr/bin/xcrun swiftc -O \
    "$monitor_stage/Sources/StockCore.swift" \
    "$monitor_stage/Sources/BarkPush.swift" \
    "$monitor_stage/Sources/QuerySchedule.swift" \
    "$monitor_stage/Sources/main.swift" \
    -framework AppKit -o "$monitor_app/Contents/MacOS/iPhoneStockMonitor"
# Sign outside FileProvider/iCloud; export a ZIP to avoid regenerated FinderInfo.
/usr/bin/codesign --force --sign - "$monitor_app"
/usr/bin/codesign --verify --strict "$monitor_app"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$monitor_app" "$monitor_root/dist/iPhone库存监控.zip"
echo "构建完成：$monitor_root/dist/iPhone库存监控.zip"
