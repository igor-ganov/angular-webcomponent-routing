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
  gh auth status
  $who = (gh api user --jq '.login').Trim()
  if ($who -ne $Owner) {
    throw "gh is authenticated as '$who', not '$Owner'. Run: gh auth switch --user $Owner"
  }
}

function Publish-Package([string]$Dir, [string]$Repo) {
  Write-Host "== Package: $Dir -> $Owner/$Repo ==" -ForegroundColor Cyan
  Push-Location (Join-Path $Root $Dir)
  try {
    if (-not (Test-Path .git)) { git init -b main | Out-Null }
    git add -A
    if (-not (git diff --cached --quiet; $?)) { git commit -m "Initial commit: $Repo" | Out-Null }

    $exists = $false
    try { gh repo view "$Owner/$Repo" *> $null; $exists = $true } catch { $exists = $false }
    if (-not $exists) {
      gh repo create "$Owner/$Repo" --$Visibility --source=. --remote=origin --push
    } else {
      if (-not (git remote | Select-String -Quiet '^origin$')) {
        git remote add origin "https://github.com/$Owner/$Repo.git"
      }
      git push -u origin main
    }
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
      $dir = $entry.Key
      $repo = $entry.Value
      if (-not (Test-Path (Join-Path '.git/modules' $dir))) {
        git submodule add --force "https://github.com/$Owner/$repo.git" $dir
      }
    }

    git add -A
    git commit -m 'Assemble monorepo from package submodules' | Out-Null

    $exists = $false
    try { gh repo view "$Owner/$MetaRepo" *> $null; $exists = $true } catch { $exists = $false }
    if (-not $exists) {
      gh repo create "$Owner/$MetaRepo" --$Visibility --source=. --remote=origin --push
    } else {
      if (-not (git remote | Select-String -Quiet '^origin$')) {
        git remote add origin "https://github.com/$Owner/$MetaRepo.git"
      }
      git push -u origin main
    }
  } finally { Pop-Location }
}

Confirm-Gh
foreach ($entry in $Packages.GetEnumerator()) { Publish-Package $entry.Key $entry.Value }
Wire-Submodules
Write-Host "Done. Monorepo: https://github.com/$Owner/$MetaRepo" -ForegroundColor Green
