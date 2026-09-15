<!--
  Synced from databricks-fieldkit on 2026-09-14
  Sources: ai/prompt-registry.md
  Public docs grounding:
    - https://docs.databricks.com/aws/en/mlflow3/genai/prompt-version-mgmt/prompt-registry/
  This file is auto-prepared and human-reviewed before publish.
-->

# MLflow Prompt Registry

> **Cloud**: Agnostic
> **Status**: Beta (workspace admin preview toggle)
> **Last verified**: 2026-03-18

---

## TL;DR

The MLflow Prompt Registry stores versioned prompt templates in **Unity Catalog** (as UC functions). Prompts use `{{variable}}` syntax, are immutable per version (edit = new version), and can be loaded at runtime by name + version. Stored in UC means they get governance (permissions, lineage, audit) for free. Part of MLflow 3.1+.

---

## When to use

| Scenario | Use Prompt Registry |
|---|---|
| Multiple agents/apps share the same prompt | Yes -- single source of truth |
| You need prompt versioning with rollback | Yes -- immutable versions, Git-like history |
| Prompt changes should be auditable | Yes -- UC lineage tracks who changed what |
| Different teams own different prompts | Yes -- UC permissions per schema |
| One-off prompt in a single notebook | Optional -- can still be useful for tracing lineage |
| Prompts managed in source control (IaC) | Consider -- registry complements git, doesn't replace it |

---

## Prerequisites

- MLflow >= 3.1.0 (`pip install --upgrade "mlflow[databricks]>=3.1.0"`)
- UC schema with `CREATE FUNCTION`, `EXECUTE`, and `MANAGE` privileges
- MLflow experiment linked to tracking server (`mlflow.set_tracking_uri("databricks")`)

---

## How it works

```
Developer                    Unity Catalog                   Agent/App
    |                             |                              |
    |-- register_prompt() ------->|  stored as UC function       |
    |   (template + variables)    |  (catalog.schema.prompt)     |
    |                             |                              |
    |                             |<----- load_prompt() ---------|
    |                             |  returns template v=N        |
    |                             |                              |
    |-- register_prompt() ------->|  creates version N+1         |
    |   (updated template)        |  (previous versions intact)  |
```

- **Storage**: Each prompt is a UC function in `catalog.schema.prompt_name`
- **Versioning**: Immutable -- editing creates a new version, old versions remain
- **Variables**: Double-brace syntax `{{variable_name}}`
- **Linking**: Tag experiment with `mlflow.promptRegistryLocation` = `catalog.schema`

Two prompt formats supported: **Text** (single template string) and **Chat** (list of role-based messages for conversational models targeting chat-style LLMs).

---

## Quickstart

### 1. Link experiment to UC schema

```python
import mlflow

mlflow.set_tracking_uri("databricks")
mlflow.set_experiment("/Shared/my-experiment")
mlflow.set_experiment_tags({
    "mlflow.promptRegistryLocation": "main.default"
})
```

### 2. Register a prompt

```python
uc_schema = "main.default"
prompt_name = "summarization_prompt"

template = """\
Summarize the following content in {{num_sentences}} sentences.

Content: {{content}}
"""

prompt = mlflow.genai.register_prompt(
    name=f"{uc_schema}.{prompt_name}",
    template=template,
    commit_message="Initial version",
    tags={
        "author": "data-science-team@company.com",
        "task": "summarization",
    },
)
print(f"Created '{prompt.name}' v{prompt.version}")
```

### 3. Load and use in an app

```python
# Load specific version
prompt = mlflow.genai.load_prompt(
    name_or_uri=f"prompts:/{uc_schema}.{prompt_name}/1"
)

# Or without URI syntax
prompt = mlflow.genai.load_prompt(
    name_or_uri=f"{uc_schema}.{prompt_name}", version="1"
)

# Format with variables
formatted = prompt.format(content="Some text here", num_sentences=3)
```

### 4. Use with Databricks-hosted LLM

```python
from databricks_openai import DatabricksOpenAI
import mlflow

mlflow.openai.autolog()
mlflow.set_tracking_uri("databricks")
mlflow.set_experiment("/Shared/my-experiment")

client = DatabricksOpenAI()

@mlflow.trace
def summarize(content: str, num_sentences: int):
    formatted_prompt = prompt.format(content=content, num_sentences=num_sentences)
    response = client.chat.completions.create(
        model="databricks-claude-sonnet-4",
        messages=[
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": formatted_prompt},
        ],
    )
    return response.choices[0].message.content
```

