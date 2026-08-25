#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>
#import <errno.h>
#import <signal.h>

static NSString *const GuardianBundleID = @"com.local.ClashXGuardianStatus";

typedef NS_ENUM(NSInteger, GuardianAppearance) {
    GuardianAppearanceHealthy, GuardianAppearanceWarning, GuardianAppearanceWorking,
    GuardianAppearanceError, GuardianAppearanceInactive, GuardianAppearanceStopped,
};

static GuardianAppearance BaseAppearance(NSString *state, NSString *level) {
    if ([state isEqualToString:@"healthy"]) return GuardianAppearanceHealthy;
    if ([state isEqualToString:@"unhealthy"] || [state isEqualToString:@"cooldown"]) return GuardianAppearanceWarning;
    if ([state isEqualToString:@"switching"] || [state isEqualToString:@"starting"] ||
        [state isEqualToString:@"confirming"]) return GuardianAppearanceWorking;
    if ([state isEqualToString:@"switch_failed"] || [state isEqualToString:@"controller_off"] ||
        [state isEqualToString:@"no_wifi_device"] || [state isEqualToString:@"ssid_unavailable"]) return GuardianAppearanceError;
    if ([state isEqualToString:@"codex_off"] || [state isEqualToString:@"inactive_ssid"] ||
        [state isEqualToString:@"system_proxy_off"]) return GuardianAppearanceInactive;
    if ([state isEqualToString:@"stopped"]) return GuardianAppearanceStopped;
    return [level isEqualToString:@"error"] ? GuardianAppearanceError : GuardianAppearanceInactive;
}

static NSDictionary *ReadStatus(NSURL *url, NSError **error) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:GuardianBundleID code:1 userInfo:@{NSLocalizedDescriptionKey: @"状态文件不是 JSON 对象"}];
        return nil;
    }
    NSDictionary *status = object;
    for (NSString *key in @[@"state", @"level", @"timestamp", @"failureSeconds"]) {
        if (!status[key]) {
            if (error) *error = [NSError errorWithDomain:GuardianBundleID code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"状态缺少字段：%@", key]}];
            return nil;
        }
    }
    return status;
}

static NSColor *AppearanceColor(GuardianAppearance value) {
    switch (value) {
        case GuardianAppearanceHealthy: return NSColor.systemGreenColor;
        case GuardianAppearanceWarning: return NSColor.systemOrangeColor;
        case GuardianAppearanceWorking: return NSColor.systemBlueColor;
        case GuardianAppearanceError: return NSColor.systemRedColor;
        case GuardianAppearanceInactive: return NSColor.secondaryLabelColor;
        case GuardianAppearanceStopped: return NSColor.systemGrayColor;
    }
}

static NSString *AppearanceLabel(GuardianAppearance value) {
    switch (value) {
        case GuardianAppearanceHealthy: return @"网络正常";
        case GuardianAppearanceWarning: return @"线路异常";
        case GuardianAppearanceWorking: return @"正在检测";
        case GuardianAppearanceError: return @"需要处理";
        case GuardianAppearanceInactive: return @"当前未启用";
        case GuardianAppearanceStopped: return @"Guardian 未运行";
    }
}

static NSString *AppearanceSymbol(GuardianAppearance value) {
    switch (value) {
        case GuardianAppearanceHealthy: return @"checkmark.shield.fill";
        case GuardianAppearanceWarning: return @"exclamationmark.triangle.fill";
        case GuardianAppearanceWorking: return @"arrow.triangle.2.circlepath.circle.fill";
        case GuardianAppearanceError: return @"xmark.octagon.fill";
        case GuardianAppearanceInactive: return @"pause.circle.fill";
        case GuardianAppearanceStopped: return @"power.circle.fill";
    }
}

@interface GuardianAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *previousState;
@property(nonatomic, strong) NSURL *baseDirectory, *statusURL, *triggerURL, *configURL, *logURL;
@property(nonatomic, strong) NSMenuItem *summaryItem, *ssidItem, *nodeItem, *diagnosisItem, *checkedItem, *thresholdItem;
@property(nonatomic, strong) NSMenuItem *attemptedItem, *switchedItem, *eventsHeaderItem;
@property(nonatomic, strong) NSArray<NSMenuItem *> *eventItems;
@property(nonatomic, strong) NSMenuItem *startItem, *stopItem, *restartItem;
@property(nonatomic) BOOL guardianRunning;
@end

