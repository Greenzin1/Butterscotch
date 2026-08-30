#include <stdio.h>
#include <dlfcn.h>

void* android_dlopen_ext(const char* filename, int flag, const void* extinfo) {
    return dlopen(filename, flag);
}

int dlclose(void* handle) {
    return 0;
}
