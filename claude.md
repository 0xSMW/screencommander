@AGENTS.md

## Picking the right models for workflows and subagents

Rankings: higher = better. Cost is what I actually pay (OpenAI's rates, not list price).
- **Intelligence:** how difficult a problem you can hand the model unsupervised
- **Taste:** UI/UX, code quality, API design, copy

| model        | cost | intelligence | taste |
|--------------|------|--------------|-------|
| gpt-5.5      | 9    | 8            | 5     |
| sonnet-4.6   | 7    | 4            | 6     |
| sonnet-5     | 5    | 5            | 7     |
| opus-4.8     | 4    | 7            | 8     |
| fable-5      | 2    | 9            | 9     |

**How to apply:**

- These are defaults, not limits. You have standing permission to override: if a cheaper model's output doesn't meet the bar, escalate to a smarter model and rerun the work without asking. Judge results, not price. Escalation is cheaper than shipping weak work.
- Cost is a tiebreaker only. When model axes conflict for anything shipping, use: intelligence > taste > cost.
- For bulk/mechanical work (clear-spec implementation, data analysis, migrations), use gpt-5.5 (effectively free).
- Anything user-facing (UI, copy, API design) requires taste ≥ 7.
- For review of plans or implementations, use fable-5 or opus-4.8. Optionally also run gpt-5.5 as a second independent pass.
- Never use Haiku.

**Mechanics:**

- gpt-5.5 is only reachable through the Codex CLI (`codex exec`, `codex review`). (My `~/.codex/config.toml` defaults to gpt-5.5.)
  - Use `codex-implementation`, `codex-review`, and `codex-computer-use` skills; for tasks those don’t cover, use `codex exec -s read-only` with a self-contained prompt.
- Claude models (sonnet-5, opus-4.8, fable-5) are invoked via the Agent/Workflow model parameter.

**To use gpt-5.5 inside workflows/subagents (when only Claude models are allowed):**
- Spawn a thin Claude wrapper agent with `model: 'sonnet-4.6'`, `effort: 'low'`.
- The wrapper's prompt should:
  1. Write a self-contained Codex prompt based on input
  2. Run `codex exec` via Bash
  3. Capture and return the Codex output to the calling workflow

---
