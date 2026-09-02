#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IKuuuNodeResult : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) NSInteger delayMilliseconds;
- (instancetype)initWithName:(NSString *)name delayMilliseconds:(NSInteger)delay NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// 从辅助功能标签中提取本次有明确延迟结果的节点。
NSArray<IKuuuNodeResult *> *IKuuuParseNodeLabels(NSArray<NSString *> *labels);

/// 排除特殊路由后按本次延迟排序，同延迟使用名称保持结果稳定。
NSArray<IKuuuNodeResult *> *IKuuuRankNodes(NSArray<IKuuuNodeResult *> *nodes,
                                          NSRegularExpression * _Nullable exclude);

NS_ASSUME_NONNULL_END
