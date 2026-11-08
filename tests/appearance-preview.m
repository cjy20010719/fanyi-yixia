#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
@interface AppearanceTestDelegate : AppDelegate
@property NSUInteger previews;
@end
@implementation AppearanceTestDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {}
- (void)preview:(id)sender { self.previews++;[super preview:sender]; }
@end
static void Check(BOOL ok,const char *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;id saved=[defaults objectForKey:@"bubbleAppearance"];
    @try {
        AppearanceTestDelegate *delegate=[AppearanceTestDelegate new];delegate.bubble=[Bubble new];delegate.targetCode=@"zh-CN";
        NSMenu *menu=[delegate createAppearanceMenu];[delegate createAppearanceMenu];
        [defaults setObject:@"system" forKey:@"bubbleAppearance"];
        [delegate updateBubbleAppearance];
        Check([delegate.bubble.appearanceKey isEqual:@"light"],"removed appearance must fall back to light glass");
        NSUInteger styleCount=0;
        for (NSMenuItem *item in menu.itemArray) if (!item.separatorItem) styleCount++;
        Check(styleCount==4,"only the four remaining styles should be offered");
        NSUInteger count=0;
        for(NSString *key in @[@"white",@"black",@"light",@"dark"]) {
            NSMenuItem *choice=nil;for(NSMenuItem *item in menu.itemArray) if([item.representedObject isEqual:key]) choice=item;
            Check(choice!=nil,"all four bubble appearances must have a menu choice");
            delegate.statusMenuOpen=YES;[delegate selectBubbleAppearance:choice];
            Check(delegate.appearancePreviewPending && delegate.previews==count,"preview must wait until native status-menu tracking ends");
            [delegate showPendingAppearancePreview];Check(delegate.previews==count,"open menu must not be disrupted by a preview");
            delegate.statusMenuOpen=NO;[delegate showPendingAppearancePreview];count++;
            Check(delegate.previews==count && delegate.bubble.panel.visible && [delegate.activeContext isEqual:@"preview"],"choosing any appearance must automatically replace the visible preview after menu closes");
            NSFont *bodyFont=[delegate.bubble.textView.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
            Check(bodyFont.pointSize == 13,"preview should use the chat-style system font");
            BOOL glass=[key isEqual:@"light"] || [key isEqual:@"dark"];
            BOOL dark=[key isEqual:@"black"] || [key isEqual:@"dark"];
            Check(delegate.bubble.shape.glassAppearance==glass && delegate.bubble.shape.darkAppearance==dark,"preview must use the selected solid/glass and light/dark combination");
            for(NSMenu *appearance in delegate.appearanceMenus) for(NSMenuItem *item in appearance.itemArray) if(!item.separatorItem) Check(item.state==([item.representedObject isEqual:key] ? NSControlStateValueOn : NSControlStateValueOff),"exactly one of four choices must be checked across both menus");
            [delegate showPendingAppearancePreview];Check(delegate.previews==count,"a consumed preview must not show twice");
            Check([[defaults stringForKey:@"bubbleAppearance"] isEqual:key],"explicit style selection must persist");
        }
        [delegate.bubble hide];puts("PASS: all four solid/glass appearances preview after native menu tracking, replace an existing preview, sync and save the correct choice.");
    } @finally { if(saved) [defaults setObject:saved forKey:@"bubbleAppearance"];else [defaults removeObjectForKey:@"bubbleAppearance"]; }
}return 0;}
