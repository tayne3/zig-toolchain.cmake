#ifndef SHARED_LIB_H
#define SHARED_LIB_H

#if defined(_WIN32)
#if defined(shared_lib_EXPORTS)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __declspec(dllimport)
#endif
#else
#define EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

EXPORT int add(int a, int b);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus

namespace shared_lib {

class EXPORT SharedLib {
public:
    static int add(int a, int b);
};

};  // namespace shared_lib
#endif

#endif  // SHARED_LIB_H
