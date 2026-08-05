<!--
  Synced from databricks-fieldkit on 2026-08-05
  Sources: ai/ucode.md
  Public docs grounding:
    - https://github.com/databricks/ucode
    - https://docs.databricks.com/aws/en/ai-gateway/model-provider-services
    - https://docs.databricks.com/aws/en/ai-gateway/query-model-provider-services
    - https://docs.databricks.com/aws/en/ai-gateway/coding-agent-integration-model-provider-services
    - https://docs.databricks.com/aws/en/ai-gateway/budgets

  Source-inspection grounding (claims not covered by the docs pages above):
    Read from the public databricks/ucode repo at commit ecb14e7 (2026-08-04).
    - Per-agent provider support and the credential-less subscription relay:
      ucode/databricks.py
    - Provider header injection into each agent's managed config:
      ucode/agents/claude.py, ucode/agents/codex.py
    - Loopback token-swap proxy: ucode/gateway_proxy.py
    Every ucode build reports v0.1.0, so verify capability by flag or by reading
    the pinned commit, never by version string.

  This file is auto-prepared and human-reviewed before publish.
-->

# ucode — Lightweight Coding-Agent Launcher
## Unified Auth · Per-Harness AI Gateway Routing

> **Audience**: Developers and platform teams standing up coding-agent access to Databricks
> **Cloud**: Agnostic

---

## TL;DR

ucode is Databricks' own lightweight CLI launcher for running coding agents — Codex, Claude Code, Gemini CLI, OpenCode, GitHub Copilot CLI, and Pi — through Databricks. It handles OAuth automatically and routes each agent's model calls through Unity AI Gateway using the developer's own workspace credentials. It does not include [Omnigent](omnigent-governance.md)'s session sharing, sandboxing, or policy engine — it's purely an auth-and-routing layer.

