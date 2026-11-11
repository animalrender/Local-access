#!/usr/bin/env python3
"""
Local-access agent worker — POSIX side (Linux / macOS / WSL).

Watches a "mailbox" (a GitHub issue, or a local file for tests), executes the
requests it finds there under a path sandbox, and posts the results back.

    # GitHub transport (real use)
    GITHUB_TOKEN=ghp_xxx python3 worker.py \
        --repo owner/name --issue 12 --labels win-agent

    # local file transport (no network, used by the test suite)
    python3 worker.py --transport file --file-dir /tmp/mailbox --once

Protocol: see ../PROTOCOL.md.  Requests are executed one at a time, in order.
"""

import argparse
import base64
import fnmatch
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

VERSION = "1.0.0"
REQ_RE = re.compile(r"<!--AGENT:REQ:v1:([A-Za-z0-9+/=]+)-->")
RES_RE = re.compile(r"<!--AGENT:RES:v1:([A-Za-z0-9+/=]+)-->")
MAX_INLINE = 7000          # chars of stdout kept inside the JSON payload
MAX_ENVELOPE = 60000       # base64 comment body; GitHub allows 65536

DEFAULT_CONFIG = {
    "allowedRoots": ["~", "/tmp"],
    "allowExec": True,
    "allowRead": True,
    "allowWrite": True,
    "allowHash": True,
    "maxReadBytes": 4 * 1024 * 1024,
    "maxWriteBytes": 32 * 1024 * 1024,
    "maxOutputBytes": 1024 * 1024,
    "defaultTimeoutSec": 120,
    "maxTimeoutSec": 900,
    "maxListEntries": 400,
    "progressEverySec": 15,
    "pollSeconds": 5,
}


# --------------------------------------------------------------------------
# config / helpers
# --------------------------------------------------------------------------
def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))


def load_config(path: str) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            cfg.update(json.load(fh))
    roots = []
    for root in cfg.get("allowedRoots") or []:
        roots.append(os.path.realpath(os.path.expanduser(os.path.expandvars(root))))
    if not roots:
        roots = [os.path.realpath(os.path.expanduser("~"))]
    cfg["allowedRoots"] = roots
    return cfg


def resolve_path(raw: str, cfg: dict, must_exist: bool = False) -> str:
    if not raw or not str(raw).strip():
        raise ValueError("path is required")
    path = os.path.expandvars(os.path.expanduser(str(raw).strip()))
    if not os.path.isabs(path):
        raise ValueError("path must be absolute: %s" % raw)
    full = os.path.realpath(path)
    allowed = False
    for root in cfg["allowedRoots"]:
        root = root.rstrip(os.sep) or os.sep
        if full == root or full.startswith(root + os.sep):
            allowed = True
            break
    if not allowed:
        raise PermissionError(
            "path outside allowed roots: %s (allowed: %s)"
            % (full, "; ".join(cfg["allowedRoots"]))
        )
    if must_exist and not os.path.exists(full):
        raise FileNotFoundError("not found: %s" % full)
    return full


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def clamp(value, low, high, default):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, value))


def truncate_inline(text: str, limit: int = MAX_INLINE):
    if text is None:
        return "", 0, False
    return (text[:limit], len(text), len(text) > limit)


# --------------------------------------------------------------------------
# operations
# --------------------------------------------------------------------------
def op_ping(req, cfg, ctx):
    return {
        "config": {
            "allowedRoots": cfg["allowedRoots"],
            "allowExec": cfg["allowExec"],
            "allowWrite": cfg["allowWrite"],
            "maxReadBytes": cfg["maxReadBytes"],
            "maxTimeoutSec": cfg["maxTimeoutSec"],
        },
        "python": platform.python_version(),
        "git": shutil.which("git") or None,
        "os": "%s %s" % (platform.system(), platform.release()),
    }


