#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
install_dir="$HOME/Library/Application Support/ClashXGuardian"
launch_agents_dir="$HOME/Library/LaunchAgents"
plist_path="$launch_agents_dir/com.local.clashx-guardian.plist"
label="com.local.clashx-guardian"
status_label="com.local.clashx-guardian-status"
status_plist_path="$launch_agents_dir/$status_label.plist"
status_source="$source_dir/ClashX Guardian Status.app"
applications_dir="$HOME/Applications"
status_app="$applications_dir/ClashX Guardian Status.app"
status_binary="$status_app/Contents/MacOS/ClashXGuardianStatus"
logs_dir="$HOME/Library/Logs"
guardian_log="$logs_dir/ClashXGuardian.log"
diagnostic_log="$logs_dir/ClashXGuardianDiagnostic.log"

bootstrap_with_retry() {
  local domain=$1
  local plist=$2
  local attempt
  for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  print -u2 "无法加载 LaunchAgent：$plist"
  return 1
}

mkdir -p "$install_dir" "$launch_agents_dir" "$logs_dir"
touch "$guardian_log" "$diagnostic_log"
chmod 0600 "$guardian_log" "$diagnostic_log"
install -m 0755 "$source_dir/clashx-guardian.pl" "$install_dir/clashx-guardian.pl"

if [[ ! -f "$install_dir/config.conf" ]]; then
  install -m 0600 "$source_dir/config.conf.example" "$install_dir/config.conf"
  print "已创建配置：$install_dir/config.conf"
else
  print "保留现有配置：$install_dir/config.conf"
fi

# 仅迁移旧版默认值；用户主动设置的其他数值不会被覆盖。
sed -i '' 's/^CHECK_INTERVAL=10$/CHECK_INTERVAL=5/' "$install_dir/config.conf"
sed -i '' 's/^FAILURE_SECONDS=30$/FAILURE_SECONDS=20/' "$install_dir/config.conf"
sed -i '' 's|^PROXY_URL=http://127.0.0.1:7890$|PROXY_URL=auto|' "$install_dir/config.conf"
sed -i '' 's|^CONTROLLER_URL=http://127.0.0.1:9090$|CONTROLLER_URL=auto|' "$install_dir/config.conf"
sed -i '' 's/^PROXY_GROUP=Proxy$/PROXY_GROUP=auto/' "$install_dir/config.conf"
# 新版在任意网络上工作，清理已不再生效的旧门控配置。
sed -i '' '/^TARGET_SSIDS=/d' "$install_dir/config.conf"
sed -i '' '/^REQUIRE_CODEX_RUNNING=/d' "$install_dir/config.conf"
grep -q '^STATUS_FILE=' "$install_dir/config.conf" || print 'STATUS_FILE=~/Library/Application Support/ClashXGuardian/status.json' >> "$install_dir/config.conf"
grep -q '^TRIGGER_FILE=' "$install_dir/config.conf" || print 'TRIGGER_FILE=~/Library/Application Support/ClashXGuardian/check-now' >> "$install_dir/config.conf"
grep -q '^RUNTIME_STATE_FILE=' "$install_dir/config.conf" || print 'RUNTIME_STATE_FILE=~/Library/Application Support/ClashXGuardian/runtime-state.json' >> "$install_dir/config.conf"
grep -q '^FAILED_RETRY_COOLDOWN=' "$install_dir/config.conf" || print 'FAILED_RETRY_COOLDOWN=30' >> "$install_dir/config.conf"
grep -q '^CONFIRMATION_DELAY=' "$install_dir/config.conf" || print 'CONFIRMATION_DELAY=3' >> "$install_dir/config.conf"
grep -q '^MAX_PARALLEL_TESTS=' "$install_dir/config.conf" || print 'MAX_PARALLEL_TESTS=3' >> "$install_dir/config.conf"
grep -q '^COMMON_FAILURE_LIMIT=' "$install_dir/config.conf" || print 'COMMON_FAILURE_LIMIT=2' >> "$install_dir/config.conf"
grep -q '^PROXY_CLIENT=' "$install_dir/config.conf" || print 'PROXY_CLIENT=auto' >> "$install_dir/config.conf"

escaped_program=${install_dir//&/&amp;}
escaped_program=${escaped_program//</&lt;}
escaped_program=${escaped_program//>/&gt;}
escaped_diagnostic_log=${diagnostic_log//&/&amp;}
escaped_diagnostic_log=${escaped_diagnostic_log//</&lt;}
escaped_diagnostic_log=${escaped_diagnostic_log//>/&gt;}

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/perl</string>
    <string>$escaped_program/clashx-guardian.pl</string>
    <string>$escaped_program/config.conf</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$escaped_diagnostic_log</string>
  <key>StandardErrorPath</key>
  <string>$escaped_diagnostic_log</string>
</dict>
</plist>
PLIST

chmod 0600 "$plist_path"
plutil -lint "$plist_path"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
bootstrap_with_retry "gui/$(id -u)" "$plist_path"

if [[ -d "$status_source" ]]; then
  mkdir -p "$applications_dir"
  pkill -x ClashXGuardianStatus 2>/dev/null || true
  ditto "$status_source" "$status_app"
  xattr -cr "$status_app"
  codesign --force --deep --sign - "$status_app" >/dev/null
  codesign --verify --deep --strict "$status_app"

  escaped_status_binary=${status_binary//&/&amp;}
  escaped_status_binary=${escaped_status_binary//</&lt;}
  escaped_status_binary=${escaped_status_binary//>/&gt;}
  cat > "$status_plist_path" <<STATUS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$status_label</string>
  <key>ProgramArguments</key><array><string>$escaped_status_binary</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$escaped_diagnostic_log</string>
  <key>StandardErrorPath</key><string>$escaped_diagnostic_log</string>
</dict></plist>
STATUS_PLIST
  chmod 0600 "$status_plist_path"
  plutil -lint "$status_plist_path"
  launchctl bootout "gui/$(id -u)/$status_label" 2>/dev/null || true
  bootstrap_with_retry "gui/$(id -u)" "$status_plist_path"
fi

print "安装完成。Guardian 会自动识别已运行的 ClashX Pro 或 iKuuuVPN。"
print "无需编辑配置；高级选项位于：$install_dir/config.conf"
print "运行日志：$guardian_log"
print "启动诊断：$diagnostic_log"
print "菜单栏：彩色网络状态图标"
