#import "../Sources/ShortcutPreferences.h"
static void Check(BOOL ok,const char *message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
static NSEvent *Key(UInt16 code,NSEventModifierFlags flags) {return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];}
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSDictionary<NSString *,YiShortcut *> *defaults=YiDefaultShortcuts();Check(YiValidateShortcuts(defaults,NULL),"defaults must be complete, valid and distinct");
    Check([defaults[YiShortcutCapture] carbonModifiers]==optionKey && [defaults[YiShortcutCapture] keyCode]==kVK_ANSI_S,"capture default must remain Option S");
    Check([defaults[YiShortcutAutomatic] carbonModifiers]==optionKey && [defaults[YiShortcutAutomatic] keyCode]==kVK_ANSI_D,"automatic selection default must be Option D");
    NSMutableDictionary *legacy=[YiShortcutsPropertyList(defaults) mutableCopy];[legacy removeObjectForKey:YiShortcutAutomatic];
    legacy[YiShortcutCapture]=@{@"keyCode":@(kVK_ANSI_T),@"modifiers":@(NSEventModifierFlagOption)};
    NSDictionary<NSString *,YiShortcut *> *migrated=YiShortcutsFromPropertyList(legacy);
    Check([migrated[YiShortcutCapture] keyCode]==kVK_ANSI_T && [migrated[YiShortcutAutomatic] keyCode]==kVK_ANSI_D,"legacy three-action preferences must preserve custom keys and add Option D");
    legacy[YiShortcutCapture]=@{@"keyCode":@(kVK_ANSI_D),@"modifiers":@(NSEventModifierFlagOption)};
    migrated=YiShortcutsFromPropertyList(legacy);
    Check(YiValidateShortcuts(migrated,NULL) && [migrated[YiShortcutCapture] keyCode]==kVK_ANSI_D,"migration must preserve a legacy Option D binding without introducing duplicates");
    Check([defaults[YiShortcutOpen] carbonModifiers]==(optionKey|cmdKey),"open default must include Option and Command");
    Check([YiShortcutsFromPropertyList(YiShortcutsPropertyList(defaults)) isEqual:defaults],"property list must round-trip losslessly");
    Check([YiShortcutsFromPropertyList(@{YiShortcutCapture:@{@"keyCode":@999,@"modifiers":@0}}) isEqual:defaults],"malformed stored settings must recover the complete defaults");
    Check(![YiShortcut fromPropertyList:@{@"keyCode":@0.5,@"modifiers":@(NSEventModifierFlagOption)}],"fractional key codes must not silently truncate");
    Check(![[YiShortcut shortcutWithKeyCode:kVK_ANSI_D modifiers:NSEventModifierFlagShift] validate:NULL],"shift alone cannot become a global typing shortcut");
    for(NSNumber *code in @[@(kVK_ANSI_Q),@(kVK_ANSI_H),@(kVK_ANSI_W)]) Check(![[YiShortcut shortcutWithKeyCode:code.unsignedIntValue modifiers:NSEventModifierFlagCommand] validate:NULL],"common quit/hide/close commands must be protected");
    Check(![[YiShortcut shortcutWithKeyCode:kVK_ANSI_C modifiers:NSEventModifierFlagCommand|NSEventModifierFlagShift] validate:NULL],"Command Shift editing shortcuts must not be hijacked");
    Check([[YiShortcut shortcutWithKeyCode:kVK_ANSI_C modifiers:NSEventModifierFlagCommand|NSEventModifierFlagOption] validate:NULL],"Option Command combinations remain customizable");
    Check([[[YiShortcut shortcutWithKeyCode:kVK_F8 modifiers:NSEventModifierFlagControl] displayString] containsString:@"F8"],"function key display must use its familiar label");
    NSMutableDictionary *duplicate=defaults.mutableCopy;duplicate[YiShortcutSelection]=defaults[YiShortcutCapture];Check(!YiValidateShortcuts(duplicate,NULL),"duplicate actions must fail validation");
    __block NSUInteger applies=0,closed=0;__block NSDictionary<NSString *,YiShortcut *> *applied=nil;
    YiShortcutPreferencesController *controller=[[YiShortcutPreferencesController alloc] initWithShortcuts:defaults apply:^BOOL(NSDictionary *candidate,NSError **error){applies++;applied=candidate;return YES;}];controller.windowClosed=^{closed++;};
    [controller beginRecordingForAction:YiShortcutCapture];[controller recordKeyEvent:Key(kVK_ANSI_D,0)];Check(controller.recordingAction && controller.errorMessage.length,"unmodified input must show an error and keep recording");
    [controller save:nil];Check(!applies && controller.recordingAction,"Save during unfinished recording must not apply stale settings");
    [controller recordKeyEvent:Key(kVK_Escape,0)];Check(!controller.recordingAction && [controller.pendingShortcuts isEqual:defaults],"Escape must cancel recording without changing a shortcut");
    [controller beginRecordingForAction:YiShortcutCapture];[controller recordKeyEvent:Key(kVK_ANSI_A,NSEventModifierFlagOption)];Check(controller.errorMessage.length && controller.recordingAction,"duplicate recording must not overwrite another action");
    [controller recordKeyEvent:Key(kVK_ANSI_D,NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCapsLock)];
    Check(!controller.recordingAction && [controller.pendingShortcuts[YiShortcutCapture] keyCode]==kVK_ANSI_D,"valid recording updates the pending action");
    Check([controller.pendingShortcuts[YiShortcutCapture] modifiers]==(NSEventModifierFlagControl|NSEventModifierFlagOption),"Caps Lock state must not become part of the shortcut");Check(!applies,"recording must not persist or register pending settings");
    [controller restoreDefaults:nil];Check([controller.pendingShortcuts isEqual:defaults] && !applies,"restore defaults edits pending values only");
    [controller beginRecordingForAction:YiShortcutCapture];[controller recordKeyEvent:Key(kVK_ANSI_D,NSEventModifierFlagControl)];[controller cancel:nil];Check(!applies && [controller.pendingShortcuts isEqual:defaults],"Cancel must discard edits and never apply");
    Check(closed==1,"Cancel must notify the parent to restore global shortcuts once");
    [controller windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:controller.window]];Check(closed==1,"repeated close notifications must not restore shortcuts twice");
    [controller beginRecordingForAction:YiShortcutCapture];[controller recordKeyEvent:Key(kVK_ANSI_D,NSEventModifierFlagControl)];[controller save:nil];Check(applies==1 && [applied[YiShortcutCapture] keyCode]==kVK_ANSI_D,"Save applies the full pending configuration exactly once");
    YiShortcutPreferencesController *failed=[[YiShortcutPreferencesController alloc] initWithShortcuts:defaults apply:^BOOL(NSDictionary *candidate,NSError **error){if(error)*error=YiShortcutError(@"此快捷键已被其他应用占用。");return NO;}];
    [failed beginRecordingForAction:YiShortcutCapture];[failed recordKeyEvent:Key(kVK_ANSI_T,NSEventModifierFlagOption)];[failed save:nil];Check([failed.errorMessage containsString:@"占用"] && [failed.pendingShortcuts[YiShortcutCapture] keyCode]==kVK_ANSI_T,"registration failure must stay inline and retain editable pending choices");[failed cancel:nil];
    YiShortcutPreferencesController *redClose=[[YiShortcutPreferencesController alloc] initWithShortcuts:defaults apply:^BOOL(NSDictionary *candidate,NSError **error){applies++;return YES;}];
    [redClose beginRecordingForAction:YiShortcutCapture];[redClose recordKeyEvent:Key(kVK_ANSI_D,NSEventModifierFlagOption)];
    [redClose windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:redClose.window]];
    Check([redClose.pendingShortcuts isEqual:defaults] && applies==1,"red close must discard pending values without applying");
    puts("PASS: shortcut validation, persistence, Carbon modifiers, recording, Escape, duplicate prevention and pending Save/Cancel/default semantics.");
}return 0;}
