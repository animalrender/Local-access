# Local-access

Give the Arena agent a working channel to a machine you own (Windows / Linux),
so it can run commands, read files and write files there — while the agent's own
network stays limited to GitHub, npm and PyPI.

**Start here: [docs/agent-bridge.fa.md](docs/agent-bridge.fa.md)** (فارسی)

| path | what it is |
|---|---|
| `docs/agent-bridge.fa.md` | full guide: architecture, setup, security, troubleshooting |
| `agent/PROTOCOL.md` | the wire protocol (issue = request, comment = result) |
| `agent/windows/Install-Worker.ps1` | one-time setup on Windows (config, permissions, self-test, scheduled task) |
| `agent/windows/AgentWorker.ps1` | the worker: polls the mailbox, executes, replies, closes |
| `agent/windows/AgentTask.ps1` | executor + path sandbox (`exec/ls/read/write/hash/info/ping`) |
| `agent/windows/Live-Service.ps1` | optional token-protected HTTP endpoint (for a tailnet peer) |
| `agent/linux/worker.py` | same worker for Linux / WSL / macOS |
| `agent/selftest.sh` | offline end-to-end test (no GitHub, no Windows) |
| `scripts/agent.py` | the client the agent uses |

Quick check that the protocol itself works:

```bash
bash agent/selftest.sh     # 17/17 ok
```

## Why not Tailscale (or an Actions runner)?

Measured from inside the agent sandbox:

* `controlplane.tailscale.com`, `login.tailscale.com`, `pkgs.tailscale.com` and
  `100.64.0.0/10` are all unreachable → no tailnet, no `tailscaled` install.
* `POST .../actions/workflows/{id}/dispatches` → `403` (token has `actions: read` only).
* but `POST /issues` → `201`, `GET /issues/{n}/comments` → `200`, `git push` → `ok`.

So the transport that actually works is a GitHub issue per request. Details and
the security model are in the guide.
