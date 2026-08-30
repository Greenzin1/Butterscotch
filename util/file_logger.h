#pragma once
#include <stdio.h>

void filelog_init_with_path(const char* path);
FILE* filelog_get(void);
void filelog_close(void);
