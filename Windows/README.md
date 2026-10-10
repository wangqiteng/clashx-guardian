# iKuuu Guardian for Windows — 0.1.0-preview

这是首个 Windows **检测预览版**，与现有 macOS 版本相互独立。目标客户端是 iKuuu 官方 Windows 客户端。

**重要边界：尚未取得官方 Windows 客户端的具体版本和控件样本，未实现/验证官方界面的自动测速、节点切换。它目前不能替代 macOS 完整自动恢复功能。** 不会猜测坐标、移动鼠标、读取订阅、修改客户端配置或启动客户端。若所用版本确实开放了本机 Clash/Mihomo Controller，可通过可选配置启用接口模式的测速与恢复；这不是在声称官方客户端必然支持该接口。

## 使用

1. 将 `IKuuu-Guardian-v0.1.0-preview-win-x64.zip` **完整解压**到任意普通用户目录。
2. 自行启动 iKuuu 并连接，双击 `IKuuuGuardian.exe`。无需安装 .NET、Python、管理员权限或后台服务。
3. 右下角系统托盘会出现彩色对称盾牌；若被系统折叠，请查看隐藏图标。双击盾牌查看状态。
4. 托盘菜单支持开启、暂停、立即检测、可选测速恢复、兼容性诊断、日志、退出。
5. 选择“停止检测并退出”会取消检测，必要时先尝试回退本次切换，再结束主进程。不添加开机自启；再次打开程序会开始检测。

目前提供 x64 包（Windows 10/11 x64，具体 .NET 10 支持范围以微软文档为准）。ARM64 可按下文构建对应包。本程序尚未经过真实 Windows/iKuuu 环境验收；在 Mac 上交叉编译并不等于 Windows 实机验证。程序未购买 Windows 代码签名证书，可能被 SmartScreen 提示发布者未知；请仅运行你信任的来源，不要全局关闭系统保护。

### 状态含义

- 绿色：OpenAI 和至少一个外网探针可达；“仅检测”仍表示自动切换未启用。
- 黄色：失败确认中、测速中或配置/兼容性需要处理。
- 红色：持续失败，或恢复尝试失败。
- 灰色：已暂停，或未识别到 iKuuu 进程。

默认每轮完成后等待 5 秒；网络探针并发执行，每个最多 6 秒，仅读取响应头。连续失败至少 20 秒后额外确认，再进入恢复；**20 秒不是保证恢复耗时**。休眠超过 45 秒或代理路径变化会重置失败累计。平时不会测速全部节点。

探测 URL：`https://chatgpt.com/backend-api/codex`，以及 `https://www.gstatic.com/generate_204` / `https://www.cloudflare.com/cdn-cgi/trace`。没有使用你的登录令牌或发送聊天内容。OpenAI 的 2xx/401/404/405 仅表示匿名 HTTP 入口可达；403/429/5xx 不显示为正常。公共探针只接受 2xx。**无法由这些探针保证 Codex 登录、账户地域支持或流式请求一直正常。**

程序识别进程名 `ikuuu`、`ikuuuvpn`、`ikuuu vpn`（不区分大小写）；若官方新版改名，可能显示等待客户端，请提供版本和实际进程名。检测读取当前用户的 Windows 系统代理，支持回环 HTTP/SOCKS5；未设置代理时走系统路由，可能是 TUN，也可能是直连，界面会明确说明。首版不支持 PAC，不会替你改系统代理。

## 可选 Controller 模式

仅在客户端确实支持本机 Clash/Mihomo 接口时使用。托盘 →“配置自动切换”：填写/确认回环地址及可选密钥，点击验证，选择实际承载 Codex 流量的手动策略组，勾选确认框保存。不能推断路由归属，程序不会自动选一个模糊的组。

