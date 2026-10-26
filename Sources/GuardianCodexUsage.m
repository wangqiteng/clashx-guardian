#import "GuardianCodexUsage.h"
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <math.h>

static NSTask *usageTask;
static BOOL usageStopped;

NSDictionary *GuardianUsageSummary(NSDictionary *result, NSTimeInterval now) {
    if (![result isKindOfClass:NSDictionary.class]) return nil;
    id buckets = result[@"rateLimitsByLimitId"];
    id bucket = [buckets isKindOfClass:NSDictionary.class] ? buckets[@"codex"] : result[@"rateLimits"];
    if (![bucket isKindOfClass:NSDictionary.class]) return nil;
    if ([bucket[@"limitId"] isKindOfClass:NSString.class] && ![bucket[@"limitId"] isEqual:@"codex"]) return nil;
    NSMutableArray *windows = [NSMutableArray array];
    double remaining = 100;
    for (NSString *key in @[@"primary", @"secondary"]) {
        id window = bucket[key];
        if (!window || window == NSNull.null) continue;
        if (![window isKindOfClass:NSDictionary.class]) return nil;
        for (NSString *field in @[@"usedPercent", @"windowDurationMins", @"resetsAt"])
            if (![window[field] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)window[field]) == CFBooleanGetTypeID()) return nil;
        double used = [window[@"usedPercent"] doubleValue];
        double duration = [window[@"windowDurationMins"] doubleValue];
        double reset = [window[@"resetsAt"] doubleValue];
        if (!isfinite(used) || used < 0 || used > 100 || !isfinite(duration) || duration <= 0 || !isfinite(reset) || reset <= now) return nil;
        remaining = MIN(remaining, 100 - used);
        [windows addObject:@{@"remaining": @(floor(100-used)), @"minutes": @(duration), @"reset": @(reset)}];
    }
    if (!windows.count) return nil;
    return @{@"remaining": @(floor(remaining)), @"windows": windows};
}

static void SendMessage(NSFileHandle *handle, NSDictionary *message) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    [handle writeData:data];
}

void GuardianCancelCodexUsage(void) {
    @synchronized(NSTask.class) {
        usageStopped = YES;
        if (usageTask.running) [usageTask terminate];
    }
}

NSDictionary *GuardianReadCodexUsage(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *home = manager.homeDirectoryForCurrentUser.path;
    NSArray *paths = @[@"/usr/local/bin/codex", @"/opt/homebrew/bin/codex",
        @"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        [home stringByAppendingPathComponent:@"Applications/Codex.app/Contents/Resources/codex"],
        [home stringByAppendingPathComponent:@"Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]];
    NSString *executable = nil;
    for (NSString *path in paths) if ([manager isExecutableFileAtPath:path]) { executable = path; break; }
    if (!executable) return @{@"error": @"未找到 Codex CLI，请先安装并登录 Codex"};
    NSTask *task = [NSTask new];
    NSPipe *input = NSPipe.pipe, *output = NSPipe.pipe;
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"app-server"];
    task.standardInput = input; task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    // GUI 没有终端的 PATH；补齐常见 Node 安装目录以支持 npm 的 CLI 启动器。
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    task.environment = environment;
    task.currentDirectoryURL = manager.homeDirectoryForCurrentUser;
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *answer = nil;
    @try {
        @synchronized(NSTask.class) {
            if (usageStopped) return @{@"error": @"用量读取已停止"};
            usageTask = task;
            NSError *error = nil;
            if (![task launchAndReturnError:&error]) { usageTask = nil; return @{@"error": @"无法启动 Codex 用量读取进程"}; }
        }
        fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);
        SendMessage(input.fileHandleForWriting, @{@"id": @1, @"method": @"initialize",
            @"params": @{@"clientInfo": @{@"name": @"guardian_usage", @"version": @"2.5.0"}}});
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 20;
        BOOL initialized = NO;
        while (task.running && NSProcessInfo.processInfo.systemUptime < deadline && !answer) {
            struct pollfd fd = {output.fileHandleForReading.fileDescriptor, POLLIN, 0};
            if (poll(&fd, 1, 200) <= 0) continue;
            char bytes[8192]; ssize_t count = read(fd.fd, bytes, sizeof(bytes));
            if (count <= 0) break;
            [buffer appendBytes:bytes length:(NSUInteger)count];
            if (buffer.length > 1024 * 1024) break;
            while (buffer.length) {
                NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buffer.length)];
                if (newline.location == NSNotFound) break;
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
                [buffer replaceBytesInRange:NSMakeRange(0, newline.location+1) withBytes:NULL length:0];
                id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if (![message isKindOfClass:NSDictionary.class]) continue;
                if ([message[@"id"] isEqual:@1] && !initialized) {
                    if (message[@"error"]) { answer = @{@"error": @"Codex 初始化失败，请更新 CLI"}; break; }
                    initialized = YES;
                    SendMessage(input.fileHandleForWriting, @{@"method": @"initialized"});
                    SendMessage(input.fileHandleForWriting, @{@"id": @2, @"method": @"account/rateLimits/read"});
                } else if ([message[@"id"] isEqual:@2]) {
                    answer = GuardianUsageSummary(message[@"result"], NSDate.date.timeIntervalSince1970)
                        ?: @{@"error": @"额度不可用，请检查 Codex 登录、网络或账号额度类型"};
                    break;
                }
            }
        }
    } @catch (__unused NSException *exception) {
        answer = @{@"error": @"Codex 用量读取中断"};
    } @finally {
        [input.fileHandleForWriting closeFile];
        if (task.running) [task terminate];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 1;
        while (task.running && NSProcessInfo.processInfo.systemUptime < deadline) usleep(10000);
        if (task.running) kill(task.processIdentifier, SIGKILL);
        if (task.processIdentifier > 0) [task waitUntilExit];
        [output.fileHandleForReading closeFile];
        @synchronized(NSTask.class) { if (usageTask == task) usageTask = nil; }
    }
    return answer ?: @{@"error": @"Codex 用量读取超时，将在下次刷新重试"};
}
