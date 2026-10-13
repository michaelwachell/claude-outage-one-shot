# Outage One-Shot Report
**Profile:** example-production · **Run type:** general health check (no incident reported) · **Incident window:** 2026-10-13T22:38:10Z–23:08:10Z · **Baseline:** 22:08:10Z–22:38:10Z

> **This is a sanitized real example**, lightly genericized from an actual run (service names, URLs, org
> names, and vendor specifics replaced with the fictional names from `templates/config.example.yaml`).
> It's here so you can see the shape of a real report before building your own profile — not a
> hand-written mockup. Nothing below describes an actual incident.

## Immediate Assessment

**Probable root cause:** No outage found. The system looks healthy. `account-api`'s +43.4% error count is **Probable** chronic IDP 400-404 errors rising with normal evening traffic. It is not a regression. The earlier leading hypothesis was "`account-api`'s token-exchange code bypasses its IDP error handler and caused an 'Error syncing IDP user: undefined' burst." Code review at the deployed commit **falsifies** it (see Key Evidence E7/E8).
**Confidence:** Medium on "no active incident." Live login passed, IDP 5xx is flat, two of three services improved, and Sentry shows nothing new. It is not High because a frontend session-replay source was unavailable, Sentry samples at 1%, and a 9-second error burst is still unexplained.
**Current impact:** None observed for users. The login journey at `account.example.com` passed end to end in 21.3s.
**Failure boundary:** None identified. Two small, short-lived anomalies stayed contained, both in `account-api`: 15 outbound fast-fail timeouts from 22:56:31Z, and 13 session-sync failures in 9s at 23:05:48–57Z.

## Immediate Mitigation

No production mitigation is warranted. Evidence does not support any rollback or config change. `allow_remediation_execution` is false: everything below is a suggestion for a human, and none of it is urgent.

1. **Do not roll back `account-api`'s recent runtime migration.** Why: it merged 11–13h before the window, IDP errors are proportional to traffic, and the login flow passes. A rollback adds risk (runtime/framework churn) without addressing any observed failure. Confidence: Probable. Validation: none needed. Rollback condition: revisit only if `account-api`'s 5xx rate *relative to request volume* rises in the next peak window.

## Next Five Minutes
- **Highest-value action:** none urgent. Optionally query the observability platform for `account-api`'s `/user-session-sync` endpoint between 23:05:40–23:06:05Z, grouped by status code, client, and IDP response, to see whether the 13 failures were one client retrying or a single IDP blip.
- **Highest-value validation:** compute `account-api` errors **per request** (errors ÷ total requests) for both windows. If the ratio is flat, the +43.4% is just traffic volume. Raw span counts are biased — error spans are often retained at ~100% while successes are sampled.
- **Highest-value missing evidence:** IDP-side journey logs for the sync endpoint at 23:05:48–57Z, and the upstream target of the 22:56:31Z timeouts.

