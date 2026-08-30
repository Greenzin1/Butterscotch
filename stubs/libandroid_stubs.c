#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// AAssetManager stubs
typedef void* AAssetManager;
typedef void* AAsset;

AAsset* AAssetManager_open(void* mgr, const char* filename, int mode) {
    (void)mgr; (void)filename; (void)mode;
    return NULL;
}

long long AAsset_getLength(AAsset* asset) {
    (void)asset;
    return 0;
}

int AAsset_read(AAsset* asset, void* buf, size_t count) {
    (void)asset; (void)buf; (void)count;
    return -1;
}

void AAsset_close(AAsset* asset) {
    (void)asset;
}

// AudioTrack stubs
typedef void* AudioTrack;

int AudioTrack_getMinBufferSize(int sampleRate, int channelConfig, int audioFormat) {
    (void)sampleRate; (void)channelConfig; (void)audioFormat;
    return 4096;
}

int AudioTrack_write(AudioTrack* track, const void* buffer, int offsetInBytes, int sizeInBytes) {
    (void)track; (void)buffer; (void)offsetInBytes; (void)sizeInBytes;
    return sizeInBytes;
}

// ANativeWindow stubs
int ANativeWindow_getWidth(void* window) {
    (void)window;
    return 800;
}

int ANativeWindow_getHeight(void* window) {
    (void)window;
    return 600;
}

// Sensor stubs
typedef void* ASensorManager;
typedef void* ASensor;

ASensorManager* ASensorManager_getInstance(void) {
    static int instance = 0;
    return (ASensorManager*)&instance;
}

const ASensor* ASensorManager_getDefaultSensor(ASensorManager* mgr, int type) {
    (void)mgr; (void)type;
    return NULL;
}

// Looper stubs
typedef void* ALooper;

ALooper* ALooper_forThread(void) {
    static int looper = 0;
    return (ALooper*)&looper;
}

int ALooper_addFd(ALooper* looper, int fd, int ident, int events, void* callback, void* data) {
    (void)looper; (void)fd; (void)ident; (void)events; (void)callback; (void)data;
    return 0;
}
