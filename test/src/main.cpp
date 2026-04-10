#include <stdio.h>

#include "shared_lib.h"
#include "static_lib.h"

int main(void) {
    int a = 1, b = 2;
    printf("%d + %d = %d/%d\n", a, b, add(a, b), shared_lib::SharedLib::add(a, b));
    printf("%d - %d = %d/%d\n", a, b, sub(a, b), static_lib::StaticLib::sub(a, b));
    return 0;
}
