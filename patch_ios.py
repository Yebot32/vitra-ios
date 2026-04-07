#!/usr/bin/env python3
"""Patches submodules and build files for Vitra iOS compatibility.
Run from repo root before cmake configure."""

def patch(path, old, new, required=True):
    with open(path) as f:
        txt = f.read()
    out = txt.replace(old, new)
    if out != txt:
        with open(path, 'w') as f:
            f.write(out)
        print(f"Patched: {path}")
    elif required:
        print(f"WARNING: pattern not found in {path}")
    else:
        print(f"OK (no change needed): {path}")

# 1. cubeb: disable AudioUnit backend on iOS
#    cubeb_audiounit.cpp uses CoreAudio HAL APIs (AudioObjectPropertyAddress,
#    kAudioHardwarePropertyDevices etc) that are macOS-only — not on iOS.
patch(
    'external/cubeb/CMakeLists.txt',
    'check_include_files(AudioUnit/AudioUnit.h USE_AUDIOUNIT)\nif(USE_AUDIOUNIT)',
    'check_include_files(AudioUnit/AudioUnit.h USE_AUDIOUNIT)\n'
    'if(USE_AUDIOUNIT AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")',
)

# 2. renderer: ensure concurrentqueue include dir is visible to the iOS renderer target.
#    pipeline_cache.h includes <blockingconcurrentqueue.h> which lives in
#    external/concurrentqueue/ — already set as an INTERFACE include on the
#    concurrentqueue target, but the iOS renderer target also needs it explicitly.
patch(
    'vita3k/renderer/CMakeLists.txt',
    'target_link_libraries(renderer PRIVATE ddspp SDL3::SDL3 stb ffmpeg xxHash::xxhash concurrentqueue)',
    'target_link_libraries(renderer PRIVATE ddspp SDL3::SDL3 stb ffmpeg xxHash::xxhash concurrentqueue)\n'
    'target_include_directories(renderer PRIVATE "${CMAKE_SOURCE_DIR}/external/concurrentqueue")',
)



# 3. cubeb/speex: resample.c uses #include "speex/speex_resampler.h" but the
#    include directory is only set as INTERFACE (for consumers), not PRIVATE.
#    Add PRIVATE so the speex object library can find its own header.
patch(
    'external/cubeb/CMakeLists.txt',
    '  target_include_directories(speex INTERFACE subprojects)',
    '  target_include_directories(speex PRIVATE subprojects INTERFACE subprojects)',
)

# spdlog: force external fmt so the bundled fmt 11 doesn't conflict with external fmt 12
# tweakme.h is included by spdlog/fmt/fmt.h before the SPDLOG_FMT_EXTERNAL check.
patch(
    'external/spdlog/include/spdlog/tweakme.h',
    '#pragma once',
    '#pragma once\n\n// Vitra iOS: use external fmt (submodule) instead of spdlog bundled fmt.\n// External fmt is v12 while spdlog bundles v11 - mixing them causes compile errors.\n#ifndef SPDLOG_FMT_EXTERNAL\n#define SPDLOG_FMT_EXTERNAL\n#endif',
)

print("All patches applied.")
