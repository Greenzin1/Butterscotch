#import <UIKit/UIKit.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

#include "common.h"
#include "data_win.h"
#include "runner.h"
#include "vm.h"
#include "overlay_file_system.h"
#include "noop_audio_system.h"
#include "gl/gl_renderer.h"
#include "runner_keyboard.h"
#include "runner_mouse.h"
#include "loop.h"
#include "log.h"
#include "gettime.h"
#include "wad_versions.h"

#include <dlfcn.h>

static void* iosGLGetProcAddress(const char* name) {
    void* ptr = dlsym(RTLD_DEFAULT, name);
    if (ptr) return ptr;
    void* handle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_GLOBAL);
    if (handle) ptr = dlsym(handle, name);
    return ptr;
}

static Runner* gRunner = nil;
static EAGLContext* gGLContext = nil;
static GLuint gDefaultFBO = 0;
static GLuint gColorRenderBuffer = 0;
static int32_t gWindowW = 0;
static int32_t gWindowH = 0;
static char* gCurrentDataWinPath = nil;
static char* gSavesPath = nil;
static FILE* gLogFile = nil;

static void logToFile(const char* fmt, ...) {
    if (!gLogFile) {
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* logPath = [docs stringByAppendingPathComponent:@"butterscotch.log"];
        gLogFile = fopen([logPath UTF8String], "a");
    }
    if (gLogFile) {
        va_list args;
        va_start(args, fmt);
        vfprintf(gLogFile, fmt, args);
        va_end(args);
        fprintf(gLogFile, "\n");
        fflush(gLogFile);
    }
}

#include <signal.h>
#include <execinfo.h>

static void signalHandler(int sig) {
    logToFile("=== CRASH: signal %d ===", sig);
    void* callstack[64];
    int frames = backtrace(callstack, 64);
    char** strs = backtrace_symbols(callstack, frames);
    if (strs) {
        for (int i = 0; i < frames; i++) {
            logToFile("  %s", strs[i]);
        }
        free(strs);
    }
    if (gLogFile) { fclose(gLogFile); gLogFile = nil; }
    _exit(1);
}

static void installSignalHandlers(void) {
    signal(SIGABRT, signalHandler);
    signal(SIGSEGV, signalHandler);
    signal(SIGBUS, signalHandler);
    signal(SIGFPE, signalHandler);
    signal(SIGILL, signalHandler);
    logToFile("Signal handlers installed");
}

void platformLog(const logType type, const char* format, va_list va) {
    NSString* prefix = @"";
    switch (type) {
        case LOG_TYPE_WARNING: prefix = @"[WARN] "; break;
        case LOG_TYPE_ERROR: prefix = @"[ERROR] "; break;
        case LOG_TYPE_DEBUG: prefix = @"[DEBUG] "; break;
        default: break;
    }
    NSString* msg = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:va];
    NSLog(@"%@%@", prefix, msg);
    logToFile("%s%s", [prefix UTF8String], [msg UTF8String]);
}

