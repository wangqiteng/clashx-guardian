#import <Foundation/Foundation.h>

#import "IKuuuNodeParser.h"

static void TestParsesOnlyMeasuredNodes(void) {
    NSArray<IKuuuNodeResult *> *nodes = IKuuuParseNodeLabels(@[
        @"🇭🇰 香港Y03 | IEPL\n45 ms",
        @"🇯🇵 日本Y01 | IEPL\n135 ms",
        @"🇭🇰 香港Y01\n超时",
        @"🔰 选择节点",
        @"DIRECT\n0 ms",
    ]);

    NSCAssert(nodes.count == 2, @"只应保留明确且大于零的毫秒结果");
    NSCAssert([nodes[0].name isEqualToString:@"🇭🇰 香港Y03 | IEPL"], @"应保留完整节点名");
    NSCAssert(nodes[0].delayMilliseconds == 45, @"应解析毫秒延迟");
}

static void TestRanksByCurrentDelayThenName(void) {
    NSArray<IKuuuNodeResult *> *ranked = IKuuuRankNodes(IKuuuParseNodeLabels(@[
        @"节点 B\n57 ms",
        @"节点 C\n45 ms",
        @"节点 A\n45 ms",
    ]), nil);

    NSCAssert(ranked.count == 3, @"应保留三个合法节点");
    NSCAssert([ranked[0].name isEqualToString:@"节点 A"], @"同延迟时按名称稳定排序");
    NSCAssert([ranked[1].name isEqualToString:@"节点 C"], @"最低延迟应排在前面");
    NSCAssert(ranked[2].delayMilliseconds == 57, @"较慢节点应排在最后");
}

static void TestExcludesSpecialRoutes(void) {
    NSRegularExpression *exclude = [NSRegularExpression regularExpressionWithPattern:@"^(?:DIRECT|REJECT)$"
                                                                               options:NSRegularExpressionCaseInsensitive
                                                                                 error:nil];
    NSArray<IKuuuNodeResult *> *ranked = IKuuuRankNodes(IKuuuParseNodeLabels(@[
        @"DIRECT\n1 ms",
        @"香港 Y01\n30 ms",
        @"REJECT\n2 ms",
    ]), exclude);

    NSCAssert(ranked.count == 1, @"应排除特殊路由");
    NSCAssert([ranked[0].name isEqualToString:@"香港 Y01"], @"应保留普通节点");
}

int main(void) {
    @autoreleasepool {
        TestParsesOnlyMeasuredNodes();
        TestRanksByCurrentDelayThenName();
        TestExcludesSpecialRoutes();
        puts("ikuuu_node_parser_tests_ok=1");
    }
    return 0;
}
