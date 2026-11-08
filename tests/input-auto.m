#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
@interface AutoTestDelegate:AppDelegate
@property NSUInteger submissions;
@property NSString *submitted;
@end
@implementation AutoTestDelegate
- (void)translateInput:(id)sender { [self.inputTranslationTimer invalidate]; self.inputTranslationTimer=nil; self.submissions++; self.submitted=self.inputView.string; }
@end
static void Require(BOOL ok,const char *message) { if(!ok) { fprintf(stderr,"FAIL: %s\n",message);exit(1); } }
static void Spin(double seconds) { NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds]; while(until.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
static void Change(AutoTestDelegate *d,NSString *text) { d.inputView.string=text; [d textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:d.inputView]]; }
int main(void) { @autoreleasepool {
 [NSApplication sharedApplication]; AutoTestDelegate *d=[AutoTestDelegate new];d.targetCode=@"zh-CN";[d showSetup:nil];
 [d updatePermissionIndicatorsWithSelection:YES capture:YES];
 Require(d.accessPermissionButton.hidden && d.capturePermissionButton.hidden && [d.permissionLabel.stringValue isEqual:@"权限已就绪"],"granted permissions must leave only a short status");
 [d updatePermissionIndicatorsWithSelection:NO capture:YES];
 Require(!d.accessPermissionButton.hidden && d.capturePermissionButton.hidden && NSMinX(d.accessPermissionButton.frame)==NSMinX(d.capturePermissionButton.frame),"only missing selection permission must appear, right aligned");
 [d updatePermissionIndicatorsWithSelection:YES capture:NO];
 Require(d.accessPermissionButton.hidden && !d.capturePermissionButton.hidden,"only missing capture permission must appear");
 [d updatePermissionIndicatorsWithSelection:NO capture:NO];
 Require(!d.accessPermissionButton.hidden && !d.capturePermissionButton.hidden && NSMaxX(d.accessPermissionButton.frame)<NSMinX(d.capturePermissionButton.frame),"both missing permissions must appear without overlap");
 [d updatePermission];
 Change(d,@"h");Spin(.3);Change(d,@"hello");Spin(.35);Require(d.submissions==0,"typing burst must debounce");Spin(.35);Require(d.submissions==1 && [d.submitted isEqual:@"hello"],"one request for newest text after pause");
 Change(d,@"to delete");Spin(.2);Change(d,@" \n");Spin(.7);Require(d.submissions==1 && !d.outputView.string.length,"clearing input cancels pending translation and result");
 Change(d,@"marked");[d.inputView setMarkedText:@"你好" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(0,6)];Spin(.8);Require(d.submissions==1,"unfinished IME text must never submit");[d.inputView unmarkText];Spin(.8);Require(d.submissions==2,"IME commit must submit after marked text clears");
 Change(d,@"manual");[d translateInput:nil];Spin(.7);Require(d.submissions==3,"manual submission must cancel pending auto request");
 NSUInteger before=d.generation;Change(d,@"edited");Require(d.generation>before && !d.activeText,"edits immediately invalidate late request completions");[d.setupWindow orderOut:nil];Spin(.7);Require(d.submissions==3,"hidden window must not submit pending text");
 [d.permissionTimer invalidate];[d.setupWindow close];fprintf(stdout,"PASS: debounced typing/paste, empty input, IME commit, manual deduplication, stale response invalidation and hidden window.\n");
}return 0;}