Teams that already pay for OpenAI, Anthropic, or a Claude subscription do not have to switch models to get governance: a Unity Catalog **model provider service** lets the gateway front an external provider with your own credential. What you gain and give up on that path is the subject of [Governance by inference path](#governance-by-inference-path) below — read it before promising a team "same governance, your models."

| You want... | Use ucode? |
|---|---|
| The simplest path from "installed coding agent" to "routed through Databricks" | Yes |
| OAuth handled for you, zero API keys to manage | Yes |
| Keep your existing provider account or Claude subscription, but centralize the credential and the audit trail | Yes — via a model provider service |
| A guaranteed dollar ceiling on coding-agent spend | No — budgets block only approximately, and do not see external-provider spend; use rate limits |
| Team collaboration, session sharing, a client-side cost-cap policy engine | No — see [Omnigent](omnigent-governance.md) |

---

## When to use / Anti-patterns

**Use when:**
- You want per-user identity and usage tracking on coding-agent LLM calls with minimal setup
- You don't need session sharing, sandboxing, or contextual policies

**Anti-patterns:**
- Do not expect ucode to govern **Cursor's inference**. `ucode cursor` exists but registers MCP servers only: `cursor-agent` runs models on the user's own Cursor account and exposes no gateway base URL. The result is governed tools alongside ungoverned model calls. To govern Cursor's inference, point its OpenAI-compatible base URL at the gateway manually with a token
- Do not present budgets as a spend cap for coding agents. See [Governance by inference path](#governance-by-inference-path)

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
ucode cursor       # Cursor Agent — registers MCP servers only, not inference
```

First launch prompts for the workspace URL and authenticates via browser SSO, writing each agent's config automatically. Subsequent launches go straight to the agent.

Useful per-launch flags: `--workspace <url>` targets one launch at a specific workspace (authenticating it if needed), which is what lets two agents sit on two different workspaces without reconfiguring in between; `--provider <catalog>.<schema>.<name>` routes through a model provider service; `--skip-preflight` skips the per-launch re-validation.

```bash
ucode configure        # configure multiple agents (interactive picker)
ucode configure mcp    # register Databricks MCP servers
ucode usage             # last 7 days of AI Gateway usage
ucode status            # current workspace, base URLs, managed config files, selected models
ucode revert            # clear saved state and restore backed-up config files
```

Non-interactive setup is also available via `configure` flags: `--agents`, `--workspaces`, `--profiles` (use existing Databricks CLI profiles), `--use-pat` (authenticate with a PAT instead of OAuth), `--skip-validate`, and `--dry-run`.

### Registering UC functions as agent skills

`ucode configure skills` exposes Unity Catalog functions as agent skills, so governed UC functions become callable tools inside a coding agent. Because the functions live in Unity Catalog, the same `EXECUTE` grants and audit trail govern who can invoke them.

```bash
# Interactive: pick from UC functions to expose as skills
ucode configure skills

# Register skills from a specific UC schema into a local directory
ucode configure skills --location main.default --path /local/dir

# Expose UC functions as skills through MCP (adds them to the MCP config)
ucode configure skills --location main.default --mcp
```

- `--location <catalog.schema>` selects the Unity Catalog schema whose functions become skills.
- `--path <dir>` writes the skill definitions to a local directory.
- `--mcp` registers the functions through MCP instead of writing local skill files, so they are surfaced to any MCP-capable tool.

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

## Bringing your own models

The common objection to routing coding agents through a platform is "we already pay for our own models." A Unity Catalog **model provider service** answers it. The service is a UC securable holding an external provider's connection details and encrypted credential; the gateway supplies the credential at request time, so the coding agent never handles the secret:

```bash
ucode codex  --provider main.default.openai_prod
ucode claude --provider main.default.anthropic_prod
```

Two properties matter for governance. Access is a **Unity Catalog grant** — `EXECUTE` on the service decides who may use which provider, so provider access joins the same permission model as tables and functions. And the credential **stops living on laptops**, which removes the rotation and offboarding problem that per-developer API keys create.

Provider support is per agent and narrow: reading the ucode source, Claude Code accepts `anthropic` and `amazon_bedrock` services, Codex CLI accepts `openai`, and Gemini CLI, OpenCode, Copilot, and Pi have no model-provider-service support at all.

> **Docs and source disagree on this one.** The Databricks page describes Claude Code as usable with "OpenAI, Anthropic, Amazon Bedrock, and other registered provider," and its example even shows `ucode claude --provider main.default.openai_prod`. The ucode source gates the pairing more narrowly than that. Treat the per-agent list as the binding constraint, test the specific pairing you intend to ship, and do not promise a combination on the strength of the doc example alone.

### Using a Claude subscription instead of a key

An Anthropic service can be registered **credential-less** to relay an existing Claude Max, Team, or Enterprise subscription. The developer's own subscription sign-in remains the credential the provider authenticates, while the Databricks credential travels in a separate header that a local loopback process refreshes per request. Practically: a team keeps the subscription it already pays for, and the platform still sees the traffic. This path is Claude Code only.

> **Grounding**: this behaviour is read from the ucode source (`databricks.py` for the relay flag, `gateway_proxy.py` for the loopback refresh), not from the AI Gateway doc pages listed above, which describe API-key registration only. Confirm against the [ucode repo](https://github.com/databricks/ucode) before relying on it; the mechanism is unusual and could change without a doc update.

### Governance by inference path

This is the part worth being precise about, because "route it through the gateway" does not mean "all controls apply." Governance degrades in two steps as you move away from platform-hosted models:

| Control | Databricks-hosted models | Your own key or subscription | Passthrough (forward all URL paths) |
|---|---|---|---|
| Usage tracking | Yes | Yes | No token or cost tracking |
| Payload logging (inference tables) | Yes | Yes | Yes |
| Rate limits | Yes | Yes | Token-based limits do not apply |
| Guardrails and service policies | Yes | Yes, on managed paths | Do not apply |
| Model access control | Yes | Yes (`EXECUTE` on the service) | Does not apply |
| Budgets and spend caps | Alert or block, approximately | **Not tracked at all** | Not tracked |

Three implications for anyone designing this:

1. **Budgets bound spend approximately; they do not guarantee a ceiling.** Both actions are available on Unity AI Gateway: alert, or block further requests. But enforcement runs on a near-real-time cost estimate, so spend can overshoot before blocking engages, and the docs say plainly not to rely on it for an absolute cap. Separately, external-provider spend is outside budgets entirely — "spend from model provider services is not tracked in budgets" — so that bill arrives from your provider. Where a firm ceiling on coding-agent consumption matters, **rate limits** are the control that enforces.
2. **Keep providers on managed paths.** Enabling "forward all URL paths" for unmapped provider endpoints is the single biggest governance downgrade available: usage and cost tracking, token-based rate limits, model access control, and service policies all stop applying to passthrough requests. Enable it only with a specific reason.
3. **The audit trail survives the switch.** Usage tracking, payload logging, rate limits, and policies all continue to work with your own credential. Bringing your own model costs you budget visibility, not observability.

---

## Gotchas

- **Model support varies per route** — e.g. Cursor's route doesn't support every model (open-source models like Qwen aren't supported there); check the AI Gateway UI for the per-route supported model list.
- **Claude Code's large context window can hit default FMAPI rate-limit tiers quickly** (e.g. 200k input tokens/min default tier for Claude Sonnet). Monitor via AI Gateway usage tables and request a tier increase if needed.
- **Codex requires a workspace that serves the OpenAI Responses API.** Codex speaks Responses, so a workspace whose endpoints only expose chat completions cannot host it, and the failure looks like "no models available" rather than a protocol error. Other agents use their own native dialects and are less constrained.
- **Verify rate limits and policies behaviourally, not by reading configuration.** Controls configured through the model service surface do not appear in the older serving-endpoints gateway configuration, and the two surfaces do not synchronize. Send traffic and confirm you see a `429` or a policy block; a configuration read will mislead you.
- **A polite refusal is not a policy block.** Guardrails on the current surface are model-evaluated classifiers rather than keyword matchers, so testing needs care: a `200` response saying "I can't share that" is the model declining, whereas an actual block is a `4xx` naming the policy and the phase. Built-in PII detection is the most deterministic to test against.
- **Coding-agent traffic can be attributed with request tags.** Where several tools share one endpoint, a request tag is the practical way to separate their usage in the gateway usage table, and tags are queryable as a map column.
- **Enterprise-managed agent settings can override ucode.** Claude Code honours a managed settings file at the highest precedence tier, above environment variables and command-line settings. If that file pins a base URL, an API-key helper, or custom headers, ucode cannot redirect the agent and provider routing headers are dropped. ucode warns when it detects those keys. Check the effective base URL rather than the reported model name, since the model can change while the endpoint stays pinned.
- **Environment variables outrank ucode's config files.** A shell exporting a provider base URL or model override makes the agent ignore what ucode wrote. Launch from a clean shell if routing looks wrong.

---

## Related

- [Omnigent Governance](omnigent-governance.md) — the fuller-featured alternative: same per-harness routing, plus session sharing, sandboxing, and a client-side policy engine
- [AI Gateway Patterns](ai-gateway-patterns.md) — the governance layer ucode routes through

## References

- [ucode on GitHub](https://github.com/databricks/ucode)
- [Govern external model providers (model provider services)](https://docs.databricks.com/aws/en/ai-gateway/model-provider-services)
- [Query model provider services](https://docs.databricks.com/aws/en/ai-gateway/query-model-provider-services)
- [Coding agent integration with model provider services](https://docs.databricks.com/aws/en/ai-gateway/coding-agent-integration-model-provider-services)
- [Manage budgets](https://docs.databricks.com/aws/en/ai-gateway/budgets)
