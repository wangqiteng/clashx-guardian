#import <Foundation/Foundation.h>

// 只解析 codex 额度桶；未知或过期额度绝不当作 0%。
NSDictionary *GuardianUsageSummary(NSDictionary *result, NSTimeInterval now);
NSDictionary *GuardianReadCodexUsage(void);
void GuardianCancelCodexUsage(void);
