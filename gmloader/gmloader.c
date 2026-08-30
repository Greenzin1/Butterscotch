#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach-o/dyld.h>

#include "../loader/elf_loader.h"
#include "../jni/jni_fake.h"

static ElfModule g_yoyo_module;

typedef void (*StartupFn)(void* env, void* thiz);
typedef void (*ProcessFn)(void* env, void* thiz);
typedef void (*KeyEventFn)(void* env, void* thiz, int key, int action);
typedef void (*SetKeyValueFn)(void* env, void* thiz, int key, int pressed);
typedef void (*MouseMoveEventFn)(void* env, void* thiz, float x, float y);
typedef void (*MouseButtonEventFn)(void* env, void* thiz, int button, int action, float x, float y);
typedef void (*MouseWheelEventFn)(void* env, void* thiz, float delta);
typedef void (*TouchEventFn)(void* env, void* thiz, int action, int pointer, float x, float y);
typedef void (*RenderSplashFn)(void* env, void* thiz);
typedef void (*ResumeFn)(void* env, void* thiz);
typedef void (*PauseFn)(void* env, void* thiz);
typedef void (*ChangeInitialScreenFrequencyFn)(void* env, void* thiz, int freq);
typedef void (*UpdateGameSpeedFn)(void* env, void* thiz, int speed);
typedef void (*OnDisplayFrequencyChangedFn)(void* env, void* thiz, int freq);
typedef int  (*GetGuiWidthFn)(void* env, void* thiz);
typedef int  (*GetGuiHeightFn)(void* env, void* thiz);

static StartupFn pStartup = NULL;
static ProcessFn pProcess = NULL;
static KeyEventFn pKeyEvent = NULL;
static SetKeyValueFn pSetKeyValue = NULL;
static MouseMoveEventFn pMouseMoveEvent = NULL;
static MouseButtonEventFn pMouseButtonEvent = NULL;
static MouseWheelEventFn pMouseWheelEvent = NULL;
static TouchEventFn pTouchEvent = NULL;
static RenderSplashFn pRenderSplash = NULL;
static ResumeFn pResume = NULL;
static PauseFn pPause = NULL;
static ChangeInitialScreenFrequencyFn pChangeInitialScreenFrequency = NULL;
static UpdateGameSpeedFn pUpdateGameSpeed = NULL;
static OnDisplayFrequencyChangedFn pOnDisplayFrequencyChanged = NULL;
static GetGuiWidthFn pGetGuiWidth = NULL;
static GetGuiHeightFn pGetGuiHeight = NULL;

int g_window_width = 800;
int g_window_height = 600;

extern ElfDynLibSymbol symtable_libc[];
extern ElfDynLibSymbol symtable_libm[];
extern ElfDynLibSymbol symtable_libdl[];
extern ElfDynLibSymbol symtable_liblog[];
extern ElfDynLibSymbol symtable_libandroid[];
extern ElfDynLibSymbol symtable_gles2[];
extern ElfDynLibSymbol symtable_libz[];

static void* find_sym(ElfModule* mod, const char* name) {
    return elf_find_symbol(mod, name);
}

static void* resolve_jni_func(const char* java_name) {
    void* sym = find_sym(&g_yoyo_module, java_name);
    if (sym) return sym;
    char buf[512];
    snprintf(buf, sizeof(buf), "_%s", java_name);
    sym = find_sym(&g_yoyo_module, buf);
    if (sym) return sym;
    return NULL;
}

