#import <AVFAudio/AVFAudio.h>
#import <Cocoa/Cocoa.h>
#import <NaturalLanguage/NaturalLanguage.h>

static void UpdateSpeechButton(NSButton *button, NSString *label, BOOL playing) {
    NSString *description = playing ? @"停止朗读" : label;
    NSString *symbol = playing ? @"stop.fill" : @"speaker.wave.2";
    button.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:description]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
    button.toolTip = description;
    [button setAccessibilityLabel:description];
}

static AVSpeechSynthesisVoice *SpeechVoice(NSString *text, NSString *language) {
    if (!language.length) language = [NLLanguageRecognizer dominantLanguageForString:text];
    if (!language.length || [language isEqualToString:NLLanguageUndetermined])
        language = AVSpeechSynthesisVoice.currentLanguageCode;
    if ([language isEqualToString:NLLanguageSimplifiedChinese]) language = @"zh-CN";
    if ([language isEqualToString:NLLanguageTraditionalChinese]) language = @"zh-TW";
    if ([language isEqualToString:@"en"]) language = @"en-US";

    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
    if (voice) return voice;
    // An installed regional voice can also read text detected as the base language.
    if ([language containsString:@"-"]) return nil;
    for (AVSpeechSynthesisVoice *candidate in AVSpeechSynthesisVoice.speechVoices) {
        if ([[candidate.language componentsSeparatedByString:@"-"].firstObject isEqualToString:language])
            return candidate;
    }
    return nil;
}

@interface SpeechPlayback : NSObject <AVSpeechSynthesizerDelegate>
@property AVSpeechSynthesizer *synthesizer;
@property AVSpeechUtterance *utterance;
@property (weak) NSButton *activeButton;
@property NSString *activeLabel;
- (BOOL)toggleText:(NSString *)text language:(NSString *)language button:(NSButton *)button label:(NSString *)label;
- (void)stopForButton:(NSButton *)button;
- (void)stop;
@end

@implementation SpeechPlayback
- (BOOL)toggleText:(NSString *)text language:(NSString *)language button:(NSButton *)button label:(NSString *)label {
    if (self.activeButton == button && self.utterance) {
        [self stop];
        return YES;
    }
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return NO;
    AVSpeechSynthesisVoice *voice = SpeechVoice(text, language);
    if (!voice) return NO;

    [self stop];
    if (!self.synthesizer) {
        self.synthesizer = [AVSpeechSynthesizer new];
        self.synthesizer.delegate = self;
    }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.voice = voice;
    self.utterance = utterance;
    self.activeButton = button;
    self.activeLabel = label;
    UpdateSpeechButton(button, label, YES);
    [self.synthesizer speakUtterance:utterance];
    return YES;
}

- (void)clearPlayback {
    UpdateSpeechButton(self.activeButton, self.activeLabel, NO);
    self.activeButton = nil;
    self.activeLabel = nil;
    self.utterance = nil;
}

- (void)stopForButton:(NSButton *)button {
    if (button && self.activeButton == button) [self stop];
}

- (void)stop {
    if (!self.utterance) return;
    [self clearPlayback];
    [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

- (void)finishedUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.utterance == utterance) [self clearPlayback];
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    [self finishedUtterance:utterance];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    [self finishedUtterance:utterance];
}
@end
