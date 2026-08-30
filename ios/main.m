#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>

#include "../loader/elf_loader.h"
#include "../jni/jni_fake.h"
#include "../util/file_logger.h"

#import <dlfcn.h>

static void _gmloader_nslog(NSString* fmt, ...) {
    FILE* log = filelog_get();
    if (log) {
        va_list ap;
        va_start(ap, fmt);
        NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        fprintf(log, "[NSLog] %s\n", [msg UTF8String]);
        fflush(log);
    }
}

#undef NSLog
#define NSLog(...) _gmloader_nslog(__VA_ARGS__)

extern bool gmloader_load(const char* libyoyo_path);
extern bool gmloader_start(void);
extern void gmloader_process(void);
extern void gmloader_key_event(int key, int action);
extern void gmloader_mouse_move(float x, float y);
extern void gmloader_mouse_button(int button, int action, float x, float y);
extern void gmloader_touch_event(int action, int pointer, float x, float y);
extern void gmloader_pause(void);
extern void gmloader_resume(void);
extern int g_window_width;
extern int g_window_height;

ElfDynLibSymbol symtable_libc[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_libm[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_libdl[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_liblog[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_libandroid[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_gles2[1] = {{NULL, NULL}};
ElfDynLibSymbol symtable_libz[1] = {{NULL, NULL}};

#define VK_LEFT     37
#define VK_UP       38
#define VK_RIGHT    39
#define VK_DOWN     40
#define VK_SPACE    32
#define VK_ESCAPE   27

@interface EAGLView : UIView
@property (strong, nonatomic) EAGLContext* glContext;
@property (assign, nonatomic) GLuint defaultFBO;
@property (assign, nonatomic) GLuint colorRenderbuffer;
@property (assign, nonatomic) GLuint depthRenderbuffer;
@property (assign, nonatomic) CADisplayLink* link;
@end

@implementation EAGLView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.multipleTouchEnabled = YES;
        self.opaque = YES;
        self.backgroundColor = [UIColor blackColor];

        CAEAGLLayer* eagl = (CAEAGLLayer*)self.layer;
        eagl.opaque = YES;
        eagl.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };

        _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!_glContext) {
            NSLog(@"Failed to create EAGLContext");
            return nil;
        }
        [EAGLContext setCurrentContext:_glContext];

        glGenFramebuffers(1, &_defaultFBO);
        glBindFramebuffer(GL_FRAMEBUFFER, _defaultFBO);

        glGenRenderbuffers(1, &_colorRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
        [_glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:eagl];
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_RENDERBUFFER, _colorRenderbuffer);

        GLint backingWidth, backingHeight;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);

        glGenRenderbuffers(1, &_depthRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, backingWidth, backingHeight);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                  GL_RENDERBUFFER, _depthRenderbuffer);

        glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);

        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"Framebuffer incomplete: 0x%x", glCheckFramebufferStatus(GL_FRAMEBUFFER));
        }

        NSLog(@"EAGLView: GL initialized, FBO=%u, %dx%d",
              _defaultFBO, backingWidth, backingHeight);

        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoop:)];
        _link.preferredFramesPerSecond = 30;
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    }
    return self;
}

- (void)gameLoop:(CADisplayLink*)link {
    if (!self.glContext) return;
    [EAGLContext setCurrentContext:self.glContext];

    static int frame_count = 0;
    frame_count++;
    if (frame_count <= 5 || frame_count % 300 == 0) {
        printf("[LOOP] frame %d\n", frame_count);
    }

    gmloader_process();

    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    [self.glContext presentRenderbuffer:GL_RENDERBUFFER];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint pt = [touch locationInView:self];
        CGFloat scale = [UIScreen mainScreen].scale;
        gmloader_touch_event(0, 0, pt.x * scale, pt.y * scale);
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint pt = [touch locationInView:self];
        CGFloat scale = [UIScreen mainScreen].scale;
        gmloader_touch_event(2, 0, pt.x * scale, pt.y * scale);
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint pt = [touch locationInView:self];
        CGFloat scale = [UIScreen mainScreen].scale;
        gmloader_touch_event(1, 0, pt.x * scale, pt.y * scale);
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint pt = [touch locationInView:self];
        CGFloat scale = [UIScreen mainScreen].scale;
        gmloader_touch_event(1, 0, pt.x * scale, pt.y * scale);
    }
}

- (void)dealloc {
    [_link invalidate];
}

@end

