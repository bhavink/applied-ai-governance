# Omnigent guardrails demo

> Companion code for the blog "You can't put the brakes inside the car: governing AI agents with
> Omnigent + Databricks." The guardrails can't live inside the agent you're trying to guard; they
> live outside it, in a control plane.

This folder holds a runnable, harness-agnostic agent that attaches seven out-of-the-box Omnigent
contextual policies at the tool-call boundary, with no custom code. Every action an agent takes (a
shell command, a file write, an install, a network call, adding a policy) is gated ALLOW / ASK /
DENY before it runs. On Databricks, model access is governed through the Unity AI Gateway.

See also [omnigent-governance.md](../omnigent-governance.md) for the wider governance model.

## How a tool call flows

Every tool call is evaluated by the policies before it runs, and returns ALLOW, ASK, or DENY. Model requests are governed by the gateway. Everything executes inside the sandbox, with network egress denied by default.

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant Agent as Agent (any harness)
    participant Policy as Omnigent policies
    participant Box as Sandbox + egress
    participant Gateway as Unity AI Gateway
    participant Model as Model

    Agent->>Policy: tool call (shell, file, install, egress)
    alt DENY (rm -rf /, force-push)
        Policy-->>Agent: blocked, fails closed
    else ASK (git push, curl to new host)
        Policy->>Dev: request approval
        Dev-->>Policy: approve or reject
        Policy->>Box: run only if approved
    else ALLOW (commit, ls, pytest)
        Policy->>Box: run
    end
    Agent->>Gateway: model request
    Gateway->>Model: governed call (PII, moderation)
    Model-->>Gateway: response
    Gateway-->>Agent: governed response
```

## Contents

| File | What it is |
|---|---|
| [config.yaml](config.yaml) | The agent spec: one agent, all seven OOTB policies. Sanitized; replace the placeholder hosts. |
| [scenarios.md](scenarios.md) | Four failure modes plus the guardrail-disable case, with the commands to attempt and the expected verdicts. |

## The seven policies

| Policy | Guards against |
|---|---|
| `ask_on_os_tools` | any file or shell tool without human approval |
| `blast_radius` | catastrophic, irreversible commands (`rm -rf /`, force-push) |
| `block_working_dir_changes` | escaping the working directory |
| `detect_loop` | runaway repeated tool calls |
| `max_tool_calls_per_session` | unbounded sessions |
| `install_source_allowlist` | installing unowned code (slopsquatting) |
| `egress_allowlist` | lateral movement and data exfiltration |

Plus `safety.ask_on_add_policy`, auto-injected by Omnigent, so the agent cannot silently disable its
own guardrails.

## Run it

Contextual policies are enforced by the Omnigent server and are harness-agnostic. Two ways to run:

**OSS, fully local**
```bash
omni run config.yaml --server local -p "your task"
```
Runs the agent and its policies entirely on your machine. Use a local container sandbox for
isolation (`os_env.sandbox`), or none for speed.

**On Databricks (governed)**
1. Configure a model provider in `~/.omnigent/config.yaml` that points at your workspace's Unity AI
   Gateway (no keys in this spec).
2. In the managed Omnigent UI, pick this agent and a host: the managed Databricks Sandbox (isolated,
   ephemeral) or your own machine.
3. Model calls are governed by the AI Gateway; agent actions are governed by the policies here.

## Notes

- Nothing in this folder is a secret. The workspace host, CLI profile, artifact host, and trusted
  repo are generic placeholders; substitute your own.
- Keep deliberately-risky test inputs (a slopsquat `llms.txt`, an exfil target) ephemeral. Do not
  commit them to a public repository.
