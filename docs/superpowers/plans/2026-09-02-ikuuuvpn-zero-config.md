# ClashX Guardian v2.4.0 零配置双客户端实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Guardian 自动识别已运行的 ClashX Pro 或 iKuuuVPN，并在无需普通用户编辑配置的情况下完成网络监测、测速和节点切换。

**Architecture:** Perl Guardian 保留网络状态机和 ClashX Controller 适配器，原生菜单栏应用新增 iKuuuVPN `AXUIElement` 适配器。两者通过 Application Support 目录中的原子 JSON 请求/响应文件通信；Guardian 负责真实 Codex 连通性验证，菜单栏应用只负责有权限边界的 iKuuu 界面操作。

**Tech Stack:** macOS 13+、Objective-C/AppKit/ApplicationServices、Perl 5 系统模块、launchd、clang、shell 测试与 ZIP 发布脚本。

**Spec:** `docs/superpowers/specs/2026-09-02-ikuuuvpn-zero-config-design.md`

## Global Constraints

- 不主动启动 ClashX Pro 或 iKuuuVPN。
- 两者同时运行时优先 ClashX Pro。
- iKuuuVPN 不读取订阅、不修改配置、不调用私有网络接口。
- iKuuu 操作不移动鼠标、不发送键盘事件、不依赖绝对屏幕坐标。
- 常驻检查保持 5 秒睡眠间隔，菜单栏本地轮询保持 2 秒，不增加健康状态下的全量测速。
- 所有日志和发布包不得包含控制密钥、订阅 URL、账号或本机运行状态文件。
- 普通安装路径不要求编辑配置；现有显式配置继续作为高级覆盖项。

---

### Task 1: iKuuu 节点模型与解析器

**Files:**
- Create: `Sources/IKuuuNodeParser.h`
- Create: `Sources/IKuuuNodeParser.m`
- Create: `Tests/IKuuuNodeParserTests.m`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Consumes: iKuuu 辅助功能按钮的字符串描述，例如 `🇭🇰 香港Y03 | IEPL\n45 ms` 或 `🇭🇰 香港Y01\n超时`。
- Produces: `IKuuuNodeResult`，属性为 `name: NSString *`、`delayMilliseconds: NSInteger`；函数 `NSArray<IKuuuNodeResult *> *IKuuuParseNodeLabels(NSArray<NSString *> *labels)` 和 `NSArray<IKuuuNodeResult *> *IKuuuRankNodes(NSArray<IKuuuNodeResult *> *nodes, NSRegularExpression *exclude)`。

- [ ] **Step 1: 写失败测试**

```objc
NSArray *nodes = IKuuuParseNodeLabels(@[
    @"🇭🇰 香港Y03 | IEPL\n45 ms",
    @"🇯🇵 日本Y01 | IEPL\n135 ms",
    @"🇭🇰 香港Y01\n超时",
    @"🔰 选择节点"
]);
NSCAssert(nodes.count == 2, @"只保留明确毫秒结果");
NSCAssert([nodes[0].name isEqualToString:@"🇭🇰 香港Y03 | IEPL"], @"保留完整节点名");
NSCAssert(IKuuuRankNodes(nodes, nil)[0].delayMilliseconds == 45, @"按实时延迟排序");
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation Tests/IKuuuNodeParserTests.m Sources/IKuuuNodeParser.m -o /private/tmp/IKuuuNodeParserTests && /private/tmp/IKuuuNodeParserTests`

Expected: FAIL，因为解析器文件和符号尚不存在。

- [ ] **Step 3: 实现最小解析器**

```objc
@interface IKuuuNodeResult : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) NSInteger delayMilliseconds;
- (instancetype)initWithName:(NSString *)name delayMilliseconds:(NSInteger)delay;
@end

NSArray<IKuuuNodeResult *> *IKuuuParseNodeLabels(NSArray<NSString *> *labels);
NSArray<IKuuuNodeResult *> *IKuuuRankNodes(NSArray<IKuuuNodeResult *> *nodes,
                                          NSRegularExpression *exclude);
```

解析必须使用行尾正则 `(?:^|\\n)([1-9][0-9]{0,4})\\s*ms\\s*$`，名称取匹配前去除空白后的文本；包含“超时”、没有延迟、延迟为 0 或超过 99999 的条目全部丢弃。排序先比较实时延迟，再按节点名做稳定排序。

- [ ] **Step 4: 运行测试并确认通过**

Run: `./script/build_and_run.sh --build`