@implementation GuardianAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSURL *home = NSFileManager.defaultManager.homeDirectoryForCurrentUser;
    self.baseDirectory = [home URLByAppendingPathComponent:@"Library/Application Support/ClashXGuardian" isDirectory:YES];
    self.statusURL = [self.baseDirectory URLByAppendingPathComponent:@"status.json"];
    self.triggerURL = [self.baseDirectory URLByAppendingPathComponent:@"check-now"];
    self.configURL = [self.baseDirectory URLByAppendingPathComponent:@"config.conf"];
    self.logURL = [home URLByAppendingPathComponent:@"Library/Logs/ClashXGuardian.log"];
    [self configureMenu];
    [self refreshStatus];
    [self ensureGuardianRunning:NO];
    [self requestNotificationPermission];
    self.timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    os_log_info(OS_LOG_DEFAULT, "ClashX Guardian status app started");
}

- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self.timer invalidate]; }
- (void)menuWillOpen:(NSMenu *)menu { (void)menu; [self refreshStatus]; }

- (NSMenuItem *)infoItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)actionItem:(NSString *)title selector:(SEL)selector key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    item.target = self;
    return item;
}

- (void)configureMenu {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menu = [[NSMenu alloc] initWithTitle:@"ClashX Guardian"];
    self.menu.delegate = self;
    self.summaryItem = [self infoItem:@"正在读取状态…"];
    self.ssidItem = [self infoItem:@"Wi-Fi：—"];
    self.nodeItem = [self infoItem:@"节点：—"];
    self.diagnosisItem = [self infoItem:@"线路：—"];
    self.checkedItem = [self infoItem:@"上次检测：—"];
    self.thresholdItem = [self infoItem:@"切换阈值：—"];
    self.attemptedItem = [self infoItem:@"上次尝试：—"];
    self.switchedItem = [self infoItem:@"成功切换：—"];
    for (NSMenuItem *item in @[self.summaryItem, self.ssidItem, self.nodeItem, self.diagnosisItem,
                               self.checkedItem, self.thresholdItem, self.attemptedItem, self.switchedItem]) [self.menu addItem:item];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self actionItem:@"立即检测" selector:@selector(checkNow:) key:@"r"]];
    self.startItem = [self actionItem:@"开启自动保护" selector:@selector(startGuardian:) key:@""];
    self.stopItem = [self actionItem:@"暂停自动保护" selector:@selector(stopGuardian:) key:@""];
    self.restartItem = [self actionItem:@"重启自动保护" selector:@selector(restartGuardian:) key:@""];
    [self.menu addItem:self.startItem];
    [self.menu addItem:self.stopItem];
    [self.menu addItem:self.restartItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self actionItem:@"打开配置" selector:@selector(openConfig:) key:@""]];
    [self.menu addItem:[self actionItem:@"打开日志" selector:@selector(openLog:) key:@""]];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.eventsHeaderItem = [self infoItem:@"最近事件"];
    [self.menu addItem:self.eventsHeaderItem];
    NSMutableArray<NSMenuItem *> *events = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        NSMenuItem *item = [self infoItem:@"—"];
        [events addObject:item];
        [self.menu addItem:item];
    }
    self.eventItems = events;
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self actionItem:@"退出状态栏（自动保护继续运行）" selector:@selector(quitStatusApp:) key:@"q"]];
    self.statusItem.menu = self.menu;
    [self updateControlItems];
    [self updateButton:GuardianAppearanceWorking tooltip:@"ClashX Guardian 正在启动"];
}

- (GuardianAppearance)appearanceForStatus:(NSDictionary *)status {
    if (NSDate.date.timeIntervalSince1970 - [status[@"timestamp"] doubleValue] > 20) return GuardianAppearanceStopped;
    return BaseAppearance(status[@"state"], status[@"level"]);
}

- (void)refreshStatus {
    NSError *error = nil;
    NSDictionary *status = ReadStatus(self.statusURL, &error);
    if (!status) { [self renderUnavailable:error]; return; }
    [self render:status];
    [self handleTransition:status];
}

