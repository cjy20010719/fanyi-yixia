#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Vision/Vision.h>
#import <Carbon/Carbon.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <Sparkle/Sparkle.h>
#import <ServiceManagement/ServiceManagement.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import "ShortcutPreferences.h"
#import "YoudaoWeb.h"
#import "SpeechPlayback.h"

static NSString * const BundleID = @"local.chenshanglong.Translate";
static NSArray<NSArray<NSString *> *> *Languages(void) {
    return @[@[@"zh-CN", @"简体中文"], @[@"en", @"英文"], @[@"ko", @"韩文"], @[@"ja", @"日文"], @[@"zh-TW", @"繁体中文"], @[@"fr", @"法文"], @[@"de", @"德文"], @[@"es", @"西班牙文"], @[@"ru", @"俄文"], @[@"pt", @"葡萄牙文"], @[@"it", @"意大利文"], @[@"ar", @"阿拉伯文"], @[@"th", @"泰文"], @[@"vi", @"越南文"]];
}
static NSString *LanguageName(NSString *code) { for (NSArray *language in Languages()) if ([language[0] isEqual:code]) return language[1]; return @"简体中文"; }
static void PopulateLanguages(NSPopUpButton *picker, id target, SEL action) {
    for (NSArray *language in Languages()) { [picker addItemWithTitle:language[1]]; picker.lastItem.representedObject = language[0]; }
    picker.target = target; picker.action = action;
}
static void SelectLanguage(NSPopUpButton *picker, NSString *code) { for (NSMenuItem *item in picker.itemArray) if ([item.representedObject isEqual:code]) { [picker selectItem:item]; return; } }

typedef void (^TranslationCompletion)(NSString *, NSError *);

static NSError *TranslationError(NSInteger status) {
    NSString *message;
    if (status == 429) message = @"Google 暂时限流。可在“翻译源”切换有道，或稍后再试。";
    else if (status == 403) message = @"Google 翻译拒绝了请求，请稍后重试。";
    else if (status >= 500) message = @"Google 翻译服务暂时不可用，请稍后重试。";
    else message = @"Google 翻译没有返回有效译文，请稍后重试。";
    return [NSError errorWithDomain:BundleID code:status ?: 1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *TranslationFailureMessage(NSError *error) {
    if ([error.domain isEqual:NSURLErrorDomain]) {
        return @"无法连接到 Google 翻译，请检查网络后重试。";
    }
    return error.localizedDescription ?: @"翻译失败，请稍后重试。";
}

static NSArray<NSString *> *TranslationLines(NSString *text) {
    return [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

static NSString *MatchSourceLayout(NSString *source, NSString *translation) {
    if ([source rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) return translation;

    NSCharacterSet *space = NSCharacterSet.whitespaceCharacterSet;
    NSArray<NSString *> *sourceLines = TranslationLines(source);
    NSMutableArray<NSString *> *translatedLines = [NSMutableArray new];
    for (NSString *line in TranslationLines(translation)) {
        NSString *content = [line stringByTrimmingCharactersInSet:space];
        if (content.length) [translatedLines addObject:content];
    }
    NSCharacterSet *nonSpace = space.invertedSet;
    NSUInteger contentCount = 0;
    for (NSString *line in sourceLines) {
        if ([line rangeOfCharacterFromSet:nonSpace].location != NSNotFound) contentCount++;
    }
    // A provider can merge or split lines. Only transfer layout when the
    // returned lines can be paired in order without guessing a split.
    if (contentCount != translatedLines.count) return translation;

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:sourceLines.count];
    NSUInteger index = 0;
    for (NSString *line in sourceLines) {
        NSUInteger firstText = [line rangeOfCharacterFromSet:nonSpace].location;
        if (firstText == NSNotFound) {
            [lines addObject:line];
        } else {
            [lines addObject:[[line substringToIndex:firstText] stringByAppendingString:translatedLines[index++]]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL HasEdgeLineBreak(NSString *text, NSStringCompareOptions direction) {
    if (!text.length) return NO;
    NSCharacterSet *nonSpace = NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet;
    NSRange boundary = [text rangeOfCharacterFromSet:nonSpace options:direction];
    NSRange edge = NSMakeRange(0, text.length);
    if (boundary.location != NSNotFound) {
        NSUInteger end = NSMaxRange(boundary);
        edge = direction == NSBackwardsSearch ? NSMakeRange(end, text.length - end) : NSMakeRange(0, boundary.location);
    }
    return [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet options:0 range:edge].location != NSNotFound;
}

static void AppendGoogleSegment(NSMutableString *result, id translated, id original, BOOL *previousLineBreak) {
    if (![translated isKindOfClass:NSString.class]) return;
    NSString *source = [original isKindOfClass:NSString.class] ? original : nil;
    if (result.length && (*previousLineBreak || HasEdgeLineBreak(source, 0)) &&
        !HasEdgeLineBreak(result, NSBackwardsSearch) && !HasEdgeLineBreak(translated, 0)) {
        [result appendString:@"\n"];
    }
    [result appendString:translated];
    *previousLineBreak = HasEdgeLineBreak(source, NSBackwardsSearch);
}

@interface Translator : NSObject
@property NSURLSession *session;
@property NSCache *cache;
@property NSMutableSet<NSURLSessionDataTask *> *tasks;
@property NSUInteger epoch;
@property NSString *targetLanguage;
@property NSString *provider;
@property NSDictionary *youdaoKeys;
@property NSDate *youdaoKeyDate;
@property NSDate *youdaoRetryDate;
@property NSTimeInterval nextYoudaoRequest;
@property NSMutableArray<NSDictionary *> *googleQueue;
@property BOOL googleBusy;
@property NSTimeInterval nextGoogleRequest;
@property (copy) dispatch_block_t googlePump;
@property NSDate *googleRetryDate;
@property NSUInteger googleLimitCount;
- (void)translate:(NSString *)text completion:(TranslationCompletion)completion;
- (void)raw:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion;
- (void)cancel;
@end

@implementation Translator
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 12;
        config.timeoutIntervalForResource = 18;
        config.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:config];
        _cache = [NSCache new]; _cache.countLimit = 150;
        _tasks = [NSMutableSet new]; _targetLanguage = @"zh-CN";
        _googleQueue=[NSMutableArray new];
        id retry=[NSUserDefaults.standardUserDefaults objectForKey:@"googleRetryDate"];
        if([retry isKindOfClass:NSDate.class] && [retry timeIntervalSinceNow]>0) _googleRetryDate=retry;
        _provider=[NSUserDefaults.standardUserDefaults stringForKey:@"translationProvider"] ?: @"google";
    }
    return self;
}
- (void)cancel {
    self.epoch++;
    if(self.googlePump) dispatch_block_cancel(self.googlePump);self.googlePump=nil;
    NSArray *queued=self.googleQueue.copy;[self.googleQueue removeAllObjects];
    for(NSDictionary *job in queued) {dispatch_block_t cancel=job[@"cancel"];cancel();}
    for (NSURLSessionDataTask *task in self.tasks) [task cancel]; [self.tasks removeAllObjects];
}
- (NSError *)googleCooldownError {
    NSTimeInterval remaining=self.googleRetryDate.timeIntervalSinceNow;
    if(remaining<=0) return nil;
    NSString *message=[NSString stringWithFormat:@"Google 暂时限流，约 %.0f 秒后可重试。可在“翻译源”切换有道。",ceil(remaining)];
    return [NSError errorWithDomain:BundleID code:429 userInfo:@{NSLocalizedDescriptionKey:message}];
}
- (void)recordGoogleLimit:(NSHTTPURLResponse *)response {
    self.googleLimitCount=MIN(self.googleLimitCount+1,4u);
    NSTimeInterval delay=MIN(120*pow(2,self.googleLimitCount-1),900);
    NSString *header=[response valueForHTTPHeaderField:@"Retry-After"];
    if(header.length) {
        NSTimeInterval seconds=header.doubleValue;
        if(seconds<=0) {
            NSDateFormatter *format=[NSDateFormatter new];format.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            format.dateFormat=@"EEE, dd MMM yyyy HH:mm:ss zzz";
            seconds=[[format dateFromString:header] timeIntervalSinceNow];
        }
        delay=MAX(delay,seconds);
    }
    self.googleRetryDate=[NSDate dateWithTimeIntervalSinceNow:delay];
    [NSUserDefaults.standardUserDefaults setObject:self.googleRetryDate forKey:@"googleRetryDate"];
}
- (void)pumpGoogleRequests {
    if(self.googleBusy || self.googlePump || !self.googleQueue.count) return;
    NSTimeInterval delay=MAX(0,self.nextGoogleRequest-NSProcessInfo.processInfo.systemUptime);
    __weak Translator *weakSelf=self;
    self.googlePump=dispatch_block_create(0,^{
        Translator *self=weakSelf;if(!self) return;
        self.googlePump=nil;
        if(!self.googleQueue.count) return;
        NSDictionary *job=self.googleQueue.firstObject;[self.googleQueue removeObjectAtIndex:0];
        self.googleBusy=YES;dispatch_block_t run=job[@"run"];run();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),self.googlePump);
}
- (void)youdaoRequest:(NSURLRequest *)request completion:(void (^)(NSData *, NSError *))completion {
    NSUInteger epoch=self.epoch;
    NSTimeInterval delay=MAX(0,self.nextYoudaoRequest-NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(epoch!=self.epoch) {completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);return;}
        NSTimeInterval remaining=self.youdaoRetryDate.timeIntervalSinceNow;
        if(remaining>0) {completion(nil,YoudaoResponseError(429,[NSString stringWithFormat:@"有道暂时限流，约 %.0f 秒后可重试。",ceil(remaining)]));return;}
        self.nextYoudaoRequest=NSProcessInfo.processInfo.systemUptime+0.4;
        [self sendYoudaoRequest:request completion:completion];
    });
}
- (void)sendYoudaoRequest:(NSURLRequest *)request completion:(void (^)(NSData *, NSError *))completion {
    NSUInteger epoch=self.epoch; __block __weak NSURLSessionDataTask *weakTask;
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if(weakTask) [self.tasks removeObject:weakTask];
            if(status==429) {
                NSTimeInterval retry=[[(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"] doubleValue];
                self.youdaoRetryDate=[NSDate dateWithTimeIntervalSinceNow:MAX(120,retry)];
            }
            if(epoch!=self.epoch) {completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);return;}
            if(error) {
                if(error.code==NSURLErrorCancelled) {completion(nil,error);return;}
                completion(nil,YoudaoResponseError(error.code,error.code==NSURLErrorTimedOut ? @"连接有道翻译超时，请稍后重试。" : @"无法连接到有道翻译，请检查当前网络或代理后重试。"));return;
            }
            if(status!=200) {completion(nil,YoudaoResponseError(status,status==429 ? @"有道暂时限流，请稍后重试。" : [NSString stringWithFormat:@"有道服务返回 HTTP %ld，请稍后重试。",(long)status]));return;}
            completion(data,nil);
        });
    }];weakTask=task;[self.tasks addObject:task];[task resume];
}
- (void)youdao:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion {
    [self youdao:text source:source refresh:NO completion:completion];
}
- (void)youdao:(NSString *)text source:(NSString *)source refresh:(BOOL)refresh completion:(TranslationCompletion)completion {
    NSString *target=YoudaoLanguage(self.targetLanguage);
    NSUInteger epoch=self.epoch;
    void (^translate)(NSDictionary *)=^(NSDictionary *keys) {
        NSMutableDictionary *params=YoudaoParameters(keys[@"secretKey"],@"webfanyi");
        params[@"i"]=text;params[@"from"]=YoudaoLanguage(source);params[@"to"]=target;params[@"dictResult"]=@"false";
        [self youdaoRequest:YoudaoRequest(params,YES) completion:^(NSData *data,NSError *error) {
            if(epoch!=self.epoch) {completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);return;}
            NSError *decodeError=nil;
            NSString *result=error ? nil : YoudaoDecodeResult(data, keys, text, &decodeError);
            if(!result && self.youdaoKeys==keys && !YoudaoUnsupportedLanguage(decodeError)) {
                self.youdaoKeys=nil;
                self.youdaoKeyDate=nil;
            }
            // Refresh a bad encryption key once. Never loop on denial, rate limit,
            // connection failure, cancellation, or an upstream business error.
            if(!error && [decodeError.domain isEqual:@"Translation.Youdao.Decode"] && !refresh) {
                [self youdao:text source:source refresh:YES completion:completion];return;
            }
            completion(result,error ?: decodeError);
        }];
    };
    // The same web session can reuse a recently issued key across selections.
    // Cancellation still invalidates the request, not the session key.
    NSTimeInterval keyAge = -self.youdaoKeyDate.timeIntervalSinceNow;
    if (!refresh && self.youdaoKeys && self.youdaoKeyDate && keyAge >= 0 && keyAge < 30) {
        translate(self.youdaoKeys);
        return;
    }
    [self youdaoRequest:YoudaoRequest(YoudaoParameters(@"asdjnjfenknafdfsdfsd",@"webfanyi-key-getter"),NO) completion:^(NSData *data,NSError *error) {
        if(error) {completion(nil,error);return;}
        id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![json isKindOfClass:NSDictionary.class] || ![json[@"code"] respondsToSelector:@selector(integerValue)]) {completion(nil,YoudaoError(@"有道动态密钥响应异常，请稍后重试。"));return;}
        NSInteger code=[json[@"code"] integerValue];
        if(code!=0) {completion(nil,YoudaoResponseError(code,[NSString stringWithFormat:@"有道未能提供动态密钥（代码 %ld），请稍后重试。",(long)code]));return;}
        NSDictionary *keys=[json[@"data"] isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        for(NSString *field in @[@"secretKey",@"aesKey",@"aesIv"]) if(![keys[field] isKindOfClass:NSString.class] || ![keys[field] length]) {completion(nil,YoudaoError(@"有道返回的动态密钥不完整，请稍后重试。"));return;}
        self.youdaoKeys=keys;self.youdaoKeyDate=NSDate.date;translate(keys);
    }];
}
- (void)raw:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion {
    if([self.provider isEqual:@"youdao"]) {
        NSString *key=[NSString stringWithFormat:@"raw-youdao\n%@\n%@\n%@",source,self.targetLanguage,text];
        NSString *hit=[self.cache objectForKey:key];if(hit) {completion(hit,nil);return;}
        [self youdao:text source:source completion:^(NSString *result,NSError *error) {
            if(result.length && !error) [self.cache setObject:result forKey:key];completion(result,error);
        }];return;
    }
    NSString *key=[NSString stringWithFormat:@"raw-google\n%@\n%@\n%@",source,self.targetLanguage,text];
    NSString *cached=[self.cache objectForKey:key];
    if(cached) {completion(cached,nil);return;}
    NSError *cooldown=[self googleCooldownError];if(cooldown) {completion(nil,cooldown);return;}
    NSUInteger epoch=self.epoch;NSString *target=self.targetLanguage;
    TranslationCompletion finish=^(NSString *result,NSError *error) {
        if(result.length && !error) [self.cache setObject:result forKey:key];
        self.googleBusy=NO;completion(result,error);[self pumpGoogleRequests];
    };
    [self.googleQueue addObject:@{@"run":[^{
        if(epoch!=self.epoch) {finish(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);return;}
        NSError *limit=[self googleCooldownError];if(limit) {finish(nil,limit);return;}
        // Recheck after queuing: an identical preceding request may now be cached.
        NSString *hit=[self.cache objectForKey:key];if(hit) {finish(hit,nil);return;}
        self.nextGoogleRequest=NSProcessInfo.processInfo.systemUptime+1.0;
        [self sendGoogle:text source:source target:target completion:finish];
    } copy],@"cancel":[^{completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);} copy]}];
    [self pumpGoogleRequests];
}
- (void)sendGoogle:(NSString *)text source:(NSString *)source target:(NSString *)target completion:(TranslationCompletion)completion {
    NSUInteger epoch = self.epoch;
    // Use the Google Translate web entry point used by Easydict, rather than
    // the separate googleapis GTX host. Keep one endpoint; do not rotate hosts
    // or retry through another route when Google returns a rate limit.
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://translate.google.com/translate_a/single"];
    NSMutableArray *items = [NSMutableArray new];
    NSDictionary *params = @{@"client":@"gtx", @"sl":source, @"tl":target, @"dt":@"t", @"dj":@"1", @"ie":@"UTF-8", @"q":text};
    for (NSString *key in [[params allKeys] sortedArrayUsingSelector:@selector(compare:)]) [items addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];
    url.queryItems = items;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    // The task set owns running tasks; a weak reference prevents a task/block cycle.
    __block __weak NSURLSessionDataTask *weakTask;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableString *result = [NSMutableString new];
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (!error && status == 200 && data.length) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            BOOL previousLineBreak = NO;
            if([root isKindOfClass:NSDictionary.class] && [root[@"sentences"] isKindOfClass:NSArray.class]) {
                for(id sentence in root[@"sentences"]) {
                    if ([sentence isKindOfClass:NSDictionary.class]) {
                        AppendGoogleSegment(result, sentence[@"trans"], sentence[@"orig"], &previousLineBreak);
                    }
                }
            }
            if ([root isKindOfClass:NSArray.class] && [root count] && [root[0] isKindOfClass:NSArray.class]) {
                for (id segment in root[0]) {
                    if ([segment isKindOfClass:NSArray.class] && [segment count]) {
                        AppendGoogleSegment(result, segment[0], [segment count] > 1 ? segment[1] : nil, &previousLineBreak);
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakTask) [self.tasks removeObject:weakTask];
            // Even a response superseded by a new selection must stop further traffic.
            if(status==429) [self recordGoogleLimit:(NSHTTPURLResponse *)response];
            if (epoch != self.epoch) { completion(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); return; }
            if(result.length) {self.googleLimitCount=0;self.googleRetryDate=nil;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"googleRetryDate"];}
            completion(result.length ? result : nil, error ?: (result.length ? nil : ([self googleCooldownError] ?: TranslationError(status))));
        });
    }];
    weakTask = task;
    [self.tasks addObject:task];
    [task resume];
}
// Auto detection occasionally treats a Latin sentence containing a romanized
// name as Chinese and returns it verbatim. Retry with an independent local
// language guess, keeping the entire phrase together instead of splitting names.
- (void)contextual:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion {
    [self raw:text source:source completion:^(NSString *result, NSError *error) {
        BOOL autoSource = [source isEqualToString:@"auto"];
        if (YoudaoUnsupportedLanguage(error)) {
            if (!autoSource) {
                [self raw:text source:@"auto" completion:completion];
                return;
            }
            NSString *detected = [NLLanguageRecognizer dominantLanguageForString:text];
            if ([detected isEqualToString:NLLanguageSimplifiedChinese]) detected = @"zh-CN";
            if ([detected isEqualToString:NLLanguageTraditionalChinese]) detected = @"zh-TW";
            for (NSArray<NSString *> *language in Languages()) {
                if ([language[0] isEqualToString:detected] && ![detected isEqualToString:self.targetLanguage]) {
                    [self raw:text source:detected completion:completion];
                    return;
                }
            }
            completion(nil, error);
            return;
        }
        NSString *trimmed = [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL unchanged = trimmed && [trimmed caseInsensitiveCompare:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] == NSOrderedSame;
        if (error || !unchanged || !autoSource || ![self.targetLanguage isEqual:@"zh-CN"]) { completion(result, error); return; }
        NSString *language = [NLLanguageRecognizer dominantLanguageForString:text];
        BOOL latinOnly = [text rangeOfString:@"\\p{Latin}" options:NSRegularExpressionSearch].location != NSNotFound && [text rangeOfString:@"[\\p{Han}\\p{Hangul}\\p{Hiragana}\\p{Katakana}\\p{Cyrillic}\\p{Arabic}]" options:NSRegularExpressionSearch].location == NSNotFound;
        if (latinOnly && (!language || [language hasPrefix:@"zh"] || [language isEqual:@"und"])) language = @"en";
        if (!language.length || [language hasPrefix:@"zh"] || [language isEqual:@"und"]) { completion(result, nil); return; }
        [self raw:text source:language completion:completion];
    }];
}
// Translate the sentence in context, then repair foreign-script spans that the
// dominant-language detector left untranslated. Chinese punctuation is preserved.
- (void)repair:(NSString *)text remaining:(NSInteger)remaining completion:(TranslationCompletion)completion {
    if (remaining == 0) { completion(text, nil); return; }
    NSArray *rules = @[
        @[@"[\\p{Hangul}]+(?:[ \\t]+[\\p{Hangul}]+)*", @"ko"],
        @[@"[\\p{Han}\\p{Hiragana}\\p{Katakana}]*[\\p{Hiragana}\\p{Katakana}][\\p{Han}\\p{Hiragana}\\p{Katakana}ー]*", @"ja"],
        @[@"[\\p{Cyrillic}]+(?:[ \\t]+[\\p{Cyrillic}]+)*", @"auto"],
        @[@"[\\p{Greek}]+(?:[ \\t]+[\\p{Greek}]+)*", @"el"],
        @[@"[\\p{Arabic}\\p{M}]+(?:[ \\t]+[\\p{Arabic}\\p{M}]+)*", @"ar"],
        @[@"[\\p{Hebrew}\\p{M}]+(?:[ \\t]+[\\p{Hebrew}\\p{M}]+)*", @"iw"],
        @[@"[\\p{Thai}]+", @"th"],
        @[@"[\\p{Devanagari}\\p{M}]+(?:[ \\t]+[\\p{Devanagari}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Bengali}\\p{M}]+(?:[ \\t]+[\\p{Bengali}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Tamil}\\p{M}]+(?:[ \\t]+[\\p{Tamil}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Telugu}\\p{M}]+(?:[ \\t]+[\\p{Telugu}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Gujarati}\\p{M}]+(?:[ \\t]+[\\p{Gujarati}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Gurmukhi}\\p{M}]+(?:[ \\t]+[\\p{Gurmukhi}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Kannada}\\p{M}]+(?:[ \\t]+[\\p{Kannada}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Malayalam}\\p{M}]+(?:[ \\t]+[\\p{Malayalam}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Sinhala}\\p{M}]+(?:[ \\t]+[\\p{Sinhala}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Lao}\\p{M}]+(?:[ \\t]+[\\p{Lao}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Myanmar}\\p{M}]+(?:[ \\t]+[\\p{Myanmar}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Khmer}\\p{M}]+(?:[ \\t]+[\\p{Khmer}\\p{M}]+)*", @"auto"],
        @[@"[\\p{Armenian}]+(?:[ \\t]+[\\p{Armenian}]+)*", @"auto"],
        @[@"[\\p{Georgian}]+(?:[ \\t]+[\\p{Georgian}]+)*", @"auto"],
        @[@"[\\p{Ethiopic}]+(?:[ \\t]+[\\p{Ethiopic}]+)*", @"auto"],
        @[@"[\\p{Latin}][\\p{Latin}\\p{M}'’]*(?:[ \\t]+[\\p{Latin}][\\p{Latin}\\p{M}'’]*)*", @"auto"]
    ];
    [self repairRules:rules index:0 text:text remaining:remaining completion:completion];
}
- (void)repairRules:(NSArray *)rules index:(NSUInteger)index text:(NSString *)text remaining:(NSInteger)remaining completion:(TranslationCompletion)completion {
    if (index >= rules.count || remaining <= 0) { completion(text, nil); return; }
    NSArray *rule = rules[index];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[0] options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    [self repairMatches:matches index:(NSInteger)matches.count - 1 rule:rule rules:rules ruleIndex:index text:text remaining:remaining completion:completion];
}
- (void)repairMatches:(NSArray<NSTextCheckingResult *> *)matches index:(NSInteger)index rule:(NSArray *)rule rules:(NSArray *)rules ruleIndex:(NSUInteger)ruleIndex text:(NSString *)text remaining:(NSInteger)remaining completion:(TranslationCompletion)completion {
    if (index < 0 || remaining <= 0) {
        [self repairRules:rules index:ruleIndex + 1 text:text remaining:remaining completion:completion]; return;
    }
    NSRange range = matches[index].range;
    NSString *part = [text substringWithRange:range];
    [self contextual:part source:rule[1] completion:^(NSString *translated, NSError *error) {
        if (YoudaoUnsupportedLanguage(error)) {
            // Keep this span verbatim and continue translating the other spans.
            [self repairMatches:matches index:index - 1 rule:rule rules:rules ruleIndex:ruleIndex
                           text:text remaining:remaining - 1 completion:^(NSString *partial, NSError *laterError) {
                completion(partial, laterError ?: error);
            }];
            return;
        }
        if (error) { completion(nil, error); return; }
        NSString *updated = translated.length ? [text stringByReplacingCharactersInRange:range withString:translated] : text;
        [self repairMatches:matches index:index - 1 rule:rule rules:rules ruleIndex:ruleIndex text:updated remaining:remaining - 1 completion:completion];
    }];
}
- (void)translate:(NSString *)text completion:(TranslationCompletion)completion {
    NSString *target = self.targetLanguage;
    NSString *cacheKey = [NSString stringWithFormat:@"%@\n%@\n%@", self.provider, target, text];
    NSString *cached = [self.cache objectForKey:cacheKey];
    if (cached) { completion(cached, nil); return; }
    void (^finish)(NSString *, NSError *) = ^(NSString *final, NSError *error) {
        if (error && [final isEqualToString:text]) final = nil;
        if (final) {
            if ([target isEqual:@"zh-CN"]) final = [final stringByApplyingTransform:@"Traditional-Simplified" reverse:NO] ?: final;
            final = MatchSourceLayout(text, final);
            if (!error) [self.cache setObject:final forKey:cacheKey];
        }
        completion(final, error);
    };
    if (![target isEqual:@"zh-CN"]) { [self contextual:text source:@"auto" completion:finish]; return; }
    // One dominant-language guess can silently drop a Chinese clause or
    // transliterate an embedded Korean/Arabic word. For mixed scripts, translate
    // the original spans first, preserving all original Chinese and punctuation.
    NSUInteger scripts = 0;
    for (NSString *pattern in @[@"\\p{Han}", @"\\p{Latin}", @"\\p{Hangul}", @"[\\p{Hiragana}\\p{Katakana}]", @"\\p{Cyrillic}", @"\\p{Arabic}", @"\\p{Greek}", @"\\p{Hebrew}", @"\\p{Thai}", @"\\p{Devanagari}", @"\\p{Bengali}", @"\\p{Tamil}", @"\\p{Telugu}", @"\\p{Gujarati}", @"\\p{Gurmukhi}", @"\\p{Kannada}", @"\\p{Malayalam}", @"\\p{Sinhala}", @"\\p{Lao}", @"\\p{Myanmar}", @"\\p{Khmer}", @"\\p{Armenian}", @"\\p{Georgian}", @"\\p{Ethiopic}"]) {
        if ([text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound) scripts++;
    }
    if (scripts > 1) { [self repair:text remaining:40 completion:finish]; return; }
    [self contextual:text source:@"auto" completion:^(NSString *result, NSError *error) {
        if (error) { completion(nil, error); return; }
        [self repair:result remaining:16 completion:finish];
    }];
}
@end

static id Attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

@interface Selection : NSObject
@property NSString *text;
@property NSRect anchor;
@property pid_t pid;
@end
@implementation Selection @end

static NSRect SelectionAnchorAtPoint(NSPoint point) {
    return NSMakeRect(point.x, point.y, 1, 18);
}

static NSRect SelectionAnchorForDrag(NSPoint start, NSPoint end) {
    return NSMakeRect(MIN(start.x, end.x), MIN(start.y, end.y),
                      MAX(1, fabs(start.x - end.x)), fabs(start.y - end.y) + 18);
}

static NSRect TextAnchorFromAX(id value, NSRect drag) {
    CGRect rect;
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != AXValueGetTypeID() ||
        !AXValueGetValue((__bridge AXValueRef)value, kAXValueCGRectType, &rect) ||
        rect.size.width <= 0 || rect.size.height <= 0 ||
        !isfinite(CGRectGetMaxX(rect)) || !isfinite(CGRectGetMaxY(rect)) ||
        !isfinite(rect.origin.x) || !isfinite(rect.origin.y)) return NSZeroRect;

    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    NSRect anchor = NSMakeRect(rect.origin.x, top - CGRectGetMaxY(rect), rect.size.width, rect.size.height);
    // A web editor may expose text via an off-canvas element. Its bounds must
    // still agree with the rows and endpoints that the user actually dragged.
    const CGFloat tolerance = 48;
    if (!NSIsEmptyRect(drag) &&
        (fabs(NSMinY(anchor) - NSMinY(drag)) > tolerance ||
         fabs(NSMaxY(anchor) - NSMaxY(drag)) > tolerance ||
         NSMinX(drag) < NSMinX(anchor) - tolerance ||
         NSMaxX(drag) > NSMaxX(anchor) + tolerance)) return NSZeroRect;
    return anchor;
}

static BOOL IsStandaloneWebLink(NSString *text) {
    // A browser may expose its address without the scheme or with surrounding quotes.
    static NSDataDetector *detector;
    static NSCharacterSet *wrappers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
        NSMutableCharacterSet *ignored = NSCharacterSet.whitespaceAndNewlineCharacterSet.mutableCopy;
        [ignored addCharactersInString:@"<>()[]{}\"'“”‘’《》〈〉「」『』（）【】。！？；，、.!?;,"];
        wrappers = ignored.copy;
    });
    NSString *candidate = [text stringByTrimmingCharactersInSet:wrappers];
    if (!candidate.length || [candidate rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return NO;
    NSURLComponents *components = [NSURLComponents componentsWithString:candidate];
    if (components.host.length &&
        [@[@"http", @"https"] containsObject:components.scheme.lowercaseString ?: @""]) return YES;
    NSRange range = NSMakeRange(0, candidate.length);
    NSTextCheckingResult *link = [detector firstMatchInString:candidate options:0 range:range];
    NSString *scheme = link.URL.scheme.lowercaseString;
    return link && NSEqualRanges(link.range, range) && [@[@"http", @"https"] containsObject:scheme ?: @""];
}

// Keep selection discovery independent of AX transport so nested web selections,
// secure fields and non-text values can be covered by deterministic regression tests.
@interface SelectionReader : NSObject
@property NSRect dragAnchor;
- (id)attribute:(id)element name:(CFStringRef)name;
- (id)parameter:(id)element name:(CFStringRef)name value:(id)value;
- (BOOL)isElement:(id)element;
- (Selection *)readFocus:(id)focus hit:(id)hit window:(id)window fallback:(NSRect)fallback;
@end
@implementation SelectionReader
- (BOOL)isElement:(id)element { return element && CFGetTypeID((__bridge CFTypeRef)element) == AXUIElementGetTypeID(); }
- (id)attribute:(id)element name:(CFStringRef)name {
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)element, 0.025);
    return Attribute((__bridge AXUIElementRef)element, name);
}
- (id)parameter:(id)element name:(CFStringRef)name value:(id)value {
    if (!value) return nil;
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)element, 0.025);
    CFTypeRef result = NULL;
    if (AXUIElementCopyParameterizedAttributeValue((__bridge AXUIElementRef)element, name, (__bridge CFTypeRef)value, &result) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(result);
}
- (BOOL)isSecure:(id)element {
    id subrole = [self attribute:element name:kAXSubroleAttribute];
    return [subrole isKindOfClass:NSString.class] && [[subrole lowercaseString] containsString:@"secure"];
}
- (Selection *)selected:(id)element fallback:(NSRect)fallback {
    id raw = [self attribute:element name:kAXSelectedTextAttribute];
    id range = nil; id bounds = nil; id markers = nil;
    if (![raw isKindOfClass:NSString.class] || ![raw length]) {
        id selectedRange=[self attribute:element name:kAXSelectedTextRangeAttribute];
        CFRange characters;
        if (selectedRange && CFGetTypeID((__bridge CFTypeRef)selectedRange)==AXValueGetTypeID() && AXValueGetValue((__bridge AXValueRef)selectedRange,kAXValueCFRangeType,&characters) && characters.location>=0 && characters.length>0 && characters.length<=5000) {
            raw=[self parameter:element name:kAXStringForRangeParameterizedAttribute value:selectedRange];
            if (![raw isKindOfClass:NSString.class] || ![raw length]) {
                id attributed=[self parameter:element name:kAXAttributedStringForRangeParameterizedAttribute value:selectedRange];
                if ([attributed isKindOfClass:NSAttributedString.class]) raw=[attributed string];
            }
            if (![raw isKindOfClass:NSString.class] || ![raw length]) {
                id value=[self attribute:element name:kAXValueAttribute];
                if ([value isKindOfClass:NSString.class] && (NSUInteger)characters.location<=[value length] && (NSUInteger)characters.length<=[value length]-(NSUInteger)characters.location) raw=[value substringWithRange:NSMakeRange(characters.location,characters.length)];
            }
            if ([raw isKindOfClass:NSString.class] && [raw length]) {
                range=selectedRange; bounds=[self parameter:element name:kAXBoundsForRangeParameterizedAttribute value:range];
            }
        }
    }
    // Safari/WebKit often attaches the selection to the web area's text markers,
    // while the focused element is just a heading or a generic container.
    if (![raw isKindOfClass:NSString.class] || ![raw length]) {
        markers = [self attribute:element name:CFSTR("AXSelectedTextMarkerRange")];
        raw = [self parameter:element name:CFSTR("AXStringForTextMarkerRange") value:markers];
        if ([raw isKindOfClass:NSString.class] && [raw length]) bounds = [self parameter:element name:CFSTR("AXBoundsForTextMarkerRange") value:markers];
    } else if (!range) {
        range = [self attribute:element name:kAXSelectedTextRangeAttribute];
        bounds = [self parameter:element name:kAXBoundsForRangeParameterizedAttribute value:range];
    }
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || text.length > 5000) return nil;
    NSRect anchor = TextAnchorFromAX(bounds, self.dragAnchor);
    // Web views can return selected text while exposing its bounds only through markers.
    if (NSIsEmptyRect(anchor) && !markers) {
        markers = [self attribute:element name:CFSTR("AXSelectedTextMarkerRange")];
        anchor = TextAnchorFromAX([self parameter:element name:CFSTR("AXBoundsForTextMarkerRange") value:markers], self.dragAnchor);
    }
    Selection *selection = [Selection new];
    selection.text = text;
    selection.anchor = NSIsEmptyRect(anchor) ? fallback : anchor;
    return selection;
}
- (Selection *)readFocus:(id)focus hit:(id)hit window:(id)window fallback:(NSRect)fallback {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.18;
    if ([self isElement:focus] && [self isSecure:focus]) return nil;
    NSMutableArray *visited = [NSMutableArray new];
    for (id start in @[focus ?: NSNull.null, hit ?: NSNull.null]) {
        id node = start;
        for (NSUInteger depth = 0; depth < 24 && [self isElement:node] && NSProcessInfo.processInfo.systemUptime < deadline; depth++) {
            if ([self isSecure:node]) return nil;
            if ([visited containsObject:node]) break;
            [visited addObject:node];
            Selection *selection = [self selected:node fallback:fallback]; if (selection) return selection;
            node = [self attribute:node name:kAXParentAttribute];
        }
    }
    // Bounded search of the active window's containers, including nested frames.
    // Never substitute AXValue/the whole page when an actual selection is absent.
    NSMutableArray *queue = [NSMutableArray new]; if ([self isElement:window]) [queue addObject:@[window, @0]];
    for (NSUInteger i = 0; i < queue.count && i < 192 && NSProcessInfo.processInfo.systemUptime < deadline; i++) {
        id node = queue[i][0]; NSUInteger depth = [queue[i][1] unsignedIntegerValue];
        if (![self isElement:node] || [self isSecure:node]) continue;
        if (![visited containsObject:node]) {
            [visited addObject:node];
            id role=[self attribute:node name:kAXRoleAttribute];
            if (!role || [@[@"AXWebArea",@"AXTextArea",@"AXTextField",@"AXStaticText",@"AXText"] containsObject:role]) {
                Selection *selection = [self selected:node fallback:fallback]; if (selection) return selection;
            }
        }
        if (depth >= 24) continue;
        for (NSString *attribute in @[@"AXContents",@"AXChildren"]) {
            id children = [self attribute:node name:(__bridge CFStringRef)attribute];
            if ([children isKindOfClass:NSArray.class]) for (id child in children) {
                if (queue.count >= 192) break;
                if ([self isElement:child] && ![visited containsObject:child]) [queue addObject:@[child, @(depth + 1)]];
            }
        }
    }
    return nil;
}
@end

