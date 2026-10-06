# Pin Coding Agents to One Unity Gateway Workspace

> Tool & API Governance. Companion to the [ug quickstart](ug-quickstart.md).

You run Unity Catalog and Unity Gateway, and you want your developers' coding agents governed
through `ug` (formerly `ucode`). Out of the box `ug` asks each developer for two things: which
harness (Claude Code, Codex, and so on) and which workspace to point at. You want the second
choice made for them, so every coding agent routes through one enterprise Unity Gateway
workspace instead of whichever workspace a developer happens to pick.

Here is how to do it. One recommended path, one fallback, nothing else to read.

## Prerequisites: the workspace side, do this first

Before the script or the managed config matters, the model service has to exist and the right
people have to hold the right grants. Two roles, two grant sets.

| Role | Grants needed on Databricks | Why |
|------|------------------------------|-----|
| **Service creator** (platform team) | `USE CATALOG` and `USE SCHEMA` on the target schema; `CREATE SERVICE` on that schema; `EXECUTE` on every destination the service routes to (a `system.ai` foundation model, or a model-provider service that holds an external key); ownership or `MANAGE` to change it later. | Model services use definer's privileges: Databricks checks the *owner's* `EXECUTE` on the destination, not the caller's. The creator holds the model and provider grants so users never have to. |
| **Service user** (the coding-agent group) | `EXECUTE` on the model service, plus `USE CATALOG` on its catalog and `USE SCHEMA` on its schema. | That is the entire requirement for a coding agent. Users get the governed endpoint, never the raw model or the provider key. |

Grant the user side to a group, not to individuals, in Catalog Explorer or the model service's
Permissions tab (or through the grants API or CLI):

- catalog: `USE CATALOG`
- schema: `USE SCHEMA`
- model service, for example `main.ai.coding_claude`: `EXECUTE`