- (void)render:(NSDictionary *)status {
    GuardianAppearance appearance = [self appearanceForStatus:status];
    NSString *label = AppearanceLabel(appearance);
    [self updateButton:appearance tooltip:[NSString stringWithFormat:@"ClashX Guardian：%@", label]];
    NSInteger testingIndex = [status[@"testingIndex"] integerValue];
    NSInteger testingTotal = [status[@"testingTotal"] integerValue];
    BOOL isRunning = [self guardianProcessIsAlive:status] && appearance != GuardianAppearanceStopped;
    self.summaryItem.title = !isRunning ? @"自动保护：已暂停（重新打开本应用会自动开启）"
        : testingTotal > 0 ? [NSString stringWithFormat:@"自动保护：已开启 · 正在测试 %ld/%ld", (long)testingIndex, (long)testingTotal]
        : [NSString stringWithFormat:@"自动保护：已开启 · %@", label];
    NSString *ssid = [status[@"ssid"] length] ? status[@"ssid"] : @"—";
    NSString *node = [status[@"currentNode"] length] ? status[@"currentNode"] : @"—";
    self.ssidItem.title = [NSString stringWithFormat:@"Wi-Fi：%@", ssid];
    self.nodeItem.title = [NSString stringWithFormat:@"节点：%@", [self truncated:node]];
    self.diagnosisItem.title = [NSString stringWithFormat:@"线路：%@", [self diagnosisText:status[@"diagnosis"]]];
    self.checkedItem.title = [NSString stringWithFormat:@"上次检测：%@", [self relativeTime:[status[@"timestamp"] doubleValue]]];
    NSInteger elapsed = [status[@"failureElapsed"] integerValue], threshold = [status[@"failureSeconds"] integerValue];
    self.thresholdItem.title = elapsed > 0 ? [NSString stringWithFormat:@"失败计时：%ld/%ld 秒", (long)elapsed, (long)threshold]
                                           : [NSString stringWithFormat:@"切换阈值：%ld 秒", (long)threshold];
    NSNumber *lastAttempt = status[@"lastAttemptAt"];
    NSString *attemptText = lastAttempt && lastAttempt != (id)NSNull.null ? [self relativeTime:lastAttempt.doubleValue] : @"尚未尝试";
    self.attemptedItem.title = [NSString stringWithFormat:@"上次尝试：%@", attemptText];
    NSNumber *lastSwitch = status[@"lastSwitchAt"];
    NSString *switchText = lastSwitch && lastSwitch != (id)NSNull.null ? [self relativeTime:lastSwitch.doubleValue] : @"尚未切换";
    self.switchedItem.title = [NSString stringWithFormat:@"成功切换：%@", switchText];
    [self renderEvents:status[@"recentEvents"]];
    self.guardianRunning = isRunning;
    [self updateControlItems];
}

- (NSString *)diagnosisText:(id)value {
    NSString *diagnosis = [value isKindOfClass:NSString.class] ? value : @"unknown";
    if ([diagnosis isEqualToString:@"healthy"]) return @"Codex 与外网正常";
    if ([diagnosis isEqualToString:@"openai_unreachable"]) return @"外网正常，OpenAI 异常";
    if ([diagnosis isEqualToString:@"secondary_degraded"]) return @"Codex 可达，公共探针异常";
    if ([diagnosis isEqualToString:@"route_unreachable"]) return @"当前节点无法访问外网";
    if ([diagnosis isEqualToString:@"shared_outage_suspected"]) return @"多个节点共同异常，已停止盲切";
    if ([diagnosis isEqualToString:@"starting"]) return @"正在初始化";
    return @"等待诊断";
}

- (void)renderEvents:(id)value {
    NSArray *events = [value isKindOfClass:NSArray.class] ? value : @[];
    NSInteger visible = MIN((NSInteger)events.count, (NSInteger)self.eventItems.count);
    for (NSInteger index = 0; index < (NSInteger)self.eventItems.count; index++) {
        NSMenuItem *item = self.eventItems[index];
        if (index >= visible) {
            item.title = index == 0 ? @"暂无事件" : @"";
            item.hidden = index > 0;
            continue;
        }
        item.hidden = NO;
        id rawEvent = events[events.count - 1 - index];
        NSDictionary *event = [rawEvent isKindOfClass:NSDictionary.class] ? rawEvent : @{};
        NSString *message = [event[@"message"] isKindOfClass:NSString.class] ? event[@"message"] : @"状态变化";
        NSTimeInterval timestamp = [event[@"timestamp"] doubleValue];
        item.title = [NSString stringWithFormat:@"%@ · %@", [self relativeTime:timestamp], [self truncated:message]];
    }
}

