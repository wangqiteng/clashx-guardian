#import "IKuuuRequestCoordinator.h"

static NSString *const IKuuuRequestFileName = @"ikuuu-request.json";
static NSString *const IKuuuResponseFileName = @"ikuuu-response.json";

static NSError *IKuuuProtocolError(NSString *message) {
    return [NSError errorWithDomain:@"com.local.ClashXGuardian.iKuuuProtocol"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSError *IKuuuValidateRequest(NSDictionary *request, NSTimeInterval now) {
    if (![request isKindOfClass:NSDictionary.class]) return IKuuuProtocolError(@"请求不是 JSON 对象");
    NSString *requestID = [request[@"id"] isKindOfClass:NSString.class] ? request[@"id"] : @"";
    NSString *operation = [request[@"operation"] isKindOfClass:NSString.class] ? request[@"operation"] : @"";
    NSNumber *expiresAt = [request[@"expiresAt"] isKindOfClass:NSNumber.class] ? request[@"expiresAt"] : nil;
    if (requestID.length == 0 || requestID.length > 128) return IKuuuProtocolError(@"请求 ID 无效");
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"inspect", @"benchmark", @"select", @"restore"]];
    if (![allowed containsObject:operation]) return IKuuuProtocolError(@"请求操作无效");
    if (!expiresAt || expiresAt.doubleValue <= now) return IKuuuProtocolError(@"请求已过期");
    if (([operation isEqualToString:@"select"] || [operation isEqualToString:@"restore"])) {
        NSString *node = [request[@"node"] isKindOfClass:NSString.class] ? request[@"node"] : @"";
        if (node.length == 0 || node.length > 512) return IKuuuProtocolError(@"目标节点无效");
    }
    return nil;
}

static NSString *IKuuuCapability(IKuuuAccessibilityState state) {
    switch (state) {
        case IKuuuAccessibilityStateClientNotRunning: return @"client_not_running";
        case IKuuuAccessibilityStatePermissionRequired: return @"permission_required";
        case IKuuuAccessibilityStateReady: return @"ready";
        case IKuuuAccessibilityStateIncompatible: return @"incompatible";
    }
}

static NSString *IKuuuErrorCode(NSError *error) {
    if (![error.domain isEqualToString:IKuuuAccessibilityErrorDomain]) return @"protocol_error";
    switch ((IKuuuAccessibilityError)error.code) {
        case IKuuuAccessibilityErrorClientNotRunning: return @"client_not_running";
        case IKuuuAccessibilityErrorPermissionRequired: return @"permission_required";
        case IKuuuAccessibilityErrorIncompatible:
        case IKuuuAccessibilityErrorInsufficientNodes: return @"incompatible";
        case IKuuuAccessibilityErrorTimeout: return @"timeout";
        case IKuuuAccessibilityErrorActionFailed: return @"action_failed";
    }
}

@interface IKuuuRequestCoordinator ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) IKuuuAccessibilityAdapter *adapter;
@property(nonatomic, copy) NSString *lastRequestID;
@property(nonatomic) BOOL busy;
@end

@implementation IKuuuRequestCoordinator

- (instancetype)initWithDirectory:(NSURL *)directory adapter:(IKuuuAccessibilityAdapter *)adapter {
    self = [super init];
    if (self) {
        _directory = directory;
        _adapter = adapter;
    }
    return self;
}

- (NSString *)capabilityLabel { return IKuuuCapability(self.adapter.state); }

