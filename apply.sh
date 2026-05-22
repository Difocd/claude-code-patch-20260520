#!/usr/bin/env bash
# Patch Claude Code 2.1.89 to fully support claude-opus-4-7.
#
# Two patches are applied to the installed cli.js:
#
#   22. TT() (getCanonicalName) — add an explicit "claude-opus-4-7" branch
#       before the "claude-opus-4-6" check so opus-4-7 is not stripped to
#       "claude-opus-4" by the fallback.
#
#   23. WT8() (modelSupportsAdaptiveThinking) — widen the allowlist to
#       include "opus-4-7" so the API receives thinking.type="adaptive"
#       instead of the legacy enabled+budget_tokens path (which 400s).
#
# Usage:  ./apply.sh

set -euo pipefail

# ---------- locate cli.js -------------------------------------------------

find_cli() {
  local p
  if command -v claude >/dev/null 2>&1; then
    p="$(command -v claude)"
    # follow symlink (claude is normally a symlink into node_modules)
    if [ -L "$p" ]; then
      p="$(cd "$(dirname "$p")" && cd "$(dirname "$(readlink "$p")")" && pwd)/$(basename "$(readlink "$p")")"
    fi
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  if command -v npm >/dev/null 2>&1; then
    p="$(npm root -g 2>/dev/null)/@anthropic-ai/claude-code/cli.js"
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  return 1
}

CLI="${1:-$(find_cli || true)}"
if [ -z "${CLI:-}" ] || [ ! -f "$CLI" ]; then
  echo "error: could not locate cli.js. Pass it explicitly: $0 /path/to/cli.js" >&2
  exit 1
fi
echo "target: $CLI"

# ---------- apply_patch helper -------------------------------------------

# apply_patch <label> <old> <new>
#
# Idempotent: if <new> is already present (and <old> is not), the patch is
# considered applied and skipped. Errors out if neither pattern is found,
# or if <old> appears more than once.
apply_patch() {
  local label="$1" old="$2" new="$3"
  python3 - "$CLI" "$label" "$old" "$new" <<'PY'
import sys, io
path, label, old, new = sys.argv[1:5]
with io.open(path, 'r', encoding='utf-8') as f:
    s = f.read()

# Idempotency: if `new` is already in the file, treat as applied. We check
# `new` first because in these patches `old` is a substring of `new`, so
# `count(old)` stays >= 1 even after a successful application.
n_new = s.count(new)
if n_new >= 1:
    print(f"[skip] {label}: already applied")
    sys.exit(0)

n_old = s.count(old)
if n_old == 0:
    print(f"[fail] {label}: original pattern not found (wrong cli.js version?)")
    sys.exit(2)
if n_old > 1:
    print(f"[fail] {label}: original pattern found {n_old} times (expected 1)")
    sys.exit(3)

s2 = s.replace(old, new, 1)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(s2)
print(f"[ok]   {label}: applied")
PY
}

# ---------- patches -------------------------------------------------------

# 22. Canonicalize claude-opus-4-7 in TT() (aka getCanonicalName)
#     The canonicalizer's check order is: 4-6, 4-5, 4-1, then the fallback
#     "claude-opus-4" branch. "claude-opus-4-7" matches the fallback and is
#     canonicalized to "claude-opus-4", stripping the "-7" suffix before
#     WT8 / other capability checks see it. Add a dedicated branch before
#     the fallback so opus-4-7 stays distinct.
apply_patch "Canonicalize claude-opus-4-7 (TT)" \
  'q.includes("claude-opus-4-6"))return"claude-opus-4-6"' \
  'q.includes("claude-opus-4-7"))return"claude-opus-4-7";if(q.includes("claude-opus-4-6"))return"claude-opus-4-6"'

# 23. Enable adaptive thinking for opus-4-7 in WT8()
#     modelSupportsAdaptiveThinking() hardcodes an allowlist of 4-6 models.
#     For opus-4-7, once canonicalized (see patch #22), the function falls
#     through to the legacy-exclusion branch (contains "opus") and returns
#     false, so claude.ts picks the non-adaptive path with
#     thinking.type="enabled" and budget_tokens=31999 (maxOutput-1).
#     opus-4-7 only accepts thinking.type="adaptive", so the API 400s.
#     Fix: widen the allowlist to also include opus-4-7.
apply_patch "Enable adaptive thinking for opus-4-7 (WT8)" \
  '_.includes("opus-4-6")||_.includes("sonnet-4-6")' \
  '_.includes("opus-4-6")||_.includes("sonnet-4-6")||_.includes("opus-4-7")'

# 24. Remove git commit Co-Authored-By + "Generated with" attribution (KR6).
#     In 2.1.89, KR6() builds z=`...Generated with [Claude Code]...` and
#     Y=`Co-Authored-By: ...`. We blank both. The replacement string is
#     anchored on the preceding "Claude Opus 4.6", string literal so the
#     idempotency check (which looks for `new` already in the file) is not
#     defeated by `z="",Y=""` appearing elsewhere in the minified bundle.
apply_patch "Remove commit attribution (KR6)" \
  '"Claude Opus 4.6",z=`\uD83E\uDD16 Generated with [Claude Code](${Iw6})`,Y=`Co-Authored-By: ${_} <noreply@anthropic.com>`' \
  '"Claude Opus 4.6",z="",Y=""'

# 25. Remove default PR attribution (aPK, default path).
#     Anchored on the preceding `if(K.includeCoAuthoredBy===!1)return"";`
#     guard so the resulting `let _=""` is unique in the file.
apply_patch "Remove default PR attribution (aPK)" \
  'if(K.includeCoAuthoredBy===!1)return"";let _=`\uD83E\uDD16 Generated with [Claude Code](${Iw6})`' \
  'if(K.includeCoAuthoredBy===!1)return"";let _=""'

# 26. Remove enhanced PR attribution (aPK, summary path).
#     Anchored on the preceding `recalled` ternary so the resulting
#     `,M=""` is unique in the file.
apply_patch "Remove enhanced PR attribution (aPK)" \
  'let J=O>0?`, ${O} ${O===1?"memory":"memories"} recalled`:"",M=`\uD83E\uDD16 Generated with [Claude Code](${Iw6}) (${w}% ${$}-shotted by ${H}${J})`' \
  'let J=O>0?`, ${O} ${O===1?"memory":"memories"} recalled`:"",M=""'

# 27. Disable the "consider whether it would be considered malware" reminder
#     appended to every Read tool result.
#
#     In 2.1.89, the reminder is stored in constant `hzY` and conditionally
#     appended at the Read tool-result site as:
#         _ = CzY(q) + LzY(q.file) + (SzY() ? hzY : "")
#     The gate `SzY()` returns `!RzY.has(currentModel)` — so the reminder
#     is on by default for every model not in the RzY denylist.
#
#     We force SzY() to return false so the ternary always picks "" and
#     the reminder is never injected. This is the smallest possible change
#     (no string blanking, no call-site rewrite) and leaves all related
#     identifiers/functions intact in case they're referenced elsewhere.
apply_patch "Disable malware-reminder on Read (SzY)" \
  'function SzY(){let q=gY(W5());return!RzY.has(q)}' \
  'function SzY(){return!1}'

echo "done."