static Selection *ReadSelection(NSPoint hitPoint, NSRect drag) {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front || front.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return nil;
    AXUIElementRef application = AXUIElementCreateApplication(front.processIdentifier);
    AXUIElementSetMessagingTimeout(application, 0.04);
    // Ask supporting apps to expose their existing accessibility selection once
    // per process; do not repeatedly rebuild their accessibility trees while typing.
    static NSMutableSet *prepared;
    if (!prepared) prepared = [NSMutableSet new];
    NSString *key = [NSString stringWithFormat:@"%d:%@", front.processIdentifier, front.launchDate];
    if (![prepared containsObject:key]) {
        [prepared addObject:key];
        Boolean supported=false;
        AXUIElementIsAttributeSettable(application,CFSTR("AXManualAccessibility"),&supported);
        NSString *frameworks=[front.bundleURL.path stringByAppendingPathComponent:@"Contents/Frameworks"];
        BOOL chromium=[front.bundleIdentifier hasPrefix:@"com.google.Chrome"] || [@[@"com.microsoft.edgemac",@"com.brave.Browser",@"company.thebrowser.Browser",@"com.operasoftware.Opera"] containsObject:front.bundleIdentifier];
        for (NSString *name in @[@"Electron Framework.framework",@"Chromium Embedded Framework.framework"]) if ([NSFileManager.defaultManager fileExistsAtPath:[frameworks stringByAppendingPathComponent:name]]) chromium=YES;
        if (supported || chromium) {
            if (AXUIElementSetAttributeValue(application,CFSTR("AXManualAccessibility"),kCFBooleanTrue)!=kAXErrorSuccess && chromium) AXUIElementSetAttributeValue(application,CFSTR("AXEnhancedUserInterface"),kCFBooleanTrue);
        }
    }
    id focus = Attribute(application, kAXFocusedUIElementAttribute);
    id window = Attribute(application, kAXFocusedWindowAttribute);
    AXUIElementRef hit = NULL;
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    AXUIElementCopyElementAtPosition(application, hitPoint.x, top - hitPoint.y, &hit);
    SelectionReader *reader = [SelectionReader new];
    reader.dragAnchor = drag;
    NSRect fallback = NSIsEmptyRect(drag) ? SelectionAnchorAtPoint(hitPoint) : drag;
    Selection *selection = [reader readFocus:focus hit:(__bridge id)hit window:window fallback:fallback];
    if (hit) CFRelease(hit); CFRelease(application);
    selection.pid = front.processIdentifier; return selection;
}

static id CopyMenuItem(AXUIElementRef application) {
    id bar=Attribute(application,kAXMenuBarAttribute);
    if (!bar) return nil;
    NSMutableArray *queue=[NSMutableArray arrayWithObject:bar];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+0.20;
    for (NSUInteger i=0;i<queue.count && i<160 && NSProcessInfo.processInfo.systemUptime<deadline;i++) {
        id node=queue[i]; if (CFGetTypeID((__bridge CFTypeRef)node)!=AXUIElementGetTypeID()) continue;
        AXUIElementRef element=(__bridge AXUIElementRef)node; AXUIElementSetMessagingTimeout(element,0.025);
        id key=Attribute(element,kAXMenuItemCmdCharAttribute);
        if ([key isKindOfClass:NSString.class] && [[key lowercaseString] isEqual:@"c"]) {
            id modifiers=Attribute(element,kAXMenuItemCmdModifiersAttribute);
            if ([modifiers isKindOfClass:NSNumber.class] && [modifiers unsignedIntegerValue]==0 && [Attribute(element,kAXEnabledAttribute) boolValue]) return node;
        }
        id children=Attribute(element,kAXChildrenAttribute);
        if ([children isKindOfClass:NSArray.class]) for(id child in children) { if(queue.count>=160) break; [queue addObject:child]; }
    }
    return nil;
}
static BOOL SelectionCopyAllowed(NSRunningApplication *front) {
    if (!front || front.processIdentifier==NSProcessInfo.processInfo.processIdentifier || IsSecureEventInputEnabled()) return NO;
    if ([@[@"com.apple.finder",@"com.apple.keychainaccess",@"com.apple.Passwords",@"com.apple.systempreferences"] containsObject:front.bundleIdentifier]) return NO;
    AXUIElementRef app=AXUIElementCreateApplication(front.processIdentifier); AXUIElementSetMessagingTimeout(app,0.04);
    id focus=Attribute(app,kAXFocusedUIElementAttribute); CFRelease(app);
    for(NSUInteger i=0;i<24 && focus && CFGetTypeID((__bridge CFTypeRef)focus)==AXUIElementGetTypeID();i++) {
        AXUIElementRef element=(__bridge AXUIElementRef)focus; AXUIElementSetMessagingTimeout(element,0.025);
        id subrole=Attribute(element,kAXSubroleAttribute);
        if ([subrole isKindOfClass:NSString.class] && [[subrole lowercaseString] containsString:@"secure"]) return NO;
        focus=Attribute(element,kAXParentAttribute);
    }
    return YES;
}

