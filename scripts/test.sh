#!/bin/zsh
set -euo pipefail
monitor_root="${0:A:h:h}"
monitor_stage="$(mktemp -d "${TMPDIR:-/tmp}/iphone-stock-test.XXXXXX")"
trap '/bin/rm -rf "$monitor_stage"' EXIT
/usr/bin/ditto -x -k "$monitor_root/dist/iPhone库存监控.zip" "$monitor_stage"
monitor_app="$monitor_stage/iPhone库存监控.app"
/usr/bin/plutil -lint "$monitor_app/Contents/Info.plist"
/usr/bin/codesign --verify --strict "$monitor_app"
"$monitor_app/Contents/MacOS/iPhoneStockMonitor" --self-test
