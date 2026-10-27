//
//  libwine.cpp
//  Brama ARM64 iOS Runtime Module - Wine64 NTDLL / KERNEL32 Syscall Thunk Layer
//

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <unistd.h>
#include <sys/time.h>

static char g_wine_active_prefix[512] = {0};
static uint64_t g_wine_syscall_count = 0;

extern "C" {

__attribute__((visibility("default")))
const char *wine_get_version(void) {
    return "Wine-9.0-Proton-ARM64";
}

__attribute__((visibility("default")))
int wine_init_prefix(const char *prefixPath) {
    if (prefixPath) {
        std::strncpy(g_wine_active_prefix, prefixPath, sizeof(g_wine_active_prefix) - 1);
    }
    g_wine_syscall_count = 0;
    return 0;
}

__attribute__((visibility("default")))
uint64_t wine_invoke_win64_thunk(const char *dllName, const char *symbolName) {
    g_wine_syscall_count++;
    if (!symbolName) {
        return 0;
    }
    if (std::strcmp(symbolName, "GetCurrentProcessId") == 0) {
        return static_cast<uint64_t>(getpid());
    }
    if (std::strcmp(symbolName, "GetSystemTimeAsFileTime") == 0) {
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        return ((uint64_t)tv.tv_sec * 10000000ULL) + ((uint64_t)tv.tv_usec * 10ULL) + 116444736000000000ULL;
    }
    return g_wine_syscall_count;
}

} // extern "C"