// Uses a copy command only after an explicit selection gesture/hotkey, never
// while idle polling. Old clipboard formats stay in memory and are restored only
// if the clipboard has not changed again; a user's newer copy always wins.
@interface CompatibilityReader : NSObject
@property NSPasteboard *pasteboard;
@property BOOL busy;
@property NSUInteger epoch;
- (void)readCopy:(BOOL (^)(void))copy valid:(BOOL (^)(void))valid completion:(void (^)(NSString *))completion;
- (void)cancel;
@end
@implementation CompatibilityReader
- (instancetype)init { if((self=[super init])) _pasteboard=NSPasteboard.generalPasteboard; return self; }
- (void)cancel { self.epoch++; self.busy=NO; }
- (void)readCopy:(BOOL (^)(void))copy valid:(BOOL (^)(void))valid completion:(void (^)(NSString *))completion {
    if (self.busy || !valid()) { completion(nil); return; }
    NSInteger initial=self.pasteboard.changeCount; NSUInteger total=0;
    if(initial<0) { completion(nil); return; }
    NSMutableArray<NSPasteboardItem *> *saved=[NSMutableArray new];
    for(NSPasteboardItem *item in self.pasteboard.pasteboardItems) {
        NSPasteboardItem *snapshot=[NSPasteboardItem new];
        for(NSPasteboardType type in item.types) {
            NSData *data=[item dataForType:type]; if(!data) { completion(nil); return; }
            total+=data.length; if(total>16*1024*1024) { completion(nil); return; }
            [snapshot setData:data forType:type];
        }
        [saved addObject:snapshot];
    }
    if(self.pasteboard.changeCount!=initial || !valid()) { completion(nil); return; }
    self.busy=YES; NSUInteger epoch=++self.epoch;
    if(!copy()) { self.busy=NO; completion(nil); return; }
    [self poll:initial saved:saved epoch:epoch deadline:NSProcessInfo.processInfo.systemUptime+0.65 valid:valid completion:completion];
}
- (void)poll:(NSInteger)initial saved:(NSArray *)saved epoch:(NSUInteger)epoch deadline:(NSTimeInterval)deadline valid:(BOOL (^)(void))valid completion:(void (^)(NSString *))completion {
    if(epoch!=self.epoch) return;
    if(!valid()) { self.busy=NO; completion(nil); return; }
    NSInteger copied=self.pasteboard.changeCount;
    if(copied!=initial) {
        // File copies are never translated as text paths.
        NSString *text=[self.pasteboard.types containsObject:NSPasteboardTypeFileURL] ? nil : [self.pasteboard stringForType:NSPasteboardTypeString];
        text=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(self.pasteboard.changeCount!=copied || !valid()) { self.busy=NO; completion(nil); return; }
        [self.pasteboard clearContents]; if(saved.count) [self.pasteboard writeObjects:saved];
        self.busy=NO; completion(text.length && text.length<=5000 ? text : nil); return;
    }
    if(NSProcessInfo.processInfo.systemUptime>=deadline) { self.busy=NO; completion(nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self poll:initial saved:saved epoch:epoch deadline:deadline valid:valid completion:completion]; });
}
@end

// Sample the pixels behind a bubble before showing it, then blur only its small
// footprint. Native materials have a fixed blur/opacity ratio: lowering their
// alpha brings back sharp background letters. A blurred in-memory sample lets
// the glass retain the page's colors without making those letters readable.
static NSImage *BlurredBubblePixels(CGImageRef full,NSRect frame,NSRect screenFrame) {
    if(!full || NSIsEmptyRect(frame) || NSIsEmptyRect(screenFrame)) return nil;
    CGFloat scaleX=CGImageGetWidth(full)/screenFrame.size.width;
    CGFloat scaleY=CGImageGetHeight(full)/screenFrame.size.height;
    NSRect padded=NSIntersectionRect(NSInsetRect(frame,-48,-48),screenFrame);
    CGRect regionPixels=CGRectIntersection(CGRectIntegral(CGRectMake((NSMinX(padded)-NSMinX(screenFrame))*scaleX,
        (NSMaxY(screenFrame)-NSMaxY(padded))*scaleY,padded.size.width*scaleX,padded.size.height*scaleY)),
        CGRectMake(0,0,CGImageGetWidth(full),CGImageGetHeight(full)));
    if(CGRectIsEmpty(regionPixels)) return nil;
    CGImageRef region=CGImageCreateWithImageInRect(full,regionPixels);
    if(!region) return nil;
    CIImage *input=[[CIImage alloc] initWithCGImage:region];
    CIFilter *filter=[CIFilter filterWithName:@"CIGaussianBlur"];
    [filter setValue:[input imageByClampingToExtent] forKey:kCIInputImageKey];
    [filter setValue:@(18*MIN(scaleX,scaleY)) forKey:kCIInputRadiusKey];
    static CIContext *context; static dispatch_once_t once;
    dispatch_once(&once,^{ context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}]; });
    CGColorSpaceRef colorSpace=CGImageGetColorSpace(region);
    CGColorSpaceRef fallback=colorSpace ? NULL : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef softened=[context createCGImage:filter.outputImage fromRect:input.extent format:kCIFormatRGBA8 colorSpace:colorSpace ?: fallback];
    if(fallback) CGColorSpaceRelease(fallback);
    CGImageRelease(region);
    if(!softened) return nil;
    CGRect bubblePixels=CGRectIntersection(CGRectIntegral(CGRectMake((NSMinX(frame)-NSMinX(padded))*scaleX,
        (NSMaxY(padded)-NSMaxY(frame))*scaleY,frame.size.width*scaleX,frame.size.height*scaleY)),
        CGRectMake(0,0,CGImageGetWidth(softened),CGImageGetHeight(softened)));
    CGImageRef bubble=CGImageCreateWithImageInRect(softened,bubblePixels); CGImageRelease(softened);
    if(!bubble) return nil;
    NSImage *image=[[NSImage alloc] initWithCGImage:bubble size:frame.size]; CGImageRelease(bubble);
    return image;
}
static NSImage *BlurredBubbleBackground(NSRect frame,NSScreen *screen) {
    if(!screen || !CGPreflightScreenCaptureAccess()) return nil;
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    if(!display) return nil;
    NSRect padded=NSIntersectionRect(NSInsetRect(frame,-48,-48),screen.frame);
    if(NSIsEmptyRect(padded)) return nil;
    CGRect local=CGRectMake(NSMinX(padded)-NSMinX(screen.frame),NSMaxY(screen.frame)-NSMaxY(padded),padded.size.width,padded.size.height);
    CGImageRef pixels=CGDisplayCreateImageForRect(display,local);
    NSImage *image=BlurredBubblePixels(pixels,frame,padded);
    if(pixels) CGImageRelease(pixels);
    // Some display drivers do not support the regional API. Preserve the
    // existing full-display path as a fallback and release it immediately.
    if(!image) {
        pixels=CGDisplayCreateImage(display);
        image=BlurredBubblePixels(pixels,frame,screen.frame);
        if(pixels) CGImageRelease(pixels);
    }
    return image;
}

