<#
.SYNOPSIS
  Point a developer's coding agents at ONE Unity Gateway workspace (Windows / PowerShell).

.DESCRIPTION
  The PowerShell twin of ug-onboard.sh, for teams without MDM on native Windows.
  An admin edits the three values in the CONFIG block below, shares this file, and the
  developer runs it once:

      powershell -ExecutionPolicy Bypass -File ug-onboard.ps1

  It verifies prerequisites, creates the Databricks profile (browser sign-in) if it is
  missing or expired, pins ug at your workspace, and verifies the result. On any failure it
  writes a redacted diagnostics file and tells the user to send it to the platform team.
  Safe to re-run.

  This is the convention-level fallback. It sets the default workspace; a determined user can
  still change it. Where you have MDM, ship the managed config instead (see ug-managed-workspace.md).

  PREREQUISITES (the platform team does this ONCE, before sharing the script):
    1. Unity Gateway is enabled on the workspace named below.
    2. The model service the agents will use already exists (e.g. main.ai.coding_claude).
    3. The coding-agent group has been granted, for that service:
         - EXECUTE on the model service
         - USE CATALOG on its catalog and USE SCHEMA on its schema
       The service creator/owner separately holds CREATE SERVICE and EXECUTE on the underlying
       model or provider (definer's privileges); service users never need those.

.PARAMETER Help
  Show usage and exit.
#>
[CmdletBinding()]
param([switch]$Help)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — admin edits these three values before sharing, then leave the rest.
# ─────────────────────────────────────────────────────────────────────────────
$WorkspaceHost = "https://your-workspace.cloud.databricks.com"   # the ONE workspace
$ProfileName   = "corp"                                          # Databricks CLI profile name
$Agents        = "claude,codex"                                  # harnesses to configure
$SupportContact = "your platform team (for example #ai-platform-support on Slack)"
# ─────────────────────────────────────────────────────────────────────────────

$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$Ts   = Get-Date -Format "yyyyMMdd-HHmmss"
$Diag = Join-Path $HomeDir "ug-onboard-diagnostics-$Ts.log"

function Write-Ok    { param($m) Write-Host "OK  $m" -ForegroundColor Green }
function Write-WarnL { param($m) Write-Host "!   $m" -ForegroundColor Yellow }
function Write-Step  { param($m) Write-Host "`n==> $m" -ForegroundColor White }

function Show-Usage {
@"
ug-onboard.ps1 - point your coding agents at one Unity Gateway workspace.

Usage:
  powershell -ExecutionPolicy Bypass -File ug-onboard.ps1        Run onboarding
  powershell -ExecutionPolicy Bypass -File ug-onboard.ps1 -Help  Show this help

What it does, in order:
  1. Checks prerequisites: Python, uv, Databricks CLI, and ug (installs ug if missing).
  2. Creates or refreshes the Databricks profile via browser sign-in if it is missing/expired.
  3. Pins ug at the workspace so 'ug claude' and 'ug codex' skip the workspace picker.
  On any failure it writes a redacted diagnostics file and tells you who to send it to.
  Safe to re-run.

Set by your admin (the CONFIG block at the top of this file):
  workspace : $WorkspaceHost
  profile   : $ProfileName
  agents    : $Agents
  support   : $SupportContact

Prerequisite (platform team, once): the model service exists and your group has EXECUTE on it,
plus USE CATALOG and USE SCHEMA on its catalog and schema. See ug-managed-workspace.md.

After a successful run, launch one agent from your project directory:
  ug claude      # or: ug codex
"@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

# Redact anything token-shaped so the diagnostics file is safe to share.
function Redact([string]$s) {
  if ($null -eq $s) { return "" }
  $s = $s -replace 'dapi[A-Za-z0-9]+', 'dapi<redacted>'
  $s = $s -replace 'eyJ[A-Za-z0-9._-]{10,}', '<redacted-jwt>'
  $s = $s -replace '([Bb]earer )[A-Za-z0-9._-]+', '$1<redacted>'
  return $s
}

function Add-Diag([string]$text) { Add-Content -Path $Diag -Value (Redact $text) }

function Get-ToolVersion([string]$exe, [string[]]$verArgs) {
  if (Get-Command $exe -ErrorAction SilentlyContinue) {
    try { return (& $exe @verArgs 2>&1 | Out-String).Trim() } catch { return "error" }
  }
  return "not found"
}

function Write-DiagHeader {
  @(
    "ug-onboard diagnostics - $Ts",
    "workspace: $WorkspaceHost   profile: $ProfileName   agents: $Agents",
    "os: $([System.Environment]::OSVersion.VersionString)",
    "powershell: $($PSVersionTable.PSVersion)",
    "python: $(Get-ToolVersion 'python' @('--version'))",
    "uv: $(Get-ToolVersion 'uv' @('--version'))",
    "databricks: $(Get-ToolVersion 'databricks' @('--version'))",
    "ug: $(Get-ToolVersion 'ug' @('--version'))",
    "PATH: $env:Path",
    "--------------------------------------------------------"
  ) | ForEach-Object { Add-Content -Path $Diag -Value (Redact $_) }
}

function Fail([string]$msg) {
  Write-WarnL $msg
  Write-Host ""
  Write-Host "Something needs a human. A diagnostics file was written (secrets redacted):"
  Write-Host "    $Diag"
  Write-Host "Send that file to $SupportContact and they can tell you the fix."
  Write-Host "You can safely re-run this script after the fix."
  exit 1
}

# Run a non-interactive command, logging output to diagnostics on failure. Returns $true/$false.
function Invoke-Checked([string]$desc, [string]$exe, [string[]]$cmdArgs) {
  $out = (& $exe @cmdArgs 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    Add-Diag "FAILED (exit $LASTEXITCODE): $desc`n`$ $exe $($cmdArgs -join ' ')`n$out`n"
    return $false
  }
  return $true
}

# Read the host recorded for a profile in ~/.databrickscfg (no secrets live there for OAuth).
function Get-ProfileHost([string]$name) {
  $cfg = Join-Path $HomeDir ".databrickscfg"
  if (-not (Test-Path $cfg)) { return "" }
  $inSection = $false
  foreach ($line in Get-Content $cfg) {
    if ($line -match '^\[') { $inSection = ($line.Trim() -eq "[$name]"); continue }
    if ($inSection -and $line -match '^\s*host\s*=') {
      return ($line -replace '^\s*host\s*=\s*', '').Trim()
    }
  }
  return ""
}

Write-DiagHeader
Write-Host "ug onboarding - pinning coding agents at $WorkspaceHost (profile: $ProfileName)"

# 1 - Prerequisites -----------------------------------------------------------
Write-Step "Checking prerequisites"

$python = @('python','py','python3') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $python) { Fail "Python is not installed. Install Python 3.12+ and re-run." }
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Fail "uv is not installed. Install it from https://docs.astral.sh/uv and re-run." }
Write-Ok "Python and uv present"

