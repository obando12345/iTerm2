#import "PTYSession.h"

#import "Coprocess.h"
#import "FakeWindow.h"
#import "FileTransferManager.h"
#import "ITAddressBookMgr.h"
#import "MovePaneController.h"
#import "MovePaneController.h"
#import "NSStringITerm.h"
#import "NSView+RecursiveDescription.h"
#import "PTYScrollView.h"
#import "PTYTab.h"
#import "PTYTask.h"
#import "PTYTextView.h"
#import "PasteContext.h"
#import "PasteEvent.h"
#import "PasteViewController.h"
#import "PreferencePanel.h"
#import "ProcessCache.h"
#import "SCPFile.h"
#import "SCPPath.h"
#import "SearchResult.h"
#import "SessionView.h"
#import "TmuxController.h"
#import "TmuxControllerRegistry.h"
#import "TmuxGateway.h"
#import "TmuxLayoutParser.h"
#import "TmuxStateParser.h"
#import "TmuxWindowOpener.h"
#import "Trigger.h"
#import "VT100Screen.h"
#import "VT100ScreenMark.h"
#import "VT100Terminal.h"
#import "WindowControllerInterface.h"
#import "iTerm.h"
#import "iTermApplicationDelegate.h"
#import "iTermController.h"
#import "iTermGrowlDelegate.h"
#import "iTermKeyBindingMgr.h"

#include <stdlib.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

// The format for a user defaults key that recalls if the user has already been pestered about
// outdated key mappings for a give profile. The %@ is replaced with the profile's GUID.
static NSString *const kAskAboutOutdatedKeyMappingKeyFormat = @"AskAboutOutdatedKeyMappingForGuid%@";

NSString *const kPTYSessionTmuxFontDidChange = @"kPTYSessionTmuxFontDidChange";

static NSString *TERM_ENVNAME = @"TERM";
static NSString *COLORFGBG_ENVNAME = @"COLORFGBG";
static NSString *PWD_ENVNAME = @"PWD";
static NSString *PWD_ENVVALUE = @"~";

// Constants for saved window arrangement keys.
static NSString* SESSION_ARRANGEMENT_COLUMNS = @"Columns";
static NSString* SESSION_ARRANGEMENT_ROWS = @"Rows";
static NSString* SESSION_ARRANGEMENT_BOOKMARK = @"Bookmark";
static NSString* SESSION_ARRANGEMENT_BOOKMARK_NAME = @"Bookmark Name";
static NSString* SESSION_ARRANGEMENT_WORKING_DIRECTORY = @"Working Directory";
static NSString* SESSION_ARRANGEMENT_TMUX_PANE = @"Tmux Pane";
static NSString* SESSION_ARRANGEMENT_TMUX_HISTORY = @"Tmux History";
static NSString* SESSION_ARRANGEMENT_TMUX_ALT_HISTORY = @"Tmux AltHistory";
static NSString* SESSION_ARRANGEMENT_TMUX_STATE = @"Tmux State";

static NSString *kTmuxFontChanged = @"kTmuxFontChanged";

@interface PTYSession ()
@property(nonatomic, retain) Interval *currentMarkOrNotePosition;
@end

@implementation PTYSession
{
    // Owning tab.
    PTYTab* tab_;
    
    // tty device
    NSString* tty;
    
    // name can be changed by the host.
    NSString* name;
    
    // defaultName cannot be changed by the host.
    NSString* defaultName;
    
    // The window title that should be used when this session is current. Otherwise defaultName
    // should be used.
    NSString* windowTitle;
    
    // The window title stack
    NSMutableArray* windowTitleStack;
    
    // The icon title stack
    NSMutableArray* iconTitleStack;
    
    // The original bookmark name.
    NSString* bookmarkName;
    
    // Shell wraps the underlying file descriptor pair.
    PTYTask* SHELL;
    
    // Terminal processes vt100 codes.
    VT100Terminal* TERMINAL;
    
    // The value of the $TERM environment var.
    NSString* TERM_VALUE;
    
    // The value of the $COLORFGBG environment var.
    NSString* COLORFGBG_VALUE;
    
    // The current screen contents.
    VT100Screen* SCREEN;
    
    // Has the underlying connection been closed?
    BOOL EXIT;
    
    // The view in which this session's objects live.
    SessionView* view;
    
    // The scrollview in which this session's contents are displayed.
    PTYScrollView* SCROLLVIEW;
    
    // A view that wraps the textview. It is the scrollview's document. This exists to provide a
    // top margin above the textview.
    TextViewWrapper* WRAPPER;
    
    // The view that contains all the visible text in this session.
    PTYTextView* TEXTVIEW;
    
    // This timer fires periodically to redraw TEXTVIEW, update the scroll position, tab appearance,
    // etc.
    NSTimer *updateTimer;
    
    // Anti-idle timer that sends a character every so often to the host.
    NSTimer* antiIdleTimer;
    
    // The code to send in the anti idle timer.
    char ai_code;
    
    // If true, close the tab when the session ends.
    BOOL autoClose;
    
    // True if ambiguous-width characters are double-width.
    BOOL doubleWidth;
    
    // True if mouse movements are sent to the host.
    BOOL xtermMouseReporting;
    
    // This is not used as far as I can tell.
    int bell;
    
    // True if background image should be tiled
    BOOL backgroundImageTiled;
    
    // Filename of background image.
    NSString* backgroundImagePath;
    
    // Bookmark currently in use.
    NSDictionary* addressBookEntry;
    
    // The bookmark the session was originally created with so those settings can be restored if
    // needed.
    Profile* originalAddressBookEntry;
    
    // Growl stuff
    iTermGrowlDelegate* gd;
    
    // Status reporting
    struct timeval lastInput, lastOutput;
    
    // Time that the tab label was last updated.
    struct timeval lastUpdate;
    
    // Does the session have new output? Used by -[PTYTab setLabelAttributes] to color the tab's title
    // appropriately.
    BOOL newOutput;
    
    // Is the session idle? Used by setLableAttribute to send a growl message when processing ends.
    BOOL growlIdle;
    
    // Is there new output for the purposes of growl notifications? They run on a different schedule
    // than tab colors.
    BOOL growlNewOutput;
    
    // Has this session's bookmark been divorced from the profile in the ProfileModel? Changes
    // in this bookmark may happen indepentendly of the persistent bookmark.
    bool isDivorced;
    
    // A digital video recorder for this session that implements the instant replay feature. These
    // are non-null while showing instant replay.
    DVR* dvr_;
    DVRDecoder* dvrDecoder_;
    
    // Set only if this is not a live session (we are showing instant replay). Is a pointer to the
    // hidden live session while looking at the past.
    PTYSession* liveSession_;
    
    // Is the update timer's callback currently running?
    BOOL timerRunning_;
    
    // Paste from the head of this string from a timer until it's empty.
    NSMutableString* slowPasteBuffer;
    NSTimer* slowPasteTimer;
    
    // The name of the foreground job at the moment as best we can tell.
    NSString* jobName_;
    
    // Ignore resize notifications. This would be set because the session's size musn't be changed
    // due to temporary changes in the window size, as code later on may need to know the session's
    // size to set the window size properly.
    BOOL ignoreResizeNotifications_;
    
    // Last time this session became active
    NSDate* lastActiveAt_;
    
    // Time session was created
    NSDate* creationDate_;
    
    // After receiving new output, we keep running the updateDisplay timer for a few seconds to catch
    // changes in job name.
    NSDate* updateDisplayUntil_;
    
    // If not nil, we're aggregating text to append to a pasteboard. The pasteboard will be
    // updated when this is set to nil.
    NSString *pasteboard_;
    NSMutableData *pbtext_;
    
    // The current line of text, for checking against triggers if any.
    NSMutableString *triggerLine_;
    
    // The current triggers.
    NSMutableArray *triggers_;
    
    // Does the terminal think this session is focused?
    BOOL focused_;
    
    FindContext *tailFindContext_;
    NSTimer *tailFindTimer_;
    
    enum {
        TMUX_NONE,
        TMUX_GATEWAY,
        TMUX_CLIENT
    } tmuxMode_;
    TmuxGateway *tmuxGateway_;
    TmuxController *tmuxController_;
    int tmuxPane_;
    BOOL tmuxLogging_;  // log to gateway client
    BOOL tmuxSecureLogging_;
    
    NSArray *sendModifiers_;
    NSMutableArray *eventQueue_;
    PasteViewController *pasteViewController_;
    PasteContext *pasteContext_;
    
    NSInteger requestAttentionId_;  // Last request-attention identifier
    VT100ScreenMark *lastMark_;
}

