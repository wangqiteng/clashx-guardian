# ClashX Guardian

一个低资源后台检查器和原生 macOS 菜单栏状态应用。它只在连接到配置的 Wi-Fi、Clash 控制接口可用且系统代理已开启时进行检查。连续 20 秒无法通过本地 Clash 代理访问 Codex 后端时，它会使用与 ClashX“延迟测速”菜单相同的逐节点接口并发测试策略组节点，按本次实时延迟从低到高切换，并再次验证真实连通性。默认最多同时测速 64 个节点，超大策略组会自动分批。

优化版会分别记录 Codex 主探针和公共外网探针的结果。多个可测速节点均无法完成真实连通性验证时，会判断为公共网络或目标站点异常并停止盲目切换。切换失败使用短重试间隔，只有成功切换才进入较长冷却。

默认主探针是 `https://chatgpt.com/backend-api/codex`，这是 Codex 使用 ChatGPT 登录时的后端路径。未带登录信息的探测通常会得到 401/403/404 等响应；这仍能证明 DNS、代理、TLS 和目标前门可达。脚本不会读取或发送 Codex 的令牌、账号信息或任务内容。若 Codex 使用 `OPENAI_API_KEY`，可将 `PRIMARY_URLS` 改为 `https://api.openai.com/v1/responses`。

## 使用前准备

1. 在 ClashX Pro 当前配置中启用仅本机可访问的控制接口：

   ```yaml
   external-controller: 127.0.0.1:9090
   secret: "请换成一段随机长密码"
   ```

   不要将控制接口写成 `0.0.0.0:9090`，否则同一网络中的其他设备可能访问它。

2. 在 ClashX Pro 菜单中开启“设置为系统代理”。如果使用的是增强模式/TUN，可在配置中把 `REQUIRE_SYSTEM_PROXY` 改成 `false`。

3. 确认 ClashX Pro 的代理端口（常见为 `7890`）、控制端口、控制密钥以及想切换的策略组名称。策略组必须是可以手动选择成员的 `Selector`，例如 `Proxy` 或“节点选择”。同时准备好需要保护的 Wi-Fi 名称。

## 安装

在终端进入本文件夹，然后执行：

```zsh
chmod +x install.sh uninstall.sh clashx-guardian.pl
./install.sh
open -e "$HOME/Library/Application Support/ClashXGuardian/config.conf"
```

先将 `TARGET_SSIDS` 改成需要保护的 Wi-Fi，多个名称用英文逗号分隔；再将 `PROXY_GROUP` 改成 ClashX Pro 中实际的 Selector 名称。默认 `CONTROLLER_SECRET=auto`，会直接读取 ClashX Pro 保存的控制密钥，无需复制。如果自动读取失败，再手动填写。如果端口不同，也一并修改。保存后重启检查器：

```zsh
launchctl kickstart -k "gui/$(id -u)/com.local.clashx-guardian"
```

查看状态：

```zsh
tail -f "$HOME/Library/Logs/ClashXGuardian.log"
```

更直观的状态位于 macOS 菜单栏，使用原生彩色状态图标：绿色盾牌勾表示正常、橙色警告表示正在累计失败、蓝色循环表示检测或切换、红色叉表示需要处理、灰色暂停或电源表示当前未启用或自动保护已停止。点击可查看 Wi-Fi、节点、线路诊断、候选测试进度、上次尝试、上次成功切换和最近 3 条事件，也可以立即检测、开启、暂停或重启自动保护。菜单栏应用每次打开时会自动启动尚未运行的 Guardian。

首次启动时 macOS 可能询问是否允许通知。允许后，只有开始切换、恢复成功、切换失败或 ClashX Pro 控制接口不可用时才会通知，不会为每次健康检查弹窗。

## 手动测试（建议先做）

停止后台实例后，在前台运行，便于直接检查配置：

```zsh
launchctl bootout "gui/$(id -u)/com.local.clashx-guardian"
/usr/bin/perl "$HOME/Library/Application Support/ClashXGuardian/clashx-guardian.pl" \
  "$HOME/Library/Application Support/ClashXGuardian/config.conf"
```

按 `Control-C` 停止，再恢复后台运行：

```zsh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.clashx-guardian.plist"
```

## 卸载

```zsh
./uninstall.sh
```

卸载脚本会停止任务并把 LaunchAgent 移到废纸篓，但会保留配置和日志，防止误删密钥或排障信息。

## 资源与安全设计

- Guardian 常驻进程绝大多数时间处于睡眠状态，默认每 5 秒唤醒一次；Codex 未运行时不做网络探测。
- 仅在指定 Wi-Fi、系统代理和 Clash 控制接口均符合条件时发起小流量探测。
- 只有连续失败满 20 秒并再次确认失败才测速；像 ClashX 菜单一样并发测试策略组节点，不在健康状态额外测速。
- 可用节点严格按本次实时延迟从低到高验证，历史可靠性只在延迟完全相同时打破平局。
- 成功切换至少间隔 120 秒；失败尝试默认 30 秒后可重试，不会被错误地当成一次成功切换。
- 菜单栏每 2 秒读取一次不到 1 KiB 的本地状态文件，不发起额外网络请求。
- Codex 后端主探针必须成功，同时要求独立外网探针成功；切换后再做同样的完整复检。
- 配置、日志、节点评分与 LaunchAgent 权限均设为仅当前用户可读；日志超过 512 KiB 自动轮换一次。运行状态不保存控制密钥、Codex 令牌或浏览内容。

## 常见问题

- 日志显示 `cannot read current SSID`：新版 macOS 可能要求定位权限才能读取 Wi-Fi 名称。到“系统设置 → 隐私与安全性 → 定位服务”中允许终端（手动测试时）或相关后台进程访问；不同 macOS 版本的显示方式可能不同。
- 日志显示 `controller is unavailable`：检查 ClashX Pro 是否运行、`external-controller` 端口和 `CONTROLLER_SECRET` 是否一致。
- 日志显示策略组不可选：`PROXY_GROUP` 必须精确匹配 ClashX Pro 中的 Selector 名称，大小写也要一致。
- 使用 SOCKS 端口时，将 `PROXY_URL` 写成 `socks5h://127.0.0.1:端口`，并把 `REQUIRE_SYSTEM_PROXY=false`；系统代理检测只适用于 HTTP 代理。
- 如果希望 Codex 未运行时也保护其他 OpenAI API 程序，将 `REQUIRE_CODEX_RUNNING` 改成 `false`。
- 默认最多同时产生 64 个短时本地测速任务；节点更多时自动分批，只在故障确认后运行，常驻空闲 CPU 不受影响。可通过 `MAX_BENCHMARK_CONCURRENCY` 调整上限，实际切换次数仍受 `MAX_SWITCH_ATTEMPTS` 限制。

## 边界

脚本能在 Clash 核心和至少一个订阅节点仍可用时自动恢复。若 Wi-Fi 本身断开、DNS/认证门户阻断全部流量、ClashX Pro 崩溃、控制接口未启用，或订阅中的所有节点均失效，脚本无法自行修复，只会写入日志。
