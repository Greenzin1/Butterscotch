#include "elf_loader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <errno.h>

static ElfModule g_modules[ELF_MAX_MODULES];
static int g_module_count = 0;

static void* lookup_symbol_table(ElfDynLibSymbol* table, const char* name) {
    if (!table) return NULL;
    for (int i = 0; table[i].name != NULL; i++) {
        if (strcmp(table[i].name, name) == 0)
            return table[i].address;
    }
    return NULL;
}

static void* resolve_direct_lookup(const char* name);

static void* resolve_external(const char* name) {
    void* sym;
    if ((sym = lookup_symbol_table(symtable_libc, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_libm, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_libdl, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_liblog, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_libandroid, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_gles2, name))) return sym;
    if ((sym = lookup_symbol_table(symtable_libz, name))) return sym;
    sym = dlsym(RTLD_DEFAULT, name);
    if (sym) return sym;
    return resolve_direct_lookup(name);
}

typedef struct { const char* name; void* addr; } DirectSymbol;

// Forward declarations from stubs
extern int __android_log_print(int, const char*, const char*, ...);
extern int __android_log_write(int, const char*, const char*);
extern int __android_log_vprint(int, const char*, const char*, va_list);
extern int __android_log_buf_print(int, int, const char*, const char*, ...);
extern void* android_dlopen_ext(const char*, int, const void*);
extern int* __errno_location(void);
extern void* AAssetManager_open(void*, const char*, int);
extern long long AAsset_getLength(void*);
extern int AAsset_read(void*, void*, size_t);
extern void AAsset_close(void*);
extern int AudioTrack_getMinBufferSize(int, int, int);
extern int AudioTrack_write(void*, const void*, int, int);
extern int ANativeWindow_getWidth(void*);
extern int ANativeWindow_getHeight(void*);
extern void* ASensorManager_getInstance(void);
extern const void* ASensorManager_getDefaultSensor(void*, int);
extern void* ALooper_forThread(void);
extern int ALooper_addFd(void*, int, int, int, void*, void*);

static DirectSymbol direct_symbols[] = {
    // liblog
    { "__android_log_print",    (void*)__android_log_print },
    { "__android_log_write",    (void*)__android_log_write },
    { "__android_log_vprint",   (void*)__android_log_vprint },
    { "__android_log_buf_print",(void*)__android_log_buf_print },
    // libdl
    { "android_dlopen_ext",     (void*)android_dlopen_ext },
    // libc
    { "__errno_location",       (void*)__errno_location },
    // libandroid
    { "AAssetManager_open",     (void*)AAssetManager_open },
    { "AAsset_getLength",       (void*)AAsset_getLength },
    { "AAsset_read",            (void*)AAsset_read },
    { "AAsset_close",           (void*)AAsset_close },
    { "AudioTrack_getMinBufferSize", (void*)AudioTrack_getMinBufferSize },
    { "AudioTrack_write",       (void*)AudioTrack_write },
    { "ANativeWindow_getWidth", (void*)ANativeWindow_getWidth },
    { "ANativeWindow_getHeight",(void*)ANativeWindow_getHeight },
    { "ASensorManager_getInstance",  (void*)ASensorManager_getInstance },
    { "ASensorManager_getDefaultSensor", (void*)ASensorManager_getDefaultSensor },
    { "ALooper_forThread",      (void*)ALooper_forThread },
    { "ALooper_addFd",          (void*)ALooper_addFd },
    { NULL, NULL }
};

static void* resolve_direct_lookup(const char* name) {
    for (int i = 0; direct_symbols[i].name != NULL; i++) {
        if (strcmp(direct_symbols[i].name, name) == 0)
            return direct_symbols[i].addr;
    }
    return NULL;
}

