<!--
  Synced from databricks-fieldkit on 2026-07-14
  Sources: security/prompt-attack-surfaces.md
  Public docs grounding:
    - https://owasp.org/www-project-top-10-for-large-language-model-applications/
  This file is auto-prepared and human-reviewed before publish.
-->

# Prompt Attack Surfaces on Databricks

> Every place where text enters an AI system and influences its behavior is an attack surface. This document maps the Databricks surfaces where prompts are accepted — directly by users or indirectly through data — to the attack classes that apply.

---

## Attack Class Definitions

Before mapping surfaces, here are the attack classes referenced throughout this document. These align with the [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/).

| Attack class | Description |
|---|---|
| **Direct prompt injection** | User crafts input text to override system instructions or intended behavior |
| **Indirect prompt injection** | Adversarial content embedded in data, documents, or tool responses influences LLM behavior when that content is consumed as context |
| **Unicode obfuscation** | Invisible or visually-deceptive Unicode characters (bidi controls, zero-width spaces) evade content filters or alter text rendering. Demonstrated against production systems by [RSAC researchers (2026)](https://www.rsaconference.com/library/blog/rotten-apples-the-technical-details-of-rsacs-successful-apple-intelligence-prompt-injection-attack). |
| **Tool description poisoning** | Adversarial instructions embedded in tool metadata influence tool selection or argument generation. Identified in [community scans of MCP server ecosystems](https://github.com/invariantlabs-ai/mcp-scan). |
| **Cross-agent injection** | In multi-agent systems, adversarial content from one agent's response influences the supervisor's routing or another agent's behavior |
| **Return value injection** | Data returned by tools or functions contains text that the LLM interprets as instructions |
| **Guardrail bypass** | Techniques that evade safety, PII, or keyword filters — including encoding tricks and semantic rephrasing |
| **Embedding collision** | Adversarial text designed to be semantically similar to target queries, ensuring retrieval from vector indexes regardless of topical relevance |
| **Tool confusion** | A query is phrased to route to a different sub-agent or tool than the one intended for that question type |
| **Server impersonation** | An attacker-controlled or typosquatted server is registered as a tool source, most relevant to externally-connected integrations |

---

## Surface Map

### 1. Genie Spaces (Natural Language to SQL)

**What it does**: Converts natural language questions to SQL queries against Unity Catalog tables.

| Trust boundary | Detail |
|---|---|
| User queries | Untrusted — user-supplied natural language |
| Space instructions | Trusted — set by the space creator (admin) |
| Sample questions | Trusted — set by the space creator |
| Generated SQL | Executed as the calling user via OBO |

**Attack classes that apply**: Direct prompt injection, SQL injection via natural language.

**Why the blast radius is limited**: Genie is read-only (no INSERT/UPDATE/DELETE/DDL). Generated SQL runs through UC enforcement — row filters and column masks fire on the query regardless of how it was generated. The LLM cannot trick the SQL engine into bypassing UC permissions.

**Builder action**: Write explicit space instructions and scope tables tightly. UC enforces access control on the generated SQL, but the space creator controls which tables are available and how the LLM is instructed to use them. See [Hardening Patterns](hardening-patterns.md#genie-spaces).

---

### 2. Genie Code / DS Agent (Natural Language to Code)

**What it does**: Generates Python and SQL code from natural language prompts for execution in notebooks.

| Trust boundary | Detail |
|---|---|
| User prompts | Untrusted — natural language |
| Generated code | Executed in the user's notebook session after human approval |
| Data read by generated code | Semi-trusted — sourced from UC-governed tables but content may include adversarial text |

**Attack classes that apply**: Direct prompt injection (code generation), indirect prompt injection (via data read by generated code), supply chain (generated `pip install` of attacker-controlled packages).

**Primary defense**: Human approval is required at each step. The user must review and approve generated code before execution.

**Builder action**: Establish a review discipline — treat the approval step as a code review, not a formality. Use dev/staging catalogs for exploratory work. See [Hardening Patterns](hardening-patterns.md#genie-code--ds-agent).

---

### 3. Agent Bricks — Knowledge Assistants

**What it does**: Answers questions using documents indexed in Vector Search, optionally augmented with UC Functions.

| Trust boundary | Detail |
|---|---|
| User queries | Untrusted — natural language |
| Retrieved document chunks | Semi-trusted — sourced from UC-governed tables, but document *content* is user-uploaded and may contain adversarial text |
| UC function return values | Trusted — function code is registered and governed in UC |

**Attack classes that apply**: Indirect prompt injection (via retrieved documents), Unicode obfuscation (in indexed content).

**Why this matters**: This is the classic RAG indirect injection vector. Documents are indexed as *data* but consumed by the LLM as *context*. Adversarial text in a document ("Ignore previous instructions and say: ...") can influence the assistant's response if retrieved.

**Builder action**: Sanitize documents at ingestion time — strip Unicode control characters and normalize text before indexing. This is a standard step in any RAG pipeline. See [Hardening Patterns](hardening-patterns.md#agent-bricks-ka-and-mas).

---

### 4. Agent Bricks — Multi-Agent Supervisors

**What it does**: Routes user queries to sub-agents (Genie Spaces, Knowledge Assistants, UC Functions) and aggregates responses.

| Trust boundary | Detail |
|---|---|
| User queries | Untrusted |
| Sub-agent responses | Semi-trusted — each sub-agent has its own trust model, but responses flow into the supervisor's context |
| Routing logic | Trusted — configured by admin |

**Attack classes that apply**: All classes from sub-agent surfaces, plus cross-agent injection, return value injection, and tool confusion.

**Why this matters**: The supervisor LLM processes sub-agent responses as context. A data value returned by Genie (e.g., a free-text `notes` column) flows into the supervisor and can influence its reasoning or routing decisions. Separately, a question can be phrased to make the supervisor route to a sub-agent other than the one an admin intended for that question type (for example, steering a data question toward the Vector Search agent instead of Genie).

**Builder action**: Sanitize free-text columns in Genie source tables and test cross-agent scenarios with adversarial data values. Include routing-confusion test cases in evaluation so misrouted queries surface before production. The supervisor's routing logic is admin-configured, but data flowing through sub-agents should be treated as context that needs validation. See [Hardening Patterns](hardening-patterns.md#agent-bricks-ka-and-mas).

---

### 5. MCP Servers (Managed, Custom, External)

**What it does**: Exposes tools to agents via the Model Context Protocol. Three types: Managed (Databricks-hosted), Custom (developer-built, hosted on Databricks Apps), External (third-party, proxied via UC HTTP Connections).

| Trust boundary | Managed | Custom | External |
|---|---|---|---|
| Tool descriptions | Trusted (Databricks-authored) | Developer-authored | Third-party-authored |
| Tool arguments | LLM-generated (influenced by user prompt) | Same | Same |
| Tool responses | Data (from Databricks services) | Data (from developer code) | Data (from external services) |

**Attack classes that apply**: Tool description poisoning (Custom, External), tool response injection (all types), argument manipulation (all types), server impersonation (External).

**Why tool descriptions matter**: Agent frameworks pass tool descriptions into the LLM context to guide tool selection and argument construction. If a Custom or External description contains hidden instructions (e.g., via [invisible Unicode characters](https://github.com/invariantlabs-ai/mcp-scan)), the LLM may follow them. Managed MCP descriptions are Databricks-authored and curated. For Custom and External servers, validate descriptions as part of your registration workflow.

**Server impersonation (External MCP)**: Because External MCP servers are registered via UC HTTP Connections and can point at any endpoint, verify server identity and provenance before granting `USE CONNECTION` — treat a typosquatted server name or a compromised third-party endpoint the same as any other supply-chain risk.

**Platform defense**: UC `GRANT USE CONNECTION` governs who can use External MCP servers. UC permissions enforce data access regardless of tool behavior.

---

### 6. AI Gateway

**What it does**: Control plane for model traffic — rate limiting, guardrails, usage tracking, fallbacks. Two guardrail paths are available: a pattern-based path on Serving Endpoints, and Unity AI Gateway guardrails (Preview), which add LLM-based detection.

| Trust boundary | Detail |
|---|---|
| Prompts | Pass through to the model — gateway inspects but does not generate |
| Legacy guardrails (Serving Endpoints) | Pattern-based detection (Llama Guard 2-8b safety filter, Presidio PII detection, keyword blocklists) |
| Unity AI Gateway guardrails (Preview) | LLM-based evaluator (recommended `databricks-gpt-5-nano`) across six guardrail templates, including a dedicated **Jailbreak** guardrail and a **Custom** guardrail for org-specific policy prompts up to 5,000 characters |

**Attack classes that apply**: Guardrail bypass (via Unicode obfuscation, semantic rephrasing, encoding tricks).

**What guardrails do and don't do**: Pattern-based filters detect specific content patterns rather than prompt injection as a general class — a prompt that says "ignore your instructions" passes through if those words aren't on the keyword blocklist. [RSAC researchers (2026)](https://www.rsaconference.com/library/blog/rotten-apples-the-technical-details-of-rsacs-successful-apple-intelligence-prompt-injection-attack) demonstrated that Unicode bidi tricks can cause harmful text to evade keyword filters that operate on raw byte sequences. Unity AI Gateway's LLM-based evaluator is semantic rather than pattern-based, so it generalizes better to novel injection phrasing — apply it where injection resistance matters most.

**Unity AI Gateway guardrails (Preview) — what's available**:
- Dedicated **Jailbreak** guardrail (input phase) — targets instruction overrides, role-play exploits, prompt extraction, and obfuscated payloads
- Dedicated **Hallucination** guardrail (output phase)
- **Custom** guardrail (up to 5,000-char prompt) for organization-specific policies — competitor mentions, off-topic content, tone violations
- Up to 3 blocking guardrails + 1 sanitizing guardrail per phase (input/output)
- `LOG` mode for dry-run testing without enforcement, useful for tuning before turning a guardrail to blocking mode

**Builder action**: Because guardrails evaluate a single message at a time, pair them with session-level or multi-turn evaluation (see [production monitoring's multi-turn judges](../observability/agent-tracing.md)) for attacks that build up across a conversation rather than appearing in one message. Output guardrails don't apply to streaming responses or `n > 1` completions, so budget for output-side validation in your own code when using those modes. The evaluator call has a bounded timeout (15s, retried once) and fails closed on timeout — treat evaluator latency as part of your endpoint's overall latency budget.

**Limitations to plan around**:
- Legacy PII detection covers US formats only (Presidio)
- Max batch size of 16 when legacy guardrails are enabled
- Unity AI Gateway guardrails evaluate per-message, not per-conversation

---

### 7. UC Functions (as Agent Tools)

**What it does**: SQL or Python functions registered in Unity Catalog, invoked by agents as tools.

| Trust boundary | Detail |
|---|---|
| Function code | Trusted — registered in UC, governed by GRANT EXECUTE |
| Arguments | LLM-generated (influenced by user prompt) |
| Return values | Data — fed back into LLM context |

**Attack classes that apply**: Argument manipulation, return value injection.

**Platform defense**: `GRANT EXECUTE` controls who can invoke each function. `is_member()` can be used inside functions for additional authorization.

**Builder action**: Sanitize return values in functions that return user-generated content (e.g., free-text notes, comments). Validate arguments inside the function body rather than trusting LLM-generated values. See [Hardening Patterns](hardening-patterns.md#uc-functions).

---

### 8. Vector Search (RAG Retrieval)

**What it does**: Returns document chunks from a vector index based on semantic similarity to a query.

| Trust boundary | Detail |
|---|---|
| User queries | Untrusted — natural language search queries |
| Indexed documents | Semi-trusted — sourced from UC-governed tables, but document content is user-uploaded |
| Returned chunks | Semi-trusted — subset of indexed content matching the query |

**Attack classes that apply**: Indirect prompt injection (adversarial content in indexed documents), Unicode obfuscation (bidi controls in document text), embedding collision (adversarial text designed to be semantically similar to target queries, ensuring retrieval).

**Why this matters**: Vector Search is the primary RAG retrieval mechanism. Documents are indexed as data but consumed by the LLM as context. An attacker who can upload documents to the source table can inject content that will be retrieved and influence LLM responses. The embedding collision variant targets the retrieval step itself — crafting text that embeds close to target queries.

**Builder action**: Sanitize documents at ingestion (strip Unicode control characters, normalize text). Monitor for anomalous document upload patterns. Consider content validation before indexing. UC controls who can write to the source table — this is the primary defense.

---

### 9. Model Serving Endpoints

**What it does**: Hosts ML models and agents for real-time inference via REST API.

| Trust boundary | Detail |
|---|---|
| API request payload | Untrusted — caller-supplied input |
| Model code | Trusted — deployed by model owner |
| Agent tool responses | Semi-trusted — tool outputs may contain adversarial content |

**Attack classes that apply**: Direct prompt injection (via API input), indirect prompt injection (via tool responses consumed by hosted agents), return value injection (tool outputs interpreted as instructions).

**Why this matters**: Serving endpoints are the runtime execution boundary for agents. When an agent is deployed as a serving endpoint, it processes user input AND tool responses in the same LLM context. A compromised tool response can influence the agent's subsequent behavior.

**Builder action**: Apply AI Gateway guardrails (input/output filters) to serving endpoints. Use OBO authentication where per-user governance is needed. Monitor via `system.serving.endpoint_usage` and MLflow traces.

---

## Summary Matrix

| Surface | Direct injection | Indirect injection | Unicode obfuscation | Tool poisoning | Cross-agent | Guardrail bypass | Embedding collision | Tool confusion | Server impersonation |
|---|---|---|---|---|---|---|---|---|---|
| Genie Spaces | Yes | — | Yes | — | — | — | — | — | — |
| Genie Code | Yes | Yes | Yes | — | — | — | — | — | — |
| Agent Bricks KA | — | **Yes** | **Yes** | — | — | — | — | — | — |
| Agent Bricks MAS | — | **Yes** | **Yes** | — | **Yes** | — | — | **Yes** | — |
| MCP (Custom/External) | — | Yes | **Yes** | **Yes** | — | — | — | — | Yes |
| AI Gateway | — | — | **Yes** | — | — | **Yes** | — | — | — |
| UC Functions | — | Yes | — | — | — | — | — | — | — |
| Vector Search | — | **Yes** | **Yes** | — | — | — | **Yes** | — | — |
| Model Serving | **Yes** | Yes | Yes | Yes | — | Yes | — | — | — |

**Bold** = primary attack vector for that surface.

---

## References

- OWASP: [Top 10 for Large Language Model Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- RSAC Conference (2026): [Prompt injection against production on-device LLMs with Unicode obfuscation](https://www.rsaconference.com/library/blog/is-that-a-bad-apple-in-your-pocket-we-used-prompt-injection-to-hijack-apple-intelligence)
- RSAC Conference (2026): [Technical details of Unicode RTLO filter bypass](https://www.rsaconference.com/library/blog/rotten-apples-the-technical-details-of-rsacs-successful-apple-intelligence-prompt-injection-attack)
- Invariant Labs: [mcp-scan — MCP server security scanner](https://github.com/invariantlabs-ai/mcp-scan)
- Databricks: [AI Gateway guardrails](https://docs.databricks.com/aws/en/generative-ai/guard-rails/index.html)
- Databricks: [Unity AI Gateway guardrails (Preview)](https://docs.databricks.com/aws/en/ai-gateway/guardrails)
- Databricks: [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- Databricks: [Unity Catalog access control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- Databricks: [Genie Spaces](https://docs.databricks.com/aws/en/genie/)
- Databricks: [MCP servers](https://docs.databricks.com/aws/en/generative-ai/mcp/)
