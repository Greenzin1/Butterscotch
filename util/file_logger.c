#include "file_logger.h"
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/stat.h>

static FILE* g_logfile = NULL;

void filelog_init_with_path(const char* path) {
    char dir[1024];
    snprintf(dir, sizeof(dir), "%s", path);
    char* last_slash = strrchr(dir, '/');
    if (last_slash) {
        *last_slash = '\0';
        mkdir(dir, 0755);
    }

    g_logfile = fopen(path, "w");
    if (!g_logfile) {
        fprintf(stderr, "filelog: cannot open %s\n", path);
        return;
    }

    int log_fd = fileno(g_logfile);
    dup2(log_fd, 1);
    dup2(log_fd, 2);

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    printf("filelog: logging to %s\n", path);
    fflush(g_logfile);
}

FILE* filelog_get(void) {
    return g_logfile;
}

void filelog_close(void) {
    if (g_logfile) {
        fclose(g_logfile);
        g_logfile = NULL;
    }
}
