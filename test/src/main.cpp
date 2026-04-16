#include <stdio.h>

#include "shared_lib.h"
#include "static_lib.h"

#ifndef PROJECT_VERSION
#define PROJECT_VERSION "unknown"
#endif
#ifndef BUILD_DATE
#define BUILD_DATE "unknown"
#endif
#ifndef BUILD_COMPILER_ID
#define BUILD_COMPILER_ID "unknown"
#endif
#ifndef BUILD_COMPILER_VERSION
#define BUILD_COMPILER_VERSION "unknown"
#endif

int main(void) {
    int a = 1, b = 2;
    printf("%d + %d = %d/%d\n", a, b, add(a, b), shared_lib::SharedLib::add(a, b));
    printf("%d - %d = %d/%d\n", a, b, sub(a, b), static_lib::StaticLib::sub(a, b));

    printf(PROJECT_VERSION " " BUILD_DATE " (" BUILD_COMPILER_ID " " BUILD_COMPILER_VERSION ").\n");
    return 0;
}
