#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
static void Check(BOOL condition,const char *message) { if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
static NSBitmapImageRep *Render(BubbleShape *shape) {
    [shape displayIfNeeded];
    NSBitmapImageRep *bitmap=[shape bitmapImageRepForCachingDisplayInRect:shape.bounds];
    [shape cacheDisplayInRect:shape.bounds toBitmapImageRep:bitmap];return bitmap;
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSBitmapImageRep *stripes=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:320 pixelsHigh:160 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    for(NSInteger y=0;y<160;y++) for(NSInteger x=0;x<320;x++) {
        NSUInteger shade=x%16<8 ? 0 : 255; NSUInteger pixel[4]={shade,shade,shade,255};
        [stripes setPixel:pixel atX:x y:y];
    }
    NSImage *softened=BlurredBubblePixels(stripes.CGImage,NSMakeRect(90,40,120,80),NSMakeRect(0,0,320,160));
    Check(softened!=nil,"a glass bubble must produce a cropped blurred background sample");
    NSBitmapImageRep *sample=[NSBitmapImageRep imageRepWithData:softened.TIFFRepresentation];
    NSUInteger left[4],right[4]; [sample getPixel:left atX:20 y:40]; [sample getPixel:right atX:28 y:40];
    Check(left[0]>45 && left[0]<210 && labs((long)left[0]-(long)right[0])<45,"the blur must remove high-contrast background lettering while retaining midtones");
    NSRect bubbleFrame=NSMakeRect(90,40,120,80),captureFrame=NSIntersectionRect(NSInsetRect(bubbleFrame,-48,-48),NSMakeRect(0,0,320,160));
    CGImageRef region=CGImageCreateWithImageInRect(stripes.CGImage,CGRectMake(NSMinX(captureFrame),160-NSMaxY(captureFrame),captureFrame.size.width,captureFrame.size.height));
    NSImage *regional=BlurredBubblePixels(region,bubbleFrame,captureFrame); CGImageRelease(region);
    Check(regional!=nil,"regional screen capture must be usable for a bubble near a display edge");
    NSBitmapImageRep *regionalSample=[NSBitmapImageRep imageRepWithData:regional.TIFFRepresentation];
    NSUInteger regionalPixel[4],fullPixel[4]; [regionalSample getPixel:regionalPixel atX:60 y:40]; [sample getPixel:fullPixel atX:60 y:40];
    Check(labs((long)regionalPixel[0]-(long)fullPixel[0])<8,"regional and full-display captures must align to the same screen content");
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSDictionary *arguments=[defaults volatileDomainForName:NSArgumentDomain];
    Bubble *bubble=[Bubble new];
    NSScreen *screen=NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    Check(screen!=nil,"bubble style test requires the real display service");
    NSString *text=@"Hello 文档";
    [bubble layoutText:text anchor:NSMakeRect(NSMidX(screen.visibleFrame),NSMidY(screen.visibleFrame),1,18) result:YES display:NO];
    for(NSString *style in @[@"white",@"black",@"light",@"dark",@"black",@"white"]) {
        NSMutableDictionary *fixture=[arguments mutableCopy] ?: [NSMutableDictionary new]; fixture[@"bubbleAppearance"]=style;
        [defaults setVolatileDomain:fixture forName:NSArgumentDomain]; [bubble applyAppearance];
        BOOL solid=[style isEqual:@"white"] || [style isEqual:@"black"],dark=[style isEqual:@"black"] || [style isEqual:@"dark"];
        Check(bubble.shape.glassAppearance!=solid && bubble.shape.darkAppearance==dark,"four appearance selections must switch light/dark and glass/solid independently");
        Check([bubble.translation isEqual:text] && [bubble.textView.string isEqual:text],"appearance changes must retain the existing translation");
        Check(NSMaxY(bubble.scroll.frame)<=NSMinY(bubble.languagePicker.frame)-4 && bubble.panel.frame.size.height<=75,"short bubbles must use compact nonoverlapping header/body spacing");
        Check(fabs(NSMinX(bubble.scroll.frame)-NSMinX(bubble.languagePicker.frame))<0.01,"language title and translation must share a left edge");
        NSColor *header=[bubble.languagePicker.contentTintColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
        Check(fabs(header.redComponent-header.greenComponent)<0.01 && fabs(header.greenComponent-header.blueComponent)<0.01,"header and chevron must use neutral colors instead of gold");
        NSFont *bodyFont=[bubble.textView.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        Check([bodyFont.fontName isEqual:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular].fontName] && bodyFont.pointSize == 13 && bubble.languagePicker.font.pointSize==12,
              "bubble body and header should use system typography");
        Check(bubble.panel.alphaValue==1 && bubble.shape.alphaValue==1 && bubble.textView.alphaValue==1,"translucency must not fade translation or controls");
        NSColor *body=[bubble.foregroundColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
        Check(dark ? body.redComponent>0.8 : body.redComponent<0.4,"foreground must remain readable after dark/light switching");
        NSBitmapImageRep *rendered=Render(bubble.shape); CGFloat scale=rendered.pixelsWide/bubble.shape.bounds.size.width;
        NSUInteger pixel[4]; [rendered getPixel:pixel atX:(NSInteger)(12*scale) y:(NSInteger)(NSMidY(bubble.shape.bounds)*scale)];
        if(solid) {
            Check(bubble.shape.backdrop.hidden,"solid styles must hide backdrop material");
            Check(pixel[3]==255,"classic backgrounds must be fully opaque");
            if(dark) Check(pixel[0]<60 && pixel[2]>pixel[0]+5,"classic black must render its original charcoal gradient, not inactive material gray");
            else Check(pixel[0]>245 && pixel[1]>245 && pixel[2]>245,"classic white must render its original white gradient, not inactive material gray");
        } else {
            Check(!bubble.shape.backdrop.hidden && bubble.shape.backdrop.state==NSVisualEffectStateActive && bubble.shape.backdrop.blendingMode==NSVisualEffectBlendingModeBehindWindow,"glass styles must retain actual active window-backdrop material");
            Check(bubble.shape.backdrop.alphaValue==1,"a bubble without screen capture access must use fully blurred native material");
        }
        NSView *hit=[bubble.shape hitTest:NSMakePoint(NSMidX(bubble.languagePicker.frame),NSMidY(bubble.languagePicker.frame))];
        Check(hit==bubble.languagePicker || [hit isDescendantOf:bubble.languagePicker],"background surface must not intercept language clicks");
        hit=[bubble.shape hitTest:NSMakePoint(NSMidX(bubble.clipboardButton.frame),NSMidY(bubble.clipboardButton.frame))];
        Check(hit==bubble.clipboardButton || [hit isDescendantOf:bubble.clipboardButton],"background surface must not intercept copy clicks");
    }
    Check(NSMaxX(bubble.languagePicker.frame) < NSMinX(bubble.swapButton.frame) &&
          NSMinX(bubble.speechButton.frame) - NSMaxX(bubble.swapButton.frame) == 3 &&
          NSMinX(bubble.shadeControl.frame) - NSMaxX(bubble.speechButton.frame) == 3 &&
          NSMinX(bubble.clipboardButton.frame) - NSMaxX(bubble.shadeControl.frame) == 3,
          "the four bubble controls must form a tight group without overlapping the language picker");
    NSString *structured = @"# 标题\n\n1. 第一项\n    - 子项\n\n2. 第二项";
    [bubble layoutText:structured anchor:NSMakeRect(NSMidX(screen.visibleFrame), NSMidY(screen.visibleFrame), 1, 18) result:YES display:NO];
    Check([bubble.textView.string isEqualToString:structured] && [bubble.translation isEqualToString:structured],
          "blank lines and list indentation must be identical in the rendered bubble and copied result");
    NSString *longText=[@"这是一段需要完整阅读的长译文，右侧滚动条不能遮挡任何文字。" stringByPaddingToLength:1500 withString:@"请继续阅读全部内容，确认每一行的末字清晰可见。" startingAtIndex:0];
    [bubble layoutText:longText anchor:NSMakeRect(NSMidX(screen.visibleFrame),NSMidY(screen.visibleFrame),1,18) result:YES display:NO];
    Check(bubble.scrollable && bubble.scroll.hasVerticalScroller,"long translations must remain scrollable");
    Check(bubble.scroll.frame.size.width-bubble.textView.textContainer.containerSize.width>=18,"long translation text must reserve a scrollbar strip");
    [bubble.textView.layoutManager ensureLayoutForTextContainer:bubble.textView.textContainer];
    NSRect longTextBounds=[bubble.textView.layoutManager usedRectForTextContainer:bubble.textView.textContainer];
    Check(NSMaxX(longTextBounds)<=bubble.scroll.frame.size.width-17,"long translation glyphs must not overlap the scrollbar");
    Check([bubble.textView.string isEqualToString:longText],"scrollbar spacing must retain the entire translation");
    NSRect visible = NSInsetRect(screen.visibleFrame, 12, 12);
    NSRect anchor = NSMakeRect(NSMidX(visible) - 90, NSMaxY(visible) - 170, 180, 20);
    [bubble layoutText:longText anchor:anchor result:YES display:NO];
    Check(bubble.shape.pointsDown && NSMinY(bubble.panel.frame) >= NSMaxY(anchor),
          "long results must use a scrollable bubble above the selection when there is room");
    Check(fabs(NSMidX(bubble.panel.frame) - NSMidX(anchor)) < 1 &&
          fabs(NSMinX(bubble.panel.frame) + bubble.shape.arrowX - NSMidX(anchor)) < 1,
          "the bubble and its pointer must center above the selection");
    anchor.origin.y = NSMaxY(visible) - anchor.size.height;
    [bubble layoutText:text anchor:anchor result:YES display:NO];
    Check(!bubble.shape.pointsDown && NSMaxY(bubble.panel.frame) <= NSMinY(anchor),
          "a selection at the top of the screen must show the bubble below");
    [bubble layoutText:longText anchor:NSMakeRect(NSMidX(visible),NSMidY(visible),1,18) result:YES display:NO];
    // Dispatch real AppKit mouse events to the shade control, including dragging
    // outside its bounds, then recreate the bubble to verify saved per-style values.
    id savedLevels=[defaults objectForKey:@"bubbleBackgroundLevels"];
    [defaults removeObjectForKey:@"bubbleBackgroundLevels"];
    NSMutableDictionary *fixture=[arguments mutableCopy] ?: [NSMutableDictionary new]; fixture[@"bubbleAppearance"]=@"light";
    [defaults setVolatileDomain:fixture forName:NSArgumentDomain]; [bubble applyAppearance];
    [bubble.panel orderFrontRegardless];
    NSPoint origin=[bubble.shadeControl convertPoint:NSMakePoint(12,12) toView:nil];
    NSView *shadeHit=[bubble.shape hitTest:[bubble.shadeControl convertPoint:NSMakePoint(12,12) toView:bubble.shape]];
    Check(shadeHit==bubble.shadeControl || [shadeHit isDescendantOf:bubble.shadeControl],"shade icon must receive its own mouse events");
    NSArray *types=@[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseDragged),@(NSEventTypeLeftMouseUp)];
    for(NSUInteger i=0;i<types.count;i++) {
        NSEvent *event=[NSEvent mouseEventWithType:[types[i] unsignedIntegerValue] location:NSMakePoint(origin.x,origin.y+(i ? 40 : 0)) modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:bubble.panel.windowNumber context:nil eventNumber:(NSInteger)i clickCount:1 pressure:i==2 ? 0 : 1];
        [NSApp sendEvent:event];
        if(i==1) Check(bubble.shadeControl.dragging && bubble.isInteracting && ![defaults dictionaryForKey:@"bubbleBackgroundLevels"],"drag must preview while retaining interaction and defer saving until release");
    }
    Check(fabs(bubble.shape.backgroundLevel-0.75)<0.01 && !bubble.shadeControl.dragging,"upward drag must lighten background and finish tracking outside the icon");
    Bubble *restored=[Bubble new];
    Check(fabs(restored.shape.backgroundLevel-0.75)<0.01,"a new bubble must restore the saved shade");
    fixture[@"bubbleAppearance"]=@"dark"; [defaults setVolatileDomain:fixture forName:NSArgumentDomain]; [restored applyAppearance];
    Check(restored.shape.backgroundLevel==0.5,"one appearance must not change another appearance's shade");
    [bubble hide];
    if(savedLevels) [defaults setObject:savedLevels forKey:@"bubbleBackgroundLevels"]; else [defaults removeObjectForKey:@"bubbleBackgroundLevels"];
    [defaults setVolatileDomain:arguments ?: @{} forName:NSArgumentDomain];
    puts("PASS: four bubble backgrounds render correctly, classic backgrounds are opaque, glass remains active, neutral headers and compact controls stay readable and clickable.");
}return 0;}