@class BubbleShape;
@interface BubbleSurface : NSView
@property(nonatomic,weak) BubbleShape *shape;
@end
@interface BubbleShape : NSView
@property(nonatomic) BOOL pointsDown;
@property(nonatomic) CGFloat arrowX;
@property(nonatomic) BOOL darkAppearance;
@property(nonatomic) BOOL glassAppearance;
@property(nonatomic) NSVisualEffectView *backdrop;
@property(nonatomic) BubbleSurface *surface;
@property(nonatomic) NSImage *blurredBackground;
@property(nonatomic) CGFloat backgroundLevel;
- (NSBezierPath *)bubblePath;
- (void)updateMask;
@end
@implementation BubbleShape
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _glassAppearance=YES; _backgroundLevel=0.5;
        // Keep the material separate so transparency never fades text or controls.
        _backdrop=[[NSVisualEffectView alloc] initWithFrame:self.bounds];
        _backdrop.autoresizingMask=NSViewWidthSizable | NSViewHeightSizable;
        _backdrop.blendingMode=NSVisualEffectBlendingModeBehindWindow;
        _backdrop.state=NSVisualEffectStateActive; _backdrop.material=NSVisualEffectMaterialMenu;
        [self addSubview:_backdrop];
        _surface=[[BubbleSurface alloc] initWithFrame:self.bounds]; _surface.shape=self;
        _surface.autoresizingMask=NSViewWidthSizable | NSViewHeightSizable; [self addSubview:_surface];
    }
    return self;
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self updateMask]; }
- (void)setPointsDown:(BOOL)value { _pointsDown=value; [self updateMask]; }
- (void)setArrowX:(CGFloat)value { _arrowX=value; [self updateMask]; }
- (void)setDarkAppearance:(BOOL)value {
    _darkAppearance=value;
    self.backdrop.material=value ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialMenu;
    // With a blurred screen sample, only a small fraction of the live material
    // remains visible; without one, use full material strength for readability.
    self.backdrop.alphaValue=self.blurredBackground ? 0.58 : 1;
    self.surface.needsDisplay=YES;
    self.needsDisplay=YES;
}
- (void)setBackgroundLevel:(CGFloat)value {
    _backgroundLevel=MIN(1,MAX(0,isfinite(value) ? value : 0.5));
    self.surface.needsDisplay=YES;
}
- (void)setBlurredBackground:(NSImage *)image {
    _blurredBackground=image;
    self.backdrop.alphaValue=image ? 0.58 : 1;
    self.surface.needsDisplay=YES;
}
- (void)setGlassAppearance:(BOOL)value {
    _glassAppearance=value;
    self.backdrop.hidden=!value;
    self.surface.needsDisplay=YES;
    self.needsDisplay=YES;
}
- (NSBezierPath *)bubblePath {
    NSRect body = NSMakeRect(0.5, self.pointsDown ? 8.5 : 0.5, self.bounds.size.width - 1, self.bounds.size.height - 9);
    CGFloat left=NSMinX(body),right=NSMaxX(body),bottom=NSMinY(body),top=NSMaxY(body),radius=18,curve=radius*0.55228475;
    CGFloat x = MIN(MAX(self.arrowX, 28), self.bounds.size.width - 28);
    CGFloat tip = self.pointsDown ? 0.5 : self.bounds.size.height - 0.5;
    NSBezierPath *path=[NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(left+radius,bottom)];
    if(self.pointsDown) { [path lineToPoint:NSMakePoint(x-6,bottom)]; [path lineToPoint:NSMakePoint(x,tip)]; [path lineToPoint:NSMakePoint(x+6,bottom)]; }
    [path lineToPoint:NSMakePoint(right-radius,bottom)];
    [path curveToPoint:NSMakePoint(right,bottom+radius) controlPoint1:NSMakePoint(right-radius+curve,bottom) controlPoint2:NSMakePoint(right,bottom+radius-curve)];
    [path lineToPoint:NSMakePoint(right,top-radius)];
    [path curveToPoint:NSMakePoint(right-radius,top) controlPoint1:NSMakePoint(right,top-radius+curve) controlPoint2:NSMakePoint(right-radius+curve,top)];
    if(!self.pointsDown) { [path lineToPoint:NSMakePoint(x+6,top)]; [path lineToPoint:NSMakePoint(x,tip)]; [path lineToPoint:NSMakePoint(x-6,top)]; }
    [path lineToPoint:NSMakePoint(left+radius,top)];
    [path curveToPoint:NSMakePoint(left,top-radius) controlPoint1:NSMakePoint(left+radius-curve,top) controlPoint2:NSMakePoint(left,top-radius+curve)];
    [path lineToPoint:NSMakePoint(left,bottom+radius)];
    [path curveToPoint:NSMakePoint(left+radius,bottom) controlPoint1:NSMakePoint(left,bottom+radius-curve) controlPoint2:NSMakePoint(left+radius-curve,bottom)]; [path closePath];
    return path;
}
- (void)updateMask {
    if(self.bounds.size.width<1 || self.bounds.size.height<1) return;
    NSImage *mask=[[NSImage alloc] initWithSize:self.bounds.size]; [mask lockFocus];
    [NSColor.whiteColor setFill]; [[self bubblePath] fill]; [mask unlockFocus];
    self.backdrop.frame=self.bounds; self.backdrop.maskImage=mask;
    self.surface.frame=self.bounds; self.surface.needsDisplay=YES;
    self.needsDisplay=YES;
}
@end
@implementation BubbleSurface
- (void)drawShade:(NSBezierPath *)path {
    CGFloat delta=self.shape.backgroundLevel-0.5;
    [[NSColor colorWithCalibratedWhite:delta>=0 ? 1 : 0 alpha:fabs(delta)*0.36] setFill]; [path fill];
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path=[self.shape bubblePath];
    if(!self.shape.glassAppearance) {
        NSColor *top=self.shape.darkAppearance ? [NSColor colorWithCalibratedRed:0.14 green:0.16 blue:0.19 alpha:1] : [NSColor colorWithCalibratedWhite:1 alpha:1];
        NSColor *bottom=self.shape.darkAppearance ? [NSColor colorWithCalibratedRed:0.09 green:0.105 blue:0.13 alpha:1] : [NSColor colorWithCalibratedRed:0.975 green:0.98 blue:0.985 alpha:1];
        NSGradient *gradient=[[NSGradient alloc] initWithStartingColor:top endingColor:bottom]; [gradient drawInBezierPath:path angle:-90]; [self drawShade:path];
        [(self.shape.darkAppearance ? [NSColor colorWithCalibratedWhite:1 alpha:0.13] : [NSColor colorWithCalibratedWhite:0.18 alpha:0.12]) setStroke];
        path.lineWidth=0.7; path.lineJoinStyle=NSLineJoinStyleRound; [path stroke]; return;
    }
    if(self.shape.blurredBackground) {
        [NSGraphicsContext saveGraphicsState]; [path addClip];
        [self.shape.blurredBackground drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.82];
        [NSGraphicsContext restoreGraphicsState];
    }
    NSColor *top=self.shape.darkAppearance ? [NSColor colorWithCalibratedWhite:0 alpha:0.30] : [NSColor colorWithCalibratedWhite:1 alpha:0.26];
    NSColor *bottom=self.shape.darkAppearance ? [NSColor colorWithCalibratedWhite:0 alpha:0.26] : [NSColor colorWithCalibratedWhite:1 alpha:0.22];
    [[[NSGradient alloc] initWithStartingColor:top endingColor:bottom] drawInBezierPath:path angle:-90];
    [self drawShade:path];
    [[NSColor colorWithCalibratedWhite:1 alpha:self.shape.darkAppearance ? 0.22 : 0.60] setStroke];
    path.lineWidth=0.75; path.lineJoinStyle=NSLineJoinStyleRound; [path stroke];
}
@end
@interface BubblePanel : NSPanel @end
@implementation BubblePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface BubbleButton : NSButton @end
@implementation BubbleButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
@end
@interface BubbleShadeControl : BubbleButton
@property BOOL dragging;
@property CGFloat level;
@property CGFloat startLevel;
@property CGFloat startY;
@property(copy) void (^levelChanged)(CGFloat,BOOL);
@end
@implementation BubbleShadeControl
- (void)mouseDown:(NSEvent *)event {
    self.dragging=YES; self.startY=event.locationInWindow.y; self.startLevel=self.level;
}
- (void)mouseDragged:(NSEvent *)event {
    self.level=MIN(1,MAX(0,self.startLevel+(event.locationInWindow.y-self.startY)/160.0));
    if(self.levelChanged) self.levelChanged(self.level,NO);
}
- (void)mouseUp:(NSEvent *)event {
    if(!self.dragging) return;
    [self mouseDragged:event]; self.dragging=NO;
    if(self.levelChanged) self.levelChanged(self.level,YES);
}
@end
@interface BubbleLanguagePicker : NSPopUpButton @end
@implementation BubbleLanguagePicker
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSColor *color=self.contentTintColor ?: NSColor.secondaryLabelColor;
    NSDictionary *attrs=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:color};
    NSSize size=[self.title sizeWithAttributes:attrs];
    [self.title drawAtPoint:NSMakePoint(0,(self.bounds.size.height-size.height)/2) withAttributes:attrs];
    NSBezierPath *chevron=[NSBezierPath bezierPath]; chevron.lineWidth=1; chevron.lineCapStyle=NSLineCapStyleRound;
    CGFloat x=MIN(size.width+8,self.bounds.size.width-10),y=NSMidY(self.bounds)-1;
    [chevron moveToPoint:NSMakePoint(x,y)]; [chevron lineToPoint:NSMakePoint(x+3,y+3)]; [chevron lineToPoint:NSMakePoint(x+6,y)]; [color setStroke]; [chevron stroke];
}
@end
static NSString *SelectedBubbleAppearance(void) {
    NSString *style = [NSUserDefaults.standardUserDefaults stringForKey:@"bubbleAppearance"];
    return [@[@"white", @"black", @"light", @"dark"] containsObject:style ?: @""] ? style : @"light";
}
@interface Bubble : NSObject <NSMenuDelegate>
@property BubblePanel *panel;
@property BubbleShape *shape;
@property NSScrollView *scroll;
@property NSTextView *textView;
@property NSPopUpButton *languagePicker;
@property NSButton *swapButton;
@property NSString *targetCode;
@property (copy) void (^targetChanged)(NSString *);
@property NSTextField *scrollHint;
@property NSButton *clipboardButton;
@property NSButton *speechButton;
@property BubbleShadeControl *shadeControl;
@property NSString *appearanceKey;
@property NSString *translation;
@property CGFloat documentHeight;
@property BOOL scrollable;
@property BOOL languageMenuOpen;
@property NSTimeInterval interactionUntil;
- (void)applyAppearance;
- (BOOL)isInteracting;
- (void)show:(NSString *)text anchor:(NSRect)anchor result:(BOOL)result;
- (void)layoutText:(NSString *)text anchor:(NSRect)anchor result:(BOOL)result display:(BOOL)display;
- (void)hide;
@end
@implementation Bubble
- (instancetype)init {
    if ((self = [super init])) {
        _panel = [[BubblePanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        _panel.opaque = NO; _panel.backgroundColor = NSColor.clearColor; _panel.hasShadow = YES;
        _panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        _panel.level = NSStatusWindowLevel; _panel.hidesOnDeactivate = NO;
        _panel.floatingPanel = YES; _panel.becomesKeyOnlyIfNeeded = NO; _panel.ignoresMouseEvents = NO;
        _panel.title = @"翻译气泡";
        [_panel setAccessibilityElement:YES]; [_panel setAccessibilityRole:NSAccessibilityWindowRole]; [_panel setAccessibilityLabel:@"翻译气泡"];
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        _shape = [BubbleShape new]; _panel.contentView = _shape;
        _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scroll.borderType = NSNoBorder; _scroll.drawsBackground = NO;
        _scroll.scrollerStyle = NSScrollerStyleOverlay; _scroll.autohidesScrollers = YES;
        _scroll.scrollerKnobStyle = NSScrollerKnobStyleDark;
        _scroll.hasHorizontalScroller = NO; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
        _scroll.contentView.drawsBackground = NO;
        _textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
        _textView.editable = NO; _textView.selectable = NO; _textView.drawsBackground = NO;
        _textView.textContainerInset = NSZeroSize; _textView.textContainer.lineFragmentPadding = 0;
        _textView.verticallyResizable = YES; _textView.horizontallyResizable = NO;
        _textView.minSize = NSZeroSize; _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        // Size the container separately so a long translation leaves room for
        // the overlay scrollbar without shifting the scroll view.
        _textView.textContainer.widthTracksTextView = NO;
        _textView.textContainer.heightTracksTextView = NO;
        _scroll.documentView = _textView; [_shape addSubview:_scroll];
        _targetCode = @"zh-CN";
        _languagePicker = [[BubbleLanguagePicker alloc] initWithFrame:NSZeroRect pullsDown:NO];
        _languagePicker.bordered = NO; _languagePicker.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        _languagePicker.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        PopulateLanguages(_languagePicker, self, @selector(languageSelected:));
        _languagePicker.menu.delegate = self;
        _languagePicker.toolTip = @"选择本次和后续翻译的目标语言";
        [_shape addSubview:_languagePicker];
        _swapButton = [BubbleButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right" accessibilityDescription:@"中英文切换"] target:self action:@selector(swapLanguage:)];
        _swapButton.bordered = NO; _swapButton.contentTintColor = [NSColor colorWithCalibratedWhite:0.36 alpha:1];
        _swapButton.image=[_swapButton.image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
        _swapButton.toolTip = @"一键切换中文 / 英文"; [_shape addSubview:_swapButton];
        _scrollHint = [NSTextField labelWithString:@"滚动查看完整译文"];
        _scrollHint.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
        _scrollHint.textColor = [NSColor colorWithCalibratedWhite:0.48 alpha:1]; [_shape addSubview:_scrollHint];
        _clipboardButton = [BubbleButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:@"复制完整译文"] target:self action:@selector(copyResult:)];
        _clipboardButton.bordered = NO; _clipboardButton.imagePosition = NSImageOnly;
        _clipboardButton.image=[_clipboardButton.image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
        _clipboardButton.contentTintColor = [NSColor colorWithCalibratedWhite:0.36 alpha:1]; _clipboardButton.toolTip = @"复制完整译文";
        [_shape addSubview:_clipboardButton];
        _speechButton = [[BubbleButton alloc] initWithFrame:NSZeroRect];
        _speechButton.bordered = NO;
        _speechButton.imagePosition = NSImageOnly;
        UpdateSpeechButton(_speechButton, @"朗读译文", NO);
        [_shape addSubview:_speechButton];
        _shadeControl=[[BubbleShadeControl alloc] initWithFrame:NSZeroRect];
        _shadeControl.bordered=NO; _shadeControl.imagePosition=NSImageOnly;
        _shadeControl.image=[[NSImage imageWithSystemSymbolName:@"circle.lefthalf.filled" accessibilityDescription:@"背景深浅"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
        _shadeControl.toolTip=@"按住上下拖动：向上变浅，向下变深；松开自动保存";
        __weak Bubble *weakSelf=self;
        _shadeControl.levelChanged=^(CGFloat level,BOOL save) {
            Bubble *self=weakSelf; if(!self) return;
            self.shape.backgroundLevel=level;
            self.interactionUntil=NSProcessInfo.processInfo.systemUptime+0.4;
            if(save) {
                NSMutableDictionary *levels=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"bubbleBackgroundLevels"] mutableCopy] ?: [NSMutableDictionary new];
                levels[self.appearanceKey]=@(level);
                [NSUserDefaults.standardUserDefaults setObject:levels forKey:@"bubbleBackgroundLevels"];
            }
        };
        [_shape addSubview:_shadeControl];
        [_textView addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(copyResult:)]];
        [self applyAppearance];
    }
    return self;
}
- (NSColor *)foregroundColor {
    return self.shape.darkAppearance ? [NSColor colorWithCalibratedWhite:0.96 alpha:1] : [NSColor colorWithCalibratedWhite:0.08 alpha:1];
}
- (void)applyAppearance {
    NSString *style = SelectedBubbleAppearance();
    BOOL dark=[style isEqual:@"dark"] || [style isEqual:@"black"];
    self.shape.darkAppearance=dark;
    self.shape.glassAppearance=![style isEqual:@"white"] && ![style isEqual:@"black"];
    self.appearanceKey=style;
    id saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"bubbleBackgroundLevels"][style];
    self.shape.backgroundLevel=[saved isKindOfClass:NSNumber.class] ? [saved doubleValue] : 0.5;
    self.shadeControl.level=self.shape.backgroundLevel;
    BOOL lightInk=dark;
    self.panel.appearance=[NSAppearance appearanceNamed:lightInk ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    self.languagePicker.appearance=self.panel.appearance;
    self.languagePicker.contentTintColor=lightInk ? [NSColor colorWithCalibratedWhite:0.83 alpha:1] : [NSColor colorWithCalibratedWhite:0.30 alpha:1];
    self.languagePicker.needsDisplay=YES;
    self.scroll.scrollerKnobStyle=lightInk ? NSScrollerKnobStyleLight : NSScrollerKnobStyleDark;
    NSColor *tint=lightInk ? [NSColor colorWithCalibratedWhite:0.76 alpha:1] : [NSColor colorWithCalibratedWhite:0.47 alpha:1];
    self.swapButton.contentTintColor=tint; self.clipboardButton.contentTintColor=tint; self.shadeControl.contentTintColor=tint;
    self.speechButton.contentTintColor = tint;
    self.scrollHint.textColor=lightInk ? [NSColor colorWithCalibratedWhite:0.82 alpha:1] : [NSColor colorWithCalibratedWhite:0.48 alpha:1];
    [self.textView.textStorage addAttribute:NSForegroundColorAttributeName value:self.foregroundColor range:NSMakeRange(0,self.textView.string.length)];
    self.shape.needsDisplay=YES;
}
- (BOOL)isInteracting {
    return self.panel.visible && (self.languageMenuOpen || self.shadeControl.dragging || NSProcessInfo.processInfo.systemUptime < self.interactionUntil || NSPointInRect(NSEvent.mouseLocation,self.panel.frame));
}
- (void)menuWillOpen:(NSMenu *)menu { self.languageMenuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu {
    self.languageMenuOpen = NO;
    self.interactionUntil = NSProcessInfo.processInfo.systemUptime + 0.4;
}
- (void)languageSelected:(NSPopUpButton *)sender {
    NSString *code = sender.selectedItem.representedObject;
    if (self.targetChanged) self.targetChanged(code);
}
- (void)swapLanguage:(id)sender {
    NSString *code = [self.targetCode isEqual:@"en"] ? @"zh-CN" : @"en";
    if (self.targetChanged) self.targetChanged(code);
}
- (void)copyResult:(id)sender {
    if (!self.translation.length) return;
    [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:self.translation forType:NSPasteboardTypeString];
    self.clipboardButton.image = [[NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:@"已复制"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
    self.clipboardButton.toolTip = @"已复制完整译文";
}
- (void)show:(NSString *)text anchor:(NSRect)anchor result:(BOOL)result {
    [self layoutText:text anchor:anchor result:result display:YES];
}
- (void)layoutText:(NSString *)text anchor:(NSRect)anchor result:(BOOL)result display:(BOOL)display {
    self.translation = result ? text : nil;
    SelectLanguage(self.languagePicker, self.targetCode);
    self.clipboardButton.hidden = !result;
    self.speechButton.hidden = !result;
    self.clipboardButton.image = [[NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:@"复制完整译文"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
    self.clipboardButton.toolTip = @"复制完整译文";
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSPoint anchorCenter = NSMakePoint(NSMidX(anchor), NSMidY(anchor));
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(anchorCenter, candidate.frame)) { screen = candidate; break; }
    NSRect visible = NSInsetRect(screen.visibleFrame, 12, 12);
    NSFont *font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    const CGFloat inset = 18;
    const CGFloat headerOffset = 28;
    const CGFloat bodyInset = 8;
    const CGFloat overhead = 52;
    const CGFloat scrollFooter = 17;
    const CGFloat minimumViewport = 20;
    CGFloat singleWidth = [text sizeWithAttributes:@{NSFontAttributeName:font}].width;
    BOOL compact = text.length < 24 && [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound && singleWidth < 270;
    CGFloat width = MIN(visible.size.width, compact ? MAX(result ? 250 : 214, ceil(singleWidth) + 2 * inset) : 420);
    CGFloat contentWidth = width - 2 * inset;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping; paragraph.lineSpacing = compact ? 1 : 4;
    paragraph.paragraphSpacing = compact ? 0 : 2;
    NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:self.foregroundColor, NSParagraphStyleAttributeName:paragraph};
    self.textView.frame = NSMakeRect(0, 0, contentWidth, 1);
    self.textView.textContainer.containerSize = NSMakeSize(contentWidth, CGFLOAT_MAX);
    [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    NSRect used = [self.textView.layoutManager usedRectForTextContainer:self.textView.textContainer];
    self.documentHeight = MAX(18, ceil(NSMaxY(used)) + 2);
    CGFloat aboveSpace = MAX(0, NSMaxY(visible) - NSMaxY(anchor) - 8);
    CGFloat belowSpace = MAX(0, NSMinY(anchor) - NSMinY(visible) - 8);
    // When there is room to read above the selection, scroll long results there.
    const CGFloat minimumHeight = overhead + scrollFooter + minimumViewport;
    CGFloat availableSpace = aboveSpace >= minimumHeight ? aboveSpace : MAX(aboveSpace, belowSpace);
    CGFloat maxHeight = MIN(360, MAX(minimumHeight, availableSpace));
    CGFloat maxViewport = maxHeight - overhead - scrollFooter;
    self.scrollable = self.documentHeight > maxHeight - overhead;
    if (self.scrollable) {
        // Overlay scrollers draw on top of their document. Reflow the text inside
        // a narrower container so final glyphs cannot sit under the thumb.
        self.textView.textContainer.containerSize = NSMakeSize(contentWidth - 18, CGFLOAT_MAX);
        [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
        NSRect scrolledText = [self.textView.layoutManager usedRectForTextContainer:self.textView.textContainer];
        self.documentHeight = MAX(20, ceil(NSMaxY(scrolledText)) + 2);
    }
    CGFloat viewport = self.scrollable ? maxViewport : self.documentHeight;
    CGFloat footer = self.scrollable ? scrollFooter : 0;
    CGFloat height = viewport + overhead + footer;
    CGFloat x = MIN(MAX(NSMidX(anchor) - width / 2, NSMinX(visible)), NSMaxX(visible) - width);
    self.shape.pointsDown = aboveSpace >= height || aboveSpace >= belowSpace;
    CGFloat y = self.shape.pointsDown ? NSMaxY(anchor) + 8 : NSMinY(anchor) - height - 8;
    y = MIN(MAX(y, NSMinY(visible)), NSMaxY(visible) - height);
    [self.panel setFrame:NSMakeRect(x, y, width, height) display:NO];
    if(display) {
        [self.panel orderOut:nil];
        self.shape.blurredBackground=self.shape.glassAppearance ? BlurredBubbleBackground(self.panel.frame,screen) : nil;
    }
    self.shape.frame = NSMakeRect(0, 0, width, height); self.shape.arrowX = NSMidX(anchor) - x;
    CGFloat bodyBottom = self.shape.pointsDown ? 8 : 0;
    CGFloat bodyTop = height - (self.shape.pointsDown ? 0 : 8);
    self.languagePicker.frame = NSMakeRect(inset, bodyTop - headerOffset, 100, 22);
    const CGFloat buttonSize = 24;
    const CGFloat buttonStep = 27;
    CGFloat lastButtonX = width - inset - buttonSize;
    CGFloat buttonY = bodyTop - headerOffset - 1;
    self.clipboardButton.frame = NSMakeRect(lastButtonX, buttonY, buttonSize, buttonSize);
    self.shadeControl.frame = NSMakeRect(lastButtonX - (result ? buttonStep : 0), buttonY, buttonSize, buttonSize);
    self.speechButton.frame = NSMakeRect(lastButtonX - 2 * buttonStep, buttonY, buttonSize, buttonSize);
    self.swapButton.frame = NSMakeRect(lastButtonX - (result ? 3 : 1) * buttonStep, buttonY, buttonSize, buttonSize);
    self.scrollHint.hidden = !self.scrollable;
    self.scrollHint.frame = NSMakeRect(inset, bodyBottom + bodyInset, contentWidth, 15);
    self.scroll.frame = NSMakeRect(inset, bodyBottom + bodyInset + footer, contentWidth, viewport);
    self.scroll.hasVerticalScroller = self.scrollable;
    self.textView.frame = NSMakeRect(0, 0, contentWidth, self.documentHeight);
    [self.scroll.contentView scrollToPoint:NSZeroPoint]; [self.scroll reflectScrolledClipView:self.scroll.contentView];
    self.shape.needsDisplay = YES;
    if (display) [self.panel orderFrontRegardless];
}
- (void)hide { [self.panel orderOut:nil]; self.shape.blurredBackground=nil; }
@end

typedef void (^CaptureCompletion)(NSRect);
@interface CaptureFrame : NSObject
@property NSRect frame;
@property NSBitmapImageRep *bitmap;
@end
@implementation CaptureFrame @end

static NSBitmapImageRep *CopyCaptureBitmap(CGImageRef image) {
    if(!image) return nil;
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width || !height) return nil;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    // Keep the screenshot's profile with its pixels. Converting every display
    // to sRGB and then presenting untagged DeviceRGB shifts wide-gamut colors.
    CGColorSpaceRef sourceSpace=CGImageGetColorSpace(image);
    CGColorSpaceRef space=(sourceSpace && CGColorSpaceGetModel(sourceSpace)==kCGColorSpaceModelRGB) ? CGColorSpaceRetain(sourceSpace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSColorSpace *profile=[[NSColorSpace alloc] initWithCGColorSpace:space];
    CGContextRef context=CGBitmapContextCreate(bitmap.bitmapData,width,height,8,bitmap.bytesPerRow,space,kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if(!context) return nil;
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image); CGContextRelease(context);
    return [bitmap bitmapImageRepByRetaggingWithColorSpace:profile];
}
static NSBitmapImageRep *CopyConfiguredCaptureBitmap(CGImageRef image,CGColorSpaceRef outputSpace) {
    if(!image) return nil;
    CGColorSpaceRef sourceSpace=CGImageGetColorSpace(image),device=CGColorSpaceCreateDeviceRGB();
    BOOL unmanaged=!sourceSpace || CFEqual(sourceSpace,device); CGColorSpaceRelease(device);
    // ScreenCaptureKit can return DeviceRGB even when its output space was
    // explicitly requested. Attach that known profile before AppKit draws it.
    // A valid, already-tagged image must never be relabelled as another space.
    if(!unmanaged || !outputSpace) return CopyCaptureBitmap(image);
    CGImageRef tagged=CGImageCreateCopyWithColorSpace(image,outputSpace);
    NSBitmapImageRep *bitmap=CopyCaptureBitmap(tagged); if(tagged) CGImageRelease(tagged);
    return bitmap;
}
static CFStringRef CaptureOutputColorSpaceName(NSScreen *screen) {
    CGColorSpaceRef profile=screen.colorSpace.CGColorSpace;
    return profile && CGColorSpaceIsWideGamutRGB(profile) ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB;
}
static BOOL CaptureBitmapHasVisiblePixels(NSBitmapImageRep *bitmap) {
    if(!bitmap || !bitmap.pixelsWide || !bitmap.pixelsHigh) return NO;
    NSUInteger pixel[4];
    for(NSInteger row=0;row<25;row++) for(NSInteger column=0;column<41;column++) {
        NSInteger x=MIN(bitmap.pixelsWide-1,(2*column+1)*bitmap.pixelsWide/82);
        NSInteger y=MIN(bitmap.pixelsHigh-1,(2*row+1)*bitmap.pixelsHigh/50);
        [bitmap getPixel:pixel atX:x y:y];
        if(pixel[3] && (pixel[0] || pixel[1] || pixel[2])) return YES;
    }
    return NO;
}

static CGImageRef CreateCaptureCrop(CaptureFrame *source, NSRect selection) CF_RETURNS_RETAINED {
    if(!source.bitmap || NSIsEmptyRect(source.frame) || NSIsEmptyRect(selection)) return NULL;
    NSRect clipped=NSIntersectionRect(selection,source.frame);
    if(NSIsEmptyRect(clipped)) return NULL;
    CGImageRef image=source.bitmap.CGImage;
    CGFloat scaleX=CGImageGetWidth(image)/source.frame.size.width;
    CGFloat scaleY=CGImageGetHeight(image)/source.frame.size.height;
    CGRect pixels=CGRectMake((NSMinX(clipped)-NSMinX(source.frame))*scaleX,
                             (NSMaxY(source.frame)-NSMaxY(clipped))*scaleY,
                             clipped.size.width*scaleX,clipped.size.height*scaleY);
    return CGImageCreateWithImageInRect(image,CGRectIntegral(pixels));
}
@interface CaptureView : NSView
@property NSPoint start;
@property NSRect selection;
@property BOOL dragging;
@property BOOL finished;
@property NSImage *snapshot;
@property (copy) CaptureCompletion completion;
@end
@implementation CaptureView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects {
    static NSCursor *captureCursor; static dispatch_once_t once;
    dispatch_once(&once,^{
        NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(27,27)]; [image lockFocus];
        NSBezierPath *cross=[NSBezierPath bezierPath];
        [cross moveToPoint:NSMakePoint(0.5,13.5)]; [cross lineToPoint:NSMakePoint(26.5,13.5)];
        [cross moveToPoint:NSMakePoint(13.5,0.5)]; [cross lineToPoint:NSMakePoint(13.5,26.5)];
        [cross appendBezierPathWithOvalInRect:NSMakeRect(7.5,7.5,12,12)];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.85] setStroke]; cross.lineWidth=2.5; [cross stroke];
        [NSColor.blackColor setStroke]; cross.lineWidth=1; [cross stroke]; [image unlockFocus];
        captureCursor=[[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(13.5,13.5)];
    });
    [self addCursorRect:self.bounds cursor:captureCursor];
}
- (void)drawRect:(NSRect)dirtyRect {
    [self.snapshot drawInRect:self.bounds];
    NSShadow *textShadow=[NSShadow new]; textShadow.shadowColor=NSColor.whiteColor; textShadow.shadowBlurRadius=2; textShadow.shadowOffset=NSZeroSize;
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],NSForegroundColorAttributeName:NSColor.blackColor,NSShadowAttributeName:textShadow};
    if (self.dragging && !NSIsEmptyRect(self.selection)) {
        // Shade only the selected region. SourceOver preserves the frozen menu pixels.
        [[NSColor colorWithCalibratedWhite:0 alpha:0.16] setFill];
        NSRectFillUsingOperation(self.selection,NSCompositingOperationSourceOver);
        CGFloat scale=self.window.backingScaleFactor; if(scale<=0) scale=1;
        NSString *dimensions=[NSString stringWithFormat:@"%.0f\n%.0f",self.selection.size.width*scale,self.selection.size.height*scale];
        NSSize size=[dimensions sizeWithAttributes:attrs];
        NSPoint pointer=[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        if(!self.window) pointer=NSMakePoint(NSMaxX(self.selection),NSMinY(self.selection));
        CGFloat x=pointer.x+9,y=pointer.y-size.height-2;
        if(x+size.width>NSMaxX(self.bounds)-8) x=pointer.x-size.width-9;
        if(y<8) y=pointer.y+9;
        [dimensions drawAtPoint:NSMakePoint(MAX(8,x),MIN(y,NSMaxY(self.bounds)-size.height-8)) withAttributes:attrs];
    }
    NSString *hint=self.dragging ? @"松开鼠标翻译  ·  Esc 或右键取消" : @"拖动框选翻译  ·  Esc 或右键取消";
    NSShadow *hintShadow=[NSShadow new];
    hintShadow.shadowColor=[NSColor colorWithCalibratedWhite:0 alpha:0.8];
    hintShadow.shadowBlurRadius=3;
    hintShadow.shadowOffset=NSMakeSize(0,-1);
    NSDictionary *hintAttrs=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor,NSStrokeColorAttributeName:[NSColor colorWithCalibratedWhite:0 alpha:0.75],NSStrokeWidthAttributeName:@(-2),NSShadowAttributeName:hintShadow};
    NSSize hintSize=[hint sizeWithAttributes:hintAttrs];
    [hint drawAtPoint:NSMakePoint(round((self.bounds.size.width-hintSize.width)/2),34) withAttributes:hintAttrs];
}
- (void)completeSelection:(NSRect)rect {
    if (self.finished) return;
    self.finished=YES; self.dragging=NO;
    if (self.completion) self.completion(rect);
}
- (void)mouseDown:(NSEvent *)event { if(self.finished) return; self.start = [self convertPoint:event.locationInWindow fromView:nil]; self.dragging = YES; self.selection = NSZeroRect; self.needsDisplay = YES; }
- (void)mouseDragged:(NSEvent *)event { if(!self.dragging || self.finished) return; NSPoint end = [self convertPoint:event.locationInWindow fromView:nil]; self.selection = NSMakeRect(MIN(end.x,self.start.x),MIN(end.y,self.start.y),fabs(end.x-self.start.x),fabs(end.y-self.start.y)); self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)event {
    // Ignore the menu item's opening mouse-up: a selection needs its own press.
    if(!self.dragging || self.finished) return;
    [self mouseDragged:event];
    [self completeSelection:self.selection.size.width >= 5 && self.selection.size.height >= 5 ? [self.window convertRectToScreen:self.selection] : NSZeroRect];
}
- (void)rightMouseDown:(NSEvent *)event { [self completeSelection:NSZeroRect]; }
- (void)keyDown:(NSEvent *)event { if (event.keyCode == 53) [self completeSelection:NSZeroRect]; else [super keyDown:event]; }
@end
@interface CaptureWindow : NSPanel @end
@implementation CaptureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSArray<VNRecognizedTextObservation *> *RecognizePass(CGImageRef image, NSArray *languages, BOOL automatic, NSError **error) {
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new]; request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection=YES; request.automaticallyDetectsLanguage=automatic; request.recognitionLanguages=languages;
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:error]) return nil;
    return request.results;
}
static NSString *RecognizeImage(CGImageRef image, NSError **error) {
    NSArray *supported=[[VNRecognizeTextRequest new] supportedRecognitionLanguagesAndReturnError:error]; if (!supported) return nil;
    NSMutableArray *languages=[NSMutableArray new];
    for (NSString *code in @[@"zh-Hans",@"zh-Hant",@"en-US",@"ko-KR",@"ja-JP",@"fr-FR",@"de-DE",@"es-ES",@"ru-RU"]) if ([supported containsObject:code]) [languages addObject:code];
    NSArray *first=RecognizePass(image,languages,YES,error); if (!first) return nil;
    NSMutableArray *observations=[first mutableCopy];
    // Automatic detection can omit a Korean row in a Chinese/Japanese image.
    // Supplement only observations containing the requested script, merging by
    // their image coordinates so the same row is never emitted twice.
    for (NSArray *pass in @[@[@"ko-KR",@"\\p{Hangul}"],@[@"ja-JP",@"[\\p{Hiragana}\\p{Katakana}]"]]) {
        if (![supported containsObject:pass[0]]) continue;
        NSError *supplementError=nil;
        NSArray *supplement=RecognizePass(image,@[pass[0],@"en-US"],NO,&supplementError);
        for (VNRecognizedTextObservation *observation in supplement) {
            VNRecognizedText *candidate=[observation topCandidates:1].firstObject;
            if (candidate.confidence<0.35 || [candidate.string rangeOfString:pass[1] options:NSRegularExpressionSearch].location==NSNotFound) continue;
            NSInteger match=-1;
            for (NSUInteger i=0;i<observations.count;i++) {
                CGRect existing=[observations[i] boundingBox], box=observation.boundingBox, intersection=CGRectIntersection(existing,box);
                CGFloat overlap=CGRectIsNull(intersection) ? 0 : intersection.size.width*intersection.size.height;
                CGFloat smaller=MIN(existing.size.width*existing.size.height,box.size.width*box.size.height);
                if (smaller>0 && overlap/smaller>0.6) { match=(NSInteger)i; break; }
            }
            if (match>=0) observations[(NSUInteger)match]=observation; else [observations addObject:observation];
        }
    }
    [observations sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *left,VNRecognizedTextObservation *right){
        NSInteger rowA=(NSInteger)floor((1-CGRectGetMidY(left.boundingBox))*70),rowB=(NSInteger)floor((1-CGRectGetMidY(right.boundingBox))*70);
        if (rowA!=rowB) return rowA<rowB ? NSOrderedAscending:NSOrderedDescending;
        return left.boundingBox.origin.x<right.boundingBox.origin.x ? NSOrderedAscending:NSOrderedDescending;
    }];
    NSMutableArray *lines=[NSMutableArray new]; for (VNRecognizedTextObservation *observation in observations) { NSString *line=[observation topCandidates:1].firstObject.string; if (line.length) [lines addObject:line]; }
    return [lines componentsJoinedByString:@"\n"];
}

@interface MainBackground : NSView @end
@implementation MainBackground
- (void)drawRect:(NSRect)dirtyRect {
    NSGradient *gradient=[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.985 green:0.982 blue:0.970 alpha:1] endingColor:[NSColor colorWithCalibratedRed:0.925 green:0.941 blue:0.953 alpha:1]];
    [gradient drawInRect:self.bounds angle:-65];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.055] setStroke]; NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(28,130)]; [line lineToPoint:NSMakePoint(self.bounds.size.width-28,130)]; line.lineWidth=0.6; [line stroke];
}
@end
@interface ReadingCard : NSView
@property BOOL subtle;
@end
@implementation ReadingCard
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect=NSInsetRect(self.bounds,1,1); NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:self.subtle?16:20 yRadius:self.subtle?16:20];
    [NSGraphicsContext saveGraphicsState]; NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(0,-2); shadow.shadowBlurRadius=10; shadow.shadowColor=[NSColor colorWithCalibratedWhite:0 alpha:self.subtle?0.015:0.04]; [shadow set];
    [[NSColor colorWithCalibratedWhite:1 alpha:self.subtle?0.58:0.93] setFill]; [path fill]; [NSGraphicsContext restoreGraphicsState];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.055] setStroke]; path.lineWidth=0.6; [path stroke];
}
@end
// Row labels use the same vertical text-centering as popup titles and buttons.
// NSTextField's default top alignment otherwise lifts smaller secondary labels.
@interface MainRowLabel : NSTextField @end
@implementation MainRowLabel
- (void)drawRect:(NSRect)dirtyRect {
    NSDictionary *attributes=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:self.textColor};
    NSSize size=[self.stringValue sizeWithAttributes:attributes];
    [self.stringValue drawAtPoint:NSMakePoint(2,(self.bounds.size.height-size.height)/2) withAttributes:attributes];
}
@end
@interface SoftButton : NSButton
@property BOOL prominent;
@end
@implementation SoftButton
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect=NSInsetRect(self.bounds,0.5,0.5); NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:rect.size.height/2 yRadius:rect.size.height/2];
    NSColor *fill=self.prominent ? [NSColor colorWithCalibratedRed:0.12 green:0.145 blue:0.17 alpha:1] : [NSColor colorWithCalibratedWhite:1 alpha:0.75];
    if (self.cell.highlighted) fill=self.prominent?[NSColor colorWithCalibratedWhite:0.28 alpha:1]:[NSColor colorWithCalibratedWhite:0.92 alpha:1];
    [fill setFill]; [path fill]; if (!self.prominent) { [[NSColor colorWithCalibratedWhite:0 alpha:0.08] setStroke]; path.lineWidth=0.6; [path stroke]; }
    NSFont *font=self.font?:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    NSDictionary *attrs=@{NSFontAttributeName:font,NSForegroundColorAttributeName:self.prominent?NSColor.whiteColor:[NSColor colorWithCalibratedRed:0.23 green:0.27 blue:0.30 alpha:1]};
    NSSize size=[self.title sizeWithAttributes:attrs]; CGFloat extra=self.image?22:0;
    CGFloat x=(self.bounds.size.width-size.width-extra)/2;
    if (self.image) [self.image drawInRect:NSMakeRect(x,(self.bounds.size.height-15)/2,15,15) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.title drawAtPoint:NSMakePoint(x+extra,(self.bounds.size.height-size.height)/2) withAttributes:attrs];
}
@end
@interface PlaceholderTextView : NSTextView
@property NSString *placeholder;
@property NSEventModifierFlags commandModifiers;
@end
@implementation PlaceholderTextView
- (void)keyDown:(NSEvent *)event {
    self.commandModifiers=event.modifierFlags;
    @try { [super keyDown:event]; }
    @finally { self.commandModifiers=0; }
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.string.length && self.placeholder.length) [self.placeholder drawInRect:NSMakeRect(self.textContainerInset.width+self.textContainer.lineFragmentPadding,self.textContainerInset.height,self.bounds.size.width-2*(self.textContainerInset.width+self.textContainer.lineFragmentPadding),70) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightLight],NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.62 alpha:1]}];
}
@end

