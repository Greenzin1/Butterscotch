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

static Runner* gRunner = nil;
static EAGLContext* gGLContext = nil;
static GLuint gDefaultFBO = 0;
static GLuint gColorRenderBuffer = 0;
static int32_t gWindowW = 0;
static int32_t gWindowH = 0;
static char* gCurrentDataWinPath = nil;
static char* gSavesPath = nil;

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
}

static bool startRunner(const char* dataWinPath, const char* savesPath) {
    if (gRunner != nil) return false;

    mkdir(savesPath, 0777);

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
        logError("Failed to parse data.win at %s", dataWinPath);
        return false;
    }

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

    VMContext* vm = VM_create(dataWin);
    Renderer* renderer = GLRenderer_create();
    ((GLRenderer*)renderer)->hostFramebuffer = gDefaultFBO;
    OverlayFileSystem* overlayFs = OverlayFileSystem_create(bundleDir, savesPath);
    free(bundleDir);

    gRunner = Runner_create(dataWin, vm, renderer, (FileSystem*)overlayFs, (AudioSystem*)NoopAudioSystem_create(), 0);
    gRunner->osType = OS_WINDOWS;
    gRunner->getWindowSize = NULL;

    const char* gameArgs[] = { "butterscotch" };
    Runner_setGameArgs(gRunner, (char**)gameArgs, 1);

    Runner_initFirstRoom(gRunner);

    gCurrentDataWinPath = safeStrdup(dataWinPath);
    gSavesPath = safeStrdup(savesPath);
    logInfo("Runner started OK");
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

@interface GameViewController : UIViewController
@property (nonatomic, strong) EAGLContext* glContext;
@property (nonatomic, assign) BOOL gameRunning;
@property (nonatomic, strong) UILabel* infoLabel;
@property (nonatomic, strong) UIButton* loadButton;
@property (nonatomic, assign) int touchCount;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    CAEAGLLayer* eaglLayer = (CAEAGLLayer*)self.view.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
    };

    self.glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:self.glContext];
    gGLContext = self.glContext;

    glGenRenderbuffers(1, &gColorRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, gColorRenderBuffer);
    [self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer];

    GLint bw, bh;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &bw);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &bh);
    gWindowW = bw;
    gWindowH = bh;

    glGenFramebuffers(1, &gDefaultFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, gDefaultFBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, gColorRenderBuffer);

    NSLog(@"[Butterscotch-iOS] GL framebuffer: %dx%d", gWindowW, gWindowH);

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 100)];
    self.infoLabel.textColor = [UIColor whiteColor];
    self.infoLabel.font = [UIFont systemFontOfSize:15];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.text = @"Butterscotch iOS\nPut data.win in Files app\ntap Load Game";
    [self.view addSubview:self.infoLabel];

    self.loadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadButton.frame = CGRectMake(40, self.view.bounds.size.height - 120, self.view.bounds.size.width - 80, 50);
    self.loadButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1];
    [self.loadButton setTitle:@"Load Game" forState:UIControlStateNormal];
    [self.loadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loadButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.loadButton.layer.cornerRadius = 12;
    [self.loadButton addTarget:self action:@selector(loadGame) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.loadButton];
}

- (void)loadGame {
    NSString* docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    NSString* dataWinPath = [docsDir stringByAppendingPathComponent:@"data.win"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataWinPath]) {
        self.infoLabel.text = @"data.win not found!\nPlace it via Files app";
        return;
    }

    char* path = safeStrdup([dataWinPath UTF8String]);
    char* saves = safeStrdup([[docsDir stringByAppendingPathComponent:@"saves"] UTF8String]);

    if (startRunner(path, saves)) {
        self.gameRunning = YES;
        self.infoLabel.hidden = YES;
        self.loadButton.hidden = YES;

        CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoop:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    } else {
        self.infoLabel.text = @"Failed to parse data.win!";
    }
    free(path);
    free(saves);
}

- (void)gameLoop:(CADisplayLink*)link {
    if (!gRunner || !self.gameRunning) {
        link.paused = YES;
        return;
    }

    [EAGLContext setCurrentContext:self.glContext];

    float dt = (float)(link.targetTimestamp - link.timestamp);
    if (dt <= 0 || dt > 0.1f) dt = 1.0f / 60.0f;

    RunnerKeyboard_beginFrame(gRunner->keyboard);
    RunnerMouse_beginFrame(gRunner->mouse);

    Runner_step(gRunner);

    if (gRunner->audioSystem) {
        gRunner->audioSystem->vtable->update(gRunner->audioSystem, dt);
    }

    int32_t winW = gWindowW;
    int32_t winH = gWindowH;

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

    int32_t gameW = gRunner->applicationWidth;
    int32_t gameH = gRunner->applicationHeight;

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
        teardownRunner();
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    self.touchCount = (int)touches.count;
    if (!gRunner) return;
    UITouch* touch = [touches anyObject];
    CGPoint pt = [touch locationInView:self.view];
    CGFloat scale = [UIScreen mainScreen].scale;
    Runner_updateMousePosition(gRunner, gWindowW, gWindowH, pt.x * scale, pt.y * scale);

    if (self.touchCount == 1) {
        RunnerMouse_onButtonDown(gRunner->mouse, GML_MB_LEFT);
    } else if (self.touchCount == 2) {
        RunnerMouse_onButtonDown(gRunner->mouse, GML_MB_RIGHT);
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!gRunner) return;
    UITouch* touch = [touches anyObject];
    CGPoint pt = [touch locationInView:self.view];
    CGFloat scale = [UIScreen mainScreen].scale;
    Runner_updateMousePosition(gRunner, gWindowW, gWindowH, pt.x * scale, pt.y * scale);
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!gRunner) return;
    if (self.touchCount == 1) {
        RunnerMouse_onButtonUp(gRunner->mouse, GML_MB_LEFT);
    } else if (self.touchCount == 2) {
        RunnerMouse_onButtonUp(gRunner->mouse, GML_MB_RIGHT);
    }
    self.touchCount = 0;
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

- (void)dealloc {
    teardownRunner();
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
