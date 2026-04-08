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


# 4. cubeb/speex: speex_resampler.h includes "speexdsp_types.h" when OUTSIDE_SPEEX
#    is defined, but cubeb bundles it as "speex_config_types.h". Create a shim by
#    patching the include in speex_resampler.h to use the actual bundled filename.
patch(
    'external/cubeb/subprojects/speex/speex_resampler.h',
    '#include "speexdsp_types.h"',
    '#include "speex_config_types.h"',
)


# 5. cubeb/speex: speex_config_types.h uses int16_t etc without including <stdint.h>.
#    Also arch.h includes "speex/speexdsp_types.h" (with subdir prefix) when not
#    OUTSIDE_SPEEX — patch both to use the local file.
patch(
    'external/cubeb/subprojects/speex/speex_config_types.h',
    '/* these are filled in by configure */',
    '/* these are filled in by configure */\n#include <stdint.h>',
)
patch(
    'external/cubeb/subprojects/speex/arch.h',
    '#include "speex/speexdsp_types.h"',
    '#include "speex_config_types.h"',
)


# 6. cubeb/speex: the FLOATING_POINT and OUTSIDE_SPEEX compile definitions from 
#    CMakeLists don't reliably reach the OBJECT library's own compilation in Xcode.
#    Patch resample.c to define them at the top before any includes.
patch(
    'external/cubeb/subprojects/speex/resample.c',
    '/* Copyright (C) 2007-2008 Jean-Marc Valin',
    '/* Vitra iOS: ensure required defines are set regardless of build system */\n'
    '#ifndef OUTSIDE_SPEEX\n#define OUTSIDE_SPEEX\n#endif\n'
    '#ifndef FLOATING_POINT\n#define FLOATING_POINT\n#endif\n'
    '#ifndef EXPORT\n#define EXPORT\n#endif\n'
    '#ifndef RANDOM_PREFIX\n#define RANDOM_PREFIX speex\n#endif\n\n'
    '/* Copyright (C) 2007-2008 Jean-Marc Valin',
)


# 7. cubeb/speex: os_support.h is not present in cubeb's bundled speex copy.
#    It's only needed for speex-internal malloc wrappers which aren't used
#    when OUTSIDE_SPEEX is set. Patch it out.
patch(
    'external/cubeb/subprojects/speex/resample.c',
    '#include "speex/speex_resampler.h"\n#include "arch.h"\n#include "os_support.h"',
    '#include "speex/speex_resampler.h"\n#include "arch.h"\n/* os_support.h not present in cubeb bundle - not needed with OUTSIDE_SPEEX */',
)


# 8. spdlog compiled lib: each .cpp checks SPDLOG_COMPILED_LIB before any #include.
#    tweakme.h can't help here. Define it directly at the top of each .cpp.
patch(
    'external/spdlog/src/async.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/bundled_fmtlib_format.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/cfg.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/color_sinks.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/file_sinks.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/spdlog.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)
patch(
    'external/spdlog/src/stdout_sinks.cpp',
    '#ifndef SPDLOG_COMPILED_LIB',
    '#define SPDLOG_COMPILED_LIB  // Vitra iOS: defined here because Xcode does not propagate CMake PUBLIC defines\n#ifndef SPDLOG_COMPILED_LIB',
    required=False,
)

# spdlog: force external fmt so the bundled fmt 11 doesn't conflict with external fmt 12
# tweakme.h is included by spdlog/fmt/fmt.h before the SPDLOG_FMT_EXTERNAL check.
patch(
    'external/spdlog/include/spdlog/tweakme.h',
    '#pragma once',
    '#pragma once\n\n// Vitra iOS: use external fmt and compiled-lib mode.\n// External fmt is v12 while spdlog bundles v11 - mixing them causes compile errors.\n#ifndef SPDLOG_FMT_EXTERNAL\n#define SPDLOG_FMT_EXTERNAL\n#endif\n#ifndef SPDLOG_COMPILED_LIB\n#define SPDLOG_COMPILED_LIB\n#endif',
)

print("All patches applied.")
