// Shared state between libMyEmuDisplay (inside the engine) and MyEmu: a 4 KB file both map.
// MyEmu mirrors these offsets in DirectDisplay.swift.
#include <stdint.h>

typedef struct {
    uint32_t contextId;    // offset 0: Core Animation context with the Android screen, 0 until ready
    uint32_t reserved;     // offset 4
    uint64_t presents;     // offset 8: frames gfxstream has presented
    uint64_t slowPresents; // offset 16: presents that came ≥ 40 ms after the previous one
} MyEmuDisplayState;