Expected: 新解析器测试及现有启动策略、状态应用自测全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/IKuuuNodeParser.h Sources/IKuuuNodeParser.m Tests/IKuuuNodeParserTests.m script/build_and_run.sh
git commit -m "feat: parse iKuuu node latency results"
```

### Task 2: iKuuu 辅助功能适配器

**Files:**
- Create: `Sources/IKuuuAccessibilityAdapter.h`
- Create: `Sources/IKuuuAccessibilityAdapter.m`
- Create: `Tests/IKuuuAccessibilityAdapterTests.m`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Consumes: `IKuuuNodeParser`、bundle identifier `org.ikuuu.vpn`、macOS `AXUIElement`。
- Produces: `IKuuuAccessibilityState` 枚举；`-requestAccessibilityPermission`、`-inspectWithError:`、`-benchmarkWithTimeout:error:`、`-selectNodeNamed:error:` 和 `-currentNodeWithError:`。

- [ ] **Step 1: 写可注入辅助功能树的失败测试**

```objc
IKuuuAXSnapshot *snapshot = [[IKuuuAXSnapshot alloc] initWithStrings:@[
    @"服务器", @"🔰 选择节点", @"🇭🇰 香港Y03 | IEPL\n45 ms", @"🇯🇵 日本Y01 | IEPL\n135 ms"
]];
NSError *error = nil;
NSArray *nodes = IKuuuNodesFromSnapshot(snapshot, &error);
NSCAssert(error == nil && nodes.count == 2, @"合法结构可解析");
NSCAssert(IKuuuNodesFromSnapshot([[IKuuuAXSnapshot alloc] initWithStrings:@[@"主页"]], &error) == nil,
          @"缺少服务器语义时安全失败");
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `./script/build_and_run.sh --build`

Expected: FAIL，缺少适配器类型和实现。

- [ ] **Step 3: 实现适配器和安全选择器**

```objc
typedef NS_ENUM(NSInteger, IKuuuAccessibilityState) {
    IKuuuAccessibilityStateClientNotRunning,
    IKuuuAccessibilityStatePermissionRequired,
    IKuuuAccessibilityStateReady,
    IKuuuAccessibilityStateIncompatible
};

@interface IKuuuAccessibilityAdapter : NSObject
- (IKuuuAccessibilityState)state;
- (void)requestAccessibilityPermission;
- (NSArray<IKuuuNodeResult *> * _Nullable)benchmarkWithTimeout:(NSTimeInterval)timeout
                                                          error:(NSError **)error;
- (BOOL)selectNodeNamed:(NSString *)name error:(NSError **)error;
- (NSString * _Nullable)currentNodeWithError:(NSError **)error;
@end
```

使用 `NSRunningApplication runningApplicationsWithBundleIdentifier:` 查找进程，找不到时绝不调用 `launchApplicationAtURL:`。遍历 AX 树时只读取 `AXRole`、`AXTitle`、`AXValue`、`AXDescription`、`AXChildren` 和 `AXFrame`；必须同时找到“服务器”“选择节点”和至少两个可解析节点。刷新按钮通过按钮角色、服务器内容容器和搜索按钮右侧的相对布局识别；候选不唯一时返回 `Incompatible`。所有动作只执行 `AXUIElementPerformAction(element, kAXPressAction)`。

- [ ] **Step 4: 增加超时和选择确认测试**

```objc
NSCAssert(IKuuuWaitForStableSamples(@[@[@45, @135], @[@45, @135]], 2), @"连续两次相同才稳定");
NSCAssert(!IKuuuWaitForStableSamples(@[@[@45], @[@57]], 2), @"变化中不可切换");
NSCAssert(IKuuuSelectionMatches(@"🇭🇰 香港Y03", @"🇭🇰 香港Y03 | IEPL"), @"顶部短名允许前缀确认");
```

- [ ] **Step 5: 构建并确认全部测试通过**

Run: `./script/build_and_run.sh --build`

Expected: 所有 Objective-C 测试 PASS，应用通过严格警告构建和签名校验。

- [ ] **Step 6: 提交**

```bash
git add Sources/IKuuuAccessibilityAdapter.h Sources/IKuuuAccessibilityAdapter.m Tests/IKuuuAccessibilityAdapterTests.m script/build_and_run.sh
git commit -m "feat: add safe iKuuu accessibility adapter"
```

### Task 3: 原子 JSON 请求协议与菜单栏协调器

