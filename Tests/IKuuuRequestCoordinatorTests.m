#import <Foundation/Foundation.h>

#import "IKuuuRequestCoordinator.h"

@interface FakeIKuuuAdapter : IKuuuAccessibilityAdapter
@property(nonatomic) IKuuuAccessibilityState fakeState;
@property(nonatomic, copy) NSString *selectedNode;
@end

@implementation FakeIKuuuAdapter
- (IKuuuAccessibilityState)state { return self.fakeState; }
- (NSArray<IKuuuNodeResult *> *)benchmarkWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    (void)timeout; (void)error;
    return @[
        [[IKuuuNodeResult alloc] initWithName:@"香港 Y03" delayMilliseconds:45],
        [[IKuuuNodeResult alloc] initWithName:@"日本 Y01" delayMilliseconds:135],
    ];
}
- (BOOL)selectNodeNamed:(NSString *)name error:(NSError **)error {
    (void)error;
    self.selectedNode = name;
    return YES;
}
- (NSString *)currentNodeWithError:(NSError **)error { (void)error; return self.selectedNode ?: @"香港 Y01"; }
@end

static NSURL *TemporaryDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    NSCAssert([NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error], @"创建临时目录失败：%@", error);
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static void WriteRequest(NSURL *directory, NSDictionary *request) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSURL *url = [directory URLByAppendingPathComponent:@"ikuuu-request.json"];
    NSCAssert([data writeToURL:url options:NSDataWritingAtomic error:nil], @"写入请求失败");
}

static NSDictionary *WaitForResponse(NSURL *directory) {
    NSURL *url = [directory URLByAppendingPathComponent:@"ikuuu-response.json"];
    for (NSInteger attempt = 0; attempt < 50; attempt++) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data) return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        [NSThread sleepForTimeInterval:0.02];
    }
    return nil;
}

static void TestValidatesRequestEnvelope(void) {
    NSTimeInterval future = NSDate.date.timeIntervalSince1970 + 30;
    NSDictionary *valid = @{@"id": @"request-1", @"operation": @"benchmark", @"expiresAt": @(future)};
    NSCAssert(IKuuuValidateRequest(valid, NSDate.date.timeIntervalSince1970) == nil, @"合法请求应通过");
    NSCAssert(IKuuuValidateRequest(@{@"operation": @"select"}, NSDate.date.timeIntervalSince1970) != nil,
              @"缺少请求 ID 必须拒绝");
    NSCAssert(IKuuuValidateRequest(@{@"id": @"x", @"operation": @"unknown", @"expiresAt": @(future)},
                                  NSDate.date.timeIntervalSince1970) != nil,
              @"未知操作必须拒绝");
    NSCAssert(IKuuuValidateRequest(@{@"id": @"x", @"operation": @"inspect", @"expiresAt": @1},
                                  NSDate.date.timeIntervalSince1970) != nil,
              @"过期请求必须拒绝");
}

static void TestBenchmarkProducesAtomicResponse(void) {
    NSURL *directory = TemporaryDirectory();
    FakeIKuuuAdapter *adapter = [FakeIKuuuAdapter new];
    adapter.fakeState = IKuuuAccessibilityStateReady;
    IKuuuRequestCoordinator *coordinator = [[IKuuuRequestCoordinator alloc] initWithDirectory:directory adapter:adapter];
    WriteRequest(directory, @{
        @"id": @"benchmark-1",
        @"operation": @"benchmark",
        @"expiresAt": @(NSDate.date.timeIntervalSince1970 + 30),
    });

    [coordinator pollOnce];
    NSDictionary *response = WaitForResponse(directory);
    NSCAssert([response[@"id"] isEqualToString:@"benchmark-1"], @"响应必须匹配请求 ID");
    NSCAssert([response[@"success"] boolValue], @"测速响应应成功");
    NSArray *candidates = response[@"candidates"];
    NSCAssert(candidates.count == 2, @"应返回两个候选");
    NSCAssert([candidates[0][@"delay"] integerValue] == 45, @"应保留延迟排序");
}

static void TestSelectReturnsConfirmedNode(void) {
    NSURL *directory = TemporaryDirectory();
    FakeIKuuuAdapter *adapter = [FakeIKuuuAdapter new];
    adapter.fakeState = IKuuuAccessibilityStateReady;
    IKuuuRequestCoordinator *coordinator = [[IKuuuRequestCoordinator alloc] initWithDirectory:directory adapter:adapter];
    WriteRequest(directory, @{
        @"id": @"select-1",
        @"operation": @"select",
        @"node": @"香港 Y03",
        @"expiresAt": @(NSDate.date.timeIntervalSince1970 + 30),
    });

    [coordinator pollOnce];
    NSDictionary *response = WaitForResponse(directory);
    NSCAssert([response[@"success"] boolValue], @"选择响应应成功");
    NSCAssert([response[@"currentNode"] isEqualToString:@"香港 Y03"], @"响应必须包含已确认节点");
}

int main(void) {
    @autoreleasepool {
        TestValidatesRequestEnvelope();
        TestBenchmarkProducesAtomicResponse();
        TestSelectReturnsConfirmedNode();
        puts("ikuuu_request_coordinator_tests_ok=1");
    }
    return 0;
}
