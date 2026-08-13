# claude-code-patch-20260520

Patches Claude Code **2.1.89** to fully support `claude-opus-4-7`,
`claude-opus-4-8`, and `claude-opus-5`.

## What it does

Surgical edits to the installed `cli.js`:

### Patch 22 / 33 — `TT()` (a.k.a. `getCanonicalName`)

The canonicalizer checks model substrings in this order:

```
4-6  ->  claude-opus-4-6
4-5  ->  claude-opus-4-5
4-1  ->  claude-opus-4-1
opus-4 (fallback) -> claude-opus-4   <-- strips "-7"/"-8" suffix
```

Any new `claude-opus-4-N` (N > 6) falls into the fallback and gets
canonicalized to `claude-opus-4`, which hides the suffix from every
downstream capability check.

Fix: add dedicated branches for `claude-opus-4-7`, `claude-opus-4-8`, and
`claude-opus-5` **before** the `4-6` check so each stays distinct.

### Patch 23 / 34 — `WT8()` (a.k.a. `modelSupportsAdaptiveThinking`)

`modelSupportsAdaptiveThinking` hardcodes an allowlist of `4-6` models.
Once the canonicalizer keeps the new opus models distinct, this function
still falls through to the legacy `contains("opus")` exclusion branch and
returns `false`. That makes `claude.ts` send the non-adaptive payload:

```jsonc
{ "thinking": { "type": "enabled", "budget_tokens": 31999 } }
```

But `opus-4-7` / `opus-4-8` / `opus-5` only accept
`thinking.type = "adaptive"`, so the API returns 400.

Fix: widen the allowlist to also include `opus-4-7`, `opus-4-8`, and
`opus-5`.

### Patch 35 — `P16()` (max-output defaults)

`P16(model)` returns the default and upper-limit `max_tokens` for each
model. Stock 2.1.89 only gives `opus-4-6` the 64K / 128K bucket; every
other opus falls through to the 32K default. Modern opus models (4.7,
4.8, 5) also support 128K output, so long responses get truncated
mid-thought at 32K.

Fix: widen the `opus-4-6` branch to also match `opus-4-7`, `opus-4-8`,
and `opus-5` so they all get the 64K default / 128K upper-limit bucket.

### Patch 36 — `B18()` (a.k.a. `countTokensWithFallback`)

`/context` computed every row of its token table over the network. `B18`
is the chokepoint all the category counters funnel through — system
prompt sections (one call each), memory files (one call each), builtin
tools (bulk + one per deferred tool), MCP tools, custom agents (one
each), the `Skill` tool (counted **twice**, second result discarded),
and the whole message history.

Nothing was cached: `withTokenCountVCR` is a pass-through unless
`NODE_ENV=test`, so every `/context` re-counted from scratch.

Worse, `B18` had a two-stage escalation:

1. `La6()` → `POST /v1/messages/count_tokens`, sending a dummy
   `content:"foo"` message when only tools are being counted (the API
   rejects an empty `messages` array).
2. on failure, `XfK()` → a **real, billed** `POST /v1/messages` with
   `content:"count"` and `max_tokens:1`, purely to read back
   `usage.input_tokens`. The response content is `null` by design.

On endpoints without `count_tokens`, stage 1 404s and *every* counter
escalates to stage 2 — doubling the request count. Stage 2 is also just
wrong: it counts against `getSmallFastModel()`, not the main loop model,
so it reports a different model's tokenization.

Fix: count locally via `T3()` (`roughTokenCountEstimation`). Strings use
the default chars/4; tool schemas are dense JSON so they use chars/2
(same rationale as the stock `bytesPerTokenForFileType()` `json:2`
case). When tools are present, the 500-token tool-prompt preamble is
added back, since callers subtract `TOOL_TOKEN_COUNT_OVERHEAD` (500) —
and a non-zero return also avoids the "API unavailable" sentinel that
callers test for.

Result: `/context` makes **zero** API calls (`duration_api_ms: 0`) and
returns instantly. `XfK` is left with no callers. The two remaining
`La6` callers (`FileReadTool`, `mcpValidation`) are untouched — they
pass real content, never the `"foo"` dummy.

**Accuracy:** the headline total is unaffected. `analyzeContextUsage`
already prefers real usage from the last API response via
`getCurrentUsage()` (`input_tokens + cache_creation + cache_read`), and
only sums the estimates when no assistant turn has happened yet (e.g.
a fresh session, or `claude -p "/context"`). So the total stays exact
after the first reply; only per-category attribution becomes
approximate (~±20-30%) — which the stock code already did anyway for
its per-tool breakdowns.

## Usage

```sh
./apply.sh                 # auto-detects cli.js via `which claude` / `npm root -g`
./apply.sh /path/to/cli.js # or pass it explicitly
```

The script is **idempotent** — running it twice on an already-patched
`cli.js` reports `[skip] already applied` for each patch and leaves the
file untouched.

## Requirements

- `bash`, `python3` (any 3.x)
- Claude Code **2.1.89** installed globally (other versions will fail the
  exact-string match and the script will abort before writing).

## Verifying

```sh
claude --version           # -> 2.1.89 (Claude Code)
./apply.sh                 # -> [ok] / [skip] for every patch
```
