# 托盘菜单界面回归

显式运行 `dotnet run --project Windows/Guardian.UITests/Guardian.UITests.csproj -c Release -- --run-ui`。测试会短暂显示自己的测试窗口和菜单，验证实际额度渲染器的单行布局、失去焦点关闭、重新打开与 Esc 关闭；不启动 VPN、不切换节点、不读账号。普通回归不会运行本项目。
