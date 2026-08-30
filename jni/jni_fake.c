#include "jni_fake.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static JNIEnv g_env_storage;
static JNIEnv* g_env = NULL;

void jni_fake_init(void) {
    memset(&g_env_storage, 0, sizeof(g_env_storage));
    g_env = &g_env_storage;
    printf("[JNI] Fake JNI initialized\n");
}

JNIEnv* jni_fake_get_env(void) {
    if (!g_env) jni_fake_init();
    return g_env;
}
