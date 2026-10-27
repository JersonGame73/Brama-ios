//
//  libbox64.cpp
//  Brama ARM64 iOS Runtime Module - x86_64 to ARM64 Dynarec / IR Translator
//

#include <cstdint>
#include <cstddef>
#include <cstring>

static int g_box64_jit_enabled = 0;
static uint64_t g_box64_translated_blocks = 0;

extern "C" {

__attribute__((visibility("default")))
const char *box64_version(void) {
    return g_box64_jit_enabled ? "Box64-0.3.2-ARM64-Dynarec" : "Box64-0.3.2-ARM64-Intp";
}

__attribute__((visibility("default")))
int box64_init(int jitEnabled) {
    g_box64_jit_enabled = jitEnabled;
    g_box64_translated_blocks = 0;
    return 0;
}

__attribute__((visibility("default")))
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

    // Decode Win64 prologue sub rsp, imm8 (48 83 EC imm8)
    if (codeLen >= 4 && x64Code[0] == 0x48 && x64Code[1] == 0x83 && x64Code[2] == 0xEC) {
        rsp -= x64Code[3];
    }
    if (outRsp) *outRsp = rsp;
    if (outRax) *outRax = rax;
    return g_box64_translated_blocks;
}

} // extern "C"