- (id)init
{
    self = [super init];
    if (self) {
        // The new session won't have the move-pane overlay, so just exit move pane
        // mode.
        [[MovePaneController sharedInstance] exitMovePaneMode];
        triggerLine_ = [[NSMutableString alloc] init];
        isDivorced = NO;
        gettimeofday(&lastInput, NULL);
        lastOutput = lastInput;
        lastUpdate = lastInput;
        EXIT=NO;
        updateTimer = nil;
        antiIdleTimer = nil;
        addressBookEntry = nil;
        windowTitleStack = nil;
        iconTitleStack = nil;
        eventQueue_ = [[NSMutableArray alloc] init];

        // Allocate screen, shell, and terminal objects
        SHELL = [[PTYTask alloc] init];
        TERMINAL = [[VT100Terminal alloc] init];
        SCREEN = [[VT100Screen alloc] initWithTerminal:TERMINAL];
        NSParameterAssert(SHELL != nil && TERMINAL != nil && SCREEN != nil);

        // Need Growl plist stuff
        gd = [iTermGrowlDelegate sharedInstance];
        growlIdle = growlNewOutput = NO;

        slowPasteBuffer = [[NSMutableString alloc] init];
        creationDate_ = [[NSDate date] retain];
        tmuxSecureLogging_ = NO;
        tailFindContext_ = [[FindContext alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowResized)
                                                     name:@"iTermWindowDidResize"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(coprocessChanged)
                                                     name:@"kCoprocessStatusChangeNotification"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionContentsChanged:)
                                                     name:@"iTermTabContentsChanged"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(synchronizeTmuxFonts:)
                                                     name:kTmuxFontChanged
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [self stopTailFind];  // This frees the substring in the tail find context, if needed.
    [triggerLine_ release];
    [triggers_ release];
    [pasteboard_ release];
    [pbtext_ release];
    [slowPasteBuffer release];
    if (slowPasteTimer) {
        [slowPasteTimer invalidate];
    }
    [updateDisplayUntil_ release];
    [creationDate_ release];
    [lastActiveAt_ release];
    [bookmarkName release];
    [TERM_VALUE release];
    [COLORFGBG_VALUE release];
    [name release];
    [windowTitle release];
    [windowTitleStack release];
    [iconTitleStack release];
    [addressBookEntry release];
    [eventQueue_ release];
    [backgroundImagePath release];
    [antiIdleTimer invalidate];
    [antiIdleTimer release];
    [updateTimer invalidate];
    [updateTimer release];
    [originalAddressBookEntry release];
    [liveSession_ release];
    [tmuxGateway_ release];
    [tmuxController_ release];
    [sendModifiers_ release];
    [pasteViewController_ release];
    [pasteContext_ release];
    [SHELL release];
    SHELL = nil;
    [SCREEN release];
    SCREEN = nil;
    [TERMINAL release];
    TERMINAL = nil;
    [tailFindContext_ release];
    _currentMarkOrNotePosition = nil;
    [lastMark_ release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (dvrDecoder_) {
        [dvr_ releaseDecoder:dvrDecoder_];
        [dvr_ release];
    }

    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p %dx%d>",
               [self class], self, [SCREEN width], [SCREEN height]];
}

- (void)cancelTimers
{
    [view cancelTimers];
    [updateTimer invalidate];
    [antiIdleTimer invalidate];
}

- (void)setDvr:(DVR*)dvr liveSession:(PTYSession*)liveSession
{
    assert(liveSession != self);

    liveSession_ = liveSession;
    [liveSession_ retain];
    SCREEN.dvr = nil;
    dvr_ = dvr;
    [dvr_ retain];
    dvrDecoder_ = [dvr getDecoder];
    long long t = [dvr_ lastTimeStamp];
    if (t) {
        [dvrDecoder_ seek:t];
        [self setDvrFrame];
    }
}

- (void)irAdvance:(int)dir
{
    if (!dvr_) {
        if (dir < 0) {
            [[[self tab] realParentWindow] replaySession:self];
            PTYSession* irSession = [[[self tab] realParentWindow] currentSession];
             if (irSession != self) {
                 // Failed to enter replay mode (perhaps nothing to replay?)
                [irSession irAdvance:dir];
             }
            return;
        } else {
            NSBeep();
            return;
        }

    }
    if (dir > 0) {
        if (![dvrDecoder_ next] || [dvrDecoder_ timestamp] == [dvr_ lastTimeStamp]) {
            // Switch to the live view
            [[[self tab] realParentWindow] showLiveSession:liveSession_ inPlaceOf:self];
            return;
        }
    } else {
        if (![dvrDecoder_ prev]) {
            NSBeep();
        }
    }
    [self setDvrFrame];
}

- (long long)irSeekToAtLeast:(long long)timestamp
{
    assert(dvr_);
    if (![dvrDecoder_ seek:timestamp]) {
        [dvrDecoder_ seek:[dvr_ firstTimeStamp]];
    }
    [self setDvrFrame];
    return [dvrDecoder_ timestamp];
}

- (DVR*)dvr
{
    return dvr_;
}

- (DVRDecoder*)dvrDecoder
{
    return dvrDecoder_;
}

- (PTYSession*)liveSession
{
    return liveSession_;
}

- (void)coprocessChanged
{
    [TEXTVIEW setNeedsDisplay:YES];
}

- (void)windowResized
{
    // When the window is resized the title is temporarily changed and it's our
    // timer that resets it.
    if (!EXIT) {
        [self scheduleUpdateIn:kBackgroundSessionIntervalSec];
    }
}

+ (void)drawArrangementPreview:(NSDictionary *)arrangement frame:(NSRect)frame
{
    Profile* theBookmark =
        [[ProfileModel sharedInstance] bookmarkWithGuid:[[arrangement objectForKey:SESSION_ARRANGEMENT_BOOKMARK]
                                                             objectForKey:KEY_GUID]];
    if (!theBookmark) {
        theBookmark = [arrangement objectForKey:SESSION_ARRANGEMENT_BOOKMARK];
    }
    //    [self setForegroundColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_FOREGROUND_COLOR]]];
    [[ITAddressBookMgr decodeColor:[theBookmark objectForKey:KEY_BACKGROUND_COLOR]] set];
    NSRectFill(frame);
}

- (void)setSizeFromArrangement:(NSDictionary*)arrangement
{
    [self setWidth:[[arrangement objectForKey:SESSION_ARRANGEMENT_COLUMNS] intValue]
            height:[[arrangement objectForKey:SESSION_ARRANGEMENT_ROWS] intValue]];
}

+ (PTYSession*)sessionFromArrangement:(NSDictionary*)arrangement
                               inView:(SessionView*)sessionView
                                inTab:(PTYTab*)theTab
                        forObjectType:(iTermObjectType)objectType
{
    PTYSession* aSession = [[[PTYSession alloc] init] autorelease];
    aSession->view = sessionView;
    [[sessionView findViewController] setDelegate:aSession];
    Profile* theBookmark =
        [[ProfileModel sharedInstance] bookmarkWithGuid:[[arrangement objectForKey:SESSION_ARRANGEMENT_BOOKMARK]
                                                            objectForKey:KEY_GUID]];
    BOOL needDivorce = NO;
    if (!theBookmark) {
        theBookmark = [arrangement objectForKey:SESSION_ARRANGEMENT_BOOKMARK];
        needDivorce = YES;
    }
    [[aSession SCREEN] setUnlimitedScrollback:[[theBookmark objectForKey:KEY_UNLIMITED_SCROLLBACK] boolValue]];
    [[aSession SCREEN] setMaxScrollbackLines:[[theBookmark objectForKey:KEY_SCROLLBACK_LINES] intValue]];

     // set our preferences
    [aSession setAddressBookEntry:theBookmark];

    [aSession setScreenSize:[sessionView frame] parent:[theTab realParentWindow]];
    NSDictionary *state = [arrangement objectForKey:SESSION_ARRANGEMENT_TMUX_STATE];
    if (state) {
        // For tmux tabs, get the size from the arrangement instead of the containing view because
        // it helps things to line up correctly.
        [aSession setSizeFromArrangement:arrangement];
    }
    [aSession setPreferencesFromAddressBookEntry:theBookmark];
    [aSession loadInitialColorTable];
    [aSession setName:[theBookmark objectForKey:KEY_NAME]];
    NSString *arrangementBookmarkName = arrangement[SESSION_ARRANGEMENT_BOOKMARK_NAME];
    if (arrangementBookmarkName) {
        [aSession setBookmarkName:arrangementBookmarkName];
    } else {
        [aSession setBookmarkName:[theBookmark objectForKey:KEY_NAME]];
    }
    if ([[[[theTab realParentWindow] window] title] compare:@"Window"] == NSOrderedSame) {
        [[theTab realParentWindow] setWindowTitle];
    }
    [aSession setTab:theTab];
    NSNumber *n = [arrangement objectForKey:SESSION_ARRANGEMENT_TMUX_PANE];
    if (!n) {
        [aSession runCommandWithOldCwd:[arrangement objectForKey:SESSION_ARRANGEMENT_WORKING_DIRECTORY]
                         forObjectType:objectType];
    } else {
        NSString *title = [state objectForKey:@"title"];
        if (title) {
            [aSession setName:title];
            [aSession setWindowTitle:title];
        }
    }
    if (needDivorce) {
        [aSession divorceAddressBookEntryFromPreferences];
    }

    if (n) {
        [aSession setTmuxPane:[n intValue]];
    }
    NSArray *history = [arrangement objectForKey:SESSION_ARRANGEMENT_TMUX_HISTORY];
    if (history) {
        [[aSession SCREEN] setHistory:history];
    }
    history = [arrangement objectForKey:SESSION_ARRANGEMENT_TMUX_ALT_HISTORY];
    if (history) {
        [[aSession SCREEN] setAltScreen:history];
    }
    if (state) {
        [[aSession SCREEN] setTmuxState:state];
        NSData *pendingOutput = [state objectForKey:kTmuxWindowOpenerStatePendingOutput];
        if (pendingOutput && [pendingOutput length]) {
            [[aSession TERMINAL] putStreamData:pendingOutput];
        }
        [[aSession TERMINAL] setInsertMode:[[state objectForKey:kStateDictInsertMode] boolValue]];
        [[aSession TERMINAL] setCursorMode:[[state objectForKey:kStateDictKCursorMode] boolValue]];
        [[aSession TERMINAL] setKeypadMode:[[state objectForKey:kStateDictKKeypadMode] boolValue]];
        if ([[state objectForKey:kStateDictMouseStandardMode] boolValue]) {
            [[aSession TERMINAL] setMouseMode:MOUSE_REPORTING_NORMAL];
        } else if ([[state objectForKey:kStateDictMouseButtonMode] boolValue]) {
            [[aSession TERMINAL] setMouseMode:MOUSE_REPORTING_BUTTON_MOTION];
        } else if ([[state objectForKey:kStateDictMouseAnyMode] boolValue]) {
            [[aSession TERMINAL] setMouseMode:MOUSE_REPORTING_ALL_MOTION];
        } else {
            [[aSession TERMINAL] setMouseMode:MOUSE_REPORTING_NONE];
        }
        [[aSession TERMINAL] setMouseFormat:[[state objectForKey:kStateDictMouseUTF8Mode] boolValue] ? MOUSE_FORMAT_XTERM_EXT : MOUSE_FORMAT_XTERM];
    }
    return aSession;
}

// Session specific methods
- (BOOL)setScreenSize:(NSRect)aRect parent:(id<WindowControllerInterface>)parent
{
    SCREEN.delegate = self;

    // Allocate a container to hold the scrollview
    if (!view) {
        view = [[[SessionView alloc] initWithFrame:NSMakeRect(0, 0, aRect.size.width, aRect.size.height)
                                          session:self] autorelease];
        [[view findViewController] setDelegate:self];
    }

    // Allocate a scrollview
    SCROLLVIEW = [[PTYScrollView alloc] initWithFrame:NSMakeRect(0,
                                                                 0,
                                                                 aRect.size.width,
                                                                 aRect.size.height)
                                  hasVerticalScroller:[parent scrollbarShouldBeVisible]];
    NSParameterAssert(SCROLLVIEW != nil);
    [SCROLLVIEW setAutoresizingMask: NSViewWidthSizable|NSViewHeightSizable];

    // assign the main view
    [view addSubview:SCROLLVIEW];
    if (![self isTmuxClient]) {
        [view setAutoresizesSubviews:YES];
    }
    // TODO(georgen): I disabled setCopiesOnScroll because there is a vertical margin in the PTYTextView and
    // we would not want that copied. This is obviously bad for performance when scrolling, but it's unclear
    // whether the difference will ever be noticable. I believe it could be worked around (painfully) by
    // subclassing NSClipView and overriding viewBoundsChanged: and viewFrameChanged: so that it coipes on
    // scroll but it doesn't include the vertical marigns when doing so.
    // The vertical margins are indespensable because different PTYTextViews may use different fonts/font
    // sizes, but the window size does not change as you move from tab to tab. If the margin is outside the
    // NSScrollView's contentView it looks funny.
    [[SCROLLVIEW contentView] setCopiesOnScroll:NO];

    // Allocate a text view
    NSSize aSize = [SCROLLVIEW contentSize];
    WRAPPER = [[TextViewWrapper alloc] initWithFrame:NSMakeRect(0, 0, aSize.width, aSize.height)];
    [WRAPPER setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    TEXTVIEW = [[PTYTextView alloc] initWithFrame: NSMakeRect(0, VMARGIN, aSize.width, aSize.height)];
    [TEXTVIEW setDimOnlyText:[[PreferencePanel sharedInstance] dimOnlyText]];
    [TEXTVIEW setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
    [TEXTVIEW setFont:[ITAddressBookMgr fontWithDesc:[addressBookEntry objectForKey:KEY_NORMAL_FONT]]
               nafont:[ITAddressBookMgr fontWithDesc:[addressBookEntry objectForKey:KEY_NON_ASCII_FONT]]
    horizontalSpacing:[[addressBookEntry objectForKey:KEY_HORIZONTAL_SPACING] floatValue]
      verticalSpacing:[[addressBookEntry objectForKey:KEY_VERTICAL_SPACING] floatValue]];
    [self setTransparency:[[addressBookEntry objectForKey:KEY_TRANSPARENCY] floatValue]];
        const float theBlend = [addressBookEntry objectForKey:KEY_BLEND] ?
                                                  [[addressBookEntry objectForKey:KEY_BLEND] floatValue] : 0.5;
    [self setBlend:theBlend];

    [WRAPPER addSubview:TEXTVIEW];
    [TEXTVIEW setFrame:NSMakeRect(0, VMARGIN, aSize.width, aSize.height - VMARGIN)];
    [TEXTVIEW release];

    // assign terminal and task objects
    TERMINAL.delegate = SCREEN;
    [SHELL setDelegate:self];

    // initialize the screen
    int width = (aSize.width - MARGIN*2) / [TEXTVIEW charWidth];
    int height = (aSize.height - VMARGIN*2) / [TEXTVIEW lineHeight];
    // NB: In the bad old days, this returned whether setup succeeded because it would allocate an
    // enormous amount of memory. That's no longer an issue.
    [SCREEN destructivelySetScreenWidth:width height:height];
    [self setName:@"Shell"];
    [self setDefaultName:@"Shell"];

    [TEXTVIEW setDataSource:SCREEN];
    [TEXTVIEW setDelegate:self];
    [SCROLLVIEW setDocumentView:WRAPPER];
    [WRAPPER release];
    [SCROLLVIEW setDocumentCursor:[PTYTextView textViewCursor]];
    [SCROLLVIEW setLineScroll:[TEXTVIEW lineHeight]];
    [SCROLLVIEW setPageScroll:2*[TEXTVIEW lineHeight]];
    [SCROLLVIEW setHasVerticalScroller:[parent scrollbarShouldBeVisible]];

    ai_code=0;
    [antiIdleTimer release];
    antiIdleTimer = nil;
    newOutput = NO;

    return YES;
}

- (void)runCommandWithOldCwd:(NSString*)oldCWD
               forObjectType:(iTermObjectType)objectType
{
    NSMutableString *cmd;
    NSArray *arg;
    NSString *pwd;
    BOOL isUTF8;

    // Grab the addressbook command
    Profile* addressbookEntry = [self addressBookEntry];
    cmd = [[[NSMutableString alloc] initWithString:[ITAddressBookMgr bookmarkCommand:addressbookEntry
                                                                       forObjectType:objectType]] autorelease];
    NSMutableString* theName = [[[NSMutableString alloc] initWithString:[addressbookEntry objectForKey:KEY_NAME]] autorelease];
    // Get session parameters
    [[[self tab] realParentWindow] getSessionParameters:cmd withName:theName];

    [cmd breakDownCommandToPath:&cmd cmdArgs:&arg];

    pwd = [ITAddressBookMgr bookmarkWorkingDirectory:addressbookEntry
                                       forObjectType:objectType];
    if ([pwd length] == 0) {
        if (oldCWD) {
            pwd = oldCWD;
        } else {
            pwd = NSHomeDirectory();
        }
    }
    NSDictionary *env = [NSDictionary dictionaryWithObject:pwd forKey:@"PWD"];
    isUTF8 = ([[addressbookEntry objectForKey:KEY_CHARACTER_ENCODING] unsignedIntValue] == NSUTF8StringEncoding);

    [[[self tab] realParentWindow] setName:theName forSession:self];

    // Start the command
    [self startProgram:cmd arguments:arg environment:env isUTF8:isUTF8];
}

- (void)setWidth:(int)width height:(int)height
{
    DLog(@"Set session %@ to %dx%d", self, width, height);
    [SCREEN resizeWidth:width height:height];
    [SHELL setWidth:width height:height];
    [TEXTVIEW clearHighlights];
    [[tab_ realParentWindow] invalidateRestorableState];
}

- (void)setSplitSelectionMode:(SplitSelectionMode)mode
{
    [[self view] setSplitSelectionMode:mode];
}

- (int)overUnder:(int)proposedSize inVerticalDimension:(BOOL)vertically
{
    int x = proposedSize;
    if (vertically) {
        if ([view showTitle]) {
            // x = 50/53
            x -= [SessionView titleHeight];
        }
        // x = 28/31
        x -= VMARGIN * 2;
        // x = 18/21
        // iLineHeight = 10
        int iLineHeight = [TEXTVIEW lineHeight];
        x %= iLineHeight;
        // x = 8/1
        if (x > iLineHeight / 2) {
            x -= iLineHeight;
        }
        // x = -2/1
        return x;
    } else {
        x -= MARGIN * 2;
        int iCharWidth = [TEXTVIEW charWidth];
        x %= iCharWidth;
        if (x > iCharWidth / 2) {
            x -= iCharWidth;
        }
    }
    return x;
}

- (NSArray *)childJobNames
{
    int skip = 0;
    pid_t thePid = [SHELL pid];
    if ([[[ProcessCache sharedInstance] getNameOfPid:thePid isForeground:nil] isEqualToString:@"login"]) {
        skip = 1;
    }
    NSMutableArray *names = [NSMutableArray array];
    for (NSNumber *n in [[ProcessCache sharedInstance] childrenOfPid:thePid levelsToSkip:skip]) {
        pid_t pid = [n intValue];
        NSDictionary *info = [[ProcessCache sharedInstance] dictionaryOfTaskInfoForPid:pid];
        [names addObject:[info objectForKey:PID_INFO_NAME]];
    }
    return names;
}

- (BOOL)promptOnClose
{
    if (EXIT) {
        return NO;
    }
    switch ([[addressBookEntry objectForKey:KEY_PROMPT_CLOSE] intValue]) {
        case PROMPT_ALWAYS:
            return YES;

        case PROMPT_NEVER:
            return NO;

        case PROMPT_EX_JOBS: {
            NSArray *jobsThatDontRequirePrompting = [addressBookEntry objectForKey:KEY_JOBS];
            for (NSString *childName in [self childJobNames]) {
                if ([jobsThatDontRequirePrompting indexOfObject:childName] == NSNotFound) {
                    // This job is not in the ignore list.
                    return YES;
                }
            }
            // All jobs were in the ignore list.
            return NO;
        }
    }

    return YES;
}

- (void)setNewOutput:(BOOL)value
{
    newOutput = value;
}

- (BOOL)newOutput
{
    return newOutput;
}

// This command installs the xterm-256color terminfo in the user's terminfo directory:
// tic -e xterm-256color $FILENAME
- (void)_maybeAskAboutInstallXtermTerminfo
{
    NSString* NEVER_WARN = @"NeverWarnAboutXterm256ColorTerminfo";
    if ([[NSUserDefaults standardUserDefaults] objectForKey:NEVER_WARN]) {
        return;
    }

    NSString* filename = [[NSBundle bundleForClass:[self class]] pathForResource:@"xterm-terminfo" ofType:@"txt"];
    if (!filename) {
        return;
    }
    NSString* cmd = [NSString stringWithFormat:@"tic -e xterm-256color %@", [filename stringWithEscapedShellCharacters]];
    if (system("infocmp xterm-256color > /dev/null")) {
        switch (NSRunAlertPanel(@"Warning",
                                @"The terminfo file for the terminal type you're using, \"xterm-256color\", is not installed on your system. Would you like to install it now?",
                                @"Install",
                                @"Never ask me again",
                                @"Not Now",
                                nil)) {
            case NSAlertDefaultReturn:
                if (system([cmd UTF8String])) {
                    NSRunAlertPanel(@"Error",
                                    [NSString stringWithFormat:@"Sorry, an error occurred while running: %@", cmd],
                                    @"Ok", nil, nil);
                }
                break;
            case NSAlertAlternateReturn:
                [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:YES] forKey:NEVER_WARN];
                break;
        }
    }
}

- (NSString *)_autoLogFilenameForTermId:(NSString *)termid
{
    // $(LOGDIR)/YYYYMMDD_HHMMSS.$(NAME).wNtNpN.$(PID).$(RANDOM).log
    return [NSString stringWithFormat:@"%@/%@.%@.%@.%d.%0x.log",
            [addressBookEntry objectForKey:KEY_LOGDIR],
            [[NSDate date] descriptionWithCalendarFormat:@"%Y%m%d_%H%M%S"
                                                timeZone:nil
                                                  locale:nil],
            [addressBookEntry objectForKey:KEY_NAME],
            termid,
            (int)getpid(),
            (int)arc4random()];
}

- (BOOL)shouldSetCtype {
    return ![[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSetCtype"];
}

- (void)startProgram:(NSString *)program
           arguments:(NSArray *)prog_argv
         environment:(NSDictionary *)prog_env
              isUTF8:(BOOL)isUTF8
{
    NSString *path = program;
    NSMutableArray *argv = [NSMutableArray arrayWithArray:prog_argv];
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:prog_env];


    if ([env objectForKey:TERM_ENVNAME] == nil)
        [env setObject:TERM_VALUE forKey:TERM_ENVNAME];
    if ([[env objectForKey:TERM_ENVNAME] isEqualToString:@"xterm-256color"]) {
        [self _maybeAskAboutInstallXtermTerminfo];
    }

    if ([env objectForKey:COLORFGBG_ENVNAME] == nil && COLORFGBG_VALUE != nil)
        [env setObject:COLORFGBG_VALUE forKey:COLORFGBG_ENVNAME];

    DLog(@"Begin locale logic");
    if (![addressBookEntry objectForKey:KEY_SET_LOCALE_VARS] ||
        [[addressBookEntry objectForKey:KEY_SET_LOCALE_VARS] boolValue]) {
        DLog(@"Setting locale vars...");
        NSString* lang = [self _lang];
        if (lang) {
            DLog(@"set LANG=%@", lang);
            [env setObject:lang forKey:@"LANG"];
        } else if ([self shouldSetCtype]){
            DLog(@"should set ctype...");
            // Try just the encoding by itself, which might work.
            NSString *encName = [self encodingName];
            DLog(@"See if encoding %@ is supported...", encName);
            if (encName && [self _localeIsSupported:encName]) {
                DLog(@"Set LC_CTYPE=%@", encName);
                [env setObject:encName forKey:@"LC_CTYPE"];
            }
        }
    }

    if ([env objectForKey:PWD_ENVNAME] == nil) {
        [env setObject:[PWD_ENVVALUE stringByExpandingTildeInPath] forKey:PWD_ENVNAME];
    }

    NSWindowController<iTermWindowController> *pty = [tab_ realParentWindow];
    NSString *itermId = [NSString stringWithFormat:@"w%dt%dp%d",
                         [pty number],
                         [tab_ realObjectCount] - 1,
                         [tab_ indexOfSessionView:[self view]]];
    [env setObject:itermId forKey:@"ITERM_SESSION_ID"];
    if ([addressBookEntry objectForKey:KEY_NAME]) {
        [env setObject:[addressBookEntry objectForKey:KEY_NAME] forKey:@"ITERM_PROFILE"];
    }
    if ([[addressBookEntry objectForKey:KEY_AUTOLOG] boolValue]) {
        [SHELL loggingStartWithPath:[self _autoLogFilenameForTermId:itermId]];
    }
    [SHELL launchWithPath:path
                arguments:argv
              environment:env
                    width:[SCREEN width]
                   height:[SCREEN height]
                   isUTF8:isUTF8];
    NSString *initialText = [addressBookEntry objectForKey:KEY_INITIAL_TEXT];
    if ([initialText length]) {
        [SHELL writeTask:[initialText dataUsingEncoding:[self encoding]]];
        [SHELL writeTask:[@"\n" dataUsingEncoding:[self encoding]]];
    }
}

- (void)launchProfileInCurrentTerminal:(Profile *)profile
                               withURL:(NSString *)url
{
    PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
    [[iTermController sharedInstance] launchBookmark:profile
                                          inTerminal:term
                                             withURL:url
                                            isHotkey:NO
                                             makeKey:NO];
}

- (void)selectPaneLeftInCurrentTerminal
{
    [[[iTermController sharedInstance] currentTerminal] selectPaneLeft:nil];
}

- (void)selectPaneRightInCurrentTerminal
{
    [[[iTermController sharedInstance] currentTerminal] selectPaneRight:nil];
}

- (void)selectPaneAboveInCurrentTerminal
{
    [[[iTermController sharedInstance] currentTerminal] selectPaneUp:nil];
}

- (void)selectPaneBelowInCurrentTerminal
{
    [[[iTermController sharedInstance] currentTerminal] selectPaneDown:nil];
}

- (void)_maybeWarnAboutShortLivedSessions
{
    if ([[NSDate date] timeIntervalSinceDate:creationDate_] < 3) {
        NSString* theName = [addressBookEntry objectForKey:KEY_NAME];
        NSString* theKey = [NSString stringWithFormat:@"NeverWarnAboutShortLivedSessions_%@", [addressBookEntry objectForKey:KEY_GUID]];
        if (![[[NSUserDefaults standardUserDefaults] objectForKey:theKey] boolValue]) {
            if (NSRunAlertPanel(@"Short-Lived Session Warning",
                                [NSString stringWithFormat:@"A session ended very soon after starting. Check that the command in profile \"%@\" is correct.", theName],
                                @"Ok",
                                @"Don't Warn Again for This Profile",
                                nil) != NSAlertDefaultReturn) {
                [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:YES] forKey:theKey];
            }
        }
    }
}

// Terminate a replay session but not the live session
- (void)softTerminate
{
    liveSession_ = nil;
    [self terminate];
}

- (void)terminate
{
    if ([[self TEXTVIEW] isFindingCursor]) {
        [[self TEXTVIEW] endFindCursor];
    }
    if (EXIT) {
        [self _maybeWarnAboutShortLivedSessions];
    }
    if (tmuxMode_ == TMUX_CLIENT) {
        assert([tab_ tmuxWindow] >= 0);
        [tmuxController_ deregisterWindow:[tab_ tmuxWindow]
                               windowPane:tmuxPane_];
        // This call to fitLayoutToWindows is necessary to handle the case where
        // a small window closes and leaves behind a larger (e.g., fullscreen)
        // window. We want to set the client size to that of the smallest
        // remaining window.
        int n = [[tab_ sessions] count];
        if ([[tab_ sessions] indexOfObjectIdenticalTo:self] != NSNotFound) {
            n--;
        }
        if (n == 0) {
            // The last session in this tab closed so check if the client has
            // changed size
            [tmuxController_ fitLayoutToWindows];
        }
    } else if (tmuxMode_ == TMUX_GATEWAY) {
        [tmuxController_ detach];
                [tmuxGateway_ release];
                tmuxGateway_ = nil;
    }
    tmuxMode_ = TMUX_NONE;
    [tmuxController_ release];
    tmuxController_ = nil;

    // The source pane may have just exited. Dogs and cats living together!
    // Mass hysteria!
    [[MovePaneController sharedInstance] exitMovePaneMode];

    // deregister from the notification center
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (liveSession_) {
        [liveSession_ terminate];
    }

    EXIT = YES;
    [SHELL stop];

    // final update of display
    [self updateDisplay];

    [tab_ removeSession:self];

    [TEXTVIEW setDataSource:nil];
    [TEXTVIEW setDelegate:nil];
    [TEXTVIEW removeFromSuperview];
    TEXTVIEW = nil;

    [SHELL setDelegate:nil];
    SCREEN.delegate = nil;
    [SCREEN setTerminal:nil];
    TERMINAL.delegate = nil;
    if ([[view findViewController] delegate] == self) {
        [[view findViewController] setDelegate:nil];
    }

    [updateTimer invalidate];
    [updateTimer release];
    updateTimer = nil;

    if (slowPasteTimer) {
        [slowPasteTimer invalidate];
        slowPasteTimer = nil;
        [eventQueue_ removeAllObjects];
    }
    
    [[tab_ realParentWindow]  sessionDidTerminate:self];

    tab_ = nil;
}

- (void)writeTaskImpl:(NSData *)data
{
    static BOOL checkedDebug;
    static BOOL debugKeyDown;
    if (!checkedDebug) {
        debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];
        checkedDebug = YES;
    }
    if (debugKeyDown || gDebugLogging) {
        NSArray *stack = [NSThread callStackSymbols];
        if (debugKeyDown) {
            NSLog(@"writeTaskImpl %p: called from %@", self, stack);
        }
        if (gDebugLogging) {
            DebugLog([NSString stringWithFormat:@"writeTaskImpl %p: called from %@", self, stack]);
        }
        const char *bytes = [data bytes];
        for (int i = 0; i < [data length]; i++) {
            if (debugKeyDown) {
                NSLog(@"writeTask keydown %d: %d (%c)", i, (int) bytes[i], bytes[i]);
            }
            if (gDebugLogging) {
                DebugLog([NSString stringWithFormat:@"writeTask keydown %d: %d (%c)", i, (int) bytes[i], bytes[i]]);
            }
        }
    }

    // check if we want to send this input to all the sessions
    if (![[[self tab] realParentWindow] broadcastInputToSession:self]) {
        // Send to only this session
        if (!EXIT) {
            [self setBell:NO];
            PTYScroller* ptys = (PTYScroller*)[SCROLLVIEW verticalScroller];
            [SHELL writeTask:data];
            [ptys setUserScroll:NO];
        }
    } else {
        // send to all sessions
        [[[self tab] realParentWindow] sendInputToAllSessions:data];
    }
}

- (void)writeTaskNoBroadcast:(NSData *)data
{
    if (tmuxMode_ == TMUX_CLIENT) {
        [[tmuxController_ gateway] sendKeys:data
                               toWindowPane:tmuxPane_];
        return;
    }
    [self writeTaskImpl:data];
}

- (void)handleKeypressInTmuxGateway:(unichar)unicode
{
    if (unicode == 27) {
        [self tmuxDetach];
    } else if (unicode == 'L') {
        tmuxLogging_ = !tmuxLogging_;
        [self printTmuxMessage:[NSString stringWithFormat:@"tmux logging %@", (tmuxLogging_ ? @"on" : @"off")]];
    } else if (unicode == 'C') {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Enter command to send tmux:"
                                         defaultButton:@"Ok"
                                       alternateButton:@"Cancel"
                                           otherButton:nil
                             informativeTextWithFormat:@""];
        NSTextField *tmuxCommand = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)] autorelease];
        [tmuxCommand setEditable:YES];
        [tmuxCommand setSelectable:YES];
        [alert setAccessoryView:tmuxCommand];
        if ([alert runModal] == NSAlertDefaultReturn && [[tmuxCommand stringValue] length]) {
            [self printTmuxMessage:[NSString stringWithFormat:@"Run command \"%@\"", [tmuxCommand stringValue]]];
            [tmuxGateway_ sendCommand:[tmuxCommand stringValue]
                       responseTarget:self
                     responseSelector:@selector(printTmuxCommandOutputToScreen:)];
        }
    } else if (unicode == 'X') {
        [self printTmuxMessage:@"Exiting tmux mode, but tmux client may still be running."];
        [self tmuxHostDisconnected];
    }
}

- (void)writeTask:(NSData*)data
{
    if (tmuxMode_ == TMUX_CLIENT) {
        [self setBell:NO];
        if ([[tab_ realParentWindow] broadcastInputToSession:self]) {
            [[tab_ realParentWindow] sendInputToAllSessions:data];
        } else {
            [[tmuxController_ gateway] sendKeys:data
                                     toWindowPane:tmuxPane_];
        }
        PTYScroller* ptys = (PTYScroller*)[SCROLLVIEW verticalScroller];
        [ptys setUserScroll:NO];
        return;
    } else if (tmuxMode_ == TMUX_GATEWAY) {
        // Use keypresses for tmux gateway commands for development and debugging.
        NSString *s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        for (int i = 0; i < s.length; i++) {
            unichar unicode = [s characterAtIndex:i];
            [self handleKeypressInTmuxGateway:unicode];
        }
        return;
    }
    self.currentMarkOrNotePosition = nil;
    [self writeTaskImpl:data];
}

- (void)readTask:(NSData*)data
{
    if ([data length] == 0 || EXIT) {
        return;
    }
    if ([SHELL hasMuteCoprocess]) {
        return;
    }
    if (gDebugLogging) {
      const char* bytes = [data bytes];
      int length = [data length];
      DebugLog([NSString stringWithFormat:@"readTask called with %d bytes. The last byte is %d", (int)length, (int)bytes[length-1]]);
    }
    if (tmuxMode_ == TMUX_GATEWAY) {
        if (tmuxLogging_) {
            [self printTmuxCommandOutputToScreen:[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]];
        }
        data = [tmuxGateway_ readTask:data];
        if (!data) {
            // All data was consumed.
            return;
        }
    }

    [TERMINAL putStreamData:data];

    // while loop to process all the tokens we can get
    while (!EXIT &&
           TERMINAL &&
           tmuxMode_ != TMUX_GATEWAY &&
           [TERMINAL parseNextToken]) {
        // process token
        [TERMINAL executeToken];
    }

    gettimeofday(&lastOutput, NULL);
    newOutput = YES;

    // Make sure the screen gets redrawn soonish
    [updateDisplayUntil_ release];
    updateDisplayUntil_ = [[NSDate dateWithTimeIntervalSinceNow:10] retain];
    if ([[[self tab] parentWindow] currentTab] == [self tab]) {
        if ([data length] < 1024) {
            [self scheduleUpdateIn:kFastTimerIntervalSec];
        } else {
            [self scheduleUpdateIn:kSlowTimerIntervalSec];
        }
    } else {
        [self scheduleUpdateIn:kBackgroundSessionIntervalSec];
    }
    [[ProcessCache sharedInstance] notifyNewOutput];
}

- (void)checkTriggers
{
    for (Trigger *trigger in triggers_) {
        [trigger tryString:triggerLine_ inSession:self];
    }
}

- (void)appendStringToTriggerLine:(NSString *)s
{
    const int kMaxTriggerLineLength = 1024;
    if ([triggers_ count] && [triggerLine_ length] + [s length] < kMaxTriggerLineLength) {
        [triggerLine_ appendString:s];
    }
}

- (void)clearTriggerLine
{
    if ([triggers_ count]) {
        [self checkTriggers];
        [triggerLine_ setString:@""];
    }
}

- (BOOL)_growlOnForegroundTabs
{
    return [[[NSUserDefaults standardUserDefaults] objectForKey:@"GrowlOnForegroundTabs"] boolValue];
}

- (void)brokenPipe
{
    if (SCREEN.postGrowlNotifications &&
        (![[self tab] isForegroundTab] || [self _growlOnForegroundTabs])) {
        [gd growlNotify:@"Session Ended"
            withDescription:[NSString stringWithFormat:@"Session \"%@\" in tab #%d just terminated.",
                             [self name],
                             [[self tab] realObjectCount]]
            andNotification:@"Broken Pipes"];
    }

    EXIT = YES;
    [[self tab] setLabelAttributes];

    if ([self autoClose]) {
        [[self tab] closeSession:self];
    } else {
        [self updateDisplay];
    }
}