// Launch Services marks login launches in the initial open-application event.
// Manual launches and reopen requests still show the normal Yi window.
static BOOL WasLaunchedAtLogin(NSAppleEventDescriptor *event) {
    return event.eventClass==kCoreEventClass && event.eventID==kAEOpenApplication &&
        [event paramDescriptorForKeyword:keyAEPropData].enumCodeValue==keyAELaunchedAsLogInItem;
}

@protocol YiLoginService <NSObject>
@property (readonly) SMAppServiceStatus status;
- (BOOL)registerAndReturnError:(NSError **)error;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate>
@property Translator *translator;
@property SPUStandardUpdaterController *updaterController;
@property id<YiLoginService> loginService;
@property Bubble *bubble;
@property SpeechPlayback *speechPlayback;
@property NSButton *inputSpeechButton;
@property NSButton *outputSpeechButton;
@property NSString *spokenResult;
@property NSStatusItem *status;
@property NSMenuItem *pauseItem;
@property NSMenuItem *summaryItem;
@property NSMenu *targetMenu;
@property NSMenu *statusMenu;
@property NSWindow *setupWindow;
@property BOOL keepsSwitcherAfterMinimize;
@property BOOL statusMenuOpen;
@property CFRunLoopTimerRef statusMenuDismissTimer;
@property uint64_t statusMenuMouseDownCounter;
@property NSTextView *inputView;
@property NSTextView *outputView;
@property NSPopUpButton *mainLanguagePicker;
@property NSSwitch *automaticToggle;
@property NSTextField *permissionLabel;
@property NSButton *accessPermissionButton;
@property NSButton *capturePermissionButton;
@property NSTimer *permissionTimer;
@property NSTimer *inputTranslationTimer;
@property NSMutableArray *monitors;
@property dispatch_block_t pending;
@property NSUInteger generation;
@property NSPoint mouseDown;
@property BOOL hasMouseDown;
@property NSRect recentDragAnchor;
@property pid_t recentDragPID;
@property BOOL enabled;
@property BOOL started;
@property NSTimer *selectionTimer;
@property NSString *lastSelectionKey;
@property NSString *lastStatus;
@property NSTextField *statusLabel;
@property NSString *targetCode;
@property NSString *activeText;
@property NSRect activeAnchor;
@property NSString *activeContext;
@property pid_t activePID;
@property BOOL captureInProgress;
@property BOOL captureWaitingForMenu;
@property BOOL captureFramesPreparing;
@property NSUInteger captureSession;
@property NSMutableArray<CaptureWindow *> *captureWindows;
@property NSArray<CaptureFrame *> *captureFrames;
@property NSRunningApplication *captureFrontApp;
@property EventHotKeyRef captureHotkey;
@property EventHotKeyRef selectionHotkey;
@property EventHotKeyRef openHotkey;
@property EventHotKeyRef automaticHotkey;
@property NSDictionary<NSString *,YiShortcut *> *shortcuts;
@property YiShortcutPreferencesController *shortcutPreferences;
@property BOOL shortcutsSuspended;
@property CompatibilityReader *compatibilityReader;
@property NSMenuItem *compatibilityMenuItem;
@property NSMenuItem *compatibilityAppItem;
@property NSMutableArray<NSMenu *> *appearanceMenus;
@property NSMutableArray<NSMenu *> *providerMenus;
@property BOOL appearancePreviewPending;
- (NSEvent *)handleLocalEvent:(NSEvent *)event;
- (void)capture:(id)sender;
- (void)dismissStatusMenu;
- (void)translateSelectedText:(id)sender;
- (void)showSetup:(id)sender;
- (void)showShortcutPreferences:(id)sender;
- (void)toggle:(id)sender;
@end

static OSStatus TranslationHotkeyHandler(EventHandlerCallRef handler, EventRef event, void *context) {
    EventHotKeyID identifier = {0};
    OSStatus status=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(identifier),NULL,&identifier);
    if (status!=noErr || identifier.signature!='Trns' || identifier.id<1 || identifier.id>4) return eventNotHandledErr;
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    // The main dispatch queue can be starved by AppKit's menu tracking loop.
    // Common run-loop modes keep the shortcut responsive while a menu is open.
    CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopCommonModes,^{
        if(delegate.shortcutsSuspended) return;
        if (identifier.id==1) { [delegate capture:nil]; [delegate dismissStatusMenu]; }
        else if(identifier.id==2) [delegate translateSelectedText:nil];
        else if(identifier.id==4) { [delegate dismissStatusMenu]; [delegate toggle:nil]; }
        else { [delegate dismissStatusMenu]; dispatch_async(dispatch_get_main_queue(),^{ [delegate showSetup:nil]; }); }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return noErr;
}

@implementation AppDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self showSetup:nil]; return YES; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:BundleID].count > 1) { [NSApp terminate:nil]; return; }
    BOOL loginLaunch=WasLaunchedAtLogin(NSAppleEventManager.sharedAppleEventManager.currentAppleEvent);
    self.loginService=(id<YiLoginService>)SMAppService.mainAppService;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.shortcuts=YiShortcutsFromPropertyList([defaults objectForKey:@"keyboardShortcuts"]);
    self.targetCode = [defaults stringForKey:@"targetLanguage"] ?: @"zh-CN";
    if (![LanguageName(self.targetCode) length]) self.targetCode = @"zh-CN";
    self.translator = [Translator new]; self.bubble = [Bubble new]; self.monitors = [NSMutableArray new]; self.enabled = YES; self.compatibilityReader=[CompatibilityReader new];
    __weak AppDelegate *weakSelf = self;
    self.bubble.targetCode = self.targetCode;
    self.bubble.targetChanged = ^(NSString *code) { [weakSelf changeTarget:code]; };
    self.bubble.speechButton.target = self;
    self.bubble.speechButton.action = @selector(speakText:);
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];
    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self updateStatusIcon];
    NSMenu *menu = [NSMenu new];
    self.summaryItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    NSMenuItem *main = [menu addItemWithTitle:@"打开" action:@selector(showSetup:) keyEquivalent:@""]; main.target = self;
    NSMenuItem *selection = [menu addItemWithTitle:@"划词翻译" action:@selector(translateSelectedText:) keyEquivalent:@""]; selection.target = self;
    NSMenuItem *capture = [menu addItemWithTitle:@"截图翻译" action:@selector(capture:) keyEquivalent:@""]; capture.target = self;
    self.pauseItem = [menu addItemWithTitle:@"自动划词" action:@selector(toggle:) keyEquivalent:@""]; self.pauseItem.target = self;
    self.compatibilityMenuItem=[menu addItemWithTitle:@"兼容取词" action:@selector(toggleCompatibility:) keyEquivalent:@""]; self.compatibilityMenuItem.target=self;
    NSMenuItem *appearance=[menu addItemWithTitle:@"气泡外观" action:NULL keyEquivalent:@""]; appearance.submenu=[self createAppearanceMenu];
    [self addProviderMenu:menu];
    NSMenuItem *target = [menu addItemWithTitle:@"目标语言" action:NULL keyEquivalent:@""];
    self.targetMenu = [NSMenu new];
    for (NSArray *language in Languages()) {
        NSMenuItem *item = [self.targetMenu addItemWithTitle:language[1] action:@selector(menuLanguage:) keyEquivalent:@""]; item.representedObject = language[0]; item.target = self;
    }
    target.submenu = self.targetMenu;
    NSMenuItem *shortcuts=[menu addItemWithTitle:@"快捷键设置…" action:@selector(showShortcutPreferences:) keyEquivalent:@""]; shortcuts.target=self;
    [menu addItem:NSMenuItem.separatorItem];
    [self addUpdateItems:menu];
    NSMenuItem *quit = [menu addItemWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"]; quit.target = self;
    // Keep only the right-click context menu in the requested native light style.
    NSAppearance *contextAppearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    menu.appearance=contextAppearance;
    for(NSMenuItem *item in menu.itemArray) if(item.submenu) item.submenu.appearance=contextAppearance;
    self.statusMenu = menu;
    self.status.button.target = self;
    self.status.button.action = @selector(statusClicked:);
    [self.status.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self installMainMenu]; [self updateTargetControls];
    [self updateCompatibility];
    [self updateBubbleAppearance];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(appChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetEventDispatcherTarget(), &TranslationHotkeyHandler, 1, &eventType, (__bridge void *)self, NULL);
    [self registerShortcutKeys:self.shortcuts strict:NO error:NULL];
    [self updateShortcutMenuItems];
    if ([defaults boolForKey:@"onlineTranslationAccepted"] && AXIsProcessTrusted()) [self start];
    [self finishStartupForLoginLaunch:loginLaunch];
}
- (void)finishStartupForLoginLaunch:(BOOL)loginLaunch {
    if (!loginLaunch) [self showSetup:nil];
}
- (void)installMainMenu {
    NSMenu *main = [NSMenu new]; NSMenuItem *app = [NSMenuItem new]; [main addItem:app]; app.submenu = [NSMenu new];
    NSMenuItem *about = [app.submenu addItemWithTitle:@"关于翻译一下" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""]; about.target=NSApp;
    [self addUpdateItems:app.submenu];
    [self addProviderMenu:app.submenu];
    [app.submenu addItem:NSMenuItem.separatorItem];
    self.compatibilityAppItem=[app.submenu addItemWithTitle:@"兼容取词" action:@selector(toggleCompatibility:) keyEquivalent:@""]; self.compatibilityAppItem.target=self;
    NSMenuItem *appearance=[app.submenu addItemWithTitle:@"气泡外观" action:NULL keyEquivalent:@""]; appearance.submenu=[self createAppearanceMenu];
    NSMenuItem *shortcuts=[app.submenu addItemWithTitle:@"快捷键设置…" action:@selector(showShortcutPreferences:) keyEquivalent:@""]; shortcuts.target=self;
    [app.submenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [app.submenu addItemWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"]; quit.target = self;
    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:@"编辑" action:NULL keyEquivalent:@""]; [main addItem:edit]; edit.submenu = [NSMenu new];
    for (NSArray *item in @[@[@"剪切",@"cut:",@"x"],@[@"复制",@"copy:",@"c"],@[@"粘贴",@"paste:",@"v"],@[@"全选",@"selectAll:",@"a"]]) [edit.submenu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];
    NSApp.mainMenu = main;
}
- (void)addUpdateItems:(NSMenu *)menu {
    NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"未知";
    NSMenuItem *check=[menu addItemWithTitle:[NSString stringWithFormat:@"检查更新…（v%@）",version] action:@selector(checkForUpdates:) keyEquivalent:@""];
    check.target=self.updaterController;
    NSMenuItem *automatic=[menu addItemWithTitle:@"自动检查更新" action:@selector(toggleAutomaticUpdates:) keyEquivalent:@""];
    automatic.target=self;
    NSMenuItem *login=[menu addItemWithTitle:@"开机静默启动" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    login.target=self;
}
- (void)toggleAutomaticUpdates:(id)sender {
    self.updaterController.updater.automaticallyChecksForUpdates=!self.updaterController.updater.automaticallyChecksForUpdates;
}
- (void)showLoginServiceError:(NSError *)error {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"无法更改开机启动";
    alert.informativeText=error.localizedDescription ?: @"请确认 翻译一下位于应用程序文件夹后重试。";
    [alert addButtonWithTitle:@"好"]; [alert runModal];
}
- (void)requestLoginServiceApproval {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"开机启动需要系统允许";
    alert.informativeText=@"请在系统设置的“登录项”中允许翻译一下。允许后，翻译一下会在你登录 Mac 时在后台启动，不自动打开主窗口。";
    [alert addButtonWithTitle:@"打开登录项设置"]; [alert addButtonWithTitle:@"稍后"];
    if([alert runModal]==NSAlertFirstButtonReturn) [SMAppService openSystemSettingsLoginItems];
}
- (void)toggleLaunchAtLogin:(id)sender {
    id<YiLoginService> service=self.loginService;
    NSError *error=nil;
    BOOL registered=service.status==SMAppServiceStatusEnabled || service.status==SMAppServiceStatusRequiresApproval;
    BOOL success=service && (registered ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error]);
    if(!success) { [self showLoginServiceError:error]; return; }
    if(service.status==SMAppServiceStatusRequiresApproval) [self requestLoginServiceApproval];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action==@selector(toggleAutomaticUpdates:)) item.state=self.updaterController.updater.automaticallyChecksForUpdates ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action==@selector(toggleLaunchAtLogin:)) {
        SMAppServiceStatus status=self.loginService.status;
        item.state=status==SMAppServiceStatusEnabled ? NSControlStateValueOn : (status==SMAppServiceStatusRequiresApproval ? NSControlStateValueMixed : NSControlStateValueOff);
        item.title=status==SMAppServiceStatusRequiresApproval ? @"开机静默启动（待系统允许）" : @"开机静默启动";
        return self.loginService!=nil;
    }
    return YES;
}
- (void)minimizeToSwitcher:(id)sender {
    // Only an explicit yellow-button click promotes Yi into Dock / Cmd+Tab.
    // Login launches and ordinary menu-bar use retain the accessory policy.
    if([NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]) self.keepsSwitcherAfterMinimize=YES;
    [self.setupWindow miniaturize:sender];
}
- (void)restoreWindowFromSwitcher {
    if(!self.keepsSwitcherAfterMinimize || self.captureInProgress || self.statusMenuOpen || self.bubble.isInteracting) return;
    NSWindow *key=NSApp.keyWindow;
    if(NSApp.modalWindow || (key.visible && key!=self.setupWindow && key!=self.bubble.panel)) return;
    // Switching away may orderOut the main window without miniaturizing it.
    // Cmd+Tab must restore both hidden and genuinely miniaturized states.
    if(self.setupWindow.miniaturized || !self.setupWindow.visible) [self showSetup:nil];
}
- (void)applicationDidBecomeActive:(NSNotification *)notification { [self restoreWindowFromSwitcher]; }
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.setupWindow) {
        [self.speechPlayback stopForButton:self.inputSpeechButton];
        [self.speechPlayback stopForButton:self.outputSpeechButton];
    }
    if(notification.object==self.setupWindow && self.keepsSwitcherAfterMinimize) {
        self.keepsSwitcherAfterMinimize=NO;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}
