#include "static_lib.h"

namespace static_lib {

int StaticLib::sub(int a, int b) {
    return ::sub(a, b);
}

};  // namespace static_lib
