#!/usr/bin/env python3
"""Patch curl files for iOS cross-compilation."""
import sys, re, os

config_path = os.path.abspath(sys.argv[1])
deps_dir = os.path.dirname(os.path.dirname(os.path.dirname(config_path)))
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

# --- Patch curl_setup.h ---
# Strategy: prepend defines at the very top so the #error checks evaluate false.
# This avoids needing to parse/remove the #if blocks entirely.
setup_path = os.path.join(curl_src, 'curl_setup.h')
if os.path.exists(setup_path):
    raw = open(setup_path, 'rb').read()
    s = raw.replace(b'\r\n', b'\n').decode('utf-8')
    
    # Prepend iOS overrides at the top of the file.
    # CURL_SIZEOF_CURL_OFF_T=8 makes both #if checks false (not < 8, not != 8).
    # HAVE_STRUCT_TIMEVAL=1 prevents curl from defining its own timeval.
    prefix = """/* Vitra iOS: force correct values for cross-compilation */
#ifndef CURL_SIZEOF_CURL_OFF_T
#define CURL_SIZEOF_CURL_OFF_T 8
#endif
#ifndef CURL_TYPEOF_CURL_OFF_T
#define CURL_TYPEOF_CURL_OFF_T long long
#endif
#ifndef CURL_SUFFIX_CURL_OFF_T
#define CURL_SUFFIX_CURL_OFF_T LL
#endif
#ifndef HAVE_STRUCT_TIMEVAL
#define HAVE_STRUCT_TIMEVAL 1
#endif
/* End Vitra iOS overrides */

"""
    if 'Vitra iOS' not in s:
        s = prefix + s
    
    open(setup_path, 'w').write(s)
    
    # Verify
    if 'CURL_SIZEOF_CURL_OFF_T 8' in s:
        print(f"Patched and verified: {setup_path}")
    else:
        print(f"ERROR: patch failed for {setup_path}")
else:
    print(f"WARNING: not found: {setup_path}")

# --- Patch curl_setup_once.h: guard timeval ---
once_path = os.path.join(curl_src, 'curl_setup_once.h')
if os.path.exists(once_path):
    raw = open(once_path, 'rb').read()
    s = raw.replace(b'\r\n', b'\n').decode('utf-8')
    # Guard timeval struct - iOS SDK already defines it
    s = re.sub(
        r'(struct timeval \{[^}]+\};)',
        r'#ifndef _TIMEVAL_DEFINED\n\1\n#endif',
        s
    )
    # Also add a guard for the entire timeval block if HAVE_STRUCT_TIMEVAL is set
    open(once_path, 'w').write(s)
    print(f"Patched: {once_path}")
else:
    print(f"WARNING: not found: {once_path}")

print("Done.")
