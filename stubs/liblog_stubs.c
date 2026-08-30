#include <stdio.h>
#include <stdarg.h>

#define ANDROID_LOG_VERBOSE 2
#define ANDROID_LOG_DEBUG   3
#define ANDROID_LOG_INFO    4
#define ANDROID_LOG_WARN    5
#define ANDROID_LOG_ERROR   6
#define ANDROID_LOG_FATAL   7

int __android_log_print(int prio, const char* tag, const char* fmt, ...) {
    const char* prefix = "";
    switch (prio) {
        case ANDROID_LOG_VERBOSE: prefix = "V/"; break;
        case ANDROID_LOG_DEBUG:   prefix = "D/"; break;
        case ANDROID_LOG_INFO:    prefix = "I/"; break;
        case ANDROID_LOG_WARN:    prefix = "W/"; break;
        case ANDROID_LOG_ERROR:   prefix = "E/"; break;
        case ANDROID_LOG_FATAL:   prefix = "F/"; break;
        default:                  prefix = "?/"; break;
    }
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%s%s] ", prefix, tag);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    return 0;
}

int __android_log_write(int prio, const char* tag, const char* text) {
    (void)prio;
    fprintf(stderr, "[%s] %s\n", tag, text);
    return 0;
}

int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap) {
    (void)prio;
    fprintf(stderr, "[%s] ", tag);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    return 0;
}

int __android_log_buf_print(int bufID, int prio, const char* tag, const char* fmt, ...) {
    (void)bufID;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%s] ", tag);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    return 0;
}
