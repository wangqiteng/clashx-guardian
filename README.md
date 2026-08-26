# ClashX Guardian

ClashX Guardian 是一个面向 macOS + ClashX Pro 的轻量网络守护工具，目标是在 Codex 工作期间检测 OpenAI 线路故障，并自动切换到真实可用的代理节点。

## 主要能力

- 仅在指定 Wi-Fi、Codex 正在运行且系统代理开启时探测，空闲时保持睡眠。
- 分别检测 Codex 后端和公共外网，识别 OpenAI 单站异常、当前节点故障与疑似公共故障。
- 故障确认后使用与 ClashX“延迟测速”菜单相同的逐节点接口，并发测试策略组节点；默认并发上限 64，当前常见订阅可一次完成。
- 严格按本次实时延迟从低到高尝试；日常健康状态不会触发全量测速。
- 区分切换尝试和成功切换；失败后快速重试，成功后使用较长冷却。
- 菜单栏使用居中的彩色对称盾牌表示线路状态；启动台图标保留“盾牌 + Wi-Fi”品牌图形。菜单可查看线路原因、切换进度、最近事件，并提供开启、暂停和重启。

## 项目结构

- `outputs/clashx-guardian/clashx-guardian.pl`：后台守护进程。
- `Sources/ClashXGuardianStatus/main.m`：原生 AppKit 菜单栏应用。
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

在已配置 ClashX Pro 控制器的电脑上，还可以只测速、不切换节点，验证并发逻辑：

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

默认配置使用占位 Wi-Fi 名称和 `Proxy` 策略组，安装后必须按实际环境编辑配置。控制接口必须仅监听 `127.0.0.1`，不要暴露到局域网。
