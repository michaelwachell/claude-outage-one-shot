#!/usr/bin/env bash
# outage-one-shot doctor checks — mechanical, non-agentic validation only.
# Claude (per SKILL.md) interprets this script's output; this script makes
# no judgment calls about MCP names, config schema, or evidence quality.
#
# Usage: doctor.sh <path-to-profile-config.yaml>

set -uo pipefail

CONFIG_PATH="${1:-}"
FAIL=0

section() { printf '\n== %s ==\n' "$1"; }
ok()      { printf '  [OK]   %s\n' "$1"; }
warn()    { printf '  [WARN] %s\n' "$1"; }
fail()    { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

if [[ -z "$CONFIG_PATH" ]]; then
  fail "No config path given. Usage: doctor.sh <path-to-profile-config.yaml>"
  exit 1
fi

section "Config file"
if [[ -f "$CONFIG_PATH" ]]; then
  ok "Found: $CONFIG_PATH"
else
  fail "Config file not found at $CONFIG_PATH"
  exit 1
fi

HAVE_PYYAML=0
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import yaml" >/dev/null 2>&1; then
    HAVE_PYYAML=1
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$CONFIG_PATH" 2>/tmp/oos_yaml_err; then
      ok "YAML syntax valid"
    else
      fail "YAML syntax invalid: $(cat /tmp/oos_yaml_err)"
    fi
  else
    warn "python3 found but the 'yaml' module (pyyaml) is not installed — skipping YAML syntax validation and all config-driven checks below (repositories, credentials, report directory). Install with: pip3 install pyyaml. Claude should still sanity-check the file structure directly by reading it."
  fi
else
  warn "python3 not found — skipping YAML syntax validation (Claude should still sanity-check structure by reading the file)"
fi

section "Git"
if command -v git >/dev/null 2>&1; then
  ok "git available: $(git --version)"
else
  fail "git not found on PATH"
fi

section "Playwright"
if command -v npx >/dev/null 2>&1; then
  if npx --no-install playwright --version >/dev/null 2>&1; then
    ok "Playwright CLI available: $(npx --no-install playwright --version 2>/dev/null)"
    # The CLI being present does not mean its managed browser binaries are installed — confirmed by
    # reproduction: a run silently fell back to system Chrome instead of failing or warning, which
    # means flow results could depend on an uncontrolled, untested browser without anyone knowing.
    if command -v node >/dev/null 2>&1; then
      BROWSER_CHECK=$(node -e "
        try {
          const { chromium } = require('playwright');
          const fs = require('fs');
          const p = chromium.executablePath();
          console.log(fs.existsSync(p) ? 'INSTALLED' : 'MISSING:' + p);
        } catch (e) { console.log('UNKNOWN:' + e.message); }
      " 2>/dev/null)
      case "$BROWSER_CHECK" in
        INSTALLED) ok "Playwright-managed Chromium binary is installed" ;;
        MISSING:*) warn "Playwright-managed Chromium binary is NOT installed (${BROWSER_CHECK#MISSING:}). A flow run may silently fall back to whatever browser happens to be on PATH instead of the tested one. Run: npx playwright install chromium" ;;
        *) warn "Could not determine Playwright browser-binary install status (${BROWSER_CHECK#UNKNOWN:}) — Claude should check directly before relying on flow results" ;;
      esac
    else
      warn "node not found — cannot check Playwright browser-binary install status"
    fi
  else
    warn "Playwright CLI not found via npx in this environment. Claude may need to run 'npm install -D @playwright/test' or use the Playwright MCP server instead."
  fi
else
  warn "npx not found — cannot check local Playwright install. Rely on Playwright MCP if configured."
fi

section "Claude CLI / MCP"
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI available"
  # 'claude mcp list' is known to hang indefinitely when run as a nested subprocess from inside
  # an active Claude Code session on some hosts (reproduced on macOS/Bun) — never call it unguarded.
  # Portable watchdog (no dependency on GNU coreutils 'timeout', which stock macOS lacks).
  rm -f /tmp/oos_mcp_list.out
  claude mcp list >/tmp/oos_mcp_list.out 2>&1 &
  MCP_PID=$!
  ( sleep 10; kill -9 "$MCP_PID" 2>/dev/null ) &
  WATCHDOG_PID=$!
  if wait "$MCP_PID" 2>/dev/null; then
    kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null
    echo "  Configured MCP servers (raw 'claude mcp list' output below — Claude should parse this):"
    sed 's/^/    /' /tmp/oos_mcp_list.out
  else
    warn "'claude mcp list' did not return within 10s and was killed — likely a nested-CLI hang on this host. Claude should instead introspect its own currently available/deferred tool list (e.g. via ToolSearch) to determine which MCP servers are connected, rather than retrying this command."
  fi
  rm -f /tmp/oos_mcp_list.out
