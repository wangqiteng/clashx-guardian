#import "IKuuuAccessibilityAdapter.h"

#import <ApplicationServices/ApplicationServices.h>

NSErrorDomain const IKuuuAccessibilityErrorDomain = @"com.local.ClashXGuardian.iKuuuAccessibility";

static NSString *const IKuuuBundleIdentifier = @"org.ikuuu.vpn";

@implementation IKuuuAXSnapshot

- (instancetype)initWithStrings:(NSArray<NSString *> *)strings {
    self = [super init];
    if (self) _strings = [strings copy];
    return self;
}

@end

static NSError *IKuuuError(IKuuuAccessibilityError code, NSString *message) {
    return [NSError errorWithDomain:IKuuuAccessibilityErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL IKuuuSnapshotHasServerSemantics(IKuuuAXSnapshot *snapshot) {
    BOOL hasServer = NO;
    BOOL hasSelector = NO;
    for (NSString *string in snapshot.strings) {
        hasServer = hasServer || [string containsString:@"服务器"];
        hasSelector = hasSelector || [string containsString:@"选择节点"];
    }
    return hasServer && hasSelector;
}

BOOL IKuuuSnapshotHasNavigation(IKuuuAXSnapshot *snapshot) {
    NSMutableSet *labels = [NSMutableSet set];
    for (NSString *text in snapshot.strings) {
        NSString *first = [text componentsSeparatedByString:@"\n"].firstObject;
        if (first) [labels addObject:first];
    }
    return [labels containsObject:@"主页"] && [labels containsObject:@"服务器"] &&
           [labels containsObject:@"我的"];
}

NSInteger IKuuuBenchmarkFrameIndex(NSArray<NSValue *> *frames, NSRect window) {
    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    for (NSUInteger i = 0; i < frames.count; i++) {
        NSRect frame = frames[i].rectValue;
        if (NSContainsRect(window, frame) && frame.size.width >= 36 && frame.size.width <= 72 &&
            frame.size.height >= 36 && frame.size.height <= 72 &&
            NSMidX(frame) >= NSMinX(window) + window.size.width * 0.85 &&
            NSMidY(frame) >= NSMinY(window) + window.size.height * 0.75)
            [matches addObject:@(i)];
    }
    // 当前版本右下角唯一的悬浮按钮触发全节点测速，顶部圆形箭头是刷新。
    return matches.count == 1 ? matches.firstObject.integerValue : NSNotFound;
}

NSString *IKuuuPreferredText(NSArray<NSString *> *values) {
    NSString *result = @"";
    // AXTitle、AXValue、AXDescription 常是同一标签的不同详略版本，不可串接为节点名。
    for (NSString *value in values) if (value.length > result.length) result = value;
    return result;
}

NSString *IKuuuCurrentNodeFromLabels(NSArray<NSString *> *labels) {
    for (NSString *text in labels) {
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        NSString *first = lines.firstObject;
        if (![first isEqualToString:@"当前节点"] && ![first containsString:@"选择节点"]) continue;
        if (lines.count > 1) {
            NSString *name = [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (name.length) return name;
        }
    }
    return nil;
}

NSArray<IKuuuNodeResult *> *IKuuuNodesFromSnapshot(IKuuuAXSnapshot *snapshot, NSError **error) {
    if (!IKuuuSnapshotHasServerSemantics(snapshot)) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible,
                                      @"未识别到 iKuuu 服务器与节点选择区域");
        return nil;
    }

    NSArray<IKuuuNodeResult *> *nodes = IKuuuParseNodeLabels(snapshot.strings);
    if (nodes.count < 2) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorInsufficientNodes,
                                      @"可读取的测速节点不足两个");
        return nil;
    }
    return nodes;
}

BOOL IKuuuDelaySamplesAreStable(NSArray<NSArray<NSNumber *> *> *samples, NSInteger requiredCount) {
    if (requiredCount < 1 || samples.count < (NSUInteger)requiredCount) return NO;
    NSArray<NSNumber *> *last = samples.lastObject;
    for (NSInteger offset = 2; offset <= requiredCount; offset++) {
        if (![last isEqual:samples[samples.count - (NSUInteger)offset]]) return NO;
    }
    return YES;
}

static NSString *IKuuuNormalizedNodeName(NSString *name) {
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

BOOL IKuuuSelectionMatches(NSString *currentNode, NSString *targetNode) {
    NSString *current = IKuuuNormalizedNodeName(currentNode);
    NSString *target = IKuuuNormalizedNodeName(targetNode);
    if (current.length == 0 || target.length == 0) return NO;
    return [current isEqualToString:target] ||
           [current hasPrefix:[target stringByAppendingString:@" |"]] ||
           [target hasPrefix:[current stringByAppendingString:@" |"]];
}

static id IKuuuCopyAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    return CFBridgingRelease(value);
}

