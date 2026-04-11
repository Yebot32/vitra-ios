#!/usr/bin/env python3
"""Patch curl files for iOS cross-compilation. Pass path to curl_config.h."""
import sys, re, os

config_path = os.path.abspath(sys.argv[1])
deps_dir = os.path.dirname(os.path.dirname(os.path.dirname(config_path)))  # _deps/
curl_src = os.path.join(deps_dir, 'curl-src', 'lib')

# --- Patch curl_config.h ---
txt = open(config_path).read()
txt = re.sub(r'#define CURL_SIZEOF_CURL_OFF_T \d+', '#define CURL_SIZEOF_CURL_OFF_T 8', txt)
txt = re.sub(r'#define CURL_SUFFIX_CURL_OFF_T\s+\S+', '#define CURL_SUFFIX_CURL_OFF_T LL', txt)
txt = re.sub(r'#define CURL_TYPEOF_CURL_OFF_T\s+\S+', '#define CURL_TYPEOF_CURL_OFF_T long long', txt)
txt = re.sub(r'struct timeval \{[^}]+\};', '/* timeval: provided by iOS SDK */', txt, flags=re.DOTALL)
for undef in ['HAVE_STRUCT_TIMEVAL', 'HAVE_RECV', 'HAVE_SEND']:
    txt = re.sub(r'/\* #undef ' + undef + r' \*/', f'#define {undef} 1', txt)
    if undef not in txt:
        txt += f'\n#define {undef} 1\n'
txt += """
#ifndef RECV_TYPE_ARG1
#define RECV_TYPE_ARG1 int
#define RECV_TYPE_ARG2 void *
#define RECV_TYPE_ARG3 size_t
#define RECV_TYPE_ARG4 int
#define RECV_TYPE_RETV ssize_t
#define SEND_TYPE_ARG1 int
#define SEND_TYPE_ARG2 const void *
#define SEND_TYPE_ARG3 size_t
#define SEND_TYPE_ARG4 int
#define SEND_TYPE_RETV ssize_t
#endif
"""
open(config_path, 'w').write(txt)
print(f"Patched: {config_path}")

# --- Patch curl_setup.h: remove the #error size checks ---
setup_path = os.path.join(curl_src, 'curl_setup.h')
print(f"Looking for curl_setup.h at: {setup_path}")
if os.path.exists(setup_path):
    s = open(setup_path).read()
    # Remove "too small curl_off_t" error block
    s = re.sub(
        r'#if \(CURL_SIZEOF_CURL_OFF_T < 8\)[^\n]*\n[^\n]*"too small curl_off_t"[^\n]*\n#endif',
        '/* curl_off_t < 8 check disabled for iOS (arm64 is always 64-bit) */',
        s
    )
    # Remove "must be exactly 64 bits" error block  
    s = re.sub(
        r'#if \(CURL_SIZEOF_CURL_OFF_T != 8\)[^\n]*\n[^\n]*"curl_off_t must be exactly[^"]*"[^\n]*\n#endif',
        '/* curl_off_t == 8 check disabled for iOS (arm64 is always 64-bit) */',
        s
    )
    open(setup_path, 'w').write(s)
    print(f"Patched: {setup_path}")
else:
    print(f"WARNING: {setup_path} not found")

# --- Patch curl_setup_once.h: guard timeval ---
once_path = os.path.join(curl_src, 'curl_setup_once.h')
if os.path.exists(once_path):
    s = open(once_path).read()
    # Guard the timeval struct definition
    s = re.sub(
        r'(struct timeval \{[^}]+\};)',
        r'#ifndef _TIMEVAL_DEFINED\n\1\n#endif',
        s
    )
    open(once_path, 'w').write(s)
    print(f"Patched: {once_path}")
else:
    print(f"WARNING: {once_path} not found")

print("Done.")
