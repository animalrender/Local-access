#!/usr/bin/env python3
"""
agent.py — the agent-side client for the Local-access bridge.

How it works (and why it looks like this): this sandbox can only reach
github.com / api.github.com / npm / PyPI, and its token may *create* issues but
not comment on them.  So a request is one issue on the private repo; the worker
on your PC answers with a comment and closes the issue.  Nothing inbound is
needed on your side, and the whole exchange stays visible in the issue list.

    scripts/agent.py ping
    scripts/agent.py exec "Get-Process | Sort CPU -Desc | Select -First 5"
    scripts/agent.py ls "C:\\Users\\me\\Desktop" --recursive
    scripts/agent.py read "C:\\Users\\me\\notes.txt"
    scripts/agent.py write "C:\\Users\\me\\notes.txt" --from ./notes.txt
    scripts/agent.py hash "C:\\Users\\me\\big.iso"
    scripts/agent.py status

Environment:
    AGENT_REPO       owner/name         (default: animalrender/Local-access)
    AGENT_TOKEN      GitHub token       (default: $GITHUB_TOKEN / $GH_TOKEN / `gh auth token`)
    AGENT_WAIT       seconds to wait    (default: 180)
    AGENT_POLL       poll interval      (default: 3)
    AGENT_MAILBOX_DIR  local mailbox instead of GitHub (offline testing)
"""

import argparse
import base64
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
VERSION = "2.0.0"
PREFIX = "[agent-req]"          # issues with this title prefix are requests
REQ_RE = re.compile(r"<!--AGENT:REQ:v1:([A-Za-z0-9+/=]+)-->")
RES_RE = re.compile(r"<!--AGENT:RES:v1:([A-Za-z0-9+/=]+)-->")
CHUNK = 32000                   # bytes per write round-trip (base64 must fit one comment)


# --------------------------------------------------------------------------- #
# github
# --------------------------------------------------------------------------- #
class GitHub:
    def __init__(self, repo, token):
        self.repo = repo
        self.token = token

    def call(self, method, path, payload=None, query=None):
        url = API + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("Authorization", "Bearer %s" % self.token)
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        request.add_header("User-Agent", "local-access-agent-client/%s" % VERSION)
        if data:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                raw = response.read().decode("utf-8")
                return json.loads(raw) if raw.strip() else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise SystemExit("GitHub %s %s failed: HTTP %s\n%s" % (method, path, exc.code, detail[:600]))

    def repo_info(self):
        return self.call("GET", "/repos/%s" % self.repo)

    def create_issue(self, title, body):
        return self.call("POST", "/repos/%s/issues" % self.repo, {"title": title, "body": body})

    def issue(self, number):
        return self.call("GET", "/repos/%s/issues/%d" % (self.repo, number))

    def comments(self, number):
        out, page = [], 1
        while page <= 5:
            batch = self.call(
                "GET",
                "/repos/%s/issues/%d/comments" % (self.repo, number),
                query={"per_page": 100, "page": page},
            ) or []
            out.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        return out

    def open_requests(self):
        out, page = [], 1
        while page <= 5:
            batch = self.call(
                "GET",
                "/repos/%s/issues" % self.repo,
                query={"state": "open", "per_page": 50, "page": page, "sort": "created", "direction": "asc"},
            ) or []
            for issue in batch:
                if "pull_request" in issue:
                    continue
                if str(issue.get("title", "")).startswith(PREFIX):
                    out.append(issue)
            if len(batch) < 50:
                break
            page += 1
        return out


class FileBackend:
    """Offline mailbox with the same interface (used by agent/selftest.sh)."""

    def __init__(self, directory):
        self.dir = directory
        self.repo = "local/mailbox"
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

    def repo_info(self):
        return {"private": True, "full_name": self.repo}

    def create_issue(self, title, body):
        data = self._read()
        number = 1 + max([int(r.get("number", 0)) for r in data if r.get("kind") == "issue"] or [0])
        return self._append({"kind": "issue", "number": number, "title": title, "body": body,
                             "state": "open", "created_at": now_iso()})

    def comments(self, number):
        return [r for r in self._read() if r.get("kind") == "comment" and int(r.get("issue", 0)) == int(number)]

    def open_requests(self):
        data = self._read()
        closed = {int(r["number"]) for r in data if r.get("kind") == "close"}
        return [
            r for r in data
            if r.get("kind") == "issue" and int(r["number"]) not in closed
            and str(r.get("title", "")).startswith(PREFIX)
        ]