- (void)renderUnavailable:(NSError *)error {
    [self updateButton:GuardianAppearanceStopped tooltip:@"ClashX Guardian 状态不可用"];
    self.summaryItem.title = @"自动保护：已暂停（重新打开本应用会自动开启）";
    self.ssidItem.title = @"Wi-Fi：—"; self.nodeItem.title = @"节点：—"; self.diagnosisItem.title = @"线路：—";
    self.checkedItem.title = @"上次检测：—"; self.thresholdItem.title = @"切换阈值：—";
    self.attemptedItem.title = @"上次尝试：—"; self.switchedItem.title = @"成功切换：—";
    [self renderEvents:nil];
    self.guardianRunning = NO;
    [self updateControlItems];
    if (error) os_log_debug(OS_LOG_DEFAULT, "status read failed: %{public}@", error.localizedDescription);
}

- (void)updateButton:(GuardianAppearance)appearance tooltip:(NSString *)tooltip {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) return;
    NSColor *color = AppearanceColor(appearance);
    NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightSemibold];
    NSImageSymbolConfiguration *palette = [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
    NSImageSymbolConfiguration *configuration = [size configurationByApplyingConfiguration:palette];
    NSImage *image = [[NSImage imageWithSystemSymbolName:AppearanceSymbol(appearance) accessibilityDescription:AppearanceLabel(appearance)]
        imageWithSymbolConfiguration:configuration];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:AppearanceLabel(appearance)];
    image.template = NO;
    button.title = @"";
    button.image = image;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = color;
    button.toolTip = tooltip;
    [button setAccessibilityLabel:[NSString stringWithFormat:@"ClashX Guardian：%@", AppearanceLabel(appearance)]];
}

- (void)handleTransition:(NSDictionary *)status {
    NSString *state = status[@"state"], *previous = self.previousState;
    self.previousState = state;
    if (!previous || [previous isEqualToString:state]) return;
    if ([state isEqualToString:@"switching"]) [self notify:@"Codex 线路异常" body:@"正在测试并切换 ClashX 节点"];
    else if ([state isEqualToString:@"healthy"] && [@[@"unhealthy", @"switching", @"switch_failed", @"controller_off"] containsObject:previous]) {
        NSString *node = [status[@"currentNode"] length] ? status[@"currentNode"] : @"可用节点";
        [self notify:@"Codex 网络已恢复" body:[NSString stringWithFormat:@"当前节点：%@", node]];
    } else if ([state isEqualToString:@"switch_failed"]) [self notify:@"Codex 网络恢复失败" body:@"没有候选节点通过完整连通性检查"];
    else if ([state isEqualToString:@"controller_off"]) [self notify:@"ClashX Pro 不可用" body:@"Guardian 无法访问本地控制接口"];
}

- (void)requestNotificationPermission {
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError *error) {
            if (error) os_log_error(OS_LOG_DEFAULT, "notification permission failed: %{public}@", error.localizedDescription);
            os_log_info(OS_LOG_DEFAULT, "notification permission granted=%{public}@", granted ? @"yes" : @"no");
        }];
}

- (void)notify:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title; content.body = body; content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)checkNow:(id)sender {
    (void)sender;
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:self.baseDirectory withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error) [[NSData data] writeToURL:self.triggerURL options:NSDataWritingAtomic error:&error];
    if (error) [self showAlert:@"无法请求检测" message:error.localizedDescription];
    else { self.summaryItem.title = @"状态：已请求立即检测…"; os_log_info(OS_LOG_DEFAULT, "immediate check requested"); }
}

- (void)restartGuardian:(id)sender {
    (void)sender;
    if (!self.guardianRunning) { [self ensureGuardianRunning:YES]; return; }
    self.summaryItem.title = @"自动保护：正在重启…";
    [self runLaunchctl:@[@"kickstart", @"-k", [self guardianServiceTarget]] completion:^(BOOL success, NSString *message) {
        if (!success) [self showAlert:@"无法重启 Guardian" message:message];
        else os_log_info(OS_LOG_DEFAULT, "guardian restart requested");
        [self refreshStatus];
    }];
}