@interface GameViewController : UIViewController
@property (strong, nonatomic) EAGLView* glView;
@property (strong, nonatomic) UILabel* infoLabel;
@property (strong, nonatomic) UIButton* loadButton;
@property (strong, nonatomic) UIButton* logButton;
@property (strong, nonatomic) UIScrollView* logScrollView;
@property (strong, nonatomic) UILabel* logLabel;
@property (assign, nonatomic) BOOL gameRunning;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, self.view.bounds.size.width - 40, 200)];
    self.infoLabel.textColor = [UIColor whiteColor];
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.text = @"GMLoader-iOS\nLoading libyoyo.so...";
    self.infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.infoLabel];

    self.loadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loadButton.frame = CGRectMake(self.view.bounds.size.width/2 - 100, 320, 200, 50);
    self.loadButton.tintColor = [UIColor whiteColor];
    [self.loadButton setTitle:@"START GAME" forState:UIControlStateNormal];
    [self.loadButton addTarget:self action:@selector(startGame) forControlEvents:UIControlEventTouchUpInside];
    self.loadButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.loadButton];

    self.logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.logButton.frame = CGRectMake(self.view.bounds.size.width/2 - 100, 380, 200, 40);
    self.logButton.tintColor = [UIColor grayColor];
    [self.logButton setTitle:@"SHOW LOG" forState:UIControlStateNormal];
    [self.logButton addTarget:self action:@selector(toggleLog) forControlEvents:UIControlEventTouchUpInside];
    self.logButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.logButton];

    self.logScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 60, self.view.bounds.size.width - 20, self.view.bounds.size.height - 80)];
    self.logScrollView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
    self.logScrollView.layer.borderColor = [UIColor grayColor].CGColor;
    self.logScrollView.layer.borderWidth = 1;
    self.logScrollView.hidden = YES;
    self.logScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.logScrollView];

    self.logLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 0, self.view.bounds.size.width - 30, 2000)];
    self.logLabel.textColor = [UIColor greenColor];
    self.logLabel.numberOfLines = 0;
    self.logLabel.font = [UIFont fontWithName:@"Menlo" size:10];
    self.logLabel.textAlignment = NSTextAlignmentLeft;
    [self.logScrollView addSubview:self.logLabel];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString* libPath = [bundlePath stringByAppendingPathComponent:@"libyoyo.so"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:libPath]) {
            NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            libPath = [paths[0] stringByAppendingPathComponent:@"libyoyo.so"];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![[NSFileManager defaultManager] fileExistsAtPath:libPath]) {
                self.infoLabel.text = @"libyoyo.so not found!\nPlace it in the app bundle or Documents.";
                return;
            }

            NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:libPath error:nil];
            unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
            self.infoLabel.text = [NSString stringWithFormat:@"Loading libyoyo.so (%llu MB)...", fileSize / 1024 / 1024];
            NSLog(@"Loading libyoyo.so from: %s (%llu bytes)", [libPath UTF8String], fileSize);

            if (gmloader_load([libPath UTF8String])) {
                self.infoLabel.text = @"libyoyo.so loaded!\nPress START GAME.";
                self.loadButton.hidden = NO;
            } else {
                self.infoLabel.text = @"Failed to load libyoyo.so\nTap SHOW LOG for details.";
                self.logButton.hidden = NO;
            }
        });
    });
}

- (void)toggleLog {
    if (self.logScrollView.hidden) {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* logPath = [paths[0] stringByAppendingPathComponent:@"log.txt"];
        NSString* content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        if (!content) content = @"(no log file found)";

        self.logLabel.text = content;
        self.logLabel.frame = CGRectMake(5, 0, self.logScrollView.bounds.size.width - 30, MAX(2000, content.length * 0.5));
        self.logScrollView.contentSize = CGSizeMake(self.logScrollView.bounds.size.width, self.logLabel.frame.size.height + 20);

        self.logScrollView.hidden = NO;
        [self.logButton setTitle:@"HIDE LOG" forState:UIControlStateNormal];
        self.infoLabel.hidden = YES;
        self.loadButton.hidden = YES;
    } else {
        self.logScrollView.hidden = YES;
        [self.logButton setTitle:@"SHOW LOG" forState:UIControlStateNormal];
        if (!self.gameRunning) {
            self.infoLabel.hidden = NO;
            self.loadButton.hidden = NO;
        }
    }
}

- (void)startGame {
    if (self.gameRunning) return;

    self.glView = [[EAGLView alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.glView];

    self.infoLabel.hidden = YES;
    self.loadButton.hidden = YES;

    if (gmloader_start()) {
        self.gameRunning = YES;
        NSLog(@"Game started!");
    } else {
        self.infoLabel.text = @"Failed to start game!\nTap SHOW LOG for details.";
        self.infoLabel.hidden = NO;
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];

    NSLog(@"GMLoader-iOS started");
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
    gmloader_pause();
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
    gmloader_resume();
}

@end

#include <signal.h>
#include <execinfo.h>

static void crash_handler(int sig) {
    FILE* log = filelog_get();
    if (log) {
        fprintf(log, "\n!!! CRASH signal %d !!!\n", sig);
        void* callstack[128];
        int frames = backtrace(callstack, 128);
        char** symbols = backtrace_symbols(callstack, frames);
        if (symbols) {
            for (int i = 0; i < frames; i++) {
                fprintf(log, "  %s\n", symbols[i]);
            }
            free(symbols);
        }
        fflush(log);
    }
    _exit(1);
}

int main(int argc, char* argv[]) {
    @autoreleasepool {
        signal(SIGSEGV, crash_handler);
        signal(SIGBUS, crash_handler);
        signal(SIGABRT, crash_handler);
        signal(SIGFPE, crash_handler);
        signal(SIGILL, crash_handler);

        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docsDir = paths[0];
        NSString* logPath = [docsDir stringByAppendingPathComponent:@"log.txt"];

        filelog_init_with_path([logPath UTF8String]);

        printf("=== GMLoader-iOS v0.5 ===\n");
        printf("Documents dir: %s\n", [docsDir UTF8String]);
        printf("Log file: %s\n", [logPath UTF8String]);
        printf("Bundle path: %s\n", [[[NSBundle mainBundle] bundlePath] UTF8String]);

        NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docsDir error:nil];
        printf("Documents contents: %lu files\n", (unsigned long)files.count);
        for (NSString* f in files) {
            printf("  - %s\n", [f UTF8String]);
        }

        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        NSArray* bundleFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
        printf("\nBundle contents: %lu files\n", (unsigned long)bundleFiles.count);
        for (NSString* f in bundleFiles) {
            NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:
                                   [bundlePath stringByAppendingPathComponent:f] error:nil];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            printf("  %s (%llu KB)\n", [f UTF8String], size / 1024);
        }
        printf("\n");

        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
