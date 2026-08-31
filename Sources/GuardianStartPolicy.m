#import "GuardianStartPolicy.h"

GuardianServiceState GuardianServiceStateFromLaunchctlOutput(NSString *output) {
    if ([output containsString:@"state = running"]) return GuardianServiceStateRunning;
    if ([output containsString:@"state = xpcproxy"] ||
        [output containsString:@"state = spawning"] ||
        [output containsString:@"state = spawn scheduled"]) return GuardianServiceStateStarting;
    if ([output containsString:@"state = not running"] ||
        [output containsString:@"state = exited"]) return GuardianServiceStateIdle;
    return GuardianServiceStateUnknown;
}

GuardianStartAction GuardianStartActionForService(BOOL loaded, GuardianServiceState state) {
    if (!loaded) return GuardianStartActionBootstrap;
    if (state == GuardianServiceStateRunning) return GuardianStartActionComplete;
    if (state == GuardianServiceStateStarting) return GuardianStartActionWait;
    return GuardianStartActionKickstart;
}

NSArray<NSString *> *GuardianNonDestructiveKickstartArguments(NSString *target) {
    return @[@"kickstart", target];
}

NSString *GuardianVisibleSummary(NSString *operationLabel, NSString *statusSummary) {
    if (operationLabel.length) return [@"自动保护：" stringByAppendingString:operationLabel];
    return statusSummary ?: @"";
}

BOOL GuardianDiagnosticLogNeedsRotation(unsigned long long size) {
    return size > 512 * 1024;
}
