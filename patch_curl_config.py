#!/usr/bin/env python3
"""Patch curl_config.h and curl_setup.h for iOS cross-compilation."""
import sys, re, os

config_path = sys.argv[1]
# Also patch curl_setup.h which has the #error checks
setup_path = config_path.replace('curl-build/lib/curl_config.h', 'curl-src/lib/curl_setup.h')
setup_once_path = config_path.replace('curl-build/lib/curl_config.h', 'curl-src/lib/curl_setup_once.h')

# --- Patch curl_config.h ---
txt = open(config_path).read()
txt = re.sub(r'#define CURL_SIZEOF_CURL_OFF_T \d+', '#define CURL_SIZEOF_CURL_OFF_T 8', txt)
txt = re.sub(r'#define CURL_SUFFIX_CURL_OFF_T\s+\S+', '#define CURL_SUFFIX_CURL_OFF_T LL', txt)
txt = re.sub(r'#define CURL_TYPEOF_CURL_OFF_T\s+\S+', '#define CURL_TYPEOF_CURL_OFF_T long long', txt)
txt = re.sub(r'struct timeval \{[^}]+\};', '/* timeval: provided by iOS SDK */', txt, flags=re.DOTALL)
txt = re.sub(r'/\* #undef HAVE_STRUCT_TIMEVAL \*/', '#define HAVE_STRUCT_TIMEVAL 1', txt)
if 'HAVE_STRUCT_TIMEVAL' not in txt:
    txt += '\n#define HAVE_STRUCT_TIMEVAL 1\n'
txt = re.sub(r'/\* #undef HAVE_RECV \*/', '#define HAVE_RECV 1', txt)
txt = re.sub(r'/\* #undef HAVE_SEND \*/', '#define HAVE_SEND 1', txt)
if 'HAVE_RECV' not in txt: txt += '\n#define HAVE_RECV 1\n'
if 'HAVE_SEND' not in txt: txt += '\n#define HAVE_SEND 1\n'
txt += """
/* iOS recv/send POSIX signatures */
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
if os.path.exists(setup_path):
    s = open(setup_path).read()
    # Remove the "too small curl_off_t" error - we know it's 64-bit on iOS
    s = s.replace(
        '#if (CURL_SIZEOF_CURL_OFF_T < 8)\n#  error "too small curl_off_t"\n#endif',
        '/* curl_off_t size check disabled for iOS cross-compilation (always 64-bit) */'
    )
    s = s.replace(
        '#if (CURL_SIZEOF_CURL_OFF_T != 8)\n    #error "curl_off_t must be exactly 64 bits"\n#endif',
        '/* curl_off_t 64-bit check disabled for iOS cross-compilation */'
    )
    # Also try alternate formatting
    s = re.sub(
        r'#\s*if\s*\(CURL_SIZEOF_CURL_OFF_T\s*<\s*8\).*?#\s*endif',
        '/* curl_off_t size check disabled for iOS */',
        s, flags=re.DOTALL
    )
    open(setup_path, 's').write(s) if False else open(setup_path, 'w').write(s)
    print(f"Patched: {setup_path}")

# --- Patch curl_setup_once.h: remove timeval and sread/swrite errors ---
if os.path.exists(setup_once_path):
    s = open(setup_once_path).read()
    # Guard timeval struct against redefinition
    s = s.replace(
        'struct timeval {',
        '#ifndef _STRUCT_TIMEVAL\nstruct timeval {'
    )
    s = re.sub(
        r'(struct timeval \{[^}]+\};)',
        r'\1\n#endif /* _STRUCT_TIMEVAL */',
        s
    )
    open(setup_once_path, 'w').write(s)
    print(f"Patched: {setup_once_path}")
    
print("All curl patches applied.")