def op_info(req, cfg, ctx):
    tailscale = None
    ts = shutil.which("tailscale")
    if ts:
        try:
            tailscale = {
                "path": ts,
                "ip4": subprocess.run(
                    [ts, "ip", "-4"], capture_output=True, text=True, timeout=10
                ).stdout.strip(),
            }
        except Exception as exc:  # pragma: no cover - environment dependent
            tailscale = {"path": ts, "error": str(exc)}
    env_sample = {}
    for key in ("HOME", "USER", "SHELL", "PWD", "LANG", "TZ"):
        if key in os.environ:
            env_sample[key] = os.environ[key]
    return {
        "os": "%s %s" % (platform.system(), platform.release()),
        "python_version": platform.python_version(),
        "machine": platform.machine(),
        "drives": [p for p in ("/",) if os.path.isdir(p)],
        "env_sample": env_sample,
        "tailscale": tailscale,
        "cwd": os.getcwd(),
    }


def op_ls(req, cfg, ctx):
    path = resolve_path(req.get("path", "~"), cfg, must_exist=True)
    recursive = bool(req.get("recursive"))
    pattern = req.get("pattern") or "*"
    limit = cfg["maxListEntries"]
    entries = []
    truncated = False

    def add(full):
        nonlocal truncated
        if len(entries) >= limit:
            truncated = True
            return False
        try:
            st = os.lstat(full)
        except OSError:
            return True
        name = os.path.basename(full) or full
        if not recursive and not fnmatch.fnmatch(name, pattern):
            return True
        entries.append(
            {
                "name": name,
                "path": full,
                "type": "dir" if os.path.isdir(full) else "file",
                "size": st.st_size if not os.path.isdir(full) else None,
                "mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime)),
            }
        )
        return True

    if recursive:
        for root, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".git"))
            for name in sorted(dirs) + sorted(files):
                if not add(os.path.join(root, name)):
                    break
            if truncated:
                break
    else:
        for name in sorted(os.listdir(path)):
            if not add(os.path.join(path, name)):
                break

    return {"path": path, "entries": entries, "count": len(entries), "truncated": truncated}


def op_read(req, cfg, ctx):
    if not cfg["allowRead"]:
        raise PermissionError("reads are disabled (allowRead=false)")
    path = resolve_path(req.get("path"), cfg, must_exist=True)
    if os.path.isdir(path):
        raise IsADirectoryError("path is a directory: %s" % path)
    size = os.path.getsize(path)
    offset = clamp(req.get("offset", 0), 0, size, 0)
    length = clamp(req.get("length", 262144), 1, cfg["maxReadBytes"], 262144)
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read(length)
    return {
        "path": path,
        "size": size,
        "offset": offset,
        "length": len(data),
        "eof": offset + len(data) >= size,
        "sha256": sha256_bytes(data),
        "data_base64": b64e(data),
    }


def op_write(req, cfg, ctx):
    if not cfg["allowWrite"]:
        raise PermissionError("writes are disabled (allowWrite=false)")
    path = resolve_path(req.get("path"), cfg)
    if os.path.isdir(path):
        raise IsADirectoryError("path is a directory: %s" % path)
    data = b64d(req.get("data_base64") or "")
    if len(data) > cfg["maxWriteBytes"]:
        raise ValueError("payload too large: %d > %d bytes" % (len(data), cfg["maxWriteBytes"]))
    mode = (req.get("mode") or "overwrite").lower()
    if mode not in ("overwrite", "append"):
        raise ValueError("mode must be overwrite|append")
    parent = os.path.dirname(path) or "."
    if not os.path.isdir(parent):
        if req.get("create_dirs", True):
            os.makedirs(parent, exist_ok=True)
        else:
            raise FileNotFoundError("directory does not exist: %s" % parent)
    with open(path, "ab" if mode == "append" else "wb") as fh:
        fh.write(data)
    return {
        "path": path,
        "bytes_written": len(data),
        "mode": mode,
        "size": os.path.getsize(path),
        "sha256": sha256_bytes(data),
    }


