#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, GuardianServiceState) {
    GuardianServiceStateUnknown,
    GuardianServiceStateIdle,
    GuardianServiceStateStarting,
    GuardianServiceStateRunning,
};

typedef NS_ENUM(NSInteger, GuardianStartAction) {
    GuardianStartActionBootstrap,
    GuardianStartActionKickstart,
    GuardianStartActionWait,
    GuardianStartActionComplete,
};

GuardianServiceState GuardianServiceStateFromLaunchctlOutput(NSString *output);
GuardianStartAction GuardianStartActionForService(BOOL loaded, GuardianServiceState state);
NSArray<NSString *> *GuardianNonDestructiveKickstartArguments(NSString *target);
NSString *GuardianVisibleSummary(NSString *operationLabel, NSString *statusSummary);
BOOL GuardianDiagnosticLogNeedsRotation(unsigned long long size);
