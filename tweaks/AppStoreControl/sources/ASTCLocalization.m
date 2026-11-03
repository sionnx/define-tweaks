//
//  ASTCLocalization.m
//  AppStoreControl
//

#import "ASTCLocalization.h"

NSString *ASTCLocalized(NSString *english)
{
    static NSDictionary<NSString *, NSString *> *chinese;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chinese = @{
            @"Available Versions" : @"可用版本",
            @"compatible" : @"兼容",
            @"installed" : @"已安装",
        };
    });
    if (![[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"]) {
        return english;
    }
    return chinese[english] ?: english;
}
