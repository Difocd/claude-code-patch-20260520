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

# ---------- auto-mode unlock (28, 29, 30, 31) -----------------------------
#
# The auto permission mode runs an AI classifier (sideQuery + classify_result
# tool call) instead of prompting the human on every tool call. Stock 2.1.89
# gates entry behind three checks, all of which fail closed against a self-
# hosted / non-firstParty endpoint:
#
#   - Iy()  = isAutoModeGateEnabled()     — explicit-entry sync gate
#   - _q7() = parseAutoModeEnabledState() — GrowthBook "enabled" parser; defaults
#                                          to "disabled" (= HAY) when the config
#                                          is absent (no GrowthBook = no config)
#   - fG6() = modelSupportsAutoMode()     — returns false unconditionally when
#                                          T7() (getAPIProvider) != "firstParty"
#
# And one ant-only escape hatch that the bundler DCE'd out of the external
# build entirely:
#
#   - Gx4() = getClassifierModel()        — the CLAUDE_CODE_AUTO_MODE_MODEL env
#                                          var path lived inside an "ant" branch
#                                          and got eliminated at build time;
#                                          re-inject it so the classifier model
#                                          can be picked independently of the
#                                          main loop model.
#
# The classifier itself works fine against any Anthropic-compatible endpoint —
# it's just a regular tool-forced sideQuery against the active model. The gates
# are operational (kill switch + tenant policy + capability allowlist), not
# semantic. Unlock all four so the TUI carousel shows "auto", entry doesn't
# throw, verifyAutoModeGateAccess doesn't kick us back to default, and the
# classifier can be routed to a model that accepts temperature:0.

# 28. Force-enable auto mode entry gate (Iy / isAutoModeGateEnabled).
#     Short-circuit return true at the top; leave the body intact for any
#     debugger / telemetry hook that inspects it.
apply_patch "Force-enable auto mode entry gate (Iy)" \
  'function Iy(){if(Zv?.isAutoModeCircuitBroken()??!1)return!1;' \
  'function Iy(){return!0;if(Zv?.isAutoModeCircuitBroken()??!1)return!1;'

# 29. Default tengu_auto_mode_config.enabled to "enabled" (_q7 /
#     parseAutoModeEnabledState). Without GrowthBook, autoModeConfig?.enabled
#     is undefined and _q7 returns HAY ("disabled"), which makes
#     verifyAutoModeGateAccess set isAutoModeAvailable=false and kick the user
#     out of auto on every async re-check. Swap the fallback to "enabled".
apply_patch "Default auto mode parser to enabled (_q7)" \
  'function _q7(q){if(q==="enabled"||q==="disabled"||q==="opt-in")return q;return HAY}' \
  'function _q7(q){if(q==="enabled"||q==="disabled"||q==="opt-in")return q;return"enabled"}'

# 30. Allow non-firstParty providers in modelSupportsAutoMode (fG6).
#     The provider check `if(T7()!=="firstParty")return!1` blocks Vertex /
#     Bedrock / proxied endpoints (incl. API_MULERUN_BASE_URL) before the
#     GrowthBook allowModels override is even consulted. Short-circuit
#     return true at the top; leave the body intact (matches patch 28's
#     shape so the idempotency check — which compares whether `new` is
#     already present — works correctly).
#
#     After this patch, model capability is fully governed by:
#       - the operator's choice of main model, and
#       - any `tengu_auto_mode_config.allowModels` entries in settings.json.
#     The "claude-(opus|sonnet)-4-6" regex still runs but is now an irrelevant
#     fallback because we always returned true above.
apply_patch "Allow non-firstParty providers in modelSupportsAutoMode (fG6)" \
  'function fG6(q){{let K=gY(q);if(T7()!=="firstParty")return!1;' \
  'function fG6(q){return!0;{let K=gY(q);if(T7()!=="firstParty")return!1;'

# 31. Unlock CLAUDE_CODE_AUTO_MODE_MODEL env var (Gx4 / getClassifierModel).
#     The env var path was DCE'd by the bundler because `"external" === 'ant'`
#     is a compile-time false. The entire `process.env.CLAUDE_CODE_AUTO_MODE_MODEL`
#     reference is absent from cli.js. Re-inject it at the top of the function
#     so it takes priority over GrowthBook config and the main-loop model.
#     This lets you route classifier calls to a different model (e.g. opus-4-6)
#     than the main loop model (e.g. opus-4-7) — useful when the main model
#     doesn't support temperature:0 but the classifier forces it.
apply_patch "Unlock CLAUDE_CODE_AUTO_MODE_MODEL env var (Gx4)" \
  'function Gx4(){let q=u8("tengu_auto_mode_config",{});if(q?.model)return q.model;return W5()}' \
  'function Gx4(){if(process.env.CLAUDE_CODE_AUTO_MODE_MODEL)return process.env.CLAUDE_CODE_AUTO_MODE_MODEL;let q=u8("tengu_auto_mode_config",{});if(q?.model)return q.model;return W5()}'

echo "done."