static bool startRunner(const char* dataWinPath, const char* savesPath) {
    if (gRunner != nil) return false;
    logToFile("startRunner: path=%s saves=%s", dataWinPath, savesPath);

    mkdir(savesPath, 0777);
    logToFile("startRunner: parsing data.win...");

    DataWin* dataWin = DataWin_parse(dataWinPath, (DataWinParserOptions){
        .parseGen8 = true, .parseOptn = true, .parseLang = true,
        .parseExtn = true, .parseSond = true, .parseAgrp = true,
        .parseSprt = true, .parseBgnd = true, .parsePath = true,
        .parseScpt = true, .parseGlob = true, .parseShdr = true,
        .parseFont = true, .parseTmln = true, .parseObjt = true,
        .parseRoom = true, .parseTpag = true, .parseCode = true,
        .parseVari = true, .parseFunc = true, .parseStrg = true,
        .parseTxtr = true, .parseAudo = true,
        .skipLoadingPreciseMasksForNonPreciseSprites = true,
        .loadType = DATAWINLOADTYPE_LOAD_IN_MEMORY_AHEAD_OF_TIME,
        .lazyLoadRooms = false, .eagerlyLoadedRooms = nil
    });
    if (!dataWin) {
        logToFile("startRunner: FAILED to parse data.win!");
        return false;
    }
    logToFile("startRunner: data.win parsed OK");

    char* bundleDir = nil;
    const char* lastSlash = strrchr(dataWinPath, '/');
    if (lastSlash) {
        size_t len = (size_t)(lastSlash - dataWinPath + 1);
        bundleDir = safeMalloc(len + 1);
        memcpy(bundleDir, dataWinPath, len);
        bundleDir[len] = '\0';
    } else {
        bundleDir = safeStrdup("./");
    }

    logToFile("startRunner: creating VM...");
    VMContext* vm = VM_create(dataWin);
    logToFile("startRunner: creating GLRenderer...");
    Renderer* renderer = GLRenderer_create();
    ((GLRenderer*)renderer)->hostFramebuffer = gDefaultFBO;
    logToFile("startRunner: creating OverlayFileSystem...");
    OverlayFileSystem* overlayFs = OverlayFileSystem_create(bundleDir, savesPath);
    free(bundleDir);

    logToFile("startRunner: creating NoopAudioSystem...");
    gRunner = Runner_create(dataWin, vm, renderer, (FileSystem*)overlayFs, (AudioSystem*)NoopAudioSystem_create(), 0);
    gRunner->osType = OS_WINDOWS;
    gRunner->getWindowSize = NULL;
    logToFile("startRunner: Runner created");

    const char* gameArgs[] = { "butterscotch" };
    Runner_setGameArgs(gRunner, (char**)gameArgs, 1);

    logToFile("startRunner: initFirstRoom...");
    Runner_initFirstRoom(gRunner);

    gCurrentDataWinPath = safeStrdup(dataWinPath);
    gSavesPath = safeStrdup(savesPath);
    logToFile("startRunner: DONE - runner started OK");
    return true;
}

static void teardownRunner(void) {
    if (!gRunner) return;
    gRunner->audioSystem->vtable->destroy(gRunner->audioSystem);
    gRunner->renderer->vtable->destroy(gRunner->renderer);
    DataWin* dataWin = gRunner->dataWin;
    VMContext* vm = gRunner->vmContext;
    Runner_free(gRunner);
    VM_free(vm);
    DataWin_free(dataWin);
    gRunner = nil;
    free(gCurrentDataWinPath); gCurrentDataWinPath = nil;
    free(gSavesPath); gSavesPath = nil;
}

// === Virtual Button ===
@interface VirtualButton : UIView
@property (nonatomic, copy) NSString* label;
@property (nonatomic, assign) int keyCode;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end

@implementation VirtualButton
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, self.pressed ?
        [UIColor colorWithRed:1 green:1 blue:1 alpha:0.4].CGColor :
        [UIColor colorWithRed:1 green:1 blue:1 alpha:0.15].CGColor);
    CGContextFillEllipseInRect(ctx, self.bounds);

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:1 blue:1 alpha:0.5].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(self.bounds, 1, 1));

    if (self.label) {
        NSDictionary* attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.7]
        };
        CGSize sz = [self.label sizeWithAttributes:attrs];
        CGPoint pt = CGPointMake((CGRectGetMidX(self.bounds) - sz.width/2),
                                 (CGRectGetMidY(self.bounds) - sz.height/2));
        [self.label drawAtPoint:pt withAttributes:attrs];
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    self.pressed = YES;
    [self setNeedsDisplay];
    if (self.target && self.action) {
        ((void(*)(id, SEL, int, BOOL))objc_msgSend)(self.target, self.action, self.keyCode, YES);
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    self.pressed = NO;
    [self setNeedsDisplay];
    if (self.target && self.action) {
        ((void(*)(id, SEL, int, BOOL))objc_msgSend)(self.target, self.action, self.keyCode, NO);
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    CGFloat dx = point.x - CGRectGetMidX(self.bounds);
    CGFloat dy = point.y - CGRectGetMidY(self.bounds);
    CGFloat r = CGRectGetMidX(self.bounds);
    return (dx*dx + dy*dy) <= r*r * 1.5;
}
@end

// === EAGLView ===
@interface EAGLView : UIView
@property (nonatomic, weak) UIViewController* gameVC;
@end

@implementation EAGLView
+ (Class)layerClass { return [CAEAGLLayer class]; }
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self.gameVC touchesBegan:touches withEvent:event]; }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self.gameVC touchesMoved:touches withEvent:event]; }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self.gameVC touchesEnded:touches withEvent:event]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self.gameVC touchesCancelled:touches withEvent:event]; }
@end

