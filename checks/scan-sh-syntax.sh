#!/usr/bin/env bash
# Scan every SH hook for latent syntax errors by executing it with an input
# that points at a real .scope.json, forcing bash to parse the whole file
# (bash parses incrementally, so early-exit paths can mask real syntax errors).
set +e
here="$(cd "$(dirname "$0")" && pwd)"
hooks_dir="$here/../linux/hooks"
tmp="/c/Users/bh/AppData/Local/Temp/cdt-scan"
rm -rf "$tmp"; mkdir -p "$tmp"
cat > "$tmp/.scope.json" <<'EOFJ'
{"prompt":"p","intent":"do task","decomposition":[{"step":1,"subtask":"a","expected_files":["a.ts"]}],"verifications":[],"files":["a.ts"],"acceptance":"ok"}
EOFJ
printf '%s' '{"role":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ACCEPT step 1: ok"}]}}' > "$tmp/t.jsonl"
payload="{\"conversation_id\":\"scan\",\"transcript_path\":\"$tmp/t.jsonl\",\"cwd\":\"$tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"path\":\"a.ts\"}}"
exitcode=0
for h in "$hooks_dir"/*.sh; do
    name="$(basename "$h")"
    out="$(printf '%s' "$payload" | bash "$h" 2>&1)"
    rc=$?
    if echo "$out" | grep -q 'syntax error'; then
        echo "SYNTAX-ERROR $name (rc=$rc):"
        echo "$out" | grep 'syntax error' | head -2
        exitcode=1
    else
        echo "OK $name (rc=$rc)"
    fi
done
rm -rf "$tmp"
exit $exitcode
