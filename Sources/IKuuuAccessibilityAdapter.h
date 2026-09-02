#import <Cocoa/Cocoa.h>

#import "IKuuuNodeParser.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const IKuuuAccessibilityErrorDomain;

typedef NS_ERROR_ENUM(IKuuuAccessibilityErrorDomain, IKuuuAccessibilityError) {
    IKuuuAccessibilityErrorClientNotRunning = 1,
    IKuuuAccessibilityErrorPermissionRequired = 2,
    IKuuuAccessibilityErrorIncompatible = 3,
    IKuuuAccessibilityErrorInsufficientNodes = 4,
    IKuuuAccessibilityErrorTimeout = 5,
    IKuuuAccessibilityErrorActionFailed = 6,
};

typedef NS_ENUM(NSInteger, IKuuuAccessibilityState) {
    IKuuuAccessibilityStateClientNotRunning,
    IKuuuAccessibilityStatePermissionRequired,
    IKuuuAccessibilityStateReady,
    IKuuuAccessibilityStateIncompatible,
};

@interface IKuuuAXSnapshot : NSObject
@property(nonatomic, copy, readonly) NSArray<NSString *> *strings;
- (instancetype)initWithStrings:(NSArray<NSString *> *)strings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NSArray<IKuuuNodeResult *> * _Nullable IKuuuNodesFromSnapshot(IKuuuAXSnapshot *snapshot,
                                                               NSError **error);
BOOL IKuuuDelaySamplesAreStable(NSArray<NSArray<NSNumber *> *> *samples, NSInteger requiredCount);
BOOL IKuuuSelectionMatches(NSString *currentNode, NSString *targetNode);

@interface IKuuuAccessibilityAdapter : NSObject
- (IKuuuAccessibilityState)state;
- (void)requestAccessibilityPermission;
- (IKuuuAXSnapshot * _Nullable)inspectWithError:(NSError **)error;
- (NSArray<IKuuuNodeResult *> * _Nullable)benchmarkWithTimeout:(NSTimeInterval)timeout
                                                          error:(NSError **)error;
- (BOOL)selectNodeNamed:(NSString *)name error:(NSError **)error;
- (NSString * _Nullable)currentNodeWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
