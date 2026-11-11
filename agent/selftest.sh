#!/usr/bin/env bash
# Offline self-test for the agent bridge — no GitHub, no Windows needed.
#
#   bash agent/selftest.sh
#
# It starts the POSIX worker against a throw-away mailbox in /tmp, drives it
# with the real client, and checks the round-trips (exec, ls, read, write,
# hash, sandbox refusals).  Exit code 0 = everything works.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/agent-selftest.XXXXXX)"
MAILBOX="$WORK/mailbox"
STATE="$WORK/state.json"
PIDFILE="$WORK/worker.pid"
CLIENT=(python3 "$REPO_ROOT/scripts/agent.py" --mailbox-dir "$MAILBOX" --wait 60 --quiet)
PASS=0
FAIL=0

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 0.3
    kill -9 "$(cat "$PIDFILE")" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

check() { # check <name> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then
    echo "  ok   $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $1"
    FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$MAILBOX"
setsid python3 "$REPO_ROOT/agent/linux/worker.py" \
  --transport file --file-dir "$MAILBOX" --interval 1 \
  --state "$STATE" --work-root "$WORK/run" >"$WORK/worker.log" 2>&1 </dev/null &
echo $! >"$PIDFILE"
sleep 1.2

echo "bridge self-test ($WORK)"

out="$("${CLIENT[@]}" ping)"; check "ping" $?
grep -q '"allowExec": true' <<<"$out"; check "ping reports config" $?

out="$("${CLIENT[@]}" exec 'echo hello; pwd' --shell bash)"; check "exec" $?
grep -q '^hello$' <<<"$out"; check "exec stdout" $?

"${CLIENT[@]}" exec 'exit 0' --shell bash >/dev/null 2>&1; check "exec honours exit 0" $?

out="$("${CLIENT[@]}" ls "$WORK")"; check "ls" $?
grep -q 'worker.log' <<<"$out"; check "ls lists files" $?

printf 'hello\nفارسی\n' >"$WORK/utf8.txt"
out="$("${CLIENT[@]}" read "$WORK/utf8.txt")"; check "read text" $?
grep -q 'فارسی' <<<"$out"; check "read keeps utf-8" $?

head -c 120000 /dev/urandom >"$WORK/payload.bin"
"${CLIENT[@]}" write "$WORK/copy.bin" --from "$WORK/payload.bin" >/dev/null 2>&1
check "write 120 KB (chunked)" $?
cmp -s "$WORK/payload.bin" "$WORK/copy.bin"; check "write bytes are exact" $?

"${CLIENT[@]}" read "$WORK/copy.bin" --out "$WORK/back.bin" >/dev/null 2>&1
check "read 120 KB (chunked)" $?
cmp -s "$WORK/payload.bin" "$WORK/back.bin"; check "read/write round-trip identical" $?

sha_local="$(sha256sum "$WORK/payload.bin" | cut -d' ' -f1)"
out="$("${CLIENT[@]}" hash "$WORK/copy.bin")"
grep -q "$sha_local" <<<"$out"; check "hash matches sha256sum" $?

"${CLIENT[@]}" read /etc/shadow >/dev/null 2>&1; check "sandbox refuses /etc/shadow" $((! $?))
"${CLIENT[@]}" write /etc/passwd --from "$WORK/utf8.txt" >/dev/null 2>&1
check "sandbox refuses write outside roots" $((! $?))

# the worker must ignore a request that was already answered
before="$(grep -c '\"kind\": \"comment\"' "$MAILBOX/mailbox.jsonl" || true)"
kill "$(cat "$PIDFILE")" 2>/dev/null; sleep 0.4
setsid python3 "$REPO_ROOT/agent/linux/worker.py" \
  --transport file --file-dir "$MAILBOX" --interval 1 \
  --state "$STATE" --work-root "$WORK/run" >>"$WORK/worker.log" 2>&1 </dev/null &
echo $! >"$PIDFILE"
sleep 1.5
after="$(grep -c '\"kind\": \"comment\"' "$MAILBOX/mailbox.jsonl" || true)"
[[ "$before" -eq "$after" ]]; check "restart does not replay old requests" $?

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
