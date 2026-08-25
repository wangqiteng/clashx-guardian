#!/bin/zsh
set -euo pipefail

label="com.local.clashx-guardian"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
status_label="com.local.clashx-guardian-status"
status_plist_path="$HOME/Library/LaunchAgents/$status_label.plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$status_label" 2>/dev/null || true
if [[ -f "$plist_path" ]]; then
  mv "$plist_path" "$HOME/.Trash/$label.plist.$(date +%Y%m%d-%H%M%S)"
fi
if [[ -f "$status_plist_path" ]]; then
  mv "$status_plist_path" "$HOME/.Trash/$status_label.plist.$(date +%Y%m%d-%H%M%S)"
fi

print "已停止并移除 LaunchAgent。"
print "配置和脚本仍保留在：$HOME/Library/Application Support/ClashXGuardian"
print "菜单栏应用仍保留在：$HOME/Applications/ClashX Guardian Status.app"
print "如确认不再需要，可手动移到废纸篓。"