static NSArray *IKuuuChildren(AXUIElementRef element) {
    id value = IKuuuCopyAttribute(element, kAXChildrenAttribute);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSString *IKuuuDirectText(AXUIElementRef element) {
    NSMutableOrderedSet<NSString *> *parts = [NSMutableOrderedSet orderedSet];
    for (id attribute in @[(__bridge id)kAXTitleAttribute,
                           (__bridge id)kAXValueAttribute,
                           (__bridge id)kAXDescriptionAttribute]) {
        id value = IKuuuCopyAttribute(element, (__bridge CFStringRef)attribute);
        if ([value isKindOfClass:NSString.class]) {
            NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length) [parts addObject:text];
        }
    }
    return IKuuuPreferredText(parts.array);
}

static NSString *IKuuuElementText(AXUIElementRef element) {
    NSMutableOrderedSet<NSString *> *parts = [NSMutableOrderedSet orderedSet];
    NSString *direct = IKuuuDirectText(element);
    if (direct.length) [parts addObject:direct];
    for (id rawChild in IKuuuChildren(element)) {
        AXUIElementRef child = (__bridge AXUIElementRef)rawChild;
        NSString *childText = IKuuuDirectText(child);
        if (childText.length) [parts addObject:childText];
    }
    return [parts.array componentsJoinedByString:@"\n"];
}

static void IKuuuCollectElements(AXUIElementRef element, NSInteger depth,
                                 NSMutableArray *elements, NSMutableArray<NSString *> *strings) {
    // Flutter 原始 AX 树包含多层不可见容器，节点卡片比可视化工具显示的树更深。
    if (!element || depth > 64 || elements.count >= 3000) return;
    [elements addObject:(__bridge id)element];
    // 父容器会聚合整个列表；只保留控件自己的标签，避免拼出虚假的多行节点名。
    NSString *text = IKuuuDirectText(element);
    if (text.length) [strings addObject:text];
    for (id rawChild in IKuuuChildren(element)) {
        IKuuuCollectElements((__bridge AXUIElementRef)rawChild, depth + 1, elements, strings);
    }
}

static BOOL IKuuuElementFrame(AXUIElementRef element, CGRect *frame) {
    id positionValue = IKuuuCopyAttribute(element, kAXPositionAttribute);
    id sizeValue = IKuuuCopyAttribute(element, kAXSizeAttribute);
    if (!positionValue || !sizeValue ||
        CFGetTypeID((__bridge CFTypeRef)positionValue) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)sizeValue) != AXValueGetTypeID()) return NO;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    if (!AXValueGetValue((__bridge AXValueRef)positionValue, kAXValueCGPointType, &position) ||
        !AXValueGetValue((__bridge AXValueRef)sizeValue, kAXValueCGSizeType, &size)) return NO;
    *frame = (CGRect){position, size};
    return YES;
}

@interface IKuuuAccessibilityAdapter ()
- (AXUIElementRef _Nullable)copyWindowWithElements:(NSMutableArray * _Nullable)elements
                                             strings:(NSMutableArray<NSString *> * _Nullable)strings
                                               error:(NSError **)error CF_RETURNS_RETAINED;
@end

@implementation IKuuuAccessibilityAdapter

- (NSRunningApplication *)runningApplication {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:IKuuuBundleIdentifier].firstObject;
}

- (IKuuuAccessibilityState)state {
    if (![self runningApplication]) return IKuuuAccessibilityStateClientNotRunning;
    if (!AXIsProcessTrusted()) return IKuuuAccessibilityStatePermissionRequired;
    NSError *error = nil;
    IKuuuAXSnapshot *snapshot = [self inspectWithError:&error];
    if (!snapshot || (!IKuuuSnapshotHasServerSemantics(snapshot) && !IKuuuSnapshotHasNavigation(snapshot)))
        return IKuuuAccessibilityStateIncompatible;
    return IKuuuAccessibilityStateReady;
}