- (NSSize)idealScrollViewSizeWithStyle:(NSScrollerStyle)scrollerStyle
{
    NSSize innerSize = NSMakeSize([SCREEN width] * [TEXTVIEW charWidth] + MARGIN * 2,
                                  [SCREEN height] * [TEXTVIEW lineHeight] + VMARGIN * 2);
    BOOL hasScrollbar = [[tab_ realParentWindow] scrollbarShouldBeVisible];
    NSSize outerSize =
        [PTYScrollView frameSizeForContentSize:innerSize
                       horizontalScrollerClass:nil
                         verticalScrollerClass:hasScrollbar ? [PTYScroller class] : nil
                                    borderType:NSNoBorder
                                   controlSize:NSRegularControlSize
                                 scrollerStyle:scrollerStyle];
        return outerSize;
}

- (int)_keyBindingActionForEvent:(NSEvent*)event
{
    unsigned int modflag;
    NSString *unmodkeystr;
    unichar unmodunicode;
    int keyBindingAction;
    NSString *keyBindingText;

    modflag = [event modifierFlags];
    unmodkeystr = [event charactersIgnoringModifiers];
    unmodunicode = [unmodkeystr length]>0?[unmodkeystr characterAtIndex:0]:0;

    /*
    unsigned short keycode = [event keyCode];
    NSString *keystr = [event characters];
    unichar unicode = [keystr length] > 0 ? [keystr characterAtIndex:0] : 0;
    NSLog(@"event:%@ (%x+%x)[%@][%@]:%x(%c) <%d>", event,modflag,keycode,keystr,unmodkeystr,unicode,unicode,(modflag & NSNumericPadKeyMask));
    */

    // Check if we have a custom key mapping for this event
    keyBindingAction = [iTermKeyBindingMgr actionForKeyCode:unmodunicode
                                                  modifiers:modflag
                                                       text:&keyBindingText
                                                keyMappings:[[self addressBookEntry] objectForKey:KEY_KEYBOARD_MAP]];
    return keyBindingAction;
}

- (BOOL)hasTextSendingKeyMappingForEvent:(NSEvent*)event
{
    int keyBindingAction = [self _keyBindingActionForEvent:event];
    switch (keyBindingAction) {
        case KEY_ACTION_ESCAPE_SEQUENCE:
        case KEY_ACTION_HEX_CODE:
        case KEY_ACTION_TEXT:
        case KEY_ACTION_RUN_COPROCESS:
        case KEY_ACTION_IGNORE:
        case KEY_ACTION_SEND_C_H_BACKSPACE:
        case KEY_ACTION_SEND_C_QM_BACKSPACE:
            return YES;
    }
    return NO;
}

- (BOOL)_askAboutOutdatedKeyMappings
{
    NSNumber* n = [addressBookEntry objectForKey:KEY_ASK_ABOUT_OUTDATED_KEYMAPS];
    if (!n) {
        n = [[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:kAskAboutOutdatedKeyMappingKeyFormat,
                                                                 [addressBookEntry objectForKey:KEY_GUID]]];
        if (!n && [addressBookEntry objectForKey:KEY_ORIGINAL_GUID]) {
            n = [[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:kAskAboutOutdatedKeyMappingKeyFormat,
                                                                     [addressBookEntry objectForKey:KEY_ORIGINAL_GUID]]];
        }
    }
    return n ? [n boolValue] : YES;
}

- (void)_removeOutdatedKeyMapping
{
    NSMutableDictionary* temp = [NSMutableDictionary dictionaryWithDictionary:addressBookEntry];
    [iTermKeyBindingMgr removeMappingWithCode:NSLeftArrowFunctionKey
                                    modifiers:NSCommandKeyMask | NSAlternateKeyMask | NSNumericPadKeyMask
                                   inBookmark:temp];
    [iTermKeyBindingMgr removeMappingWithCode:NSRightArrowFunctionKey
                                    modifiers:NSCommandKeyMask | NSAlternateKeyMask | NSNumericPadKeyMask
                                   inBookmark:temp];

    ProfileModel* model;
    if (isDivorced) {
        model = [ProfileModel sessionsInstance];
    } else {
        model = [ProfileModel sharedInstance];
    }
    [model setBookmark:temp withGuid:[temp objectForKey:KEY_GUID]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"iTermKeyBindingsChanged"
                                                        object:nil
                                                      userInfo:nil];
    [[iTermController sharedInstance] reloadAllBookmarks];
}

- (void)_setKeepOutdatedKeyMapping
{
    ProfileModel* model;
    if (isDivorced) {
        model = [ProfileModel sessionsInstance];
    } else {
        model = [ProfileModel sharedInstance];
    }
    [model setObject:[NSNumber numberWithBool:NO]
                                       forKey:KEY_ASK_ABOUT_OUTDATED_KEYMAPS
                                   inBookmark:addressBookEntry];
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO]
                                              forKey:[NSString stringWithFormat:kAskAboutOutdatedKeyMappingKeyFormat,
                                                      [addressBookEntry objectForKey:KEY_GUID]]];
    if ([addressBookEntry objectForKey:KEY_ORIGINAL_GUID]) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO]
                                                  forKey:[NSString stringWithFormat:kAskAboutOutdatedKeyMappingKeyFormat,
                                                          [addressBookEntry objectForKey:KEY_ORIGINAL_GUID]]];
    }
    [[iTermController sharedInstance] reloadAllBookmarks];
}

+ (BOOL)_recursiveSelectMenuItem:(NSString*)theName inMenu:(NSMenu*)menu
{
    for (NSMenuItem* item in [menu itemArray]) {
        if (![item isEnabled] || [item isHidden] || [item isAlternate]) {
            continue;
        }
        if ([item hasSubmenu]) {
            if ([PTYSession _recursiveSelectMenuItem:theName inMenu:[item submenu]]) {
                return YES;
            }
        } else if ([theName isEqualToString:[item title]]) {
            [NSApp sendAction:[item action]
                           to:[item target]
                         from:item];
            return YES;
        }
    }
    return NO;
}

+ (BOOL)handleShortcutWithoutTerminal:(NSEvent*)event
{
    unsigned int modflag;
    NSString *unmodkeystr;
    unichar unmodunicode;
    int keyBindingAction;
    NSString *keyBindingText;

    modflag = [event modifierFlags];
    unmodkeystr = [event charactersIgnoringModifiers];
    unmodunicode = [unmodkeystr length]>0?[unmodkeystr characterAtIndex:0]:0;

    // Check if we have a custom key mapping for this event
    keyBindingAction = [iTermKeyBindingMgr actionForKeyCode:unmodunicode
                                                  modifiers:modflag
                                                       text:&keyBindingText
                                                keyMappings:[iTermKeyBindingMgr globalKeyMap]];


    if (keyBindingAction == KEY_ACTION_SELECT_MENU_ITEM) {
        [PTYSession selectMenuItem:keyBindingText];
        return YES;
    } else {
        return NO;
    }
}


+ (void)selectMenuItem:(NSString*)theName
{
    if (![self _recursiveSelectMenuItem:theName inMenu:[NSApp mainMenu]]) {
        NSBeep();
    }
}

- (BOOL)willHandleEvent:(NSEvent *) theEvent
{
    return NO;
}

- (void)handleEvent:(NSEvent *)theEvent
{
}

- (void)insertNewline:(id)sender
{
    [self insertText:@"\n"];
}

- (void)insertTab:(id)sender
{
    [self insertText:@"\t"];
}

- (void)moveUp:(id)sender
{
    [self writeTask:[TERMINAL keyArrowUp:0]];
}

- (void)moveDown:(id)sender
{
    [self writeTask:[TERMINAL keyArrowDown:0]];
}

- (void)moveLeft:(id)sender
{
    [self writeTask:[TERMINAL keyArrowLeft:0]];
}

- (void)moveRight:(id)sender
{
    [self writeTask:[TERMINAL keyArrowRight:0]];
}

- (void)pageUp:(id)sender
{
    [self writeTask:[TERMINAL keyPageUp:0]];
}

- (void)pageDown:(id)sender
{
    [self writeTask:[TERMINAL keyPageDown:0]];
}

- (void)emptyEventQueue {
    int eventsSent = 0;
    for (NSEvent *event in eventQueue_) {
        ++eventsSent;
        if ([event isKindOfClass:[PasteEvent class]]) {
            PasteEvent *pasteEvent = (PasteEvent *)event;
            [self pasteString:pasteEvent.string flags:pasteEvent.flags];
            // Can't empty while pasting.
            break;
        } else {
            [TEXTVIEW keyDown:event];
        }
    }
    [eventQueue_ removeObjectsInRange:NSMakeRange(0, eventsSent)];
}

+ (NSString*)pasteboardString
{
    NSPasteboard *board;
    
    board = [NSPasteboard generalPasteboard];
    assert(board != nil);
    
    NSArray *supportedTypes = [NSArray arrayWithObjects:NSFilenamesPboardType, NSStringPboardType, nil];
    NSString *bestType = [board availableTypeFromArray:supportedTypes];
    
    NSString* info = nil;
    if ([bestType isEqualToString:NSFilenamesPboardType]) {
        NSArray *filenames = [board propertyListForType:NSFilenamesPboardType];
        NSMutableArray *escapedFilenames = [NSMutableArray array];
        for (NSString *filename in filenames) {
            [escapedFilenames addObject:[filename stringWithEscapedShellCharacters]];
        }
        if (escapedFilenames.count > 0) {
            info = [escapedFilenames componentsJoinedByString:@" "];
        }
        if ([info length] == 0) {
            info = nil;
        }
    } else {
        info = [board stringForType:NSStringPboardType];
    }
    return info;
}

- (void)insertText:(NSString *)string
{
    NSData *data;
    NSMutableString *mstring;
    int i;
    int max;

    if (EXIT) {
        return;
    }

    //    NSLog(@"insertText:%@",string);
    mstring = [NSMutableString stringWithString:string];
    max = [string length];
    for (i = 0; i < max; i++) {
        // From http://lists.apple.com/archives/cocoa-dev/2001/Jul/msg00114.html
        // in MacJapanese, the backslash char (ASCII 0xdC) is mapped to Unicode 0xA5.
        // The following line gives you NSString containing an Unicode character Yen sign (0xA5) in Japanese localization.
        // string = [NSString stringWithCString:"\"];
        // TODO: Check the locale before doing this.
        if ([mstring characterAtIndex:i] == 0xa5) {
            [mstring replaceCharactersInRange:NSMakeRange(i, 1) withString:@"\\"];
        }
    }

    data = [mstring dataUsingEncoding:[TERMINAL encoding]
                 allowLossyConversion:YES];

    if (data != nil) {
        if (gDebugLogging) {
            DebugLog([NSString stringWithFormat:@"writeTask:%@", data]);
        }
        [self writeTask:data];
    }
}

- (void)showPasteUI {
    pasteViewController_ = [[PasteViewController alloc] initWithContext:pasteContext_
                                                                 length:slowPasteBuffer.length];
    pasteViewController_.delegate = self;
    pasteViewController_.view.frame = NSMakeRect(20,
                                                 view.frame.size.height - pasteViewController_.view.frame.size.height,
                                                 pasteViewController_.view.frame.size.width,
                                                 pasteViewController_.view.frame.size.height);
    [view addSubview:pasteViewController_.view];
    [pasteViewController_ updateFrame];
}

- (void)hidePasteUI {
    [pasteViewController_ close];
    [pasteViewController_ release];
    pasteViewController_ = nil;
}

- (void)updatePasteUI {
    [pasteViewController_ setRemainingLength:slowPasteBuffer.length];
}

- (NSData *)dataByRemovingControlCodes:(NSData *)data {
    NSMutableData *output = [NSMutableData dataWithCapacity:[data length]];
    const unsigned char *p = data.bytes;
    int start = 0;
    int i = 0;
    for (i = 0; i < data.length; i++) {
        if (p[i] < ' ' && p[i] != '\n' && p[i] != '\r' && p[i] != '\t' && p[i] != 12) {
            if (i > start) {
                [output appendBytes:p + start length:i - start];
            }
            start = i + 1;
        }
    }
    if (i > start) {
        [output appendBytes:p + start length:i - start];
    }
    return output;
}

- (void)_pasteStringImmediately:(NSString*)aString
{
    if ([aString length] > 0) {
        NSData *data = [aString dataUsingEncoding:[TERMINAL encoding]
                             allowLossyConversion:YES];
        NSData *safeData = [self dataByRemovingControlCodes:data];
        [self writeTask:safeData];

    }
}

- (void)_pasteAgain {
    NSRange range;
    range.location = 0;
    range.length = MIN(pasteContext_.bytesPerCall, [slowPasteBuffer length]);
    [self _pasteStringImmediately:[slowPasteBuffer substringWithRange:range]];
    [slowPasteBuffer deleteCharactersInRange:range];
    [self updatePasteUI];
    if ([slowPasteBuffer length] > 0) {
        [pasteContext_ updateValues];
        slowPasteTimer = [NSTimer scheduledTimerWithTimeInterval:pasteContext_.delayBetweenCalls
                                                          target:self
                                                        selector:@selector(_pasteAgain)
                                                        userInfo:nil
                                                         repeats:NO];
    } else {
        if ([TERMINAL bracketedPasteMode]) {
            [self writeTask:[[NSString stringWithFormat:@"%c[201~", 27]
                             dataUsingEncoding:[TERMINAL encoding]
                             allowLossyConversion:YES]];
        }
        slowPasteTimer = nil;
        [self hidePasteUI];
        [pasteContext_ release];
        pasteContext_ = nil;
        [self emptyEventQueue];
    }
}

- (void)_pasteWithBytePerCallPrefKey:(NSString*)bytesPerCallKey
                        defaultValue:(int)bytesPerCallDefault
            delayBetweenCallsPrefKey:(NSString*)delayBetweenCallsKey
                        defaultValue:(float)delayBetweenCallsDefault
{
    [pasteContext_ release];
    pasteContext_ = [[PasteContext alloc] initWithBytesPerCallPrefKey:bytesPerCallKey
                                                         defaultValue:bytesPerCallDefault
                                             delayBetweenCallsPrefKey:delayBetweenCallsKey
                                                         defaultValue:delayBetweenCallsDefault];
    const int kPasteBytesPerSecond = 10000;  // This is a wild-ass guess.
    if (pasteContext_.delayBetweenCalls * slowPasteBuffer.length / pasteContext_.bytesPerCall + slowPasteBuffer.length / kPasteBytesPerSecond > 3) {
        [self showPasteUI];
    }

    [self _pasteAgain];
}

// Outputs 16 bytes every 125ms so that clients that don't buffer input can handle pasting large buffers.
// Override the constants by setting defaults SlowPasteBytesPerCall and SlowPasteDelayBetweenCalls
- (void)_pasteSlowly:(id)sender
{
    [self _pasteWithBytePerCallPrefKey:@"SlowPasteBytesPerCall"
                          defaultValue:16
              delayBetweenCallsPrefKey:@"SlowPasteDelayBetweenCalls"
                          defaultValue:0.125];
}

- (void)_pasteStringMore
{
    [self _pasteWithBytePerCallPrefKey:@"QuickPasteBytesPerCall"
                          defaultValue:1024
              delayBetweenCallsPrefKey:@"QuickPasteDelayBetweenCalls"
                          defaultValue:0.01];
}

- (void)_pasteString:(NSString *)aString
{
    if ([aString length] > 0) {
        // This is the "normal" way of pasting. It's fast but tends not to
        // outrun a shell's ability to read from its buffer. Why this crazy
        // thing? See bug 1031.
        [slowPasteBuffer appendString:[aString stringWithLinefeedNewlines]];
        [self _pasteStringMore];
    } else {
        NSBeep();
    }
}

- (void)pasteString:(NSString *)aString
{
    if (![self maybeWarnAboutMultiLinePaste:aString]) {
        return;
    }
    if ([TERMINAL bracketedPasteMode]) {
        [self writeTask:[[NSString stringWithFormat:@"%c[200~", 27]
                         dataUsingEncoding:[TERMINAL encoding]
                         allowLossyConversion:YES]];
    }
    [self _pasteString:aString];
}

- (void)deleteBackward:(id)sender
{
    unsigned char p = 0x08; // Ctrl+H

    [self writeTask:[NSData dataWithBytes:&p length:1]];
}

- (void)deleteForward:(id)sender
{
    unsigned char p = 0x7F; // DEL

    [self writeTask:[NSData dataWithBytes:&p length:1]];
}

- (void)textViewDidChangeSelection:(NSNotification *) aNotification
{
    if ([[PreferencePanel sharedInstance] copySelection]) {
        [TEXTVIEW copySelectionAccordingToUserPreferences];
    }
}

- (PTYScroller *)textViewVerticalScroller
{
    return (PTYScroller *)[SCROLLVIEW verticalScroller];
}

- (BOOL)textViewHasCoprocess {
    return [SHELL hasCoprocess];
}

- (void) textViewResized:(NSNotification *) aNotification;
{
    int w;
    int h;

    w = (int)(([[SCROLLVIEW contentView] frame].size.width - MARGIN * 2) / [TEXTVIEW charWidth]);
    h = (int)(([[SCROLLVIEW contentView] frame].size.height) / [TEXTVIEW lineHeight]);
    //NSLog(@"%s: w = %d; h = %d; old w = %d; old h = %d", __PRETTY_FUNCTION__, w, h, [SCREEN width], [SCREEN height]);

    [self setWidth:w height:h];
}

- (BOOL) bell
{
    return bell;
}

- (void)setBell:(BOOL)flag
{
    if (flag != bell) {
        bell = flag;
        [[self tab] setBell:flag];
        if (bell) {
            if ([TEXTVIEW keyIsARepeat] == NO &&
                ![[TEXTVIEW window] isKeyWindow] &&
                SCREEN.postGrowlNotifications) {
                [gd growlNotify:NSLocalizedStringFromTableInBundle(@"Bell",
                                                                   @"iTerm",
                                                                   [NSBundle bundleForClass:[self class]],
                                                                   @"Growl Alerts")
                withDescription:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Session %@ #%d just rang a bell!",
                                                                                              @"iTerm",
                                                                                              [NSBundle bundleForClass:[self class]],
                                                                                              @"Growl Alerts"),
                                 [self name],
                                 [[self tab] realObjectCount]]
                andNotification:@"Bells"
                    windowIndex:[self screenWindowIndex]
                       tabIndex:[self screenTabIndex]
                      viewIndex:[self screenViewIndex]];
            }
        }
    }
}

- (NSString*)ansiColorsMatchingForeground:(NSDictionary*)fg andBackground:(NSDictionary*)bg inBookmark:(Profile*)aDict
{
    NSColor *fgColor;
    NSColor *bgColor;
    fgColor = [ITAddressBookMgr decodeColor:fg];
    bgColor = [ITAddressBookMgr decodeColor:bg];

    int bgNum = -1;
    int fgNum = -1;
    for(int i = 0; i < 16; ++i) {
        NSString* key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, i];
        if ([fgColor isEqual:[ITAddressBookMgr decodeColor:[aDict objectForKey:key]]]) {
            fgNum = i;
        }
        if ([bgColor isEqual:[ITAddressBookMgr decodeColor:[aDict objectForKey:key]]]) {
            bgNum = i;
        }
    }

    if (bgNum < 0 || fgNum < 0) {
        return nil;
    }

    return ([[NSString alloc] initWithFormat:@"%d;%d", fgNum, bgNum]);
}

- (void)loadInitialColorTable
{
    int i;
    for (i = 0; i < 216; i++) {
        [self setColorTable:i+16
                      color:[NSColor colorWithCalibratedRed:(i/36) ? ((i/36)*40+55)/255.0 : 0
                                                      green:(i%36)/6 ? (((i%36)/6)*40+55)/255.0:0
                                                       blue:(i%6) ?((i%6)*40+55)/255.0:0
                                                      alpha:1]];
    }
    for (i = 0; i < 24; i++) {
        [self setColorTable:i+232 color:[NSColor colorWithCalibratedWhite:(i*10+8)/255.0 alpha:1]];
    }
}

