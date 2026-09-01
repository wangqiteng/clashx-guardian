#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>
#import <errno.h>
#import <signal.h>
#import "GuardianStartPolicy.h"

static NSString *const GuardianBundleID = @"com.local.ClashXGuardianStatus";

static void PrepareDiagnosticLog(NSURL *logURL) {
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtURL:logURL.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];
    NSNumber *size = [manager attributesOfItemAtPath:logURL.path error:nil][NSFileSize];
    if (GuardianDiagnosticLogNeedsRotation(size.unsignedLongLongValue)) {
        // 只保留一份旧诊断，避免长期运行无限占用磁盘。
        NSURL *previousURL = [NSURL fileURLWithPath:[logURL.path stringByAppendingString:@".previous"]];
        [manager removeItemAtURL:previousURL error:nil];
        [manager moveItemAtURL:logURL toURL:previousURL error:nil];
    }
    if (![manager fileExistsAtPath:logURL.path]) {
        [manager createFileAtPath:logURL.path contents:NSData.data
                       attributes:@{NSFilePosixPermissions: @0600}];
    }
}

typedef NS_ENUM(NSInteger, GuardianAppearance) {
    GuardianAppearanceHealthy, GuardianAppearanceWarning, GuardianAppearanceWorking,
    GuardianAppearanceError, GuardianAppearanceInactive, GuardianAppearanceStopped,
};

static NSImage *GuardianStatusImage(GuardianAppearance appearance);
static NSImage *GuardianApplicationIconImage(void);

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
        case GuardianAppearanceHealthy: return [NSColor colorWithSRGBRed:0.10 green:0.78 blue:0.36 alpha:1];
        case GuardianAppearanceWarning: return [NSColor colorWithSRGBRed:1.00 green:0.58 blue:0.08 alpha:1];
        case GuardianAppearanceWorking: return [NSColor colorWithSRGBRed:0.12 green:0.55 blue:0.98 alpha:1];
        case GuardianAppearanceError: return [NSColor colorWithSRGBRed:0.96 green:0.20 blue:0.22 alpha:1];
        case GuardianAppearanceInactive: return [NSColor colorWithSRGBRed:0.48 green:0.50 blue:0.54 alpha:1];
        case GuardianAppearanceStopped: return [NSColor colorWithSRGBRed:0.38 green:0.40 blue:0.44 alpha:1];
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

static NSString *SummaryText(NSDictionary *status, BOOL isRunning, GuardianAppearance appearance) {
    if (!isRunning) return @"自动保护：已暂停（重新打开本应用会自动开启）";
    NSInteger testingIndex = [status[@"testingIndex"] integerValue];
    NSInteger testingTotal = [status[@"testingTotal"] integerValue];
    NSString *candidate = [status[@"candidateNode"] isKindOfClass:NSString.class] ? status[@"candidateNode"] : @"";
    if (testingTotal > 0) {
        NSString *progress = [NSString stringWithFormat:@"自动保护：已开启 · 正在测试 %ld/%ld",
                              (long)testingIndex, (long)testingTotal];
        return candidate.length ? [progress stringByAppendingFormat:@" · %@", candidate] : progress;
    }
    return [NSString stringWithFormat:@"自动保护：已开启 · %@", AppearanceLabel(appearance)];
}

