#!/bin/zsh
set -euo pipefail
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/com.local.iphoneduostock" 2>/dev/null || true
/usr/bin/killall -u "$(/usr/bin/id -un)" iPhoneStockMonitor 2>/dev/null || true
monitor_plist="$HOME/Library/LaunchAgents/com.local.iphoneduostock.plist"
if [[ -f "$monitor_plist" ]]; then
    /bin/mv -f "$monitor_plist" "$monitor_plist.disabled"
fi
echo '已停止库存监控，并停用登录后自动运行。再次运行“开启持续监控.command”可恢复。'
