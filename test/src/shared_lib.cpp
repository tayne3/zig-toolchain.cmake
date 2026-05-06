#include "shared_lib.h"

namespace shared_lib {

int SharedLib::add(int a, int b) {
    return ::add(a, b);
}

};  // namespace shared_lib
