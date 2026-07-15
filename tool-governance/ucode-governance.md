<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: ai/ucode.md
  Public docs grounding:
    - https://github.com/databricks/ucode
  This file is auto-prepared and human-reviewed before publish.
-->

# ucode — Lightweight Coding-Agent Launcher
## Unified Auth · Per-Harness AI Gateway Routing

> **Audience**: Developers and platform teams standing up coding-agent access to Databricks
> **Cloud**: Agnostic

---

## TL;DR

ucode is Databricks' own lightweight CLI launcher for running coding agents — Codex, Claude Code, Gemini CLI, OpenCode, GitHub Copilot CLI, and Pi — through Databricks. It handles OAuth automatically, requires no API keys, and routes each agent's model calls through Unity AI Gateway using the developer's own workspace credentials. It does not include [Omnigent](omnigent-governance.md)'s session sharing, sandboxing, or policy engine — it's purely an auth-and-routing layer.

| You want... | Use ucode? |
|---|---|
| The simplest path from "installed coding agent" to "routed through Databricks" | Yes |
| OAuth handled for you, zero API keys to manage | Yes |
| Team collaboration, session sharing, a client-side cost-cap policy engine | No — see [Omnigent](omnigent-governance.md) |

---

## When to use / Anti-patterns

**Use when:**
- You want per-user identity and usage tracking on coding-agent LLM calls with minimal setup
- You don't need session sharing, sandboxing, or contextual policies

**Anti-patterns:**
- Cursor's OAuth flow isn't available through ucode — Cursor routes through its own servers, so use a PAT or Service Principal token for it instead

---

## How it works

### Install and launch

```bash
uv tool install git+https://github.com/databricks/ucode

ucode claude       # Claude Code
ucode codex        # OpenAI Codex CLI
ucode gemini       # Gemini CLI
ucode opencode     # OpenCode
ucode copilot      # GitHub Copilot CLI
ucode pi           # Pi
```

First launch prompts for the workspace URL and authenticates via browser SSO, writing each agent's config automatically. Subsequent launches go straight to the agent.

```bash
ucode configure        # configure multiple agents
ucode configure mcp    # register Databricks MCP servers
ucode usage             # last 7 days of AI Gateway usage
```

### Per-harness model routing

Each tool routes to its own dedicated Unity AI Gateway surface, matching that tool's native wire format — the same routing pattern [Omnigent](omnigent-governance.md) uses for the same tools:

| Tool | Base URL | Wire format |
|---|---|---|
| Claude Code | `{workspace}/ai-gateway/anthropic` | Anthropic Messages API |
| Codex CLI | `{workspace}/ai-gateway/codex/v1` | OpenAI Responses API |
| Gemini CLI | `{workspace}/ai-gateway/gemini` | Gemini API |

### Authentication

**Preferred: OAuth**, automatic — browser SSO on first launch. Per-user identity, usage tracking, and rate limiting key off this identity, with no shared secret to manage.

**Manual fallback: Databricks PAT**, for tools configured by hand instead of launched through ucode:

| Tool | Manual PAT wiring |
|---|---|
| Cursor | PAT set as the OpenAI API key in Cursor settings |
| Codex CLI | PAT retrieved via `databricks auth token` in `~/.codex/config.toml` |
| Gemini CLI | PAT set as a bearer token in `~/.gemini/.env` |
| Claude Code | PAT configured through "Other Integrations" in the AI Gateway UI |

### External developer access

Non-Databricks developers need to be provisioned as workspace users first — via [AIM/JIT provisioning](https://learn.microsoft.com/en-us/azure/databricks/admin/users-groups/automatic-identity-management) (preferred) or SCIM — then generate a PAT or use OAuth. Once provisioned, per-user identity, usage tracking, and rate limiting all work correctly.

---

## Gotchas

- **Model support varies per route** — e.g. Cursor's route doesn't support every model (open-source models like Qwen aren't supported there); check the AI Gateway UI for the per-route supported model list.
- **Claude Code's large context window can hit default FMAPI rate-limit tiers quickly** (e.g. 200k input tokens/min default tier for Claude Sonnet). Monitor via AI Gateway usage tables and request a tier increase if needed.

---

## Related

- [Omnigent Governance](omnigent-governance.md) — the fuller-featured alternative: same per-harness routing, plus session sharing, sandboxing, and a client-side policy engine
- [AI Gateway Patterns](ai-gateway-patterns.md) — the governance layer ucode routes through

## References

- [ucode on GitHub](https://github.com/databricks/ucode)