- (void)applicationDidResignActive:(NSNotification *)notification {
    [self dismissStatusMenu];
    if(!self.setupWindow.miniaturized) [self.setupWindow orderOut:nil];
}
- (void)dismissStatusMenu {
    if(self.statusMenuOpen) [self.statusMenu cancelTrackingWithoutAnimation];
}
- (uint64_t)menuMouseDownCounter {
    return (uint64_t)CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,kCGEventLeftMouseDown)
        +(uint64_t)CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,kCGEventRightMouseDown)
        +(uint64_t)CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,kCGEventOtherMouseDown);
}
- (NSPoint)menuPointerLocation { return NSEvent.mouseLocation; }
- (BOOL)menuPointerIsOutside:(NSPoint)point {
    // A sibling status item may open without changing the frontmost app.
    // Its mouse-down counter still changes while AppKit tracks this menu.
    for(NSScreen *screen in NSScreen.screens) {
        CGFloat barHeight=MAX(NSStatusBar.systemStatusBar.thickness,screen.safeAreaInsets.top);
        NSRect bar=NSMakeRect(NSMinX(screen.frame),NSMaxY(screen.frame)-barHeight,screen.frame.size.width,barHeight);
        if(NSPointInRect(point,bar)) return YES;
    }
    // Public WindowServer geometry keeps clicks inside our menu/submenus
    // available to AppKit. Query only after a new click, not on every tick.
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame); BOOL foundMenu=NO;
    for(NSDictionary *info in windows) {
        if([info[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=NSProcessInfo.processInfo.processIdentifier || [info[(__bridge NSString *)kCGWindowLayer] integerValue]<NSPopUpMenuWindowLevel) continue;
        CGRect bounds=CGRectZero;
        if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds],&bounds)) continue;
        foundMenu=YES;
        NSRect frame=NSMakeRect(bounds.origin.x,top-CGRectGetMaxY(bounds),bounds.size.width,bounds.size.height);
        if(NSPointInRect(point,NSInsetRect(frame,-2,-2))) return NO;
    }
    return foundMenu;
}
- (void)pollStatusMenuDismissal {
    if(!self.statusMenuOpen) return;
    uint64_t counter=[self menuMouseDownCounter];
    if(counter==self.statusMenuMouseDownCounter) return;
    self.statusMenuMouseDownCounter=counter;
    if([self menuPointerIsOutside:[self menuPointerLocation]]) [self dismissStatusMenu];
}
- (void)startStatusMenuDismissMonitor {
    [self stopStatusMenuDismissMonitor]; self.statusMenuMouseDownCounter=[self menuMouseDownCounter];
    __weak AppDelegate *weakSelf=self;
    self.statusMenuDismissTimer=CFRunLoopTimerCreateWithHandler(NULL,CFAbsoluteTimeGetCurrent()+0.03,0.03,0,0,^(CFRunLoopTimerRef timer){ [weakSelf pollStatusMenuDismissal]; });
    if(self.statusMenuDismissTimer) CFRunLoopAddTimer(CFRunLoopGetMain(),self.statusMenuDismissTimer,kCFRunLoopCommonModes);
}
- (void)stopStatusMenuDismissMonitor {
    if(!self.statusMenuDismissTimer) return;
    CFRunLoopTimerInvalidate(self.statusMenuDismissTimer); CFRelease(self.statusMenuDismissTimer); self.statusMenuDismissTimer=NULL;
}
- (void)showStatusMenu {
    if(self.statusMenuOpen) return;
    self.statusMenuOpen=YES;
    // Yi may remain an accessory while another app is already active. In that
    // case, clicking that same app produces no activation notification.
    __weak AppDelegate *weakSelf=self;
    id outsideClick=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown handler:^(NSEvent *event) {
        [weakSelf dismissStatusMenu];
    }];
    @try {
        [self startStatusMenuDismissMonitor];
        // Attach to the status item so AppKit owns menu-bar tracking and closes
        // this menu when another menu-bar item's menu takes over.
        self.status.menu=self.statusMenu;
        [self.status.button performClick:nil];
    } @finally {
        [self stopStatusMenuDismissMonitor];
        self.status.menu=nil; // Keep the ordinary left-click window action.
        if(outsideClick) [NSEvent removeMonitor:outsideClick];
        self.statusMenuOpen=NO;
        [self resumeCaptureAfterMenu];
        [self showPendingAppearancePreview];
    }
}
- (void)statusClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp || (NSApp.currentEvent.modifierFlags & NSEventModifierFlagControl)) {
        [self showStatusMenu];
        return;
    }
    if (self.setupWindow.visible) [self.setupWindow orderOut:nil]; else [self showSetup:nil];
}
- (EventHotKeyRef *)shortcutReferenceForAction:(NSString *)action {
    if([action isEqual:YiShortcutCapture]) return &_captureHotkey;
    if([action isEqual:YiShortcutSelection]) return &_selectionHotkey;
    if([action isEqual:YiShortcutAutomatic]) return &_automaticHotkey;
    return &_openHotkey;
}
- (void)unregisterShortcutKeys {
    for(NSString *action in YiShortcutActions()) {
        EventHotKeyRef *reference=[self shortcutReferenceForAction:action];
        if(*reference) { UnregisterEventHotKey(*reference); *reference=NULL; }
    }
}
- (BOOL)registerShortcutKeys:(NSDictionary<NSString *,YiShortcut *> *)shortcuts strict:(BOOL)strict error:(NSError **)error {
    if(!YiValidateShortcuts(shortcuts,error)) return NO;
    BOOL success=YES;
    for(NSString *action in YiShortcutActions()) {
        YiShortcut *shortcut=shortcuts[action];
        UInt32 number=[action isEqual:YiShortcutCapture] ? 1 : ([action isEqual:YiShortcutSelection] ? 2 : ([action isEqual:YiShortcutAutomatic] ? 4 : 3));
        EventHotKeyID identifier={'Trns',number};
        OSStatus status=RegisterEventHotKey(shortcut.keyCode,shortcut.carbonModifiers,identifier,GetEventDispatcherTarget(),0,[self shortcutReferenceForAction:action]);
        if(status!=noErr) {
            success=NO;
            NSString *message=[NSString stringWithFormat:@"%@的 %@ 无法使用，可能已被其他应用占用。请换一组快捷键。",YiShortcutActionName(action),shortcut.displayString];
            if(error) *error=YiShortcutError(message); self.lastStatus=message;
            if(strict) { [self unregisterShortcutKeys]; return NO; }
        }
    }
    return success;
}
- (void)updateShortcutMenuItems {
    for(NSMenuItem *item in self.statusMenu.itemArray) {
        NSString *action=nil;
        if(item.action==@selector(capture:)) action=YiShortcutCapture;
        else if(item.action==@selector(translateSelectedText:)) action=YiShortcutSelection;
        else if(item.action==@selector(showSetup:)) action=YiShortcutOpen;
        else if(item.action==@selector(toggle:)) action=YiShortcutAutomatic;
        if(!action) continue;
        YiShortcut *shortcut=self.shortcuts[action];
        BOOL registered=*([self shortcutReferenceForAction:action])!=NULL;
        item.title=YiShortcutActionName(action);
        item.keyEquivalent=(registered || self.shortcutsSuspended) ? shortcut.keyEquivalent : @"";
        item.keyEquivalentModifierMask=shortcut.modifiers;
        if(!registered && !self.shortcutsSuspended) item.title=[item.title stringByAppendingString:@"（快捷键不可用）"];
    }
}
- (void)showShortcutPreferences:(id)sender {
    [self dismissStatusMenu];
    dispatch_async(dispatch_get_main_queue(),^{
        if(self.shortcutPreferences.window.visible) { [NSApp activateIgnoringOtherApps:YES]; [self.shortcutPreferences showWindow:nil]; return; }
        [self cancel];
        if(!self.shortcuts) self.shortcuts=YiDefaultShortcuts();
        self.shortcutsSuspended=YES; [self unregisterShortcutKeys];
        __weak AppDelegate *weakSelf=self;
        self.shortcutPreferences=[[YiShortcutPreferencesController alloc] initWithShortcuts:self.shortcuts apply:^BOOL(NSDictionary<NSString *,YiShortcut *> *shortcuts,NSError **error) {
            AppDelegate *self=weakSelf; if(!self) return NO;
            [self unregisterShortcutKeys];
            if(![self registerShortcutKeys:shortcuts strict:YES error:error]) return NO;
            self.shortcuts=shortcuts.copy;
            [NSUserDefaults.standardUserDefaults setObject:YiShortcutsPropertyList(shortcuts) forKey:@"keyboardShortcuts"];
            [self updateShortcutMenuItems]; return YES;
        }];
        self.shortcutPreferences.windowClosed=^{
            AppDelegate *self=weakSelf; if(!self) return;
            self.shortcutsSuspended=NO;
            if(!self.captureHotkey && !self.selectionHotkey && !self.openHotkey && !self.automaticHotkey) [self registerShortcutKeys:self.shortcuts strict:NO error:NULL];
            [self updateShortcutMenuItems]; [self updatePermission];
        };
        [NSApp activateIgnoringOtherApps:YES]; [self.shortcutPreferences showWindow:nil];
    });
}
- (void)updateStatusIcon {
    self.status.button.title = @"";
    static NSImage *mark;static dispatch_once_t once;
    dispatch_once(&once, ^{
        mark=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"MenuBarIcon" ofType:@"png"]];
        mark.size=NSMakeSize(18,18);mark.template=YES;
    });
    self.status.visible = YES; self.status.button.image = mark;
    self.status.button.imagePosition = NSImageOnly;
    self.status.button.appearsDisabled = !self.enabled;
    self.status.button.toolTip = [NSString stringWithFormat:@"翻译一下 · 自动识别 → %@",LanguageName(self.targetCode)];
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame font:(NSFont *)font {
    NSTextField *label = [NSTextField wrappingLabelWithString:text]; label.frame = frame; label.font = font; [self.setupWindow.contentView addSubview:label]; return label;
}
- (NSTextField *)rowLabel:(NSString *)text frame:(NSRect)frame font:(NSFont *)font {
    MainRowLabel *label=[[MainRowLabel alloc] initWithFrame:frame];
    label.stringValue=text; label.font=font; label.textColor=NSColor.labelColor;
    label.editable=NO; label.selectable=NO; label.bordered=NO; label.drawsBackground=NO;
    [self.setupWindow.contentView addSubview:label]; return label;
}
- (NSTextView *)textArea:(NSRect)frame editable:(BOOL)editable {
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:frame]; scroll.borderType=NSNoBorder; scroll.drawsBackground=NO; scroll.contentView.drawsBackground=NO;
    scroll.hasVerticalScroller=YES; scroll.scrollerStyle=NSScrollerStyleOverlay; scroll.autohidesScrollers=YES;
    PlaceholderTextView *view=[[PlaceholderTextView alloc] initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];
    view.placeholder=editable?@"输入或粘贴需要翻译的内容…":@"译文会在这里呈现。";
    view.editable=editable; view.selectable=YES; view.richText=NO; view.drawsBackground=NO;
    view.font=[NSFont systemFontOfSize:15 weight:NSFontWeightLight]; view.textColor=[NSColor colorWithCalibratedRed:0.18 green:0.21 blue:0.24 alpha:1];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new]; paragraph.lineSpacing=5; view.defaultParagraphStyle=paragraph;
    view.typingAttributes=@{NSFontAttributeName:view.font,NSParagraphStyleAttributeName:paragraph,NSForegroundColorAttributeName:view.textColor};
    view.textContainerInset=NSMakeSize(0,8); view.textContainer.lineFragmentPadding=0; view.verticallyResizable=YES; view.horizontallyResizable=NO;
    view.textContainer.widthTracksTextView=YES; view.autoresizingMask=NSViewWidthSizable;
    view.minSize=NSMakeSize(0,frame.size.height); view.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
    scroll.documentView=view; [self.setupWindow.contentView addSubview:scroll]; return view;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    SoftButton *button=[[SoftButton alloc] initWithFrame:frame]; button.title=title; button.target=self; button.action=action; button.bordered=NO; button.font=[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]; [self.setupWindow.contentView addSubview:button]; return button;
}
- (NSButton *)speechButtonWithLabel:(NSString *)label frame:(NSRect)frame {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.target = self;
    button.action = @selector(speakText:);
    UpdateSpeechButton(button, label, NO);
    [self.setupWindow.contentView addSubview:button];
    return button;
}
- (void)speakText:(NSButton *)sender {
    BOOL original = sender == self.inputSpeechButton;
    BOOL floating = sender == self.bubble.speechButton;
    NSString *text = original ? self.inputView.string : (floating ? self.bubble.translation : self.spokenResult);
    if (!text.length) return;
    if (!self.speechPlayback) self.speechPlayback = [SpeechPlayback new];
    NSString *label = original ? @"朗读原文" : @"朗读译文";
    NSString *language = original ? nil : (floating ? self.bubble.targetCode : self.targetCode);
    if (![self.speechPlayback toggleText:text language:language button:sender label:label]) {
        NSString *message = @"没有可用的朗读语音，可在 macOS 辅助功能中添加语音。";
        if (floating) sender.toolTip = message;
        else {
            self.lastStatus = message;
            [self updatePermission];
        }
        NSBeep();
    }
}
- (void)showSetup:(id)sender {
    if (!self.setupWindow) {
        self.setupWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,760,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
        self.setupWindow.delegate=self;
        NSButton *minimize=[self.setupWindow standardWindowButton:NSWindowMiniaturizeButton];
        minimize.target=self; minimize.action=@selector(minimizeToSwitcher:);
        self.setupWindow.title=@"翻译一下"; self.setupWindow.titleVisibility=NSWindowTitleHidden; self.setupWindow.titlebarAppearsTransparent=YES;
        self.setupWindow.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua]; self.setupWindow.releasedWhenClosed=NO;
        self.setupWindow.contentView=[[MainBackground alloc] initWithFrame:NSMakeRect(0,0,760,600)];
        NSImageView *icon=[[NSImageView alloc] initWithFrame:NSMakeRect(28,520,50,50)]; icon.image=[NSImage imageNamed:@"AppIcon"]; icon.imageScaling=NSImageScaleProportionallyUpOrDown; [self.setupWindow.contentView addSubview:icon];
        [self label:@"翻译一下" frame:NSMakeRect(92,539,350,33) font:[NSFont systemFontOfSize:26 weight:NSFontWeightLight]];
        NSTextField *subtitle=[self label:@"让语言之间，少一点距离。" frame:NSMakeRect(92,518,360,20) font:[NSFont systemFontOfSize:11.5 weight:NSFontWeightLight]]; subtitle.textColor=[NSColor colorWithCalibratedWhite:0.48 alpha:1];
        NSButton *captureButton=[self button:@"截图翻译" action:@selector(capture:) frame:NSMakeRect(582,530,150,34)];
        captureButton.image=[[NSImage imageWithSystemSymbolName:@"viewfinder" accessibilityDescription:@"框选截图"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor colorWithCalibratedWhite:0.3 alpha:1]]];
        ReadingCard *source=[[ReadingCard alloc] initWithFrame:NSMakeRect(28,199,342,286)]; [self.setupWindow.contentView addSubview:source];
        ReadingCard *result=[[ReadingCard alloc] initWithFrame:NSMakeRect(390,199,342,286)]; [self.setupWindow.contentView addSubview:result];
        [self rowLabel:@"原文" frame:NSMakeRect(46,447,55,24) font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        NSTextField *detect=[self rowLabel:@"自动识别" frame:NSMakeRect(94,447,120,24) font:[NSFont systemFontOfSize:12 weight:NSFontWeightLight]]; detect.textColor=[NSColor colorWithCalibratedWhite:0.55 alpha:1];
        self.mainLanguagePicker=[[BubbleLanguagePicker alloc] initWithFrame:NSMakeRect(410,447,127,24) pullsDown:NO]; self.mainLanguagePicker.bordered=NO; self.mainLanguagePicker.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; PopulateLanguages(self.mainLanguagePicker,self,@selector(mainLanguage:)); [self.setupWindow.contentView addSubview:self.mainLanguagePicker];
        [self button:@"⇄" action:@selector(swapMain:) frame:NSMakeRect(542,447,35,24)];
        [self button:@"复制" action:@selector(copyMain:) frame:NSMakeRect(678,447,38,24)];
        self.inputSpeechButton = [self speechButtonWithLabel:@"朗读原文" frame:NSMakeRect(322,447,30,24)];
        self.outputSpeechButton = [self speechButtonWithLabel:@"朗读译文" frame:NSMakeRect(640,447,30,24)];
        self.inputView=[self textArea:NSMakeRect(48,213,304,222) editable:YES];
        self.inputView.delegate=self;
        self.inputView.toolTip=@"停止输入后自动翻译 · Shift＋回车换行";
        self.outputView=[self textArea:NSMakeRect(410,213,304,222) editable:NO];
        self.statusLabel=[self rowLabel:@"" frame:NSMakeRect(30,148,500,36) font:[NSFont systemFontOfSize:11.5 weight:NSFontWeightLight]]; self.statusLabel.textColor=[NSColor colorWithCalibratedWhite:0.44 alpha:1];
        SoftButton *translate=(SoftButton *)[self button:@"翻译 →" action:@selector(translateInput:) frame:NSMakeRect(628,151,104,30)]; translate.prominent=YES; translate.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        ReadingCard *preferences=[[ReadingCard alloc] initWithFrame:NSMakeRect(28,58,704,52)]; preferences.subtle=YES; [self.setupWindow.contentView addSubview:preferences];
        self.automaticToggle=[[NSSwitch alloc] initWithFrame:NSMakeRect(44,75,38,22)]; self.automaticToggle.target=self; self.automaticToggle.action=@selector(toggle:); self.automaticToggle.controlSize=NSControlSizeSmall; [self.setupWindow.contentView addSubview:self.automaticToggle];
        [self rowLabel:@"自动划词" frame:NSMakeRect(92,73,100,26) font:[NSFont systemFontOfSize:12 weight:NSFontWeightLight]];
        self.permissionLabel=[self rowLabel:@"" frame:NSMakeRect(204,73,308,26) font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightLight]]; self.permissionLabel.textColor=[NSColor colorWithCalibratedWhite:0.48 alpha:1];
        self.accessPermissionButton=[self button:@"划词权限" action:@selector(openPermissions:) frame:NSMakeRect(530,73,88,26)];
        self.capturePermissionButton=[self button:@"截图权限" action:@selector(openCapturePermissions:) frame:NSMakeRect(626,73,88,26)];
        self.accessPermissionButton.font=[NSFont systemFontOfSize:10.5];
        self.capturePermissionButton.font=[NSFont systemFontOfSize:10.5];
        NSTextField *privacy=[self label:@"气泡背景与截图仅在本机处理  ·  原文发送至所选翻译服务  ·  不保存历史" frame:NSMakeRect(30,18,704,20) font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightLight]]; privacy.textColor=[NSColor colorWithCalibratedWhite:0.55 alpha:1];
        [self.setupWindow center]; __weak AppDelegate *weakSelf=self;
        self.permissionTimer=[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer){ [weakSelf updatePermission]; }];
    }
    if(self.setupWindow.miniaturized) [self.setupWindow deminiaturize:nil];
    [self updateTargetControls]; [self updatePermission]; [self.setupWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)copyMain:(id)sender {
    if (!self.outputView.string.length) return;
    [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:self.outputView.string forType:NSPasteboardTypeString];
    self.lastStatus=@"完整译文已复制。"; [self updatePermission];
}
- (void)updateCompatibility {
    NSInteger state=[NSUserDefaults.standardUserDefaults boolForKey:@"compatibilityCopyEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.compatibilityMenuItem.state=state; self.compatibilityAppItem.state=state;
}
- (NSMenu *)createAppearanceMenu {
    if(!self.appearanceMenus) self.appearanceMenus=[NSMutableArray new];
    NSMenu *menu=[NSMenu new];
    for(NSArray *style in @[@[@"white",@"白色气泡"],@[@"black",@"黑色气泡"],@[@"light",@"浅色玻璃"],@[@"dark",@"深色玻璃"]]) {
        if([style[0] isEqual:@"light"]) [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *item=[menu addItemWithTitle:style[1] action:@selector(selectBubbleAppearance:) keyEquivalent:@""];
        item.representedObject=style[0]; item.target=self;
    }
    [self.appearanceMenus addObject:menu]; return menu;
}
- (void)updateBubbleAppearance {
    NSString *selected = SelectedBubbleAppearance();
    for(NSMenu *menu in self.appearanceMenus) for(NSMenuItem *item in menu.itemArray) item.state=[item.representedObject isEqual:selected] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.bubble applyAppearance];
}
- (void)selectBubbleAppearance:(NSMenuItem *)sender {
    if(![@[@"white",@"black",@"light",@"dark"] containsObject:sender.representedObject]) return;
    [NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:@"bubbleAppearance"];
    [self updateBubbleAppearance];
    self.appearancePreviewPending=YES;
    if(!self.statusMenuOpen) dispatch_async(dispatch_get_main_queue(),^{ [self showPendingAppearancePreview]; });
}
- (void)showPendingAppearancePreview {
    if(!self.appearancePreviewPending || self.statusMenuOpen) return;
    self.appearancePreviewPending=NO;
    [self cancel]; [self preview:nil];
}
- (void)toggleCompatibility:(id)sender {
    BOOL enabled=![NSUserDefaults.standardUserDefaults boolForKey:@"compatibilityCopyEnabled"];
    if(enabled) {
        NSAlert *alert=[NSAlert new]; alert.messageText=@"开启兼容取词";
        alert.informativeText=@"仅在读不到选区且你划词或按划词翻译快捷键时临时复制取词，并尽量恢复原剪贴板。原剪贴板只在内存中暂存；选中文字发送给当前选中的 Google 或有道翻译。新的复制操作优先保留。";
        [alert addButtonWithTitle:@"开启"]; [alert addButtonWithTitle:@"取消"];
        if([alert runModal]!=NSAlertFirstButtonReturn) return;
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"compatibilityCopyEnabled"]; [self.compatibilityReader cancel]; [self updateCompatibility];
}
- (void)addProviderMenu:(NSMenu *)parent {
    NSMenuItem *item=[parent addItemWithTitle:@"翻译源" action:NULL keyEquivalent:@""];item.submenu=[NSMenu new];
    if(!self.providerMenus) self.providerMenus=[NSMutableArray new];[self.providerMenus addObject:item.submenu];
    for(NSArray *entry in @[@[@"google",@"Google 翻译"],@[@"youdao",@"有道翻译"]]) {
        NSMenuItem *choice=[item.submenu addItemWithTitle:entry[1] action:@selector(selectProvider:) keyEquivalent:@""];
        choice.target=self;choice.representedObject=entry[0];choice.state=[self.translator.provider isEqual:entry[0]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}
- (void)selectProvider:(NSMenuItem *)sender {
    NSString *provider=sender.representedObject;if([provider isEqual:self.translator.provider]) return;
    [self.translator cancel];self.translator.provider=provider;
    [NSUserDefaults.standardUserDefaults setObject:provider forKey:@"translationProvider"];
    for(NSMenu *menu in self.providerMenus) for(NSMenuItem *choice in menu.itemArray) choice.state=[choice.representedObject isEqual:provider] ? NSControlStateValueOn : NSControlStateValueOff;
    self.lastStatus=[NSString stringWithFormat:@"已切换至%@",[provider isEqual:@"youdao"] ? @"有道翻译" : @"Google 翻译"];[self updatePermission];
    if(self.activeText.length) [self runTranslation:self.activeText anchor:self.activeAnchor context:self.activeContext ?: @"input" pid:self.activePID];
}
- (void)updateTargetControls {
    SelectLanguage(self.mainLanguagePicker,self.targetCode); self.bubble.targetCode = self.targetCode;
    self.summaryItem.title = [NSString stringWithFormat:@"自动识别 / 混合语言 → %@",LanguageName(self.targetCode)];
    for (NSMenuItem *item in self.targetMenu.itemArray) item.state = [item.representedObject isEqual:self.targetCode] ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateStatusIcon];
}
- (void)changeTarget:(NSString *)code {
    if ([code isEqual:self.targetCode]) return;
    self.targetCode = code; [NSUserDefaults.standardUserDefaults setObject:code forKey:@"targetLanguage"];
    [self updateTargetControls];
    if (self.activeText.length) [self runTranslation:self.activeText anchor:self.activeAnchor context:self.activeContext ?: @"input" pid:self.activePID];
}
- (void)mainLanguage:(NSPopUpButton *)sender { [self changeTarget:sender.selectedItem.representedObject]; }
- (void)menuLanguage:(NSMenuItem *)sender { [self changeTarget:sender.representedObject]; }
- (void)swapMain:(id)sender { [self changeTarget:[self.targetCode isEqual:@"en"] ? @"zh-CN" : @"en"]; }
- (BOOL)onlineEnabled {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"onlineTranslationAccepted"]) return YES;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"启用在线翻译";
    alert.informativeText = @"要翻译的原文会发送到当前选择的 Google 或有道。玻璃气泡会临时读取并模糊背后的屏幕区域；截图仅在本机识别，图片不会上传或保存。";
    [alert addButtonWithTitle:@"同意并启用"]; [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return NO;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onlineTranslationAccepted"]; return YES;
}
- (void)updatePermissionIndicatorsWithSelection:(BOOL)selection capture:(BOOL)capture {
    self.accessPermissionButton.hidden = selection;
    self.capturePermissionButton.hidden = capture;
    NSRect accessFrame = self.accessPermissionButton.frame;
    accessFrame.origin.x = NSMinX(self.capturePermissionButton.frame) - (capture ? 0 : NSWidth(accessFrame) + 8);
    self.accessPermissionButton.frame = accessFrame;
    if (selection && capture) {
        self.permissionLabel.stringValue = @"权限已就绪";
    } else if (!selection && !capture) {
        self.permissionLabel.stringValue = @"需要开启划词和截图权限";
    } else {
        self.permissionLabel.stringValue = selection ? @"需要开启截图权限" : @"需要开启划词权限";
    }
}
- (void)updatePermission {
    [self updatePermissionIndicatorsWithSelection:AXIsProcessTrusted() capture:CGPreflightScreenCaptureAccess()];
    self.statusLabel.stringValue = self.lastStatus ?: @"停止输入后自动翻译，Shift＋回车换行。";
    self.automaticToggle.state = self.started && self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.pauseItem.state=self.started && self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.inputSpeechButton.enabled = [self.inputView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    self.outputSpeechButton.enabled = self.spokenResult.length > 0;
}
- (void)openPermissions:(id)sender {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)openCapturePermissions:(id)sender {
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)start {
    if (self.started) { self.enabled = YES; return; }
    if (!AXIsProcessTrusted() || ![self onlineEnabled]) return;
    self.started = YES; self.enabled = YES;
    __weak AppDelegate *weakSelf = self;
    id global = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskScrollWheel handler:^(NSEvent *event) { [weakSelf handle:event]; }]; if (global) [self.monitors addObject:global];
    id local = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return [weakSelf handleLocalEvent:event] ?: event;
    }]; if (local) [self.monitors addObject:local];
    Selection *baseline = ReadSelection(NSEvent.mouseLocation, NSZeroRect); self.lastSelectionKey = baseline ? [NSString stringWithFormat:@"%d:%@",baseline.pid,baseline.text] : @"";
    self.selectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *timer) {
        AppDelegate *self = weakSelf;
        if (!self || !self.enabled || self.pending || self.captureInProgress || self.compatibilityReader.busy || self.bubble.isInteracting || (NSEvent.pressedMouseButtons & 1)) return;
        if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return;
        NSPoint point = NSEvent.mouseLocation;
        NSRect drag = [self currentDragAnchor];
        Selection *selection = ReadSelection(point, drag);
        NSString *key = selection ? [NSString stringWithFormat:@"%d:%@",selection.pid,selection.text] : @"";
        if ([key isEqual:self.lastSelectionKey]) return; self.lastSelectionKey = key;
        if (selection && !IsStandaloneWebLink(selection.text)) {
            [self schedule:point dragAnchor:drag allowCompatibility:NO];
        } else if ([self.activeContext isEqual:@"selection"] ||
                   (selection && [self.activeContext isEqual:@"compatibility"])) {
            [self cancel];
        }
    }];
}
- (NSEvent *)handleLocalEvent:(NSEvent *)event {
    if (self.captureInProgress) return event;
    if (event.type == NSEventTypeLeftMouseDown) {
        if (event.window == self.setupWindow) [self cancel];
    } else if (event.type == NSEventTypeKeyDown && event.keyCode == 53) {
        [self cancel];
    }
    return event;
}
- (void)appChanged:(NSNotification *)notification {
    NSRunningApplication *activated=notification.userInfo[NSWorkspaceApplicationKey] ?: NSWorkspace.sharedWorkspace.frontmostApplication;
    if (activated && activated.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
        [self dismissStatusMenu];
        if (activated.processIdentifier != self.recentDragPID) self.recentDragAnchor = NSZeroRect;
    }
    if (self.captureInProgress || self.bubble.isInteracting) return;
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == NSProcessInfo.processInfo.processIdentifier) { [self restoreWindowFromSwitcher]; return; }
    if (([self.activeContext isEqual:@"selection"] || [self.activeContext isEqual:@"compatibility"]) && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != self.activePID) [self cancel];
}
- (void)handle:(NSEvent *)event {
    if (!self.enabled || self.captureInProgress) return;
    if(event.type==NSEventTypeKeyDown) for(YiShortcut *shortcut in (self.shortcuts ?: YiDefaultShortcuts()).allValues) {
        if(event.keyCode==shortcut.keyCode && (event.modifierFlags & YiShortcutModifierMask())==shortcut.modifiers) return;
    }
    if (self.bubble.languageMenuOpen || NSProcessInfo.processInfo.systemUptime < self.bubble.interactionUntil) return;
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
            self.mouseDown = event.CGEvent ? CGEventGetUnflippedLocation(event.CGEvent) : NSEvent.mouseLocation;
            self.hasMouseDown = YES;
            self.recentDragAnchor = NSZeroRect;
            if (!self.bubble.panel.visible || !NSPointInRect(self.mouseDown, self.bubble.panel.frame)) [self cancel];
            break;
        case NSEventTypeLeftMouseUp: {
            NSPoint point = event.CGEvent ? CGEventGetUnflippedLocation(event.CGEvent) : NSEvent.mouseLocation;
            BOOL dragged = self.hasMouseDown && hypot(point.x - self.mouseDown.x, point.y - self.mouseDown.y) > 3;
            self.hasMouseDown = NO;
            if (self.bubble.panel.visible && NSPointInRect(point, self.bubble.panel.frame)) break;
            if (dragged || event.clickCount >= 2) {
                self.recentDragAnchor = dragged ? SelectionAnchorForDrag(self.mouseDown, point) : NSZeroRect;
                self.recentDragPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
                [self schedule:point dragAnchor:self.recentDragAnchor allowCompatibility:YES];
            }
            break;
        }
        case NSEventTypeKeyUp:
            if ((event.modifierFlags & NSEventModifierFlagShift) && event.keyCode >= 123 && event.keyCode <= 126) {
                self.recentDragAnchor = NSZeroRect;
                [self schedule:NSEvent.mouseLocation dragAnchor:NSZeroRect allowCompatibility:YES];
            }
            break;
        case NSEventTypeKeyDown:
            self.recentDragAnchor = NSZeroRect;
            if (event.keyCode == 53 || !(event.modifierFlags & NSEventModifierFlagShift)) [self cancel];
            break;
        case NSEventTypeScrollWheel:
            if (self.bubble.panel.visible && NSPointInRect(NSEvent.mouseLocation, self.bubble.panel.frame)) break;
            self.recentDragAnchor = NSZeroRect;
            [self cancel];
            break;
        case NSEventTypeRightMouseDown:
            self.recentDragAnchor = NSZeroRect;
            [self cancel];
            break;
        default: break;
    }
}
- (void)cancel { [self.inputTranslationTimer invalidate]; self.inputTranslationTimer=nil; if (self.pending) dispatch_block_cancel(self.pending); self.pending = nil; self.generation++; [self.compatibilityReader cancel]; [self.translator cancel]; [self.speechPlayback stopForButton:self.bubble.speechButton]; [self.bubble hide]; }
- (NSRect)currentDragAnchor {
    pid_t pid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    return pid == self.recentDragPID ? self.recentDragAnchor : NSZeroRect;
}
- (void)schedule:(NSPoint)point dragAnchor:(NSRect)drag allowCompatibility:(BOOL)allowCompatibility {
    [self cancel];
    __weak AppDelegate *weakSelf = self;
    self.pending = dispatch_block_create(0, ^{
        AppDelegate *delegate = weakSelf;
        delegate.pending = nil;
        [delegate translateSelection:point dragAnchor:drag allowCompatibility:allowCompatibility];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), self.pending);
}
- (void)translateSelection:(NSPoint)point dragAnchor:(NSRect)drag allowCompatibility:(BOOL)allowCompatibility {
    if (!self.enabled || !AXIsProcessTrusted()) return;
    Selection *selection = ReadSelection(point, drag);
    if (selection) {
        [self submitSelectionText:selection.text anchor:selection.anchor context:@"selection" pid:selection.pid manual:NO];
    } else if (allowCompatibility) {
        [self tryCompatibility:NSIsEmptyRect(drag) ? SelectionAnchorAtPoint(point) : drag manual:NO];
    }
}
- (void)submitSelectionText:(NSString *)text anchor:(NSRect)anchor context:(NSString *)context pid:(pid_t)pid manual:(BOOL)manual {
    self.lastSelectionKey = [NSString stringWithFormat:@"%d:%@", pid, text];
    if (!manual && IsStandaloneWebLink(text)) return;
    [self runTranslation:text anchor:anchor context:context pid:pid];
}
- (void)tryCompatibility:(NSRect)anchor manual:(BOOL)manual {
    if(![NSUserDefaults.standardUserDefaults boolForKey:@"compatibilityCopyEnabled"]) { if(manual) [self showSelectionHint:anchor]; return; }
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(!SelectionCopyAllowed(front)) { if(manual) [self showSelectionHint:anchor]; return; }
    AXUIElementRef app=AXUIElementCreateApplication(front.processIdentifier); AXUIElementSetMessagingTimeout(app,0.04);
    id item=CopyMenuItem(app); CFRelease(app);
    // Automatic fallback requires the app's own enabled Copy command. Never
    // manufacture a copy when dragging files, controls or an unselected page.
    if(!item) { if(manual) [self showSelectionHint:anchor]; return; }
    [self cancel]; NSUInteger generation=self.generation; pid_t pid=front.processIdentifier;
    [self.compatibilityReader readCopy:^BOOL{
        AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)item,0.20);
        return AXUIElementPerformAction((__bridge AXUIElementRef)item,kAXPressAction)==kAXErrorSuccess;
    } valid:^BOOL{
        return self.generation==generation && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==pid && !self.captureInProgress;
    } completion:^(NSString *text){
        if(self.generation!=generation) return;
        if(!text.length) { if(manual) [self showSelectionHint:anchor]; return; }
        [self submitSelectionText:text anchor:anchor context:@"compatibility" pid:pid manual:manual];
    }];
}
- (void)showSelectionHint:(NSRect)anchor {
    [self cancel]; self.activeText=nil; self.activeContext=nil;
    NSString *captureKey=[(self.shortcuts ?: YiDefaultShortcuts())[YiShortcutCapture] displayString];
    [self.bubble show:[NSString stringWithFormat:@"未读取到文字选区，请重新选择，或按 %@ 截图翻译。",captureKey] anchor:anchor result:NO];
}
- (void)translateSelectedText:(id)sender {
    if (self.captureInProgress) return;
    if (!AXIsProcessTrusted()) { [self openPermissions:nil]; return; }
    // Explicit translation remains available while automatic selection is paused.
    NSPoint point=NSEvent.mouseLocation;
    NSRect drag = [self currentDragAnchor];
    Selection *selection = ReadSelection(point, drag);
    if (!selection) {
        [self tryCompatibility:NSIsEmptyRect(drag) ? SelectionAnchorAtPoint(point) : drag manual:YES];
        return;
    }
    [self submitSelectionText:selection.text anchor:selection.anchor context:@"selection" pid:selection.pid manual:YES];
}
- (void)runTranslation:(NSString *)text anchor:(NSRect)anchor context:(NSString *)context pid:(pid_t)pid {
    if (![self onlineEnabled]) return;
    if (!text.length || text.length>5000) { self.lastStatus = @"每次请翻译 1–5000 字的文字。"; [self updatePermission]; return; }
    [self cancel]; self.activeText = text; self.activeAnchor = anchor; self.activeContext = context; self.activePID = pid;
    self.translator.targetLanguage = self.targetCode;
    NSUInteger generation = ++self.generation;
    BOOL floating = ![context isEqual:@"input"];
    [self.speechPlayback stopForButton:self.outputSpeechButton];
    self.spokenResult = nil;
    self.lastStatus = [NSString stringWithFormat:@"正在翻译成%@…",LanguageName(self.targetCode)];
    if (self.inputView && floating) {
        if (![self.inputView.string isEqualToString:text]) [self.speechPlayback stopForButton:self.inputSpeechButton];
        self.inputView.string = text;
    }
    if (floating) [self.bubble show:@"翻译中…" anchor:anchor result:NO];
    [self updatePermission];
    [self.translator translate:text completion:^(NSString *result,NSError *error) {
        if (generation != self.generation) return;
        pid_t currentPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        if (([context isEqual:@"selection"] || [context isEqual:@"compatibility"]) && currentPID != pid && currentPID != NSProcessInfo.processInfo.processIdentifier) return;
        NSString *failure=TranslationFailureMessage(error);
        NSString *partialNote = result && YoudaoUnsupportedLanguage(error)
            ? @"有道不支持部分语种，已保留原文。可在「翻译源」切换到 Google。"
            : nil;
        self.outputView.string = result ?: failure;
        self.spokenResult = result;
        self.lastStatus = partialNote ?: (result ? [NSString stringWithFormat:@"已翻译成%@",LanguageName(self.targetCode)] : failure);
        if (floating) {
            NSString *display = partialNote ? [NSString stringWithFormat:@"%@\n\n%@", result, partialNote] : (result ?: failure);
            [self.bubble show:display anchor:anchor result:result!=nil];
            if (partialNote) self.bubble.translation = result;
        }
        [self updatePermission];
    }];
}
- (void)scheduleInputTranslationAfter:(NSTimeInterval)delay {
    [self.inputTranslationTimer invalidate];
    __weak AppDelegate *weakSelf=self;
    self.inputTranslationTimer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        AppDelegate *self=weakSelf; if(!self) return;
        self.inputTranslationTimer=nil;
        if(!self.setupWindow.visible || self.captureInProgress) return;
        // A committed IME candidate may not emit another text change; wait for
        // marked text to clear without sending unfinished composition online.
        if(self.inputView.hasMarkedText) { [self scheduleInputTranslationAfter:0.2]; return; }
        NSString *text=[self.inputView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(text.length && text.length<=5000) [self translateInput:nil];
    }];
}
- (void)textDidChange:(NSNotification *)notification {
    if(notification.object!=self.inputView) return;
    // Cancel the old request immediately so a late response cannot replace the
    // result for newly edited text during the debounce interval.
    [self cancel]; self.activeText=nil; self.activeContext=@"input";
    [self.speechPlayback stopForButton:self.inputSpeechButton];
    [self.speechPlayback stopForButton:self.outputSpeechButton];
    self.spokenResult = nil;
    NSString *text=[self.inputView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.outputView.string=@"";
    self.lastStatus=text.length>5000 ? @"每次请翻译 1–5000 字的文字。" : (text.length ? @"停止输入后自动翻译…" : nil);
    [self updatePermission];
    if(text.length && text.length<=5000) [self scheduleInputTranslationAfter:0.4];
}
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    // Let the input method consume Return to confirm marked Chinese/Japanese
    // text first. Only a committed, unmodified newline submits the source editor.
    if (textView != self.inputView || commandSelector != @selector(insertNewline:) || textView.hasMarkedText) return NO;
    NSEventModifierFlags modifiers = ((PlaceholderTextView *)textView).commandModifiers & (NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagCommand);
    if (modifiers) return NO;
    [self translateInput:textView];
    return YES;
}
- (void)translateInput:(id)sender {
    [self.inputTranslationTimer invalidate]; self.inputTranslationTimer=nil;
    if(self.inputView.hasMarkedText) return;
    NSString *text = [self.inputView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self runTranslation:text anchor:NSZeroRect context:@"input" pid:0];
}
- (void)toggle:(id)sender {
    if (!self.started) { [self start]; if (!self.started) { self.lastStatus = @"请先开启 翻译一下的辅助功能权限。"; [self openPermissions:nil]; } }
    else { self.enabled = !self.enabled; if (!self.enabled) [self cancel]; }
    [self updateStatusIcon]; [self updatePermission];
}
- (void)preview:(id)sender {
    NSPoint p = self.setupWindow.visible ? NSMakePoint(NSMidX(self.setupWindow.frame),NSMaxY(self.setupWindow.frame)-160) : NSEvent.mouseLocation;
    self.activeText = @"Hello, welcome to 翻译一下."; self.activeContext = @"preview"; self.activePID=0; self.activeAnchor=NSMakeRect(p.x,p.y-35,1,18);
    [self.bubble show:@"你好，欢迎使用翻译一下。" anchor:self.activeAnchor result:YES];
}
- (void)capture:(id)sender {
    if (self.captureInProgress) return;
    if (![self onlineEnabled]) return;
    if (!CGPreflightScreenCaptureAccess()) { self.lastStatus=@"截图翻译需要屏幕录制权限，请点击“截图权限”开启。"; [self showSetup:nil]; return; }
    self.captureFrontApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    [self cancel]; [self.setupWindow orderOut:nil]; self.captureInProgress=YES;
    if(self.statusMenuOpen) { self.captureWaitingForMenu=YES; return; }
    [self beginCaptureSelection];
}
- (void)resumeCaptureAfterMenu {
    if(!self.captureWaitingForMenu || self.statusMenuOpen) return;
    self.captureWaitingForMenu=NO;
    // The popup's tracking loop must unwind before an overlay can take focus.
    dispatch_async(dispatch_get_main_queue(), ^{ if(self.captureInProgress) [self beginCaptureSelection]; });
}
- (void)beginCaptureSelection {
    if(!self.captureInProgress || self.captureWindows.count || self.captureFramesPreparing) return;
    // Capture every display before creating/activating any overlay. Transient
    // menus disappear on focus changes; selection must use this frozen frame.
    self.captureFramesPreparing=YES;
    NSUInteger session=++self.captureSession;
    [self prepareCaptureFrames:NSScreen.screens completion:^(NSArray<CaptureFrame *> *frames) {
        if(!self.captureInProgress || self.captureSession!=session) return;
        self.captureFramesPreparing=NO;
        if(!frames.count) {
            self.captureInProgress=NO; self.captureFrames=nil;
            self.lastStatus=@"无法读取截图，请确认屏幕录制权限后重试。"; [self showSetup:nil]; return;
        }
        self.captureFrames=frames; [self showCaptureOverlays];
    }];
}
- (void)prepareCaptureFrames:(NSArray<NSScreen *> *)screens completion:(void (^)(NSArray<CaptureFrame *> *))completion {
    if(@available(macOS 14.0,*)) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error) {
            dispatch_async(dispatch_get_main_queue(),^{
                if(error || !content) { completion(nil); return; }
                NSMutableArray<CaptureFrame *> *frames=[NSMutableArray new];
                dispatch_group_t group=dispatch_group_create();
                __block BOOL failed=NO;
                for(NSScreen *screen in screens) {
                    CGDirectDisplayID number=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
                    SCDisplay *display=nil;
                    for(SCDisplay *candidate in content.displays) if(candidate.displayID==number) { display=candidate; break; }
                    if(!display) { failed=YES; continue; }
                    // An excluding-display filter includes the entire desktop,
                    // Dock and menus, rather than only shareable app windows.
                    // Use a display/application exclusion filter. An empty
                    // window-exclusion list can yield blank frames on some OS releases.
                    SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:display excludingApplications:@[] exceptingWindows:@[]];
                    if(@available(macOS 14.2,*)) filter.includeMenuBar=YES;
                    SCStreamConfiguration *config=[SCStreamConfiguration new];
                    config.width=(size_t)llround(screen.frame.size.width*screen.backingScaleFactor);
                    config.height=(size_t)llround(screen.frame.size.height*screen.backingScaleFactor);
                    config.pixelFormat='BGRA';
                    CFStringRef outputName=CaptureOutputColorSpaceName(screen);
                    config.colorSpaceName=outputName;
                    config.showsCursor=NO; config.capturesAudio=NO;
                    dispatch_group_enter(group);
                    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image,NSError *captureError) {
                        // Own CPU pixels before ScreenCaptureKit releases its frame.
                        CGColorSpaceRef outputSpace=CGColorSpaceCreateWithName(outputName);
                        NSBitmapImageRep *bitmap=CopyConfiguredCaptureBitmap(image,outputSpace); CGColorSpaceRelease(outputSpace);
                        dispatch_async(dispatch_get_main_queue(),^{
                            NSBitmapImageRep *result=bitmap;
                            if(captureError || !CaptureBitmapHasVisiblePixels(result)) result=[self snapshotForScreen:screen];
                            if(!CaptureBitmapHasVisiblePixels(result)) failed=YES;
                            else { CaptureFrame *source=[CaptureFrame new]; source.frame=screen.frame; source.bitmap=result; [frames addObject:source]; }
                            dispatch_group_leave(group);
                        });
                    }];
                }
                dispatch_group_notify(group,dispatch_get_main_queue(),^{ completion(failed ? nil : frames); });
            });
        }];
        return;
    }
    NSMutableArray<CaptureFrame *> *frames=[NSMutableArray new];
    for(NSScreen *screen in screens) {
        NSBitmapImageRep *bitmap=[self snapshotForScreen:screen];
        if(!CaptureBitmapHasVisiblePixels(bitmap)) { completion(nil); return; }
        CaptureFrame *source=[CaptureFrame new]; source.frame=screen.frame; source.bitmap=bitmap; [frames addObject:source];
    }
    completion(frames);
}
- (void)showCaptureOverlays {
    self.captureWindows=[NSMutableArray new];
    __weak AppDelegate *weakSelf=self;
    for (CaptureFrame *source in self.captureFrames) {
        CaptureWindow *window=[[CaptureWindow alloc] initWithContentRect:source.frame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO; window.hidesOnDeactivate=NO; window.opaque=YES; window.backgroundColor=NSColor.blackColor;
        window.hasShadow=NO;
        for(NSScreen *screen in NSScreen.screens) if(NSEqualRects(screen.frame,source.frame)) { window.colorSpace=screen.colorSpace; break; }
        window.level=NSPopUpMenuWindowLevel+1;
        window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        CaptureView *view=[[CaptureView alloc] initWithFrame:NSMakeRect(0,0,source.frame.size.width,source.frame.size.height)];
        view.snapshot=[[NSImage alloc] initWithCGImage:source.bitmap.CGImage size:source.frame.size];
        view.snapshot.cacheMode=NSImageCacheNever;
        view.completion=^(NSRect rect){ [weakSelf finishCapture:rect]; }; window.contentView=view;
        [self.captureWindows addObject:window]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view];
    }
}
- (NSBitmapImageRep *)snapshotForScreen:(NSScreen *)screen {
    // Capture the display, not a composition of shareable windows. The latter
    // omits NSWindowSharingNone surfaces such as some transient system menus.
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    if(!display) return nil;
    CGImageRef image=CGDisplayCreateImage(display);
    if(!image) return nil;
    // Quartz display images use this display's ICC profile when DeviceRGB is
    // returned; the ScreenCaptureKit output setting does not apply here.
    NSBitmapImageRep *bitmap=CopyConfiguredCaptureBitmap(image,screen.colorSpace.CGColorSpace); CGImageRelease(image);
    return bitmap;
}
- (void)finishCapture:(NSRect)rect {
    if (!self.captureInProgress) return;
    self.captureWaitingForMenu=NO;
    self.captureSession++; self.captureFramesPreparing=NO;
    CGImageRef image=NULL;
    if(!NSEqualRects(rect,NSZeroRect)) for(CaptureFrame *source in self.captureFrames) {
        if(NSContainsRect(source.frame,rect)) { image=CreateCaptureCrop(source,rect); break; }
    }
    for (CaptureWindow *window in self.captureWindows) {
        ((CaptureView *)window.contentView).finished=YES;
        ((CaptureView *)window.contentView).snapshot=nil;
        [window orderOut:nil];
    }
    [self.captureWindows removeAllObjects];
    self.captureFrames=nil;
    if (NSEqualRects(rect,NSZeroRect)) { self.captureInProgress=NO; self.lastStatus=@"已取消截图"; [self updatePermission]; return; }
    if (self.captureFrontApp.processIdentifier != NSProcessInfo.processInfo.processIdentifier) [self.captureFrontApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    if (!image) { self.captureInProgress=NO; self.lastStatus=@"截图选区已失效，请重新框选。"; [self showSetup:nil]; return; }
    self.lastStatus=@"正在本机识别截图文字…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil; NSString *text=RecognizeImage(image,&error); CGImageRelease(image);
        dispatch_async(dispatch_get_main_queue(),^{
            self.captureInProgress=NO;
            Selection *baseline=ReadSelection(NSEvent.mouseLocation, NSZeroRect); self.lastSelectionKey=baseline ? [NSString stringWithFormat:@"%d:%@",baseline.pid,baseline.text] : @"";
            if (!text.length) { self.lastStatus=error ? @"截图识别失败，请重试。" : @"没有识别到文字，请缩小选区并重试。"; [self showSetup:nil]; return; }
            [self runTranslation:text anchor:rect context:@"capture" pid:0];
        });
    });
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.speechPlayback stop];
    [self stopStatusMenuDismissMonitor];
    [self unregisterShortcutKeys];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