static NSImage *GuardianStatusImage(GuardianAppearance appearance) {
    NSSize size = NSMakeSize(18, 18);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:36 pixelsHigh:36 bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    CGContextSetShouldAntialias(context.CGContext, true);
    CGContextClearRect(context.CGContext, CGRectMake(0, 0, 18, 18));

    NSBezierPath *shield = [NSBezierPath bezierPath];
    [shield moveToPoint:NSMakePoint(9, 17)];
    [shield curveToPoint:NSMakePoint(2.5, 14.4) controlPoint1:NSMakePoint(7.1, 16.1) controlPoint2:NSMakePoint(4.9, 15.0)];
    [shield lineToPoint:NSMakePoint(2.5, 9.2)];
    [shield curveToPoint:NSMakePoint(9, 1.2) controlPoint1:NSMakePoint(2.5, 5.6) controlPoint2:NSMakePoint(5.2, 2.7)];
    [shield curveToPoint:NSMakePoint(15.5, 9.2) controlPoint1:NSMakePoint(12.8, 2.7) controlPoint2:NSMakePoint(15.5, 5.6)];
    [shield lineToPoint:NSMakePoint(15.5, 14.4)];
    [shield curveToPoint:NSMakePoint(9, 17) controlPoint1:NSMakePoint(13.1, 15.0) controlPoint2:NSMakePoint(10.9, 16.1)];
    [shield closePath];
    [AppearanceColor(appearance) setFill];
    [shield fill];

    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image addRepresentation:bitmap];
    image.template = NO;
    image.accessibilityDescription = [NSString stringWithFormat:@"ClashX Guardian：%@", AppearanceLabel(appearance)];
    return image;
}

static NSImage *GuardianApplicationIconImage(void) {
    const NSInteger pixels = 1024;
    NSSize size = NSMakeSize(pixels, pixels);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    CGContextSetShouldAntialias(context.CGContext, true);
    CGContextClearRect(context.CGContext, CGRectMake(0, 0, pixels, pixels));

    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(64, 64, 896, 896)
                                                         xRadius:196 yRadius:196];
    NSGradient *tileGradient = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.96 green:0.98 blue:1.00 alpha:1]
                  endingColor:[NSColor colorWithSRGBRed:0.84 green:0.89 blue:0.95 alpha:1]];
    [tileGradient drawInBezierPath:tile angle:90];
    [[NSColor colorWithWhite:1 alpha:0.72] setStroke];
    tile.lineWidth = 4;
    [tile stroke];

    NSBezierPath *shield = [NSBezierPath bezierPath];
    [shield moveToPoint:NSMakePoint(512, 836)];
    [shield curveToPoint:NSMakePoint(274, 724) controlPoint1:NSMakePoint(444, 802) controlPoint2:NSMakePoint(360, 750)];
    [shield lineToPoint:NSMakePoint(274, 498)];
    [shield curveToPoint:NSMakePoint(512, 190) controlPoint1:NSMakePoint(274, 354) controlPoint2:NSMakePoint(372, 242)];
    [shield curveToPoint:NSMakePoint(750, 498) controlPoint1:NSMakePoint(652, 242) controlPoint2:NSMakePoint(750, 354)];
    [shield lineToPoint:NSMakePoint(750, 724)];
    [shield curveToPoint:NSMakePoint(512, 836) controlPoint1:NSMakePoint(664, 750) controlPoint2:NSMakePoint(580, 802)];
    [shield closePath];

    NSBezierPath *shieldShadow = [shield copy];
    NSAffineTransform *shadowTransform = [NSAffineTransform transform];
    [shadowTransform translateXBy:0 yBy:-12];
    [shieldShadow transformUsingAffineTransform:shadowTransform];
    [[NSColor colorWithSRGBRed:0.18 green:0.30 blue:0.34 alpha:0.12] setFill];
    [shieldShadow fill];

    NSGradient *shieldGradient = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.65 green:0.82 blue:0.70 alpha:1]
                  endingColor:[NSColor colorWithSRGBRed:0.36 green:0.65 blue:0.50 alpha:1]];
    [shieldGradient drawInBezierPath:shield angle:90];
    [[NSColor colorWithWhite:1 alpha:0.45] setStroke];
    shield.lineWidth = 6;
    [shield stroke];

    NSColor *glyphColor = [NSColor colorWithSRGBRed:1.00 green:0.99 blue:0.96 alpha:1];
    [glyphColor setStroke];
    [glyphColor setFill];
    for (NSNumber *radiusValue in @[@170, @286]) {
        NSBezierPath *wave = [NSBezierPath bezierPath];
        wave.lineWidth = 72;
        wave.lineCapStyle = NSLineCapStyleRound;
        [wave appendBezierPathWithArcWithCenter:NSMakePoint(512, 338)
                                         radius:radiusValue.doubleValue
                                     startAngle:43
                                       endAngle:137];
        [wave stroke];
    }
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(468, 270, 88, 88)] fill];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image addRepresentation:bitmap];
    image.template = NO;
    image.accessibilityDescription = @"ClashX Guardian 网络守护";
    return image;
}

