# Harness — Identity and Observability in the Agent Runtime

The harness is where identity and observability meet at runtime. An agent
harness is the layer that sits between a coding or task agent and the tools it
calls. It decides which tool calls are allowed, carries the caller's identity
into every downstream request, and emits the signals you later audit. That
makes it the applied intersection of the two pillars this repository focuses on:

- **Identity** flows *through* the harness. The user's token is exchanged and
  propagated so that tool calls and SQL run as the real caller, and per-user
  authorization (row filters, column masks, connection grants) still applies.
  See [`../identity/`](../identity/).
- **Observability** is *how you watch* the harness. Every policy decision, tool
  call, and cost event becomes a trace or an audit record you can review and
  alert on. See [`../observability/`](../observability/).

This section stays deliberately narrow. It covers how identity and
observability show up in an agent runtime, not general tool or agent
governance.

## Runnable example: omnigent-guardrails-demo

[`omnigent-guardrails-demo/`](omnigent-guardrails-demo/) is a self-contained,
runnable policy harness. It pairs a guardrail configuration with a set of
scenarios and their expected verdicts, so the policies are testable rather than
aspirational.

- [`config.yaml`](omnigent-guardrails-demo/config.yaml): the guardrail policy
  set, including working-directory confinement, an egress allowlist, blast-radius
  limits, human-approval gates on OS tools, loop detection, a per-session
  tool-call cap, and CEL-based custom policies.
- [`scenarios.md`](omnigent-guardrails-demo/scenarios.md): the attack and
  everyday scenarios the policies are meant to handle.
- [`tests/`](omnigent-guardrails-demo/tests/): a deterministic pytest suite that
  asserts the expected verdict (ALLOW, ASK, or DENY) for each command, so a
  policy change that shifts a verdict is caught immediately.

### Running the tests

The suite exercises the Omnigent runtime, which is installed separately.

```bash
cd harness/omnigent-guardrails-demo
uv tool install "omnigent[databricks]"     # the runtime under test
pip install -r requirements-dev.txt         # pytest + PyYAML
pytest tests/
```

Each test maps a command to a policy and asserts the verdict. For example,
reading an absolute path is an ALLOW under working-directory confinement but an
ASK under the OS-tools approval gate, while an actual directory change is a DENY.

## How this connects to the pillars

| Concern | Where it lives | In the harness |
|---|---|---|
| Who the caller is | [`../identity/`](../identity/) | Token exchange and per-user propagation into tool calls |
| What the caller may do | [Row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/) | Enforced at the data layer under the caller's identity |
| What actually happened | [`../observability/`](../observability/) | Policy verdicts, tool-call traces, and cost events |
