#import "../Sources/GuardianStartPolicy.h"

static void Require(BOOL condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "start policy test failed: %s\n", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        Require(GuardianServiceStateFromLaunchctlOutput(@"state = xpcproxy\n") == GuardianServiceStateStarting,
                "xpcproxy must be treated as an in-progress launch");
        Require(GuardianServiceStateFromLaunchctlOutput(@"state = spawning\n") == GuardianServiceStateStarting,
                "spawning must be treated as an in-progress launch");
        Require(GuardianServiceStateFromLaunchctlOutput(@"state = running\n") == GuardianServiceStateRunning,
                "running service must be recognized");
        Require(GuardianServiceStateFromLaunchctlOutput(@"state = not running\n") == GuardianServiceStateIdle,
                "loaded inactive service must be recognized");

        Require(GuardianStartActionForService(NO, GuardianServiceStateUnknown) == GuardianStartActionBootstrap,
                "an unloaded service must be bootstrapped");
        Require(GuardianStartActionForService(YES, GuardianServiceStateStarting) == GuardianStartActionWait,
                "an in-progress launch must never be restarted");
        Require(GuardianStartActionForService(YES, GuardianServiceStateIdle) == GuardianStartActionKickstart,
                "an idle loaded service needs one non-destructive kickstart");
        Require(GuardianStartActionForService(YES, GuardianServiceStateRunning) == GuardianStartActionComplete,
                "a running service needs no launch command");

        NSArray<NSString *> *arguments = GuardianNonDestructiveKickstartArguments(@"gui/501/example");
        Require([arguments isEqualToArray:@[@"kickstart", @"gui/501/example"]],
                "normal start must never include the destructive -k option");
        Require([GuardianVisibleSummary(@"正在开启…（最长等待 120 秒）", @"自动保护：已暂停")
                    isEqualToString:@"自动保护：正在开启…（最长等待 120 秒）"],
                "an in-progress launch must remain visible during status refreshes");
        Require([GuardianVisibleSummary(nil, @"自动保护：网络正常")
                    isEqualToString:@"自动保护：网络正常"],
                "normal status must be shown when no launch is in progress");
        Require(!GuardianDiagnosticLogNeedsRotation(512 * 1024),
                "a diagnostic log at the size limit must be retained");
        Require(GuardianDiagnosticLogNeedsRotation(512 * 1024 + 1),
                "an oversized diagnostic log must be rotated");
        printf("start_policy_tests_ok=1\n");
    }
    return 0;
}
