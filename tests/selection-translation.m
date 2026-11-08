#define main YiApplicationMain
#import "../Sources/main.m"
#undef main

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

@interface FixtureReader : SelectionReader
@end
@implementation FixtureReader
- (BOOL)isElement:(id)element { return [element isKindOfClass:NSDictionary.class]; }
- (id)attribute:(id)element name:(CFStringRef)name { return element[(__bridge NSString *)name]; }
- (id)parameter:(id)element name:(CFStringRef)name value:(id)value {
    if (!value) return nil;
    return element[(__bridge NSString *)name];
}
@end

@interface NameTranslator : Translator
@property NSMutableArray *requests;
@property BOOL failRetry;
@end
@implementation NameTranslator
- (instancetype)init { if ((self = [super init])) _requests = [NSMutableArray new]; return self; }
- (void)raw:(NSString *)text source:(NSString *)source completion:(TranslationCompletion)completion {
    [self.requests addObject:@[source, text]];
    if ([source isEqual:@"auto"]) { completion(text, nil); return; } // Reproduce the reported untranslated result.
    if (self.failRetry) { completion(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); return; }
    NSDictionary *translations = @{@"Welcome to Chen Shanglong Music Studio":@"欢迎来到陈尚龙音乐工作室", @"Welcome to John Smith Music Studio":@"欢迎来到约翰·史密斯音乐工作室", @"Bonjour Pierre":@"你好，皮埃尔"};
    completion(translations[text] ?: text, nil);
}
@end

@interface SelectionSubmissionFixture : AppDelegate
@property NSMutableArray<NSString *> *submitted;
@end
@implementation SelectionSubmissionFixture
- (void)runTranslation:(NSString *)text anchor:(NSRect)anchor context:(NSString *)context pid:(pid_t)pid {
    [self.submitted addObject:text];
}
@end

