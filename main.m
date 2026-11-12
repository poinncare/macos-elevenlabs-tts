#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Vision/Vision.h>

static NSString *const DefaultVoice = @"JBFqnCBsd6RMkjVDRZzb";
static NSString *const VoicePreference = @"voiceID";
static const EventHotKeyID SelectionHotKeyID = {0x54545321, 1};

static id AccessibilityValue(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *SelectedText(pid_t pid, BOOL *secureField) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.25f);
    id focused = AccessibilityValue(app, kAXFocusedUIElementAttribute);
    CFRelease(app);
    if (!focused || CFGetTypeID((__bridge CFTypeRef)focused) != AXUIElementGetTypeID()) return nil;
    AXUIElementRef element = (__bridge AXUIElementRef)focused;
    AXUIElementSetMessagingTimeout(element, 0.25f);
    *secureField = [AccessibilityValue(element, kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXSecureTextFieldSubrole];
    if (*secureField) return nil;
    id text = AccessibilityValue(element, kAXSelectedTextAttribute);
    return [text isKindOfClass:NSString.class] ? text : nil;
}

static NSArray<NSPasteboardItem *> *SnapshotPasteboard(NSPasteboard *board) {
    NSMutableArray *snapshot = [NSMutableArray array];
    for (NSPasteboardItem *item in board.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (!data || ![copy setData:data forType:type]) return nil;
        }
        [snapshot addObject:copy];
    }
    return snapshot;
}

static NSString *PasteboardText(NSPasteboard *board) {
    NSString *text = [board stringForType:NSPasteboardTypeString];
    if (text.length) return text;
    NSData *rtf = [board dataForType:NSPasteboardTypeRTF];
    return rtf ? [[[NSAttributedString alloc] initWithRTF:rtf documentAttributes:NULL] string] : nil;
}

static BOOL PostCopy(pid_t pid) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_C, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_C, false);
    if (down && up) {
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
    }
    BOOL posted = down && up;
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    return posted;
}

static NSString *ReadKey(void) {
    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    task.arguments = @[@"find-generic-password", @"-s", @"just-aloud-api-key", @"-w"];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;
    NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *RequestError(NSURLResponse *response, NSError *error) {
    if (error) return error.localizedDescription;
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return @"Пустой ответ ElevenLabs.";
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status >= 200 && status < 300) return nil;
    if (status == 401) return @"ElevenLabs отклонил запрос. Проверь ключ и его права.";
    if (status == 403) return @"У ключа нет доступа к этому голосу или операции.";
    if (status == 429) return @"ElevenLabs ограничил запросы. Проверь остаток кредитов и попробуй позже.";
    return [NSString stringWithFormat:@"ElevenLabs вернул ошибку HTTP %ld.", (long)status];
}

@interface TTSApp : NSObject <NSApplicationDelegate, NSMenuDelegate, AVAudioPlayerDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSStatusItem *status;
@property (nonatomic, strong) NSWindow *voiceWindow;
@property (nonatomic, strong) NSComboBox *voicePicker;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSTextField *shortcutHint;
@property (nonatomic, strong) NSButton *permissionButton;
@property (nonatomic, copy) NSArray<NSDictionary *> *voices;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *speech;
@property (nonatomic, strong) AVAudioPlayer *player;
@property BOOL loadingVoices;
@property BOOL readingSelection;
@property NSUInteger generation;
@property EventHotKeyRef selectionHotKey;
@property EventHandlerRef hotKeyHandler;
- (void)readFrontmostSelection;
@end

static OSStatus HandleSelectionHotKey(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID hotKey;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hotKey), NULL, &hotKey) != noErr ||
        hotKey.signature != SelectionHotKeyID.signature || hotKey.id != SelectionHotKeyID.id) {
        return eventNotHandledErr;
    }
    TTSApp *app = (__bridge TTSApp *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [app readFrontmostSelection]; });
    return noErr;
}

