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
    NSCAssert(!IKuuuSelectionMatches(@"日本Y01", @"日本Y010"), @"公共前缀不能确认另一个节点");
    NSCAssert(IKuuuSelectionMatches(@"🇭🇰 香港Y03", @"🇭🇰 香港Y03 | IEPL"), @"顶部短名应允许前缀确认");
    NSCAssert(!IKuuuSelectionMatches(@"🇭🇰 香港Y04", @"🇭🇰 香港Y03 | IEPL"), @"不同节点不得误判成功");
}

int main(void) {
    @autoreleasepool {
        NSArray *toolbarFrames = @[
            [NSValue valueWithRect:NSMakeRect(670, 8, 32, 32)],
            [NSValue valueWithRect:NSMakeRect(710, 8, 32, 32)],
            [NSValue valueWithRect:NSMakeRect(687, 82, 32, 32)],
            [NSValue valueWithRect:NSMakeRect(686, 536, 48, 48)]
        ];
        NSRect window = NSMakeRect(0, 0, 750, 600);
        NSCAssert(IKuuuBenchmarkFrameIndex(toolbarFrames, window) == 3, @"必须点击实测确认的右下角测速按钮");
        NSCAssert(IKuuuBenchmarkFrameIndex(@[toolbarFrames[0]], window) == NSNotFound, @"顶部刷新按钮不能当测速");
        NSCAssert(IKuuuBenchmarkFrameIndex(@[toolbarFrames[3], toolbarFrames[3]], window) == NSNotFound, @"有多义按钮不可点击");
        NSString *preferred = IKuuuPreferredText(@[@"日本Y01", @"日本Y01\n99 ms"]);
        NSCAssert([preferred isEqualToString:@"日本Y01\n99 ms"], @"同一控件的标题和详细描述不能重复拼接");
        NSArray *deduplicated = IKuuuParseNodeLabels(@[@"节点 A\n42 ms", @"节点 A\n42 ms", @"容器\n节点 B\n43 ms"]);
        NSCAssert(deduplicated.count == 1, @"容器聚合文本和重复标签不能产生虚假候选");
        IKuuuAXSnapshot *home = [[IKuuuAXSnapshot alloc] initWithStrings:@[
            @"主页\n第 1 个标签，共 3 个", @"服务器\n第 2 个标签，共 3 个", @"我的\n第 3 个标签，共 3 个",
            @"当前节点\n🇯🇵 日本Y01 | IEPL\n99 ms\n7.7KB\n1.3MB"
        ]];
        NSCAssert(IKuuuSnapshotHasNavigation(home), @"主页必须被识别为支持的客户端");
        NSCAssert(!IKuuuSnapshotHasServerSemantics(home), @"主页不能被误认为节点列表");
        NSCAssert([IKuuuCurrentNodeFromLabels(home.strings) isEqualToString:@"🇯🇵 日本Y01 | IEPL"], @"主页应读出节点而非流量或延迟");
        NSCAssert(!IKuuuSnapshotHasNavigation([[IKuuuAXSnapshot alloc] initWithStrings:@[@"服务器"]]), @"残缺页面不可自动导航");
        TestRequiresServerSemantics();
        TestRequiresAtLeastTwoMeasuredNodes();
        TestCompatibleStructureDoesNotRequirePreviousMeasurements();
        TestStableSamplesNeedConsecutiveAgreement();
        TestSelectionConfirmationAllowsHeaderShortName();
        puts("ikuuu_accessibility_adapter_tests_ok=1");
    }
    return 0;
}