if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
  Fail "The Databricks CLI is not installed. Install it from https://docs.databricks.com/en/dev-tools/cli and re-run."
}
Write-Ok "Databricks CLI present"

if (-not (Get-Command ug -ErrorAction SilentlyContinue)) {
  Write-WarnL "ug not found. Installing it with uv..."
  & uv tool install git+https://github.com/databricks/unity-gateway
  if ($LASTEXITCODE -ne 0) { Fail "Could not install ug. Check network access to GitHub and PyPI, then re-run." }
  if (-not (Get-Command ug -ErrorAction SilentlyContinue)) {
    Fail "ug installed but is not on PATH. Add the directory from 'uv tool dir --bin' to your PATH, open a new terminal, and re-run."
  }
}
Write-Ok "ug present ($(Get-ToolVersion 'ug' @('--version')))"

# 2 - Databricks profile ------------------------------------------------------
Write-Step "Checking the Databricks profile '$ProfileName'"

$existingHost = Get-ProfileHost $ProfileName
if ($existingHost -and $existingHost -ne $WorkspaceHost) {
  Write-WarnL "Profile '$ProfileName' points at $existingHost, not $WorkspaceHost."
  Write-WarnL "Re-authenticating it at the correct workspace."
}

$profileOk = ($existingHost -eq $WorkspaceHost) -and (Invoke-Checked "verify profile" "databricks" @('current-user','me','-p',$ProfileName))
if ($profileOk) {
  Write-Ok "Profile '$ProfileName' is valid and points at the right workspace"
} else {
  Write-WarnL "Profile '$ProfileName' is missing or expired. Opening browser sign-in..."
  Write-Host "    Sign in as yourself. Approve the login in the browser window."
  # Interactive: let the browser flow reach the console directly.
  & databricks auth login --host $WorkspaceHost --profile $ProfileName
  if ($LASTEXITCODE -ne 0) {
    Add-Diag "FAILED: databricks auth login --host $WorkspaceHost --profile $ProfileName"
    Fail "Browser sign-in did not complete. Common causes: closed the browser tab, denied the request, or the login port was blocked."
  }
  if (-not (Invoke-Checked "re-verify profile after login" "databricks" @('current-user','me','-p',$ProfileName))) {
    Fail "Signed in, but the profile still cannot reach the workspace. Confirm you have access to $WorkspaceHost."
  }
  Write-Ok "Profile '$ProfileName' created and verified"
}

# 3 - Pin ug at the workspace -------------------------------------------------
Write-Step "Configuring ug for $Agents at $WorkspaceHost"
Write-Host "    Follow any browser or terminal prompts. This writes each agent's config."
# Interactive: ug may run its own sign-in and discovery.
& ug configure --workspace $WorkspaceHost --agents $Agents
if ($LASTEXITCODE -ne 0) {
  Add-Diag "FAILED: ug configure --workspace $WorkspaceHost --agents $Agents"
  Fail "ug configure did not finish. If it reported OS-managed settings overriding it, this machine already has a managed config; tell the platform team which workspace it names."
}
Write-Ok "ug configured; $WorkspaceHost is now the default workspace"

# 4 - Done --------------------------------------------------------------------
Remove-Item -Path $Diag -ErrorAction SilentlyContinue   # success: no diagnostics needed
Write-Step "Done"
Write-Ok "Coding agents will route through $WorkspaceHost."
Write-Host ""
Write-Host "Launch one from your project directory:"
Write-Host "    ug claude     or     ug codex"
Write-Host ""
Write-Host "If a launch fails, re-run this script. If it still fails, contact $SupportContact."
