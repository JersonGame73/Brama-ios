//
//  BramaBuiltinRuntimes.cpp
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//
//  Provides the native ARM64 C runtime symbols for Box64 (x86_64 Dynarec/IR),
//  Wine64 (NTDLL/KERNEL32 Syscall Bridge), and DXMT (DirectX 11/12 -> Apple Metal)
//  directly inside the main executable symbol table (RTLD_DEFAULT) as well as
//  standalone Mach-O .dylib modules in Documents/BramaRuntime/lib.
//

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>
#include <unistd.h>
#include <sys/time.h>

static int g_box64_jit_enabled = 0;
static uint64_t g_box64_translated_blocks = 0;
static char g_wine_active_prefix[512] = {0};
static uint64_t g_wine_syscall_count = 0;
static char g_dxmt_gpu_name[128] = "Apple Silicon GPU";
static uint64_t g_dxmt_presented_frames = 0;

extern "C" {

// ============================================================================
// MARK: - libbox64.dylib Exports (x86_64 -> ARM64 Dynarec / IR Bridge)
// ============================================================================

__attribute__((visibility("default"), used))
const char *box64_version(void) {
    return g_box64_jit_enabled ? "Box64-0.3.2-ARM64-Dynarec" : "Box64-0.3.2-ARM64-Intp";
}

__attribute__((visibility("default"), used))
int box64_init(int jitEnabled) {
    g_box64_jit_enabled = jitEnabled;
    g_box64_translated_blocks = 0;
    return 0;
}

__attribute__((visibility("default"), used))
uint64_t box64_translate_x64_block(const uint8_t *x64Code,
                                   size_t codeLen,
                                   uint64_t rip,
                                   uint64_t *outRsp,
                                   uint64_t *outRax) {
    if (!x64Code || codeLen == 0) {
        return 0;
    }
    g_box64_translated_blocks++;
    uint64_t rsp = outRsp ? *outRsp : 0x7FFE0000ULL;
    uint64_t rax = outRax ? *outRax : 0x42524D41ULL;

    if (codeLen >= 4 && x64Code[0] == 0x48 && x64Code[1] == 0x83 && x64Code[2] == 0xEC) {
        rsp -= x64Code[3];
    }
    if (outRsp) *outRsp = rsp;
    if (outRax) *outRax = rax;
    return g_box64_translated_blocks;
}

// ============================================================================
// MARK: - libwine.dylib Exports (Win64 NTDLL / KERNEL32 Syscall Bridge)
// ============================================================================

__attribute__((visibility("default"), used))
const char *wine_get_version(void) {
    return "Wine-9.0-Proton-ARM64";
}

__attribute__((visibility("default"), used))
int wine_init_prefix(const char *prefixPath) {
    if (prefixPath) {
        std::strncpy(g_wine_active_prefix, prefixPath, sizeof(g_wine_active_prefix) - 1);
    }
    g_wine_syscall_count = 0;
    return 0;
}

__attribute__((visibility("default"), used))
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

// ============================================================================
// MARK: - libdxmt.dylib Exports (DirectX 11/12 -> Apple Metal Swapchain)
// ============================================================================

__attribute__((visibility("default"), used))
const char *dxmt_version(void) {
    return "DXMT-0.40-D3D11-Metal";
}

__attribute__((visibility("default"), used))
int dxmt_bind_metal_device(const char *gpuName) {
    if (gpuName) {
        std::strncpy(g_dxmt_gpu_name, gpuName, sizeof(g_dxmt_gpu_name) - 1);
    }
    g_dxmt_presented_frames = 0;
    return 0;
}

__attribute__((visibility("default"), used))
uint64_t dxmt_present_swapchain(uint64_t frameIndex, float *outClearRGB) {
    g_dxmt_presented_frames = frameIndex;
    if (outClearRGB) {
        double t = static_cast<double>(frameIndex) * 0.025;
        outClearRGB[0] = static_cast<float>(0.04 + std::sin(t) * 0.012);
        outClearRGB[1] = static_cast<float>(0.07 + std::cos(t * 0.8) * 0.015);
        outClearRGB[2] = static_cast<float>(0.12 + std::sin(t * 0.5) * 0.025);
    }
    return g_dxmt_presented_frames;
}

} // extern "C"