@implementation TTSApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 25;
    config.timeoutIntervalForResource = 75;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.voices = @[@{@"voice_id": DefaultVoice, @"name": @"George"}];

    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    [self menuNeedsUpdate:menu];
    self.status.menu = menu;
    [self updateStatus];

    NSApp.servicesProvider = self;
    NSUpdateDynamicServices();
    EventTypeSpec hotKeyEvent = {kEventClassKeyboard, kEventHotKeyReleased};
    EventHandlerRef handler = NULL;
    if (InstallEventHandler(GetApplicationEventTarget(), HandleSelectionHotKey, 1, &hotKeyEvent,
                            (__bridge void *)self, &handler) == noErr) {
        self.hotKeyHandler = handler;
        EventHotKeyRef hotKey = NULL;
        OSStatus result = RegisterEventHotKey(kVK_ANSI_V, controlKey, SelectionHotKeyID,
                                              GetApplicationEventTarget(), kEventHotKeyExclusive, &hotKey);
        if (result == noErr) self.selectionHotKey = hotKey;
        else NSLog(@"TTS: Control+V could not be registered (%d)", (int)result);
    }
    [self loadVoicesShowingErrors:NO];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.selectionHotKey) UnregisterEventHotKey(self.selectionHotKey);
    if (self.hotKeyHandler) RemoveEventHandler(self.hotKeyHandler);
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self updateShortcutHint];
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--background"]) return YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showVoiceWindow:nil]; });
    return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showVoiceWindow:nil];
    return NO;
}

- (void)showVoiceWindow:(id)sender {
    if (!self.voiceWindow) {
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
        self.voiceWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 490, 165)
                                                      styleMask:style backing:NSBackingStoreBuffered defer:NO];
        self.voiceWindow.title = @"TTS — выбор голоса";
        self.voiceWindow.releasedWhenClosed = NO;
        [self.voiceWindow center];

        self.voicePicker = [[NSComboBox alloc] initWithFrame:NSZeroRect];
        self.voicePicker.editable = NO;
        self.voicePicker.numberOfVisibleItems = 12;
        self.voicePicker.target = self;
        self.voicePicker.action = @selector(selectVoiceFromPicker:);
        self.voicePicker.accessibilityLabel = @"Голос ElevenLabs";
        [self.voicePicker setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *label = [NSTextField labelWithString:@"Голос"];
        NSStackView *voiceRow = [NSStackView stackViewWithViews:@[label, self.voicePicker]];
        voiceRow.alignment = NSLayoutAttributeFirstBaseline;
        [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        self.refreshButton = [NSButton buttonWithTitle:@"Обновить список" target:self action:@selector(refreshVoices:)];
        NSButton *clipboard = [NSButton buttonWithTitle:@"Озвучить из буфера" target:self action:@selector(speakClipboard:)];
        self.stopButton = [NSButton buttonWithTitle:@"Остановить" target:self action:@selector(stop:)];
        NSStackView *buttons = [NSStackView stackViewWithViews:@[self.refreshButton, clipboard, self.stopButton]];

        self.shortcutHint = [NSTextField labelWithString:@""];
        self.shortcutHint.textColor = NSColor.secondaryLabelColor;
        self.permissionButton = [NSButton buttonWithTitle:@"Разрешить чтение выделенного текста…"
                                                  target:self action:@selector(requestAccessibility:)];
        NSStackView *content = [NSStackView stackViewWithViews:@[voiceRow, buttons, self.shortcutHint, self.permissionButton]];
        content.orientation = NSUserInterfaceLayoutOrientationVertical;
        content.alignment = NSLayoutAttributeLeading;
        content.spacing = 12;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *view = self.voiceWindow.contentView;
        [view addSubview:content];
        [NSLayoutConstraint activateConstraints:@[
            [content.topAnchor constraintEqualToAnchor:view.topAnchor constant:18],
            [content.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
            [content.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
            [voiceRow.widthAnchor constraintEqualToAnchor:content.widthAnchor]
        ]];
    }
    [self updateVoicePicker];
    [self updateStatus];
    [self updateShortcutHint];
    [NSApp activate];
    [self.voiceWindow makeKeyAndOrderFront:nil];
}

- (void)updateShortcutHint {
    self.shortcutHint.stringValue = self.selectionHotKey
        ? @"Выдели текст в любом приложении и нажми Control + V."
        : @"Control + V недоступно. Проверь, не занято ли сочетание.";
    self.permissionButton.hidden = AXIsProcessTrusted();
}

- (void)requestAccessibility:(id)sender {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        NSURL *settings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [NSWorkspace.sharedWorkspace openURL:settings];
    }
    [self updateShortcutHint];
}

- (void)updateVoicePicker {
    if (!self.voicePicker) return;
    [self.voicePicker removeAllItems];
    NSString *selected = self.selectedVoice;
    NSCountedSet *names = [NSCountedSet setWithArray:[self.voices valueForKey:@"name"]];
    for (NSUInteger index = 0; index < self.voices.count; index++) {
        NSDictionary *voice = self.voices[index];
        NSString *name = voice[@"name"];
        if ([names countForObject:name] > 1) {
            name = [NSString stringWithFormat:@"%@ (%@)", name, voice[@"voice_id"]];
        }
        [self.voicePicker addItemWithObjectValue:name];
        if ([voice[@"voice_id"] isEqual:selected]) [self.voicePicker selectItemAtIndex:(NSInteger)index];
    }
    self.voicePicker.enabled = !self.loadingVoices && self.voices.count > 0;
    self.refreshButton.enabled = !self.loadingVoices;
    self.refreshButton.title = self.loadingVoices ? @"Загружаю голоса…" : @"Обновить список";
}

- (void)selectVoiceFromPicker:(NSComboBox *)picker {
    NSInteger index = picker.indexOfSelectedItem;
    if (index < 0 || (NSUInteger)index >= self.voices.count) return;
    NSMenuItem *choice = [NSMenuItem new];
    choice.representedObject = self.voices[(NSUInteger)index][@"voice_id"];
    [self selectVoice:choice];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                       newRequest:(NSURLRequest *)request
                completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}

- (NSMutableURLRequest *)requestForPath:(NSString *)path query:(NSArray<NSURLQueryItem *> *)query {
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = @"https";
    url.host = @"api.elevenlabs.io";
    url.path = path;
    url.queryItems = query;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL];
    [request setValue:self.key forHTTPHeaderField:@"xi-api-key"];
    return request;
}

