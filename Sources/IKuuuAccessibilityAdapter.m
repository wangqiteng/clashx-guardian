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
    return [current isEqualToString:target] || [current hasPrefix:target] || [target hasPrefix:current];
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
    return [parts.array componentsJoinedByString:@"\n"];
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
    if (!element || depth > 12 || elements.count >= 1500) return;
    [elements addObject:(__bridge id)element];
    NSString *text = IKuuuElementText(element);
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
    if (!snapshot || !IKuuuSnapshotHasServerSemantics(snapshot)) return IKuuuAccessibilityStateIncompatible;
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
    NSArray *windows = IKuuuCopyAttribute(appElement, kAXWindowsAttribute);
    CFRelease(appElement);
    if (![windows isKindOfClass:NSArray.class] || windows.count == 0) {
        if (error) *error = IKuuuError(IKuuuAccessibilityErrorIncompatible, @"未找到 iKuuuVPN 标准窗口");
        return NULL;
    }

    AXUIElementRef window = (__bridge AXUIElementRef)windows.firstObject;
    CFRetain(window);
    if (elements && strings) IKuuuCollectElements(window, 0, elements, strings);
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

- (AXUIElementRef)copyRefreshButtonInWindow:(AXUIElementRef)window elements:(NSArray *)elements {
    CGRect windowFrame = CGRectZero;
    if (!IKuuuElementFrame(window, &windowFrame)) return NULL;
    NSMutableArray *candidates = [NSMutableArray array];
    for (id rawElement in elements) {
        AXUIElementRef element = (__bridge AXUIElementRef)rawElement;
        NSString *role = IKuuuCopyAttribute(element, kAXRoleAttribute);
        if (![role isEqualToString:(__bridge NSString *)kAXButtonRole]) continue;
        if (IKuuuElementText(element).length) continue;
        CGRect frame = CGRectZero;
        if (!IKuuuElementFrame(element, &frame)) continue;
        BOOL inToolbar = CGRectGetMidY(frame) <= CGRectGetMinY(windowFrame) + windowFrame.size.height * 0.18;
        BOOL onRight = CGRectGetMidX(frame) >= CGRectGetMinX(windowFrame) + windowFrame.size.width * 0.70;
        if (inToolbar && onRight) [candidates addObject:rawElement];
    }
    if (candidates.count < 2) return NULL;
    id rightmost = [candidates sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        CGRect leftFrame = CGRectZero, rightFrame = CGRectZero;
        IKuuuElementFrame((__bridge AXUIElementRef)left, &leftFrame);
        IKuuuElementFrame((__bridge AXUIElementRef)right, &rightFrame);
        return CGRectGetMidX(leftFrame) > CGRectGetMidX(rightFrame) ? NSOrderedAscending : NSOrderedDescending;
    }].firstObject;
    AXUIElementRef result = (__bridge AXUIElementRef)rightmost;
    CFRetain(result);
    return result;
}

- (NSArray<IKuuuNodeResult *> *)benchmarkWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
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
    NSArray<IKuuuNodeResult *> *latest = nil;
    [NSThread sleepForTimeInterval:1.0];
    while (NSDate.date.timeIntervalSince1970 < deadline) {
        NSError *inspectError = nil;
        IKuuuAXSnapshot *snapshot = [self inspectWithError:&inspectError];
        NSArray<IKuuuNodeResult *> *nodes = snapshot ? IKuuuNodesFromSnapshot(snapshot, nil) : nil;
        if (nodes.count >= 2) {
            latest = IKuuuRankNodes(nodes, nil);
            [samples addObject:[latest valueForKey:@"delayMilliseconds"]];
            if (IKuuuDelaySamplesAreStable(samples, 2)) return latest;
        }
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
