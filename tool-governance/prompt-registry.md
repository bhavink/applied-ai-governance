<!--
  Synced from databricks-fieldkit on 2026-04-27
  Sources: ai/prompt-registry.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/mlflow3/genai/prompt-version-mgmt/prompt-registry/
    - https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/prompt-version-mgmt/prompt-registry/create-and-edit-prompts
  This file is auto-prepared and human-reviewed before publish.
-->

# Prompt Registry — Governed Prompt Versioning

> **TL;DR**: The MLflow Prompt Registry stores versioned prompt templates as **Unity Catalog functions**. Prompts are immutable per version (edit creates a new version), referenced by `catalog.schema.prompt_name@version`, and inherit the UC governance model — privileges, lineage, audit. Treat prompts the way you treat models: name them deterministically, version every change, grant by group, and tag with author and intent.

---

## Why Prompts Are a Governance Surface

A production prompt is part of the agent's behavior. A change to "you are a helpful assistant" can flip safety posture, change tool selection, or shift the answer distribution. Without versioning and access control, prompt changes are undetected, unattributed, and unrollback-able.

The Prompt Registry treats a prompt as a UC object so that:

| Question | Answer source |
|---|---|
| Who can read this prompt? | UC `EXECUTE` privilege on the function |
| Who can edit (create new versions)? | UC `MANAGE` and `CREATE FUNCTION` privileges |
| Which prompt version produced this output? | MLflow trace lineage |
| When was this prompt last changed and by whom? | UC audit logs |
| What changed between v3 and v4? | Registry version comparison + commit message |

---

## Mental Model

```
Author                       Unity Catalog                 Agent / App
   │                              │                            │
   │ register_prompt(template) ──>│  function: catalog.schema  │
   │                              │  version 1 (immutable)     │
   │                              │                            │
   │                              │<── load_prompt(name, v=1) ─│
   │                              │  template returned         │
   │                              │                            │
   │ register_prompt(updated) ───>│  version 2 (v1 intact)     │
   │                              │                            │
```

- **Storage**: each prompt is a UC function in `catalog.schema.prompt_name`
- **Versioning**: immutable — every edit produces a new version, prior versions remain queryable
- **Variables**: double-brace syntax (`{{variable_name}}`)
- **Experiment binding**: set the experiment tag `mlflow.promptRegistryLocation` to `catalog.schema` so the experiment knows where its prompts live

---

## Prerequisites

- MLflow 3.1+ (`pip install --upgrade "mlflow[databricks]>=3.1.0"`)
- UC schema with `CREATE FUNCTION`, `EXECUTE`, and `MANAGE` privileges on the registering identity
- MLflow experiment linked to the Databricks tracking server

---

## Core Operations

### Bind the experiment to a UC schema

```python
import mlflow

mlflow.set_tracking_uri("databricks")
mlflow.set_experiment("/Shared/my-experiment")
mlflow.set_experiment_tags({
    "mlflow.promptRegistryLocation": "main.prompts"
})
```

### Register a prompt

```python
template = """\
Summarize the following content in {{num_sentences}} sentences.

Content: {{content}}
"""

prompt = mlflow.genai.register_prompt(
    name="main.prompts.summarization",
    template=template,
    commit_message="Initial version",
    tags={
        "author":  "platform-team",
        "task":    "summarization",
        "intent":  "general-purpose document summarizer",
    },
)
```

### Load a specific version

```python
prompt = mlflow.genai.load_prompt(
    name_or_uri="prompts:/main.prompts.summarization/1"
)

# Or with explicit version
prompt = mlflow.genai.load_prompt(
    name_or_uri="main.prompts.summarization", version="1"
)

formatted = prompt.format(content="...", num_sentences=3)
```

### Create a new version (edit)

```python
mlflow.genai.register_prompt(
    name="main.prompts.summarization",
    template=new_template,
    commit_message="Added neutrality requirement",
)
```

### Search prompts

```python
results = mlflow.genai.search_prompts(
    "catalog = 'main' AND schema = 'prompts'"
)
```

---

## Governance Levers

| Aspect | Control |
|---|---|
| **Access control** | UC privileges on the schema. `EXECUTE` to load, `CREATE FUNCTION` + `MANAGE` to register or update |
| **Versioning** | Immutable per version — every change is a new version, history retained |
| **Lineage** | MLflow Tracing records the prompt version used in each LLM call |
| **Audit** | UC audit logs capture who registered or loaded which version |
| **Tagging** | Custom tags per version (author, intent, compatible models, review status) |

### Recommended schema layout

```
main.prompts        ← shared, broadly readable
team_a.prompts      ← team-owned, restricted to team_a group
team_b.prompts      ← team-owned, restricted to team_b group
sandbox.prompts     ← author-only schemas for experimentation
```

Grant `EXECUTE` on shared schemas to the agent service principals that need to load prompts at runtime. Reserve `CREATE FUNCTION` and `MANAGE` to a small platform or review group.

---

## Patterns to Apply

| When building... | Configure... |
|---|---|
| A production agent | Pin to a specific prompt version (`prompts:/.../<n>`); never load `latest` in production |
| A multi-tenant agent platform | Per-tenant or per-team prompt schemas with group grants |
| Prompt review process | Register new versions in a `staging.prompts` schema; promote by re-registering in `prod.prompts` after review |
| Audit "what produced this output" | Enable MLflow Tracing — every LLM call records the prompt URI |
| Rollback after a bad change | Pin the agent to the previous version URI; do not edit history |
| Source control + registry coexistence | Keep prompt YAML in git as source of truth; CI registers each merge to UC |

---

## Patterns to Avoid

| Pattern | Better approach |
|---|---|
| Loading `latest` in production agents | Pin to an explicit version URI; promote deliberately |
| Inline prompt strings scattered across services | Single registered prompt + load by name |
| Editing a prompt template in place | Register a new version; immutability is the audit guarantee |
| Single brace variable syntax `{var}` | Double brace `{{var}}` — required by the registry's templating |
| Granting `MANAGE` broadly | Reserve `MANAGE` to a small review group; broad `EXECUTE` is usually fine |
| Storing prompts in app config without versioning | Move to the registry — version, audit, and lineage come for free |

---

## Related

- [`agent-governance.md`](agent-governance.md) — Agents that load prompts at runtime
- [`../observability/agent-tracing.md`](../observability/agent-tracing.md) — Tracing captures prompt version per call
- [`../data-governance/uc-governance.md`](../data-governance/uc-governance.md) — UC privilege model that backs the registry

---

## Public References

- [Prompt Registry overview](https://docs.databricks.com/aws/en/mlflow3/genai/prompt-version-mgmt/prompt-registry/)
- [Create and edit prompts](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/prompt-version-mgmt/prompt-registry/create-and-edit-prompts)
- [MLflow `genai` API reference](https://mlflow.org/docs/latest/python_api/mlflow.genai.html)