**Files:**
- Create: `Sources/IKuuuRequestCoordinator.h`
- Create: `Sources/IKuuuRequestCoordinator.m`
- Create: `Tests/IKuuuRequestCoordinatorTests.m`
- Modify: `Sources/ClashXGuardianStatus/main.m`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Consumes: `IKuuuAccessibilityAdapter`；请求文件 `ikuuu-request.json`。
- Produces: 响应文件 `ikuuu-response.json`；菜单状态 `clientName`、`switchCapability`、`currentNode`。

- [ ] **Step 1: 写协议校验失败测试**

```objc
NSDictionary *valid = @{ @"id": @"request-1", @"operation": @"benchmark", @"expiresAt": @4102444800 };
NSCAssert(IKuuuValidateRequest(valid, 1) == nil, @"合法请求通过");
NSCAssert(IKuuuValidateRequest(@{ @"operation": @"select" }, 1) != nil, @"缺少 id 必须拒绝");
NSCAssert(IKuuuValidateRequest(@{ @"id": @"x", @"operation": @"unknown", @"expiresAt": @4102444800 }, 1) != nil,
          @"未知操作必须拒绝");
```

- [ ] **Step 2: 运行构建并确认失败**

Run: `./script/build_and_run.sh --build`

Expected: FAIL，协调器符号不存在。

- [ ] **Step 3: 实现协议与协调器**

```objc
@interface IKuuuRequestCoordinator : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory adapter:(IKuuuAccessibilityAdapter *)adapter;
- (void)pollOnce;
@property(nonatomic, copy, readonly) NSString *capabilityLabel;
@end
```

请求操作只允许 `inspect`、`benchmark`、`select`、`restore`。协调器每 2 秒由现有菜单定时器调用一次；验证 UUID/非空 ID、未过期时间和单任务锁。响应统一为 `{id, success, code, message, currentNode, candidates}`，使用 `NSDataWritingAtomic` 写入固定响应文件。处理后删除匹配请求；同一 ID 只处理一次。日志只写错误代码，不写原始 AX 树。

- [ ] **Step 4: 接入菜单与授权操作**

在 `GuardianAppDelegate` 增加：

```objc
@property(nonatomic, strong) IKuuuRequestCoordinator *ikuuuCoordinator;
@property(nonatomic, strong) NSMenuItem *clientItem, *capabilityItem, *ikuuuPermissionItem;
- (void)authorizeIKuuu:(id)sender;
```

状态菜单显示当前客户端和自动切换能力。`authorizeIKuuu:` 先展示 Guardian 自有说明弹窗，再调用 `AXIsProcessTrustedWithOptions` 的系统提示；用户点“稍后”时写入 `NSUserDefaults` 标记，自动提示不再重复，但菜单操作始终保留。

- [ ] **Step 5: 运行测试并确认通过**

Run: `./script/build_and_run.sh --build`

Expected: 协议测试、解析器测试、启动策略和状态应用自测全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/IKuuuRequestCoordinator.h Sources/IKuuuRequestCoordinator.m Tests/IKuuuRequestCoordinatorTests.m Sources/ClashXGuardianStatus/main.m script/build_and_run.sh
git commit -m "feat: coordinate iKuuu switching from status app"
```

### Task 4: Guardian 自动发现与双客户端状态机

**Files:**
- Modify: `outputs/clashx-guardian/clashx-guardian.pl`
- Modify: `outputs/clashx-guardian/config.conf.example`

**Interfaces:**
- Consumes: macOS `scutil --proxy`、ClashX Controller、iKuuu 请求/响应协议。
- Produces: `activeClient`、`switchCapability` 状态字段；`detect_active_client()`、`resolve_proxy_url()`、`resolve_clash_group()`、`ikuuu_request()`。

- [ ] **Step 1: 扩展 Perl 自测并确认失败**

```perl
die "self-test failed: ClashX must win\n"
    unless choose_client(clash_ready => 1, ikuuu_running => 1) eq 'clashx';
die "self-test failed: iKuuu fallback\n"
    unless choose_client(clash_ready => 0, ikuuu_running => 1) eq 'ikuuu';
die "self-test failed: no client must wait\n"
    unless choose_client(clash_ready => 0, ikuuu_running => 0) eq 'none';
die "self-test failed: system proxy auto discovery\n"
    unless proxy_url_from_scutil("HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 7891\n") eq
           'http://127.0.0.1:7891';
