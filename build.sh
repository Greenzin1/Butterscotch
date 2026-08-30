#!/bin/bash
CC=/tmp/theos/toolchain/iphone/bin/clang
SDK=/tmp/theos_sdks/iPhoneOS14.5.sdk
TARGET="-target arm64-apple-ios16.0 -arch arm64"
SYSROOT="-isysroot $SDK"
FLAGS="$TARGET $SYSROOT -O2 -Wno-everything -fobjc-arc"

INCLUDES="-I/tmp/gmloader-ios -I/tmp/gmloader-ios/loader -I/tmp/gmloader-ios/jni -I/tmp/gmloader-ios/gmloader -I/tmp/gmloader-ios/util"
FRAMEWORKS="-framework UIKit -framework OpenGLES -framework QuartzCore -framework Foundation -framework CoreGraphics"
LDFLAGS="$TARGET $SYSROOT $FRAMEWORKS -dead_strip"

OUT=/tmp/gmloader-ios/build
mkdir -p $OUT

echo "=== Compiling ELF loader ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/loader/elf_loader.c -o $OUT/elf_loader.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: elf_loader.c"; exit 1; fi

echo "=== Compiling file logger ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/util/file_logger.c -o $OUT/file_logger.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: file_logger.c"; exit 1; fi

echo "=== Compiling libc stubs ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/stubs/libc_stubs.c -o $OUT/libc_stubs.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: libc_stubs.c"; exit 1; fi

echo "=== Compiling libdl stubs ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/stubs/libdl_stubs.c -o $OUT/libdl_stubs.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: libdl_stubs.c"; exit 1; fi

echo "=== Compiling liblog stubs ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/stubs/liblog_stubs.c -o $OUT/liblog_stubs.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: liblog_stubs.c"; exit 1; fi

echo "=== Compiling libandroid stubs ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/stubs/libandroid_stubs.c -o $OUT/libandroid_stubs.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: libandroid_stubs.c"; exit 1; fi

echo "=== Compiling JNI fake ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/jni/jni_fake.c -o $OUT/jni_fake.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: jni_fake.c"; exit 1; fi

echo "=== Compiling gmloader ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/gmloader/gmloader.c -o $OUT/gmloader.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: gmloader.c"; exit 1; fi

echo "=== Compiling iOS main ==="
$CC $FLAGS $INCLUDES -c /tmp/gmloader-ios/ios/main.m -o $OUT/ios_main.o 2>&1
if [ $? -ne 0 ]; then echo "FAILED: ios/main.m"; exit 1; fi

echo "=== Linking ==="
$CC $LDFLAGS \
    $OUT/elf_loader.o \
    $OUT/file_logger.o \
    $OUT/libc_stubs.o \
    $OUT/libdl_stubs.o \
    $OUT/liblog_stubs.o \
    $OUT/libandroid_stubs.o \
    $OUT/jni_fake.o \
    $OUT/gmloader.o \
    $OUT/ios_main.o \
    -o $OUT/GMLoader 2>&1
if [ $? -ne 0 ]; then echo "FAILED: linking"; exit 1; fi

echo "=== Done! ==="
ls -lh $OUT/GMLoader
echo "Binary: $OUT/GMLoader"