# --------------------------------------------------------------------------- #
# envelopes
# --------------------------------------------------------------------------- #
def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def b64e(data):
    return base64.b64encode(data).decode("ascii")


def b64d(text):
    return base64.b64decode(text.encode("ascii"))


def encode_req(obj):
    return "<!--AGENT:REQ:v1:%s-->" % b64e(json.dumps(obj, ensure_ascii=False).encode("utf-8"))


def decode(body, pattern):
    match = pattern.search(body or "")
    if not match:
        return None
    try:
        return json.loads(b64d(match.group(1)).decode("utf-8"))
    except Exception:
        return None


def summarize_request(request):
    """Human-readable line for the issue body, so the request is auditable."""
    op = request.get("op")
    if op == "exec":
        script = (request.get("script") or "").strip().replace("\n", " ⏎ ")
        return "exec: `%s`" % (script[:300])
    if op in ("read", "write", "hash", "ls"):
        extra = ""
        if op == "read":
            extra = " (offset %s, %s bytes)" % (request.get("offset", 0), request.get("length"))
        if op == "write":
            extra = " (%s bytes, mode %s)" % (request.get("bytes", "?"), request.get("mode"))
        return "%s: `%s`%s" % (op, request.get("path"), extra)
    return str(op)


# --------------------------------------------------------------------------- #
# request/response round-trip
# --------------------------------------------------------------------------- #
class Mailbox:
    def __init__(self, gh, wait, poll, quiet=False):
        self.gh = gh
        self.wait = wait
        self.poll = poll
        self.quiet = quiet

    def submit(self, request):
        request.setdefault("v", 1)
        request.setdefault("created", now_iso())
        title = "%s %s %s" % (PREFIX, request["req"], request.get("op"))
        body = "\n".join(
            [
                encode_req(request),
                "",
                "**%s** — %s" % (request.get("op"), summarize_request(request)),
                "",
                "_request from the Arena agent; the worker replies below and closes the issue_",
            ]
        )
        issue = self.gh.create_issue(title, body)
        if not self.quiet:
            print("→ %s %s (issue #%s)" % (request["req"], request.get("op"), issue["number"]), file=sys.stderr)
        return int(issue["number"])

    def wait_for(self, req_id, number):
        deadline = time.time() + self.wait
        partial_seen = False
        while time.time() < deadline:
            for comment in self.gh.comments(number):
                result = decode(comment.get("body"), RES_RE)
                if not result or result.get("req") != req_id:
                    continue
                if result.get("partial"):
                    if not self.quiet and result.get("stdout"):
                        sys.stderr.write(result["stdout"][-1200:])
                        sys.stderr.flush()
                    partial_seen = True
                    continue
                return result
            time.sleep(self.poll)
        if partial_seen:
            print("\n! timed out, the last partial output is above", file=sys.stderr)
        else:
            print(
                "! no answer after %ss — worker offline?  see: scripts/agent.py status" % self.wait,
                file=sys.stderr,
            )
        return None

    def run(self, request):
        number = self.submit(request)
        return self.wait_for(request["req"], number)


# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #
def print_result(result, raw=False):
    if raw:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return
    if not result.get("ok"):
        print("✗ %s  (%s)" % (result.get("req"), result.get("error")), file=sys.stderr)
        if result.get("stdout"):
            print(result["stdout"])
        return
    op = result.get("op")
    meta = "host=%s user=%s %sms" % (result.get("host"), result.get("user"), result.get("duration_ms"))
    if op == "exec":
        print("[exec exit=%s %s]" % (result.get("exit_code"), meta), file=sys.stderr)
        if result.get("stdout"):
            sys.stdout.write(result["stdout"])
            if not result["stdout"].endswith("\n"):
                sys.stdout.write("\n")
        if result.get("stderr"):
            sys.stderr.write(result["stderr"])
        if result.get("stdout_truncated"):
            print("(truncated; full log on the PC: %s)" % result.get("log_path"), file=sys.stderr)
    elif op == "ls":
        entries = (result.get("result") or {}).get("entries") or []
        for entry in entries:
            size = "" if entry.get("size") is None else str(entry["size"]).rjust(12)
            print("%s %s %s" % ("d" if entry["type"] == "dir" else "-", size, entry["path"]))
        print("[%d entries]" % len(entries), file=sys.stderr)
    elif op == "read":
        info = result.get("result") or {}
        if info.get("data_base64"):
            data = b64d(info["data_base64"])
            text = None
            if b"\x00" not in data[:4096]:
                try:
                    text = data.decode("utf-8")
                except UnicodeDecodeError:
                    text = None
            if text is not None:
                sys.stdout.write(text)
                if not text.endswith("\n"):
                    sys.stdout.write("\n")
            else:
                print("[binary %d bytes, sha256=%s]" % (len(data), info.get("sha256")))
        else:
            print(json.dumps(info, indent=2, ensure_ascii=False))
    else:
        print(json.dumps(result.get("result") or {}, indent=2, ensure_ascii=False))


