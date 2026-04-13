# Prompt Security — Threat Intelligence Log

> Rolling append-only log of prompt security findings relevant to Databricks AI applications.
> Each entry is sourced from a primary public disclosure. Only findings with verifiable public sources are included.
> **Update cadence**: Append after each reviewed disclosure. Do not backfill.
> **Companion files**: [attack-surfaces.md](attack-surfaces.md) (attack surface map), [hardening-patterns.md](hardening-patterns.md) (build-time defensive actions).

---

## How to Use This Log

Each entry contains:

| Field | What it means |
|---|---|
| **Date** | Date of public disclosure |
| **Source** | Primary source URL(s) — always a public reference |
| **Target** | System or platform affected |
| **Technique** | Attack method, as described in the source |
| **Affected Databricks surfaces** | Which parts of a Databricks AI stack are relevant |
| **Confidence** | Evidence quality — High / Medium / Low with rationale |
| **Defensive actions** | Concrete steps builders can take |

Cross-reference the attack class taxonomy in [attack-surfaces.md](attack-surfaces.md). If an entry represents a new attack class not yet in the taxonomy, add it there.

**Principles:**
- Factual only — cite the primary source URL for every finding.
- Do not extrapolate beyond what the source reports. If evidence is weak, say so.
- Credit the original researchers and publications.

---

## Log Entries

### INTEL-001: Prompt Injection via Universal Adversarial Trigger + Unicode RTLO

| Field | Detail |
|---|---|
| **Date disclosed** | Apr 9, 2026 |
| **Source** | RSAC Conference — [Blog post](https://www.rsaconference.com/library/blog/is-that-a-bad-apple-in-your-pocket-we-used-prompt-injection-to-hijack-apple-intelligence), [Technical details](https://www.rsaconference.com/library/blog/rotten-apples-the-technical-details-of-rsacs-successful-apple-intelligence-prompt-injection-attack) |
| **Target** | Apple Intelligence on-device LLM (iOS/macOS) |
| **Technique** | Indirect prompt injection using a universal adversarial trigger combined with Unicode RIGHT-TO-LEFT OVERRIDE (U+202E) to obfuscate harmful output. The trigger is inline-composable — it can be embedded in otherwise benign text without losing effect. |
| **Reported success rate** | 76% before Apple's Mar 24, 2026 patches (per RSAC blog) |
| **Affected Databricks surfaces** | AI Gateway guardrails (Unicode bypass), Vector Search (indexed docs with bidi chars), MCP tool descriptions (Unicode smuggling), Agent Bricks KA/MAS (retrieved content with bidi chars) |
| **Confidence** | High — real production target, published PoC methodology, measured attack success rate, vendor patch confirmed |

**Key takeaways for Databricks builders:**

1. Unicode bidi controls (U+202E, U+202C, U+2066, U+2069) can evade both input and output filters that operate on raw byte sequences rather than normalized or rendered text.
2. Inline-composable payloads survive chunking, summarization, and retrieval — relevant to any RAG pipeline.
3. AI Gateway keyword filters operate on raw text and would not detect reversed strings rendered via bidi overrides.

**Defensive actions:**
- Add Unicode normalization (NFC/NFKC) to any content pipeline that feeds into LLM context.
- Test AI Gateway guardrails with bidi-encoded payloads.
- Add bidi-control character stripping to document ingestion pipelines for Vector Search.

See [hardening-patterns.md](hardening-patterns.md) → Unicode normalization section.

---

### INTEL-002: Invisible Unicode Smuggling in MCP Tool Descriptions

| Field | Detail |
|---|---|
| **Date disclosed** | Apr 6, 2026 |
| **Source** | Community research — [Reddit post](https://www.reddit.com/r/pwnhub/comments/1sedi0o/we_tested_invisible_unicode_smuggling-against/) citing a scan of 3,471 MCP servers. Related tooling: [Invariant Labs mcp-scan](https://github.com/invariantlabs-ai/mcp-scan) |
| **Target** | MCP servers across multiple agent frameworks |
| **Technique** | Invisible Unicode characters — zero-width spaces (U+200B), zero-width non-joiner (U+200C), zero-width joiner (U+200D), bidi isolates (U+2066/U+2069) — embedded in MCP tool descriptions. These characters are invisible in UIs and code review but are tokenized by the LLM, allowing hidden instructions to influence tool selection and argument construction. |
| **Affected Databricks surfaces** | Custom MCP servers (developer-authored), External MCP servers (third-party-authored). Tool descriptions are passed into LLM context as part of tool selection. Managed MCP descriptions are Databricks-authored and not affected by this attack vector. |
| **Confidence** | Medium — social-post-level evidence without a full primary write-up with reproducible methodology. The attack technique class is well-established; the specific MCP scan results are not independently verified. |

**Key takeaways for Databricks builders:**

1. Tool descriptions are an attack surface. They are treated as trusted context by agent frameworks but may contain adversarial content if authored by third parties.
2. Managed MCP descriptions are Databricks-authored and safe. Custom and External MCP descriptions are developer/third-party-authored and should be validated before deployment.
3. Code review and UI inspection are insufficient — invisible Unicode is invisible by design.

**Defensive actions:**
- Run [mcp-scan](https://github.com/invariantlabs-ai/mcp-scan) against Custom and External MCP server registrations.
- Strip zero-width and bidi-control Unicode characters from tool descriptions before passing to LLM context.
- Add Unicode normalization to Custom MCP server code templates.

See [hardening-patterns.md](hardening-patterns.md) → MCP section.

---

## Landscape Note (Apr 05–13, 2026)

The RSAC Apple Intelligence finding is the strongest practical attack disclosure of this period. It validates three attack patterns worth expanding in red team datasets:

1. **Payload-bearing gibberish triggers** — universal adversarial triggers that are syntactically opaque but semantically active.
2. **Inline-composable indirect injections** — payloads embeddable in benign-looking text that survive retrieval, chunking, and summarization.
3. **Unicode-rendering tricks** — bidi and invisible character abuse that evades both pre- and post-generation filters.

These patterns are complementary and stackable. Builders should test guardrails against each class independently.

---

*Next entry: append below after next threat disclosure.*
