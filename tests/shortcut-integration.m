#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import "../Sources/ShortcutPreferences.h"

// No system registrations, user preferences or visible windows are changed.
static NSMutableDictionary<NSValue *,NSDictionary *> *ActiveKeys;
static UInt32 BlockedCode=UINT32_MAX,BlockedModifiers=0;
static NSUInteger NextReference=1;
static OSStatus FakeRegister(UInt32 code,UInt32 flags,EventHotKeyID identifier,EventTargetRef target,OptionBits options,EventHotKeyRef *output) {
    if(code==BlockedCode && flags==BlockedModifiers) return eventHotKeyExistsErr;
    for(NSDictionary *binding in ActiveKeys.allValues) if([binding[@"code"] unsignedIntValue]==code && [binding[@"flags"] unsignedIntValue]==flags) return eventHotKeyExistsErr;
    EventHotKeyRef reference=(EventHotKeyRef)(uintptr_t)(NextReference++*16);
    ActiveKeys[[NSValue valueWithPointer:reference]]=@{@"code":@(code),@"flags":@(flags),@"id":@(identifier.id)};*output=reference;return noErr;
}
static OSStatus FakeUnregister(EventHotKeyRef reference) { [ActiveKeys removeObjectForKey:[NSValue valueWithPointer:reference]];return noErr; }
@interface ShortcutDefaults : NSObject
@property NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (NSDictionary *)dictionaryForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
@end
@implementation ShortcutDefaults
+ (instancetype)standardUserDefaults {static ShortcutDefaults *defaults;static dispatch_once_t once;dispatch_once(&once,^{defaults=[self new];defaults.values=[NSMutableDictionary new];});return defaults;}
- (id)objectForKey:(NSString *)key {return self.values[key];}
- (NSString *)stringForKey:(NSString *)key {return self.values[key];}
- (NSDictionary *)dictionaryForKey:(NSString *)key {return self.values[key];}
- (BOOL)boolForKey:(NSString *)key {return [self.values[key] boolValue];}
- (void)setObject:(id)value forKey:(NSString *)key {self.values[key]=value;}
- (void)removeObjectForKey:(NSString *)key {[self.values removeObjectForKey:key];}
- (void)setBool:(BOOL)value forKey:(NSString *)key {self.values[key]=@(value);}
@end
@interface HiddenShortcutPreferencesController : YiShortcutPreferencesController @end
@implementation HiddenShortcutPreferencesController
- (void)showWindow:(id)sender {} // Exercise actual parent callbacks without showing UI.
@end
@interface ShortcutTestApplication : NSApplication @end
@implementation ShortcutTestApplication
- (void)activateIgnoringOtherApps:(BOOL)flag {}
@end
#define RegisterEventHotKey FakeRegister
#define UnregisterEventHotKey FakeUnregister
#define NSUserDefaults ShortcutDefaults
#define YiShortcutPreferencesController HiddenShortcutPreferencesController
#define main YiApplicationMain
#import "../Sources/main.m"
#undef main
#undef YiShortcutPreferencesController
#undef NSUserDefaults
#undef RegisterEventHotKey
#undef UnregisterEventHotKey