## Key Evidence
- **E1 (Playwright, Confirmed, High):** Real login at `https://account.example.com` passed in 21.3s. Steps: email → auth-method screen → password → authenticated landing page. No 5xx, no TOTP, no browser-substitution fallback.
- **E2 (Observability platform, Confirmed):** IDP request volume +2%, 500-errors flat. `identity-api` errors −15%, `media-auth-api` errors −34% (both improved).
- **E3 (Observability platform, Confirmed):** `account-api` errors went 1,578 → 2,262 (+43.4%). 2,101 of them are "IDP client error 400-404," the same class that dominates the baseline (1,578). Raw counts, subject to sampling bias noted above.
- **E4 (Observability platform, Possible-correlate):** IDP tenant sessions +50%, auth +32%, OAuth grants +38%. Consistent with an evening traffic peak, which would explain E3's growth. Not confirmed against prior-day baselines.
- **E5 (Observability platform):** `account-api` outbound fast-fail timeouts, 15 total, starting 22:56:31Z. Upstream target not identified.
- **E6 (Observability platform):** "Error syncing IDP user: undefined," 13 hits between 23:05:48 and 23:05:57Z.
- **E7 (Repo, Confirmed, High; verified during synthesis):** `account-api`'s token-exchange helper uses `return await` **inside** a try block. Rejections are still caught by the surrounding catch, which calls the shared IDP error handler. Only success-path tracing tags are skipped. The "bypasses the error handler entirely" claim from the earlier collection stage was incorrect.
- **E8 (Repo, Confirmed, High; verified during synthesis):** the burst log is in a session-sync controller and prints `error?.data`. The call it wraps POSTs directly to an IDP journey endpoint and never touches the token-exchange helper above. The underlying HTTP client library stores error bodies at `.response.data`, so the log prints "undefined" for essentially every failure — a logging bug, not evidence of lost error context.
- **E9 (Repo/git, Confirmed):** `account-api`'s two runtime-migration PRs merged at 09:47:54Z and 11:21:03Z — 11–13 hours before the incident window.
- **E10 (Repo, Confirmed):** the IDP tenant config repo shows a defensive script patch at 21:06:00Z that explicitly treats a missing user-identifier attribute as an expected state for not-yet-backfilled identities — explaining the related `account-api` log hits as known residual noise, not an incident signal.
- **E11 (Observability platform, Confirmed, no impact):** an automated path-traversal security probe against `account-web`, 136 requests between 22:56:53 and 22:57:14Z, all rejected by the application framework.
- **E12 (Sentry, Confirmed, Low weight due to 1% sampling):** zero new or escalating issues in the window.