- (void)setPreferencesFromAddressBookEntry:(NSDictionary *)aePrefs
{
    NSColor *colorTable[2][8];
    int i;
    NSDictionary *aDict;

    aDict = aePrefs;
    if (aDict == nil) {
        aDict = [[ProfileModel sharedInstance] defaultBookmark];
    }
    if (aDict == nil) {
        return;
    }

    [self setForegroundColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_FOREGROUND_COLOR]]];
    [self setBackgroundColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_BACKGROUND_COLOR]]];
    [self setSelectionColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_SELECTION_COLOR]]];
    [self setSelectedTextColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_SELECTED_TEXT_COLOR]]];
    [self setBoldColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_BOLD_COLOR]]];
    [self setCursorColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_CURSOR_COLOR]]];
    [self setCursorTextColor:[ITAddressBookMgr decodeColor:[aDict objectForKey:KEY_CURSOR_TEXT_COLOR]]];
    BOOL scc;
    if ([aDict objectForKey:KEY_SMART_CURSOR_COLOR]) {
        scc = [[aDict objectForKey:KEY_SMART_CURSOR_COLOR] boolValue];
    } else {
        scc = [[PreferencePanel sharedInstance] legacySmartCursorColor];
    }
    [self setSmartCursorColor:scc];

    float mc;
    if ([aDict objectForKey:KEY_MINIMUM_CONTRAST]) {
        mc = [[aDict objectForKey:KEY_MINIMUM_CONTRAST] floatValue];
    } else {
        mc = [[PreferencePanel sharedInstance] legacyMinimumContrast];
    }
    [self setMinimumContrast:mc];

    for (i = 0; i < 8; i++) {
        colorTable[0][i] = [ITAddressBookMgr decodeColor:[aDict objectForKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, i]]];
        colorTable[1][i] = [ITAddressBookMgr decodeColor:[aDict objectForKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, i + 8]]];
    }
    for(i = 0; i < 8; i++) {
        [self setColorTable:i color:colorTable[0][i]];
        [self setColorTable:i+8 color:colorTable[1][i]];
    }

    // background image
    [self setBackgroundImagePath:[aDict objectForKey:KEY_BACKGROUND_IMAGE_LOCATION]];
    [self setBackgroundImageTiled:[[aDict objectForKey:KEY_BACKGROUND_IMAGE_TILED] boolValue]];

    // colour scheme
    [self setCOLORFGBG_VALUE:[self ansiColorsMatchingForeground:[aDict objectForKey:KEY_FOREGROUND_COLOR]
                                                  andBackground:[aDict objectForKey:KEY_BACKGROUND_COLOR]
                                                     inBookmark:aDict]];

    // transparency
    [self setTransparency:[[aDict objectForKey:KEY_TRANSPARENCY] floatValue]];
    [self setBlend:[[aDict objectForKey:KEY_BLEND] floatValue]];

    // bold
    NSNumber* useBoldFontEntry = [aDict objectForKey:KEY_USE_BOLD_FONT];
    NSNumber* disableBoldEntry = [aDict objectForKey:KEY_DISABLE_BOLD];
    if (useBoldFontEntry) {
        [self setUseBoldFont:[useBoldFontEntry boolValue]];
    } else if (disableBoldEntry) {
        // Only deprecated option is set.
        [self setUseBoldFont:![disableBoldEntry boolValue]];
    } else {
        [self setUseBoldFont:YES];
    }
    [TEXTVIEW setUseBrightBold:[aDict objectForKey:KEY_USE_BRIGHT_BOLD] ? [[aDict objectForKey:KEY_USE_BRIGHT_BOLD] boolValue] : YES];

    // italic
    [self setUseItalicFont:[[aDict objectForKey:KEY_USE_ITALIC_FONT] boolValue]];

    // set up the rest of the preferences
    [SCREEN setAudibleBell:![[aDict objectForKey:KEY_SILENCE_BELL] boolValue]];
    [SCREEN setShowBellIndicator:[[aDict objectForKey:KEY_VISUAL_BELL] boolValue]];
    [SCREEN setFlashBell:[[aDict objectForKey:KEY_FLASHING_BELL] boolValue]];
    [SCREEN setPostGrowlNotifications:[[aDict objectForKey:KEY_BOOKMARK_GROWL_NOTIFICATIONS] boolValue]];
    [SCREEN setCursorBlinks:[[aDict objectForKey:KEY_BLINKING_CURSOR] boolValue]];
    [TEXTVIEW setBlinkAllowed:[[aDict objectForKey:KEY_BLINK_ALLOWED] boolValue]];
    [TEXTVIEW setBlinkingCursor:[[aDict objectForKey:KEY_BLINKING_CURSOR] boolValue]];
    [TEXTVIEW setCursorType:([aDict objectForKey:KEY_CURSOR_TYPE] ? [[aDict objectForKey:KEY_CURSOR_TYPE] intValue] : [[PreferencePanel sharedInstance] legacyCursorType])];

    PTYTab* currentTab = [[[self tab] parentWindow] currentTab];
    if (currentTab == nil || currentTab == [self tab]) {
        [[self tab] recheckBlur];
    }
    BOOL asciiAA;
    BOOL nonasciiAA;
    if ([aDict objectForKey:KEY_ASCII_ANTI_ALIASED]) {
        asciiAA = [[aDict objectForKey:KEY_ASCII_ANTI_ALIASED] boolValue];
    } else {
        asciiAA = [[aDict objectForKey:KEY_ANTI_ALIASING] boolValue];
    }
    if ([aDict objectForKey:KEY_NONASCII_ANTI_ALIASED]) {
        nonasciiAA = [[aDict objectForKey:KEY_NONASCII_ANTI_ALIASED] boolValue];
    } else {
        nonasciiAA = [[aDict objectForKey:KEY_ANTI_ALIASING] boolValue];
    }
    [triggers_ release];
    triggers_ = [[NSMutableArray alloc] init];
    for (NSDictionary *triggerDict in [aDict objectForKey:KEY_TRIGGERS]) {
        Trigger *trigger = [Trigger triggerFromDict:triggerDict];
        if (trigger) {
            [triggers_ addObject:trigger];
        }
    }
    [TEXTVIEW setSmartSelectionRules:[aDict objectForKey:KEY_SMART_SELECTION_RULES]];
    [TEXTVIEW setTrouterPrefs:[aDict objectForKey:KEY_TROUTER]];
    [TEXTVIEW setUseNonAsciiFont:[[aDict objectForKey:KEY_USE_NONASCII_FONT] boolValue]];
    [TEXTVIEW setAntiAlias:asciiAA nonAscii:nonasciiAA];
    [self setEncoding:[[aDict objectForKey:KEY_CHARACTER_ENCODING] unsignedIntValue]];
    [self setTERM_VALUE:[aDict objectForKey:KEY_TERMINAL_TYPE]];
    [self setAntiCode:[[aDict objectForKey:KEY_IDLE_CODE] intValue]];
    [self setAntiIdle:[[aDict objectForKey:KEY_SEND_CODE_WHEN_IDLE] boolValue]];
    [self setAutoClose:[[aDict objectForKey:KEY_CLOSE_SESSIONS_ON_END] boolValue]];
    [self setDoubleWidth:[[aDict objectForKey:KEY_AMBIGUOUS_DOUBLE_WIDTH] boolValue]];
    [self setXtermMouseReporting:[[aDict objectForKey:KEY_XTERM_MOUSE_REPORTING] boolValue]];
    [TERMINAL setDisableSmcupRmcup:[[aDict objectForKey:KEY_DISABLE_SMCUP_RMCUP] boolValue]];
    [SCREEN setAllowTitleReporting:[[aDict objectForKey:KEY_ALLOW_TITLE_REPORTING] boolValue]];
    [TERMINAL setAllowKeypadMode:[[aDict objectForKey:KEY_APPLICATION_KEYPAD_ALLOWED] boolValue]];
    [TERMINAL setUseCanonicalParser:[[aDict objectForKey:KEY_USE_CANONICAL_PARSER] boolValue]];
    [SCREEN setUnlimitedScrollback:[[aDict objectForKey:KEY_UNLIMITED_SCROLLBACK] intValue]];
    [SCREEN setMaxScrollbackLines:[[aDict objectForKey:KEY_SCROLLBACK_LINES] intValue]];

    [self setFont:[ITAddressBookMgr fontWithDesc:[aDict objectForKey:KEY_NORMAL_FONT]]
           nafont:[ITAddressBookMgr fontWithDesc:[aDict objectForKey:KEY_NON_ASCII_FONT]]
        horizontalSpacing:[[aDict objectForKey:KEY_HORIZONTAL_SPACING] floatValue]
        verticalSpacing:[[aDict objectForKey:KEY_VERTICAL_SPACING] floatValue]];
    [SCREEN setSaveToScrollbackInAlternateScreen:[aDict objectForKey:KEY_SCROLLBACK_IN_ALTERNATE_SCREEN] ? [[aDict objectForKey:KEY_SCROLLBACK_IN_ALTERNATE_SCREEN] boolValue] : YES];
    [[tab_ realParentWindow] invalidateRestorableState];
}

- (NSString *)uniqueID
{
    return ([self tty]);
}

- (void)setUniqueID:(NSString*)uniqueID
{
    NSLog(@"Not allowed to set unique ID");
}

- (NSString*)formattedName:(NSString*)base
{
    NSString *prefix = tmuxController_ ? [NSString stringWithFormat:@"↣ %@: ", [[self tab] tmuxWindowName]] : @"";

    BOOL baseIsBookmarkName = [base isEqualToString:bookmarkName];
    PreferencePanel* panel = [PreferencePanel sharedInstance];
    if ([panel jobName] && jobName_) {
        if (baseIsBookmarkName && ![panel showBookmarkName]) {
            return [NSString stringWithFormat:@"%@%@", prefix, [self jobName]];
        } else {
            return [NSString stringWithFormat:@"%@%@ (%@)", prefix, base, [self jobName]];
        }
    } else {
        if (baseIsBookmarkName && ![panel showBookmarkName]) {
            return [NSString stringWithFormat:@"%@Shell", prefix];
        } else {
            return [NSString stringWithFormat:@"%@%@", prefix, base];
        }
    }
}

- (NSString*)defaultName
{
    return [self formattedName:defaultName];
}

- (NSString*)joblessDefaultName
{
    return defaultName;
}

- (void)setDefaultName:(NSString*)theName
{
    if ([defaultName isEqualToString:theName]) {
        return;
    }

    if (defaultName) {
        // clear the window title if it is not different
        if (windowTitle == nil || [name isEqualToString:windowTitle]) {
            windowTitle = nil;
        }
        [defaultName release];
        defaultName = nil;
    }
    if (!theName) {
        theName = NSLocalizedStringFromTableInBundle(@"Untitled",
                                                     @"iTerm",
                                                     [NSBundle bundleForClass:[self class]],
                                                     @"Profiles");
    }

    defaultName = [theName retain];
}

- (PTYTab*)tab
{
    return tab_;
}

- (PTYTab*)ptytab
{
    return tab_;
}

- (void)setTab:(PTYTab*)tab
{
    if ([self isTmuxClient]) {
        [tmuxController_ deregisterWindow:[tab_ tmuxWindow]
                               windowPane:tmuxPane_];
    }
    tab_ = tab;
    if ([self isTmuxClient]) {
        [tmuxController_ registerSession:self
                                withPane:tmuxPane_
                                inWindow:[tab_ tmuxWindow]];
    }
    [tmuxController_ fitLayoutToWindows];
}

- (struct timeval)lastOutput
{
    return lastOutput;
}

- (void)setGrowlIdle:(BOOL)value
{
    growlIdle = value;
}

- (BOOL)growlIdle
{
    return growlIdle;
}

- (void)setGrowlNewOutput:(BOOL)value
{
    growlNewOutput = value;
}

- (BOOL)growlNewOutput
{
    return growlNewOutput;
}

- (NSString *)windowName {
    return [[[self tab] realParentWindow] currentSessionName];
}

- (NSString*)name
{
    return [self formattedName:name];
}

- (NSString*)rawName
{
    return name;
}

- (void)setBookmarkName:(NSString*)theName
{
    [bookmarkName release];
    bookmarkName = [theName copy];
}

- (void)setName:(NSString*)theName
{
    [view setTitle:theName];
    if (!bookmarkName) {
        bookmarkName = [theName copy];
    }
    if ([name isEqualToString:theName]) {
        return;
    }

    if (name) {
        // clear the window title if it is not different
        if ([name isEqualToString:windowTitle]) {
            windowTitle = nil;
        }
        [name release];
        name = nil;
    }
    if (!theName) {
        theName = NSLocalizedStringFromTableInBundle(@"Untitled",
                                                     @"iTerm",
                                                     [NSBundle bundleForClass:[self class]],
                                                     @"Profiles");
    }

    name = [theName retain];
    // sync the window title if it is not set to something else
    if (windowTitle == nil) {
        [self setWindowTitle:theName];
    }

    [[self tab] nameOfSession:self didChangeTo:[self name]];
    [self setBell:NO];

    // get the session submenu to be rebuilt
    if ([[iTermController sharedInstance] currentTerminal] == [[self tab] parentWindow]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"iTermNameOfSessionDidChange"
                                                            object:[[self tab] parentWindow]
                                                          userInfo:nil];
    }
}

- (NSString*)windowTitle
{
    if (!windowTitle) {
        return nil;
    }
    return [self formattedName:windowTitle];
}

- (void)setWindowTitle:(NSString*)theTitle
{
    if ([theTitle isEqualToString:windowTitle]) {
        return;
    }

    [windowTitle autorelease];
    windowTitle = nil;

    if (theTitle != nil && [theTitle length] > 0) {
        windowTitle = [theTitle retain];
    }

    if ([[[self tab] parentWindow] currentTab] == [self tab]) {
        [[[self tab] parentWindow] setWindowTitle];
    }
}

- (void)pushWindowTitle
{
    if (!windowTitleStack) {
        // initialize lazily
        windowTitleStack = [[NSMutableArray alloc] init];
    }
    NSString *title = windowTitle;
    if (!title) {
        // if current title is nil, treat it as an empty string.
        title = @"";
    }
    // push it
    [windowTitleStack addObject:title];
}

- (void)popWindowTitle
{
    // Ignore if title stack is nil or stack count == 0
    NSUInteger count = [windowTitleStack count];
    if (count > 0) {
        // pop window title
        [self setWindowTitle:[windowTitleStack objectAtIndex:count - 1]];
        [windowTitleStack removeObjectAtIndex:count - 1];
    }
}

- (void)pushIconTitle
{
    if (!iconTitleStack) {
        // initialize lazily
        iconTitleStack = [[NSMutableArray alloc] init];
    }
    NSString *title = name;
    if (!title) {
        // if current icon title is nil, treat it as an empty string.
        title = @"";
    }
    // push it
    [iconTitleStack addObject:title];
}

- (void)popIconTitle
{
    // Ignore if icon title stack is nil or stack count == 0.
    NSUInteger count = [iconTitleStack count];
    if (count > 0) {
        // pop icon title
        [self setName:[iconTitleStack objectAtIndex:count - 1]];
        [iconTitleStack removeObjectAtIndex:count - 1];
    }
}

- (PTYTask *)SHELL
{
    return SHELL;
}

- (void)setSHELL:(PTYTask *)theSHELL
{
    [SHELL autorelease];
    SHELL = [theSHELL retain];
}

- (VT100Terminal *)TERMINAL
{
    return TERMINAL;
}

- (NSString *)TERM_VALUE
{
    return TERM_VALUE;
}

- (void)setTERM_VALUE:(NSString *)theTERM_VALUE
{
    [TERM_VALUE autorelease];
    TERM_VALUE = [theTERM_VALUE retain];
    [TERMINAL setTermType:theTERM_VALUE];
}

- (NSString *)COLORFGBG_VALUE
{
    return (COLORFGBG_VALUE);
}

- (void)setCOLORFGBG_VALUE:(NSString *)theCOLORFGBG_VALUE
{
    [COLORFGBG_VALUE autorelease];
    COLORFGBG_VALUE = [theCOLORFGBG_VALUE retain];
}

- (VT100Screen *)SCREEN
{
    return SCREEN;
}

- (void)setSCREEN:(VT100Screen *)theSCREEN
{
    [SCREEN autorelease];
    SCREEN = [theSCREEN retain];
}

- (SessionView *)view
{
    return view;
}

- (void)setView:(SessionView*)newView
{
    // View holds a reference to us so we don't hold a reference to it.
    view = newView;
    [[view findViewController] setDelegate:self];
}

- (PTYTextView *)TEXTVIEW
{
    return TEXTVIEW;
}

- (void)setTEXTVIEW:(PTYTextView *)theTEXTVIEW
{
    [TEXTVIEW autorelease];
    TEXTVIEW = [theTEXTVIEW retain];
}

- (void)setSCROLLVIEW:(PTYScrollView *)theSCROLLVIEW
{
    [SCROLLVIEW autorelease];
    SCROLLVIEW = [theSCROLLVIEW retain];
}

- (NSStringEncoding)encoding
{
    return [TERMINAL encoding];
}

- (void)setEncoding:(NSStringEncoding)encoding
{
    [TERMINAL setEncoding:encoding];
}


- (NSString *)tty
{
    return [SHELL tty];
}

- (NSString *)contents
{
    return [TEXTVIEW content];
}

- (BOOL)backgroundImageTiled
{
    return backgroundImageTiled;
}

- (void)setBackgroundImageTiled:(BOOL)set
{
    backgroundImageTiled = set;
    [self setBackgroundImagePath:backgroundImagePath];
}

- (NSString *)backgroundImagePath
{
    return backgroundImagePath;
}

- (void)setBackgroundImagePath:(NSString *)imageFilePath
{
    if ([imageFilePath length]) {
        [imageFilePath retain];
        [backgroundImagePath release];
        backgroundImagePath = nil;

        if ([imageFilePath isAbsolutePath] == NO) {
            NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
            backgroundImagePath = [myBundle pathForResource:imageFilePath ofType:@""];
            [imageFilePath release];
            [backgroundImagePath retain];
        } else {
            backgroundImagePath = imageFilePath;
        }
        NSImage *anImage = [[NSImage alloc] initWithContentsOfFile:backgroundImagePath];
        if (anImage != nil) {
            [SCROLLVIEW setDrawsBackground:NO];
            [SCROLLVIEW setBackgroundImage:anImage asPattern:[self backgroundImageTiled]];
            [anImage release];
        } else {
            [SCROLLVIEW setDrawsBackground:YES];
            [backgroundImagePath release];
            backgroundImagePath = nil;
        }
    } else {
        [SCROLLVIEW setDrawsBackground:YES];
        [SCROLLVIEW setBackgroundImage:nil];
        [backgroundImagePath release];
        backgroundImagePath = nil;
    }

    [TEXTVIEW setNeedsDisplay:YES];
}


- (NSColor *)foregroundColor
{
    return [TEXTVIEW defaultFGColor];
}

- (void)setForegroundColor:(NSColor*)color
{
    if (color == nil) {
        return;
    }

    if (([TEXTVIEW defaultFGColor] != color) ||
       ([[TEXTVIEW defaultFGColor] alphaComponent] != [color alphaComponent])) {
        // Change the fg color for future stuff
        [TEXTVIEW setFGColor:color];
    }
}

- (NSColor *)backgroundColor
{
    return [TEXTVIEW defaultBGColor];
}

- (void)setBackgroundColor:(NSColor*) color {
    if (color == nil) {
        return;
    }

    if (([TEXTVIEW defaultBGColor] != color) ||
        ([[TEXTVIEW defaultBGColor] alphaComponent] != [color alphaComponent])) {
        // Change the bg color for future stuff
        [TEXTVIEW setBGColor:color];
    }

    [[self SCROLLVIEW] setBackgroundColor:color];
}

- (NSColor *) boldColor
{
    return [TEXTVIEW defaultBoldColor];
}

- (void)setBoldColor:(NSColor*)color
{
    [[self TEXTVIEW] setBoldColor:color];
}

- (NSColor *)cursorColor
{
    return [TEXTVIEW defaultCursorColor];
}

- (void)setCursorColor:(NSColor*)color
{
    [[self TEXTVIEW] setCursorColor:color];
}

- (void)setSmartCursorColor:(BOOL)value
{
    [[self TEXTVIEW] setSmartCursorColor:value];
}

- (void)setMinimumContrast:(float)value
{
    [[self TEXTVIEW] setMinimumContrast:value];
}

- (NSColor *)selectionColor
{
    return [TEXTVIEW selectionColor];
}

- (void)setSelectionColor:(NSColor *)color
{
    [TEXTVIEW setSelectionColor:color];
}

- (NSColor *)selectedTextColor
{
    return [TEXTVIEW selectedTextColor];
}

- (void)setSelectedTextColor:(NSColor *)aColor
{
    [TEXTVIEW setSelectedTextColor:aColor];
}

- (NSColor *)cursorTextColor
{
    return [TEXTVIEW cursorTextColor];
}

- (void)setCursorTextColor:(NSColor *)aColor
{
    [TEXTVIEW setCursorTextColor:aColor];
}

// Changes transparency

- (float)transparency
{
    return [TEXTVIEW transparency];
}

- (float)blend
{
    return [TEXTVIEW blend];
}

- (void)setTransparency:(float)transparency
{
    // Limit transparency because fully transparent windows can't be clicked on.
    if (transparency > 0.9) {
        transparency = 0.9;
    }

    // set transparency of background image
    [SCROLLVIEW setTransparency:transparency];
    [TEXTVIEW setTransparency:transparency];
}

- (void)setBlend:(float)blendVal
{
    [TEXTVIEW setBlend:blendVal];
}

- (void)setColorTable:(int)theIndex color:(NSColor *)theColor
{
    [TEXTVIEW setColorTable:theIndex color:theColor];
}

- (BOOL)antiIdle
{
    return antiIdleTimer ? YES : NO;
}

- (int)antiCode
{
    return ai_code;
}

- (void)setAntiIdle:(BOOL)set
{
    if (set == [self antiIdle]) {
        return;
    }

    if (set) {
        antiIdleTimer = [[NSTimer scheduledTimerWithTimeInterval:30
                                                          target:self
                                                        selector:@selector(doAntiIdle)
                                                        userInfo:nil
                repeats:YES] retain];
    } else {
        [antiIdleTimer invalidate];
        [antiIdleTimer release];
        antiIdleTimer = nil;
    }
}

- (void)setAntiCode:(int)code
{
    ai_code = code;
}

- (BOOL)autoClose
{
    return autoClose;
}

- (void)setAutoClose:(BOOL)set
{
    autoClose = set;
}

- (BOOL)useBoldFont
{
    return [TEXTVIEW useBoldFont];
}

- (void)setUseBoldFont:(BOOL)boldFlag
{
    [TEXTVIEW setUseBoldFont:boldFlag];
}

- (BOOL)useItalicFont
{
    return [TEXTVIEW useItalicFont];
}

- (void)setUseItalicFont:(BOOL)italicFlag
{
    [TEXTVIEW setUseItalicFont:italicFlag];
}

- (BOOL)doubleWidth
{
    return doubleWidth;
}

- (void)setDoubleWidth:(BOOL)set
{
    doubleWidth = set;
    tmuxController_.ambiguousIsDoubleWidth = set;
}

- (void)setXtermMouseReporting:(BOOL)set
{
    xtermMouseReporting = set;
    [TEXTVIEW updateCursor:[NSApp currentEvent]];
}

- (BOOL)logging
{
    return [SHELL logging];
}

- (void)logStart
{
    NSSavePanel *panel;
    int sts;

    panel = [NSSavePanel savePanel];
    // Session could end before panel is dismissed.
    [[self retain] autorelease];
    panel.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    panel.nameFieldStringValue = @"";
    sts = [panel runModal];
    if (sts == NSOKButton) {
        BOOL logsts = [SHELL loggingStartWithPath:panel.URL.path];
        if (logsts == NO) {
            NSBeep();
        }
    }
}

- (void)logStop
{
    [SHELL loggingStop];
}

- (void)clearBuffer
{
    [SCREEN clearBuffer];
}

- (void)clearScrollbackBuffer
{
    [SCREEN clearScrollbackBuffer];
}

- (BOOL)exited
{
    return EXIT;
}