bool elf_load_module(const char* path, ElfModule* mod) {
    fprintf(stderr, "elf_load_module: opening %s\n", path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "elf_load: cannot open %s (errno=%d)\n", path, errno);
        return false;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        fprintf(stderr, "elf_load: fstat failed (errno=%d)\n", errno);
        close(fd);
        return false;
    }
    fprintf(stderr, "elf_load: file size = %lld bytes\n", (long long)st.st_size);

    Elf64_Ehdr ehdr;
    fprintf(stderr, "elf_load: reading ELF header (%zu bytes)\n", sizeof(ehdr));
    if (pread(fd, &ehdr, sizeof(ehdr), 0) != sizeof(ehdr)) {
        fprintf(stderr, "elf_load: FAILED to read ELF header (errno=%d)\n", errno);
        close(fd);
        return false;
    }

    if (memcmp(ehdr.e_ident, "\x7f" "ELF", 4) != 0) {
        fprintf(stderr, "elf_load: not a valid ELF file\n");
        close(fd);
        return false;
    }

    if (ehdr.e_machine != 0xB7) {
        fprintf(stderr, "elf_load: not an AArch64 binary\n");
        close(fd);
        return false;
    }

    if (ehdr.e_type != ET_DYN) {
        fprintf(stderr, "elf_load: not a shared object (ET_DYN)\n");
        close(fd);
        return false;
    }

    printf("elf_load: %s - %d program headers, entry=0x%llx\n",
           path, ehdr.e_phnum, (unsigned long long)ehdr.e_entry);

    Elf64_Phdr* phdrs = malloc(ehdr.e_phnum * sizeof(Elf64_Phdr));
    if (!phdrs) {
        fprintf(stderr, "elf_load: malloc failed for phdrs (%d entries)\n", ehdr.e_phnum);
        close(fd);
        return false;
    }
    fprintf(stderr, "elf_load: reading %d phdrs from offset 0x%llx\n",
            ehdr.e_phnum, (unsigned long long)ehdr.e_phoff);
    ssize_t phdr_read = pread(fd, phdrs, ehdr.e_phnum * sizeof(Elf64_Phdr), ehdr.e_phoff);
    if (phdr_read != (ssize_t)(ehdr.e_phnum * sizeof(Elf64_Phdr))) {
        fprintf(stderr, "elf_load: FAILED to read program headers (got %zd, errno=%d)\n", phdr_read, errno);
        free(phdrs);
        close(fd);
        return false;
    }

    Elf64_Addr min_vaddr = UINT64_MAX;
    Elf64_Addr max_vaddr = 0;
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;
        if (phdrs[i].p_vaddr < min_vaddr)
            min_vaddr = phdrs[i].p_vaddr;
        if (phdrs[i].p_vaddr + phdrs[i].p_memsz > max_vaddr)
            max_vaddr = phdrs[i].p_vaddr + phdrs[i].p_memsz;
    }

    size_t total_size = max_vaddr - min_vaddr;
    size_t page_size = (size_t)getpagesize();
    size_t aligned_size = (total_size + page_size - 1) & ~(page_size - 1);

    fprintf(stderr, "elf_load: min_vaddr=0x%llx max_vaddr=0x%llx total=0x%zx aligned=0x%zx pagesize=%zu\n",
            (unsigned long long)min_vaddr, (unsigned long long)max_vaddr,
            total_size, aligned_size, page_size);

    uint8_t* base = mmap(NULL, aligned_size,
                         PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) {
        perror("elf_load: mmap base");
        free(phdrs);
        close(fd);
        return false;
    }

    memset(base, 0, aligned_size);

    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;
        Elf64_Addr seg_start = phdrs[i].p_vaddr - min_vaddr;
        if (phdrs[i].p_filesz > 0) {
            fprintf(stderr, "elf_load: reading segment %d from file_offset=0x%llx -> mem_offset=0x%llx size=0x%llx\n",
                    i, (unsigned long long)phdrs[i].p_offset,
                    (unsigned long long)seg_start,
                    (unsigned long long)phdrs[i].p_filesz);
            lseek(fd, phdrs[i].p_offset, SEEK_SET);
            ssize_t nread = read(fd, base + seg_start, phdrs[i].p_filesz);
            if (nread != (ssize_t)phdrs[i].p_filesz) {
                fprintf(stderr, "elf_load: FAILED to read segment %d (got %zd, errno=%d)\n", i, nread, errno);
    // phdrs kept in mod->phdrs for relocate phase — do not free here
                close(fd);
                munmap(base, aligned_size);
                return false;
            }
            fprintf(stderr, "elf_load: segment %d read OK (%zd bytes)\n", i, nread);
        }
    }

    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;

        Elf64_Addr seg_start = phdrs[i].p_vaddr - min_vaddr;
        Elf64_Addr seg_end = seg_start + phdrs[i].p_memsz;
        int prot = PROT_READ;
        if (phdrs[i].p_flags & PF_W) prot |= PROT_WRITE;
        if (phdrs[i].p_flags & PF_X) prot |= PROT_EXEC;

        Elf64_Addr page_start = seg_start & ~(page_size - 1);
        Elf64_Addr page_end = (seg_end + page_size - 1) & ~(page_size - 1);

        if (mprotect(base + page_start, page_end - page_start, prot) != 0) {
            perror("elf_load: mprotect");
        }

        printf("  LOAD segment %d: vaddr=0x%llx filesz=0x%llx memsz=0x%llx prot=%c%c%c\n",
               i,
               (unsigned long long)phdrs[i].p_vaddr,
               (unsigned long long)phdrs[i].p_filesz,
               (unsigned long long)phdrs[i].p_memsz,
               (phdrs[i].p_flags & PF_R) ? 'R' : '-',
               (phdrs[i].p_flags & PF_W) ? 'W' : '-',
               (phdrs[i].p_flags & PF_X) ? 'X' : '-');
    }

    Elf64_Dyn* dyn = NULL;
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdrs[i].p_type == PT_DYNAMIC) {
            dyn = (Elf64_Dyn*)(base + phdrs[i].p_vaddr - min_vaddr);
            break;
        }
    }

    free(phdrs);
    close(fd);

    if (!dyn) {
        fprintf(stderr, "elf_load: no PT_DYNAMIC found\n");
        munmap(base, aligned_size);
        return false;
    }

    const char* dynstr = NULL;
    Elf64_Sym* dynsym = NULL;
    Elf64_Rela* rela = NULL;
    size_t rela_count = 0;
    Elf64_Rela* jmprel = NULL;
    size_t jmprel_count = 0;

    for (Elf64_Dyn* d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
            case DT_STRTAB:
                dynstr = (const char*)(base + d->d_un.d_ptr - min_vaddr);
                break;
            case DT_SYMTAB:
                dynsym = (Elf64_Sym*)(base + d->d_un.d_ptr - min_vaddr);
                break;
            case DT_RELA:
                rela = (Elf64_Rela*)(base + d->d_un.d_ptr - min_vaddr);
                break;
            case DT_RELASZ:
                rela_count = d->d_un.d_val / sizeof(Elf64_Rela);
                break;
            case DT_JMPREL:
                jmprel = (Elf64_Rela*)(base + d->d_un.d_ptr - min_vaddr);
                break;
            case DT_PLTRELSZ:
                jmprel_count = d->d_un.d_val / sizeof(Elf64_Rela);
                break;
            default:
                break;
        }
    }

    strncpy(mod->name, path, sizeof(mod->name) - 1);
    mod->base = base;
    mod->size = aligned_size;
    mod->phdrs = phdrs;
    mod->phdr_count = ehdr.e_phnum;
    mod->dynsym = dynsym;
    mod->dynstr = dynstr;
    mod->rela = rela;
    mod->rela_count = rela_count;
    mod->jmprel = jmprel;
    mod->jmprel_count = jmprel_count;
    mod->loaded = true;

    printf("elf_load: loaded %s at %p (size=0x%zx)\n", path, base, aligned_size);
    printf("elf_load: dynstr=%p dynsym=%p rela_count=%zu jmprel_count=%zu\n",
           dynstr, dynsym, rela_count, jmprel_count);

    for (Elf64_Dyn* d = dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag == DT_NEEDED && dynstr) {
            printf("elf_load:   NEEDED: %s\n", dynstr + d->d_un.d_val);
        }
    }

    return true;
}