def op_hash(req, cfg, ctx):
    if not cfg["allowHash"]:
        raise PermissionError("hashing is disabled (allowHash=false)")
    path = resolve_path(req.get("path"), cfg, must_exist=True)
    if os.path.isdir(path):
        raise IsADirectoryError("path is a directory: %s" % path)
    st = os.stat(path)
    return {
        "path": path,
        "size": st.st_size,
        "sha256": sha256_file(path),
        "mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime)),
    }


def op_exec(req, cfg, ctx):
    if not cfg["allowExec"]:
        raise PermissionError("exec is disabled (allowExec=false)")
    script = req.get("script") or ""
    if not script.strip():
        raise ValueError("exec requires 'script'")
    shell = (req.get("shell") or "bash").lower()
    timeout = clamp(req.get("timeout_sec"), 1, cfg["maxTimeoutSec"], cfg["defaultTimeoutSec"])
    work = tempfile.mkdtemp(prefix="agent-exec-", dir=ctx["work_root"])
    out_path = os.path.join(ctx["logs_dir"], "%s.stdout.txt" % req["req"])
    err_path = os.path.join(ctx["logs_dir"], "%s.stderr.txt" % req["req"])

    if shell in ("powershell", "pwsh"):
        exe = shutil.which("pwsh")
        if not exe:
            raise RuntimeError("pwsh not found; use shell=bash on this host")
        script_path = os.path.join(work, "task.ps1")
        argv = [exe, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script_path]
    else:
        exe = shutil.which("bash") or "/bin/sh"
        script_path = os.path.join(work, "task.sh")
        argv = [exe, script_path]

    with open(script_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(script)

    cwd = req.get("cwd")
    cwd = resolve_path(cwd, cfg, must_exist=True) if cwd else ctx["work_root"]

    env = dict(os.environ)
    env.update({"AGENT_REQ": req["req"], "AGENT_WORKER": "posix", "PYTHONUNBUFFERED": "1"})
    started = time.time()
    proc = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    buffers = {"out": bytearray(), "err": bytearray()}

    def reader(stream, key):
        for chunk in iter(lambda: stream.read(4096), b""):
            buffers[key].extend(chunk)

    threads = [
        threading.Thread(target=reader, args=(proc.stdout, "out"), daemon=True),
        threading.Thread(target=reader, args=(proc.stderr, "err"), daemon=True),
    ]
    for thread in threads:
        thread.start()

    cap = cfg["maxOutputBytes"]
    progress = cfg["progressEverySec"]
    last_progress = 0.0
    timed_out = False
    while proc.poll() is None:
        elapsed = time.time() - started
        if elapsed > timeout:
            timed_out = True
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                proc.kill()
            break
        if progress and ctx.get("progress_cb") and elapsed - last_progress >= progress:
            last_progress = elapsed
            ctx["progress_cb"](buffers["out"].decode("utf-8", "replace"), elapsed)
        time.sleep(0.2)

    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:  # pragma: no cover
        proc.kill()
    for thread in threads:
        thread.join(timeout=10)

    stdout = buffers["out"].decode("utf-8", "replace")
    stderr = buffers["err"].decode("utf-8", "replace")
    with open(out_path, "wb") as fh:
        fh.write(stdout.encode("utf-8", "replace")[:cap])
    with open(err_path, "wb") as fh:
        fh.write(stderr.encode("utf-8", "replace")[:cap])

    shutil.rmtree(work, ignore_errors=True)
    return {
        "exit_code": proc.returncode,
        "timed_out": timed_out,
        "duration_ms": int((time.time() - started) * 1000),
        "stdout": stdout,
        "stderr": stderr,
        "log_path": out_path,
        "err_path": err_path,
    }


OPS = {
    "ping": op_ping,
    "info": op_info,
    "ls": op_ls,
    "read": op_read,
    "write": op_write,
    "hash": op_hash,
    "exec": op_exec,
}


# --------------------------------------------------------------------------
# task runner
# --------------------------------------------------------------------------
def run_task(req, cfg, ctx):
    started = time.time()
    started_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    result = {
        "v": 1,
        "req": req.get("req") or "unknown",
        "op": req.get("op"),
        "worker": "posix",
        "worker_version": VERSION,
        "host": socket.gethostname(),
        "user": os.environ.get("USER") or os.environ.get("USERNAME") or "unknown",
        "started": started_iso,
        "ok": False,
        "error": None,
        "exit_code": None,
    }
    try:
        handler = OPS.get(req.get("op"))
        if handler is None:
            raise ValueError("unknown op: %r (expected one of %s)" % (req.get("op"), ", ".join(OPS)))
        payload = handler(req, cfg, ctx)
        result["ok"] = True
        if req.get("op") == "exec":
            for key in ("exit_code", "timed_out", "duration_ms", "log_path"):
                if key in payload:
                    result[key] = payload[key]
            stdout, stdout_len, stdout_cut = truncate_inline(payload.pop("stdout"))
            stderr, stderr_len, stderr_cut = truncate_inline(payload.pop("stderr"))
            result.update(
                {
                    "stdout": stdout,
                    "stderr": stderr,
                    "stdout_len": stdout_len,
                    "stderr_len": stderr_len,
                    "stdout_truncated": stdout_cut,
                    "stderr_truncated": stderr_cut,
                }
            )
            if result["exit_code"] not in (0, None) and not result["error"]:
                result["ok"] = True  # the command ran; non-zero exit is data, not failure
            payload.pop("err_path", None)
        result["result"] = payload
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller by design
        result["ok"] = False
        result["error"] = "%s: %s" % (type(exc).__name__, exc)
    finished = time.time()
    result["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(finished))
    if "duration_ms" not in result or result.get("duration_ms") is None:
        result["duration_ms"] = int((finished - started) * 1000)
    return result


def cap_payload(result):
    """Shrink a result so its base64 envelope fits in one GitHub comment."""
    probe = json.dumps(result).encode("utf-8")
    if len(probe) * 4 / 3 < MAX_ENVELOPE:
        return result
    trimmed = dict(result)
    if trimmed.get("stdout"):
        trimmed["stdout"] = trimmed["stdout"][:2000] + "\n…[truncated]"
        trimmed["stdout_truncated"] = True
    data = trimmed.get("result", {}).get("data_base64")
    if data:
        # drop base64 blobs out of the JSON and rely on chunked `read` instead
        trimmed["result"] = dict(trimmed["result"])
        trimmed["result"].pop("data_base64", None)
        trimmed["result"]["note"] = "payload too large for one comment; re-read with offset/length"
    entries = (trimmed.get("result") or {}).get("entries")
    if entries:
        keep = len(entries)
        while keep > 1:
            keep //= 2
            trimmed["result"]["entries"] = entries[:keep]
            trimmed["result"]["count"] = keep
            trimmed["result"]["truncated"] = True
            trimmed["result"]["total_entries"] = len(entries)
            if len(json.dumps(trimmed).encode("utf-8")) * 4 / 3 < MAX_ENVELOPE:
                break

    probe = json.dumps(trimmed).encode("utf-8")
    while len(probe) * 4 / 3 >= MAX_ENVELOPE and len(trimmed.get("stdout", "")) > 200:
        trimmed["stdout"] = trimmed["stdout"][: len(trimmed["stdout"]) // 2]
        trimmed["stdout_truncated"] = True
        probe = json.dumps(trimmed).encode("utf-8")
    return trimmed


# --------------------------------------------------------------------------
# transports
# --------------------------------------------------------------------------
# Protocol v1 ("issue per request"): the agent creates one issue per request
# (it may create issues but not comment), the worker replies with a comment and
# closes the issue.  See ../PROTOCOL.md.
# --------------------------------------------------------------------------
class FileTransport:
    """Local mailbox for tests / offline use: one `mailbox.jsonl` in a directory."""

    name = "file"

    def __init__(self, directory):
        self.dir = directory
        os.makedirs(directory, exist_ok=True)
        self.store = os.path.join(directory, "mailbox.jsonl")
        open(self.store, "a", encoding="utf-8").close()

    def _read(self):
        items = []
        with open(self.store, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    items.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return items

    def _append(self, record):
        with open(self.store, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        return record

    def open_requests(self):
        data = self._read()
        closed = {r["number"] for r in data if r.get("kind") == "close"}
        return [
            r
            for r in data
            if r.get("kind") == "issue" and r["number"] not in closed
        ]

    def reply(self, number, body):
        data = self._read()
        next_id = 1 + max([int(r.get("id", 0)) for r in data if r.get("kind") == "comment"] or [0])
        self._append({"kind": "comment", "issue": number, "id": next_id,
                      "body": body, "created_at": now_iso()})

    def close(self, number):
        self._append({"kind": "close", "number": number, "created_at": now_iso()})


class GithubTransport:
    """GitHub issues as the mailbox (issue = request, comment = result)."""

    name = "github"
    api = "https://api.github.com"

    def __init__(self, repo, token, prefix="[agent-req]"):
        if not repo:
            raise SystemExit("--repo is required for the github transport")
        if not token:
            raise SystemExit("GITHUB_TOKEN is required for the github transport")
        self.repo = repo
        self.token = token
        self.prefix = prefix

    def _call(self, method, url, payload=None):
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("Authorization", "Bearer %s" % self.token)
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        request.add_header("User-Agent", "local-access-agent/%s" % VERSION)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                body = response.read().decode("utf-8")
                return response.status, (json.loads(body) if body.strip() else None)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            raise RuntimeError("GitHub API %s %s -> %s: %s" % (method, url, exc.code, body[:300]))

    def open_requests(self):
        out, page = [], 1
        while page <= 5:
            _, data = self._call(
                "GET",
                "%s/repos/%s/issues?state=open&per_page=50&page=%d&sort=created&direction=asc"
                % (self.api, self.repo, page),
            )
            if not data:
                break
            for issue in data:
                if "pull_request" in issue:
                    continue
                if not (issue.get("title") or "").startswith(self.prefix):
                    continue
                out.append(issue)
            if len(data) < 50:
                break
            page += 1
        return out

    def reply(self, number, body):
        self._call(
            "POST",
            "%s/repos/%s/issues/%s/comments" % (self.api, self.repo, number),
            {"body": body},
        )

    def close(self, number):
        try:
            self._call(
                "PATCH",
                "%s/repos/%s/issues/%s" % (self.api, self.repo, number),
                {"state": "closed", "state_reason": "completed"},
            )
        except RuntimeError as exc:
            log("warning: could not close #%s: %s" % (number, exc))


# --------------------------------------------------------------------------
# envelopes
# --------------------------------------------------------------------------
def decode_req(body):
    match = REQ_RE.search(body or "")
    if not match:
        return None
    try:
        return json.loads(b64d(match.group(1)).decode("utf-8"))
    except Exception:
        return None


def decode_res(body):
    match = RES_RE.search(body or "")
    if not match:
        return None
    try:
        return json.loads(b64d(match.group(1)).decode("utf-8"))
    except Exception:
        return None


def encode_res(result):
    payload = json.dumps(cap_payload(result), ensure_ascii=False).encode("utf-8")
    return "<!--AGENT:RES:v1:%s-->" % b64e(payload)


# --------------------------------------------------------------------------
# main loop
# --------------------------------------------------------------------------
def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(message):
    line = "%s %s" % (now_iso(), message)
    print(line, file=sys.stderr, flush=True)
    state_log = os.environ.get("AGENT_WORKER_LOG")
    if state_log:
        with open(state_log, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def acquire_lock(path):
    """Refuse to run twice against the same state file (double execution check)."""
    try:
        import fcntl
    except ImportError:  # pragma: no cover - windows
        return None
    handle = open(path + ".lock", "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit("another worker already holds %s" % (path + ".lock"))
    return handle


def load_state(path):
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, json.JSONDecodeError):
            pass
    return {"done_issues": [], "done_reqs": []}


def save_state(path, state):
    state["done_issues"] = state.get("done_issues", [])[-500:]
    state["done_reqs"] = state.get("done_reqs", [])[-500:]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local-access agent worker (POSIX)")
    parser.add_argument("--transport", choices=["github", "file"], default="github")
    parser.add_argument("--repo", default=os.environ.get("AGENT_REPO", ""))
    parser.add_argument("--prefix", default=os.environ.get("AGENT_PREFIX", "[agent-req]"))
    parser.add_argument("--file-dir", default=os.environ.get("AGENT_MAILBOX_DIR", ""))
    parser.add_argument("--config", default=os.environ.get("AGENT_CONFIG", ""))
    parser.add_argument("--state", default=os.environ.get("AGENT_STATE", "state.json"))
    parser.add_argument("--work-root", default=(os.environ.get("AGENT_WORK_ROOT") or os.path.join(tempfile.gettempdir(), "local-access-agent")))
    parser.add_argument("--interval", type=int, default=0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--init", action="store_true", help="mark current open requests as already handled")
    parser.add_argument("--replay", action="store_true")
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    interval = args.interval or cfg["pollSeconds"]
    logs_dir = os.path.join(args.work_root, "logs")
    os.makedirs(logs_dir, exist_ok=True)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if args.transport == "github":
        transport = GithubTransport(args.repo, token, args.prefix)
    else:
        transport = FileTransport(args.file_dir or args.work_root)

    lock = acquire_lock(args.state)
    state = load_state(args.state)
    ctx = {"work_root": args.work_root, "logs_dir": logs_dir, "progress_cb": None}

    if args.init:
        issues = transport.open_requests()
        for issue in issues:
            state.setdefault("done_issues", []).append(int(issue["number"]))
            req = decode_req(issue.get("body"))
            if req and req.get("req"):
                state.setdefault("done_reqs", []).append(req["req"])
        save_state(args.state, state)
        log("initialised: %d open request(s) marked as handled" % len(issues))
        return 0

    log("worker %s up (transport=%s interval=%ss)" % (VERSION, transport.name, interval))

    while True:
        try:
            issues = list(reversed(transport.open_requests()))  # oldest first
        except Exception as exc:  # noqa: BLE001 - keep the loop alive
            log("poll failed: %s" % exc)
            issues = []

        for issue in issues:
            number = int(issue["number"])
            body = issue.get("body") or ""
            req = decode_req(body)
            req_id = (req or {}).get("req") or "unknown"

            if number in state.get("done_issues", []) or req_id in state.get("done_reqs", []):
                if not args.replay:
                    transport.close(number)
                    continue

            if req is None:
                log("issue #%s: no request envelope, closing" % number)
                state.setdefault("done_issues", []).append(number)
                save_state(args.state, state)
                transport.close(number)
                continue

            log("run %s (issue #%s) op=%s" % (req_id, number, req.get("op")))
            result = run_task(req, cfg, ctx)
            try:
                transport.reply(number, encode_res(result))
                log("result %s ok=%s" % (req_id, result.get("ok")))
            except Exception as exc:  # noqa: BLE001
                log("reply failed for %s: %s" % (req_id, exc))
            state.setdefault("done_issues", []).append(number)
            state.setdefault("done_reqs", []).append(req_id)
            save_state(args.state, state)
            transport.close(number)

        if args.once:
            return 0
        time.sleep(max(1, interval))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
