#import "IKuuuNodeParser.h"

@implementation IKuuuNodeResult

- (instancetype)initWithName:(NSString *)name delayMilliseconds:(NSInteger)delay {
    self = [super init];
    if (self) {
        _name = [name copy];
        _delayMilliseconds = delay;
    }
    return self;
}

@end

NSArray<IKuuuNodeResult *> *IKuuuParseNodeLabels(NSArray<NSString *> *labels) {
    static NSRegularExpression *delayExpression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delayExpression = [NSRegularExpression regularExpressionWithPattern:@"(?:^|\\n)([1-9][0-9]{0,4})\\s*ms\\s*$"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
    });

    NSMutableArray<IKuuuNodeResult *> *results = [NSMutableArray array];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (id rawLabel in labels) {
        if (![rawLabel isKindOfClass:NSString.class]) continue;
        NSString *label = (NSString *)rawLabel;
        NSTextCheckingResult *match = [delayExpression firstMatchInString:label
                                                                  options:0
                                                                    range:NSMakeRange(0, label.length)];
        if (!match || match.numberOfRanges < 2) continue;
        NSInteger delay = [[label substringWithRange:[match rangeAtIndex:1]] integerValue];
        if (delay <= 0 || delay > 99999) continue;
        NSString *name = [[label substringToIndex:match.range.location]
            stringByTrimmingCharactersInSet:whitespace];
        if (name.length == 0) continue;
        [results addObject:[[IKuuuNodeResult alloc] initWithName:name delayMilliseconds:delay]];
    }
    return results;
}

NSArray<IKuuuNodeResult *> *IKuuuRankNodes(NSArray<IKuuuNodeResult *> *nodes,
                                          NSRegularExpression *exclude) {
    NSMutableArray<IKuuuNodeResult *> *filtered = [NSMutableArray array];
    for (IKuuuNodeResult *node in nodes) {
        if (exclude && [exclude firstMatchInString:node.name
                                           options:0
                                             range:NSMakeRange(0, node.name.length)]) continue;
        [filtered addObject:node];
    }
    return [filtered sortedArrayUsingComparator:^NSComparisonResult(IKuuuNodeResult *left,
                                                                     IKuuuNodeResult *right) {
        if (left.delayMilliseconds < right.delayMilliseconds) return NSOrderedAscending;
        if (left.delayMilliseconds > right.delayMilliseconds) return NSOrderedDescending;
        return [left.name localizedStandardCompare:right.name];
    }];
}
