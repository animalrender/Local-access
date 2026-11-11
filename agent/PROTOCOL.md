# Agent bridge — wire protocol (v1, "issue per request")

The agent runs in a sandbox whose outbound network is limited to
`github.com` / `api.github.com` / npm / PyPI, and whose GitHub token may
**create** issues but may **not comment** on them (`403`, needs `issues=write`).
The machine on the other side has full internet.

So the transport is a GitHub issue per request:

```
 agent (sandbox)          GitHub (private repo)              your machine
 ───────────────          ─────────────────────             ─────────────
 POST /issues      ──▶   #42  [agent-req] r-… op=exec
                              body: <!--AGENT:REQ:v1:…-->
                                   │
                                   │  poll: GET /issues?state=open
                                   ▼
                              worker executes locally
                                   │
                         ◀──  comment: <!--AGENT:RES:v1:…-->
                              PATCH state=closed
 GET /issues/42/comments ◀──
```

* No inbound port, no public IP, no tunnel — works behind CGNAT.
* Everything is visible in the issue list, so the human can audit each step.
* The agent only needs **create issue** + **read** permission.

## Request (issue body)

Title: `[agent-req] <req> <op>` — the prefix is the mailbox filter.

Body: one HTML comment holding base64 JSON, plus a human-readable line:

```
<!--AGENT:REQ:v1:<base64(utf8 JSON)>-->

**exec** — exec: `Get-Process | Sort CPU -Desc`
```

```json
{
  "v": 1,
  "req": "r-20261111T2130-ab12",
  "op": "exec|ping|info|ls|read|write|hash",
  "created": "2026-11-11T21:30:00Z",

  "script": "Get-ChildItem C:\\Users",   // exec
  "shell": "powershell|cmd|bash",
  "cwd": "C:\\Users\\me",
  "timeout_sec": 120,                    // clamped to config.maxTimeoutSec

  "path": "C:\\Users\\me",               // ls/read/write/hash
  "recursive": false, "pattern": "*",    // ls
  "offset": 0, "length": 30000,          // read
  "data_base64": "…", "mode": "overwrite|append", "create_dirs": true   // write
}
```

## Result (comment on that issue)

```
<!--AGENT:RES:v1:<base64(utf8 JSON)>-->
```

```json
{
  "v": 1, "req": "r-20261111T2130-ab12", "ok": true, "op": "exec",
  "worker": "windows|posix", "worker_version": "1.0.0",
  "host": "DESKTOP-ABC", "user": "ali",
  "started": "…", "finished": "…", "duration_ms": 812,
  "error": null,
  "exit_code": 0, "timed_out": false,
  "stdout": "…", "stderr": "…",
  "stdout_len": 1234, "stderr_len": 0,
  "stdout_truncated": false, "stderr_truncated": false,
  "log_path": "C:\\Users\\ali\\AppData\\Local\\win-agent\\logs\\r-….stdout.txt",
  "result": { }
}
```

`result` per op:

| op | result |
|---|---|
| `ping` | `{ config, work_root, version }` |
| `info` | `{ os, ps_version, drives, env_sample, tailscale, … }` |
| `ls` | `{ path, entries: [{name,path,type,size,mtime}], count, truncated }` |
| `read` | `{ path, size, offset, length, eof, sha256, data_base64 }` |
| `write` | `{ path, bytes_written, mode, size, sha256 }` |
| `hash` | `{ path, size, sha256, mtime }` |

Long `exec` calls also post `{"partial": true, "stdout": "…tail…"}` comments
every `progressEverySec` seconds, so the agent can watch output live.

## Sizes

GitHub allows 65 536 characters per comment/issue body → ≈ 48 KB of JSON per
message. Therefore:

* `read` returns at most ~32 KB per call — the client loops with `offset`.
* `write` is sent in ~32 KB chunks — first `overwrite`, then `append`.
* `exec` stdout is capped in the JSON (7 KB) and the full text is written to
  `log_path` on the machine, readable later with `read`.

## Path sandbox

Every `path` is resolved to an absolute path and must be under one of
`allowedRoots` from the worker config; anything else (including `..` escapes
and symlinks pointing outside) is refused with `ok:false`. `exec` is not
path-restricted by design — set `"allowExec": false` to make the bridge
read-only.

## Idempotency

* The worker keeps `done_issues` / `done_reqs` in `state.json`; a restart never
  replays a request.
* After answering, the worker closes the issue. If closing fails, the request
  stays open but is still skipped on the next poll.
* Leftover `[agent]…` issues without a valid payload are closed automatically.
* Requests are executed one at a time, oldest first.
