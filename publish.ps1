#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Publishes the three workspace packages as independent GitHub repositories under
  the `igor-ganov` account, then wires them back into this monorepo as git submodules.

.DESCRIPTION
  Idempotent and safe to re-run. Steps:
    1. For each package directory: `git init` + initial commit (if needed),
       create the GitHub repo (if missing), and push.
    2. In this monorepo: drop the placeholder .gitignore entries, add each package
       as a submodule pointing at its new remote, commit, create the meta repo, push.

  Pushes use the active account's token directly in a one-off URL (never written to
  git config), so it works non-interactively even with multiple `gh` accounts.

  Nothing here runs automatically. Review it, confirm `gh auth status` shows you signed
  in as `igor-ganov`, then run:  pwsh ./publish.ps1

.NOTES
  To undo locally:  git submodule deinit -f <path>; git rm -f <path>; rm -rf .git/modules/<path>
#>

$ErrorActionPreference = 'Stop'
$Owner = 'igor-ganov'
$Visibility = 'public'   # change to 'private' if preferred
$MetaRepo = 'angular-webcomponent-routing'

# package directory -> GitHub repository name
$Packages = [ordered]@{
  'router-lib'    = 'subtree-router'
  'web-component' = 'feature-web-component'
  'host-app'      = 'angular-host'
}

$Root = $PSScriptRoot

function Confirm-Gh {
  Write-Host '== Checking GitHub auth ==' -ForegroundColor Cyan
  $who = (gh api user --jq '.login').Trim()
  if ($who -ne $Owner) {
    throw "gh is authenticated as '$who', not '$Owner'. Run: gh auth switch --user $Owner"
  }
  Write-Host "  active account: $who" -ForegroundColor Green
}

# Pushes HEAD -> main using the active account's token in a one-off URL (not persisted).
function Push-Main([string]$Repo) {
  $token = (gh auth token).Trim()
  git push "https://x-access-token:$token@github.com/$Owner/$Repo.git" HEAD:main
}

function Test-Repo([string]$Repo) {
  try { gh repo view "$Owner/$Repo" --json name -q .name *> $null; return $true } catch { return $false }
}

function Ensure-Origin([string]$Repo) {
  if (-not (git remote | Select-String -Quiet '^origin$')) {
    git remote add origin "https://github.com/$Owner/$Repo.git"
  }
}

function Publish-Package([string]$Dir, [string]$Repo) {
  Write-Host "== Package: $Dir -> $Owner/$Repo ==" -ForegroundColor Cyan
  Push-Location (Join-Path $Root $Dir)
  try {
    if (-not (Test-Path .git)) { git init -b main | Out-Null }
    git add -A
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m "Initial commit: $Repo" | Out-Null }

    if (-not (Test-Repo $Repo)) { gh repo create "$Owner/$Repo" --$Visibility | Out-Null }
    Ensure-Origin $Repo
    Push-Main $Repo
  } finally { Pop-Location }
}

function Wire-Submodules {
  Write-Host '== Wiring submodules into the monorepo ==' -ForegroundColor Cyan
  Push-Location $Root
  try {
    if (-not (Test-Path .git)) { git init -b main | Out-Null }

    # Drop the "workspace packages are independent git repos" placeholder block,
    # so the directories can be added as submodules instead of being ignored.
    $gi = Get-Content .gitignore -Raw
    $gi = ($gi -split '# --- workspace packages')[0].TrimEnd() + "`n"
    Set-Content .gitignore $gi -NoNewline

    foreach ($entry in $Packages.GetEnumerator()) {
      if (-not (Test-Path (Join-Path '.git/modules' $entry.Key))) {
        git submodule add --force "https://github.com/$Owner/$($entry.Value).git" $entry.Key
      }
    }

    git add -A
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m 'Assemble monorepo from package submodules' | Out-Null }

    if (-not (Test-Repo $MetaRepo)) { gh repo create "$Owner/$MetaRepo" --$Visibility | Out-Null }
    Ensure-Origin $MetaRepo
    Push-Main $MetaRepo
  } finally { Pop-Location }
}

Confirm-Gh
foreach ($entry in $Packages.GetEnumerator()) { Publish-Package $entry.Key $entry.Value }
Wire-Submodules
Write-Host "Done. Monorepo: https://github.com/$Owner/$MetaRepo" -ForegroundColor Green