bool elf_relocate_module(ElfModule* mod) {
    if (!mod->loaded || !mod->rela) return false;

    // Make entire module RW so all writes during relocation work
    size_t page_size = (size_t)getpagesize();
    uint64_t mod_start = (uint64_t)mod->base;
    uint64_t mod_end = mod_start + mod->size;
    uint64_t ps = mod_start & ~(page_size - 1);
    uint64_t pe = (mod_end + page_size - 1) & ~(page_size - 1);
    mprotect((void*)ps, pe - ps, PROT_READ | PROT_WRITE);

    printf("elf_relocate: processing %zu RELA entries...\n", mod->rela_count);

    int unresolved_count = 0;
    for (size_t i = 0; i < mod->rela_count; i++) {
        Elf64_Rela* r = &mod->rela[i];
        uint32_t type = ELF64_R_TYPE(r->r_info);
        uint32_t sym_idx = ELF64_R_SYM(r->r_info);
        Elf64_Sym* sym = &mod->dynsym[sym_idx];
        const char* sym_name = mod->dynstr + sym->st_name;
        uint64_t* patch = (uint64_t*)(mod->base + r->r_offset);

        switch (type) {
            case R_AARCH64_RELATIVE: {
                uint64_t value = (uint64_t)mod->base + r->r_addend;
                *patch = value;
                break;
            }
            case R_AARCH64_ABS64:
            case R_AARCH64_GLOB_DAT:
            case R_AARCH64_JUMP_SLOT: {
                void* resolved = resolve_external(sym_name);
                if (resolved) {
                    *patch = (uint64_t)resolved;
                } else if (ELF64_ST_BIND(sym->st_info) == 1) {
                    fprintf(stderr, "elf_relocate: UNRESOLVED: %s (type=0x%x)\n", sym_name, type);
                    unresolved_count++;
                }
                break;
            }
            default:
                fprintf(stderr, "elf_relocate: unknown reloc type 0x%x at 0x%llx\n",
                        type, (unsigned long long)r->r_offset);
                break;
        }
    }

    if (mod->jmprel && mod->jmprel_count > 0) {
        printf("elf_relocate: processing %zu PLT relocations...\n", mod->jmprel_count);
        for (size_t i = 0; i < mod->jmprel_count; i++) {
            Elf64_Rela* r = &mod->jmprel[i];
            uint32_t type = ELF64_R_TYPE(r->r_info);
            uint32_t sym_idx = ELF64_R_SYM(r->r_info);
            Elf64_Sym* sym = &mod->dynsym[sym_idx];
            const char* sym_name = mod->dynstr + sym->st_name;
            uint64_t* patch = (uint64_t*)(mod->base + r->r_offset);

            if (type == R_AARCH64_JUMP_SLOT || type == R_AARCH64_ABS64 ||
                type == R_AARCH64_GLOB_DAT) {
                void* resolved = resolve_external(sym_name);
                if (resolved) {
                    *patch = (uint64_t)resolved;
                } else {
                    fprintf(stderr, "elf_relocate: UNRESOLVED PLT: %s\n", sym_name);
                }
            }
        }
    }

    // Restore correct permissions per segment
    for (int i = 0; i < mod->phdr_count; i++) {
        if (mod->phdrs[i].p_type != PT_LOAD) continue;
        int prot = 0;
        if (mod->phdrs[i].p_flags & PF_R) prot |= PROT_READ;
        if (mod->phdrs[i].p_flags & PF_W) prot |= PROT_WRITE;
        if (mod->phdrs[i].p_flags & PF_X) prot |= PROT_EXEC;
        uint64_t seg_start = (uint64_t)(mod->base + (mod->phdrs[i].p_vaddr & ~(page_size - 1)));
        uint64_t seg_end = (uint64_t)(mod->base + ((mod->phdrs[i].p_vaddr + mod->phdrs[i].p_memsz + page_size - 1) & ~(page_size - 1)));
        mprotect((void*)seg_start, seg_end - seg_start, prot);
    }

    printf("elf_relocate: done (%d unresolved)\n", unresolved_count);
    return true;
}

void* elf_find_symbol(ElfModule* mod, const char* name) {
    if (!mod->loaded || !mod->dynsym || !mod->dynstr) return NULL;

    for (size_t i = 0; mod->dynsym[i].st_name != 0; i++) {
        Elf64_Sym* sym = &mod->dynsym[i];
        if (sym->st_value == 0) continue;
        const char* sym_name = mod->dynstr + sym->st_name;
        if (sym_name && strcmp(sym_name, name) == 0) {
            return (void*)(mod->base + sym->st_value);
        }
    }
    return NULL;
}

void elf_call_init(ElfModule* mod) {
    if (!mod->loaded) return;
}