```

- [ ] **Step 2: 运行自测并确认失败**

Run: `/usr/bin/perl outputs/clashx-guardian/clashx-guardian.pl outputs/clashx-guardian/config.conf.example --self-test`

Expected: FAIL，自动发现函数不存在或默认 auto 值尚不支持。

- [ ] **Step 3: 实现自动发现**

```perl
sub choose_client {
    my %state = @_;
    return 'clashx' if $state{clash_ready};
    return 'ikuuu' if $state{ikuuu_running};
    return 'none';
}

sub process_running {
    my ($name) = @_;
    my (undef, $status) = run_capture('/usr/bin/pgrep', '-x', $name);
    return $status == 0;
}
```

`PROXY_URL=auto` 时解析 `scutil --proxy` 中启用的 HTTP/HTTPS loopback 代理；只接受 `127.0.0.1` 或 `localhost`。`CONTROLLER_URL=auto` 先读取 ClashX Pro 偏好中的 Controller 端口，再尝试 loopback `9090`。`PROXY_GROUP=auto` 从 `/proxies` 中选择 `type=Selector` 且 `all` 至少两个成员的组，依次偏好 `GLOBAL` 当前引用的组、名称匹配 `Proxy|PROXY|节点选择|代理` 的组、唯一剩余组；歧义时返回不可自动切换而不猜测。

- [ ] **Step 4: 实现 iKuuu 请求客户端**

```perl
sub ikuuu_request {
    my ($operation, $payload, $timeout) = @_;
    my $id = sprintf('%d-%d-%06d', time, $$, int(rand(1_000_000)));
    # 原子写请求，轮询匹配响应；超时后只删除属于本请求的文件。
    return wait_for_ikuuu_response($id, $timeout);
}
```

iKuuu 切换流程依次请求 `benchmark`、对最低延迟候选请求 `select`、调用现有 `diagnose_connectivity()`；失败继续下一个，全部失败请求 `restore`。菜单栏应用未运行、未授权或结构不兼容时只记录有界错误并继续监测。

- [ ] **Step 5: 扩展状态 JSON**

`write_status` 增加：

```perl
activeClient     => $active_client,
switchCapability => $switch_capability,
clientRunning    => $active_client ne 'none' ? JSON::PP::true : JSON::PP::false,
```

`none` 状态不累计网络失败；iKuuu 未授权状态继续探测，但达到阈值时不发出切换请求。

- [ ] **Step 6: 运行全部离线验证**

Run: `/usr/bin/perl outputs/clashx-guardian/clashx-guardian.pl outputs/clashx-guardian/config.conf.example --self-test && ./script/build_and_run.sh --build`

Expected: Perl 自测和全部原生测试 PASS。

- [ ] **Step 7: 提交**

```bash
git add outputs/clashx-guardian/clashx-guardian.pl outputs/clashx-guardian/config.conf.example
git commit -m "feat: auto-detect ClashX and iKuuuVPN"
```

### Task 5: 零配置安装、菜单文案与升级迁移

**Files:**
- Modify: `outputs/clashx-guardian/install.sh`
- Modify: `Sources/ClashXGuardianStatus/main.m`
- Modify: `script/build_and_run.sh`
- Modify: `Tests/fixtures/healthy-status.json`
- Modify: `Tests/fixtures/switching-status.json`

**Interfaces:**
- Consumes: Task 4 状态字段。
- Produces: 新安装零配置默认值、旧配置安全迁移、v2.4.0 菜单展示。

- [ ] **Step 1: 更新状态夹具并让旧 UI 自测失败**

```json
{
  "activeClient": "ikuuu",
  "switchCapability": "ready",
  "clientRunning": true
}
```

Run: `./script/build_and_run.sh --build`

Expected: FAIL，因为自测尚未断言客户端和能力文案。

- [ ] **Step 2: 完成菜单展示和通知文案**

```objc
self.clientItem.title = [NSString stringWithFormat:@"当前客户端：%@", ClientDisplayName(status[@"activeClient"])];
self.capabilityItem.title = [NSString stringWithFormat:@"自动切换：%@", CapabilityDisplayName(status[@"switchCapability"])];
```

通知中使用当前客户端名称，不再硬编码“ClashX 节点”。未运行代理客户端时灰色盾牌；等待授权时黄色盾牌；结构不兼容时红色盾牌但不阻塞“立即检测”。

- [ ] **Step 3: 实现配置迁移**

新安装的示例配置写入四个 `auto` 值。升级时只把仍等于历史默认值的 `PROXY_URL=http://127.0.0.1:7890`、`CONTROLLER_URL=http://127.0.0.1:9090`、`PROXY_GROUP=Proxy` 迁移为 `auto`；任何用户自定义值保持原样。新增 `PROXY_CLIENT=auto` 时使用 `grep -q` 后追加，不产生重复键。