- 地址限制为回环 IP，不跟随重定向，不经系统代理访问 Controller。
- 密钥使用当前 Windows 用户 DPAPI 加密，不写进 JSON、日志或分享包。
- 使用 `GET /proxies/{name}/delay`，最多并发 16 个，单节点核心测速超时 2500 ms。不能保证所有订阅在 3 秒内结束。
- 只尝试指定组的直接叶子节点，跳过嵌套策略组、特殊路由和台湾/台北/Taiwan/Taipei/TW/🇹🇼 节点。
- 按本次延迟升序，最多尝试 3 个，切换后验证实际组选择和双类探针；成功冷却 120 秒，失败重试间隔至少 30 秒。
- 检测到用户/客户端手动修改组选择或系统代理路径变化时停止操作；回退不会覆盖已观察到的手动选择。Controller 没有原子比较并切换功能，仍存在极短并发竞争窗口。
- 暂停/退出取消操作后最多给回退 8 秒；若原节点属于排除地区，不自动切回台湾，保留最后候选并记录警告。

API 依据：[Mihomo 官方 API 文档](https://wiki.metacubex.one/api/)。这不是 iKuuu 官方接口承诺。

## 帮助完成官方客户端适配

打开 iKuuu 节点列表 → 托盘“导出 iKuuu 兼容性诊断” → 确认只读访问。

`%LOCALAPPDATA%\IKuuuGuardian\compatibility.json` 记录客户端版本、有限导航/测速标签、控件类型和支持的 UI Automation 模式。其他文本脱敏；不导出账户、订阅、密钥或完整节点名称，不自动上传。读取在独立子进程进行，15 秒未完成即终止诊断子进程，不会卡死托盘。若返回空控件，可能需要展开窗口、权限级别不同，或客户端没有暴露控件。

请先检查该文件，再将其连同客户端版本号、节点列表截图提供给开发者。截图可能包含账户/订阅信息，请遮盖后分享。只有拿到真实控件样本并做安全校验后，才能继续实现官方 UI 的测速/切换。

UIA 依据：[Microsoft UI Automation control patterns](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-controlpatternsoverview)。本版诊断不调用任何 Invoke/Select 控件操作。

## 日志、配置与卸载

托盘“打开日志目录”：`%LOCALAPPDATA%\IKuuuGuardian`，含 `guardian.log`、最多一份滚动备份、`settings.json`、可选加密密钥及诊断文件。日志可能含你选用的节点名称，请检查后再分享。配置修改后重启生效。

退出后删除解压目录即可卸载；如需清除历史，可另行删除上述**专用数据目录**。没有服务、计划任务或启动项需要卸载。

## 开发和打包

安装 .NET 10 SDK（仅开发者需要），在仓库根目录运行：

```sh
dotnet run --project Windows/Guardian.Tests/Guardian.Tests.csproj
dotnet publish Windows/Guardian.Windows/Guardian.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist/windows/win-x64
```

macOS/Linux 可使用 `bash script/package_windows.sh`，通过 `DOTNET=/path/to/dotnet` 指定 SDK；传入 `win-arm64` 构建 ARM64。Windows PowerShell 使用 `./Windows/package.ps1`。发布不执行 trimming，避免破坏 WinForms/UIA。编译采用微软支持的 [EnableWindowsTargeting](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100) 和 [self-contained single-file publishing](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)。

首个发布前的实机验收：

- 冷启动可见托盘、重复启动无重复进程；未运行 iKuuu 时不替用户启动它。
- 已连接时可探测；断开代理、403/429、睡眠恢复、切换系统代理不会显示虚假的健康状态。
- 暂停、退出、重新打开的状态符合预期，退出后无守护残留。
- 诊断输出仅含允许的信息，界面卡住时诊断可超时结束。
- 可选 Controller 模式：确认策略组、测速排序、排除台湾、切换复检、失败回退、手动改节点和取消中断。

本版本代码独立放在 `Windows/`，不会重建、安装或改变现有 macOS 程序及其辅助功能授权。