static int RunLayoutTests(NSString *directory) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSString *paragraph = @"赞助你依赖的开源项目\n\n贡献者正在幕后努力，让开源软件变得更好。请给予他们应有的帮助与认可，让更多好的想法继续生长。";
    NSArray *samples = @[@"文档", paragraph, [@"这是一段需要完整阅读的长译文。自动换行后，所有句子都应该保留；内容较长时可以在气泡内滚动查看。\n\n" stringByPaddingToLength:1800 withString:@"后续段落仍然完整保留，不应因窗口高度限制而截断。\n\n" startingAtIndex:0], @"这是一整段没有空格的译文，需要自动折行。\n第二段继续显示，保留段落结构与标点。"];
    for (NSUInteger i = 0; i < samples.count; i++) {
        Bubble *bubble = [Bubble new];
        NSRect anchor = i == 3 ? NSMakeRect(NSMinX(screen) + 2, NSMaxY(screen) - 20, 30, 18) : NSMakeRect(NSMidX(screen), NSMidY(screen), 60, 24);
        [bubble layoutText:samples[i] anchor:anchor result:YES display:NO];
        [bubble.textView.layoutManager ensureLayoutForTextContainer:bubble.textView.textContainer];
        NSRange glyphs = [bubble.textView.layoutManager glyphRangeForTextContainer:bubble.textView.textContainer];
        BOOL complete = [bubble.translation isEqualToString:samples[i]] && [bubble.textView.string isEqualToString:samples[i]] && NSMaxRange(glyphs) == bubble.textView.layoutManager.numberOfGlyphs;
        BOOL fits = NSContainsRect(NSInsetRect(screen, 12, 12), bubble.panel.frame);
        if (!complete || !fits || (i == 2 && !bubble.scrollable)) { fprintf(stderr,"FAIL: layout case %lu\n", (unsigned long)i); return 1; }
        NSRect last = [bubble.textView.layoutManager boundingRectForGlyphRange:NSMakeRange(glyphs.length - 1, 1) inTextContainer:bubble.textView.textContainer];
        if (NSMaxY(last) > bubble.documentHeight + 1) { fputs("FAIL: final line clipped\n",stderr); return 2; }
        [bubble.shape displayIfNeeded];
        NSBitmapImageRep *rep = [bubble.shape bitmapImageRepForCachingDisplayInRect:bubble.shape.bounds];
        [bubble.shape cacheDisplayInRect:bubble.shape.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"bubble-%lu.png", (unsigned long)i]] atomically:YES];
        printf("PASS case %lu: %.0fx%.0f; document %.0f; scroll %s; complete text and visible frame\n",(unsigned long)i,bubble.panel.frame.size.width,bubble.panel.frame.size.height,bubble.documentHeight,bubble.scrollable ? "yes":"no");
        if (bubble.scrollable) {
            [bubble.scroll.contentView scrollToPoint:NSMakePoint(0, bubble.documentHeight - bubble.scroll.contentView.bounds.size.height)];
            [bubble.scroll reflectScrolledClipView:bubble.scroll.contentView];
            if (!NSIntersectsRect(bubble.textView.visibleRect,last)) { fputs("FAIL: last line not reachable by scroll\n",stderr); return 3; }
        }
    }
    return 0;
}