bool gmloader_load(const char* libyoyo_path) {
    printf("=== GMLoader-iOS ===\n");
    printf("Loading %s...\n", libyoyo_path);

    jni_fake_init();

    if (!elf_load_module(libyoyo_path, &g_yoyo_module)) {
        fprintf(stderr, "Failed to load libyoyo.so\n");
        return false;
    }

    if (!elf_relocate_module(&g_yoyo_module)) {
        fprintf(stderr, "Failed to relocate libyoyo.so\n");
        return false;
    }

    printf("\n=== Resolving RunnerJNILib methods ===\n");

    #define RESOLVE(var, name) do { \
        var = (typeof(var))resolve_jni_func(name); \
        if (var) printf("  [OK] %s -> %p\n", name, var); \
        else printf("  [!!] %s -> NOT FOUND\n", name); \
    } while(0)

    RESOLVE(pStartup, "Java_com_yoyogames_runner_RunnerJNILib_Startup");
    RESOLVE(pProcess, "Java_com_yoyogames_runner_RunnerJNILib_Process");
    RESOLVE(pKeyEvent, "Java_com_yoyogames_runner_RunnerJNILib_KeyEvent");
    RESOLVE(pSetKeyValue, "Java_com_yoyogames_runner_RunnerJNILib_SetKeyValue");
    RESOLVE(pMouseMoveEvent, "Java_com_yoyogames_runner_RunnerJNILib_MouseMoveEvent");
    RESOLVE(pMouseButtonEvent, "Java_com_yoyogames_runner_RunnerJNILib_MouseButtonEvent");
    RESOLVE(pMouseWheelEvent, "Java_com_yoyogames_runner_RunnerJNILib_MouseWheelEvent");
    RESOLVE(pTouchEvent, "Java_com_yoyogames_runner_RunnerJNILib_TouchEvent");
    RESOLVE(pRenderSplash, "Java_com_yoyogames_runner_RunnerJNILib_RenderSplash");
    RESOLVE(pResume, "Java_com_yoyogames_runner_RunnerJNILib_Resume");
    RESOLVE(pPause, "Java_com_yoyogames_runner_RunnerJNILib_Pause");
    RESOLVE(pGetGuiWidth, "Java_com_yoyogames_runner_RunnerJNILib_getGuiWidth");
    RESOLVE(pGetGuiHeight, "Java_com_yoyogames_runner_RunnerJNILib_getGuiHeight");

    printf("\n=== Resolving internal symbols ===\n");
    void* the_functions = find_sym(&g_yoyo_module, "the_functions");
    if (the_functions) printf("  [OK] the_functions -> %p\n", the_functions);

    printf("\n=== Loading complete ===\n");
    return true;
}

bool gmloader_start(void) {
    if (!pStartup) {
        fprintf(stderr, "Startup function not resolved!\n");
        return false;
    }
    printf("Calling Startup...\n");
    JNIEnv* env = jni_fake_get_env();
    pStartup(env, NULL);
    printf("Startup complete!\n");
    return true;
}

void gmloader_process(void) {
    if (!pProcess) return;
    JNIEnv* env = jni_fake_get_env();
    pProcess(env, NULL);
}

void gmloader_key_event(int key, int action) {
    if (pKeyEvent) {
        JNIEnv* env = jni_fake_get_env();
        pKeyEvent(env, NULL, key, action);
    }
    if (pSetKeyValue) {
        JNIEnv* env = jni_fake_get_env();
        pSetKeyValue(env, NULL, key, action);
    }
}

void gmloader_mouse_move(float x, float y) {
    if (pMouseMoveEvent) {
        JNIEnv* env = jni_fake_get_env();
        pMouseMoveEvent(env, NULL, x, y);
    }
}

void gmloader_mouse_button(int button, int action, float x, float y) {
    if (pMouseButtonEvent) {
        JNIEnv* env = jni_fake_get_env();
        pMouseButtonEvent(env, NULL, button, action, x, y);
    }
}

void gmloader_touch_event(int action, int pointer, float x, float y) {
    if (pTouchEvent) {
        JNIEnv* env = jni_fake_get_env();
        pTouchEvent(env, NULL, action, pointer, x, y);
    }
}

void gmloader_pause(void) {
    if (pPause) {
        JNIEnv* env = jni_fake_get_env();
        pPause(env, NULL);
    }
}

void gmloader_resume(void) {
    if (pResume) {
        JNIEnv* env = jni_fake_get_env();
        pResume(env, NULL);
    }
}
