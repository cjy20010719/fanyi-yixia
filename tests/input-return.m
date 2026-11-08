#define main YiApplicationMain
#import "../Sources/main.m"
#undef main

@interface ReturnTestDelegate : AppDelegate
@property NSUInteger submissions;
@property NSString *submittedText;
@property NSUInteger captures;
@property NSUInteger selectionRequests;
@property NSUInteger automaticToggles;
@end
@implementation ReturnTestDelegate
- (void)translateInput:(id)sender { self.submissions++; self.submittedText = self.inputView.string; }
- (void)capture:(id)sender { self.captures++; }
- (void)translateSelectedText:(id)sender { self.selectionRequests++; }
- (void)toggle:(id)sender { self.automaticToggles++; }
@end

static void Require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void SendReturn(NSWindow *window, NSEventModifierFlags modifiers, BOOL keypad) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:keypad ? @"\003" : @"\r" charactersIgnoringModifiers:keypad ? @"\003" : @"\r" isARepeat:NO keyCode:keypad ? 76 : 36];
    [NSApp sendEvent:event];
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ReturnTestDelegate *delegate = [ReturnTestDelegate new];
        delegate.targetCode = @"zh-CN";
        [delegate showSetup:nil];
        Require(delegate.inputView.delegate == delegate, "source editor must actually be connected to the command handler");
        delegate.inputView.string = @"two";
        [delegate.setupWindow makeFirstResponder:delegate.inputView];
        [delegate.inputView setSelectedRange:NSMakeRange(3, 0)];
        SendReturn(delegate.setupWindow, 0, NO);
        Require(delegate.submissions == 1 && [delegate.submittedText isEqual:@"two"] && [delegate.inputView.string isEqual:@"two"], "Return must submit current source without inserting a newline");
        SendReturn(delegate.setupWindow, NSEventModifierFlagShift, NO);
        Require(delegate.submissions == 1 && [delegate.inputView.string isEqual:@"two\n"], "Shift+Return must insert a newline without submitting");
        SendReturn(delegate.setupWindow, NSEventModifierFlagNumericPad, YES);
        Require(delegate.submissions == 2, "keypad Enter must submit too");
        [delegate.inputView setMarkedText:@"你好" selectedRange:NSMakeRange(0, 2) replacementRange:NSMakeRange(NSNotFound, 0)];
        Require(delegate.inputView.hasMarkedText, "IME fixture must contain marked text");
        Require(![delegate textView:delegate.inputView doCommandBySelector:@selector(insertNewline:)], "Return while composing must remain under the input method's control");
        Require(delegate.submissions == 2, "composition confirmation must not submit prematurely");
        [delegate.inputView unmarkText];
        Require(![delegate textView:delegate.outputView doCommandBySelector:@selector(insertNewline:)], "other text views must not submit the source");
        for (UInt32 value=1; value<=5; value++) {
            EventRef event=NULL;
            CreateEvent(NULL,kEventClassKeyboard,kEventHotKeyPressed,0,kEventAttributeNone,&event);
            EventHotKeyID hotkey={'Trns',value};
            SetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,sizeof(hotkey),&hotkey);
            OSStatus status=TranslationHotkeyHandler(NULL,event,(__bridge void *)delegate);
            Require(status==(value<=4 ? noErr : eventNotHandledErr), "only the four known hotkey identifiers should be handled");
            ReleaseEvent(event);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            Require(delegate.captures==1 && delegate.selectionRequests==1 && delegate.automaticToggles==1, "screenshot, selection and automatic-selection hotkeys must dispatch to distinct actions exactly once");
            [delegate.permissionTimer invalidate]; [delegate.setupWindow close];
            puts("PASS: native Return submits, Shift+Return inserts newline, keypad Enter submits, IME composition and other editors do not submit.");
            puts("PASS: Carbon hotkey routing distinguishes screenshot, selection and unknown identifiers.");
            exit(0);
        });
        [NSApp run];
    }
    return 0;
}