// === GameViewController ===
@interface GameViewController : UIViewController
@property (nonatomic, strong) EAGLContext* glContext;
@property (nonatomic, strong) EAGLView* glView;
@property (nonatomic, assign) BOOL gameRunning;
@property (nonatomic, strong) UILabel* infoLabel;
@property (nonatomic, strong) UIButton* loadButton;
@property (nonatomic, strong) UIView* controlsContainer;
@property (nonatomic, strong) VirtualButton* btnUp;
@property (nonatomic, strong) VirtualButton* btnDown;
@property (nonatomic, strong) VirtualButton* btnLeft;
@property (nonatomic, strong) VirtualButton* btnRight;
@property (nonatomic, strong) VirtualButton* btnA;
@property (nonatomic, strong) VirtualButton* btnB;
@property (nonatomic, strong) VirtualButton* btnMenu;
@property (nonatomic, assign) BOOL controlsVisible;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    logToFile("=== Butterscotch iOS launched ===");

    self.view.backgroundColor = [UIColor blackColor];

    self.glView = [[EAGLView alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.glView.backgroundColor = [UIColor blackColor];
    self.glView.gameVC = self;
    [self.view addSubview:self.glView];

    CAEAGLLayer* eaglLayer = (CAEAGLLayer*)self.glView.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
    };

    self.glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!self.glContext) { logToFile("FATAL: no GLES3"); return; }
    [EAGLContext setCurrentContext:self.glContext];
    gGLContext = self.glContext;

    int loaded = gladLoadGLES2Loader((GLADloadproc)iosGLGetProcAddress);
    logToFile("viewDidLoad: glad loaded %d", loaded);

    glGenRenderbuffers(1, &gColorRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, gColorRenderBuffer);
    [self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer];

    GLint bw, bh;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &bw);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &bh);
    gWindowW = bw; gWindowH = bh;

    glGenFramebuffers(1, &gDefaultFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, gColorRenderBuffer);

    logToFile("viewDidLoad: GL OK %dx%d", gWindowW, gWindowH);

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 100)];
    self.infoLabel.textColor = [UIColor whiteColor];
    self.infoLabel.font = [UIFont systemFontOfSize:15];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.text = @"Butterscotch iOS\nPut data.win in Files app\ntap Load Game";
    self.infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.infoLabel];

    self.loadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1];
    [self.loadButton setTitle:@"Load Game" forState:UIControlStateNormal];
    [self.loadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loadButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.loadButton.layer.cornerRadius = 12;
    [self.loadButton addTarget:self action:@selector(loadGame) forControlEvents:UIControlEventTouchUpInside];
    self.loadButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:self.loadButton];
    [self layoutLoadButton];

    [self createControls];
    logToFile("viewDidLoad: UI done");
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutLoadButton];
    [self layoutControls];
    if (gRunner) {
        [self resizeRenderbuffer];
    }
}

- (void)layoutLoadButton {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    self.loadButton.frame = CGRectMake(40, h - 120, w - 80, 50);
    self.infoLabel.frame = CGRectMake(20, h/2 - 80, w - 40, 100);
}

- (void)resizeRenderbuffer {
    [EAGLContext setCurrentContext:self.glContext];

    CAEAGLLayer* eaglLayer = (CAEAGLLayer*)self.glView.layer;
    glBindRenderbuffer(GL_RENDERBUFFER, gColorRenderBuffer);
    [self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer];

    GLint bw, bh;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &bw);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &bh);
    gWindowW = bw; gWindowH = bh;

    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, gColorRenderBuffer);

    if (gRunner) {
        ((GLRenderer*)gRunner->renderer)->hostFramebuffer = gDefaultFBO;
    }
    logToFile("resizeRenderbuffer: %dx%d", gWindowW, gWindowH);
}

