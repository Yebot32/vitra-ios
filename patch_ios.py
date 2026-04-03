#!/usr/bin/env python3
"""Patches submodules for iOS compatibility. Run from repo root."""
import os

def patch(path, old, new):
    with open(path) as f:
        txt = f.read()
    out = txt.replace(old, new)
    with open(path, 'w') as f:
        f.write(out)
    if out != txt:
        print(f"Patched: {path}")
    else:
        print(f"WARNING: pattern not found in {path}")

# cubeb: disable AudioUnit backend on iOS (uses macOS-only CoreAudio HAL APIs)
patch(
    'external/cubeb/CMakeLists.txt',
    'check_include_files(AudioUnit/AudioUnit.h USE_AUDIOUNIT)\nif(USE_AUDIOUNIT)',
    'check_include_files(AudioUnit/AudioUnit.h USE_AUDIOUNIT)\n'
    'if(USE_AUDIOUNIT AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")',
)