def new_req_id():
    return "r-%s-%04x" % (time.strftime("%Y%m%dT%H%M%S", time.gmtime()), random.getrandbits(16))


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def build_request(args):
    request = {"v": 1, "req": new_req_id(), "op": args.command}
    if args.command == "exec":
        request["script"] = args.script
        if args.shell:
            request["shell"] = args.shell
        if args.cwd:
            request["cwd"] = args.cwd
        if args.timeout:
            request["timeout_sec"] = args.timeout
    elif args.command == "ls":
        request["path"] = args.path
        request["recursive"] = bool(args.recursive)
        if args.pattern:
            request["pattern"] = args.pattern
    elif args.command == "read":
        request["path"] = args.path
        request["offset"] = args.offset
        request["length"] = args.length
    elif args.command == "write":
        request["path"] = args.path
        request["mode"] = args.mode
        request["create_dirs"] = True
    elif args.command == "hash":
        request["path"] = args.path
    return request


def cmd_simple(args, mailbox):
    result = mailbox.run(build_request(args))
    if not result:
        return 1
    print_result(result, raw=args.json)
    return 0 if result.get("ok") else 1


def cmd_read(args, mailbox):
    if not args.out:
        return cmd_simple(args, mailbox)
    offset, got, size = args.offset, 0, 0
    with open(args.out, "wb") as fh:
        while True:
            request = {"v": 1, "req": new_req_id(), "op": "read",
                       "path": args.path, "offset": offset, "length": args.length}
            result = mailbox.run(request)
            if not result or not result.get("ok"):
                if result:
                    print_result(result)
                raise SystemExit("read failed at offset %d" % offset)
            info = result.get("result") or {}
            if "data_base64" not in info:
                raise SystemExit("worker dropped the payload (chunk too large); re-run with --length 30000")
            data = b64d(info.get("data_base64") or "")
            fh.write(data)
            got += len(data)
            size = info.get("size", 0)
            if not data or offset + len(data) >= size:
                break
            offset += len(data)
    print("wrote %d/%d bytes to %s" % (got, size, args.out), file=sys.stderr)
    return 0


def cmd_write(args, mailbox):
    payload = sys.stdin.buffer.read() if args.stdin else open(args.source, "rb").read()
    total, offset, mode = len(payload), 0, args.mode
    while True:
        chunk = payload[offset:offset + args.chunk]
        request = {"v": 1, "req": new_req_id(), "op": "write", "path": args.path,
                   "mode": mode, "data_base64": b64e(chunk), "create_dirs": True, "bytes": total}
        result = mailbox.run(request)
        if not result or not result.get("ok"):
            if result:
                print_result(result)
            raise SystemExit("write failed at offset %d" % offset)
        offset += len(chunk)
        mode = "append"
        if offset >= total:
            break
    print("wrote %d bytes to %s" % (total, args.path), file=sys.stderr)
    return 0


def cmd_status(args, mailbox):
    gh = mailbox.gh
    open_requests = gh.open_requests()
    print("repo %s   open requests: %d" % (gh.repo, len(open_requests)))
    if not open_requests:
        print("  (nothing pending — the worker has answered and closed everything)")
        return 0
    now = time.time()
    for issue in open_requests[-10:]:
        created = issue.get("created_at") or ""
        age = ""
        try:
            age = "%.0fs" % (now - time.mktime(time.strptime(created, "%Y-%m-%dT%H:%M:%SZ")) + time.timezone)
        except Exception:
            pass
        req = decode(issue.get("body"), REQ_RE) or {}
        print("  #%s %-28s %-6s %s ago" % (issue["number"], issue.get("title", "")[len(PREFIX):].strip(),
                                           (req.get("op") or "?"), age or "?"))
    print("hint: open requests that never get answered mean the worker is stopped or its token expired")
    return 0