static int WriteApplicationIcon(NSString *path) {
    NSImage *image = GuardianApplicationIconImage();
    NSBitmapImageRep *bitmap = (NSBitmapImageRep *)image.representations.firstObject;
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png || ![png writeToFile:path atomically:YES]) {
        fprintf(stderr, "failed to write application icon: %s\n", path.UTF8String);
        return 1;
    }
    return 0;
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
@property(nonatomic) BOOL guardianStartInProgress;
@property(nonatomic, copy) NSString *guardianOperationLabel;
@property(nonatomic, strong) NSURL *diagnosticLogURL;
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
    self.diagnosticLogURL = [home URLByAppendingPathComponent:@"Library/Logs/ClashXGuardianDiagnostic.log"];
    PrepareDiagnosticLog(self.diagnosticLogURL);
    freopen(self.diagnosticLogURL.fileSystemRepresentation, "a", stderr);
    setvbuf(stderr, NULL, _IOLBF, 0);
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
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
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
    [self.menu addItem:[self actionItem:@"打开诊断日志" selector:@selector(openDiagnosticLog:) key:@""]];
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
    [self.menu addItem:[self actionItem:@"退出 ClashX Guardian（同时停止自动保护）" selector:@selector(quitStatusApp:) key:@"q"]];
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
    BOOL isRunning = [self guardianProcessIsAlive:status] && appearance != GuardianAppearanceStopped;
    self.summaryItem.title = GuardianVisibleSummary(self.guardianOperationLabel,
                                                    SummaryText(status, isRunning, appearance));
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
    self.summaryItem.title = GuardianVisibleSummary(self.guardianOperationLabel,
                                                    @"自动保护：已暂停（重新打开本应用会自动开启）");
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
    button.title = @"";
    button.image = GuardianStatusImage(appearance);
    button.imagePosition = NSImageOnly;
    button.contentTintColor = nil;
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
    if (self.guardianStartInProgress) return;
    if (!self.guardianRunning) { [self ensureGuardianRunning:YES]; return; }
    [self beginGuardianOperation:@"正在重启…"];
    [self runLaunchctl:@[@"kickstart", @"-k", [self guardianServiceTarget]] completion:^(BOOL success, NSString *message) {
        if (!success) {
            [self finishGuardianOperation:NO showErrors:YES message:message];
            return;
        }
        os_log_info(OS_LOG_DEFAULT, "guardian restart requested");
        [self pollGuardianUntil:NSDate.date.timeIntervalSince1970 + 120 showErrors:YES lastMessage:message];
    }];
}

- (void)startGuardian:(id)sender { (void)sender; [self ensureGuardianRunning:YES]; }

- (void)stopGuardian:(id)sender {
    (void)sender;
    if (self.guardianStartInProgress) return;
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
    if (self.guardianRunning || self.guardianStartInProgress) return;
    [self beginGuardianOperation:@"正在开启…（最长等待 120 秒）"];
    NSString *domain = [NSString stringWithFormat:@"gui/%d", getuid()];
    NSString *plist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.local.clashx-guardian.plist"];
    [self runLaunchctl:@[@"bootstrap", domain, plist] completion:^(BOOL success, NSString *message) {
        if (success) {
            [self pollGuardianUntil:NSDate.date.timeIntervalSince1970 + 120 showErrors:showErrors lastMessage:message];
            return;
        }
        [self runLaunchctl:@[@"print", [self guardianServiceTarget]] completion:^(BOOL loaded, NSString *printOutput) {
            GuardianServiceState state = GuardianServiceStateFromLaunchctlOutput(printOutput);
            GuardianStartAction action = GuardianStartActionForService(loaded, state);
            if (action == GuardianStartActionComplete) {
                [self finishGuardianOperation:YES showErrors:showErrors message:printOutput];
            } else if (action == GuardianStartActionWait) {
                [self pollGuardianUntil:NSDate.date.timeIntervalSince1970 + 120
                             showErrors:showErrors lastMessage:printOutput];
            } else if (action == GuardianStartActionKickstart) {
                [self runLaunchctl:GuardianNonDestructiveKickstartArguments([self guardianServiceTarget])
                        completion:^(BOOL kicked, NSString *kickMessage) {
                    NSString *detail = kickMessage.length ? kickMessage : message;
                    if (!kicked) {
                        [self finishGuardianOperation:NO showErrors:showErrors message:detail];
                        return;
                    }
                    [self pollGuardianUntil:NSDate.date.timeIntervalSince1970 + 120
                                 showErrors:showErrors lastMessage:detail];
                }];
            } else {
                NSString *detail = message.length ? message : printOutput;
                [self finishGuardianOperation:NO showErrors:showErrors message:detail];
            }
        }];
    }];
}