- (BOOL)shouldSendEscPrefixForModifier:(unsigned int)modmask
{
    if ([self optionKey] == OPT_ESC) {
        if ((modmask == NSAlternateKeyMask) ||
            (modmask & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask) {
            return YES;
        }
    }
    if ([self rightOptionKey] == OPT_ESC) {
        if ((modmask & NSRightAlternateKeyMask) == NSRightAlternateKeyMask) {
            return YES;
        }
    }
    return NO;
}

- (void)setSendModifiers:(NSArray *)sendModifiers {
    [sendModifiers_ autorelease];
    sendModifiers_ = [sendModifiers retain];
    // TODO(georgen): Actually use this. It's not well documented and the xterm code is a crazy mess :(.
    // For future reference, in tmux commit 8df3ec612a8c496fc2c975b8241f4e95faef5715 the list of xterm
    // keys gives a hint about how this is supposed to work (e.g., control-! sends a long CSI code). See also
    // the xterm manual (look for modifyOtherKeys, etc.) for valid values, and ctlseqs.html on invisible-island
    // for the meaning of the indices (under CSI > Ps; Pm m).
}

- (void)setAddressBookEntry:(NSDictionary*)entry
{
    NSMutableDictionary *dict = [[entry mutableCopy] autorelease];
    // This is the most practical way to migrate the bopy of a
    // profile that's stored in a saved window arrangement. It doesn't get
    // saved back into the arrangement, unfortunately.
    [ProfileModel migratePromptOnCloseInMutableBookmark:dict];

    NSString *originalGuid = [entry objectForKey:KEY_ORIGINAL_GUID];
    if (originalGuid) {
        // This code path is taken when changing an existing session's profile.
        // See bug 2632.
        Profile *possibleOriginalProfile = [[ProfileModel sharedInstance] bookmarkWithGuid:originalGuid];
        if (possibleOriginalProfile) {
            [originalAddressBookEntry autorelease];
            originalAddressBookEntry = [possibleOriginalProfile copy];
        }
    }
    if (!originalAddressBookEntry) {
        // This is normally taken when a new session is being created.
        originalAddressBookEntry = [NSDictionary dictionaryWithDictionary:dict];
        [originalAddressBookEntry retain];
    }
    [addressBookEntry release];
    addressBookEntry = [dict retain];
    [[tab_ realParentWindow] invalidateRestorableState];
}

- (NSDictionary *)addressBookEntry
{
    return addressBookEntry;
}

- (NSDictionary *)originalAddressBookEntry
{
    return originalAddressBookEntry;
}

- (iTermGrowlDelegate*)growlDelegate
{
    return gd;
}

- (void)sendCommand:(NSString *)command
{
    NSData *data = nil;
    NSString *aString = nil;

    if (command != nil) {
        aString = [NSString stringWithFormat:@"%@\n", command];
        data = [aString dataUsingEncoding:[TERMINAL encoding]];
    }

    if (data != nil) {
        [self writeTask:data];
    }
}

- (NSDictionary*)arrangement
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:3];
    [result setObject:[NSNumber numberWithInt:[SCREEN width]] forKey:SESSION_ARRANGEMENT_COLUMNS];
    [result setObject:[NSNumber numberWithInt:[SCREEN height]] forKey:SESSION_ARRANGEMENT_ROWS];
    [result setObject:addressBookEntry forKey:SESSION_ARRANGEMENT_BOOKMARK];
    result[SESSION_ARRANGEMENT_BOOKMARK_NAME] = bookmarkName;
    NSString* pwd = [SHELL getWorkingDirectory];
    [result setObject:pwd ? pwd : @"" forKey:SESSION_ARRANGEMENT_WORKING_DIRECTORY];
    return result;
}

+ (NSDictionary *)arrangementFromTmuxParsedLayout:(NSDictionary *)parseNode
                                         bookmark:(Profile *)bookmark
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:3];
    [result setObject:[parseNode objectForKey:kLayoutDictWidthKey] forKey:SESSION_ARRANGEMENT_COLUMNS];
    [result setObject:[parseNode objectForKey:kLayoutDictHeightKey] forKey:SESSION_ARRANGEMENT_ROWS];
    [result setObject:bookmark forKey:SESSION_ARRANGEMENT_BOOKMARK];
    result[SESSION_ARRANGEMENT_BOOKMARK_NAME] = [bookmark objectForKey:KEY_NAME];
    [result setObject:@"" forKey:SESSION_ARRANGEMENT_WORKING_DIRECTORY];
    [result setObject:[parseNode objectForKey:kLayoutDictWindowPaneKey] forKey:SESSION_ARRANGEMENT_TMUX_PANE];
    NSObject *value = [parseNode objectForKey:kLayoutDictHistoryKey];
    if (value) {
        [result setObject:value forKey:SESSION_ARRANGEMENT_TMUX_HISTORY];
    }
    value = [parseNode objectForKey:kLayoutDictAltHistoryKey];
    if (value) {
        [result setObject:value forKey:SESSION_ARRANGEMENT_TMUX_ALT_HISTORY];
    }
    value = [parseNode objectForKey:kLayoutDictStateKey];
    if (value) {
        [result setObject:value forKey:SESSION_ARRANGEMENT_TMUX_STATE];
    }

    return result;
}

- (void)updateScroll
{
    if (![(PTYScroller*)([SCROLLVIEW verticalScroller]) userScroll]) {
        [TEXTVIEW scrollEnd];
    }
}

static long long timeInTenthsOfSeconds(struct timeval t)
{
    return t.tv_sec * 10 + t.tv_usec / 100000;
}

- (void)updateDisplay
{
    timerRunning_ = YES;
    BOOL anotherUpdateNeeded = [NSApp isActive];
    if (!anotherUpdateNeeded &&
        updateDisplayUntil_ &&
        [[NSDate date] timeIntervalSinceDate:updateDisplayUntil_] < 0) {
        // We're still in the time window after the last output where updates are needed.
        anotherUpdateNeeded = YES;
    }

    BOOL isForegroundTab = [[self tab] isForegroundTab];
    if (!isForegroundTab) {
        // Set color, other attributes of a background tab.
        anotherUpdateNeeded |= [[self tab] setLabelAttributes];
    }
    if ([[self tab] activeSession] == self) {
        // Update window info for the active tab.
        struct timeval now;
        gettimeofday(&now, NULL);
        if (!jobName_ ||
            timeInTenthsOfSeconds(now) >= timeInTenthsOfSeconds(lastUpdate) + 7) {
            // It has been more than 700ms since the last time we were here or
            // the job doesn't have a name
            if (isForegroundTab && [[[self tab] parentWindow] tempTitle]) {
                // Revert to the permanent tab title.
                [[[self tab] parentWindow] setWindowTitle];
                [[[self tab] parentWindow] resetTempTitle];
            } else {
                // Update the job name in the tab title.
                NSString* oldName = jobName_;
                jobName_ = [[SHELL currentJob:NO] copy];
                if (![oldName isEqualToString:jobName_]) {
                    [[self tab] nameOfSession:self didChangeTo:[self name]];
                    [[[self tab] parentWindow] setWindowTitle];
                }
                [oldName release];
            }
            lastUpdate = now;
        } else if (timeInTenthsOfSeconds(now) < timeInTenthsOfSeconds(lastUpdate) + 7) {
            // If it's been less than 700ms keep updating.
            anotherUpdateNeeded = YES;
        }
    }

    anotherUpdateNeeded |= [TEXTVIEW refresh];
    anotherUpdateNeeded |= [[[self tab] parentWindow] tempTitle];

    if (anotherUpdateNeeded) {
        if ([[[self tab] parentWindow] currentTab] == [self tab]) {
            [self scheduleUpdateIn:[[PreferencePanel sharedInstance] timeBetweenBlinks]];
        } else {
            [self scheduleUpdateIn:kBackgroundSessionIntervalSec];
        }
    } else {
        [updateTimer release];
        updateTimer = nil;
    }

    if (tailFindTimer_ && [[[view findViewController] view] isHidden]) {
        [self stopTailFind];
    }
    timerRunning_ = NO;
}

- (void)refreshAndStartTimerIfNeeded
{
    if ([TEXTVIEW refresh]) {
        [self scheduleUpdateIn:[[PreferencePanel sharedInstance] timeBetweenBlinks]];
    }
}

- (void)scheduleUpdateIn:(NSTimeInterval)timeout
{
    if (EXIT) {
        return;
    }
    float kEpsilon = 0.001;
    if (!timerRunning_ &&
        [updateTimer isValid] &&
        [[updateTimer userInfo] floatValue] - (float)timeout < kEpsilon) {
        // An update of at least the current frequency is already scheduled. Let
        // it run to avoid pushing it back repeatedly (which prevents it from firing).
        return;
    }

    [updateTimer invalidate];
    [updateTimer release];

    updateTimer = [[NSTimer scheduledTimerWithTimeInterval:timeout
                                                    target:self
                                                  selector:@selector(updateDisplay)
                                                  userInfo:[NSNumber numberWithFloat:(float)timeout]
                                                   repeats:NO] retain];
}

- (void)doAntiIdle
{
    struct timeval now;
    gettimeofday(&now, NULL);

    if (now.tv_sec >= lastInput.tv_sec+60) {
        [SHELL writeTask:[NSData dataWithBytes:&ai_code length:1]];
        lastInput = now;
    }
}

- (BOOL)canInstantReplayPrev
{
    if (dvrDecoder_) {
        return [dvrDecoder_ timestamp] != [dvr_ firstTimeStamp];
    } else {
        return YES;
    }
}

- (BOOL)canInstantReplayNext
{
    if (dvrDecoder_) {
        return YES;
    } else {
        return NO;
    }
}

- (int)rows
{
    return [SCREEN height];
}

- (int)columns
{
    return [SCREEN width];
}

- (NSFont*)fontWithRelativeSize:(int)dir from:(NSFont*)font
{
    int newSize = [font pointSize] + dir;
    if (newSize < 2) {
        newSize = 2;
    }
    if (newSize > 200) {
        newSize = 200;
    }
    return [NSFont fontWithName:[font fontName] size:newSize];
}

- (void)setFont:(NSFont*)font
         nafont:(NSFont*)nafont
    horizontalSpacing:(float)horizontalSpacing
    verticalSpacing:(float)verticalSpacing
{
    DLog(@"setFont:%@ nafont:%@", font, nafont);
    NSWindow *window = [[[self tab] realParentWindow] window];
    DLog(@"Before:\n%@", [window.contentView iterm_recursiveDescription]);
    DLog(@"Window frame: %@", window);
    if ([[TEXTVIEW font] isEqualTo:font] &&
        [[TEXTVIEW nafont] isEqualTo:nafont] &&
        [TEXTVIEW horizontalSpacing] == horizontalSpacing &&
        [TEXTVIEW verticalSpacing] == verticalSpacing) {
        return;
    }
    DLog(@"Line height was %f", (float)[TEXTVIEW lineHeight]);
    [TEXTVIEW setFont:font nafont:nafont horizontalSpacing:horizontalSpacing verticalSpacing:verticalSpacing];
    DLog(@"Line height is now %f", (float)[TEXTVIEW lineHeight]);
    if (![[[self tab] parentWindow] anyFullScreen]) {
        if ([[PreferencePanel sharedInstance] adjustWindowForFontSizeChange]) {
            [[[self tab] parentWindow] fitWindowToTab:[self tab]];
        }
    }
    // If the window isn't able to adjust, or adjust enough, make the session
    // work with whatever size we ended up having.
    if ([self isTmuxClient]) {
        [tmuxController_ windowDidResize:[[self tab] realParentWindow]];
    } else {
        [[self tab] fitSessionToCurrentViewSize:self];
    }
    DLog(@"After:\n%@", [window.contentView iterm_recursiveDescription]);
    DLog(@"Window frame: %@", window);
}

- (void)synchronizeTmuxFonts:(NSNotification *)notification
{
    if (!EXIT && [self isTmuxClient]) {
        NSArray *fonts = [notification object];
        NSFont *font = [fonts objectAtIndex:0];
        NSFont *nafont = [fonts objectAtIndex:1];
        NSNumber *hSpacing = [fonts objectAtIndex:2];
        NSNumber *vSpacing = [fonts objectAtIndex:3];
        [TEXTVIEW setFont:font
                   nafont:nafont
            horizontalSpacing:[hSpacing doubleValue]
            verticalSpacing:[vSpacing doubleValue]];
    }
}

- (void)notifyTmuxFontChange
{
    static BOOL fontChangeNotificationInProgress;
    if (!fontChangeNotificationInProgress) {
        fontChangeNotificationInProgress = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:kTmuxFontChanged
                                                            object:[NSArray arrayWithObjects:[TEXTVIEW font],
                                                                    [TEXTVIEW nafont],
                                                                    [NSNumber numberWithDouble:[TEXTVIEW horizontalSpacing]],
                                                                    [NSNumber numberWithDouble:[TEXTVIEW verticalSpacing]],
                                                                    nil]];
        fontChangeNotificationInProgress = NO;
        [PTYTab setTmuxFont:[TEXTVIEW font]
                     nafont:[TEXTVIEW nafont]
                   hSpacing:[TEXTVIEW horizontalSpacing]
                   vSpacing:[TEXTVIEW verticalSpacing]];
        [[NSNotificationCenter defaultCenter] postNotificationName:kPTYSessionTmuxFontDidChange
                                                            object:nil];
    }
}

- (void)setIgnoreResizeNotifications:(BOOL)ignore
{
    ignoreResizeNotifications_ = ignore;
}

- (BOOL)ignoreResizeNotifications
{
    return ignoreResizeNotifications_;
}

- (void)changeFontSizeDirection:(int)dir
{
    DLog(@"changeFontSizeDirection:%d", dir);
    NSFont* font;
    NSFont* nafont;
    float hs, vs;
    if (dir) {
        // Grow or shrink
        DLog(@"grow/shrink");
        font = [self fontWithRelativeSize:dir from:[TEXTVIEW font]];
        nafont = [self fontWithRelativeSize:dir from:[TEXTVIEW nafont]];
        hs = [TEXTVIEW horizontalSpacing];
        vs = [TEXTVIEW verticalSpacing];
    } else {
        // Restore original font size.
        NSDictionary *abEntry = [self originalAddressBookEntry];
        NSString* fontDesc = [abEntry objectForKey:KEY_NORMAL_FONT];
        font = [ITAddressBookMgr fontWithDesc:fontDesc];
        nafont = [ITAddressBookMgr fontWithDesc:[abEntry objectForKey:KEY_NON_ASCII_FONT]];
        hs = [[abEntry objectForKey:KEY_HORIZONTAL_SPACING] floatValue];
        vs = [[abEntry objectForKey:KEY_VERTICAL_SPACING] floatValue];
    }
    [self setFont:font nafont:nafont horizontalSpacing:hs verticalSpacing:vs];

    if (dir || isDivorced) {
        // Move this bookmark into the sessions model.
        NSString* guid = [self divorceAddressBookEntryFromPreferences];

        // Set the font in the bookmark dictionary
        NSMutableDictionary* temp = [NSMutableDictionary dictionaryWithDictionary:addressBookEntry];
        [temp setObject:[ITAddressBookMgr descFromFont:font] forKey:KEY_NORMAL_FONT];
        [temp setObject:[ITAddressBookMgr descFromFont:nafont] forKey:KEY_NON_ASCII_FONT];

        // Update this session's copy of the bookmark
        [self setAddressBookEntry:[NSDictionary dictionaryWithDictionary:temp]];

        // Update the model's copy of the bookmark.
        [[ProfileModel sessionsInstance] setBookmark:[self addressBookEntry] withGuid:guid];

        // Update an existing one-bookmark prefs dialog, if open.
        if ([[[PreferencePanel sessionsInstance] window] isVisible]) {
            [[PreferencePanel sessionsInstance] underlyingBookmarkDidChange];
        }
    }
}

- (void)remarry
{
    isDivorced = NO;
}

- (NSString*)divorceAddressBookEntryFromPreferences
{
    Profile* bookmark = [self addressBookEntry];
    NSString* guid = [bookmark objectForKey:KEY_GUID];
    if (isDivorced && [[ProfileModel sessionsInstance] bookmarkWithGuid:guid]) {
        // Once, I saw a case where an already-divorced bookmark's guid was missing from
        // sessionsInstance. I don't know why, but if that's the case, just create it there
        // again. :(
        return guid;
    }
    isDivorced = YES;
    [[ProfileModel sessionsInstance] removeBookmarkWithGuid:guid];
    [[ProfileModel sessionsInstance] addBookmark:bookmark];

    // Change the GUID so that this session can follow a different path in life
    // than its bookmark. Changes to the bookmark will no longer affect this
    // session, and changes to this session won't affect its originating bookmark
    // (which may not evene exist any longer).
    bookmark = [[ProfileModel sessionsInstance] setObject:guid
                                                    forKey:KEY_ORIGINAL_GUID
                                                inBookmark:bookmark];
    guid = [ProfileModel freshGuid];
    [[ProfileModel sessionsInstance] setObject:guid
                                         forKey:KEY_GUID
                                     inBookmark:bookmark];
    [self setAddressBookEntry:[[ProfileModel sessionsInstance] bookmarkWithGuid:guid]];
    return guid;
}

- (NSString*)jobName
{
    return jobName_;
}

- (NSString*)uncachedJobName
{
    return [SHELL currentJob:YES];
}

- (void)setLastActiveAt:(NSDate*)date
{
    [lastActiveAt_ release];
    lastActiveAt_ = [date copy];
}

- (NSDate*)lastActiveAt
{
    return lastActiveAt_;
}

// Jump to the saved scroll position
- (void)jumpToSavedScrollPosition
{
    VT100ScreenMark *mark = nil;
    if (lastMark_ && [SCREEN markIsValid:lastMark_]) {
        mark = lastMark_;
    } else {
        mark = [SCREEN lastMark];
    }
    Interval *interval = mark.entry.interval;
    if (!interval) {
        NSBeep();
        return;
    }
    VT100GridRange range = [SCREEN lineNumberRangeOfInterval:interval];
    long long offset = range.location;
    if (offset < 0) {
        NSBeep();  // This really shouldn't ever happen
    } else {
        self.currentMarkOrNotePosition = [mark.entry.interval retain];
        offset += [SCREEN totalScrollbackOverflow];
        [TEXTVIEW scrollToAbsoluteOffset:offset height:[SCREEN height]];
        [TEXTVIEW highlightMarkOnLine:VT100GridRangeMax(range)];
    }
}

// Is there a saved scroll position?
- (BOOL)hasSavedScrollPosition
{
    return [SCREEN lastMark] != nil;
}

- (void)useStringForFind:(NSString*)string
{
    [[view findViewController] findString:string];
}

- (void)findWithSelection
{
    if ([TEXTVIEW selectedText]) {
        [[view findViewController] findString:[TEXTVIEW selectedText]];
    }
}

- (void)toggleFind
{
    [[view findViewController] toggleVisibility];
}

- (void)searchNext
{
    [[view findViewController] searchNext];
}

- (void)searchPrevious
{
    [[view findViewController] searchPrevious];
}

- (void)resetFindCursor
{
    [TEXTVIEW resetFindCursor];
}

- (BOOL)findInProgress
{
    return [TEXTVIEW findInProgress];
}

- (BOOL)continueFind
{
    return [TEXTVIEW continueFind];
}

- (BOOL)growSelectionLeft
{
    return [TEXTVIEW growSelectionLeft];
}

- (void)growSelectionRight
{
    [TEXTVIEW growSelectionRight];
}

- (NSString*)selectedText
{
    return [TEXTVIEW selectedText];
}

- (BOOL)canSearch
{
    return TEXTVIEW != nil && tab_ && [tab_ realParentWindow];
}

- (BOOL)findString:(NSString *)aString
  forwardDirection:(BOOL)direction
      ignoringCase:(BOOL)ignoreCase
             regex:(BOOL)regex
        withOffset:(int)offset
{
    return [TEXTVIEW findString:aString
               forwardDirection:direction
                   ignoringCase:ignoreCase
                          regex:regex
                     withOffset:offset];
}

- (NSString*)unpaddedSelectedText
{
    return [TEXTVIEW selectedTextWithPad:NO];
}

- (void)copySelection
{
    return [TEXTVIEW copySelectionAccordingToUserPreferences];
}

- (void)takeFocus
{
    [[[[self tab] realParentWindow] window] makeFirstResponder:TEXTVIEW];
}

- (void)clearHighlights
{
    [TEXTVIEW clearHighlights];
}

- (NSImage *)dragImage
{
    NSImage *image = [self imageOfSession:YES];
    NSImage *dragImage = [[[NSImage alloc] initWithSize:[image size]] autorelease];
    [dragImage lockFocus];
    [image compositeToPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:0.5];
    [dragImage unlockFocus];
    return dragImage;
}

- (NSImage *)imageOfSession:(BOOL)flip
{
    [TEXTVIEW refresh];
    NSRect theRect = [SCROLLVIEW documentVisibleRect];
    NSImage *textviewImage = [[[NSImage alloc] initWithSize:theRect.size] autorelease];

    [textviewImage lockFocus];
    if (flip) {
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform scaleXBy:1.0 yBy:-1];
        [transform translateXBy:0 yBy:-theRect.size.height];
        [transform concat];
    }

    [TEXTVIEW drawBackground:theRect toPoint:NSMakePoint(0, 0)];
    // Draw the background flipped, which is actually the right way up.
    NSPoint temp = NSMakePoint(0, 0);
    [TEXTVIEW drawRect:theRect to:&temp];
    [textviewImage unlockFocus];

    return textviewImage;
}

- (void)setPasteboard:(NSString *)pbName
{
    if (pbName) {
        [pasteboard_ autorelease];
        pasteboard_ = [pbName copy];
        [pbtext_ release];
        pbtext_ = [[NSMutableData alloc] init];
    } else {
        NSPasteboard *pboard = [NSPasteboard pasteboardWithName:pasteboard_];
        [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:self];
        [pboard setData:pbtext_ forType:NSStringPboardType];

        [pasteboard_ release];
        pasteboard_ = nil;
        [pbtext_ release];
        pbtext_ = nil;

        // In case it was the find pasteboard that chagned
        [[NSNotificationCenter defaultCenter] postNotificationName:@"iTermLoadFindStringFromSharedPasteboard"
                                                            object:nil
                                                          userInfo:nil];
    }
}

- (void)stopCoprocess
{
    [SHELL stopCoprocess];
}

- (BOOL)hasCoprocess
{
    return [SHELL hasCoprocess];
}

- (void)launchCoprocessWithCommand:(NSString *)command mute:(BOOL)mute
{
    Coprocess *coprocess = [Coprocess launchedCoprocessWithCommand:command];
    coprocess.mute = mute;
    [SHELL setCoprocess:coprocess];
    [TEXTVIEW setNeedsDisplay:YES];
}

- (void)launchSilentCoprocessWithCommand:(NSString *)command
{
    [self launchCoprocessWithCommand:command mute:YES];
}

- (void)setFocused:(BOOL)focused
{
    if (focused != focused_) {
        focused_ = focused;
        if ([TERMINAL reportFocus]) {
            char flag = focused ? 'I' : 'O';
            NSString *message = [NSString stringWithFormat:@"%c[%c", 27, flag];
            [self writeTask:[message dataUsingEncoding:[self encoding]]];
        }
    }
}

- (BOOL)wantsContentChangedNotification
{
    // We want a content change notification if it's worth doing a tail find.
    // That means the find window is open, we're not already doing a tail find,
    // and a search was performed in the find window (vs select+cmd-e+cmd-f).
    return !tailFindTimer_ &&
           ![[[view findViewController] view] isHidden] &&
           [TEXTVIEW initialFindContext].substring != nil;
}