#### Also works with OpenAI-hosted LLMs

```python
import openai, mlflow

mlflow.openai.autolog()
mlflow.set_tracking_uri("databricks")

client = openai.OpenAI()  # uses OPENAI_API_KEY env var

@mlflow.trace
def summarize(content: str, num_sentences: int):
    formatted_prompt = prompt.format(content=content, num_sentences=num_sentences)
    response = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": formatted_prompt},
        ],
    )
    return response.choices[0].message.content
```

### 5. Create a new version (edit)

```python
new_template = """\
You are an expert summarizer. Condense the following into exactly {{num_sentences}} sentences.

Content: {{content}}

Requirements:
- Exactly {{num_sentences}} sentences
- Only the most important information
- Neutral, objective tone
"""

updated = mlflow.genai.register_prompt(
    name=f"{uc_schema}.{prompt_name}",
    template=new_template,
    commit_message="Added quality guidelines",
)
print(f"Created v{updated.version}")
```

### 6. Search prompts

```python
# REQUIRED: catalog AND schema must both be specified for UC
results = mlflow.genai.search_prompts("catalog = 'main' AND schema = 'default'")

# Using variables
catalog_name = uc_schema.split('.')[0]
schema_name = uc_schema.split('.')[1]
results = mlflow.genai.search_prompts(
    f"catalog = '{catalog_name}' AND schema = '{schema_name}'"
)

# Limit results
results = mlflow.genai.search_prompts(
    filter_string=f"catalog = '{catalog_name}' AND schema = '{schema_name}'",
    max_results=50
)
```

---

## UI workflow

1. Navigate to MLflow experiment > **Prompts** tab
2. Click **New Prompt** > select UC schema > name the prompt
3. Click **Create new version** > type template with `{{variables}}` > **Save**
4. Compare versions: click prompt name > **Compare** > select versions

---

## Governance

| Aspect | How it works |
|---|---|
| **Access control** | UC privileges on the schema (`CREATE FUNCTION`, `EXECUTE`, `MANAGE`) |
| **Versioning** | Immutable versions -- full history, safe rollback |
| **Lineage** | MLflow traces link prompt version to model output |
| **Audit** | UC audit logs track who registered/loaded which version |
| **Tagging** | Custom tags per version (author, use_case, model_compatibility) |

---

## Gotchas

| Issue | Detail |
|---|---|
| **UC schema permissions** | Need `CREATE FUNCTION` + `EXECUTE` + `MANAGE` on the schema -- not just `USE SCHEMA` |
| **Experiment must be linked** | Set `mlflow.promptRegistryLocation` tag before registering prompts |
| **Versions are immutable** | Cannot edit in place -- must create new version |
| **Variable syntax** | Double braces `{{var}}` -- single braces `{var}` won't work |
| **Name format** | Must be fully qualified: `catalog.schema.prompt_name` |
| **Search filter format** | Must specify both `catalog` and `schema`: `"catalog = 'x' AND schema = 'y'"` — not just catalog |
| **Prompt name constraints** | Names can only contain letters, numbers, hyphens, underscores, and dots — no spaces or special chars |

---

## Related

- [`agent-framework.md`](agent-framework.md) -- Agent SDK and LangGraph (uses prompts in agents)
- [`mlflow-tracing.md`](mlflow-tracing.md) -- Tracing captures prompt version lineage
- [`production-monitoring.md`](production-monitoring.md) -- Monitor prompt quality in production
- [`../governance/unity-catalog.md`](../governance/unity-catalog.md) -- UC privileges and governance
- [Evaluate prompt versions](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/prompt-version-mgmt/prompt-registry/evaluate-prompts) -- Compare prompt versions to find the best performer
- [Track prompts with app versions](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/prompt-version-mgmt/prompt-registry/track-prompts-app-versions) -- Link prompt versions to app versions for full lineage
- [Use prompts in deployed apps](https://learn.microsoft.com/en-us/azure/databricks/mlflow3/genai/prompt-version-mgmt/prompt-registry/use-prompts-in-deployed-apps) -- Deploy with aliases for stable references