- (NSString *)selectedVoice {
    return [NSUserDefaults.standardUserDefaults stringForKey:VoicePreference] ?: DefaultVoice;
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = enabled;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [menu addItem:[self item:@"Открыть окно TTS…" action:@selector(showVoiceWindow:) enabled:YES]];
    if (!AXIsProcessTrusted()) {
        [menu addItem:[self item:@"Разрешить чтение выделенного текста…" action:@selector(requestAccessibility:) enabled:YES]];
    }
    [menu addItem:[self item:@"Озвучить из буфера" action:@selector(speakClipboard:) enabled:YES]];
    [menu addItem:[self item:@"Остановить" action:@selector(stop:) enabled:self.speech || self.player]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *voiceItem = [self item:@"Голос" action:NULL enabled:YES];
    NSMenu *voiceMenu = [NSMenu new];
    for (NSDictionary *voice in self.voices) {
        NSMenuItem *choice = [self item:voice[@"name"] action:@selector(selectVoice:) enabled:YES];
        choice.representedObject = voice[@"voice_id"];
        choice.state = [choice.representedObject isEqual:self.selectedVoice] ? NSControlStateValueOn : NSControlStateValueOff;
        [voiceMenu addItem:choice];
    }
    voiceItem.submenu = voiceMenu;
    [menu addItem:voiceItem];
    NSString *refresh = self.loadingVoices ? @"Загружаю голоса…" : @"Обновить список голосов";
    [menu addItem:[self item:refresh action:@selector(refreshVoices:) enabled:!self.loadingVoices]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Выйти из TTS" action:@selector(quit:) enabled:YES]];
}

- (void)selectVoice:(NSMenuItem *)choice {
    if (!choice.representedObject) return;
    [NSUserDefaults.standardUserDefaults setObject:choice.representedObject forKey:VoicePreference];
    for (NSUInteger index = 0; index < self.voices.count; index++) {
        if ([self.voices[index][@"voice_id"] isEqual:choice.representedObject]) {
            [self.voicePicker selectItemAtIndex:(NSInteger)index];
            break;
        }
    }
    [self speak:@"Привет! Я проверяю этот голос." emptyMessage:@""];
}

- (void)refreshVoices:(id)sender {
    [self loadVoicesShowingErrors:YES];
}

- (void)loadVoicesShowingErrors:(BOOL)showErrors {
    if (self.loadingVoices) return;
    self.loadingVoices = YES;
    [self updateVoicePicker];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *key = ReadKey();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!key.length) {
                self.loadingVoices = NO;
                [self updateVoicePicker];
                if (showErrors) [self showError:@"Не удалось прочитать ключ ElevenLabs из Связки ключей."];
                return;
            }
            self.key = key;
            [self loadVoicePage:nil collected:[NSMutableArray array] remaining:5 showErrors:showErrors];
        });
    });
}