def cmd_result(args, mailbox):
    gh = mailbox.gh
    for issue in gh.open_requests():
        if args.req in str(issue.get("title", "")):
            for comment in gh.comments(issue["number"]):
                result = decode(comment.get("body"), RES_RE)
                if result and result.get("req") == args.req and not result.get("partial"):
                    print_result(result, raw=args.json)
                    return 0
    raise SystemExit("no result found for %s" % args.req)


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #
def main(argv=None):
    common = argparse.ArgumentParser(add_help=False, argument_default=argparse.SUPPRESS)
    common.add_argument("--repo")
    common.add_argument("--token")
    common.add_argument("--wait", type=int)
    common.add_argument("--poll", type=int)
    common.add_argument("--mailbox-dir", help="local mailbox instead of GitHub (offline/testing)")
    common.add_argument("--allow-public", action="store_true")
    common.add_argument("--json", action="store_true", help="print the raw result object")
    common.add_argument("-q", "--quiet", action="store_true")

    parser = argparse.ArgumentParser(description="Agent client for the Local-access bridge", parents=[common])
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("ping", parents=[common], help="round-trip test / show worker config")
    sub.add_parser("info", parents=[common], help="host, os, drives, tailscale")
    sub.add_parser("status", parents=[common], help="pending requests, worker liveness")

    p_exec = sub.add_parser("exec", parents=[common], help="run a script on the worker host")
    p_exec.add_argument("script")
    p_exec.add_argument("--shell", default=None, help="powershell (default) | cmd | bash")
    p_exec.add_argument("--cwd", default=None)
    p_exec.add_argument("--timeout", type=int, default=None)

    p_ls = sub.add_parser("ls", parents=[common], help="list a directory")
    p_ls.add_argument("path")
    p_ls.add_argument("--recursive", action="store_true")
    p_ls.add_argument("--pattern", default=None)

    p_read = sub.add_parser("read", parents=[common], help="read a file (chunked)")
    p_read.add_argument("path")
    p_read.add_argument("--offset", type=int, default=0)
    p_read.add_argument("--length", type=int, default=30000)
    p_read.add_argument("--out", default=None, help="save to this local path instead of printing")

    p_write = sub.add_parser("write", parents=[common], help="write a file (chunked)")
    p_write.add_argument("path")
    p_write.add_argument("--from", dest="source", default=None)
    p_write.add_argument("--stdin", action="store_true")
    p_write.add_argument("--mode", default="overwrite", choices=["overwrite", "append"])
    p_write.add_argument("--chunk", type=int, default=CHUNK)

    p_hash = sub.add_parser("hash", parents=[common], help="sha256 of a remote file")
    p_hash.add_argument("path")

    p_res = sub.add_parser("result", parents=[common], help="re-print a result by request id")
    p_res.add_argument("req")

    args = parser.parse_args(argv)
    defaults = {
        "repo": os.environ.get("AGENT_REPO", "animalrender/Local-access"),
        "token": os.environ.get("AGENT_TOKEN", ""),
        "wait": int(os.environ.get("AGENT_WAIT", "180")),
        "poll": int(os.environ.get("AGENT_POLL", "3")),
        "mailbox_dir": os.environ.get("AGENT_MAILBOX_DIR", ""),
        "allow_public": False,
        "json": False,
        "quiet": False,
    }
    for key, value in defaults.items():
        if not hasattr(args, key):
            setattr(args, key, value)

    if args.mailbox_dir:
        backend = FileBackend(args.mailbox_dir)
    else:
        token = args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if not token:
            try:
                token = subprocess.check_output(["gh", "auth", "token"], text=True).strip()
            except Exception:
                raise SystemExit("no token: pass --token or export GITHUB_TOKEN")
        backend = GitHub(args.repo, token)
        info = backend.repo_info()
        if not info.get("private") and not args.allow_public:
            raise SystemExit(
                "refusing to use a PUBLIC repository: file contents and command output would be\n"
                "visible to the whole internet.  Make %s private\n"
                "  (Settings → General → Danger Zone → Change visibility → Private)\n"
                "or re-run with --allow-public if you accept that." % backend.repo
            )
    mailbox = Mailbox(backend, args.wait, args.poll, quiet=args.quiet)

    if args.command == "status":
        return cmd_status(args, mailbox)
    if args.command == "result":
        return cmd_result(args, mailbox)
    if args.command in ("ping", "info", "exec", "ls", "hash"):
        return cmd_simple(args, mailbox)
    if args.command == "read":
        return cmd_read(args, mailbox)
    if args.command == "write":
        if not args.source and not args.stdin:
            raise SystemExit("write needs --from FILE or --stdin")
        return cmd_write(args, mailbox)
    raise SystemExit("unknown command")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
