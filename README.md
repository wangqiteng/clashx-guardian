# ClashX Guardian

Windows 首版位于 [`Windows/`](Windows/README.md)：提供 iKuuu 官方客户端的网络检测、托盘控制和只读兼容性诊断；**官方 Windows UI 自动测速/切换尚未适配**。可选支持本机 Clash/Mihomo Controller 模式，不影响下述 macOS 版本。

ClashX Guardian 是一个面向 macOS、ClashX Pro 与 iKuuuVPN 的轻量网络守护工具，目标是在 Codex 工作期间检测 OpenAI 线路故障，并自动切换到真实可用的代理节点。

## 主要能力

2.5.4 的 Mac 菜单栏在盾牌内部显示 Codex 剩余额度数字（省略百分号），保持单图标宽度；微拱盾牌保留鲜明状态底色，实心粗体数字按底色选择高对比度黑白文字。盾牌颜色仍代表网络状态，数字取 Codex 有效额度窗口中的最低剩余比例；菜单显示各窗口和本地时区的重置时间，可手动刷新或隐藏数字。后台每 3 分钟读取一次，超时/未知/过期显示 `--`，不会伪装成 0%。

额度来自已安装并登录的 Codex CLI 的只读 `account/rateLimits/read`（[官方协议](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)）。没有模型调用，不消耗模型 token，不读取、复制或记录登录密钥。GUI 使用 CLI 的当前账号，可能与另行登录的桌面账号不同；API-key-only 或不提供额度窗口的账号可能无法显示。需要本机 Codex CLI，支持标准 App 路径和 Homebrew/npm 常见安装位置。数字显示设置保存在当前用户偏好中；隐藏数字不影响菜单明细和网络守护。

2.4.3 在 2.4.2 的 iKuuu 适配基础上默认排除台湾、台北节点，避免影响 Codex 连通性；自定义 `EXCLUDE_PATTERN` 仍会被保留，并修复升级脚本的规则迁移。

2.4.1 修复了 iKuuu 停在主页时被误判为不兼容的问题：日常检查可读取主页当前节点，恢复操作会通过辅助功能进入服务器页后测速。同时修复中文 Wi-Fi 名称乱码、重复节点标签和相似节点名误匹配。iKuuu 主窗口需保持可供辅助功能读取；关闭窗口或权限失效时会暂停自动切换。

- 开启后在任意网络上持续探测，不再依赖 Wi-Fi 名称或 Codex 进程状态；每轮之间保持睡眠。
- 自动识别已经运行的 ClashX Pro 或 iKuuuVPN；不会主动启动代理软件，同时运行时优先 ClashX Pro。
- 普通安装无需填写代理端口、Controller 地址、密钥或策略组；现有显式配置保留为高级覆盖项。
- 分别检测 Codex 后端和公共外网，识别 OpenAI 单站异常、当前节点故障与疑似公共故障。
- 故障确认后使用与 ClashX“延迟测速”菜单相同的逐节点接口，并发测试策略组节点；默认并发上限 64，当前常见订阅可一次完成。
- iKuuuVPN 通过 macOS 辅助功能读取其公开的界面控件，触发测速并选择低延迟节点；不移动鼠标、不读取订阅，也不调用私有接口。
- 严格按本次实时延迟从低到高尝试；日常健康状态不会触发全量测速。
- 区分切换尝试和成功切换；失败后快速重试，成功后使用较长冷却。
- 菜单栏使用居中的彩色对称盾牌表示线路状态；启动台图标保留“盾牌 + Wi-Fi”品牌图形。菜单可查看线路原因、切换进度、最近事件，并提供开启、暂停、重启以及“停止自动保护并退出”。
- 菜单栏启动 Guardian 时识别 launchd 的启动中状态，只发出一次非破坏性启动请求并等待最多 120 秒，避免反复点击导致进程一直被重启。
- Guardian 与菜单栏启动错误写入持久诊断日志，便于定位偶发的 launchd 启动失败。

## 项目结构

- `outputs/clashx-guardian/clashx-guardian.pl`：后台守护进程。
- `Sources/ClashXGuardianStatus/main.m`：原生 AppKit 菜单栏应用。
- `Sources/GuardianStartPolicy.*`：launchd 状态识别与安全启动策略。
- `Tests/GuardianStartPolicyTests.m`：启动策略回归测试。
- `script/build_and_run.sh`：构建、运行和验证入口。
- `script/package_release.sh`：生成不含本机配置、密钥、日志和节点历史的分享包。
- `outputs/clashx-guardian/README.md`：完整安装和配置说明。

## 开发与验证

```bash
./script/build_and_run.sh --build
/usr/bin/perl outputs/clashx-guardian/clashx-guardian.pl \
  outputs/clashx-guardian/config.conf.example --self-test
./script/build_and_run.sh --verify
```

在 ClashX Pro 控制器可用的电脑上，还可以只测速、不切换节点，验证并发逻辑：

```bash
/usr/bin/perl outputs/clashx-guardian/clashx-guardian.pl \
  "$HOME/Library/Application Support/ClashXGuardian/config.conf" --delay-self-test
```

生成分享包：

```bash
./script/package_release.sh
```

## 安装

构建分享包后，解压进入 `clashx-guardian` 目录，先阅读其中的 `README.md`，再执行：

```bash
./install.sh
```

安装后会自动识别当前系统代理、ClashX Controller 与策略组，无需编辑配置。iKuuuVPN 用户首次使用时只需按菜单提示授予一次“辅助功能”权限。ClashX 控制接口必须仅监听 `127.0.0.1`，不要暴露到局域网。