- (void)loadVoicePage:(NSString *)token collected:(NSMutableArray<NSDictionary *> *)voices
            remaining:(NSUInteger)remaining showErrors:(BOOL)showErrors {
    NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"page_size" value:@"100"]];
    if (token) [query addObject:[NSURLQueryItem queryItemWithName:@"next_page_token" value:token]];
    NSURLRequest *request = [self requestForPath:@"/v2/voices" query:query];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *problem = RequestError(response, error);
        id page = data && !problem ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *entries = [page isKindOfClass:NSDictionary.class] ? page[@"voices"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![entries isKindOfClass:NSArray.class]) {
                self.loadingVoices = NO;
                [self updateVoicePicker];
                if (showErrors) [self showError:problem ?: @"Не удалось загрузить голоса ElevenLabs."];
                return;
            }
            for (id entry in entries) {
                if ([entry isKindOfClass:NSDictionary.class] &&
                    [entry[@"name"] isKindOfClass:NSString.class] &&
                    [entry[@"voice_id"] isKindOfClass:NSString.class]) {
                    [voices addObject:entry];
                }
            }
            id next = page[@"next_page_token"];
            if (remaining > 1 && [next isKindOfClass:NSString.class] && [next length]) {
                [self loadVoicePage:next collected:voices remaining:remaining - 1 showErrors:showErrors];
                return;
            }
            self.loadingVoices = NO;
            if (voices.count) {
                self.voices = [voices sortedArrayUsingDescriptors:@[
                    [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedStandardCompare:)]
                ]];
                if (![[self.voices valueForKey:@"voice_id"] containsObject:self.selectedVoice]) {
                    [NSUserDefaults.standardUserDefaults setObject:self.voices.firstObject[@"voice_id"] forKey:VoicePreference];
                }
            }
            [self updateVoicePicker];
        });
    }] resume];
}

- (void)speakSelection:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    [self speak:PasteboardText(pasteboard) emptyMessage:@"Сначала выдели текст."];
}

- (void)readFrontmostSelection {
    if (self.readingSelection) return;
    if (!AXIsProcessTrusted()) {
        [self requestAccessibility:nil];
        return;
    }
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front) return;
    pid_t pid = front.processIdentifier;
    self.readingSelection = YES;
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL secureField = NO;
        NSString *text = [SelectedText(pid, &secureField)
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || secureField ||
                NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != pid) {
                self.readingSelection = NO;
            } else if (text.length) {
                self.readingSelection = NO;
                [self speak:text emptyMessage:@""];
            } else {
                [self copySelectionFrom:pid generation:generation];
            }
        });
    });
}

- (void)copySelectionFrom:(pid_t)pid generation:(NSUInteger)generation {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSInteger originalCount = board.changeCount;
    NSArray<NSPasteboardItem *> *snapshot = SnapshotPasteboard(board);
    if (!snapshot || board.changeCount != originalCount) {
        self.readingSelection = NO;
        [self showError:@"Буфер обмена занят. Скопируй текст вручную и нажми «Озвучить из буфера» в TTS."];
        return;
    }
    if (!PostCopy(pid)) {
        self.readingSelection = NO;
        [self showError:@"Не удалось скопировать выделение. Скопируй текст вручную и нажми «Озвучить из буфера» в TTS."];
        return;
    }
    [self waitForCopyFrom:pid originalCount:originalCount lastCount:originalCount
                 snapshot:snapshot remaining:20 generation:generation];
}