// === Controls ===
- (void)createControls {
    self.controlsContainer = [[UIView alloc] initWithFrame:self.view.bounds];
    self.controlsContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controlsContainer.backgroundColor = [UIColor clearColor];
    self.controlsContainer.hidden = YES;
    self.controlsContainer.userInteractionEnabled = YES;
    [self.view addSubview:self.controlsContainer];

    CGFloat bs = 60;

    self.btnUp = [self makeButton:@"W" keyCode:87 size:bs];
    self.btnDown = [self makeButton:@"S" keyCode:83 size:bs];
    self.btnLeft = [self makeButton:@"A" keyCode:65 size:bs];
    self.btnRight = [self makeButton:@"D" keyCode:68 size:bs];

    self.btnA = [self makeButton:@"Z" keyCode:90 size:bs];
    self.btnB = [self makeButton:@"X" keyCode:88 size:bs];
    self.btnMenu = [self makeButtonCGSize:@"ESC" keyCode:27 size:CGSizeMake(70, 40)];

    [self.controlsContainer addSubview:self.btnUp];
    [self.controlsContainer addSubview:self.btnDown];
    [self.controlsContainer addSubview:self.btnLeft];
    [self.controlsContainer addSubview:self.btnRight];
    [self.controlsContainer addSubview:self.btnA];
    [self.controlsContainer addSubview:self.btnB];
    [self.controlsContainer addSubview:self.btnMenu];
}

- (VirtualButton*)makeButton:(NSString*)label keyCode:(int)code size:(CGFloat)s {
    return [self makeButtonCGSize:label keyCode:code size:CGSizeMake(s, s)];
}

- (VirtualButton*)makeButtonCGSize:(NSString*)label keyCode:(int)code size:(CGSize)s {
    VirtualButton* btn = [[VirtualButton alloc] initWithFrame:CGRectMake(0, 0, s.width, s.height)];
    btn.label = label;
    btn.keyCode = code;
    btn.target = self;
    btn.action = @selector(keyPressed:down:);
    btn.backgroundColor = [UIColor clearColor];
    return btn;
}

- (void)keyPressed:(int)keyCode down:(BOOL)down {
    if (!gRunner) return;
    if (down) {
        RunnerKeyboard_onKeyDown(gRunner->keyboard, keyCode);
    } else {
        RunnerKeyboard_onKeyUp(gRunner->keyboard, keyCode);
    }
}

- (void)layoutControls {
    CGFloat sw = self.view.bounds.size.width;
    CGFloat sh = self.view.bounds.size.height;
    CGFloat pad = 20;
    CGFloat bs = 60;
    CGFloat dPadSpacing = 68;

    CGFloat leftX = pad + 30;
    CGFloat rightX = sw - pad - 30 - bs;
    CGFloat bottomY = sh - pad - bs - 40;

    CGFloat cx = leftX + bs/2;
    CGFloat cy = bottomY + bs/2;

    self.btnUp.frame = CGRectMake(cx - bs/2, cy - dPadSpacing - bs/2, bs, bs);
    self.btnDown.frame = CGRectMake(cx - bs/2, cy + dPadSpacing - bs/2, bs, bs);
    self.btnLeft.frame = CGRectMake(cx - dPadSpacing - bs/2, cy - bs/2, bs, bs);
    self.btnRight.frame = CGRectMake(cx + dPadSpacing - bs/2, cy - bs/2, bs, bs);

    CGFloat rCx = rightX + bs/2;
    CGFloat rCy = bottomY + bs/2;
    self.btnA.frame = CGRectMake(rCx - bs/2, rCy - bs/2, bs, bs);
    self.btnB.frame = CGRectMake(rCx - bs - 20, rCy - bs/2, bs, bs);

    self.btnMenu.frame = CGRectMake(sw/2 - 35, 10, 70, 36);
}

- (void)toggleControls {
    self.controlsVisible = !self.controlsVisible;
    self.controlsContainer.hidden = !self.controlsVisible;
}

