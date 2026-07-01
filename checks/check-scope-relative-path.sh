#!/usr/bin/env bash
# Verifies scope_relative_path handles Windows drive-absolute paths
# case-insensitively (parity with the PS twin's OrdIgnoreCase) and Unix
# absolute paths case-sensitively.
set +e
. "$(cd "$(dirname "$0")" && pwd)/../linux/hooks/hook-common.sh"

failures=0
check() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
        echo "PASS [$label] -> '$got'"
    else
        echo "FAIL [$label] -> got '$got' want '$expected'"
        failures=$((failures+1))
    fi
}

# Windows drive-absolute: root upper, path lower drive letter -> strip case-insensitively.
got="$(scope_relative_path "c:/Users/bh/proj/src/foo.ts" "C:/Users/bh/proj")"
check "win drive lower-path upper-root" "src/foo.ts" "$got"

# Windows drive-absolute: same case -> strip.
got="$(scope_relative_path "C:/Users/bh/proj/src/foo.ts" "C:/Users/bh/proj")"
check "win drive same-case" "src/foo.ts" "$got"

# Windows: path outside root -> empty (dropped).
got="$(scope_relative_path "C:/Other/x.ts" "C:/Users/bh/proj")"
check "win drive outside-root" "" "$got"

# Windows: backslash path -> normalized + stripped.
got="$(scope_relative_path "C:\\Users\\bh\\proj\\src\\foo.ts" "C:/Users/bh/proj")"
check "win backslash path" "src/foo.ts" "$got"

# Windows: root == path exactly -> empty.
got="$(scope_relative_path "C:/Users/bh/proj" "C:/Users/bh/proj")"
check "win root-equals-path" "" "$got"

# Unix absolute: case-sensitive (Foo != foo on Linux) -> outside root -> empty.
got="$(scope_relative_path "/home/bh/proj/src/foo.ts" "/home/bh/proj")"
check "unix absolute strip" "src/foo.ts" "$got"

got="$(scope_relative_path "/home/bh/proj/x.ts" "/home/Other/proj")"
check "unix absolute case-sensitive mismatch" "" "$got"

# Relative path with .. -> empty (escape attempt).
got="$(scope_relative_path "../etc/passwd" "/home/bh/proj")"
check "relative dotdot" "" "$got"

if [ "$failures" -gt 0 ]; then
    echo ""
    echo "FAILURES: $failures"
    exit 1
fi
echo ""
echo "ALL PASS: scope_relative_path case-insensitive (Windows) + case-sensitive (Unix) verified."
exit 0