- (void)waitForCopyFrom:(pid_t)pid originalCount:(NSInteger)originalCount lastCount:(NSInteger)lastCount
               snapshot:(NSArray<NSPasteboardItem *> *)snapshot remaining:(NSUInteger)remaining
             generation:(NSUInteger)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSPasteboard *board = NSPasteboard.generalPasteboard;
        NSInteger current = board.changeCount;
        BOOL sameApp = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == pid;
        if (sameApp && current != originalCount && (current == lastCount || remaining == 0)) {
            NSString *text = [PasteboardText(board) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (board.changeCount == current) {
                [board clearContents];
                if (snapshot.count) [board writeObjects:snapshot];
                self.readingSelection = NO;
                if (generation == self.generation) {
                    [self speak:text emptyMessage:@"Не удалось получить текст. Выдели его или скопируй нужную область экрана."];
                }
                return;
            }
        }
        if (sameApp && remaining > 0) {
            [self waitForCopyFrom:pid originalCount:originalCount lastCount:current
                         snapshot:snapshot remaining:remaining - 1 generation:generation];
            return;
        }
        self.readingSelection = NO;
        if (sameApp && generation == self.generation) {
            [self showError:@"Приложение не скопировало текст. Выдели его или скопируй область экрана (Control + Shift + Command + 4), затем нажми «Озвучить из буфера» в TTS."];
        }
    });
}

- (void)speakClipboard:(id)sender {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSString *text = [PasteboardText(board) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length) {
        [self speak:text emptyMessage:@""];
        return;
    }
    NSData *image = [board dataForType:NSPasteboardTypePNG] ?: [board dataForType:NSPasteboardTypeTIFF]
        ?: [board dataForType:@"public.jpeg"];
    if (!image.length) {
        [self showError:@"Сначала скопируй текст или область экрана (Control + Shift + Command + 4)."];
        return;
    }
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.automaticallyDetectsLanguage = YES;
        NSArray *supported = [request supportedRecognitionLanguagesAndReturnError:NULL];
        if ([supported containsObject:@"ru-RU"] && [supported containsObject:@"en-US"]) {
            request.recognitionLanguages = @[@"ru-RU", @"en-US"];
        }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithData:image options:@{}];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        if ([handler performRequests:@[request] error:NULL]) {
            for (VNRecognizedTextObservation *observation in request.results) {
                NSString *line = [observation topCandidates:1].firstObject.string;
                if (line.length) [lines addObject:line];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self.generation) {
                [self speak:[lines componentsJoinedByString:@"\n"] emptyMessage:@"На изображении не удалось распознать текст."];
            }
        });
    });
}

- (void)speak:(NSString *)input emptyMessage:(NSString *)emptyMessage {
    NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { [self showError:emptyMessage]; return; }
    if (text.length > 10000) { [self showError:@"Выдели фрагмент до 10 000 символов."]; return; }
    if (!self.key.length) {
        [self showError:self.loadingVoices ? @"Подожди, пока загрузятся голоса." : @"Ключ недоступен. Открой TTS.app и нажми «Обновить список»."];
        return;
    }

    NSString *voice = self.selectedVoice;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    if (!voice.length || [voice rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        [self showError:@"Открой TTS.app и выбери голос."];
        return;
    }
    [self stop:nil];
    NSUInteger generation = self.generation;
    NSMutableURLRequest *request = [self requestForPath:[@"/v1/text-to-speech/" stringByAppendingString:voice] query:nil];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"text": text, @"model_id": @"eleven_multilingual_v2"
    } options:0 error:NULL];

    self.speech = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *problem = RequestError(response, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.speech = nil;
            if (problem) {
                [self updateStatus];
                [self showError:problem];
                return;
            }
            if ([response.MIMEType hasPrefix:@"audio/"] && data.length) {
                self.player = [[AVAudioPlayer alloc] initWithData:data error:NULL];
                self.player.delegate = self;
            }
            if (![self.player play]) {
                self.player = nil;
                [self showError:@"Не удалось воспроизвести аудио."];
            }
            [self updateStatus];
        });
    }];
    [self.speech resume];
    [self updateStatus];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.player) return;
    self.player = nil;
    [self updateStatus];
}

- (void)stop:(id)sender {
    self.generation += 1;
    [self.speech cancel];
    self.speech = nil;
    [self.player stop];
    self.player = nil;
    [self updateStatus];
}

- (void)updateStatus {
    self.status.button.title = self.speech ? @"TTS…" : self.player ? @"▶ TTS" : @"TTS";
    self.status.button.toolTip = @"Озвучивание через ElevenLabs";
    self.stopButton.enabled = self.speech || self.player;
}

- (void)showError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"TTS";
        alert.informativeText = message;
        [NSApp activate];
        [alert runModal];
    });
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        TTSApp *delegate = [TTSApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
