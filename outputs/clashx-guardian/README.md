# ClashX Guardian

一个低资源后台检查器和原生 macOS 菜单栏状态应用。它自动识别已经运行的 ClashX Pro 或 iKuuuVPN，不会主动启动代理软件；两者同时运行时优先 ClashX Pro。连续 20 秒无法访问 Codex 后端时，Guardian 会测速、按实时延迟选择候选节点，并再次验证真实连通性。

ClashX Pro 使用本机 Controller；iKuuuVPN 使用 macOS 辅助功能读取节点名称与延迟并直接触发控件，不移动鼠标、不输入文字、不读取账号或订阅，也不修改 iKuuu 配置。

优化版会分别记录 Codex 主探针和公共外网探针的结果。多个可测速节点均无法完成真实连通性验证时，会判断为公共网络或目标站点异常并停止盲目切换。切换失败使用短重试间隔，只有成功切换才进入较长冷却。

默认主探针是 `https://chatgpt.com/backend-api/codex`，这是 Codex 使用 ChatGPT 登录时的后端路径。未带登录信息的探测通常会得到 401/403/404 等响应；这仍能证明 DNS、代理、TLS 和目标前门可达。脚本不会读取或发送 Codex 的令牌、账号信息或任务内容。若 Codex 使用 `OPENAI_API_KEY`，可将 `PRIMARY_URLS` 改为 `https://api.openai.com/v1/responses`。

## 安装

解压后在终端进入本文件夹，执行：

```zsh
chmod +x install.sh
./install.sh
```

安装完成后无需编辑配置。Guardian 会自动读取 macOS 当前回环系统代理，并识别 ClashX Controller、密钥和可选策略组。高级设置仍位于：

```zsh
open -e "$HOME/Library/Application Support/ClashXGuardian/config.conf"
```

Guardian 只管理已经运行的代理软件。如果 ClashX Pro 和 iKuuuVPN 都没有运行，菜单会显示“未检测到”，不会代替用户启动它们。

### iKuuuVPN 首次授权

当 iKuuuVPN 正在运行且 ClashX Pro 未运行时，Guardian 会提示授予 macOS“辅助功能”权限。点击“继续授权”，在“系统设置 → 隐私与安全性 → 辅助功能”中开启 `ClashX Guardian Status` 即可。用户选择稍后时不会反复弹窗，菜单中保留授权入口。

分享包使用临时签名，升级应用后 macOS 可能要求重新开启该权限。使用 Developer ID 正式签名可以改善权限延续，但不影响本版本功能。

### ClashX Controller 安全

Guardian 会自动读取 ClashX Pro 已保存的本地 Controller 设置。如果 Controller 被关闭，菜单会显示不可用。控制接口只能监听 `127.0.0.1`，不要使用 `0.0.0.0` 暴露到局域网。

查看状态：

```zsh
tail -f "$HOME/Library/Logs/ClashXGuardian.log"
```

若点击“开启”后迟迟没有运行，可从菜单选择“打开诊断日志”，或在终端查看：

```zsh
tail -f "$HOME/Library/Logs/ClashXGuardianDiagnostic.log"
```

诊断日志会保留菜单栏执行的 `launchctl` 命令、退出码和错误信息，也会接收两个 LaunchAgent 的标准错误输出；超过 512 KiB 时自动轮换并保留一份 `.previous`。

更直观的状态位于 macOS 菜单栏，使用完整、居中、左右对称的盾牌图标：绿色表示正常、橙色表示正在累计失败、蓝色表示检测或切换、红色表示需要处理、灰色表示当前未启用或自动保护已停止。点击可查看 Wi-Fi、节点、线路诊断、候选测试进度、上次尝试、上次成功切换和最近 3 条事件，也可以立即检测、开启、暂停或重启自动保护。选择“退出 ClashX Guardian”会先停止后台自动保护，确认成功后再退出菜单栏。菜单栏应用每次打开时会自动启动尚未运行的 Guardian；启动期间会显示进度并暂时禁用重复操作，最多等待 120 秒，不会因连续点击反复杀掉正在启动的进程。

首次启动时 macOS 可能询问是否允许通知。允许后，只有开始切换、恢复成功、切换失败或当前代理客户端无法自动切换时才会通知，不会为每次健康检查弹窗。

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

- Guardian 常驻进程绝大多数时间处于睡眠状态，默认每 5 秒唤醒一次。
- 开启后不限制 Wi-Fi 名称或 Codex 进程状态；检测到受支持的客户端和回环系统代理后发起小流量探测。
- 只有连续失败满 20 秒并再次确认失败才测速；ClashX 使用 Controller 并发测速，iKuuu 使用其测速界面，不在健康状态额外测速。
- 可用节点严格按本次实时延迟从低到高验证，历史可靠性只在延迟完全相同时打破平局。
- 成功切换至少间隔 120 秒；失败尝试默认 30 秒后可重试，不会被错误地当成一次成功切换。
- 菜单栏每 2 秒读取一次不到 1 KiB 的本地状态文件，不发起额外网络请求。
- Codex 后端主探针必须成功，同时要求独立外网探针成功；切换后再做同样的完整复检。
- 配置、日志、节点评分与 LaunchAgent 权限均设为仅当前用户可读；日志超过 512 KiB 自动轮换一次。运行状态不保存控制密钥、Codex 令牌或浏览内容。

## 常见问题

- 菜单栏无法显示 Wi-Fi 名称：新版 macOS 可能要求定位权限；这只影响名称展示，不会暂停线路检测。
- 日志显示 `controller is unavailable`：检查 ClashX Pro 是否运行、`external-controller` 端口和 `CONTROLLER_SECRET` 是否一致。
- 日志显示策略组无法识别：自动模式只在能唯一、安全识别 Selector 时切换；可在高级配置中显式填写 `PROXY_GROUP`。
- iKuuu 显示“等待辅助功能授权”：从 Guardian 菜单选择“授权 iKuuu 自动保护”，在系统设置中开启对应权限。
- iKuuu 显示“当前版本无法安全识别”：Guardian 会继续监测但不会猜测点击，请升级兼容版本。
- 使用 SOCKS 端口时，将 `PROXY_URL` 写成 `socks5h://127.0.0.1:端口`，并把 `REQUIRE_SYSTEM_PROXY=false`；系统代理检测只适用于 HTTP 代理。
- 默认最多同时产生 64 个短时本地测速任务；节点更多时自动分批，只在故障确认后运行，常驻空闲 CPU 不受影响。可通过 `MAX_BENCHMARK_CONCURRENCY` 调整上限，实际切换次数仍受 `MAX_SWITCH_ATTEMPTS` 限制。

## 边界

脚本能在当前代理客户端和至少一个订阅节点仍可用时自动恢复。若 Wi-Fi 本身断开、DNS/认证门户阻断全部流量、代理客户端崩溃、ClashX Controller 不可用、iKuuu 辅助功能结构不兼容，或订阅中的所有节点均失效，脚本无法自行修复，只会显示状态并写入日志。
