#!/usr/bin/env python3
"""Patch curl_config.h for iOS cross-compilation.
Run after cmake configure: python3 patch_curl_config.py path/to/curl_config.h
"""
import sys, re

path = sys.argv[1]
txt = open(path).read()

# Fix 1: curl_off_t must be 64-bit on iOS (it's long long on all Apple 64-bit platforms)
txt = re.sub(r'#define CURL_SIZEOF_CURL_OFF_T \d+', '#define CURL_SIZEOF_CURL_OFF_T 8', txt)
txt = re.sub(r'#define CURL_SUFFIX_CURL_OFF_T\s+\S+', '#define CURL_SUFFIX_CURL_OFF_T LL', txt)
txt = re.sub(r'#define CURL_TYPEOF_CURL_OFF_T\s+\S+', '#define CURL_TYPEOF_CURL_OFF_T long long', txt)
# Ensure the signed suffix is also set
if 'CURL_SUFFIX_CURL_OFF_TU' not in txt:
    txt += '\n#define CURL_SUFFIX_CURL_OFF_TU ULL\n'

# Fix 2: timeval redefinition - iOS SDK defines it in sys/time.h.
# curl's configure sometimes emits its own definition; remove it.
txt = re.sub(r'struct timeval \{[^}]+\};', '/* timeval: provided by iOS SDK sys/time.h */', txt, flags=re.DOTALL)
# Mark HAVE_STRUCT_TIMEVAL so curl doesn't try to define it again
txt = re.sub(r'/\* #undef HAVE_STRUCT_TIMEVAL \*/', '#define HAVE_STRUCT_TIMEVAL 1', txt)
if 'HAVE_STRUCT_TIMEVAL' not in txt:
    txt += '\n#define HAVE_STRUCT_TIMEVAL 1\n'

# Fix 3: sread/swrite macros require HAVE_RECV and HAVE_SEND.
# Cross-compile detection fails to find recv/send; force them on.
txt = re.sub(r'/\* #undef HAVE_RECV \*/', '#define HAVE_RECV 1', txt)
txt = re.sub(r'/\* #undef HAVE_SEND \*/', '#define HAVE_SEND 1', txt)
if 'HAVE_RECV' not in txt:
    txt += '\n#define HAVE_RECV 1\n'
if 'HAVE_SEND' not in txt:
    txt += '\n#define HAVE_SEND 1\n'

# Fix 4: recv/send signatures for POSIX iOS
extra = """
/* iOS recv/send signatures (POSIX) - required for sread/swrite macros */
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
txt += extra

open(path, 'w').write(txt)
print(f"curl_config.h patched: {path}")