- [ ] **Step 4: 更新版本号与构建号**

在 `script/build_and_run.sh` 设置：

```xml
<key>CFBundleShortVersionString</key><string>2.4.0</string>
<key>CFBundleVersion</key><string>8</string>
```

- [ ] **Step 5: 运行构建与安装脚本静态验证**

Run: `zsh -n outputs/clashx-guardian/install.sh && ./script/build_and_run.sh --build`

Expected: shell 语法、所有测试、应用签名和图标校验 PASS。

- [ ] **Step 6: 提交**

```bash
git add outputs/clashx-guardian/install.sh Sources/ClashXGuardianStatus/main.m script/build_and_run.sh Tests/fixtures
git commit -m "feat: deliver zero-config dual-client setup"
```

### Task 6: 文档、发布包与真实环境验证

**Files:**
- Modify: `README.md`
- Modify: `outputs/clashx-guardian/README.md`
- Modify: `script/package_release.sh`
- Modify: `.gitignore` only if the v2.4.0 archive pattern is not already covered.

**Interfaces:**
- Consumes: 完成的 v2.4.0 功能。
- Produces: 可分享 ZIP、SHA-256、当前电脑安装和 GitHub 提交。

- [ ] **Step 1: 更新用户文档**

根 README 和分享包 README 必须明确：解压后执行 `./install.sh` 即可；Guardian 不启动代理客户端；同时运行时优先 ClashX；iKuuu 首次需要辅助功能授权；高级配置可选；临时签名升级可能要求重新授权。

- [ ] **Step 2: 更新发布脚本包含新增源码和测试**

```bash
install -m 0644 "$ROOT_DIR/Sources/IKuuuNodeParser.h" "$RELEASE_DIR/Source/IKuuuNodeParser.h"
install -m 0644 "$ROOT_DIR/Sources/IKuuuAccessibilityAdapter.m" "$RELEASE_DIR/Source/IKuuuAccessibilityAdapter.m"
install -m 0644 "$ROOT_DIR/Sources/IKuuuRequestCoordinator.m" "$RELEASE_DIR/Source/IKuuuRequestCoordinator.m"
```

同时复制对应头文件和三份测试，默认版本改为 `2.4.0`。

- [ ] **Step 3: 运行完整离线验证**

Run: `./script/build_and_run.sh --build && /usr/bin/perl outputs/clashx-guardian/clashx-guardian.pl outputs/clashx-guardian/config.conf.example --self-test && ./script/package_release.sh 2.4.0`

Expected: 生成 `outputs/ClashX-Guardian-v2.4.0-macOS.zip` 和 `.sha256`，ZIP 隐私扫描通过。

- [ ] **Step 4: 运行 iKuuu 只读验证**

Run: 菜单栏应用的 `--ikuuu-self-test` 模式，只读取辅助功能树并输出 `client=ikuuu nodes=<N> current=<redacted-or-name> action=none`。

Expected: `N >= 2`，不触发刷新、不切换节点、不激活窗口。

- [ ] **Step 5: 进行一次受控真实切换并恢复**

记录当前节点；通过菜单“立即测速并恢复”执行一次 iKuuu 测速，选择最低延迟候选，验证 Codex 与公共外网；测试结束无论成功失败都恢复记录的原节点。检查日志中不存在账号、订阅 URL 或密钥。

- [ ] **Step 6: 安装并验证 launchd**

Run: `cd outputs/clashx-guardian && ./install.sh`

Expected: `~/Applications/ClashX Guardian Status.app` 的版本为 2.4.0；两个 LaunchAgent 均为 running；状态 JSON 包含 `activeClient` 和 `switchCapability`。

- [ ] **Step 7: 最终回归和工作树检查**

Run: `./script/build_and_run.sh --verify && git diff --check && git status --short`

Expected: 应用正在运行、无空白错误；只剩预期的源码、文档和发布产物变化。

- [ ] **Step 8: 提交并推送**

```bash
git add README.md outputs/clashx-guardian/README.md script/package_release.sh Sources Tests outputs/clashx-guardian
git commit -m "feat: support zero-config iKuuuVPN recovery"
git push origin main
```

Expected: GitHub `main` 包含 v2.4.0，当前电脑安装包与提交源码一致。
