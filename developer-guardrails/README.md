# Developer Guardrails

> **Pillar 0** -- Is the AI coding assistant doing something dangerous during development?

The newest attack surface. AI coding tools have shell access, file system access, and network access on developer machines. Allow/deny lists don't scale; context-aware classification does.

## Status

Future work. This pillar will cover:

- **Credential exfiltration prevention** -- Block reads of `~/.ssh/`, `~/.aws/`, `.env` files
- **Destructive operation guards** -- Classify `git push --force`, `rm -rf`, destructive SQL by context
- **Supply chain protection** -- Detect obfuscated shell commands, piped curl-to-shell patterns
- **Project boundary enforcement** -- Prevent writes outside the project directory
- **Context-aware classification** -- Classify by what the operation actually does, not what tool it uses

## Design Direction

The goal is a hook-based system that intercepts tool calls before execution:

```
Tool call → Context classifier → Allow / Deny / Escalate
```

Classification runs in milliseconds using structural rules. For ambiguous cases, optionally route to an LLM. Every decision is logged and inspectable.

## Related Pillars

- [Identity](../identity/) -- Developer guardrails protect the build process; identity protects the runtime
- [Governance Framework](../GOVERNANCE-FRAMEWORK.md) -- Developer guardrails are Pillar 0 in the seven-pillar model
