# Windows 自动恢复实机验收

此项目不属于普通回归检查。它调用真实 iKuuu 控件并实际切换节点，需要手动添加 `--run-live` 才会运行。

运行前停止已安装 Guardian；连接 iKuuu 0.17.5，打开服务器页面并最小化；保持桌面解锁。测试期间不要手动改节点或系统代理。

```powershell
dotnet run --project Windows/Guardian.IntegrationTests/Guardian.IntegrationTests.csproj -c Release -- --run-live
```

测试在本进程内注入 503 响应模拟持续故障，不改系统代理或 VPN 配置；使用真实托盘定时器、默认失败确认窗口、官方测速和节点选择。第一次真实选择成功后恢复真实 HTTP 传输，要求通过真实 OpenAI API 和公共网络复检。所有子操作必须保持客户端最小化。验收结束时仅在当前选择仍归本次测试所有时恢复原节点。

每次运行有 160 秒观察期限。测试会写入正常日志及最近事件，含“503”的模拟故障只代表本次测试注入。普通 53 项回归检查不运行本测试。