int main(void) {
    @autoreleasepool {
        FixtureReader *reader = [FixtureReader new];
        NSRect fallback = SelectionAnchorAtPoint(NSMakePoint(100, 100));
        NSDictionary *web = @{@"AXSelectedTextMarkerRange":@"selected-marker", @"AXStringForTextMarkerRange":@"Welcome to Chen Shanglong Music Studio"};
        NSRect drag = SelectionAnchorForDrag(NSMakePoint(260, 150), NSMakePoint(100, 150));
        Check(NSMidX(drag) == 180 && NSEqualRects(drag, SelectionAnchorForDrag(NSMakePoint(100, 150), NSMakePoint(260, 150))),
              @"drag fallback must point to the middle in either direction");
        NSDictionary *textOnly = @{@"AXSelectedText": @"Change visibility"};
        Check(NSEqualRects([reader readFocus:textOnly hit:nil window:nil fallback:drag].anchor, drag),
              @"a missing text rectangle must retain the drag anchor");
        CGRect textRect = CGRectMake(50, 90, 150, 20);
        id textBounds = CFBridgingRelease(AXValueCreate(kAXValueCGRectType, &textRect));
        NSDictionary *textWithMarkers = @{@"AXSelectedText": @"Change visibility", @"AXSelectedTextMarkerRange": @"markers",
                                          @"AXBoundsForTextMarkerRange": textBounds};
        NSRect markerAnchor = [reader readFocus:textWithMarkers hit:nil window:nil fallback:drag].anchor;
        Check(NSMidX(markerAnchor) == 125 && markerAnchor.size.height == 20,
              @"browser marker bounds must take precedence over the drag estimate");
        [NSApplication sharedApplication];
        NSRect display = NSScreen.screens.firstObject.visibleFrame;
        CGFloat left = NSMidX(display) - 260;
        CGFloat bottom = NSMinY(display) + 80;
        CGFloat top = NSMidY(display);
        NSRect paragraphDrag = SelectionAnchorForDrag(NSMakePoint(left, top), NSMakePoint(left + 520, bottom));
        reader.dragAnchor = paragraphDrag;
        CGFloat screenTop = NSMaxY(NSScreen.screens.firstObject.frame);
        CGRect proxyRect = CGRectMake(left - 170, screenTop - NSMaxY(display), 110, 20);
        id proxyBounds = CFBridgingRelease(AXValueCreate(kAXValueCGRectType, &proxyRect));
        CFRange paragraphRange = CFRangeMake(0, 100);
        id paragraphValue = CFBridgingRelease(AXValueCreate(kAXValueCFRangeType, &paragraphRange));
        NSDictionary *proxy = @{@"AXSelectedText": @"A selected document paragraph.", @"AXSelectedTextRange": paragraphValue,
                                @"AXBoundsForRange": proxyBounds};
        Selection *paragraph = [reader readFocus:proxy hit:nil window:nil fallback:paragraphDrag];
        Check([paragraph.text isEqual:proxy[@"AXSelectedText"]] && NSEqualRects(paragraph.anchor, paragraphDrag),
              @"unrelated editor coordinates must preserve text and use the visible drag center");
        CGRect paragraphRect = CGRectMake(left - 5, screenTop - top - 15, 570, top - bottom + 16);
        NSMutableDictionary *withMarkers = proxy.mutableCopy;
        withMarkers[@"AXSelectedTextMarkerRange"] = @"visible markers";
        withMarkers[@"AXBoundsForTextMarkerRange"] = CFBridgingRelease(AXValueCreate(kAXValueCGRectType, &paragraphRect));
        NSRect visibleAnchor = [reader readFocus:withMarkers hit:nil window:nil fallback:paragraphDrag].anchor;
        Check(NSEqualRects(visibleAnchor, NSMakeRect(left - 5, bottom - 1, 570, top - bottom + 16)),
              @"a valid marker rectangle must supersede bad range coordinates and the drag estimate");
        Bubble *paragraphBubble = [Bubble new];
        NSString *translation = [@"这是需要滚动查看的长段落。" stringByPaddingToLength:1200 withString:@"译文仍应放在蓝色选区的中间上方。" startingAtIndex:0];
        [paragraphBubble layoutText:translation anchor:paragraph.anchor result:YES display:NO];
        Check(paragraphBubble.scrollable && paragraphBubble.shape.pointsDown &&
              NSMinY(paragraphBubble.panel.frame) >= NSMaxY(paragraphDrag) &&
              fabs(NSMidX(paragraphBubble.panel.frame) - NSMidX(paragraphDrag)) < 1 &&
              fabs(NSMinX(paragraphBubble.panel.frame) + paragraphBubble.shape.arrowX - NSMidX(paragraphDrag)) < 1,
              @"a long translation with bogus editor coordinates must sit above the real drag with a centered pointer");
        reader.dragAnchor = NSZeroRect;
        NSDictionary *focus = @{@"AXParent":web};
        Check([[reader readFocus:focus hit:nil window:nil fallback:fallback].text isEqual:@"Welcome to Chen Shanglong Music Studio"], @"WebKit parent text-marker selection must be read");
        NSDictionary *nested = @{@"AXChildren":@[@{@"AXChildren":@[web]}]};
        Check([reader readFocus:@{} hit:nil window:nested fallback:fallback] != nil, @"nested web area selection must be found even when focus is a container");
        Check([reader readFocus:nil hit:web window:nil fallback:fallback] != nil, @"hit-tested text must work without focused text");
        NSDictionary *secure = @{@"AXSubrole":@"AXSecureTextField", @"AXSelectedText":@"secret"};
        Check([reader readFocus:secure hit:web window:nested fallback:fallback] == nil, @"secure focus must block all fallbacks");
        Check([reader readFocus:@{} hit:nil window:@{@"AXValue":@"unselected page content"} fallback:fallback] == nil, @"unselected AXValue must never be treated as selected text");
        CFRange characters=CFRangeMake(7,17);
        id range=CFBridgingRelease(AXValueCreate(kAXValueCFRangeType,&characters));
        NSDictionary *ranged=@{@"AXSelectedTextRange":range,@"AXStringForRange":@"Change visibility"};
        Check([[reader readFocus:ranged hit:nil window:nil fallback:fallback].text isEqual:@"Change visibility"],@"selected range without AXSelectedText must be extracted using AXStringForRange");
        NSDictionary *sliced=@{@"AXSelectedTextRange":range,@"AXValue":@"prefix Change visibility suffix"};
        Check([[reader readFocus:sliced hit:nil window:nil fallback:fallback].text isEqual:@"Change visibility"],@"valid selected range must slice only selected text, excluding surrounding content");
        characters=CFRangeMake(1000,20); id invalid=CFBridgingRelease(AXValueCreate(kAXValueCFRangeType,&characters));
        Check([reader readFocus:@{@"AXSelectedTextRange":invalid,@"AXValue":@"short"} hit:nil window:nil fallback:fallback]==nil,@"out-of-bounds ranges must not fall back to whole content");
        id deep=web; for(NSUInteger depth=0;depth<14;depth++) deep=@{@"AXRole":@"AXGroup",@"AXContents":@[deep]};
        Check([[reader readFocus:nil hit:nil window:deep fallback:fallback].text isEqual:web[@"AXStringForTextMarkerRange"]],@"deeply nested chat web areas must be found through AXContents");
        Check([reader readFocus:@{@"AXSelectedText":@42} hit:nil window:nil fallback:fallback] == nil, @"malformed selection must be ignored");
        Check([reader readFocus:@{@"AXSelectedText":[@"x" stringByPaddingToLength:5001 withString:@"x" startingAtIndex:0]} hit:nil window:nil fallback:fallback] == nil, @"selection length limit must apply to every fallback");
        NSMutableDictionary *cycle = [NSMutableDictionary new]; cycle[@"AXParent"] = cycle;
        Check([reader readFocus:cycle hit:nil window:nil fallback:fallback] == nil, @"cyclic AX parents must terminate"); [cycle removeAllObjects];
        puts("PASS: web text markers, nested containers, hit testing, secure fields, no-selection, length limit and cycles.");

        SelectionSubmissionFixture *submission = [SelectionSubmissionFixture new];
        submission.submitted = [NSMutableArray new];
        NSArray<NSString *> *links = @[@"https://www.youtube.com/watch?v=example&t=298s",
            @"www.youtube.com/watch?v=example&t=298s", @"youtu.be/example", @"「https://example.com/」"];
        for (NSString *context in @[@"selection", @"compatibility"]) {
            for (NSString *link in links) {
                [submission submitSelectionText:link anchor:NSZeroRect context:context pid:42 manual:NO];
                Check(submission.submitted.count == 0,
                      [NSString stringWithFormat:@"standalone URL reached automatic %@ translation: %@", context, link]);
            }
        }
        Check(submission.lastSelectionKey.length > 0, @"ignored URLs still update the polling baseline");
        NSArray<NSString *> *textSamples = @[@"Read https://example.com for details.", @"详见https://example.com。", @"Hello world", @"main.m"];
        for (NSString *sample in textSamples)
            [submission submitSelectionText:sample anchor:NSZeroRect context:@"selection" pid:42 manual:NO];
        [submission submitSelectionText:links.firstObject anchor:NSZeroRect context:@"selection" pid:42 manual:YES];
        Check([submission.submitted isEqualToArray:[textSamples arrayByAddingObject:links.firstObject]],
              @"ordinary selections and manual URL requests remain available");
        puts("PASS: automatic selection ignores standalone web links and preserves prose and manual requests.");

        NameTranslator *translator = [NameTranslator new];
        for (NSString *sample in @[@"Welcome to Chen Shanglong Music Studio", @"Welcome to John Smith Music Studio", @"Bonjour Pierre"]) {
            [translator translate:sample completion:^(NSString *result, NSError *error) {
                Check(!error && [result rangeOfString:@"\\p{Han}" options:NSRegularExpressionSearch].location != NSNotFound, @"unchanged name-containing sentence must be translated using local language fallback");
            }];
        }
        Check([translator.requests[1][0] isEqual:@"en"], @"English phrase must retry as English, retaining the full name and context");
        Check([translator.requests.lastObject[0] isEqual:@"fr"], @"French phrase must retry as French");
        [translator translate:@"明天 Welcome to John Smith Music Studio。" completion:^(NSString *result, NSError *error) {
            Check(!error && [result hasPrefix:@"明天 "] && [result containsString:@"音乐工作室"], @"mixed Chinese and name phrase must preserve Chinese and translate the entire foreign span");
        }];
        NSUInteger count = translator.requests.count;
        [translator translate:@"Welcome to Chen Shanglong Music Studio" completion:^(NSString *result, NSError *error) { Check(result.length && !error, @"cache result must be available"); }];
        Check(count == translator.requests.count, @"successful retry must be cached");
        NameTranslator *cancelled = [NameTranslator new]; cancelled.failRetry = YES;
        [cancelled translate:@"Welcome to Chen Shanglong Music Studio" completion:^(NSString *result, NSError *error) { Check(!result && error.code == NSURLErrorCancelled, @"cancellation must not publish an untranslated success"); }];
        puts("PASS: English/French names, mixed Chinese preservation, retry cache and cancellation.");
    }
    return 0;
}