// === Load Game ===
- (void)loadGame {
    logToFile("loadGame: starting");
    NSString* docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString* dataWinPath = [docsDir stringByAppendingPathComponent:@"data.win"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:dataWinPath]) {
        logToFile("loadGame: data.win NOT FOUND");
        self.infoLabel.text = @"data.win not found!\nPlace it via Files app";
        return;
    }

    logToFile("loadGame: data.win found");
    [EAGLContext setCurrentContext:self.glContext];
    int loaded = gladLoadGLES2Loader((GLADloadproc)iosGLGetProcAddress);
    logToFile("loadGame: glad %d", loaded);

    char* path = safeStrdup([dataWinPath UTF8String]);
    char* saves = safeStrdup([[docsDir stringByAppendingPathComponent:@"saves"] UTF8String]);

    if (startRunner(path, saves)) {
        self.gameRunning = YES;
        self.infoLabel.hidden = YES;
        self.loadButton.hidden = YES;
        self.controlsContainer.hidden = NO;
        self.controlsVisible = YES;

        CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoop:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    } else {
        self.infoLabel.text = @"Failed to parse data.win!";
    }
    free(path); free(saves);
}

// === Game Loop ===
- (void)gameLoop:(CADisplayLink*)link {
    if (!gRunner || !self.gameRunning) { link.paused = YES; return; }

    [EAGLContext setCurrentContext:self.glContext];

    float dt = (float)(link.targetTimestamp - link.timestamp);
    if (dt <= 0 || dt > 0.1f) dt = 1.0f / 60.0f;

    RunnerKeyboard_beginFrame(gRunner->keyboard);
    RunnerMouse_beginFrame(gRunner->mouse);

    Runner_step(gRunner);

    if (gRunner->audioSystem)
        gRunner->audioSystem->vtable->update(gRunner->audioSystem, dt);

    int32_t winW = gWindowW, winH = gWindowH;
    Gen8* gen8 = &gRunner->dataWin->gen8;
    if (!gRunner->appSurfaceEnabled) {
        gRunner->applicationWidth = winW;
        gRunner->applicationHeight = winH;
        gRunner->usingAppSurface = false;
    } else {
        if (gRunner->applicationWidth <= 0 || gRunner->applicationHeight <= 0) {
            gRunner->applicationWidth = gen8->defaultWindowWidth;
            gRunner->applicationHeight = gen8->defaultWindowHeight;
        }
        gRunner->usingAppSurface = true;
    }
    int32_t gameW = gRunner->applicationWidth, gameH = gRunner->applicationHeight;

    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    Runner_drawPre(gRunner, winW, winH);
    Runner_beginFrame(gRunner, gameW, gameH, winW, winH, winW, winH);
    Runner_drawViews(gRunner, gameW, gameH, false);
    gRunner->renderer->vtable->endFrameInit(gRunner->renderer);
    Runner_drawPost(gRunner, winW, winH);
    gRunner->renderer->vtable->endFrameEnd(gRunner->renderer);
    Runner_drawGUI(gRunner, winW, winH, gameW, gameH);
    Runner_handlePendingRoomChange(gRunner);

    glBindRenderbuffer(GL_RENDERBUFFER, gColorRenderBuffer);
    [self.glContext presentRenderbuffer:GL_RENDERBUFFER];

    if (gRunner->shouldExit) {
        self.gameRunning = NO;
        link.paused = YES;
        self.controlsContainer.hidden = YES;
        teardownRunner();
    }
}

// === Touch (for game area, not controls) ===
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!gRunner) return;
    for (UITouch* touch in touches) {
        CGPoint pt = [touch locationInView:self.glView];
        CGFloat scale = [UIScreen mainScreen].scale;
        Runner_updateMousePosition(gRunner, gWindowW, gWindowH, pt.x * scale, pt.y * scale);
        RunnerMouse_onButtonDown(gRunner->mouse, GML_MB_LEFT);
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!gRunner) return;
    UITouch* touch = [touches anyObject];
    CGPoint pt = [touch locationInView:self.glView];
    CGFloat scale = [UIScreen mainScreen].scale;
    Runner_updateMousePosition(gRunner, gWindowW, gWindowH, pt.x * scale, pt.y * scale);
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!gRunner) return;
    for (UITouch* touch in touches) {
        RunnerMouse_onButtonUp(gRunner->mouse, GML_MB_LEFT);
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)dealloc { teardownRunner(); }
@end

// === AppDelegate ===
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    logToFile("=== AppDelegate ===");
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        installSignalHandlers();
        logToFile("=== main() ===");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