- (void)hideSession
{
    [[MovePaneController sharedInstance] moveSessionToNewWindow:self
                                                        atPoint:[[view window] convertBaseToScreen:NSMakePoint(0, 0)]];
    [[[tab_ realParentWindow] window] miniaturize:self];
}

- (void)startTmuxMode
{
    if ([[TmuxControllerRegistry sharedInstance] numberOfClients]) {
        const char *message = "detach\n";
        [self printTmuxMessage:@"Can't enter tmux mode: another tmux is already attached"];
        [SCREEN crlf];
        [self writeTaskImpl:[NSData dataWithBytes:message length:strlen(message)]];
        return;
    }

    if (tmuxMode_ != TMUX_NONE) {
        return;
    }
    tmuxMode_ = TMUX_GATEWAY;
    tmuxGateway_ = [[TmuxGateway alloc] initWithDelegate:self];
    tmuxController_ = [[TmuxController alloc] initWithGateway:tmuxGateway_];
    tmuxController_.ambiguousIsDoubleWidth = doubleWidth;
    NSSize theSize;
    Profile *tmuxBookmark = [PTYTab tmuxBookmark];
    theSize.width = MAX(1, [[tmuxBookmark objectForKey:KEY_COLUMNS] intValue]);
    theSize.height = MAX(1, [[tmuxBookmark objectForKey:KEY_ROWS] intValue]);
    [tmuxController_ validateOptions];
    [tmuxController_ setClientSize:theSize];

    [self printTmuxMessage:@"** tmux mode started **"];
    [SCREEN crlf];
    [self printTmuxMessage:@"Command Menu"];
    [self printTmuxMessage:@"----------------------------"];
    [self printTmuxMessage:@"esc    Detach cleanly."];
    [self printTmuxMessage:@"  X    Force-quit tmux mode."];
    [self printTmuxMessage:@"  L    Toggle logging."];
    [self printTmuxMessage:@"  C    Run tmux command."];

    if ([[PreferencePanel sharedInstance] autoHideTmuxClientSession]) {
        [self hideSession];
    }

    [tmuxGateway_ readTask:[TERMINAL streamData]];
    [TERMINAL clearStream];
}

- (BOOL)isTmuxClient
{
    return tmuxMode_ == TMUX_CLIENT;
}

- (BOOL)isTmuxGateway
{
    return tmuxMode_ == TMUX_GATEWAY;
}

- (void)tmuxDetach
{
    if (tmuxMode_ != TMUX_GATEWAY) {
        return;
    }
    [self printTmuxMessage:@"Detaching..."];
    [tmuxGateway_ detach];
}

- (int)tmuxPane
{
    return tmuxPane_;
}

- (void)setTmuxPane:(int)windowPane
{
    tmuxPane_ = windowPane;
    tmuxMode_ = TMUX_CLIENT;
}

- (void)setTmuxController:(TmuxController *)tmuxController
{
    [tmuxController_ autorelease];
    tmuxController_ = [tmuxController retain];
}

- (void)resizeFromArrangement:(NSDictionary *)arrangement
{
    [self setWidth:[[arrangement objectForKey:SESSION_ARRANGEMENT_COLUMNS] intValue]
            height:[[arrangement objectForKey:SESSION_ARRANGEMENT_ROWS] intValue]];
}

- (BOOL)isCompatibleWith:(PTYSession *)otherSession
{
    if (tmuxMode_ != TMUX_CLIENT && otherSession->tmuxMode_ != TMUX_CLIENT) {
        // Non-clients are always compatible
        return YES;
    } else if (tmuxMode_ == TMUX_CLIENT && otherSession->tmuxMode_ == TMUX_CLIENT) {
        // Clients are compatible with other clients from the same controller.
        return (tmuxController_ == otherSession->tmuxController_);
    } else {
        // Clients are never compatible with non-clients.
        return NO;
    }
}

- (void)toggleShowTimestamps {
    [TEXTVIEW toggleShowTimestamps];
}

- (VT100GridCoordRange)smartSelectionRangeAt:(VT100GridCoord)coord {
    if (coord.x < 0 || coord.y < 0 || coord.x >= SCREEN.width || coord.y >= SCREEN.height) {
        return VT100GridCoordRangeMake(0, 0, 0, 0);
    }
    int startX, startY, endX, endY;
    [TEXTVIEW smartSelectAtX:coord.x
                           y:coord.y + [SCREEN numberOfScrollbackLines]
                    toStartX:&startX
                    toStartY:&startY
                      toEndX:&endX
                      toEndY:&endY
            ignoringNewlines:NO
              actionRequired:NO];
    return [TEXTVIEW rangeByTrimmingNullsFromRange:VT100GridCoordRangeMake(startX,
                                                                           startY,
                                                                           endX,
                                                                           endY)
                                        trimSpaces:YES];
}

- (void)addNoteAtCursor {
    PTYNoteViewController *note = [[[PTYNoteViewController alloc] init] autorelease];
    VT100GridCoordRange rangeAtCursor =
        [self smartSelectionRangeAt:VT100GridCoordMake(SCREEN.cursorX - 1,
                                                       SCREEN.cursorY - 1)];
    VT100GridCoordRange rangeBeforeCursor =
        [self smartSelectionRangeAt:VT100GridCoordMake(SCREEN.cursorX - 2,
                                                       SCREEN.cursorY - 1)];
    VT100GridCoordRange rangeAfterCursor =
        [self smartSelectionRangeAt:VT100GridCoordMake(SCREEN.cursorX,
                                                       SCREEN.cursorY - 1)];
    if (VT100GridCoordRangeLength(rangeAtCursor, SCREEN.width) > 0) {
        [SCREEN addNote:note inRange:rangeAtCursor];
    } else if (VT100GridCoordRangeLength(rangeAfterCursor, SCREEN.width) > 0) {
        [SCREEN addNote:note inRange:rangeAfterCursor];
    } else if (VT100GridCoordRangeLength(rangeBeforeCursor, SCREEN.width) > 0) {
        [SCREEN addNote:note inRange:rangeBeforeCursor];
    } else {
        int y = SCREEN.cursorY - 1 + [SCREEN numberOfScrollbackLines];
        [SCREEN addNote:note inRange:VT100GridCoordRangeMake(0, y, SCREEN.width, y)];
    }
    [note makeFirstResponder];
}

- (void)showHideNotes {
    VT100GridCoordRange range =
        VT100GridCoordRangeMake(0,
                                0,
                                SCREEN.width,
                                SCREEN.height + [SCREEN numberOfScrollbackLines]);
    NSArray *notes = [SCREEN notesInRange:range];
    BOOL anyNoteIsVisible = NO;
    for (PTYNoteViewController *note in notes) {
        if (!note.view.isHidden) {
            anyNoteIsVisible = YES;
            break;
        }
    }
    for (PTYNoteViewController *note in notes) {
        [note setNoteHidden:anyNoteIsVisible];
    }
}

- (void)highlightMarkOrNote:(id<IntervalTreeObject>)obj {
    if ([obj isKindOfClass:[VT100ScreenMark class]]) {
        [TEXTVIEW highlightMarkOnLine:VT100GridRangeMax([SCREEN lineNumberRangeOfInterval:obj.entry.interval])];
    } else {
        PTYNoteViewController *note = (PTYNoteViewController *)obj;
        [note setNoteHidden:NO];
        [note highlight];
    }
}

- (void)previousMarkOrNote {
    NSArray *objects = nil;
    if (self.currentMarkOrNotePosition == nil) {
        objects = [SCREEN lastMarksOrNotes];
    } else {
        objects = [SCREEN marksOrNotesBefore:self.currentMarkOrNotePosition];
        if (!objects.count) {
            objects = [SCREEN lastMarksOrNotes];
            if (objects.count) {
                [TEXTVIEW beginFlash:FlashWrapToBottom];
            }
        }
    }
    if (objects.count) {
        id<IntervalTreeObject> obj = objects[0];
        self.currentMarkOrNotePosition = obj.entry.interval;
        VT100GridRange range = [SCREEN lineNumberRangeOfInterval:self.currentMarkOrNotePosition];
        [TEXTVIEW scrollLineNumberRangeIntoView:range];
        for (obj in objects) {
            [self highlightMarkOrNote:obj];
        }
    }
}

- (void)nextMarkOrNote {
    NSArray *objects = nil;
    if (self.currentMarkOrNotePosition == nil) {
        objects = [SCREEN firstMarksOrNotes];
    } else {
        objects = [SCREEN marksOrNotesAfter:self.currentMarkOrNotePosition];
        if (!objects.count) {
            objects = [SCREEN firstMarksOrNotes];
            if (objects.count) {
                [TEXTVIEW beginFlash:FlashWrapToTop];
            }
        }
    }
    if (objects.count) {
        id<IntervalTreeObject> obj = objects[0];
        self.currentMarkOrNotePosition = obj.entry.interval;
        VT100GridRange range = [SCREEN lineNumberRangeOfInterval:self.currentMarkOrNotePosition];
        [TEXTVIEW scrollLineNumberRangeIntoView:range];
        for (obj in objects) {
            [self highlightMarkOrNote:obj];
        }
    }
}

#pragma mark tmux gateway delegate methods
// TODO (also, capture and throw away keyboard input)

- (TmuxController *)tmuxController
{
    return tmuxController_;
}

- (void)tmuxUpdateLayoutForWindow:(int)windowId
                           layout:(NSString *)layout
{
    PTYTab *tab = [tmuxController_ window:windowId];
    if (tab) {
        [tmuxController_ setLayoutInTab:tab toLayout:layout];
    }
}

- (void)tmuxWindowAddedWithId:(int)windowId
{
    if (![tmuxController_ window:windowId]) {
        [tmuxController_ openWindowWithId:windowId
                              intentional:NO];
    }
    [tmuxController_ windowsChanged];
}

- (void)tmuxWindowClosedWithId:(int)windowId
{
    PTYTab *tab = [tmuxController_ window:windowId];
    if (tab) {
        [[tab realParentWindow] removeTab:tab];
    }
    [tmuxController_ windowsChanged];
}

- (void)tmuxWindowRenamedWithId:(int)windowId to:(NSString *)newName
{
    PTYTab *tab = [tmuxController_ window:windowId];
    if (tab) {
        [tab setTmuxWindowName:newName];
    }
    [tmuxController_ windowWasRenamedWithId:windowId to:newName];
}

- (void)tmuxPrintLine:(NSString *)line
{
    [SCREEN appendStringAtCursor:line ascii:NO];
    [SCREEN crlf];
}

- (void)tmuxHostDisconnected
{
    [tmuxController_ detach];

    // Autorelease the gateway because it called this function so we can't free
    // it immediately.
    [tmuxGateway_ autorelease];
    tmuxGateway_ = nil;
    [tmuxController_ release];
    tmuxController_ = nil;
    [SCREEN appendStringAtCursor:@"Detached" ascii:YES];
    [SCREEN crlf];
    tmuxMode_ = TMUX_NONE;
    tmuxLogging_ = NO;

    if ([[PreferencePanel sharedInstance] autoHideTmuxClientSession] &&
        [[[tab_ realParentWindow] window] isMiniaturized]) {
        [[[tab_ realParentWindow] window] deminiaturize:self];
    }
}

- (void)tmuxSetSecureLogging:(BOOL)secureLogging {
    tmuxSecureLogging_ = secureLogging;
}

