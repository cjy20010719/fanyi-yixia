#ifndef YI_SHORTCUT_PREFERENCES_H
#define YI_SHORTCUT_PREFERENCES_H
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <math.h>

static NSString * const YiShortcutCapture=@"capture";
static NSString * const YiShortcutSelection=@"selection";
static NSString * const YiShortcutOpen=@"open";
static NSString * const YiShortcutAutomatic=@"automatic";
static NSEventModifierFlags YiShortcutModifierMask(void) { return NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift|NSEventModifierFlagCommand; }
static NSArray<NSString *> *YiShortcutActions(void) { return @[YiShortcutOpen,YiShortcutSelection,YiShortcutCapture,YiShortcutAutomatic]; }
static NSString *YiShortcutActionName(NSString *action) { return [@{YiShortcutAutomatic:@"自动划词",YiShortcutOpen:@"打开",YiShortcutSelection:@"划词翻译",YiShortcutCapture:@"截图翻译"} objectForKey:action] ?: action; }
static NSError *YiShortcutError(NSString *message) { return [NSError errorWithDomain:@"Yi.Shortcuts" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }

@interface YiShortcut : NSObject <NSCopying>
@property (nonatomic,readonly) UInt32 keyCode;
@property (nonatomic,readonly) NSEventModifierFlags modifiers;
+ (instancetype)shortcutWithKeyCode:(UInt32)keyCode modifiers:(NSEventModifierFlags)modifiers;
+ (instancetype)fromPropertyList:(id)value;
- (NSDictionary *)propertyList;
- (BOOL)validate:(NSError **)error;
- (NSString *)displayString;
- (NSString *)keyEquivalent;
- (UInt32)carbonModifiers;
@end
@implementation YiShortcut
+ (instancetype)shortcutWithKeyCode:(UInt32)keyCode modifiers:(NSEventModifierFlags)modifiers { YiShortcut *shortcut=[self new]; shortcut->_keyCode=keyCode; shortcut->_modifiers=modifiers & YiShortcutModifierMask(); return shortcut; }
+ (instancetype)fromPropertyList:(id)value {
    if(![value isKindOfClass:NSDictionary.class]) return nil;
    id key=value[@"keyCode"],flags=value[@"modifiers"];
    if(![key isKindOfClass:NSNumber.class] || ![flags isKindOfClass:NSNumber.class]) return nil;
    double code=[key doubleValue],mask=[flags doubleValue];
    if(!isfinite(code) || !isfinite(mask) || code<0 || code>127 || floor(code)!=code || mask<0 || mask>(double)NSUIntegerMax || floor(mask)!=mask) return nil;
    NSEventModifierFlags modifiers=[flags unsignedIntegerValue]; if(modifiers & ~YiShortcutModifierMask()) return nil;
    YiShortcut *shortcut=[self shortcutWithKeyCode:[key unsignedIntValue] modifiers:modifiers];
    return [shortcut validate:NULL] ? shortcut : nil;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (NSDictionary *)propertyList { return @{@"keyCode":@(self.keyCode),@"modifiers":@(self.modifiers)}; }
- (BOOL)isEqual:(id)object { return [object isKindOfClass:YiShortcut.class] && self.keyCode==[(YiShortcut *)object keyCode] && self.modifiers==[(YiShortcut *)object modifiers]; }
- (NSUInteger)hash { return (NSUInteger)self.keyCode ^ (NSUInteger)self.modifiers; }
- (BOOL)validate:(NSError **)error {
    NSString *message=nil;
    if(self.keyCode>127 || (self.keyCode>=54 && self.keyCode<=63) || self.keyCode==kVK_Escape) message=@"请选择一个字母、数字或功能键。Esc 用于取消录入。";
    else if(!(self.modifiers & (NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCommand))) message=@"快捷键至少需要包含 Control、Option 或 Command。";
    else if((self.modifiers & NSEventModifierFlagCommand) && !(self.modifiers & (NSEventModifierFlagControl|NSEventModifierFlagOption))) {
        NSSet *reserved=[NSSet setWithArray:@[@(kVK_ANSI_C),@(kVK_ANSI_V),@(kVK_ANSI_X),@(kVK_ANSI_A),@(kVK_ANSI_Z),@(kVK_ANSI_F),@(kVK_ANSI_S),@(kVK_ANSI_P),@(kVK_ANSI_T),@(kVK_ANSI_N),@(kVK_ANSI_Q),@(kVK_ANSI_H),@(kVK_ANSI_W),@(kVK_Tab),@(kVK_Space)]];
        if([reserved containsObject:@(self.keyCode)]) message=@"此组合属于系统或编辑常用快捷键，请加入 Option、Control 或换一组。";
    }
    if(message && error) *error=YiShortcutError(message); return message==nil;
}
- (UInt32)carbonModifiers {
    UInt32 flags=0; if(self.modifiers & NSEventModifierFlagControl) flags|=controlKey;
    if(self.modifiers & NSEventModifierFlagOption) flags|=optionKey;
    if(self.modifiers & NSEventModifierFlagShift) flags|=shiftKey;
    if(self.modifiers & NSEventModifierFlagCommand) flags|=cmdKey; return flags;
}
- (NSString *)keyEquivalent {
    switch(self.keyCode) {
        case kVK_Return:return @"\r"; case kVK_Tab:return @"\t"; case kVK_Space:return @" "; case kVK_Delete:return @"\b";
        case kVK_ForwardDelete:return [NSString stringWithFormat:@"%C",(unichar)NSDeleteFunctionKey];
        case kVK_Home:return [NSString stringWithFormat:@"%C",(unichar)NSHomeFunctionKey];
        case kVK_End:return [NSString stringWithFormat:@"%C",(unichar)NSEndFunctionKey];
        case kVK_PageUp:return [NSString stringWithFormat:@"%C",(unichar)NSPageUpFunctionKey];
        case kVK_PageDown:return [NSString stringWithFormat:@"%C",(unichar)NSPageDownFunctionKey];
        case kVK_LeftArrow:return [NSString stringWithFormat:@"%C",(unichar)NSLeftArrowFunctionKey];
        case kVK_RightArrow:return [NSString stringWithFormat:@"%C",(unichar)NSRightArrowFunctionKey];
        case kVK_UpArrow:return [NSString stringWithFormat:@"%C",(unichar)NSUpArrowFunctionKey];
        case kVK_DownArrow:return [NSString stringWithFormat:@"%C",(unichar)NSDownArrowFunctionKey];
    }
    const UInt32 functionCodes[]={kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20};
    for(NSUInteger i=0;i<20;i++) if(self.keyCode==functionCodes[i]) return [NSString stringWithFormat:@"%C",(unichar)(NSF1FunctionKey+i)];
    NSString *result=nil;
    TISInputSourceRef source=TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef data=source ? TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData) : NULL;
    if(data) {
        UInt32 dead=0;UniChar characters[8];UniCharCount count=0;
        OSStatus status=UCKeyTranslate((const UCKeyboardLayout *)CFDataGetBytePtr(data),(UInt16)self.keyCode,kUCKeyActionDisplay,0,LMGetKbdType(),kUCKeyTranslateNoDeadKeysBit,&dead,8,&count,characters);
        if(status==noErr && count) result=[[NSString stringWithCharacters:characters length:count] lowercaseString];
    }
    if(source) CFRelease(source);
    // A layout may not be available during startup or headless tests.
    if(!result.length) result=@{@(kVK_ANSI_A):@"a",@(kVK_ANSI_S):@"s",@(kVK_ANSI_D):@"d",@(kVK_ANSI_T):@"t",@(kVK_ANSI_Q):@"q",@(kVK_ANSI_H):@"h",@(kVK_ANSI_W):@"w"}[@(self.keyCode)];
    return result ?: @"";
}
- (NSString *)displayString {
    NSMutableString *label=[NSMutableString new];
    if(self.modifiers & NSEventModifierFlagControl) [label appendString:@"⌃"];
    if(self.modifiers & NSEventModifierFlagOption) [label appendString:@"⌥"];
    if(self.modifiers & NSEventModifierFlagShift) [label appendString:@"⇧"];
    if(self.modifiers & NSEventModifierFlagCommand) [label appendString:@"⌘"];
    NSString *key=[self keyEquivalent];
    NSDictionary *symbols=@{@"\r":@"↩",@"\t":@"⇥",@" ":@"空格",@"\b":@"⌫",[NSString stringWithFormat:@"%C",(unichar)NSDeleteFunctionKey]:@"⌦",[NSString stringWithFormat:@"%C",(unichar)NSLeftArrowFunctionKey]:@"←",[NSString stringWithFormat:@"%C",(unichar)NSRightArrowFunctionKey]:@"→",[NSString stringWithFormat:@"%C",(unichar)NSUpArrowFunctionKey]:@"↑",[NSString stringWithFormat:@"%C",(unichar)NSDownArrowFunctionKey]:@"↓",[NSString stringWithFormat:@"%C",(unichar)NSHomeFunctionKey]:@"↖",[NSString stringWithFormat:@"%C",(unichar)NSEndFunctionKey]:@"↘",[NSString stringWithFormat:@"%C",(unichar)NSPageUpFunctionKey]:@"⇞",[NSString stringWithFormat:@"%C",(unichar)NSPageDownFunctionKey]:@"⇟"};
    if(key.length==1 && [key characterAtIndex:0]>=NSF1FunctionKey && [key characterAtIndex:0]<=NSF20FunctionKey) key=[NSString stringWithFormat:@"F%u",(unsigned)([key characterAtIndex:0]-NSF1FunctionKey+1)];
    else key=symbols[key] ?: key.uppercaseString;
    [label appendString:key.length ? key : [NSString stringWithFormat:@"键 %u",(unsigned)self.keyCode]];return label;
}
@end

static NSDictionary<NSString *,YiShortcut *> *YiDefaultShortcuts(void) {
    return @{YiShortcutAutomatic:[YiShortcut shortcutWithKeyCode:kVK_ANSI_D modifiers:NSEventModifierFlagOption],YiShortcutCapture:[YiShortcut shortcutWithKeyCode:kVK_ANSI_S modifiers:NSEventModifierFlagOption],YiShortcutSelection:[YiShortcut shortcutWithKeyCode:kVK_ANSI_A modifiers:NSEventModifierFlagOption],YiShortcutOpen:[YiShortcut shortcutWithKeyCode:kVK_ANSI_A modifiers:NSEventModifierFlagOption|NSEventModifierFlagCommand]};
}
static BOOL YiValidateShortcuts(NSDictionary *shortcuts,NSError **error) {
    if(![shortcuts isKindOfClass:NSDictionary.class] || shortcuts.count!=YiShortcutActions().count) { if(error) *error=YiShortcutError(@"快捷键配置不完整，请恢复默认后重试。");return NO; }
    NSMutableSet *seen=[NSMutableSet new];
    for(NSString *action in YiShortcutActions()) {
        YiShortcut *shortcut=shortcuts[action];
        if(![shortcut isKindOfClass:YiShortcut.class]) {if(error) *error=YiShortcutError(@"快捷键配置不完整，请恢复默认后重试。");return NO;}
        if(![shortcut validate:error]) return NO;
        if([seen containsObject:shortcut]) {if(error) *error=YiShortcutError(@"不同功能不能使用相同的快捷键。");return NO;}[seen addObject:shortcut];
    }return YES;
}
static NSDictionary<NSString *,YiShortcut *> *YiShortcutsFromPropertyList(id value) {
    if(![value isKindOfClass:NSDictionary.class]) return YiDefaultShortcuts();
    NSMutableDictionary *result=[NSMutableDictionary new];
    for(NSString *action in YiShortcutActions()) { YiShortcut *shortcut=[YiShortcut fromPropertyList:value[action]];
        if(!shortcut && [action isEqual:YiShortcutAutomatic] && [value count]==3 && !value[action]) {
            shortcut=YiDefaultShortcuts()[action];
            // Preserve existing custom bindings if a legacy action already uses Option D.
            if([result.allValues containsObject:shortcut]) {
                for(UInt32 key=kVK_F13;key<=127;key++) {
                    YiShortcut *candidate=[YiShortcut shortcutWithKeyCode:key modifiers:NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCommand];
                    if([candidate validate:NULL] && ![result.allValues containsObject:candidate]) {shortcut=candidate;break;}
                }
            }
        }
        if(!shortcut) return YiDefaultShortcuts();result[action]=shortcut; }
    return YiValidateShortcuts(result,NULL) ? result.copy : YiDefaultShortcuts();
}
static NSDictionary *YiShortcutsPropertyList(NSDictionary<NSString *,YiShortcut *> *shortcuts) {
    NSMutableDictionary *result=[NSMutableDictionary new];for(NSString *action in YiShortcutActions()) if([shortcuts[action] isKindOfClass:YiShortcut.class]) result[action]=shortcuts[action].propertyList;return result.copy;
}

typedef BOOL (^YiShortcutApplyBlock)(NSDictionary<NSString *,YiShortcut *> *shortcuts,NSError **error);
@class YiShortcutPreferencesController;
@interface YiShortcutRecorderButton : NSButton
@property (nonatomic,weak) YiShortcutPreferencesController *recorder;
@property (nonatomic,copy) NSString *actionIdentifier;
@end
@interface YiShortcutPreferencesController : NSWindowController <NSWindowDelegate>
@property (nonatomic,readonly,copy) NSDictionary<NSString *,YiShortcut *> *pendingShortcuts;
@property (nonatomic,readonly,copy) NSString *recordingAction;
@property (nonatomic,copy) void (^recordingChanged)(BOOL recording);
@property (nonatomic,copy) void (^windowClosed)(void);
@property (nonatomic,readonly,copy) NSString *errorMessage;
- (instancetype)initWithShortcuts:(NSDictionary<NSString *,YiShortcut *> *)shortcuts apply:(YiShortcutApplyBlock)apply;
- (void)beginRecordingForAction:(NSString *)action;
- (BOOL)recordKeyEvent:(NSEvent *)event;
- (void)restoreDefaults:(id)sender;
- (void)save:(id)sender;
- (void)cancel:(id)sender;
@end
@interface YiShortcutPreferencesController ()
@property (nonatomic,copy) NSDictionary<NSString *,YiShortcut *> *originalShortcuts;
@property (nonatomic,strong) NSMutableDictionary<NSString *,YiShortcut *> *editingShortcuts;
@property (nonatomic,copy,readwrite) NSString *recordingAction;
@property (nonatomic,copy) YiShortcutApplyBlock applyChanges;
@property (nonatomic,strong) NSMutableDictionary<NSString *,YiShortcutRecorderButton *> *recordingButtons;
@property (nonatomic,strong) NSTextField *errorLabel;
@property (nonatomic,strong) id keyMonitor;
@property (nonatomic) BOOL notifiedClose;
@end
@implementation YiShortcutRecorderButton
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { if(![self.recorder recordKeyEvent:event]) [super keyDown:event]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { return [self.recorder recordKeyEvent:event] || [super performKeyEquivalent:event]; }
@end
@implementation YiShortcutPreferencesController
- (instancetype)initWithShortcuts:(NSDictionary<NSString *,YiShortcut *> *)shortcuts apply:(YiShortcutApplyBlock)apply {
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,480,397) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])) {
        self.originalShortcuts=YiValidateShortcuts(shortcuts,NULL) ? shortcuts.copy : YiDefaultShortcuts(); self.editingShortcuts=self.originalShortcuts.mutableCopy;self.applyChanges=apply;
        window.title=@"快捷键";window.releasedWhenClosed=NO;window.delegate=self;window.titlebarAppearsTransparent=YES;window.backgroundColor=NSColor.windowBackgroundColor;
        NSView *content=window.contentView;
        NSTextField *heading=[NSTextField labelWithString:@"键盘快捷键"];heading.font=[NSFont systemFontOfSize:22 weight:NSFontWeightMedium];heading.frame=NSMakeRect(28,333,424,30);[content addSubview:heading];
        NSTextField *hint=[NSTextField labelWithString:@"点击右侧按键，再按下你想使用的组合。Esc 取消录入。"];hint.font=[NSFont systemFontOfSize:12];hint.textColor=NSColor.secondaryLabelColor;hint.frame=NSMakeRect(28,307,424,20);[content addSubview:hint];
        self.recordingButtons=[NSMutableDictionary new];NSArray *actions=YiShortcutActions();
        for(NSUInteger i=0;i<actions.count;i++) {
            NSString *action=actions[i];CGFloat y=255-i*49;
            NSTextField *label=[NSTextField labelWithString:YiShortcutActionName(action)];label.font=[NSFont systemFontOfSize:14];label.frame=NSMakeRect(32,y+7,200,22);[content addSubview:label];
            YiShortcutRecorderButton *button=[YiShortcutRecorderButton buttonWithTitle:@"" target:self action:@selector(recordClicked:)];button.frame=NSMakeRect(266,y,184,34);button.bezelStyle=NSBezelStyleRounded;button.font=[NSFont systemFontOfSize:14 weight:NSFontWeightMedium];button.recorder=self;button.actionIdentifier=action;button.toolTip=@"点击后按组合键，Esc 取消";button.accessibilityLabel=[YiShortcutActionName(action) stringByAppendingString:@"快捷键"];[content addSubview:button];self.recordingButtons[action]=button;
        }
        self.errorLabel=[NSTextField wrappingLabelWithString:@""];self.errorLabel.font=[NSFont systemFontOfSize:11];self.errorLabel.textColor=NSColor.systemRedColor;self.errorLabel.frame=NSMakeRect(30,57,420,39);[content addSubview:self.errorLabel];
        NSButton *defaults=[NSButton buttonWithTitle:@"恢复默认" target:self action:@selector(restoreDefaults:)];defaults.frame=NSMakeRect(26,18,100,32);[content addSubview:defaults];
        NSButton *cancel=[NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];cancel.frame=NSMakeRect(286,18,76,32);cancel.keyEquivalent=@"\033";[content addSubview:cancel];
        NSButton *save=[NSButton buttonWithTitle:@"保存" target:self action:@selector(save:)];save.frame=NSMakeRect(366,18,86,32);save.keyEquivalent=@"\r";[content addSubview:save];
        [self refreshButtons];[window center];
    }return self;
}
- (NSDictionary *)pendingShortcuts { return self.editingShortcuts.copy; }
- (NSString *)errorMessage { return self.errorLabel.stringValue; }
- (void)refreshButtons { for(NSString *action in self.recordingButtons) self.recordingButtons[action].title=[action isEqual:self.recordingAction] ? @"按下组合键…" : [self.editingShortcuts[action] displayString]; }
- (void)recordClicked:(YiShortcutRecorderButton *)sender { [self beginRecordingForAction:sender.actionIdentifier]; }
- (void)finishRecording {
    if(self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor];self.keyMonitor=nil; }
    BOOL wasRecording=self.recordingAction!=nil;self.recordingAction=nil;[self refreshButtons];
    if(wasRecording && self.recordingChanged) self.recordingChanged(NO);
}
- (void)beginRecordingForAction:(NSString *)action {
    if(!self.recordingButtons[action]) return;[self finishRecording];self.errorLabel.stringValue=@"";self.recordingAction=action;[self refreshButtons];
    [self.window makeFirstResponder:self.recordingButtons[action]];
    __weak typeof(self) weakSelf=self;
    self.keyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        YiShortcutPreferencesController *controller=weakSelf;
        if(controller.recordingAction && (event.window==controller.window || NSApp.keyWindow==controller.window) && [controller recordKeyEvent:event]) return nil;return event;
    }];
    if(self.recordingChanged) self.recordingChanged(YES);
}
- (BOOL)recordKeyEvent:(NSEvent *)event {
    if(!self.recordingAction || event.type!=NSEventTypeKeyDown) return NO;
    if(event.isARepeat) return YES;
    if(event.keyCode==kVK_Escape) {self.errorLabel.stringValue=@"";[self finishRecording];return YES;}
    YiShortcut *shortcut=[YiShortcut shortcutWithKeyCode:event.keyCode modifiers:event.modifierFlags];NSError *error=nil;
    if(![shortcut validate:&error]) {self.errorLabel.stringValue=error.localizedDescription;return YES;}
    for(NSString *action in self.editingShortcuts) if(![action isEqual:self.recordingAction] && [self.editingShortcuts[action] isEqual:shortcut]) {self.errorLabel.stringValue=@"此组合已用于其他功能，请换一组。";return YES;}
    self.editingShortcuts[self.recordingAction]=shortcut;self.errorLabel.stringValue=@"";[self finishRecording];return YES;
}
- (void)restoreDefaults:(id)sender { [self finishRecording];self.editingShortcuts=YiDefaultShortcuts().mutableCopy;self.errorLabel.stringValue=@"";[self refreshButtons]; }
- (void)save:(id)sender {
    if(self.recordingAction) {self.errorLabel.stringValue=@"请先按下组合键，或按 Esc 取消录入。";return;}
    NSError *error=nil;NSDictionary *candidate=self.pendingShortcuts;
    if(!YiValidateShortcuts(candidate,&error) || !self.applyChanges || !self.applyChanges(candidate,&error)) {self.errorLabel.stringValue=error.localizedDescription ?: @"无法保存快捷键，请重试。";return;}
    self.originalShortcuts=candidate;[self close];
}
- (void)cancel:(id)sender { [self finishRecording];self.editingShortcuts=self.originalShortcuts.mutableCopy;[self refreshButtons];[self close]; }
- (void)windowDidResignKey:(NSNotification *)notification { [self finishRecording]; }
- (void)windowWillClose:(NSNotification *)notification { [self finishRecording];self.editingShortcuts=self.originalShortcuts.mutableCopy;[self refreshButtons];if(!self.notifiedClose) {self.notifiedClose=YES;if(self.windowClosed) self.windowClosed();} }
- (void)showWindow:(id)sender {self.notifiedClose=NO;[super showWindow:sender];}
- (void)dealloc {if(_keyMonitor) [NSEvent removeMonitor:_keyMonitor];}
@end
#endif