- (void)requestAccessibilityPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (AXUIElementRef)copyWindowWithElements:(NSMutableArray *)elements
                                  strings:(NSMutableArray<NSString *> *)strings
                                    error:(NSError **)error {
    NSRunningApplication *application = [self runningApplication];
    if (!application) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorClientNotRunning, @"iKuuuVPN 未运行");
        return NULL;
    }
    if (!AXIsProcessTrusted()) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorPermissionRequired, @"尚未授予辅助功能权限");
        return NULL;
    }

    AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
    AXUIElementSetMessagingTimeout(appElement, 1.0);
    // Flutter 按辅助功能客户端需求生成语义树；先请求增强界面，避免后台首次读取为空。
    Boolean settable = false;
    if (AXUIElementIsAttributeSettable(appElement, CFSTR("AXEnhancedUserInterface"), &settable) == kAXErrorSuccess && settable)
        AXUIElementSetAttributeValue(appElement, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    NSArray *windows = IKuuuCopyAttribute(appElement, kAXWindowsAttribute);
    CFRelease(appElement);
    if (![windows isKindOfClass:NSArray.class] || windows.count == 0) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"未找到 iKuuuVPN 标准窗口");
        return NULL;
    }

    AXUIElementRef window = (__bridge AXUIElementRef)windows.firstObject;
    CFRetain(window);
    if (elements && strings) {
        for (NSInteger attempt = 0; attempt < 4; attempt++) {
            [elements removeAllObjects];
            [strings removeAllObjects];
            IKuuuCollectElements(window, 0, elements, strings);
            IKuuuAXSnapshot *snapshot = [[IKuuuAXSnapshot alloc] initWithStrings:strings];
            if (IKuuuSnapshotHasNavigation(snapshot) || IKuuuSnapshotHasServerSemantics(snapshot)) break;
            if (attempt < 3) [NSThread sleepForTimeInterval:0.15];
        }
    }
    return window;
}

- (IKuuuAXSnapshot *)inspectWithError:(NSError **)error {
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    AXUIElementRef window = [self copyWindowWithElements:elements strings:strings error:error];
    if (!window) return nil;
    CFRelease(window);
    return [[IKuuuAXSnapshot alloc] initWithStrings:strings];
}

// 仅恢复操作需要进入服务器页；日常检查留在用户当前页面。
- (BOOL)prepareServerPageWithError:(NSError **)error {
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray *strings = [NSMutableArray array];
    AXUIElementRef window = [self copyWindowWithElements:elements strings:strings error:error];
    if (!window) return NO;
    CFRelease(window);
    IKuuuAXSnapshot *snapshot = [[IKuuuAXSnapshot alloc] initWithStrings:strings];
    if (IKuuuSnapshotHasServerSemantics(snapshot)) return YES;
    if (!IKuuuSnapshotHasNavigation(snapshot)) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"无法识别 iKuuu 导航栏，请显示其主窗口后重试");
        return NO;
    }
    NSMutableArray *tabs = [NSMutableArray array];
    for (id raw in elements) {
        NSString *label = IKuuuDirectText((__bridge AXUIElementRef)raw);
        if ([label hasPrefix:@"服务器\n第 "] || [label isEqualToString:@"服务器"])
            [tabs addObject:raw];
    }
    if (tabs.count != 1 || AXUIElementPerformAction((__bridge AXUIElementRef)tabs.firstObject, kAXPressAction) != kAXErrorSuccess) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorActionFailed, @"无法打开 iKuuu 服务器页");
        return NO;
    }
    for (NSInteger attempt = 0; attempt < 12; attempt++) {
        [NSThread sleepForTimeInterval:0.15];
        IKuuuAXSnapshot *updated = [self inspectWithError:nil];
        if (updated && IKuuuSnapshotHasServerSemantics(updated)) return YES;
    }
    if (error) *error = IKuuuError(IKuuuAccessibilityErrorTimeout, @"iKuuu 服务器页未就绪");
    return NO;
}

- (AXUIElementRef)copyRefreshButtonInWindow:(AXUIElementRef)window elements:(NSArray *)elements {
    CGRect windowFrame = CGRectZero;
    if (!IKuuuElementFrame(window, &windowFrame)) return NULL;
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (id rawElement in elements) {
        AXUIElementRef element = (__bridge AXUIElementRef)rawElement;
        NSString *role = IKuuuCopyAttribute(element, kAXRoleAttribute);
        if (![role isEqualToString:(__bridge NSString *)kAXButtonRole]) continue;
        if (IKuuuElementText(element).length) continue;
        CGRect frame = CGRectZero;
        if (!IKuuuElementFrame(element, &frame)) continue;
        [candidates addObject:rawElement];
        [frames addObject:[NSValue valueWithRect:NSRectFromCGRect(frame)]];
    }
    NSInteger index = IKuuuBenchmarkFrameIndex(frames, NSRectFromCGRect(windowFrame));
    if (index == NSNotFound) return NULL;
    id rightmost = candidates[(NSUInteger)index];
    AXUIElementRef result = (__bridge AXUIElementRef)rightmost;
    CFRetain(result);
    return result;
}

