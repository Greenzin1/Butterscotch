#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "elf.h"

#define ELF_MAX_MODULES 16

typedef struct {
    const char* name;
    void* address;
} ElfDynLibSymbol;

typedef struct {
    char name[256];
    uint8_t* base;
    size_t size;
    Elf64_Phdr* phdrs;
    int phdr_count;
    Elf64_Sym* dynsym;
    const char* dynstr;
    Elf64_Rela* rela;
    size_t rela_count;
    Elf64_Rela* jmprel;
    size_t jmprel_count;
    bool loaded;
} ElfModule;

extern ElfDynLibSymbol symtable_libc[];
extern ElfDynLibSymbol symtable_libm[];
extern ElfDynLibSymbol symtable_libdl[];
extern ElfDynLibSymbol symtable_liblog[];
extern ElfDynLibSymbol symtable_libandroid[];
extern ElfDynLibSymbol symtable_gles2[];
extern ElfDynLibSymbol symtable_libz[];

bool elf_load_module(const char* path, ElfModule* mod);
bool elf_relocate_module(ElfModule* mod);
void* elf_find_symbol(ElfModule* mod, const char* name);
void elf_call_init(ElfModule* mod);
