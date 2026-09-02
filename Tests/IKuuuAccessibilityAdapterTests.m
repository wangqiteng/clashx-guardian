#import <Foundation/Foundation.h>

#import "IKuuuAccessibilityAdapter.h"

static void TestRequiresServerSemantics(void) {
    NSError *error = nil;
    IKuuuAXSnapshot *valid = [[IKuuuAXSnapshot alloc] initWithStrings:@[
        @"服务器", @"🔰 选择节点", @"🇭🇰 香港Y03 | IEPL\n45 ms", @"🇯🇵 日本Y01 | IEPL\n135 ms"
    ]];
    NSArray<IKuuuNodeResult *> *nodes = IKuuuNodesFromSnapshot(valid, &error);
    NSCAssert(error == nil && nodes.count == 2, @"合法服务器结构应返回节点");

    error = nil;
    IKuuuAXSnapshot *invalid = [[IKuuuAXSnapshot alloc] initWithStrings:@[
        @"主页", @"🇭🇰 香港Y03 | IEPL\n45 ms", @"🇯🇵 日本Y01 | IEPL\n135 ms"
    ]];
    NSCAssert(IKuuuNodesFromSnapshot(invalid, &error) == nil, @"缺少服务器语义时必须拒绝");
    NSCAssert(error.code == IKuuuAccessibilityErrorIncompatible, @"应报告版本不兼容");
}

static void TestRequiresAtLeastTwoMeasuredNodes(void) {
    NSError *error = nil;
    IKuuuAXSnapshot *snapshot = [[IKuuuAXSnapshot alloc] initWithStrings:@[
        @"服务器", @"选择节点", @"🇭🇰 香港Y03 | IEPL\n45 ms", @"🇯🇵 日本Y01\n超时"
    ]];
    NSCAssert(IKuuuNodesFromSnapshot(snapshot, &error) == nil, @"单个可测节点不足以安全操作");
    NSCAssert(error.code == IKuuuAccessibilityErrorInsufficientNodes, @"应报告候选不足");
}

static void TestCompatibleStructureDoesNotRequirePreviousMeasurements(void) {
    IKuuuAXSnapshot *fresh = [[IKuuuAXSnapshot alloc] initWithStrings:@[
        @"服务器", @"选择节点", @"🇭🇰 香港Y03 | IEPL", @"🇯🇵 日本Y01 | IEPL"
    ]];
    NSCAssert(IKuuuSnapshotHasServerSemantics(fresh), @"首次测速前只要结构完整就应兼容");
    IKuuuAXSnapshot *wrongPage = [[IKuuuAXSnapshot alloc] initWithStrings:@[@"主页", @"我的"]];
    NSCAssert(!IKuuuSnapshotHasServerSemantics(wrongPage), @"错误页面不能通过结构检查");
}

static void TestStableSamplesNeedConsecutiveAgreement(void) {
    NSCAssert(IKuuuDelaySamplesAreStable(@[
        @[@45, @135], @[@45, @135]
    ], 2), @"连续两次相同结果应稳定");
    NSCAssert(!IKuuuDelaySamplesAreStable(@[
        @[@45, @135], @[@57, @135]
    ], 2), @"仍在变化的结果不可用于切换");
    NSCAssert(!IKuuuDelaySamplesAreStable(@[@[@45, @135]], 2), @"样本不足不可视为稳定");
}

static void TestSelectionConfirmationAllowsHeaderShortName(void) {
    NSCAssert(IKuuuSelectionMatches(@"🇭🇰 香港Y03", @"🇭🇰 香港Y03 | IEPL"), @"顶部短名应允许前缀确认");
    NSCAssert(!IKuuuSelectionMatches(@"🇭🇰 香港Y04", @"🇭🇰 香港Y03 | IEPL"), @"不同节点不得误判成功");
}

int main(void) {
    @autoreleasepool {
        TestRequiresServerSemantics();
        TestRequiresAtLeastTwoMeasuredNodes();
        TestCompatibleStructureDoesNotRequirePreviousMeasurements();
        TestStableSamplesNeedConsecutiveAgreement();
        TestSelectionConfirmationAllowsHeaderShortName();
        puts("ikuuu_accessibility_adapter_tests_ok=1");
    }
    return 0;
}