- (NSArray<IKuuuNodeResult *> *)benchmarkWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (![self prepareServerPageWithError:error]) return nil;
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    AXUIElementRef window = [self copyWindowWithElements:elements strings:strings error:error];
    if (!window) return nil;
    IKuuuAXSnapshot *initialSnapshot = [[IKuuuAXSnapshot alloc] initWithStrings:strings];
    if (!IKuuuSnapshotHasServerSemantics(initialSnapshot)) {
        CFRelease(window);
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible,
                                      @"未识别到 iKuuu 服务器与节点选择区域");
        return nil;
    }
    AXUIElementRef refreshButton = [self copyRefreshButtonInWindow:window elements:elements];
    CFRelease(window);
    if (!refreshButton) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"无法唯一识别 iKuuu 测速按钮");
        return nil;
    }
    AXError action = AXUIElementPerformAction(refreshButton, kAXPressAction);
    CFRelease(refreshButton);
    if (action != kAXErrorSuccess) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorActionFailed, @"无法触发 iKuuu 节点测速");
        return nil;
    }

    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + MAX(2, timeout);
    NSMutableArray<NSArray<NSNumber *> *> *samples = [NSMutableArray array];
    NSArray<NSString *> *previousNames = nil;
    NSArray<IKuuuNodeResult *> *latest = nil;
    // 给整轮测速留出时间，避免把刷新前未变化的历史延迟当成本轮结果。
    [NSThread sleepForTimeInterval:3.0];
    while (NSDate.date.timeIntervalSince1970 < deadline) {
        NSError *inspectError = nil;
        IKuuuAXSnapshot *snapshot = [self inspectWithError:&inspectError];
        NSArray<IKuuuNodeResult *> *nodes = snapshot ? IKuuuNodesFromSnapshot(snapshot, nil) : nil;
        if (nodes.count >= 2) {
            latest = IKuuuRankNodes(nodes, nil);
            NSArray<NSString *> *names = [latest valueForKey:@"name"];
            if (previousNames && ![previousNames isEqual:names]) [samples removeAllObjects];
            previousNames = names;
            [samples addObject:[latest valueForKey:@"delayMilliseconds"]];
            if (IKuuuDelaySamplesAreStable(samples, 2)) return latest;
        } else { [samples removeAllObjects]; previousNames = nil; }
        [NSThread sleepForTimeInterval:0.5];
    }
    if (error) *error = IKuuuError(IKuuuAccessibilityErrorTimeout, @"等待 iKuuu 测速结果超时");
    return nil;
}

- (NSString *)currentNodeWithError:(NSError **)error {
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    AXUIElementRef window = [self copyWindowWithElements:elements strings:strings error:error];
    if (!window) return nil;
    CFRelease(window);
    NSString *homeNode = IKuuuCurrentNodeFromLabels(strings);
    if (homeNode) return homeNode;
    for (id rawElement in elements) {
        AXUIElementRef element = (__bridge AXUIElementRef)rawElement;
        NSString *role = IKuuuCopyAttribute(element, kAXRoleAttribute);
        if (![role isEqualToString:(__bridge NSString *)kAXButtonRole]) continue;
        NSString *text = IKuuuElementText(element);
        if (![text containsString:@"选择节点"] || [text containsString:@"ms"] || [text containsString:@"超时"]) continue;
        for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trimmed = IKuuuNormalizedNodeName(line);
            if (trimmed.length && ![trimmed containsString:@"选择节点"]) return trimmed;
        }
    }
    if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"无法读取 iKuuu 当前节点");
    return nil;
}

- (BOOL)selectNodeNamed:(NSString *)name error:(NSError **)error {
    if (![self prepareServerPageWithError:error]) return NO;
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    AXUIElementRef window = [self copyWindowWithElements:elements strings:strings error:error];
    if (!window) return NO;
    CFRelease(window);

    AXUIElementRef target = NULL;
    for (id rawElement in elements) {
        AXUIElementRef element = (__bridge AXUIElementRef)rawElement;
        NSString *role = IKuuuCopyAttribute(element, kAXRoleAttribute);
        if (![role isEqualToString:(__bridge NSString *)kAXButtonRole]) continue;
        NSArray<IKuuuNodeResult *> *nodes = IKuuuParseNodeLabels(@[IKuuuElementText(element)]);
        if (nodes.count == 1 && [nodes.firstObject.name isEqualToString:name]) {
            if (target) {
                if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"目标节点控件不唯一");
                CFRelease(target);
                return NO;
            }
            target = element;
            CFRetain(target);
        }
    }
    if (!target) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"未找到目标节点控件");
        return NO;
    }
    AXError action = AXUIElementPerformAction(target, kAXPressAction);
    CFRelease(target);
    if (action != kAXErrorSuccess) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorActionFailed, @"无法选择 iKuuu 节点");
        return NO;
    }
    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 4;
    while (NSDate.date.timeIntervalSince1970 < deadline) {
        NSString *current = [self currentNodeWithError:nil];
        if (current && IKuuuSelectionMatches(current, name)) return YES;
        [NSThread sleepForTimeInterval:0.25];
    }
    if (error) *error = IKuuuError(IKuuuAccessibilityErrorActionFailed, @"iKuuu 未确认目标节点");
    return NO;
}

@end
