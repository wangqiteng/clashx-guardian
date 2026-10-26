#import <Foundation/Foundation.h>
#import "GuardianCodexUsage.h"

int main(void) {
    @autoreleasepool {
        NSDictionary *shortWindow = @{@"usedPercent": @28, @"windowDurationMins": @300, @"resetsAt": @2000};
        NSDictionary *longWindow = @{@"usedPercent": @60, @"windowDurationMins": @10080, @"resetsAt": @3000};
        NSDictionary *bucket = @{@"primary": shortWindow, @"secondary": longWindow};
        NSDictionary *result = GuardianUsageSummary(@{@"rateLimitsByLimitId": @{@"codex": bucket}}, 1000);
        NSCAssert([result[@"remaining"] isEqual:@40], @"use lower remaining window");
        NSCAssert([result[@"windows"] count] == 2, @"keep both windows");
        NSCAssert(!GuardianUsageSummary(@{@"rateLimits": bucket}, 2500), @"expired window invalidates display");
        NSCAssert(!GuardianUsageSummary(@{@"rateLimitsByLimitId": @{@"other": bucket}}, 1000), @"never select unrelated bucket");
        NSCAssert(!GuardianUsageSummary(@{@"rateLimits": NSNull.null}, 1000), @"null is unknown");
        NSCAssert(!GuardianUsageSummary(@{}, 1000), @"missing is unknown");
        NSCAssert([GuardianUsageSummary(@{@"rateLimits": @{@"primary": shortWindow, @"secondary": NSNull.null}}, 1000)[@"remaining"] isEqual:@72], @"single window supported");
        for (id bad in @[@(-1), @101, @YES, @"2", NSNull.null]) {
            NSMutableDictionary *window = [shortWindow mutableCopy]; window[@"usedPercent"] = bad;
            NSCAssert(!GuardianUsageSummary(@{@"rateLimits": @{@"primary": window}}, 1000), @"invalid percent rejected");
        }
        NSMutableDictionary *empty = [shortWindow mutableCopy]; empty[@"usedPercent"] = @100;
        NSCAssert([GuardianUsageSummary(@{@"rateLimits": @{@"primary": empty}}, 1000)[@"remaining"] isEqual:@0], @"zero remains valid");
        puts("guardian_codex_usage_tests_ok=1");
    }
    return 0;
}