static int RunOCRTest(NSString *directory) {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    printf("Available OCR languages: %s\n",[[[VNRecognizeTextRequest new] supportedRecognitionLanguagesAndReturnError:NULL] componentsJoinedByString:@", "].UTF8String);
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSImage *fixture=[[NSImage alloc] initWithSize:NSMakeSize(1000,360)]; [fixture lockFocus];
    [NSColor.whiteColor setFill]; NSRectFill(NSMakeRect(0,0,1000,360));
    NSArray *lines=@[@"Yi screenshot test",@"문서 번역 테스트",@"日本語の翻訳",@"截图翻译测试"];
    for (NSUInteger i=0;i<lines.count;i++) [lines[i] drawAtPoint:NSMakePoint(40,280-i*72) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:34],NSForegroundColorAttributeName:NSColor.blackColor}];
    [fixture unlockFocus]; CGImageRef image=[fixture CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:@"ocr-fixture.png"] atomically:YES];
    NSError *error=nil; NSString *text=RecognizeImage(image,&error);
    if (error || !text.length) { fprintf(stderr,"FAIL OCR: %s\n",error.localizedDescription.UTF8String); return 1; }
    printf("OCR result:\n%s\n",text.UTF8String);
    for (NSString *pattern in @[@"翻译一下",@"\\p{Hangul}",@"日本",@"截图"]) if ([text rangeOfString:pattern options:NSRegularExpressionSearch].location==NSNotFound) { fprintf(stderr,"FAIL OCR missing script: %s\n",pattern.UTF8String); return 2; }
    puts("PASS: English, Korean, Japanese and Chinese recognized locally."); return 0;
}

static void RunTargetTests(Translator *translator, NSUInteger index) {
    NSArray *targets=@[@"en",@"ko",@"ja",@"fr",@"zh-CN"];
    NSArray *patterns=@[@"[A-Za-z]",@"\\p{Hangul}",@"[\\p{Hiragana}\\p{Katakana}]",@"[A-Za-z]",@"\\p{Han}"];
    if (index>=targets.count) { puts("PASS: Chinese, English, Korean, Japanese and French targets; target-scoped cache."); exit(0); }
    translator.targetLanguage=targets[index];
    NSString *source=index==4 ? @"Welcome to Yi." : @"你好，欢迎使用翻译。";
    [translator translate:source completion:^(NSString *result,NSError *error){
        if (error || [result rangeOfString:patterns[index] options:NSRegularExpressionSearch].location==NSNotFound || !result.length) { fprintf(stderr,"FAIL target %s\n",[targets[index] UTF8String]); exit(1); }
        printf("%s → %s\n",[targets[index] UTF8String],result.UTF8String); fflush(stdout); RunTargetTests(translator,index+1);
    }];
}

static void RunTranslationTests(Translator *translator, NSArray<NSString *> *samples, NSUInteger index) {
    if (index >= samples.count) { puts("PASS: all public samples translated to Chinese."); exit(0); }
    [translator translate:samples[index] completion:^(NSString *result, NSError *error) {
        if (error) { fprintf(stderr, "FAIL: %s\n", error.localizedDescription.UTF8String); exit(1); }
        printf("%s → %s\n", samples[index].UTF8String, result.UTF8String); fflush(stdout);
        NSRegularExpression *foreign = [NSRegularExpression regularExpressionWithPattern:@"[\\p{Hangul}\\p{Hiragana}\\p{Katakana}\\p{Latin}\\p{Cyrillic}\\p{Arabic}]" options:0 error:nil];
        if ([foreign firstMatchInString:result options:0 range:NSMakeRange(0, result.length)] || !result.length) { fputs("FAIL: untranslated foreign text remains.\n", stderr); exit(2); }
        if (index == 5) {
            for (NSString *meaning in @[@"明天", @"会议", @"首尔", @"护照", @"谢"]) {
                if (![result containsString:meaning]) { fprintf(stderr, "FAIL: missing meaning: %s\n", meaning.UTF8String); exit(3); }
            }
        }
        RunTranslationTests(translator, samples, index + 1);
    }];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--ocr-test"]) return RunOCRTest(NSProcessInfo.processInfo.arguments.lastObject);
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--target-test"]) { RunTargetTests([Translator new],0); [NSRunLoop.mainRunLoop run]; return 0; }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--layout-test"]) {
            NSString *output = NSProcessInfo.processInfo.arguments.lastObject;
            return RunLayoutTests(output);
        }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--translate-test"]) {
            Translator *translator = [Translator new];
            RunTranslationTests(translator, @[@"document", @"Bonjour", @"Guten Morgen", @"こんにちは", @"오늘 meeting은 오후 세 시입니다. Please bring the document. ありがとうございます。", @"明天的 meeting 在 서울，please bring your passport，ありがとう。", @"Bonjour, 오늘 날씨 is beautiful. Спасибо! مرحبا"], 0);
            [NSRunLoop.mainRunLoop run];
        } else {
            NSApplication *app = NSApplication.sharedApplication;
            AppDelegate *delegate = [AppDelegate new]; app.delegate = delegate;
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; [app run];
        }
    }
    return 0;
}