## Competing Hypotheses
1. **Healthy system; `account-api` error growth is chronic 400-404s scaling with evening traffic.** Supporting: E1, E2, E3 (dominant class unchanged), E4, E12. Contradicting: none direct, but the per-request ratio has not been computed. **Probable / Medium.** Falsifying test: an error-per-request ratio materially higher in the window than in the baseline.
2. **Transient IDP sync-journey failure, or a single client retrying, caused the 23:05:48Z burst.** Supporting: tight 9s clustering with self-recovery and nothing after it. Contradicting: no IDP-side journey evidence pulled, and IDP 500s are flat. **Possible / Low.**
3. **The `account-api` runtime migration introduced a latent regression that surfaced under peak load.** Supporting: a large runtime/framework change on the same day, plus a couple of behavior changes from the new HTTP framework (stricter body-size limit, stricter content-type handling). Contradicting: it was live for 11–13h without incident, the dominant error class is unchanged from baseline, and login passes. **Unlikely / Medium.**
4. **The token-exchange early-return caused the sync burst (the previous leading hypothesis).** Contradicting: E7 (errors are still handled) and E8 (the burst's code path never calls that helper). **Unlikely / High — effectively falsified.**
5. **The outbound timeouts are related to the security probe.** Contradicting: different services, the timeouts started 22s *earlier*, and the probe was rejected at the framework layer. **Unlikely / Medium.**

## Incident Timeline
| Time (UTC) | Observation | Source | Interpretation |
|---|---|---|---|
| 09:47:54 | `account-api` runtime-migration PR #1 merged | git | Background change, 13h before the window |
| 11:21:03 | `account-api` runtime-migration PR #2 merged | git | Background change, 11h before the window |
| 21:06:00 | IDP tenant script patched for a missing user-identifier attribute | idp config | Defensive fix; makes related `account-api` log hits expected noise |
| 22:08–22:38 | Baseline: `account-api` 1,578 errors, mostly IDP 400-404 | observability platform | Chronic error floor |
| 22:38–23:08 | IDP sessions/auth/grants +32–50%; `account-api` errors 2,262 | observability platform | Probable evening peak |
| 22:56:31 | `account-api` outbound fast-fail timeouts begin (15 total) | observability platform | Small, unexplained, upstream unknown |
| 22:56:53–22:57:14 | `account-web` path-traversal probe, 136 requests, all rejected | observability platform | Security noise, no impact |
| 23:05:48–23:05:57 | 13 "Error syncing IDP user: undefined" | observability platform | Short sync-journey failure burst; cause unknown; "undefined" is a logging artifact (E8) |
| ~23:08 | Login flow passes (21.3s) | Playwright | Login path healthy |

## Detailed Technical Analysis

### Affected Components
- **account-api:** chronic IDP 400-404 floor; small timeout and sync-failure anomalies; a freshly migrated runtime stack.
- **account-web:** probed by an automated scanner, no impact.
- **identity-api, media-auth-api, IDP tenant:** healthy or improved.

### Repository Findings
- **account-api:**
  - A session-sync error log always prints "undefined" for failures because it logs the wrong field on the underlying HTTP error object. **Confirmed** logging bug — it hides the real failure reason.
  - The token-exchange helper's early `return` skips success-path tracing tags only; errors are still routed through the shared error handler correctly. **Confirmed**, minor observability gap, not a correctness bug — the earlier collection-stage finding overstated this.
  - The new HTTP framework's default request-body size limit was never explicitly overridden, and requests without a `Content-Type` header now get rejected differently than before. **Possible** latent risk; not observed causing any failures in this window.
  - Platform-level runtime metrics were disabled during the migration due to a tooling incompatibility, reducing visibility into memory/event-loop health going forward.
- **media-auth-api (unrelated finding, worth its own ticket):** a parallel runtime migration on this service silently removed an endpoint with no tracking ticket; existing automated smoke tests still target it, so any live caller now gets a 404 with no warning.
- **identity-api:** a third-party auth integration always sends a malformed bearer token due to a wrong field name — pre-existing, silent, unrelated to this window. A six-day-old entitlement-tier migration needs cross-team confirmation that all consuming services received matching field-name updates.
- **account-web:** the shared HTTP client used for all identity-provider calls has no configured timeout — a fix is already in progress on an unmerged branch, just not landed yet. A caching-header change shipped today increases how long a stale sign-in page can be served from the CDN after a config change.
- **IDP tenant config:** the missing-attribute handling is defensive and intentional. A newly created credential is present but not yet referenced by anything, so it's latent, not active.

### Playwright Results
- `login`: **PASS**, 21.3s, against `https://account.example.com` with real test credentials. No 5xx, no TOTP, no browser-substitution fallback.

### Observability Findings
- **Observability platform:** IDP volume and 5xx flat. `identity-api` −15% errors, `media-auth-api` −34%, `account-api` +43.4% (raw counts; per-request ratio not computed).
- **Sentry:** nothing new. The dominant long-running signals are pre-existing and unrelated to today.
- **Session-replay source:** **unavailable** (not configured for this profile). Excluded from confidence.

### Unknowns and Limitations
- No session-replay source configured — no frontend session-level evidence.
- Error-tracking sample rate is low (1%) — "zero users impacted" readings are not reliable at that rate.
- Observability counts used here are raw, not normalized to request volume — error *rates* were not derived, only counts.
- The claimed traffic-peak explanation has not been checked against prior-day baselines.
- The repository findings were verified against the hosted source at the inspected commit, not against a confirmed deployed artifact.

### Recommended Permanent Corrective Actions
| # | Action | Priority | Validation |
|---|---|---|---|
| 1 | `account-api`: fix the session-sync error log to capture the actual HTTP error status/body/message | High (cheap, unblocks diagnosis of future bursts) | Next failure shows a real reason, not "undefined" |
| 2 | `media-auth-api`: ticket the silently deleted endpoint; confirm whether it has live callers, then restore or formally deprecate it | High (silent contract break) | Zero unexpected 404s, or a documented deprecation |
| 3 | `account-web`: merge the in-progress HTTP client timeout fix | Medium | A request against a hung upstream now fails instead of hanging |
| 4 | `account-api`: set an explicit request-body size limit and document the stricter content-type behavior for callers | Medium | No unexpected rejections after the change |
| 5 | `identity-api`: fix the malformed bearer token field name | Medium | The third-party integration receives a real token in staging |
| 6 | `account-api`: add an error-per-request monitor so traffic peaks stop reading as error spikes | Low | Monitor stays flat across the next evening peak |
| 7 | Confirm the entitlement-tier migration's cross-team rollout status | Low | Owner sign-off |
