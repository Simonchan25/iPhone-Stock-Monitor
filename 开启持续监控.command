#!/bin/zsh
set -euo pipefail
monitor_dir="${0:A:h}"
monitor_archive="$monitor_dir/dist/iPhone库存监控.zip"
if [[ ! -f "$monitor_archive" ]]; then
    echo '请先运行 ./scripts/build.sh 构建程序。' >&2
    exit 1
fi
monitor_stage="$(mktemp -d "${TMPDIR:-/tmp}/iphone-stock-install.XXXXXX")"
trap '/bin/rm -rf "$monitor_stage"' EXIT
/usr/bin/ditto -x -k "$monitor_archive" "$monitor_stage"
monitor_source="$monitor_stage/iPhone库存监控.app"
/usr/bin/codesign --verify --strict "$monitor_source"
monitor_runtime="$HOME/Library/Application Support/iPhoneDuoStockMonitor/iPhone库存监控.app"
monitor_bin="$monitor_runtime/Contents/MacOS/iPhoneStockMonitor"
monitor_label="com.local.iphoneduostock"
monitor_plist="$HOME/Library/LaunchAgents/$monitor_label.plist"
mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/plutil -lint "$monitor_source/Contents/Info.plist" >/dev/null
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/$monitor_label" 2>/dev/null || true
/usr/bin/killall -u "$(/usr/bin/id -un)" iPhoneStockMonitor 2>/dev/null || true
/usr/bin/ditto --norsrc "$monitor_source" "$monitor_runtime"
/usr/bin/xattr -cr "$monitor_runtime"
/usr/bin/codesign --force --sign - "$monitor_runtime"
/usr/bin/codesign --verify --strict "$monitor_runtime"
cat > "$monitor_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$monitor_label</string>
<key>ProgramArguments</key><array><string>$monitor_bin</string><string>--background</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key><string>Interactive</string>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ThrottleInterval</key><integer>30</integer>
</dict></plist>
PLIST
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$monitor_plist"
echo '已启动并设置登录后自动运行。请在菜单栏 Duo 中查看真实查询状态。'
echo '正常状态应显示最近成功时间；若出现查询故障，则该时刻库存未知。'