Confirm Unity Gateway is enabled on the workspace and that the model service the agents will use
already exists. To create a service or change its routing, see the
[ug quickstart](ug-quickstart.md#configure-model-service-routing).

## The short version

`ug` is a client-side configurator, not a server-side lock. The reliable way to fix the
workspace for everyone is to ship each coding agent's **admin-managed config file** through your
device management (MDM), with the gateway URL pinned to your one workspace. That URL is the
workspace, and an agent CLI's managed config outranks the user's own config and environment
variables, so a developer cannot repoint it.

| Approach | Enforces the workspace? | When to use it |
|---|---|---|
| **MDM-delivered managed config** (recommended) | Yes. A user cannot override it without admin rights. | Every managed device. This is the answer. |
| `ug configure --workspace <url>` default | No. It skips the picker but a user can still change the default. | Only where you have no MDM. |

## Do this: managed config via MDM

1. **Pick the workspace.** Note its host, for example `your-workspace.cloud.databricks.com`.
   Grant the coding-agent group `EXECUTE` on the model service they will call, plus
   `USE CATALOG` and `USE SCHEMA` on its schema.
2. **Stage one managed-config file per harness**, with the gateway URL pinned to that host.
   Change the host and you change the workspace; that is the only value that decides routing.
3. **Push the files with MDM** (Jamf, Intune, or Kolide) and let MDM own them, so a later
   `ug configure` on the machine cannot drop the pin.

**Codex**, at `/etc/codex/managed_config.toml` (root-owned):

```toml
model_provider = "Databricks"

[model_providers.Databricks]
name     = "Databricks"
base_url = "https://your-workspace.cloud.databricks.com/ai-gateway/codex/v1"
wire_api = "responses"

# Command-based auth: ug refreshes the token itself, no key to distribute
[model_providers.Databricks.auth]
command             = "ug"
args                = ["auth-token", "--host", "https://your-workspace.cloud.databricks.com", "--profile", "corp"]
refresh_interval_ms = 900000
```

**Claude Code**, in its managed-settings file (macOS path shown; the per-OS locations are in the
table below):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-workspace.cloud.databricks.com/ai-gateway/anthropic"
  }
}
```

Pin only the base URL in the managed file and let `ug` write the matching auth helper into
Claude Code's own config. That is the whole enforcement. The developer still chooses the
harness; the workspace is now yours.

### Where the managed file goes, per OS

Each harness reads its managed file from a fixed system location. Deliver it there with your MDM:
Jamf on macOS, Intune or Group Policy on Windows, your config-management tool on Linux.

| Harness | macOS | Linux and WSL | Windows |
|---|---|---|---|
| **Claude Code** (`managed-settings.json`) | `/Library/Application Support/ClaudeCode/managed-settings.json` | `/etc/claude-code/managed-settings.json` | `C:\Program Files\ClaudeCode\managed-settings.json` |
| **Codex** (`managed_config.toml`) | `/etc/codex/managed_config.toml` | `/etc/codex/managed_config.toml` | verify for your Codex version (see references) |

- Claude Code does **not** read the legacy Windows path `C:\ProgramData\ClaudeCode\managed-settings.json`. On Windows you can also deliver the same JSON through Group Policy or Intune as the `Settings` value under `HKLM\SOFTWARE\Policies\ClaudeCode`; on macOS, through the `com.anthropic.claudecode` configuration profile.
- Codex's Unix path is stable, but its Windows managed-config location has moved across versions, so confirm it against the current Codex configuration docs before you deploy on Windows.

## Login and token refresh take care of themselves

You do not put credentials in these files. On first launch with no profile, `ug` opens the
browser OAuth sign-in and creates the local profile. The command-based auth block then refreshes
the token automatically. A developer who has never signed in simply gets the sign-in prompt the
first time they run `ug codex` or `ug claude`, and every launch after that is silent.

## The fallback where you have no MDM

Share an onboarding script. The admin sets three values at the top (workspace, profile name,
agents), and the developer runs it once. There are two, same behavior, pick by platform:

| Script | Runs on | Command |
|---|---|---|
| [`ug-onboard.sh`](ug-onboard.sh) | macOS, Linux, WSL, Git Bash | `bash ug-onboard.sh` |
| [`ug-onboard.ps1`](ug-onboard.ps1) | Windows (native PowerShell) | `powershell -ExecutionPolicy Bypass -File ug-onboard.ps1` |

Either one checks the prerequisites, creates the Databricks profile through browser sign-in if it
is missing or expired, pins the workspace as the default so `ug claude` and `ug codex` skip the
picker, and verifies the result. On any failure it writes a redacted diagnostics file and tells
the user to send it to the platform team, which is enough to debug most issues without a support
round trip. Both accept `--help` (`-Help` in PowerShell) and are safe to re-run.

Under the covers the pinning step is just `ug configure --workspace <host>`, which saves the
default workspace. Treat this whole path as a convenience, not a control, because a developer can
still change the default. Use MDM wherever you can.

## Verify it took

- **Codex:** run `RUST_LOG=codex_core=debug codex exec --skip-git-repo-check --sandbox read-only "Reply OK"` and confirm the host in the log is your workspace. Do not rely on `ug status`, which reports saved state rather than the effective managed file.
- **Claude Code:** confirm the launch banner shows your workspace base URL.
- **Either:** have your platform admin confirm the call appears in that workspace's `system.ai_gateway.usage`.

## Know this before you roll it out

- **One file per harness.** Each agent CLI has its own managed-config file and its own gateway
  route (`/ai-gateway/codex/v1` for Codex, `/ai-gateway/anthropic` for Claude). There is no
  single `ug` file that pins every harness at once.
- **Confirm paths and flags on your version.** `ug` reports a constant version string, so check
  `ug --help` and each agent CLI's current managed-config path on the build you deploy before you
  roll it out fleet-wide.
- **This pins the client, not the network.** It stops a developer pointing at the wrong
  workspace. It does not stop someone calling a model provider directly with a personal key from
  an unmanaged machine; that is a network-egress control and is out of scope here.

## References

- [ug quickstart](ug-quickstart.md)
- [Route coding agents through model services](https://docs.databricks.com/aws/en/ai-gateway/coding-agent-integration-model-services)
- [unity-gateway CLI](https://github.com/databricks/unity-gateway#readme)
- [Deploy Claude Code managed settings](https://code.claude.com/docs/en/managed-settings)
- [Codex config loader (paths and layering)](https://github.com/openai/codex/blob/main/codex-rs/config/src/loader/README.md)