- (void)beginGuardianOperation:(NSString *)label {
    self.guardianStartInProgress = YES;
    self.guardianOperationLabel = label;
    self.summaryItem.title = GuardianVisibleSummary(label, @"");
    [self updateControlItems];
}

- (void)pollGuardianUntil:(NSTimeInterval)deadline showErrors:(BOOL)showErrors lastMessage:(NSString *)lastMessage {
    [self runLaunchctl:@[@"print", [self guardianServiceTarget]] completion:^(BOOL loaded, NSString *output) {
        GuardianServiceState state = GuardianServiceStateFromLaunchctlOutput(output);
        if (loaded && state == GuardianServiceStateRunning) {
            [self finishGuardianOperation:YES showErrors:showErrors message:output];
            return;
        }
        NSString *detail = output.length ? output : lastMessage;
        if (NSDate.date.timeIntervalSince1970 >= deadline) {
            NSString *timeout = detail.length
                ? [NSString stringWithFormat:@"等待 120 秒后仍未启动。\n\n%@", detail]
                : @"等待 120 秒后仍未启动，请查看诊断日志。";
            [self finishGuardianOperation:NO showErrors:showErrors message:timeout];
            return;
        }
        self.summaryItem.title = GuardianVisibleSummary(self.guardianOperationLabel ?: @"正在启动…", @"");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self pollGuardianUntil:deadline showErrors:showErrors lastMessage:detail];
        });
    }];
}

- (void)finishGuardianOperation:(BOOL)success showErrors:(BOOL)showErrors message:(NSString *)message {
    self.guardianStartInProgress = NO;
    self.guardianOperationLabel = nil;
    if (success) {
        self.guardianRunning = YES;
        os_log_info(OS_LOG_DEFAULT, "guardian launch completed");
    } else {
        os_log_error(OS_LOG_DEFAULT, "guardian launch failed: %{public}@", message);
        if (showErrors) [self showAlert:@"无法启动 Guardian" message:message.length ? message : @"未知错误，请查看诊断日志。"];
    }
    [self refreshStatus];
    [self updateControlItems];
}

- (NSString *)guardianServiceTarget { return [NSString stringWithFormat:@"gui/%d/com.local.clashx-guardian", getuid()]; }

- (BOOL)guardianProcessIsAlive:(NSDictionary *)status {
    pid_t pid = (pid_t)[status[@"pid"] intValue];
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

- (void)updateControlItems {
    self.startItem.title = self.guardianStartInProgress ? @"正在启动，请稍候…" : @"开启自动保护";
    if (self.guardianStartInProgress) {
        self.startItem.enabled = NO;
        self.stopItem.enabled = NO;
        self.restartItem.enabled = NO;
        return;
    }
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
        task.standardOutput = pipe;
        task.standardError = pipe;
        NSError *error = nil;
        BOOL launched = [task launchAndReturnError:&error];
        if (launched) [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        BOOL success = launched && task.terminationStatus == 0;
        NSString *message = error.localizedDescription ?: [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *command = [arguments componentsJoinedByString:@" "];
        fprintf(stderr, "%s launchctl %s exit=%d%s%s\n",
                NSDate.date.description.UTF8String, command.UTF8String,
                launched ? task.terminationStatus : -1,
                message.length ? ": " : "", message.UTF8String ?: "");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message); });
    });
}

