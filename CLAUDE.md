# claude-code-patch-20260520

Patches Claude Code **2.1.89** to fully support `claude-opus-4-7`.

## What it does

Two surgical edits to the installed `cli.js`:

### Patch 22 — `TT()` (a.k.a. `getCanonicalName`)

The canonicalizer checks model substrings in this order:

```
4-6  ->  claude-opus-4-6
4-5  ->  claude-opus-4-5
4-1  ->  claude-opus-4-1
opus-4 (fallback) -> claude-opus-4   <-- strips "-7" from "claude-opus-4-7"
```

`claude-opus-4-7` falls into the fallback and gets canonicalized to
`claude-opus-4`, which hides the `-7` suffix from every downstream
capability check.

Fix: add a dedicated `claude-opus-4-7` branch **before** the `4-6` check
so opus-4-7 stays distinct.

### Patch 23 — `WT8()` (a.k.a. `modelSupportsAdaptiveThinking`)

`modelSupportsAdaptiveThinking` hardcodes an allowlist of `4-6` models.
Once patch 22 keeps `opus-4-7` distinct, this function still falls through
to the legacy `contains("opus")` exclusion branch and returns `false`.
That makes `claude.ts` send the non-adaptive payload:

```jsonc
{ "thinking": { "type": "enabled", "budget_tokens": 31999 } }
```

But `opus-4-7` only accepts `thinking.type = "adaptive"`, so the API
returns 400.

Fix: widen the allowlist to also include `opus-4-7`.

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
./apply.sh                 # -> [ok] / [skip] for both patches
```
