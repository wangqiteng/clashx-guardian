#import <Foundation/Foundation.h>

#import "IKuuuAccessibilityAdapter.h"

NS_ASSUME_NONNULL_BEGIN

NSError * _Nullable IKuuuValidateRequest(NSDictionary *request, NSTimeInterval now);

@interface IKuuuRequestCoordinator : NSObject
@property(nonatomic, copy, readonly) NSString *capabilityLabel;
- (instancetype)initWithDirectory:(NSURL *)directory
                           adapter:(IKuuuAccessibilityAdapter *)adapter NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)pollOnce;
@end

NS_ASSUME_NONNULL_END