- (void)tmuxWriteData:(NSData *)data
{
    if (EXIT) {
        return;
    }
    if (tmuxSecureLogging_) {
        DLog(@"Write to tmux.");
    } else {
        DLog(@"Write to tmux: \"%@\"", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
    }
    if (tmuxLogging_) {
        [self printTmuxMessage:[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]];
    }
    [self writeTaskImpl:data];
}

- (void)tmuxReadTask:(NSData *)data
{
    if (!EXIT) {
        [SHELL logData:data];
        [self readTask:data];
    }
}

- (void)tmuxSessionChanged:(NSString *)sessionName sessionId:(int)sessionId
{
    [tmuxController_ sessionChangedTo:sessionName sessionId:sessionId];
}

- (void)tmuxSessionsChanged
{
    [tmuxController_ sessionsChanged];
}

- (void)tmuxWindowsDidChange
{
    [tmuxController_ windowsChanged];
}

- (void)tmuxSession:(int)sessionId renamed:(NSString *)newName
{
    [tmuxController_ session:sessionId renamedTo:newName];
}

- (NSSize)tmuxBookmarkSize
{
        NSDictionary *dict = [PTYTab tmuxBookmark];
        return NSMakeSize([[dict objectForKey:KEY_COLUMNS] intValue],
                                          [[dict objectForKey:KEY_ROWS] intValue]);
}

- (int)tmuxNumHistoryLinesInBookmark
{
        NSDictionary *dict = [PTYTab tmuxBookmark];
    if ([[dict objectForKey:KEY_UNLIMITED_SCROLLBACK] boolValue]) {
                // 10M is close enough to infinity to be indistinguishable.
                return 10 * 1000 * 1000;
        } else {
                return [[dict objectForKey:KEY_SCROLLBACK_LINES] intValue];
        }
}

- (void)pasteViewControllerDidCancel
{
    [self hidePasteUI];
    [slowPasteTimer invalidate];
    slowPasteTimer = nil;
    [slowPasteBuffer release];
    slowPasteBuffer = [[NSMutableString alloc] init];
    [self emptyEventQueue];
}

- (NSString*)encodingName
{
    // Get the encoding, perhaps as a fully written out name.
    CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding([self encoding]);
    // Convert it to the expected (IANA) format.
    NSString* ianaEncoding = (NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding);
    DLog(@"iana encoding is %@", ianaEncoding);
    // Fix up lowercase letters.
    static NSDictionary* lowerCaseEncodings;
    if (!lowerCaseEncodings) {
        NSString* plistFile = [[NSBundle bundleForClass:[self class]] pathForResource:@"EncodingsWithLowerCase" ofType:@"plist"];
        lowerCaseEncodings = [NSDictionary dictionaryWithContentsOfFile:plistFile];
        [lowerCaseEncodings retain];
    }
    if ([ianaEncoding rangeOfCharacterFromSet:[NSCharacterSet lowercaseLetterCharacterSet]].length) {
        // Some encodings are improperly returned as lower case. For instance,
        // "utf-8" instead of "UTF-8". If this isn't in the allowed list of
        // lower-case encodings, then uppercase it.
        if (lowerCaseEncodings) {
            if (![lowerCaseEncodings objectForKey:ianaEncoding]) {
                ianaEncoding = [ianaEncoding uppercaseString];
                DLog(@"Convert to uppser case. ianaEncoding is now %@", ianaEncoding);
            }
        }
    }

    if (ianaEncoding != nil) {
        // Mangle the names slightly
        NSMutableString* encoding = [[[NSMutableString alloc] initWithString:ianaEncoding] autorelease];
        [encoding replaceOccurrencesOfString:@"ISO-" withString:@"ISO" options:0 range:NSMakeRange(0, [encoding length])];
        [encoding replaceOccurrencesOfString:@"EUC-" withString:@"euc" options:0 range:NSMakeRange(0, [encoding length])];
        DLog(@"After mangling, encoding is now %@", encoding);
        return encoding;
    }

    DLog(@"Return nil encoding");

    return nil;
}

#pragma mark PTYTextViewDelegate

- (BOOL)xtermMouseReporting
{
    return xtermMouseReporting;
}

- (BOOL)isPasting {
    return slowPasteTimer != nil;
}

- (void)queueKeyDown:(NSEvent *)event {
    [eventQueue_ addObject:event];
}

// Handle bookmark- and global-scope keybindings. If there is no keybinding then
// pass the keystroke as input.
- (void)keyDown:(NSEvent *)event
{
  BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];
  unsigned char *send_str = NULL;
  unsigned char *dataPtr = NULL;
  int dataLength = 0;
  size_t send_strlen = 0;
  int send_pchr = -1;
  int keyBindingAction;
  NSString *keyBindingText;

  unsigned int modflag;
  NSString *keystr;
  NSString *unmodkeystr;
  unichar unicode, unmodunicode;

  modflag = [event modifierFlags];
  keystr  = [event characters];
  unmodkeystr = [event charactersIgnoringModifiers];
  if ([unmodkeystr length] == 0) {
    return;
  }
  unicode = [keystr length] > 0 ? [keystr characterAtIndex:0] : 0;
  unmodunicode = [unmodkeystr length] > 0 ? [unmodkeystr characterAtIndex:0] : 0;
  if (debugKeyDown) {
    NSLog(@"PTYSession keyDown modflag=%d keystr=%@ unmodkeystr=%@ unicode=%d unmodunicode=%d", (int)modflag, keystr, unmodkeystr, (int)unicode, (int)unmodunicode);
  }
  gettimeofday(&lastInput, NULL);

  if ([[[self tab] realParentWindow] inInstantReplay]) {
    if (debugKeyDown) {
      NSLog(@"PTYSession keyDown in IR");
    }
    // Special key handling in IR mode, and keys never get sent to the live
    // session, even though it might be displayed.
    if (unicode == 27) {
      // Escape exits IR
      [[[self tab] realParentWindow] closeInstantReplay:self];
      return;
    } else if (unmodunicode == NSLeftArrowFunctionKey) {
      // Left arrow moves to prev frame
      int n = 1;
      if (modflag & NSShiftKeyMask) {
        n = 15;
      }
      for (int i = 0; i < n; i++) {
        [[[self tab] realParentWindow] irPrev:self];
      }
    } else if (unmodunicode == NSRightArrowFunctionKey) {
      // Right arrow moves to next frame
      int n = 1;
      if (modflag & NSShiftKeyMask) {
        n = 15;
      }
      for (int i = 0; i < n; i++) {
        [[[self tab] realParentWindow] irNext:self];
      }
    } else {
      NSBeep();
    }
    return;
  }

  unsigned short keycode = [event keyCode];
  if (debugKeyDown) {
    NSLog(@"event:%@ (%x+%x)[%@][%@]:%x(%c) <%d>", event,modflag,keycode,keystr,unmodkeystr,unicode,unicode,(modflag & NSNumericPadKeyMask));
  }
  DebugLog([NSString stringWithFormat:@"event:%@ (%x+%x)[%@][%@]:%x(%c) <%d>", event,modflag,keycode,keystr,unmodkeystr,unicode,unicode,(modflag & NSNumericPadKeyMask)]);

  // Check if we have a custom key mapping for this event
  keyBindingAction = [iTermKeyBindingMgr actionForKeyCode:unmodunicode
                                                modifiers:modflag
                                                     text:&keyBindingText
                                              keyMappings:[[self addressBookEntry] objectForKey:KEY_KEYBOARD_MAP]];

  if (keyBindingAction >= 0) {
    if (debugKeyDown) {
      NSLog(@"PTYSession keyDown action=%d", keyBindingAction);
    }
    DebugLog([NSString stringWithFormat:@"keyBindingAction=%d", keyBindingAction]);
    // A special action was bound to this key combination.
    NSString* temp;
    int profileAction = [iTermKeyBindingMgr localActionForKeyCode:unmodunicode
                                                        modifiers:modflag
                                                             text:&temp
                                                      keyMappings:[[self addressBookEntry] objectForKey:KEY_KEYBOARD_MAP]];
    if (profileAction == keyBindingAction &&  // Don't warn if it's a global mapping
        (keyBindingAction == KEY_ACTION_NEXT_SESSION ||
         keyBindingAction == KEY_ACTION_PREVIOUS_SESSION)) {
          // Warn users about outdated default key bindings.
          int tempMods = modflag & (NSAlternateKeyMask | NSControlKeyMask | NSShiftKeyMask | NSCommandKeyMask);
          int tempKeyCode = unmodunicode;
          if (tempMods == (NSCommandKeyMask | NSAlternateKeyMask) &&
              (tempKeyCode == 0xf702 || tempKeyCode == 0xf703) &&
              [[[self tab] sessions] count] > 1) {
            if ([self _askAboutOutdatedKeyMappings]) {
              int result = NSRunAlertPanel(@"Outdated Key Mapping Found",
                                           @"It looks like you're trying to switch split panes but you have a key mapping from an old iTerm installation for ⌘⌥← or ⌘⌥→ that switches tabs instead. What would you like to do?",
                                           @"Remove it",
                                           @"Remind me later",
                                           @"Keep it");
              switch (result) {
                case NSAlertDefaultReturn:
                  // Remove it
                  [self _removeOutdatedKeyMapping];
                  return;
                  break;
                case NSAlertAlternateReturn:
                  // Remind me later
                  break;
                case NSAlertOtherReturn:
                  // Keep it
                  [self _setKeepOutdatedKeyMapping];
                  break;
                default:
                  break;
              }
            }
          }
        }

    BOOL isTmuxGateway = (!EXIT && tmuxMode_ == TMUX_GATEWAY);

    switch (keyBindingAction) {
      case KEY_ACTION_MOVE_TAB_LEFT:
        [[[self tab] realParentWindow] moveTabLeft:nil];
        break;
      case KEY_ACTION_MOVE_TAB_RIGHT:
        [[[self tab] realParentWindow] moveTabRight:nil];
        break;
      case KEY_ACTION_NEXT_MRU_TAB:
        [[[[self tab] parentWindow] tabView] processMRUEvent:event];
        break;
      case KEY_ACTION_NEXT_PANE:
        [[self tab] nextSession];
        break;
      case KEY_ACTION_PREVIOUS_PANE:
        [[self tab] previousSession];
        break;
      case KEY_ACTION_NEXT_SESSION:
        [[[self tab] parentWindow] nextTab:nil];
        break;
      case KEY_ACTION_NEXT_WINDOW:
        [[iTermController sharedInstance] nextTerminal:nil];
        break;
      case KEY_ACTION_PREVIOUS_SESSION:
        [[[self tab] parentWindow] previousTab:nil];
        break;
      case KEY_ACTION_PREVIOUS_WINDOW:
        [[iTermController sharedInstance] previousTerminal:nil];
        break;
      case KEY_ACTION_SCROLL_END:
        [TEXTVIEW scrollEnd];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_SCROLL_HOME:
        [TEXTVIEW scrollHome];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_SCROLL_LINE_DOWN:
        [TEXTVIEW scrollLineDown:self];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_SCROLL_LINE_UP:
        [TEXTVIEW scrollLineUp:self];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_SCROLL_PAGE_DOWN:
        [TEXTVIEW scrollPageDown:self];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_SCROLL_PAGE_UP:
        [TEXTVIEW scrollPageUp:self];
        [(PTYScrollView *)[TEXTVIEW enclosingScrollView] detectUserScroll];
        break;
      case KEY_ACTION_ESCAPE_SEQUENCE:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self sendEscapeSequence:keyBindingText];
        break;
      case KEY_ACTION_HEX_CODE:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self sendHexCode:keyBindingText];
        break;
      case KEY_ACTION_TEXT:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self sendText:keyBindingText];
        break;
      case KEY_ACTION_RUN_COPROCESS:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self launchCoprocessWithCommand:keyBindingText];
        break;
      case KEY_ACTION_SELECT_MENU_ITEM:
        [PTYSession selectMenuItem:keyBindingText];
        break;

      case KEY_ACTION_SEND_C_H_BACKSPACE:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self writeTask:[@"\010" dataUsingEncoding:NSUTF8StringEncoding]];
        break;
      case KEY_ACTION_SEND_C_QM_BACKSPACE:
        if (EXIT || isTmuxGateway) {
          return;
        }
        [self writeTask:[@"\177" dataUsingEncoding:NSUTF8StringEncoding]]; // decimal 127
        break;
      case KEY_ACTION_IGNORE:
        break;
      case KEY_ACTION_IR_FORWARD:
        if (isTmuxGateway) {
          return;
        }
        [[iTermController sharedInstance] irAdvance:1];
        break;
      case KEY_ACTION_IR_BACKWARD:
        if (isTmuxGateway) {
          return;
        }
        [[iTermController sharedInstance] irAdvance:-1];
        break;
      case KEY_ACTION_SELECT_PANE_LEFT:
        [[[iTermController sharedInstance] currentTerminal] selectPaneLeft:nil];
        break;
      case KEY_ACTION_SELECT_PANE_RIGHT:
        [[[iTermController sharedInstance] currentTerminal] selectPaneRight:nil];
        break;
      case KEY_ACTION_SELECT_PANE_ABOVE:
        [[[iTermController sharedInstance] currentTerminal] selectPaneUp:nil];
        break;
      case KEY_ACTION_SELECT_PANE_BELOW:
        [[[iTermController sharedInstance] currentTerminal] selectPaneDown:nil];
        break;
      case KEY_ACTION_DO_NOT_REMAP_MODIFIERS:
      case KEY_ACTION_REMAP_LOCALLY:
        break;
      case KEY_ACTION_TOGGLE_FULLSCREEN:
        [[[iTermController sharedInstance] currentTerminal] toggleFullScreenMode:nil];
        break;
      case KEY_ACTION_NEW_WINDOW_WITH_PROFILE:
        [[[self tab] realParentWindow] newWindowWithBookmarkGuid:keyBindingText];
        break;
      case KEY_ACTION_NEW_TAB_WITH_PROFILE:
        [[[self tab] realParentWindow] newTabWithBookmarkGuid:keyBindingText];
        break;
      case KEY_ACTION_SPLIT_HORIZONTALLY_WITH_PROFILE:
        [[[self tab] realParentWindow] splitVertically:NO withBookmarkGuid:keyBindingText];
        break;
      case KEY_ACTION_SPLIT_VERTICALLY_WITH_PROFILE:
        [[[self tab] realParentWindow] splitVertically:YES withBookmarkGuid:keyBindingText];
        break;
      default:
        NSLog(@"Unknown key action %d", keyBindingAction);
        break;
    }
  } else {
    // Key is not bound to an action.
    if (!EXIT && tmuxMode_ == TMUX_GATEWAY) {
      [self handleKeypressInTmuxGateway:unicode];
      return;
    }
    if (debugKeyDown) {
      NSLog(@"PTYSession keyDown no keybinding action");
    }
    DebugLog(@"No keybinding action");
    if (EXIT) {
      DebugLog(@"Terminal already dead");
      return;
    }
    // No special binding for this key combination.
    if (modflag & NSFunctionKeyMask) {
      if (debugKeyDown) {
        NSLog(@"PTYSession keyDown is a function key");
      }
      DebugLog(@"Is a function key");
      // Handle all "special" keys (arrows, etc.)
      NSData *data = nil;

      switch (unicode) {
        case NSUpArrowFunctionKey:
          data = [TERMINAL keyArrowUp:modflag];
          break;
        case NSDownArrowFunctionKey:
          data = [TERMINAL keyArrowDown:modflag];
          break;
        case NSLeftArrowFunctionKey:
          data = [TERMINAL keyArrowLeft:modflag];
          break;
        case NSRightArrowFunctionKey:
          data = [TERMINAL keyArrowRight:modflag];
          break;
        case NSInsertFunctionKey:
          data = [TERMINAL keyInsert];
          break;
        case NSDeleteFunctionKey:
          // This is forward delete, not backspace.
          data = [TERMINAL keyDelete];
          break;
        case NSHomeFunctionKey:
          data = [TERMINAL keyHome:modflag];
          break;
        case NSEndFunctionKey:
          data = [TERMINAL keyEnd:modflag];
          break;
        case NSPageUpFunctionKey:
          data = [TERMINAL keyPageUp:modflag];
          break;
        case NSPageDownFunctionKey:
          data = [TERMINAL keyPageDown:modflag];
          break;
        case NSClearLineFunctionKey:
          data = [@"\e" dataUsingEncoding:NSUTF8StringEncoding];
          break;
      }

      if (NSF1FunctionKey <= unicode && unicode <= NSF35FunctionKey) {
        data = [TERMINAL keyFunction:unicode - NSF1FunctionKey + 1];
      }

      if (data != nil) {
        send_str = (unsigned char *)[data bytes];
        send_strlen = [data length];
      } else if (keystr != nil) {
        NSData *keydat = ((modflag & NSControlKeyMask) && unicode > 0) ?
        [keystr dataUsingEncoding:NSUTF8StringEncoding] :
        [unmodkeystr dataUsingEncoding:NSUTF8StringEncoding];
        send_str = (unsigned char *)[keydat bytes];
        send_strlen = [keydat length];
      }
    } else if (((modflag & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask &&
                ([self optionKey] != OPT_NORMAL)) ||
               (modflag == NSAlternateKeyMask &&
                ([self optionKey] != OPT_NORMAL)) ||  /// synergy
               ((modflag & NSRightAlternateKeyMask) == NSRightAlternateKeyMask &&
                ([self rightOptionKey] != OPT_NORMAL))) {
                 if (debugKeyDown) {
                   NSLog(@"PTYSession keyDown opt + key -> modkey");
                 }
                 DebugLog(@"Option + key -> modified key");
                 // A key was pressed while holding down option and the option key
                 // is not behaving normally. Apply the modified behavior.
                 int mode;  // The modified behavior based on which modifier is pressed.
                 if ((modflag == NSAlternateKeyMask) ||  // synergy
                     (modflag & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask) {
                   mode = [self optionKey];
                 } else {
                   mode = [self rightOptionKey];
                 }

                 NSData *keydat = ((modflag & NSControlKeyMask) && unicode > 0)?
                 [keystr dataUsingEncoding:NSUTF8StringEncoding]:
                 [unmodkeystr dataUsingEncoding:NSUTF8StringEncoding];
                 if (keydat != nil) {
                   send_str = (unsigned char *)[keydat bytes];
                   send_strlen = [keydat length];
                 }
                 if (mode == OPT_ESC) {
                   send_pchr = '\e';
                 } else if (mode == OPT_META && send_str != NULL) {
                   int i;
                   for (i = 0; i < send_strlen; ++i) {
                     send_str[i] |= 0x80;
                   }
                 }
               } else {
                 if (debugKeyDown) {
                   NSLog(@"PTYSession keyDown regular path");
                 }
                 DebugLog(@"Regular path for keypress");
                 // Regular path for inserting a character from a keypress.
                 int max = [keystr length];
                 NSData *data=nil;

                 if (max != 1||[keystr characterAtIndex:0] > 0x7f) {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown non-ascii");
                   }
                   DebugLog(@"Non-ascii input");
                   data = [keystr dataUsingEncoding:[TERMINAL encoding]];
                 } else {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown ascii");
                   }
                   DebugLog(@"ASCII input");
                   data = [keystr dataUsingEncoding:NSUTF8StringEncoding];
                 }

                 // Enter key is on numeric keypad, but not marked as such
                 if (unicode == NSEnterCharacter && unmodunicode == NSEnterCharacter) {
                   modflag |= NSNumericPadKeyMask;
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown enter key");
                   }
                   DebugLog(@"Enter key");
                   keystr = @"\015";  // Enter key -> 0x0d
                 }
                 // Check if we are in keypad mode
                 if (modflag & NSNumericPadKeyMask) {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown numeric keyoad");
                   }
                   DebugLog(@"Numeric keypad mask");
                   data = [TERMINAL keypadData:unicode keystr:keystr];
                 }

                 int indMask = modflag & NSDeviceIndependentModifierFlagsMask;
                 if ((indMask & NSCommandKeyMask) &&   // pressing cmd
                     ([keystr isEqualToString:@"0"] ||  // pressed 0 key
                      ([keystr intValue] > 0 && [keystr intValue] <= 9) || // or any other digit key
                      [keystr isEqualToString:@"\r"])) {   // or enter
                       // Do not send anything for cmd+number because the user probably
                       // fat-fingered switching of tabs/windows.
                       // Do not send anything for cmd+[shift]+enter if it wasn't
                       // caught by the menu.
                       DebugLog(@"Cmd + 0-9 or cmd + enter");
                       if (debugKeyDown) {
                         NSLog(@"PTYSession keyDown cmd+0-9 or cmd+enter");
                       }
                       data = nil;
                     }
                 if (data != nil) {
                   send_str = (unsigned char *)[data bytes];
                   send_strlen = [data length];
                   DebugLog([NSString stringWithFormat:@"modflag = 0x%x; send_strlen = %zd; send_str[0] = '%c (0x%x)'",
                             modflag, send_strlen, send_str[0], send_str[0]]);
                   if (debugKeyDown) {
                     DebugLog([NSString stringWithFormat:@"modflag = 0x%x; send_strlen = %zd; send_str[0] = '%c (0x%x)'",
                               modflag, send_strlen, send_str[0], send_str[0]]);
                   }
                 }

                 if ((modflag & NSControlKeyMask) &&
                     send_strlen == 1 &&
                     send_str[0] == '|') {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown c-|");
                   }
                   // Control-| is sent as Control-backslash
                   send_str = (unsigned char*)"\034";
                   send_strlen = 1;
                 } else if ((modflag & NSControlKeyMask) &&
                            (modflag & NSShiftKeyMask) &&
                            send_strlen == 1 &&
                            send_str[0] == '/') {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown c-?");
                   }
                   // Control-shift-/ is sent as Control-?
                   send_str = (unsigned char*)"\177";
                   send_strlen = 1;
                 } else if ((modflag & NSControlKeyMask) &&
                            send_strlen == 1 &&
                            send_str[0] == '/') {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown c-/");
                   }
                   // Control-/ is sent as Control-/, but needs some help to do so.
                   send_str = (unsigned char*)"\037"; // control-/
                   send_strlen = 1;
                 } else if ((modflag & NSShiftKeyMask) &&
                            send_strlen == 1 &&
                            send_str[0] == '\031') {
                   if (debugKeyDown) {
                     NSLog(@"PTYSession keyDown shift-tab -> esc[Z");
                   }
                   // Shift-tab is sent as Esc-[Z (or "backtab")
                   send_str = (unsigned char*)"\033[Z";
                   send_strlen = 3;
                 }

               }

    if (EXIT == NO) {
      if (send_pchr >= 0) {
        // Send a prefix character (e.g., esc).
        char c = send_pchr;
        dataPtr = (unsigned char*)&c;
        dataLength = 1;
        [self writeTask:[NSData dataWithBytes:dataPtr length:dataLength]];
      }

      if (send_str != NULL) {
        dataPtr = send_str;
        dataLength = send_strlen;
        [self writeTask:[NSData dataWithBytes:dataPtr length:dataLength]];
      }
    }
  }
}

- (BOOL)hasActionableKeyMappingForEvent:(NSEvent *)event
{
    int keyBindingAction = [self _keyBindingActionForEvent:event];
    return (keyBindingAction >= 0) && (keyBindingAction != KEY_ACTION_DO_NOT_REMAP_MODIFIERS) && (keyBindingAction != KEY_ACTION_REMAP_LOCALLY);
}

- (int)optionKey
{
    return [[[self addressBookEntry] objectForKey:KEY_OPTION_KEY_SENDS] intValue];
}

- (int)rightOptionKey
{
    NSNumber* rightOptPref = [[self addressBookEntry] objectForKey:KEY_RIGHT_OPTION_KEY_SENDS];
    if (rightOptPref == nil) {
        return [self optionKey];
    }
    return [rightOptPref intValue];
}

- (BOOL)applicationKeypadAllowed
{
    return [[[self addressBookEntry] objectForKey:KEY_APPLICATION_KEYPAD_ALLOWED] boolValue];
}

// Contextual menu
- (void)menuForEvent:(NSEvent *)theEvent menu:(NSMenu *)theMenu
{
    // Ask the parent if it has anything to add
    if ([[self tab] realParentWindow] &&
        [[[self tab] realParentWindow] respondsToSelector:@selector(menuForEvent:menu:)]) {
        [[[self tab] realParentWindow] menuForEvent:theEvent menu:theMenu];
    }
}

- (BOOL)maybeWarnAboutMultiLinePaste:(NSString *)string
{
    iTermApplicationDelegate *ad = [[NSApplication sharedApplication] delegate];
    if (![ad warnBeforeMultiLinePaste]) {
        return YES;
    }
    
    if ([string rangeOfString:@"\n"].length == 0) {
        return YES;
    }
    
    switch (NSRunAlertPanel(@"Confirm Multi-Line Paste",
                            @"Ok to paste %d lines?",
                            @"Yes",
                            @"No",
                            @"Yes and don‘t ask again",
                            (int)[[string componentsSeparatedByString:@"\n"] count])) {
        case NSAlertDefaultReturn:
            return YES;
        case NSAlertAlternateReturn:
            return NO;
        case NSAlertOtherReturn:
            [ad toggleMultiLinePasteWarning:nil];
            return YES;
    }
    
    assert(false);
    return YES;
}

// Pastes a specific string. The API for pasting not-from-clipboard. All pastes go through here.
// If queued, this is called just before the paste occurs, not when getting queued.
- (void)pasteString:(NSString *)str flags:(int)flags
{
    if (![self maybeWarnAboutMultiLinePaste:str]) {
        return;
    }
    if (flags & 1) {
        // paste escaping special characters
        str = [str stringWithEscapedShellCharacters];
    }
    if ([TERMINAL bracketedPasteMode]) {
        [self writeTask:[[NSString stringWithFormat:@"%c[200~", 27]
                         dataUsingEncoding:[TERMINAL encoding]
                         allowLossyConversion:YES]];
    }
    if (flags & 2) {
        [slowPasteBuffer appendString:[str stringWithLinefeedNewlines]];
        [self _pasteSlowly:nil];
    } else {
        [self _pasteString:str];
    }
}

// Pastes the current string in the clipboard. Uses the sender's tag to get flags.
- (void)paste:(id)sender
{
    NSString* pbStr = [PTYSession pasteboardString];
    if (pbStr) {
        if ([self isPasting]) {
            if ([pbStr length] == 0) {
                NSBeep();
            } else {
                [eventQueue_ addObject:[PasteEvent pasteEventWithString:pbStr flags:[sender tag]]];
            }
        } else {
            [self pasteString:pbStr flags:[sender tag]];
        }
    }
}

- (void)textViewFontDidChange
{
    if ([self isTmuxClient]) {
        [self notifyTmuxFontChange];
    }
}

- (void)textViewPostTabContentsChangedNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"iTermTabContentsChanged"
                                                        object:self
                                                      userInfo:nil];
}

- (void)textViewBeginDrag
{
    [[MovePaneController sharedInstance] beginDrag:self];
}

- (void)textViewMovePane
{
    [[MovePaneController sharedInstance] movePane:self];
}

- (NSStringEncoding)textViewEncoding
{
    return [self encoding];
}

- (void)textViewWillNeedUpdateForBlink
{
    [self scheduleUpdateIn:[[PreferencePanel sharedInstance] timeBetweenBlinks]];
}

- (void)textViewSplitVertically:(BOOL)vertically withProfileGuid:(NSString *)guid
{
    Profile *profile = [[ProfileModel sharedInstance] defaultBookmark];
    if (guid) {
        profile = [[ProfileModel sharedInstance] bookmarkWithGuid:guid];
    }
    [[[self tab] realParentWindow] splitVertically:vertically
                                      withBookmark:profile
                                     targetSession:self];
}

- (void)textViewSelectNextTab
{
    [[[self tab] realParentWindow] nextTab:nil];
}

- (void)textViewSelectPreviousTab
{
    [[[self tab] realParentWindow] previousTab:nil];
}

- (void)textViewSelectNextWindow
{
    [[iTermController sharedInstance] nextTerminal:nil];
}

- (void)textViewSelectPreviousWindow
{
    [[iTermController sharedInstance] previousTerminal:nil];
}

- (void)textViewSelectNextPane
{
    [[self tab] nextSession];
}

- (void)textViewSelectPreviousPane;
{
    [[self tab] previousSession];
}

- (void)textViewEditSession
{
    [[[self tab] realParentWindow] editSession:self];
}

- (void)textViewToggleBroadcastingInput
{
    [[[self tab] realParentWindow] toggleBroadcastingInputToSession:self];
}

- (void)textViewCloseWithConfirmation
{
    [[[self tab] realParentWindow] closeSessionWithConfirmation:self];
}

- (NSString *)textViewPasteboardString
{
    return [[self class] pasteboardString];
}

- (void)textViewPasteFromSessionWithMostRecentSelection
{
    PTYSession *session = [[iTermController sharedInstance] sessionWithMostRecentSelection];
    if (session) {
        PTYTextView *textview = [session TEXTVIEW];
        if ([textview selectionStartX] > -1) {
            [self pasteString:[textview selectedText]];
        }
    }
}

- (BOOL)textViewWindowUsesTransparency
{
    return [[[self tab] realParentWindow] useTransparency];
}

- (BOOL)textViewAmbiguousWidthCharsAreDoubleWidth
{
    return [self doubleWidth];
}

- (void)textViewCreateWindowWithProfileGuid:(NSString *)guid
{
    [[[self tab] realParentWindow] newWindowWithBookmarkGuid:guid];
}

- (void)textViewCreateTabWithProfileGuid:(NSString *)guid
{
    [[[self tab] realParentWindow] newTabWithBookmarkGuid:guid];
}

- (BOOL)textViewDelegateHandlesAllKeystrokes
{
    return [[[self tab] realParentWindow] inInstantReplay];
}

- (BOOL)textViewInSameTabAsTextView:(PTYTextView *)other {
    return [self tab] == [other.delegate tab];
}

- (BOOL)textViewIsActiveSession
{
    return [[self tab] activeSession] == self;
}

- (BOOL)textViewSessionIsBroadcastingInput
{
    return [[[self tab] realParentWindow] broadcastInputToSession:self];
}

- (BOOL)textViewTabHasMaximizedPanel
{
    return [[self tab] hasMaximizedPane];
}

- (void)textViewDidBecomeFirstResponder
{
    [[self tab] setActiveSession:self];
}

- (PTYScrollView *)SCROLLVIEW
{
    return SCROLLVIEW;
}