@interface ShortcutDelegateProbe : AppDelegate
@property NSUInteger captures;
@property NSUInteger selections;
@property NSUInteger opens;
@property NSUInteger cancellations;
@property NSUInteger dismissals;
@property NSUInteger automaticToggles;
@end
@implementation ShortcutDelegateProbe
- (void)applicationDidFinishLaunching:(NSNotification *)notification {}
- (void)capture:(id)sender {self.captures++;}
- (void)translateSelectedText:(id)sender {self.selections++;}
- (void)showSetup:(id)sender {self.opens++;}
- (void)cancel {self.cancellations++;}
- (void)dismissStatusMenu {self.dismissals++;}
- (void)updatePermission {self.pauseItem.state=self.started && self.enabled ? NSControlStateValueOn : NSControlStateValueOff;}
- (void)updateStatusIcon {}
- (void)toggle:(id)sender {self.automaticToggles++;[super toggle:sender];}
@end
static void Check(BOOL ok,const char *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
static void Spin(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.06];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}
static NSEvent *Key(UInt16 code,NSEventModifierFlags flags){return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];}
static void SetPending(YiShortcutPreferencesController *controller,NSString *action,UInt16 code,NSEventModifierFlags flags){[controller beginRecordingForAction:action];[controller recordKeyEvent:Key(code,flags)];Check(!controller.recordingAction,"fixture shortcut must be accepted before Save");}
static OSStatus SendHotkey(ShortcutDelegateProbe *delegate,UInt32 value,OSType signature){EventRef event=NULL;CreateEvent(NULL,kEventClassKeyboard,kEventHotKeyPressed,0,kEventAttributeNone,&event);EventHotKeyID identifier={signature,value};SetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,sizeof(identifier),&identifier);OSStatus status=TranslationHotkeyHandler(NULL,event,(__bridge void *)delegate);ReleaseEvent(event);return status;}
int main(void){@autoreleasepool{
    [ShortcutTestApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ActiveKeys=[NSMutableDictionary new];ShortcutDelegateProbe *delegate=[ShortcutDelegateProbe new];delegate.shortcuts=YiDefaultShortcuts();delegate.enabled=YES;delegate.started=YES;
    NSMenu *menu=[NSMenu new];NSArray *selectors=@[NSStringFromSelector(@selector(showSetup:)),NSStringFromSelector(@selector(translateSelectedText:)),NSStringFromSelector(@selector(capture:)),NSStringFromSelector(@selector(toggle:))];
    for(NSString *selector in selectors){NSMenuItem *item=[menu addItemWithTitle:@"fixture" action:NSSelectorFromString(selector) keyEquivalent:@""];item.target=delegate;}delegate.statusMenu=menu;delegate.pauseItem=menu.itemArray.lastObject;
    Check([delegate registerShortcutKeys:delegate.shortcuts strict:YES error:NULL] && ActiveKeys.count==4,"startup must register all three default actions");[delegate updateShortcutMenuItems];
    NSDictionary *original=delegate.shortcuts,*stored=YiShortcutsPropertyList(original);[ShortcutDefaults.standardUserDefaults setObject:stored forKey:@"keyboardShortcuts"];[ShortcutDefaults.standardUserDefaults setObject:@"keep" forKey:@"otherPreference"];
    [delegate showShortcutPreferences:nil];Spin();Check(delegate.shortcutsSuspended && !ActiveKeys.count && delegate.shortcutPreferences,"opening settings must suspend all Carbon keys so existing shortcuts can be recorded");
    SetPending(delegate.shortcutPreferences,YiShortcutCapture,kVK_ANSI_T,NSEventModifierFlagOption);BlockedCode=kVK_ANSI_T;BlockedModifiers=optionKey;
    [delegate.shortcutPreferences save:nil];
    Check([delegate.shortcutPreferences.errorMessage containsString:@"占用"] && delegate.shortcutsSuspended,"an occupied shortcut must show an inline error and leave settings editable");
    Check(!ActiveKeys.count && !delegate.captureHotkey && !delegate.selectionHotkey && !delegate.openHotkey,"registration collision must roll back every temporary registration");
    Check([delegate.shortcuts isEqual:original] && [[ShortcutDefaults.standardUserDefaults objectForKey:@"keyboardShortcuts"] isEqual:stored],"failed Save must not change active model or persisted preferences");
    BlockedCode=UINT32_MAX;[delegate.shortcutPreferences cancel:nil];
    Check(!delegate.shortcutsSuspended && ActiveKeys.count==4 && [delegate.shortcuts isEqual:original],"Cancel must restore all original global bindings");
    [delegate showShortcutPreferences:nil];Spin();
    SetPending(delegate.shortcutPreferences,YiShortcutOpen,kVK_ANSI_O,NSEventModifierFlagControl|NSEventModifierFlagOption);
    SetPending(delegate.shortcutPreferences,YiShortcutSelection,kVK_ANSI_F,NSEventModifierFlagControl|NSEventModifierFlagOption);
    SetPending(delegate.shortcutPreferences,YiShortcutCapture,kVK_ANSI_D,NSEventModifierFlagControl|NSEventModifierFlagOption);
    NSDictionary<NSString *,YiShortcut *> *candidate=delegate.shortcutPreferences.pendingShortcuts;[delegate.shortcutPreferences save:nil];
    Check(!delegate.shortcutsSuspended && ActiveKeys.count==4 && [delegate.shortcuts isEqual:candidate],"successful Save must commit all three registrations without duplicate restoration");
    Check([[ShortcutDefaults.standardUserDefaults objectForKey:@"keyboardShortcuts"] isEqual:YiShortcutsPropertyList(candidate)] && [[ShortcutDefaults.standardUserDefaults objectForKey:@"otherPreference"] isEqual:@"keep"],"Save must persist exactly the shortcuts without altering unrelated settings");
    NSArray *actions=YiShortcutActions();for(NSUInteger i=0;i<4;i++){YiShortcut *shortcut=candidate[actions[i]];NSMenuItem *item=menu.itemArray[i];Check([item.keyEquivalent isEqual:shortcut.keyEquivalent] && item.keyEquivalentModifierMask==shortcut.modifiers,"menu shortcuts must use each current configured chord");Check([item.title isEqual:YiShortcutActionName(actions[i])],"successful registrations must not retain unavailable labels");}
    NSUInteger cancellations=delegate.cancellations;[delegate handle:Key(kVK_ANSI_D,NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCapsLock)];Check(delegate.cancellations==cancellations,"configured shortcuts must not be mistaken for translation cancellation");[delegate handle:Key(kVK_ANSI_S,NSEventModifierFlagOption)];Check(delegate.cancellations==cancellations+1,"replaced defaults must no longer bypass ordinary keyboard handling");
    for(UInt32 value=1;value<=5;value++)Check(SendHotkey(delegate,value,'Trns')==(value<=4?noErr:eventNotHandledErr),"known IDs 1-4 must route and ID 5 must be ignored");Check(SendHotkey(delegate,1,'Nope')==eventNotHandledErr,"foreign hotkey signatures must be ignored");Spin();Check(delegate.captures==1 && delegate.selections==1 && delegate.opens==1,"global hotkey IDs must dispatch to three separate actions exactly once");
    Check(delegate.automaticToggles==1 && !delegate.enabled && delegate.pauseItem.state==NSControlStateValueOff,"Option D routing must disable automatic selection and clear its checkmark");
    Check(SendHotkey(delegate,4,'Trns')==noErr,"automatic hotkey must also work while paused");Spin();
    Check(delegate.automaticToggles==2 && delegate.enabled && delegate.pauseItem.state==NSControlStateValueOn,"second automatic hotkey must restore selection and its checkmark");
    delegate.shortcutsSuspended=YES;Check(SendHotkey(delegate,1,'Trns')==noErr,"registered events may arrive while settings suspend dispatch");Spin();Check(delegate.captures==1,"hotkey dispatch must remain suspended while recording settings");delegate.shortcutsSuspended=NO;
    [delegate unregisterShortcutKeys];Check(!ActiveKeys.count,"termination cleanup must release all three bindings");
    puts("PASS: occupied Save rolls back all registrations without persistence; Cancel restores originals; successful Save commits all3 and updates menus.");
    puts("PASS: configured key events avoid cancellation; global IDs1/2/3 route distinctly; unknown/signature/suspended events are ignored.");
}return 0;}
