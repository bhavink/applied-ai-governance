<!--
  Synced from databricks-fieldkit on 2026-09-14
  Sources: ai/ucode.md
  Public docs grounding:
    - https://github.com/databricks/ucode
    - https://docs.databricks.com/aws/en/ai-gateway/model-provider-services
    - https://docs.databricks.com/aws/en/ai-gateway/query-model-provider-services
    - https://docs.databricks.com/aws/en/ai-gateway/coding-agent-integration-model-provider-services
  This file is auto-prepared and human-reviewed before publish.
-->

<!-- additional source: hands-on source inspection of the installed package (ucode/databricks.py) | last_checked: 2026-08-05 -->

# ucode

## TL;DR

ucode is Databricks' own, lightweight CLI launcher for running coding
agents through Databricks — "a lightweight launcher for running Codex,
Claude Code, Gemini CLI, OpenCode, GitHub Copilot CLI, and Pi through
Databricks." It handles OAuth automatically (or falls back to a PAT), so
by default there are no separate API keys to manage. It does not have
Omnigent's session sharing, sandboxing, or policy engine — it's purely an
auth + routing layer.

Inference does **not** have to be a Databricks-hosted foundation model. Via a
Unity Catalog **Model Provider Service** you can bring your own OpenAI /
Anthropic / Bedrock key, or relay an existing Claude Max/Team/Enterprise
subscription — but the governance you get back differs by path. See
[Bring your own model](#bring-your-own-model-external-providers-and-subscriptions).

> **Version strings are useless for this page.** Every build to date reports
> `ucode v0.1.0`, so `--version` cannot tell you what features you have.
> This page is pinned to commit **`ecb14e7`** (2026-08-04). Check capability
> by flag (`ucode codex --help`) and upgrade with
> `uv tool install --reinstall git+https://github.com/databricks/ucode`.

| You want... | Use ucode? |
|---|---|
| Quick, no-frills way to point an existing coding agent at Databricks | Yes |
| Team collaboration, session sharing, persistent multi-turn history across devices | No — use [Omnigent](omnigent.md) |
| A client-side cost cap / contextual policy engine | No — use Omnigent |
| Just want per-user identity + usage tracking on coding-agent LLM calls with zero setup friction | Yes |
| Keep using your own OpenAI/Anthropic key or Claude subscription, but govern it centrally | Yes — via a Model Provider Service, with caveats |
| A hard dollar spend cap on coding-agent traffic | No — budgets alert only, and don't see BYO spend at all; use rate limits |

---

## When to use / Anti-patterns

**Use when:**
- You want the simplest possible path from "installed coding agent" to "routed through Databricks," with OAuth handled for you
- You don't need session sharing, sandboxing, or Omnigent's policy engine
- You want per-user identity and usage tracking without provisioning API keys per developer

**Anti-patterns:**
- Do not expect session sharing, team collaboration, or contextual policies — those are Omnigent features, not ucode's
- Do not expect ucode to govern **Cursor's inference**. `ucode cursor` exists but is **MCP-only**: `cursor-agent` runs models on the user's own Cursor account and exposes no gateway base URL, so ucode registers Databricks MCP servers for it and configures no models. You get governed tools with ungoverned inference. To govern Cursor's model calls, wire its OpenAI-compatible base URL to the gateway by hand with a PAT (see [ai-gateway.md](ai-gateway.md#cursor))
- Do not rely on **budgets** as a hard cap on coding-agent spend. "Block usage" is available on Unity AI Gateway (not Genie-only — corrected 2026-08-05), but it enforces on a near-real-time cost estimate and can overshoot the threshold, and Model Provider Service spend is invisible to budgets entirely. Rate limits are the enforceable control

---

## Prerequisites

- Python 3.12+ and `uv`
- A Databricks workspace with Unity AI Gateway available

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
ucode cursor       # Cursor Agent — MCP servers only, NOT inference
```

First launch prompts for the workspace URL and authenticates via browser
SSO; it writes each agent's config file automatically. Subsequent
launches go straight to the agent.

**Per-launch flags on the launch commands** (`codex`, `claude`, and peers):

| Flag | Effect |
|---|---|
| `--workspace <url>` | Target this launch at a specific workspace, setting it up and authenticating if needed. Overrides the single `current_workspace` default, so two agents can sit on two workspaces without reconfiguring between sessions |
| `--provider <catalog>.<schema>.<name>` | Route through a Unity Catalog Model Provider Service (BYO key / subscription). Skips Databricks model pinning. Pass before any `--` separator |
| `--skip-preflight` | Skip the per-launch auth + gateway re-validation, trusting a prior `ucode configure`. The cheap way to speed up repeat launches |
| `--enable-smart-routing` / `--disable-smart-routing` | Gateway model routing for sessions **and subagents** (codex and claude; needs Codex >= 0.145.0) |

Agent-specific pass-through flags still work, and extra args are forwarded to
the agent binary — `ucode codex -c key=value` reaches `codex` itself.

```bash
ucode configure          # configure multiple agents (interactive picker)
ucode configure mcp      # register Databricks MCP servers on installed MCP-capable tools
ucode configure skills   # expose UC functions as agent skills
ucode configure tracing  # send coding-session traces to an MLflow experiment (Claude Code only)
ucode usage              # last 7 days of AI Gateway usage
ucode status             # current workspace, base URLs, managed config files, selected models
ucode upgrade            # upgrade ucode itself from GitHub
ucode revert             # clear saved state and restore backed-up config files
ucode mcp web-search     # stdio web-search MCP server (invoked as a subprocess by Claude Code)
```

Non-interactive `configure` flags: `--agents <list>`, `--workspaces <urls>`, `--profiles <names>` (use existing Databricks CLI profiles), `--use-pat` (authenticate with the profile's PAT instead of OAuth; requires `--profiles`, intended for CI/headless), `--skip-validate` (skip the test-message send per agent), `--dry-run` (preview without writing), `--skip-upgrade` (don't prompt to upgrade agent CLIs), `--verbose low` (terse output).

Also on `configure`:

- `--mcp <fq-names>` registers Databricks MCP services in the same command, e.g. `--agents claude --mcp system.ai.slack`. Use it without `--agents` for MCP-only clients such as Cursor.
- `--tracing` enables MLflow tracing for the configured workspace(s).
- `--enable-fable` / `--disable-fable` opts into the premium Claude Fable family for Claude Code (off by default; only takes effect if the workspace's gateway advertises a Fable model).
- `--enable-databricks-ai-tools` / `--disable-...` installs Databricks AI Tools (skills + plugins that teach agents to use Databricks). **Installed by default** — pass the disable flag to opt out.

Agent-specific pass-through flags work as normal, e.g. `ucode claude -r` resumes the last Claude Code session.

### Per-tool routing (confirmed from source)

`ucode/databricks.py` builds a distinct base URL per tool — its own code
comment labels this **"AI Gateway v2 only — no fallback to
/serving-endpoints"**:

```python
def build_tool_base_url(tool: str, workspace: str) -> str:
    if tool == "codex":
        return f"{workspace}/ai-gateway/codex/v1"
    if tool == "claude":
        return f"{workspace}/ai-gateway/anthropic"
    if tool == "gemini":
        return f"{workspace}/ai-gateway/gemini"
    ...
```

These are the identical URLs Omnigent's Databricks credential provider
uses for the same tools — see
[omnigent.md's per-harness routing table](omnigent.md#per-harness-model-routing-databricks-credential).
Pi and OpenCode and Copilot each speak multiple provider dialects to
their own dedicated per-family paths (each provider's native wire format
— Anthropic Messages, OpenAI Responses, Gemini generateContent, or OpenAI
chat completions — appended to a per-family base URL).

### Authentication

**Preferred: OAuth**, handled automatically — browser SSO on first
launch, no keys or PATs to manage. Per-user identity, usage tracking, and
rate limiting all key off this identity.

**Manual fallback: Databricks PAT**, for tools not launched through ucode
(e.g. Cursor configured by hand) or manual per-tool setup:

| Tool | Manual PAT wiring |
|---|---|
| Cursor | PAT set as the OpenAI API key in Cursor settings |
| Codex CLI | PAT retrieved via `databricks auth token` in `~/.codex/config.toml` |
| Gemini CLI | PAT set as a bearer token in `~/.gemini/.env` |
| Claude Code | PAT configured through "Other Integrations" in the AI Gateway UI |

---

## Bring your own model: external providers and subscriptions

You are **not** limited to Databricks-hosted foundation models. A Unity Catalog
**Model Provider Service** (MPS) is a UC securable holding a provider's connection
details and encrypted credentials; the gateway injects the credential at request
time, so the coding agent never sees the secret. Route a launch at one with:

```bash
ucode codex  --provider main.default.openai_prod
ucode claude --provider main.default.anthropic_prod
```

On the wire this is a single header, `Databricks-Model-Provider-Service:
<catalog>.<schema>.<name>`, which ucode writes into the agent's managed provider
block (`agents/codex.py:128`, `agents/claude.py:267`). Access is gated by the
`EXECUTE` privilege on the service, so who may use which provider is a UC grant.

### Which agent can use which provider

Hard-coded at `databricks.py:1473` — this is the whole list:

| Agent | Provider types it can route to |
|---|---|
| `claude` | `anthropic`, `amazon_bedrock` |
| `codex` | `openai` |

Gemini, OpenCode, Copilot, and Pi have **no** MPS support. A Bedrock-backed service
is only offered to `claude` if its targets include at least one Claude model, since
Bedrock exposes non-canonical ids (e.g. `us.anthropic.claude-sonnet-4-6`) that ucode
must pin explicitly via `ANTHROPIC_DEFAULT_*_MODEL`.

### Claude subscription relay (Max / Team / Enterprise)

A **credential-less** Anthropic MPS relays your existing Claude subscription instead
of an API key. The mechanics are unusual and worth knowing:

- Claude Code keeps its **own subscription OAuth** in the `Authorization` header.
- The Databricks credential rides separately in `X-Databricks-AI-Gateway-Token`.
- Because that token is short-lived and a static settings file can't refresh it,
  ucode runs a **loopback proxy on 127.0.0.1** and points `ANTHROPIC_BASE_URL` at
  it, minting a fresh swap header per request (`gateway_proxy.py`). The proxy binds
  loopback only and never logs header values or bodies.
- Detected from `config.anthropic.relayed` on the service (`databricks.py:1533`).
- **Claude Code only** — there is no Codex or Gemini equivalent.

### Governance by path — the important part

Routing BYO traffic through the gateway buys you most, but **not all**, of the
governance you get on Databricks-hosted models:

| Control | Databricks-hosted FM | BYO key via MPS | Claude subscription relay |
|---|---|---|---|
| Usage tracking (`system.ai_gateway.usage`) | Yes | Yes | Yes |
| Inference tables (payload logging) | Yes | Yes | Yes |
| Rate limits | Yes | Yes (service level) | Yes |
| Guardrails / service policies | Yes | Yes (managed paths only) | Yes (managed paths only) |
| UC access control (`EXECUTE`) | n/a | Yes | Yes |
| **Budgets / spend caps** | Alert only | **No — not tracked at all** | **No** |

Two cliffs to state explicitly whenever this comes up:

1. **Budgets do not see MPS spend.** Per the docs: "Spend from model provider
   services is not tracked in budgets. Budget notifications, alerts, and hard spend
   caps do not apply to model provider service usage." Your provider bills you
   directly. Use rate limits as the enforceable control.
2. **Passthrough drops most governance.** If a service enables "Forward all URL
   paths" for unmapped provider endpoints, then "usage token and cost tracking,
   token-based rate limits, model access control, and service policies do not apply
   to passthrough requests." Only the managed paths are fully governed.

### Skills management

Register schema-less utility tools (Unity Catalog functions exposed as agent skills) with:

```bash
# Interactive: pick from UC functions to expose as skills
ucode configure skills

# Download skills to a local directory from a UC schema
ucode configure skills --location main.default --path /local/dir

# Expose UC functions as skills via MCP (adds to MCP config)
ucode configure skills --location main.default --mcp

# Download only a subset, by leaf skill name (requires a single --location)
ucode configure skills --location main.default --skill my-skill
```

`--location` takes a comma-separated list of `<catalog>.<schema>` scopes.
Source: https://github.com/databricks/ucode

---

### MLflow tracing — Claude Code only

`ucode configure tracing` (or `configure --tracing`) sends coding-session traces
to a workspace MLflow experiment. Scope is **Claude Code and nothing else**:
`TRACING_AGENTS = ("claude",)` at `tracing.py:43`. Claude's
`mlflow autolog claude` Stop hook writes traces to the experiment's Unity Catalog
table. Codex and OpenCode support was **removed** because the
`@mlflow/codex`/`@mlflow/opencode` JS clients only reach the classic, non-UC trace
store; Gemini's exporter is OTLP-only and was never wired in.

The experiment must be UC-backed. If self-service
`set_experiment_trace_location` binding is disabled on the workspace, an admin has
to provision the experiment first — you cannot bootstrap it yourself.

For Codex observability use the gateway usage table and inference tables instead
(see [ai-gateway.md](ai-gateway.md#system-tables)).

---

### Web search

Web search is supported through ucode when routed through Unity AI
Gateway — either native model web search (OpenAI, Gemini models today)
or MCP-based web search (model-agnostic, via a registered search MCP
server).

ucode also **ships its own** web-search MCP server: `ucode mcp web-search` runs a
stdio server exposing a `web_search` tool backed by a Databricks-hosted GPT model's
native Responses API search, spawned as a subprocess by Claude Code. It exists
because Claude Code's built-in web search doesn't work when routed through
Databricks. Model comes from `UCODE_WEB_SEARCH_MODEL`.

---

## Gotchas

**Only specific models are supported per tool's route.** For example,
Cursor's `/cursor/v1` route doesn't support every model (open-source
models like Qwen aren't supported there) — check the AI Gateway UI for the
per-route supported model list. Anthropic and OpenAI models are generally
supported.

**Non-Databricks (external) developers** need to be provisioned as
workspace users first (via AIM/JIT provisioning or SCIM), then generate
their own PAT or use OAuth — same per-user identity/usage-tracking/rate-
limiting guarantees apply once provisioned.

**Claude Code's large context window can hit FMAPI rate-limit tiers
quickly** (e.g. 200k input tokens/min / 20k output tokens/min default tier
for Claude Sonnet). Monitor via AI Gateway usage tables, request a tier
increase, or spread load across users if the aggregate exceeds the tier.

**Every build reports `ucode v0.1.0`.** Feature detection by version string is
impossible; a months-old install and current HEAD are indistinguishable that way.
Detect by flag (`ucode codex --help`) or by file presence in the installed package,
and reinstall with `uv tool install --reinstall git+https://github.com/databricks/ucode`.
When citing ucode behavior in a document, pin the commit.

**One `current_workspace`, but `--workspace` overrides it per launch.** ucode tracks
a single active workspace in `~/.ucode/state.json`, and each
`ucode configure --workspaces <host>` flips it. Historically that forced a
reconfigure when alternating between two agents on two workspaces; symptom of drift
was "No models available for codex" (an Azure workspace has no OpenAI Responses
route). Pass `--workspace <url>` on the launch command instead — it sets up and
authenticates the workspace if needed, so a launch needs no prior `configure`.

**Environment variables outrank ucode's config files.** An exported
`ANTHROPIC_BASE_URL` (or `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL`,
`CLAUDE_CODE_USE_GATEWAY`) makes Claude Code ignore `~/.claude/ucode-settings.json`
and silently use the env-var target. Launch from a clean shell, or strip them with
`env -u ANTHROPIC_BASE_URL ... ucode claude`.

**Claude Code enterprise managed settings outrank everything, including ucode.** A
`managed-settings.json` deployed by an enterprise MDM sits at the highest precedence
tier — above env vars, `--settings`, and `CLAUDE_CONFIG_DIR`. If it pins
`env.ANTHROPIC_BASE_URL`, `apiKeyHelper`, or `env.ANTHROPIC_CUSTOM_HEADERS`, ucode
**cannot** redirect Claude Code to your workspace, and the MPS routing headers get
dropped. ucode detects and warns about exactly these three keys
(`agents/claude.py:147-165`). Verify with a base-URL check, not a model-name check:
stripping env vars can change the reported model while the base URL stays pinned.

**ucode owns the agent's provider block and rewrites it every launch.** For Codex,
`MANAGED_KEYS` covers `model_providers.<name>` and its `http_headers`
(`agents/codex.py:55-60`), so a header hand-added to `ucode.config.toml` is wiped on
the next launch. To attach durable custom headers (e.g. request tags for cost
attribution), use Codex's `env_http_headers` — a map of header name to **env var
name** — layered at launch, since ucode forwards extra args to the agent binary:

```bash
export DATABRICKS_AI_GATEWAY_REQUEST_TAGS='{"source":"codex-cli","team":"platform"}'
ucode codex -c 'model_providers.ucode-databricks.env_http_headers.Databricks-Ai-Gateway-Request-Tags="DATABRICKS_AI_GATEWAY_REQUEST_TAGS"'
```

Verified on `ecb14e7` against a local capture server: the header arrives on every
request. `request_tags` is a filterable `map<string,string>` column in
`system.ai_gateway.usage`, which is how you separate one agent's spend from another's
on a shared Databricks-owned endpoint.

**OAuth loopback listener only lives for the duration of the command.** `ucode
configure` / `databricks auth login` opens a short-lived listener on port 8020. If
the command already exited (slow browser approval, or run non-interactively) you get
`ERR_CONNECTION_REFUSED` and a stale auth code. Re-run and approve promptly.

**Codex needs the OpenAI Responses API, which not every workspace serves.** Codex
routes to `/ai-gateway/codex/v1` with `wire_api = "responses"`; a workspace whose
endpoints only expose `mlflow/v1/chat/completions` cannot host Codex. ucode discovers
eligibility by checking each endpoint's `api_types` for `openai/v1/responses` with
`ai_gateway_v2_supported = true` (`databricks.py:1115`). Claude and Gemini use their
own native dialects and are less constrained.

---

## Related

- [omnigent-oss-vs-managed-vs-ucode.md](omnigent-oss-vs-managed-vs-ucode.md) — three-way comparison: when to pick ucode vs Omnigent OSS vs Omnigent managed, with architecture and request/response diagrams
- [omnigent.md](omnigent.md) — the fuller-featured alternative: same
  per-harness routing under the hood, plus session sharing, sandboxing,
  and a client-side policy engine ucode doesn't have
- [ai-gateway.md](ai-gateway.md) — the governance layer both tools route
  through
