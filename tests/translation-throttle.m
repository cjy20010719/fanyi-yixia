#import <Cocoa/Cocoa.h>
@interface ThrottleDefaults : NSUserDefaults @end
@implementation ThrottleDefaults
+ (instancetype)standardUserDefaults { static ThrottleDefaults *value;static dispatch_once_t once;dispatch_once(&once,^{value=[[self alloc] initWithSuiteName:@"TranslationThrottleIsolatedTests"];[value removePersistentDomainForName:@"TranslationThrottleIsolatedTests"];});return value; }
@end
#define NSUserDefaults ThrottleDefaults
#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
#undef NSUserDefaults

static NSMutableArray<NSNumber *> *Starts;
static BOOL UsedWebContract=YES;
@interface ThrottleProtocol : NSURLProtocol @end
@implementation ThrottleProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)startLoading {
    @synchronized(Starts) {[Starts addObject:@(NSProcessInfo.processInfo.systemUptime)];}
    NSURLComponents *url=[NSURLComponents componentsWithURL:self.request.URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary *params=[NSMutableDictionary new];for(NSURLQueryItem *q in url.queryItems)params[q.name]=q.value;
    UsedWebContract=UsedWebContract&&[url.host isEqual:@"translate.google.com"]&&[params[@"dj"] isEqual:@"1"]&&[params[@"ie"] isEqual:@"UTF-8"]&&[[params.allKeys sortedArrayUsingSelector:@selector(compare:)] isEqualToArray:[url.queryItems valueForKey:@"name"]]&&[[self.request valueForHTTPHeaderField:@"User-Agent"] containsString:@"Mozilla/5.0"];
    BOOL limited=[self.request.URL.absoluteString containsString:@"q=limited"];
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:limited?429:200 HTTPVersion:@"HTTP/1.1" headerFields:limited?@{@"Retry-After":@"180"}:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSArray *sentences = [params[@"q"] hasPrefix:@"# Heading"] ? @[
        @{@"orig": @"# Heading\n\n", @"trans": @"# 标题"},
        @{@"orig": @"1. First item. ", @"trans": @"1. 第一项。"},
        @{@"orig": @"Another sentence.\n", @"trans": @"另一句。"},
        @{@"orig": @"    - Nested item.", @"trans": @"- 子项。"}
    ] : @[@{@"trans":@"译"}, @{@"trans":@"文"}];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:@{@"sentences":sentences} options:0 error:NULL]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static void Check(BOOL ok,const char *message) {if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
static void Spin(double seconds) {NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}
static NSUInteger Count(void) {@synchronized(Starts){return Starts.count;}}
static Translator *Create(void) {
    Translator *t=[Translator new];t.provider=@"google";
    NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.protocolClasses=@[ThrottleProtocol.class];t.session=[NSURLSession sessionWithConfiguration:c];return t;
}
int main(void) {@autoreleasepool{
    Starts=[NSMutableArray new];Translator *t=Create();__block NSUInteger done=0;
    TranslationCompletion ok=^(NSString *s,NSError *e){Check([s isEqual:@"译文"]&&!e,"structured web response must join translated segments");done++;};
    [t raw:@"hello" source:@"auto" completion:ok];[t raw:@"hello" source:@"auto" completion:ok];Spin(1.15);
    Check(Count()==1&&done==2,"overlapping duplicate fragments must share one wire request via cache recheck");
    [t raw:@"world" source:@"auto" completion:ok];[t raw:@"third" source:@"auto" completion:ok];Spin(2.15);
    Check(Count()==3&&done==4,"distinct fragments must complete");
    Check(Starts[2].doubleValue-Starts[1].doubleValue>=.95,"wire requests must be spaced by at least one second");
    t.targetLanguage=@"en";[t raw:@"hello" source:@"auto" completion:ok];Spin(1.1);
    Check(Count()==4,"raw cache must be target scoped");
    t.nextGoogleRequest=NSProcessInfo.processInfo.systemUptime+10;
    __block BOOL cancelled=NO;[t raw:@"cancelled" source:@"auto" completion:^(NSString *s,NSError *e){cancelled=e.code==NSURLErrorCancelled;}];[t cancel];Spin(.1);
    Check(cancelled&&Count()==4,"superseded queued selections must be cancelled without network traffic");
    t.targetLanguage=@"zh-CN";t.nextGoogleRequest=0;__block NSUInteger limited=0;
    TranslationCompletion limit=^(NSString *s,NSError *e){Check(!s&&e.code==429,"limit response must remain actionable");limited++;};
    [t raw:@"limited" source:@"auto" completion:limit];[t raw:@"after-limit" source:@"auto" completion:limit];Spin(1.15);
    Check(Count()==5&&limited==2,"429 must stop queued traffic without retrying");
    Check(t.googleRetryDate.timeIntervalSinceNow>175,"Retry-After must be honored");
    Translator *restarted=Create();[restarted raw:@"restart" source:@"auto" completion:limit];
    Check(Count()==5&&limited==3,"cooldown must survive application restart");
    [t raw:@"hello" source:@"auto" completion:ok];Check(done==6&&Count()==5,"cached translation remains available while limited");
    t.googleRetryDate=[NSDate dateWithTimeIntervalSinceNow:-1];t.nextGoogleRequest=0;
    [t raw:@"recovered" source:@"auto" completion:ok];Spin(.15);
    Check(done==7&&Count()==6&&!t.googleRetryDate,"expired cooldown permits a request and success clears the marker");
    Check(![ThrottleDefaults.standardUserDefaults objectForKey:@"googleRetryDate"],"successful recovery clears persisted cooldown");
    t.nextGoogleRequest = 0;
    __block BOOL structured = NO;
    [t translate:@"# Heading\n\n1. First item. Another sentence.\n    - Nested item." completion:^(NSString *result, NSError *error) {
        Check(!error && [result isEqualToString:@"# 标题\n\n1. 第一项。另一句。\n    - 子项。"],
              "restore source blank lines and indentation without splitting sentences in a single list item");
        structured = YES;
    }];
    Spin(.2);
    Check(structured && Count()==7, "structured translation uses one request");
    Check(UsedWebContract,"Google requests must use the supported web endpoint and structured response parameters");
    [ThrottleDefaults.standardUserDefaults removePersistentDomainForName:@"TranslationThrottleIsolatedTests"];
    puts("PASS: request spacing, duplicate fragment cache, cancellation, 429 circuit breaker, Retry-After, persisted cooldown and recovery; no live traffic or user settings changed.");
}return 0;}
