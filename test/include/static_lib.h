#ifndef STATIC_LIB_H
#define STATIC_LIB_H

#ifdef __cplusplus
extern "C" {
#endif

int sub(int a, int b);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
namespace static_lib {

class StaticLib {
public:
    static int sub(int a, int b);
};

};  // namespace static_lib
#endif

#endif  // STATIC_LIB_H
