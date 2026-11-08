#import <Cocoa/Cocoa.h>
@interface YoudaoTestDefaults : NSUserDefaults @end
@implementation YoudaoTestDefaults
+ (instancetype)standardUserDefaults {static YoudaoTestDefaults *d;static dispatch_once_t once;dispatch_once(&once,^{d=[[self alloc] initWithSuiteName:@"YoudaoReliabilityIsolatedTests"];[d removePersistentDomainForName:@"YoudaoReliabilityIsolatedTests"];});return d;}
@end
#define NSUserDefaults YoudaoTestDefaults
#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
#undef NSUserDefaults
static NSString *Mode;
static NSUInteger KeyRequests,TranslationRequests;
@interface YoudaoTestTranslator : Translator
@property NSMutableArray<NSString *> *requestedSources;
@end
@implementation YoudaoTestTranslator
- (void)raw:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion {
    [self.requestedSources addObject:source];
    [super raw:text source:source completion:completion];
}
@end
static void Check(BOOL ok,const char *s) {if(!ok){fprintf(stderr,"FAIL: %s\n",s);exit(1);}}
static NSDictionary *Keys(void) {return @{@"secretKey":[NSString stringWithFormat:@"secret-%lu",KeyRequests],@"aesKey":[NSString stringWithFormat:@"key-%lu",KeyRequests],@"aesIv":@"fixture-iv"};}
static NSData *JSON(id o) {return [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];}
static NSData *Encrypted(void) {
    NSData *plain=JSON(@{@"code":@0,@"translateResult":@[@[@{@"tgt":@"可靠的译文"}]]});
    NSData *key=WebMD5Data(Keys()[@"aesKey"]),*iv=WebMD5Data(Keys()[@"aesIv"]);NSMutableData *cipher=[NSMutableData dataWithLength:plain.length+kCCBlockSizeAES128];size_t length=0;
    Check(CCCrypt(kCCEncrypt,kCCAlgorithmAES,kCCOptionPKCS7Padding,key.bytes,key.length,iv.bytes,plain.bytes,plain.length,cipher.mutableBytes,cipher.length,&length)==kCCSuccess,"fixture encryption");cipher.length=length;
    NSString *b64=[cipher base64EncodedStringWithOptions:0];b64=[[b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[@" \n" stringByAppendingFormat:@"%@\n",b64] dataUsingEncoding:NSUTF8StringEncoding];
}
@interface YoudaoFixtureProtocol : NSURLProtocol @end
@implementation YoudaoFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r {return r;}
- (void)startLoading {
    BOOL key=[self.request.URL.path hasSuffix:@"/key"];if(key)KeyRequests++;else TranslationRequests++;
    if([Mode isEqual:@"timeout"]) {[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];return;}
    NSInteger status=(!key&&[Mode isEqual:@"limited"])?429:(!key&&[Mode isEqual:@"forbidden"])?403:200;
    NSData *body=key?JSON(@{@"code":@0,@"data":Keys()}):Encrypted();
    if(key&&[Mode isEqual:@"bad-key"])body=JSON(@{@"code":@0,@"data":@{@"secretKey":@"x"}});
    if(!key&&([Mode isEqual:@"always-bad"]||([Mode isEqual:@"refresh"]&&TranslationRequests==1)))body=[@"invalid encrypted payload" dataUsingEncoding:NSUTF8StringEncoding];
    if(!key&&[Mode isEqual:@"business"])body=JSON(@{@"code":@(-2),@"msg":@"upstream rejection"});
    if (!key && ([Mode isEqual:@"language-unsupported"] ||
        ([Mode hasPrefix:@"language-"] && TranslationRequests == 1))) body = JSON(@{@"code":@40});
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After":@"180"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];[self.client URLProtocol:self didLoadData:body];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static YoudaoTestTranslator *Create(NSString *mode) {
    Mode=mode;KeyRequests=TranslationRequests=0;YoudaoTestTranslator *t=[YoudaoTestTranslator new];t.provider=@"youdao";
    t.requestedSources = [NSMutableArray new];
    NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.protocolClasses=@[YoudaoFixtureProtocol.class];t.session=[NSURLSession sessionWithConfiguration:c];return t;
}
static void Await(BOOL (^done)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!done()&&end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    Check(done(),"completion must arrive");
}
static NSError *Run(Translator *t,NSString *text,BOOL success) {
    __block BOOL done=NO;__block NSError *error=nil;
    [t raw:text source:@"en" completion:^(NSString *result,NSError *e){error=e;Check(success?(result.length&&!e):(!result&&e),"expected result/error");done=YES;}];
    Await(^BOOL{ return done; });
    return error;
}
static void TestLanguage(NSString *mode, NSString *text, NSString *expected, BOOL partial, NSArray<NSString *> *sources) {
    YoudaoTestTranslator *t = Create(mode);
    __block BOOL done = NO;
    [t translate:text completion:^(NSString *result, NSError *error) {
        Check(expected ? [result isEqualToString:expected] : !result, "expected full, partial or unavailable translation");
        Check(partial || !expected ? YoudaoUnsupportedLanguage(error) : !error, "unsupported-language error retained only when needed");
        done = YES;
    }];
    Await(^BOOL{ return done; });
    if (KeyRequests != 1 || TranslationRequests != sources.count)
        fprintf(stderr, "%s: %lu key requests and %lu translation requests (expected 1 and %lu)\n",
            mode.UTF8String, (unsigned long)KeyRequests, (unsigned long)TranslationRequests, (unsigned long)sources.count);
    Check(KeyRequests == 1 && TranslationRequests == sources.count, "language recovery uses bounded requests without refreshing the key");
    Check([t.requestedSources isEqualToArray:sources], "retry changes the requested source language");
}
int main(void) {@autoreleasepool{
    NSData *layout = JSON(@{@"code": @0, @"translateResult": @[
        @[@{@"tgt": @"# 标题"}],
        @[@{@"tgt": @"1. 第一项。"}, @{@"tgt": @"另一句。"}],
        @[@{@"tgt": @"- 子项。"}]
    ]});
    NSString *sourceLayout = @"# Heading\n\n1. First item. Another sentence.\n    - Nested item.";
    NSString *decodedLayout = YoudaoDecodeResult(layout, nil, sourceLayout, NULL);
    Check([MatchSourceLayout(sourceLayout, decodedLayout) isEqualToString:@"# 标题\n\n1. 第一项。另一句。\n    - 子项。"],
          "Youdao paragraph groups retain line breaks, original blank lines and indentation");
    Translator *t=Create(@"refresh");Run(t,@"hello",YES);Check(KeyRequests==2&&TranslationRequests==2,"bad encryption refreshes exactly once and recovers");
    Run(t,@"hello",YES);Check(KeyRequests==2&&TranslationRequests==2,"successful fragments are cached");
    Mode=@"success";Run(t,@"next fragment",YES);Check(KeyRequests==2&&TranslationRequests==3,"mixed-language spans reuse current operation keys");
    [t cancel];Run(t,@"new selection",YES);Check(KeyRequests==2&&TranslationRequests==4,"new selection reuses a recent session key after cancellation");
    t.youdaoKeyDate=[NSDate dateWithTimeIntervalSinceNow:-31];
    [t cancel];Run(t,@"after key expiry",YES);Check(KeyRequests==3&&TranslationRequests==5,"expired keys must be refreshed for new text");
    t.targetLanguage=@"en";Run(t,@"hello",YES);Check(KeyRequests==3&&TranslationRequests==6,"translation cache must be target scoped and the session key can still be reused");
    t=Create(@"always-bad");NSError *error=Run(t,@"bad",NO);Check([error.domain isEqual:@"Translation.Youdao.Decode"]&&KeyRequests==2&&TranslationRequests==2,"failed refresh must terminate without a retry loop");
    t=Create(@"business");error=Run(t,@"denied",NO);Check(error.code==-2&&[error.domain isEqual:@"Translation.Youdao"]&&KeyRequests==1&&TranslationRequests==1,"upstream rejection preserves code and never triggers key retry");
    TestLanguage(@"language-auto", @"This sentence is written in English.", @"可靠的译文", NO, @[@"auto", @"en"]);
    TestLanguage(@"language-explicit", @"中文 안녕하세요", @"中文 可靠的译文", NO, @[@"ko", @"auto"]);
    TestLanguage(@"language-partial", @"中文 გამარჯობა / Hello world", @"中文 გამარჯობა / 可靠的译文", YES, @[@"auto", @"auto"]);
    TestLanguage(@"language-unsupported", @"中文 გამარჯობა", nil, NO, @[@"auto"]);
    t=Create(@"limited");error=Run(t,@"limited",NO);Check(error.code==429&&KeyRequests==1&&TranslationRequests==1,"429 never refreshes keys");Run(t,@"later",NO);Check(KeyRequests==1&&TranslationRequests==1&&t.youdaoRetryDate.timeIntervalSinceNow>175,"cooldown prevents further network requests");
    t=Create(@"forbidden");error=Run(t,@"forbidden",NO);Check(error.code==403&&KeyRequests==1&&TranslationRequests==1,"HTTP denial must not loop");
    t=Create(@"bad-key");Run(t,@"bad-key",NO);Check(KeyRequests==1&&!TranslationRequests,"incomplete keys never reach translation endpoint");
    t=Create(@"timeout");error=Run(t,@"timeout",NO);Check(error.code==NSURLErrorTimedOut&&[error.localizedDescription containsString:@"超时"]&&KeyRequests==1,"timeout is actionable without retries");
    t=Create(@"success");t.nextYoudaoRequest=NSProcessInfo.processInfo.systemUptime+.1;__block BOOL cancelled=NO;
    [t raw:@"cancelled" source:@"auto" completion:^(NSString *s,NSError *e){cancelled=e.code==NSURLErrorCancelled;}];[t cancel];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.3];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    Check(cancelled&&!KeyRequests&&!TranslationRequests,"cancelled queued work must complete without sending a request");
    [YoudaoTestDefaults.standardUserDefaults removePersistentDomainForName:@"YoudaoReliabilityIsolatedTests"];
    puts("PASS: encrypted responses, one-shot key recovery, short-lived session key reuse, fragment cache, cancellation guard, HTTP/business errors, cooldown and timeout; no live traffic or user settings changed.");
}return 0;}