- (void)openConfig:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:self.configURL]; }
- (void)openLog:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:self.logURL]; }
- (void)openDiagnosticLog:(id)sender {
    (void)sender;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.diagnosticLogURL.path]) {
        [NSFileManager.defaultManager createFileAtPath:self.diagnosticLogURL.path contents:NSData.data attributes:nil];
    }
    [NSWorkspace.sharedWorkspace openURL:self.diagnosticLogURL];
}
- (void)quitStatusApp:(id)sender {
    (void)sender;
    self.summaryItem.title = @"自动保护：正在停止并退出…";
    [self runLaunchctl:@[@"print", [self guardianServiceTarget]] completion:^(BOOL loaded, NSString *printOutput) {
        if (GuardianQuitActionForService(loaded) == GuardianQuitActionTerminate) {
            [NSApp terminate:nil];
            return;
        }
        [self runLaunchctl:GuardianStopArguments([self guardianServiceTarget]) completion:^(BOOL success, NSString *message) {
            if (!GuardianShouldTerminateAfterStop(success)) {
                NSString *detail = message.length ? message : printOutput;
                [self showAlert:@"无法退出 ClashX Guardian"
                        message:detail.length ? detail : @"后台自动保护未能停止，请查看诊断日志。"];
                [self refreshStatus];
                return;
            }
            self.guardianRunning = NO;
            [NSApp terminate:nil];
        }];
    }];
}

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
    NSImage *statusImage = GuardianStatusImage(appearance);
    if (!statusImage || statusImage.size.width != 18 || statusImage.size.height != 18 || statusImage.template) {
        fprintf(stderr, "self-test failed: menu icon must be a non-template 18x18 image\n");
        return 1;
    }
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:statusImage.TIFFRepresentation];
    NSInteger coloredPixels = 0, whitePixels = 0, mirroredAlphaDifference = 0;
    for (NSInteger y = 0; y < bitmap.pixelsHigh; y++) {
        for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
            NSColor *pixel = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            if (!pixel || pixel.alphaComponent < 0.5) continue;
            CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
            [pixel getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
            if (saturation > 0.35 && brightness > 0.25) coloredPixels++;
            if (saturation < 0.12 && brightness > 0.82) whitePixels++;

            NSInteger mirrorX = bitmap.pixelsWide - 1 - x;
            NSColor *mirror = [[bitmap colorAtX:mirrorX y:y]
                colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            if (!mirror || fabs(pixel.alphaComponent - mirror.alphaComponent) > 0.08) {
                mirroredAlphaDifference++;
            }
        }
    }
    if (coloredPixels < 20 || whitePixels > 3 || mirroredAlphaDifference > 8) {
        fprintf(stderr, "self-test failed: menu icon must be a complete, centered, symmetric colored shield "
                        "(colored=%ld white=%ld mirror-diff=%ld)\n",
                (long)coloredPixels, (long)whitePixels, (long)mirroredAlphaDifference);
        return 1;
    }
    NSString *summary = SummaryText(status, YES, appearance);
    if ([status[@"state"] isEqualToString:@"switching"] &&
        ![summary containsString:@"🇯🇵 日本 Y02 · 88 ms"]) {
        fprintf(stderr, "self-test failed: switching summary omitted measured candidate\n");
        return 1;
    }
    printf("self_test_ok=1 state=%s appearance=%ld\n", [status[@"state"] UTF8String], (long)appearance);
    return appearance == GuardianAppearanceHealthy || appearance == GuardianAppearanceWorking ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--self-test") == 0) return RunSelfTest([NSString stringWithUTF8String:argv[2]]);
        if (argc == 3 && strcmp(argv[1], "--render-app-icon") == 0) return WriteApplicationIcon([NSString stringWithUTF8String:argv[2]]);
        NSApplication *app = NSApplication.sharedApplication;
        GuardianAppDelegate *delegate = [GuardianAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