- (void)pollOnce {
    @synchronized (self) {
        if (self.busy) return;
    }
    NSURL *requestURL = [self.directory URLByAppendingPathComponent:IKuuuRequestFileName];
    NSData *data = [NSData dataWithContentsOfURL:requestURL];
    if (!data) return;
    NSError *jsonError = nil;
    id rawRequest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    NSDictionary *request = [rawRequest isKindOfClass:NSDictionary.class] ? rawRequest : @{};
    NSError *validationError = jsonError ?: IKuuuValidateRequest(request, NSDate.date.timeIntervalSince1970);
    NSString *requestID = [request[@"id"] isKindOfClass:NSString.class] ? request[@"id"] : @"invalid";
    [NSFileManager.defaultManager removeItemAtURL:requestURL error:nil];
    if (validationError) {
        [self writeResponse:@{
            @"id": requestID,
            @"success": @NO,
            @"code": @"invalid_request",
            @"message": validationError.localizedDescription,
        }];
        return;
    }
    @synchronized (self) {
        if ([self.lastRequestID isEqualToString:requestID]) {
            [self writeResponse:@{@"id": requestID, @"success": @NO,
                                  @"code": @"duplicate_request", @"message": @"请求已处理"}];
            return;
        }
        self.lastRequestID = requestID;
        self.busy = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *response = [self handleRequest:request];
        [self writeResponse:response];
        @synchronized (self) { self.busy = NO; }
    });
}

- (NSDictionary *)handleRequest:(NSDictionary *)request {
    NSString *requestID = request[@"id"];
    NSString *operation = request[@"operation"];
    NSError *error = nil;
    NSMutableDictionary *response = [@{
        @"id": requestID,
        @"success": @NO,
        @"code": @"action_failed",
        @"message": @"iKuuu 操作失败",
    } mutableCopy];

    if ([operation isEqualToString:@"inspect"]) {
        IKuuuAccessibilityState state = self.adapter.state;
        response[@"success"] = @(state == IKuuuAccessibilityStateReady);
        response[@"code"] = IKuuuCapability(state);
        response[@"message"] = state == IKuuuAccessibilityStateReady ? @"iKuuu 自动切换可用" : @"iKuuu 自动切换尚不可用";
        if (state == IKuuuAccessibilityStateIncompatible) {
            NSError *inspectionError = nil;
            [self.adapter inspectWithError:&inspectionError];
            response[@"message"] = inspectionError.localizedDescription ?: @"未识别到 iKuuu 导航栏，请显示主窗口后重试";
        }
        NSString *current = state == IKuuuAccessibilityStateReady ? [self.adapter currentNodeWithError:nil] : nil;
        if (current) response[@"currentNode"] = current;
        return response;
    }

    if ([operation isEqualToString:@"benchmark"]) {
        NSTimeInterval remaining = [request[@"expiresAt"] doubleValue] - NSDate.date.timeIntervalSince1970;
        NSArray<IKuuuNodeResult *> *nodes = [self.adapter benchmarkWithTimeout:MIN(15, MAX(2, remaining)) error:&error];
        if (nodes) {
            NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:nodes.count];
            for (IKuuuNodeResult *node in nodes) {
                [candidates addObject:@{@"name": node.name, @"delay": @(node.delayMilliseconds)}];
            }
            response[@"success"] = @YES;
            response[@"code"] = @"ok";
            response[@"message"] = @"iKuuu 测速完成";
            response[@"candidates"] = candidates;
            NSString *current = [self.adapter currentNodeWithError:nil];
            if (current) response[@"currentNode"] = current;
            return response;
        }
    } else {
        NSString *node = request[@"node"];
        if ([self.adapter selectNodeNamed:node error:&error]) {
            response[@"success"] = @YES;
            response[@"code"] = @"ok";
            response[@"message"] = [operation isEqualToString:@"restore"] ? @"原节点已恢复" : @"节点已选择";
            response[@"currentNode"] = [self.adapter currentNodeWithError:nil] ?: node;
            return response;
        }
    }

    response[@"code"] = IKuuuErrorCode(error ?: IKuuuProtocolError(@"未知错误"));
    response[@"message"] = error.localizedDescription ?: @"iKuuu 操作失败";
    return response;
}

- (void)writeResponse:(NSDictionary *)response {
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:self.directory
                           withIntermediateDirectories:YES
                                            attributes:@{NSFilePosixPermissions: @0700}
                                                 error:&directoryError];
    if (directoryError) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    NSURL *responseURL = [self.directory URLByAppendingPathComponent:IKuuuResponseFileName];
    [data writeToURL:responseURL options:NSDataWritingAtomic error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
                                    ofItemAtPath:responseURL.path
                                           error:nil];
}

@end