else
  fail "claude CLI not found on PATH — cannot check MCP server status"
fi

section "Report directory"
if [[ "$HAVE_PYYAML" -eq 1 ]]; then
  REPORT_DIR=$(python3 - "$CONFIG_PATH" <<'PYEOF' 2>/dev/null
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1]))
    print(cfg.get("profile", {}).get("report_dir", ""))
except Exception:
    pass
PYEOF
)
  if [[ -n "${REPORT_DIR:-}" ]]; then
    EXPANDED_DIR="${REPORT_DIR/#\~/$HOME}"
    mkdir -p "$EXPANDED_DIR" 2>/tmp/oos_dir_err
    if [[ -w "$EXPANDED_DIR" ]]; then
      ok "Report directory writable: $EXPANDED_DIR"
    else
      fail "Report directory not writable: $EXPANDED_DIR ($(cat /tmp/oos_dir_err 2>/dev/null))"
    fi
  else
    warn "Could not read profile.report_dir from config"
  fi
else
  warn "Skipped (pyyaml unavailable) — Claude should read profile.report_dir directly and verify it's writable"
fi

section "Repositories"
if [[ "$HAVE_PYYAML" -eq 1 ]]; then
  python3 - "$CONFIG_PATH" <<'PYEOF'
import sys, yaml, subprocess, os

cfg = yaml.safe_load(open(sys.argv[1]))
items = (cfg.get("services") or []) + (cfg.get("frontends") or [])
for item in items:
    rid = item.get("id", "?")
    repo_path = item.get("repo_path")
    repo_url = item.get("repo_url")
    if repo_path:
        expanded = os.path.expanduser(repo_path)
        if os.path.isdir(expanded):
            print(f"  [OK]   {rid}: local path exists ({expanded})")
            dirty = subprocess.run(
                ["git", "-C", expanded, "status", "--porcelain"],
                capture_output=True, text=True
            )
            if dirty.returncode == 0 and dirty.stdout.strip():
                print(f"  [WARN] {rid}: working tree has uncommitted changes — will be inspected via an isolated clone/worktree, not skipped, and uncommitted changes won't be visible there")
        else:
            print(f"  [WARN] {rid}: local path does not exist yet ({expanded}) — will need clone if repo_url is set")
    if repo_url and not repo_path:
        print(f"  [OK]   {rid}: no local path, remote url configured — will use managed cache clone")
    if not repo_path and not repo_url:
        print(f"  [FAIL] {rid}: no repo_path or repo_url configured")
PYEOF
else
  warn "Skipped (pyyaml unavailable) — Claude should read the services/frontends list directly and check each repo_path"
fi

section "Credential environment variables"
if [[ "$HAVE_PYYAML" -eq 1 ]]; then
  python3 - "$CONFIG_PATH" <<'PYEOF'
import sys, yaml, os, stat

config_path = sys.argv[1]
cfg = yaml.safe_load(open(config_path))
env_names = set()

creds = cfg.get("credentials") or {}
for k, v in creds.items():
    if k.endswith("_env") and v:
        env_names.add(v)

for flow in cfg.get("playwright_flows") or []:
    auth = flow.get("authentication") or {}
    for k, v in auth.items():
        if k.endswith("_env") and v:
            env_names.add(v)

# Sibling <profile>.env, if present, is loaded at run time for any name not already in the shell —
# check its permissions and which KEYS it defines, but never read or print the values themselves.
env_file = os.path.splitext(config_path)[0] + ".env"
env_file_keys = set()
if os.path.isfile(env_file):
    mode = stat.S_IMODE(os.stat(env_file).st_mode)
    if mode & 0o077:
        print(f"  [WARN] {env_file} is more permissive than mode 600 (group/other can read it) — chmod 600 it")
    else:
        print(f"  [OK]   {env_file} exists with safe permissions (mode 600)")
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                env_file_keys.add(line.split("=", 1)[0].strip())

if not env_names:
    print("  [WARN] No credential env var names found in config")
for name in sorted(env_names):
    if os.environ.get(name):
        print(f"  [OK]   {name} is set in this shell (value not shown)")
    elif name in env_file_keys:
        print(f"  [OK]   {name} is defined in {env_file} (value not shown, not verified non-empty)")
    else:
        print(f"  [WARN] {name} is referenced by config but not set in this shell or in {env_file}")
PYEOF
else
  warn "Skipped (pyyaml unavailable) — Claude should read the credential env var names directly from config and check them with 'printenv <name>'"
fi

section "Result"
if [[ "$FAIL" -eq 0 ]]; then
  echo "No hard failures. Review WARN lines above before running against an active incident."
else
  echo "One or more hard failures found. Resolve FAIL lines before running."
fi

exit "$FAIL"
