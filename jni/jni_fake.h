#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef void* jobject;
typedef void* jclass;
typedef void* jstring;
typedef void* jmethodID;
typedef void* jfieldID;
typedef int32_t jint;
typedef int64_t jlong;
typedef float jfloat;
typedef double jdouble;
typedef uint8_t jboolean;
typedef void* JNIEnv;
typedef void* JavaVM;

typedef struct {
    const char* name;
    void* address;
} JNINativeMethod;

#define JNI_OK 0
#define JNI_ERR (-1)
#define JNI_TRUE 1
#define JNI_FALSE 0

void jni_fake_init(void);
JNIEnv* jni_fake_get_env(void);
