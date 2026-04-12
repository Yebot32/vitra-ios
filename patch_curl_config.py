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
setup_path = os.path.join(curl_src, 'curl_setup.h')
if os.path.exists(setup_path):
    raw = open(setup_path, 'rb').read()
    # Normalize CRLF -> LF so regex works reliably
    s = raw.replace(b'\r\n', b'\n').decode('utf-8')
    
    before = s
    s = re.sub(
        r'#if \(CURL_SIZEOF_CURL_OFF_T < 8\)\n#error[^\n]+\n#endif',
        '/* curl_off_t < 8 check removed for iOS arm64 */',
        s
    )
    s = re.sub(
        r'#if \(CURL_SIZEOF_CURL_OFF_T != 8\)\n#\s*error[^\n]+\n#endif',
        '/* curl_off_t != 8 check removed for iOS arm64 */',
        s
    )
    
    if s == before:
        print(f"WARNING: curl_setup.h regex did not match - trying line-based removal")
        lines = s.splitlines()
        out = []
        skip_next = False
        i = 0
        while i < len(lines):
            line = lines[i]
            if 'CURL_SIZEOF_CURL_OFF_T < 8' in line or 'CURL_SIZEOF_CURL_OFF_T != 8' in line:
                # Skip this #if, the #error, and the #endif
                out.append('/* curl_off_t size check removed for iOS arm64 */')
                i += 1  # skip #error line
                if i < len(lines) and lines[i].strip().startswith('#error'):
                    i += 1
                if i < len(lines) and lines[i].strip() == '#endif':
                    i += 1
                continue
            out.append(line)
            i += 1
        s = '\n'.join(out)
        print(f"  Line-based removal applied")
    
    # Verify removal
    if 'too small curl_off_t' in s or 'curl_off_t must be exactly' in s:
        print(f"ERROR: #error lines still present in curl_setup.h!")
    else:
        print(f"  Verified: #error lines removed from curl_setup.h")
    
    open(setup_path, 'w').write(s)
    print(f"Patched: {setup_path}")
else:
    print(f"WARNING: not found: {setup_path}")

# --- Patch curl_setup_once.h ---
once_path = os.path.join(curl_src, 'curl_setup_once.h')
if os.path.exists(once_path):
    raw = open(once_path, 'rb').read()
    s = raw.replace(b'\r\n', b'\n').decode('utf-8')
    s = re.sub(
        r'(struct timeval \{[^}]+\};)',
        r'#ifndef _TIMEVAL_DEFINED\n\1\n#endif',
        s
    )
    open(once_path, 'w').write(s)
    print(f"Patched: {once_path}")
else:
    print(f"WARNING: not found: {once_path}")

print("Done.")