- (void)startGuardian:(id)sender { (void)sender; [self ensureGuardianRunning:YES]; }

- (void)stopGuardian:(id)sender {
    (void)sender;
    self.summaryItem.title = @"自动保护：正在暂停…";
    [self runLaunchctl:@[@"bootout", [self guardianServiceTarget]] completion:^(BOOL success, NSString *message) {
        if (!success) [self showAlert:@"无法停止 Guardian" message:message];
        else [self notify:@"Codex 自动保护已暂停" body:@"重新打开状态栏应用时会自动开启"];
        self.guardianRunning = NO;
        [self updateControlItems];
        [self refreshStatus];
    }];
}

- (void)ensureGuardianRunning:(BOOL)showErrors {
    if (self.guardianRunning) return;
    self.summaryItem.title = @"自动保护：正在开启…";
    NSString *domain = [NSString stringWithFormat:@"gui/%d", getuid()];
    NSString *plist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.local.clashx-guardian.plist"];
    [self runLaunchctl:@[@"bootstrap", domain, plist] completion:^(BOOL success, NSString *message) {
        if (success) {
            os_log_info(OS_LOG_DEFAULT, "guardian automatically started");
            [self refreshStatus];
            return;
        }
        [self runLaunchctl:@[@"kickstart", @"-k", [self guardianServiceTarget]] completion:^(BOOL kicked, NSString *kickMessage) {
            if (!kicked && showErrors) [self showAlert:@"无法启动 Guardian" message:kickMessage.length ? kickMessage : message];
            [self refreshStatus];
        }];
    }];
}

- (NSString *)guardianServiceTarget { return [NSString stringWithFormat:@"gui/%d/com.local.clashx-guardian", getuid()]; }

- (BOOL)guardianProcessIsAlive:(NSDictionary *)status {
    pid_t pid = (pid_t)[status[@"pid"] intValue];
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

- (void)updateControlItems {
    self.startItem.enabled = !self.guardianRunning;
    self.stopItem.enabled = self.guardianRunning;
    self.restartItem.enabled = self.guardianRunning;
}

- (void)runLaunchctl:(NSArray<NSString *> *)arguments completion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        NSPipe *pipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
        task.arguments = arguments;
        task.standardError = pipe;
        NSError *error = nil;
        BOOL launched = [task launchAndReturnError:&error];
        if (launched) [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        BOOL success = launched && task.terminationStatus == 0;
        NSString *message = error.localizedDescription ?: [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message); });
    });
}

- (void)openConfig:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:self.configURL]; }
- (void)openLog:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:self.logURL]; }
- (void)quitStatusApp:(id)sender { (void)sender; [NSApp terminate:nil]; }

- (NSString *)relativeTime:(NSTimeInterval)timestamp {
    NSInteger seconds = MAX(0, (NSInteger)(NSDate.date.timeIntervalSince1970 - timestamp));
    if (seconds < 5) return @"刚刚";
    if (seconds < 60) return [NSString stringWithFormat:@"%ld 秒前", (long)seconds];
    if (seconds < 3600) return [NSString stringWithFormat:@"%ld 分钟前", (long)(seconds / 60)];
    return [NSString stringWithFormat:@"%ld 小时前", (long)(seconds / 3600)];
}

- (NSString *)truncated:(NSString *)value { return value.length <= 42 ? value : [[value substringToIndex:39] stringByAppendingString:@"…"]; }
- (void)showAlert:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [NSAlert new]; alert.messageText = title; alert.informativeText = message; alert.alertStyle = NSAlertStyleWarning; [alert runModal];
}
@end

static int RunSelfTest(NSString *path) {
    NSError *error = nil;
    NSDictionary *status = ReadStatus([NSURL fileURLWithPath:path], &error);
    if (!status) { fprintf(stderr, "self-test failed: %s\n", error.localizedDescription.UTF8String); return 1; }
    GuardianAppearance appearance = BaseAppearance(status[@"state"], status[@"level"]);
    printf("self_test_ok=1 state=%s appearance=%ld\n", [status[@"state"] UTF8String], (long)appearance);
    return appearance == GuardianAppearanceHealthy ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--self-test") == 0) return RunSelfTest([NSString stringWithUTF8String:argv[2]]);
        NSApplication *app = NSApplication.sharedApplication;
        GuardianAppDelegate *delegate = [GuardianAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
