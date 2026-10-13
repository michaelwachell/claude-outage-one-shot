<p align="center">
  <img src="./assets/logo.png" alt="outage-one-shot logo" width="220">
</p>

# outage-one-shot

> **Not affiliated with, endorsed by, or sponsored by the NFL or any NFL club.** This is an
> independent personal project. "NFL" does not appear anywhere in this repo's code, docs, or
> examples, and the sample report under `examples/` is a genericized illustration, not real data
> from any specific company.

A read-only, active-incident diagnostic skill for [Claude Code](https://claude.com/claude-code).

Point it at an outage and it gathers evidence from Datadog, Sentry, LogRocket, Playwright flow
execution, and your own repositories; fans the work out to specialized subagents; correlates what comes back; and
hands everything to the strongest available reasoning model to produce a ranked, confidence-scored
root-cause report — mitigation first, verbose analysis after.

There is no separate compiled program. [`SKILL.md`](./SKILL.md) **is** the tool — Claude executes it
live, using its own tools (subagents, MCP, Bash, file I/O). The two scripts under `scripts/` exist only
for mechanical, deterministic checks that shouldn't depend on model judgment.

## Why

During a live incident you're usually flipping between three or four dashboards, a half-remembered
Playwright test, and a repo you haven't opened in a week, trying to build one coherent timeline before
you can even guess at a fix. This skill does that correlation pass automatically and consistently,
every time, with the same discipline: never guess at root cause when evidence doesn't support it, never
let a missing data source read as "healthy," and never touch production.

## Safety model

These are hardcoded, not configurable to anything less safe:

- **Never executes a production remediation.** No deploys, rollbacks, restarts, flag changes, config
  mutations, database writes, cache purges, secret rotations, or infra writes. Ever, automatically.
- **Never modifies your working tree.** Repository inspection always happens in an isolated clone or
  a temporary `git worktree` — never a `git reset`, `checkout --`, or `clean` against your checkout.
- **Never commits or pushes code**, in any repository, for any reason.
- **Never prints a raw credential value.** Config holds environment variable *names* only; secrets are
  read from the shell environment, or from an optional local `profiles/<name>.env` file (mode 600,
  never committed, never read into Claude's own context — see "Credential values" below), only at the
  moment a Playwright flow needs them, and never pass through model output. All evidence text runs
  through `scripts/redact.py` before it reaches a report or terminal.
- **An unavailable evidence source is never evidence of health.** If Datadog, Sentry, LogRocket, a
  repo, or a flow can't be reached, the report says so explicitly and excludes it from confidence — it
  never reads as "nothing wrong there."
- **Every claim carries a confidence word** — Confirmed / Probable / Possible / Unlikely / Unknown —
  so a hypothesis is never presented as a confirmed root cause.

Full detail is in `SKILL.md`'s "CRITICAL: Safety Rules" section, which overrides everything else in
the file, the config, or a user instruction for the duration of a run.

## Install

1. Clone this repo into Claude Code's user-level skills directory:

   ```bash
   git clone <this-repo-url> ~/.claude/skills/outage-one-shot
   ```

   (Or copy the files there by hand — `SKILL.md`, `scripts/`, and `templates/` need to end up directly
   under `~/.claude/skills/outage-one-shot/`.)

2. Restart Claude Code (or start a new session) so it picks up the skill.

3. Prerequisites:
   - `python3` with `pyyaml` installed (`pip3 install pyyaml`) — without it, config validation degrades
     to warnings instead of hard checks.
   - `git` on `PATH`.
   - For live Playwright flows: either a Playwright MCP server configured, or Node + `npx` with
     `@playwright/test` installed (`npx playwright install chromium` to get managed browser binaries —
     without them, a flow run can silently fall back to whatever browser happens to be on `PATH`).
   - Datadog, Sentry, and/or LogRocket MCP servers configured and authenticated, if you want those
     evidence sources. The skill still works without any of them — it just marks that source
     `unavailable` and keeps going. (LogRocket is a session-replay/frontend source — it maps to your
     configured frontends, not backend services.)

4. Run the doctor check against a profile once you've built one (see below) to confirm everything's
   wired up:

   ```text
   /outage-one-shot doctor --profile <name>
   ```

## Usage

| Command | Purpose |
|---|---|
| `/outage-one-shot init [--profile <name>]` | Interactive wizard that builds or extends a profile's config. |
| `/outage-one-shot run --profile <name> [--time <duration> \| --since <ISO8601>]` | Runs a full diagnostic pass and produces a report. |
| `/outage-one-shot config show --profile <name>` | Prints the profile config. |
| `/outage-one-shot config edit --profile <name>` | Re-enters the wizard against an existing profile. |
| `/outage-one-shot doctor [--profile <name>]` | Validates environment readiness: config, MCP servers, repos, Playwright, credentials. |
| `/outage-one-shot validate --profile <name>` | Dry-run validation of configured Playwright flows. |
| `/outage-one-shot status` | Lists known profiles and their last-run outcome. |

You don't have to type the exact command — plain language works too: "kick off an outage diagnosis
for checkout-production, last 30 minutes" maps onto `run --profile checkout-production --time 30m`.

### First-time setup

Run `/outage-one-shot init` and answer the wizard's questions: MCP server detection (Datadog/Sentry/LogRocket),
profile metadata, service and frontend inventory (repo paths/URLs, Datadog service names, Sentry
projects), Playwright flows for your critical user journeys, repository behavior (fetch/worktree
policy), and runtime defaults (concurrency, time budget, report format). The wizard writes incrementally
as you go, and you can re-run it any time via `config edit` to add a service or flow without starting
over.

Config lives outside this repo and outside whatever repo you're diagnosing, in a per-OS user directory
(see "Storage layout" in `SKILL.md`) — never inside a project's own `.git`.

### Credential values

If a Playwright flow needs auth and the wizard notices the credential env var names aren't already
set in your shell, it offers to generate `profiles/<name>.env` next to the profile — a blank
`KEY=` template (mode 600) for the three env var names, for you to fill in by hand in your own editor.
It's loaded automatically at run time only for whichever flow needs it, only if the shell doesn't
already have the value, and only inside that one subprocess invocation — never read into Claude's own
context, never committed, never shared. The shell environment always takes priority over this file.

### During an incident

```text
/outage-one-shot run --profile checkout-production --time 30m
```

Claude will:
1. Load the profile and gather incident context conversationally (symptoms, start time, affected
   segment — a single free-text answer covering several of these is fine).
2. Validate readiness, marking anything unreachable as unavailable rather than blocking the run.
3. Fan out concurrent subagents: Datadog, Sentry, LogRocket, one per Playwright flow, one per repository.
4. Run a Timeline Correlation pass and a Skeptic pass over the combined evidence.
5. Synthesize a ranked RCA on the strongest available model, with an explicit confidence word on
   every claim.
6. Write `report.md` + `report.json` to the run's timestamped report directory, and print the
   mitigation-first summary to the terminal immediately — no scrolling past the fix to find out what
   it is.

**Curious what that actually looks like?** [`examples/sample-report.md`](./examples/sample-report.md)
(+ [`.json`](./examples/sample-report.json)) is a real run's output, lightly genericized to the
fictional service names from `templates/config.example.yaml` — same structure, same evidence-driven
reasoning, same willingness to overturn its own leading hypothesis mid-synthesis when the code didn't
back it up.

### Validating the skill itself

`SKILL.md`'s "Example scenario" section describes a minimal smoke test: `init --profile demo` against
a toy service with a fake repo path and one Playwright flow, then `doctor` and a short `run`. The bar
for a passing smoke test is a *complete* report with every unavailable source correctly labeled — not
a clean bill of health. This skill was built and iterated against exactly that bar.

## How it's organized

```text
SKILL.md                     the skill itself — all behavior lives here
scripts/doctor.sh            mechanical environment/config checks (no model judgment)
scripts/redact.py            deterministic secret/PII scrubbing, run before anything is reported
templates/config.example.yaml  the config schema the init wizard writes against
```

## License

No license has been attached yet — all rights reserved by default under GitHub's terms. Reach out if
you want to use this and that's a blocker.
