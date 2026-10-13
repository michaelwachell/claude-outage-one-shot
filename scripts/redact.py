#!/usr/bin/env python3
"""outage-one-shot redaction sweep.

Deterministic secret/PII scrubbing for text passed through it — evidence
blobs, agent outputs, Playwright console/network dumps, before they are
written to a report or printed to the terminal. Pattern-based, not
judgment-based, on purpose: this is the last line of defense before
output leaves the skill, so it must not depend on model behavior.

Usage:
    redact.py < input.txt > redacted.txt
    python3 redact.py --check "some string"   # prints True/False, no output
"""

import re
import sys

PATTERNS = [
    # key=value / "key": "value" pairs for known-sensitive field names — run first, so a token
    # sitting in a recognized field is redacted wholesale before the generic shape patterns below
    # get a chance to partially match its value and leave stray bracket characters behind.
    (
        re.compile(
            r'(?i)("?\b(?:password|passwd|secret|totp|otp|token|access_token|'
            r'refresh_token|id_token|client_secret|api_key|apikey)\b"?\s*[:=]\s*)'
            r'("(?:[^"\\]|\\.)*"|[^\s,}\]]+)'
        ),
        r"\1[REDACTED]",
    ),
    # Bearer / auth headers
    (re.compile(r"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9\-_.~+/]+=*"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(authorization:\s*basic\s+)[A-Za-z0-9+/=]+"), r"\1[REDACTED]"),
    # Common token/key shapes (catches these values even outside a recognized key=value pair)
    (re.compile(r"\beyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\b"), "[REDACTED_JWT]"),
    (re.compile(r"(?i)\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{10,}\b"), "[REDACTED_KEY]"),
    (re.compile(r"(?i)\bAKIA[0-9A-Z]{16}\b"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"(?i)ghp_[A-Za-z0-9]{20,}"), "[REDACTED_GH_TOKEN]"),
    # Cookie / session values
    (re.compile(r"(?i)(set-cookie:\s*[^=;]+=)[^;]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(cookie:\s*)[^\r\n]+"), r"\1[REDACTED]"),
]

PII_PATTERNS = [
    # Email addresses — kept but masked to domain only, since domain can be diagnostically useful
    (re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b"), r"[REDACTED_EMAIL]@\1"),
]


def redact(text: str, include_pii: bool = True) -> str:
    for pattern, repl in PATTERNS:
        text = pattern.sub(repl, text)
    if include_pii:
        for pattern, repl in PII_PATTERNS:
            text = pattern.sub(repl, text)
    return text


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        target = sys.argv[2] if len(sys.argv) > 2 else ""
        changed = redact(target) != target
        print(changed)
        return 0

    data = sys.stdin.read()
    sys.stdout.write(redact(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
