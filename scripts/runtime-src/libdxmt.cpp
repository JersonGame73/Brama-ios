//
//  libdxmt.cpp
//  Brama ARM64 iOS Runtime Module - DirectX 11/12 to Apple Metal Swapchain Bridge
//

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>

static char g_dxmt_gpu_name[128] = "Apple Silicon GPU";
static uint64_t g_dxmt_presented_frames = 0;

extern "C" {

__attribute__((visibility("default")))
const char *dxmt_version(void) {
    return "DXMT-0.40-D3D11-Metal";
}

__attribute__((visibility("default")))
int dxmt_bind_metal_device(const char *gpuName) {
    if (gpuName) {
        std::strncpy(g_dxmt_gpu_name, gpuName, sizeof(g_dxmt_gpu_name) - 1);
    }
    g_dxmt_presented_frames = 0;
    return 0;
}

__attribute__((visibility("default")))
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