- (void)sendEscapeSequence:(NSString *)text
{
    if (EXIT) {
        return;
    }
    if ([text length] > 0) {
        NSString *aString = [NSString stringWithFormat:@"\e%@", text];
        [self writeTask:[aString dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

- (void)sendHexCode:(NSString *)codes
{
    if (EXIT) {
        return;
    }
    if ([codes length]) {
        NSArray* components = [codes componentsSeparatedByString:@" "];
        for (NSString* part in components) {
            const char* utf8 = [part UTF8String];
            char* endPtr;
            unsigned char c = strtol(utf8, &endPtr, 16);
            if (endPtr != utf8) {
                [self writeTask:[NSData dataWithBytes:&c length:sizeof(c)]];
            }
        }
    }
}

- (void)sendText:(NSString *)text
{
    if (EXIT) {
        return;
    }
    if ([text length] > 0) {
        NSString *temp = text;
        temp = [temp stringByReplacingEscapedChar:'n' withString:@"\n"];
        temp = [temp stringByReplacingEscapedChar:'e' withString:@"\e"];
        temp = [temp stringByReplacingEscapedChar:'a' withString:@"\a"];
        temp = [temp stringByReplacingEscapedChar:'t' withString:@"\t"];
        [self writeTask:[temp dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

- (void)launchCoprocessWithCommand:(NSString *)command
{
    [self launchCoprocessWithCommand:command mute:NO];
}

- (void)uploadFiles:(NSArray *)localFilenames toPath:(SCPPath *)destinationPath
{
    SCPFile *previous = nil;
    for (NSString *file in localFilenames) {
        SCPFile *scpFile = [[[SCPFile alloc] init] autorelease];
        scpFile.path = [[[SCPPath alloc] init] autorelease];
        scpFile.path.hostname = destinationPath.hostname;
        scpFile.path.username = destinationPath.username;
        NSString *filename = [file lastPathComponent];
        scpFile.path.path = [destinationPath.path stringByAppendingPathComponent:filename];
        scpFile.localPath = file;

        if (previous) {
            previous.successor = scpFile;
        }
        previous = scpFile;
        [scpFile upload];
    }
}

- (void)startDownloadOverSCP:(SCPPath *)path
{
    SCPFile *file = [[[SCPFile alloc] init] autorelease];
    file.path = path;
    [file download];
}

- (NSString*)_getLocale
{
    NSString* theLocale = nil;
    NSString* languageCode = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode];
    NSString* countryCode = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    DLog(@"getLocale: languageCode=%@, countryCode=%@", languageCode, countryCode);
    if (languageCode && countryCode) {
        theLocale = [NSString stringWithFormat:@"%@_%@", languageCode, countryCode];
        DLog(@"Return combined language/country locale %@", theLocale);
    } else {
        NSString *localeId = [[NSLocale currentLocale] localeIdentifier];
        DLog(@"Return local identifier of %@", localeId);
        return localeId;
    }
    return theLocale;
}

- (NSString*)_lang
{
    NSString* theLocale = [self _getLocale];
    NSString* encoding = [self encodingName];
    DLog(@"locale=%@, encoding=%@", theLocale, encoding);
    if (encoding && theLocale) {
        NSString* result = [NSString stringWithFormat:@"%@.%@", theLocale, encoding];
        DLog(@"Tentative locale is %@", result);
        if ([self _localeIsSupported:result]) {
            DLog(@"Locale is supported");
            return result;
        } else {
            DLog(@"Locale is NOT supported");
            return nil;
        }
    } else {
        DLog(@"No locale or encoding, returning nil language");
        return nil;
    }
}

- (void)setDvrFrame
{
    screen_char_t* s = (screen_char_t*)[dvrDecoder_ decodedFrame];
    int len = [dvrDecoder_ length];
    DVRFrameInfo info = [dvrDecoder_ info];
    if (info.width != [SCREEN width] || info.height != [SCREEN height]) {
        if (![liveSession_ isTmuxClient]) {
            [[[self tab] realParentWindow] sessionInitiatedResize:self
                                                            width:info.width
                                                           height:info.height];
        }
    }
    [SCREEN setFromFrame:s len:len info:info];
    [[[self tab] realParentWindow] resetTempTitle];
    [[[self tab] realParentWindow] setWindowTitle];
}

- (void)continueTailFind
{
    NSMutableArray *results = [NSMutableArray array];
    BOOL more;
    more = [SCREEN continueFindAllResults:results
                                inContext:tailFindContext_];
    for (SearchResult *r in results) {
        [TEXTVIEW addResultFromX:r->startX
                            absY:r->absStartY
                             toX:r->endX
                          toAbsY:r->absEndY];
    }
    if ([results count]) {
        [TEXTVIEW setNeedsDisplay:YES];
    }
    if (more) {
        tailFindTimer_ = [NSTimer scheduledTimerWithTimeInterval:0.01
                                                          target:self
                                                        selector:@selector(continueTailFind)
                                                        userInfo:nil
                                                         repeats:NO];
    } else {
        // Update the saved position to just before the screen.
        [SCREEN storeLastPositionInLineBufferAsFindContextSavedPosition];
        tailFindTimer_ = nil;
    }
}

- (void)beginTailFind
{
    FindContext *initialFindContext = [TEXTVIEW initialFindContext];
    if (!initialFindContext.substring) {
        return;
    }
    [SCREEN setFindString:initialFindContext.substring
         forwardDirection:YES
             ignoringCase:!!(initialFindContext.options & FindOptCaseInsensitive)
                    regex:!!(initialFindContext.options & FindOptRegex)
              startingAtX:0
              startingAtY:0
               withOffset:0
                inContext:tailFindContext_
          multipleResults:YES];

    // Set the starting position to the block & offset that the backward search
    // began at. Do a forward search from that location.
    [SCREEN restoreSavedPositionToFindContext:tailFindContext_];
    [self continueTailFind];
}

- (void)sessionContentsChanged:(NSNotification *)notification
{
    if (!tailFindTimer_ &&
        [notification object] == self &&
        [[tab_ realParentWindow] currentTab] == tab_) {
        [self beginTailFind];
    }
}

- (void)stopTailFind
{
    if (tailFindTimer_) {
        tailFindContext_.substring = nil;
        tailFindContext_.results = nil;
        [tailFindTimer_ invalidate];
        tailFindTimer_ = nil;
    }
}

- (void)printTmuxMessage:(NSString *)message
{
    if (EXIT) {
        return;
    }
    screen_char_t savedFgColor = [TERMINAL foregroundColorCode];
    screen_char_t savedBgColor = [TERMINAL backgroundColorCode];
    [TERMINAL setForegroundColor:ALTSEM_FG_DEFAULT
              alternateSemantics:YES];
    [TERMINAL setBackgroundColor:ALTSEM_BG_DEFAULT
              alternateSemantics:YES];
    [SCREEN appendStringAtCursor:message ascii:YES];
    [SCREEN crlf];
    [TERMINAL setForegroundColor:savedFgColor.foregroundColor
              alternateSemantics:savedFgColor.foregroundColorMode == ColorModeAlternate];
    [TERMINAL setBackgroundColor:savedBgColor.backgroundColor
              alternateSemantics:savedBgColor.backgroundColorMode == ColorModeAlternate];
}

- (void)printTmuxCommandOutputToScreen:(NSString *)response
{
    for (NSString *aLine in [response componentsSeparatedByString:@"\n"]) {
        aLine = [aLine stringByReplacingOccurrencesOfString:@"\r" withString:@""];
        [self printTmuxMessage:aLine];
    }
}

- (BOOL)_localeIsSupported:(NSString*)theLocale
{
    // Keep a copy of the current locale setting for this process
    char* backupLocale = setlocale(LC_CTYPE, NULL);

    // Try to set it to the proposed locale
    BOOL supported;
    if (setlocale(LC_CTYPE, [theLocale UTF8String])) {
        supported = YES;
    } else {
        supported = NO;
    }

    // Restore locale and return
    setlocale(LC_CTYPE, backupLocale);
    return supported;
}

#pragma mark - VT100ScreenDelegate

- (void)screenNeedsRedraw {
    [self refreshAndStartTimerIfNeeded];
    [TEXTVIEW updateNoteViewFrames];
    [TEXTVIEW setNeedsDisplay:YES];
}

- (void)screenUpdateDisplay {
    [self updateDisplay];
}

- (void)screenSizeDidChange {
    [self updateScroll];
    [TEXTVIEW updateNoteViewFrames];
}

- (void)screenTriggerableChangeDidOccur {
    [self clearTriggerLine];
}

- (void)screenDidReset {
    [self loadInitialColorTable];
}

- (BOOL)screenShouldSyncTitle {
    if (![[PreferencePanel sharedInstance] showBookmarkName]) {
        return NO;
    }
    return [[[self addressBookEntry] objectForKey:KEY_SYNC_TITLE] boolValue];
}

- (void)screenDidAppendStringToCurrentLine:(NSString *)string {
    [self appendStringToTriggerLine:string];
}

- (void)screenSetCursorType:(ITermCursorType)type {
    [[self TEXTVIEW] setCursorType:type];
}

- (void)screenSetCursorBlinking:(BOOL)blink {
    [[self TEXTVIEW] setBlinkingCursor:blink];
}

- (BOOL)screenShouldInitiateWindowResize {
    return ![[[self addressBookEntry] objectForKey:KEY_DISABLE_WINDOW_RESIZING] boolValue];
}

- (void)screenResizeToWidth:(int)width height:(int)height {
    [[self tab] sessionInitiatedResize:self width:width height:height];
}

- (void)screenResizeToPixelWidth:(int)width height:(int)height {
    [[[self tab] realParentWindow] setFrameSize:NSMakeSize(width, height)];
}

- (BOOL)screenShouldBeginPrinting {
    return ![[[self addressBookEntry] objectForKey:KEY_DISABLE_PRINTING] boolValue];
}

- (NSString *)screenNameExcludingJob {
    return [self joblessDefaultName];
}

- (void)screenSetWindowTitle:(NSString *)title {
    [self setWindowTitle:title];
}

- (NSString *)screenWindowTitle {
    return [self windowTitle];
}

- (NSString *)screenDefaultName {
    return [self defaultName];
}

- (void)screenSetName:(NSString *)theName {
    [self setName:theName];
}

- (BOOL)screenWindowIsFullscreen {
    return [[[self tab] parentWindow] anyFullScreen];
}

- (void)screenMoveWindowTopLeftPointTo:(NSPoint)point {
    NSRect screenFrame = [self screenWindowScreenFrame];
    point.x += screenFrame.origin.x;
    point.y = screenFrame.origin.y + screenFrame.size.height - point.y;
    [[[self tab] parentWindow] windowSetFrameTopLeftPoint:point];
}

- (NSRect)screenWindowScreenFrame {
    return [[[[self tab] parentWindow] windowScreen] visibleFrame];
}

- (NSPoint)screenWindowTopLeftPixelCoordinate {
    NSRect frame = [self screenWindowFrame];
    NSRect screenFrame = [self screenWindowScreenFrame];
    return NSMakePoint(frame.origin.x - screenFrame.origin.x,
                       (screenFrame.origin.y + screenFrame.size.height) - (frame.origin.y + frame.size.height));
}

// If flag is set, miniaturize; otherwise, deminiaturize.
- (void)screenMiniaturizeWindow:(BOOL)flag {
    if (flag) {
        [[[self tab] parentWindow] windowPerformMiniaturize:nil];
    } else {
        [[[self tab] parentWindow] windowDeminiaturize:nil];
    }
}

// If flag is set, bring to front; if not, move to back.
- (void)screenRaise:(BOOL)flag {
    if (flag) {
        [[[self tab] parentWindow] windowOrderFront:nil];
    } else {
        [[[self tab] parentWindow] windowOrderBack:nil];
    }
}

- (BOOL)screenWindowIsMiniaturized {
    return [[[self tab] parentWindow] windowIsMiniaturized];
}

- (void)screenWriteDataToTask:(NSData *)data {
    [self writeTask:data];
}

- (NSRect)screenWindowFrame {
    return [[[self tab] parentWindow] windowFrame];
}

- (NSSize)screenSize {
    return [[[[[self tab] parentWindow] currentSession] SCROLLVIEW] documentVisibleRect].size;
}

// If the flag is set, push the window title; otherwise push the icon title.
- (void)screenPushCurrentTitleForWindow:(BOOL)flag {
    if (flag) {
        [self pushWindowTitle];
    } else {
        [self pushIconTitle];
    }
}

// If the flag is set, pop the window title; otherwise pop the icon title.
- (void)screenPopCurrentTitleForWindow:(BOOL)flag {
    if (flag) {
        [self popWindowTitle];
    } else {
        [self popIconTitle];
    }
}

- (NSString *)screenName {
    return [self name];
}

- (int)screenNumber {
    return [[self tab] realObjectCount];
}

- (int)screenWindowIndex {
    return [[iTermController sharedInstance] indexOfTerminal:(PseudoTerminal *)[[self tab] realParentWindow]];
}

- (int)screenTabIndex {
    return [[self tab] number];
}

- (int)screenViewIndex {
    return [[self view] viewId];
}

- (void)screenStartTmuxMode {
    [self startTmuxMode];
}

- (void)screenModifiersDidChangeTo:(NSArray *)modifiers {
    [self setSendModifiers:modifiers];
}

- (BOOL)screenShouldTreatAmbiguousCharsAsDoubleWidth {
    return [self doubleWidth];
}

- (BOOL)screenShouldAppendToScrollbackWithStatusBar {
    return [[[self addressBookEntry] objectForKey:KEY_SCROLLBACK_WITH_STATUS_BAR] boolValue];
}

- (void)screenDidChangeNumberOfScrollbackLines {
    [TEXTVIEW updateNoteViewFrames];
}

- (void)screenShowBellIndicator {
    [self setBell:YES];
}

- (void)screenPrintString:(NSString *)string {
    [[self TEXTVIEW] printContent:string];
}

- (void)screenPrintVisibleArea {
    [[self TEXTVIEW] print:nil];
}

- (BOOL)screenShouldSendContentsChangedNotification {
    return [self wantsContentChangedNotification];
}

- (void)screenRemoveSelection {
    [TEXTVIEW deselect];
}

- (int)screenSelectionStartX {
    return [TEXTVIEW selectionStartX];
}

- (int)screenSelectionEndX {
    return [TEXTVIEW selectionEndX];
}

- (int)screenSelectionStartY {
    return [TEXTVIEW selectionStartY];
}

- (int)screenSelectionEndY {
    return [TEXTVIEW selectionEndY];
}

- (void)screenSetSelectionFromX:(int)startX
                          fromY:(int)startY
                            toX:(int)endX
                            toY:(int)endY {
    [TEXTVIEW setSelectionFromX:startX fromY:startY toX:endX toY:endY];
}

- (NSSize)screenCellSize {
    return NSMakeSize([TEXTVIEW charWidth], [TEXTVIEW lineHeight]);
}

- (void)screenClearHighlights {
    [TEXTVIEW clearHighlights];
}

- (void)screenMouseModeDidChange {
    [TEXTVIEW updateCursor:nil];
    [TEXTVIEW updateTrackingAreas];
}

- (void)screenFlashImage:(FlashImage)image {
    [TEXTVIEW beginFlash:image];
}

- (void)screenIncrementBadge {
    [[tab_ realParentWindow] incrementBadge];
}

- (void)screenRequestUserAttention:(BOOL)isCritical {
  [NSApp requestUserAttention:isCritical ? NSCriticalRequest : NSInformationalRequest];
}

- (NSString *)screenCurrentWorkingDirectory {
    return [SHELL getWorkingDirectory];
}

- (void)screenSetCursorVisible:(BOOL)visible {
    if (visible) {
        [TEXTVIEW showCursor];
    } else {
        [TEXTVIEW hideCursor];
    }
}

- (BOOL)screenHasView {
    return TEXTVIEW != nil;
}

- (void)screenAddMarkOnLine:(int)line {
    [TEXTVIEW refresh];  // In case text was appended
    [lastMark_ release];
    lastMark_ = [[SCREEN addMarkStartingAtAbsoluteLine:[SCREEN totalScrollbackOverflow] + line
                                               oneLine:YES] retain];
    self.currentMarkOrNotePosition = lastMark_.entry.interval;
    if (self.alertOnNextMark) {
        [SCREEN requestUserAttentionWithMessage:@"Your attention is requested!"];
        self.alertOnNextMark = NO;
    }
}

// Save the current scroll position
- (void)screenSaveScrollPosition
{
    [TEXTVIEW refresh];  // In case text was appended
    [lastMark_ release];
    lastMark_ = [[SCREEN addMarkStartingAtAbsoluteLine:[TEXTVIEW absoluteScrollPosition]
                                               oneLine:NO] retain];
    self.currentMarkOrNotePosition = lastMark_.entry.interval;
}

- (void)screenActivateWindow {
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)screenSetProfileToProfileNamed:(NSString *)value {
    Profile *newProfile;
    if ([value length]) {
        newProfile = [[ProfileModel sharedInstance] bookmarkWithName:value];
    } else {
        newProfile = [[ProfileModel sharedInstance] defaultBookmark];
    }
    if (newProfile) {
        NSString *theName = [[self addressBookEntry] objectForKey:KEY_NAME];
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:newProfile];
        [dict setObject:theName forKey:KEY_NAME];
        [self setAddressBookEntry:dict];
        [self setPreferencesFromAddressBookEntry:dict];
        [self remarry];
    }
}

- (void)screenSetPasteboard:(NSString *)value {
    if ([[PreferencePanel sharedInstance] allowClipboardAccess]) {
        if ([value isEqualToString:@"ruler"]) {
            [self setPasteboard:NSGeneralPboard];
        } else if ([value isEqualToString:@"find"]) {
            [self setPasteboard:NSFindPboard];
        } else if ([value isEqualToString:@"font"]) {
            [self setPasteboard:NSFontPboard];
        } else {
            [self setPasteboard:NSGeneralPboard];
        }
    } else {
        NSLog(@"Clipboard access denied for CopyToClipboard");
    }
}

- (void)screenDidAddNote:(PTYNoteViewController *)note {
    [TEXTVIEW addViewForNote:note];
    [TEXTVIEW setNeedsDisplay:YES];
}

- (void)screenDidEndEditingNote {
    [TEXTVIEW.window makeFirstResponder:TEXTVIEW];
}

- (void)screenCopyBufferToPasteboard {
    if ([[PreferencePanel sharedInstance] allowClipboardAccess]) {
        [self setPasteboard:nil];
    } else {
        [pasteboard_ release];
        pasteboard_ = nil;
        [pbtext_ release];
        pbtext_ = nil;
    }
}

- (BOOL)screenIsAppendingToPasteboard {
    return pasteboard_ != nil;
}

- (void)screenAppendDataToPasteboard:(NSData *)data {
    // Don't allow more than 100MB to be added to the pasteboard queue in case someone
    // forgets to send the EndCopy command.
    const int kMaxPasteboardBytes = 100 * 1024 * 1024;
    if ([pbtext_ length] + data.length > kMaxPasteboardBytes) {
        [self setPasteboard:nil];
    }

    [pbtext_ appendData:data];
}

- (void)setAlertOnNextMark:(BOOL)alertOnNextMark {
    _alertOnNextMark = alertOnNextMark;
    [TEXTVIEW setNeedsDisplay:YES];
}

- (void)screenRequestAttention:(BOOL)request {
    if (request) {
        requestAttentionId_ = [NSApp requestUserAttention:NSCriticalRequest];
    } else {
        [NSApp cancelUserAttentionRequest:requestAttentionId_];
    }
}

- (void)screenSetForegroundColor:(NSColor *)color {
    [TEXTVIEW setFGColor:color];
}

- (void)screenSetBackgroundColor:(NSColor *)color {
    [TEXTVIEW setBGColor:color];
}

- (void)screenSetBoldColor:(NSColor *)color {
    [TEXTVIEW setBoldColor:color];
}

- (void)screenSetSelectionColor:(NSColor *)color {
    [TEXTVIEW setSelectionColor:color];
}

- (void)screenSetSelectedTextColor:(NSColor *)color {
    [TEXTVIEW setSelectedTextColor:color];
}

- (void)screenSetCursorColor:(NSColor *)color {
    [TEXTVIEW setCursorColor:color];
}

- (void)screenSetCursorTextColor:(NSColor *)color {
    [TEXTVIEW setCursorTextColor:color];
}

- (void)screenSetColorTableEntryAtIndex:(int)n color:(NSColor *)color {
    [TEXTVIEW setColorTable:n color:color];
}

- (void)screenSetCurrentTabColor:(NSColor *)color {
    NSTabViewItem* tabViewItem = [[self ptytab] tabViewItem];
    id<WindowControllerInterface> term = [[self ptytab] parentWindow];
    [term setTabColor:nil forTabViewItem:tabViewItem];
}

- (NSColor *)tabColor {
    NSTabViewItem* tabViewItem = [[self ptytab] tabViewItem];
    id<WindowControllerInterface> term = [[self ptytab] parentWindow];
    return [term tabColorForTabViewItem:tabViewItem];
}

- (void)screenSetTabColorRedComponentTo:(CGFloat)color {
    NSColor *curColor = [self tabColor];
    [[[self ptytab] parentWindow] setTabColor:[NSColor colorWithCalibratedRed:color
                                                                        green:[curColor greenComponent]
                                                                         blue:[curColor blueComponent]
                                                                        alpha:1]
                               forTabViewItem:[[self ptytab] tabViewItem]];
}

- (void)screenSetTabColorGreenComponentTo:(CGFloat)color {
    NSColor *curColor = [self tabColor];
    [[[self ptytab] parentWindow] setTabColor:[NSColor colorWithCalibratedRed:[curColor redComponent]
                                                                        green:color
                                                                         blue:[curColor blueComponent]
                                                                        alpha:1]
                               forTabViewItem:[[self ptytab] tabViewItem]];
}

- (void)screenSetTabColorBlueComponentTo:(CGFloat)color {
    NSColor *curColor = [self tabColor];
    [[[self ptytab] parentWindow] setTabColor:[NSColor colorWithCalibratedRed:[curColor redComponent]
                                                                        green:[curColor greenComponent]
                                                                         blue:color
                                                                        alpha:1]
                               forTabViewItem:[[self ptytab] tabViewItem]];
}

- (BOOL)screenShouldSendReport {
    return (SHELL != nil) && (![self isTmuxClient]);
}

#pragma mark - PopupDelegate

- (NSWindowController *)popupWindowController {
    return [[self tab] realParentWindow];
}

- (VT100Screen *)popupVT100Screen {
    return SCREEN;
}

- (PTYTextView *)popupVT100TextView {
    return TEXTVIEW;
}

- (void)popupInsertText:(NSString *)string {
    [self insertText:string];
}

@end

@implementation PTYSession (ScriptingSupport)

    // Object specifier
    - (NSScriptObjectSpecifier *)objectSpecifier
{
    NSUInteger theIndex = 0;
    id classDescription = nil;

    NSScriptObjectSpecifier *containerRef = nil;
    if (![[self tab] realParentWindow]) {
        // TODO(georgen): scripting is broken while in instant replay.
        return nil;
    }
    // TODO: Test this with multiple panes per tab.
    theIndex = [[[[self tab] realParentWindow] tabView] indexOfTabViewItem:[[self tab] tabViewItem]];

    if (theIndex != NSNotFound) {
        containerRef = [[[self tab] realParentWindow] objectSpecifier];
        classDescription = [containerRef keyClassDescription];
        //create and return the specifier
        return [[[NSIndexSpecifier allocWithZone:[self zone]]
               initWithContainerClassDescription:classDescription
                              containerSpecifier:containerRef
                                             key:@ "sessions"
                                           index:theIndex] autorelease];
    } else {
        // NSLog(@"recipient not found!");
        return nil;
    }
}

// Handlers for supported commands:
    -(void)handleExecScriptCommand:(NSScriptCommand *)aCommand
{
    // if we are already doing something, get out.
    if ([SHELL pid] > 0) {
        NSBeep();
        return;
    }

    // Get the command's arguments:
    NSDictionary *args = [aCommand evaluatedArguments];
    NSString *command = [args objectForKey:@"command"];
    BOOL isUTF8 = [[args objectForKey:@"isUTF8"] boolValue];

    NSString *cmd;
    NSArray *arg;

    [command breakDownCommandToPath:&cmd cmdArgs:&arg];
    [self startProgram:cmd arguments:arg environment:[NSDictionary dictionary] isUTF8:isUTF8];

    return;
}

-(void)handleSelectScriptCommand:(NSScriptCommand *)command
{
    [[[[self tab] parentWindow] tabView] selectTabViewItemWithIdentifier:[self tab]];
}

-(void)handleClearScriptCommand:(NSScriptCommand *)command
{
    [self clearBuffer];
}

-(void)handleWriteScriptCommand:(NSScriptCommand *)command
{
    // Get the command's arguments:
    NSDictionary *args = [command evaluatedArguments];
    // optional argument follows (might be nil):
    NSString *contentsOfFile = [args objectForKey:@"contentsOfFile"];
    // optional argument follows (might be nil):
    NSString *text = [args objectForKey:@"text"];
    NSData *data = nil;
    NSString *aString = nil;

    if (text != nil) {
        if ([text characterAtIndex:[text length]-1]==' ') {
            data = [text dataUsingEncoding:[TERMINAL encoding]];
        } else {
            aString = [NSString stringWithFormat:@"%@\n", text];
            data = [aString dataUsingEncoding:[TERMINAL encoding]];
        }
    }

    if (contentsOfFile != nil) {
        aString = [NSString stringWithContentsOfFile:contentsOfFile
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
        data = [aString dataUsingEncoding:[TERMINAL encoding]];
    }

    if (tmuxMode_ == TMUX_CLIENT) {
        [self writeTask:data];
    } else if (data != nil && [SHELL pid] > 0) {
        int i = 0;
        // wait here until we have had some output
        while ([SHELL hasOutput] == NO && i < 1000000) {
            usleep(50000);
            i += 50000;
        }

        [self writeTask:data];
    }
}

- (void)handleTerminateScriptCommand:(NSScriptCommand *)command
{
    [[self tab] closeSession:self];
}

@end
