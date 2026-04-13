# Prompt Security

> *The AI platform trusts your identity, your permissions, and your data governance rules. Should it also trust the text it receives?*

## The Problem

Every AI application on Databricks accepts natural language at some point — a user types a question into Genie, an agent retrieves a document from Vector Search, a tool description tells the model what a function does. Each of these is a **prompt surface**: a place where text enters the system and influences what the AI does next.

Some of that text comes from your users. Some comes from your data. Some comes from third-party services. The security question is the same in every case: **can adversarial content in that text cause the AI to do something it shouldn't?**

This is not a theoretical concern. Prompt injection — the technique of embedding instructions in text that trick an LLM into overriding its intended behavior — is the most widely demonstrated attack class against LLM-powered applications. It has been validated against production systems, documented by security researchers, and recognized by [OWASP as a top risk for LLM applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/).

The challenge: unlike SQL injection, there is no complete syntactic defense. LLMs process instructions and data in the same channel. Defense requires **identifying every surface where untrusted text enters**, understanding the **blast radius** of each surface, and applying **layered mitigations** that limit damage even when individual layers are bypassed.

## How This Fits the Framework

The [Governance Framework](../GOVERNANCE-FRAMEWORK.md) asks six questions at every layer:

1. Who is asking? (Identity)
2. Can they reach it? (Network)
3. Are they allowed? (Authorization)
4. What can they do? (Capability)
5. What did they do? (Audit)
6. Can you prove it? (Compliance)

Prompt security adds a seventh question that cuts across all six:

> **7. Was the input trustworthy?**

Identity tells you *who* sent the request. Authorization tells you *what they're allowed to do*. Prompt security asks whether the *content* of the request — or the data it touches — is attempting to subvert the answer to questions 3 and 4.

A user with valid credentials and proper authorization can still cause harm if the text they submit (or the data their query retrieves) manipulates the AI into acting outside its intended scope. Prompt security is the governance layer that addresses this.

## Contents

| Document | What it covers |
|---|---|
| [Attack Surfaces](attack-surfaces.md) | Every Databricks surface where prompts are accepted, the trust boundary, and which attack classes apply |
| [Hardening Patterns](hardening-patterns.md) | Platform-native defenses and implementation patterns for each surface |

## Key Principles

These principles follow directly from the framework's [design principles](../GOVERNANCE-FRAMEWORK.md):

**1. Defense in depth applies to prompts, not just networks.**
No single filter or guardrail is sufficient. Layer platform enforcement (UC permissions, AI Gateway guardrails) with application-level validation (input sanitization, output monitoring). Assume each layer can be bypassed individually.

**2. The data layer is your strongest defense.**
Prompt injection cannot bypass UC row filters, column masks, or `GRANT` permissions. The SQL engine enforces these on generated queries regardless of what the LLM was tricked into producing. This is why [governing at the data layer](../GOVERNANCE-FRAMEWORK.md) matters — the AI application is just another query issuer.

**3. Separate trusted and untrusted text.**
System prompts, tool descriptions, and admin-configured instructions are trusted. User queries, retrieved documents, and external API responses are untrusted. The more clearly your architecture separates these, the harder injection becomes.

**4. Audit what the AI did, not just what the user asked.**
The user asked a question. The AI generated SQL, retrieved documents, called tools, and produced a response. Audit the full chain — [observability](../observability/) of the AI's actions is how you detect successful injections after the fact.

## References

- OWASP: [Top 10 for Large Language Model Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- Databricks: [AI Gateway guardrails](https://docs.databricks.com/aws/en/generative-ai/guard-rails/index.html)
- Databricks: [Agent authentication](https://docs.databricks.com/aws/en/generative-ai/agent-framework/agent-authentication)
- Databricks: [Unity Catalog access control](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control)
- RSAC Conference (2026): [Prompt injection research against production on-device LLMs](https://www.rsaconference.com/library/blog/is-that-a-bad-apple-in-your-pocket-we-used-prompt-injection-to-hijack-apple-intelligence) — demonstrates that prompt injection with Unicode obfuscation can bypass input/output filters in production systems
- Invariant Labs: [mcp-scan — MCP server security scanner](https://github.com/invariantlabs-ai/mcp-scan)
