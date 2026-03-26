# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Azure Automation Runbooks (PowerShell 7.4) for Entra ID / M365 service account monitoring. Deployed via Azure CLI shell scripts.

## Commands

Each runbook lives in its own subdirectory with companion scripts:

- `cd <runbook-dir> && ./setup.sh` — deploy runbook + runtime + schedule to Azure
- `cd <runbook-dir> && ./test.sh` — run in DryRun mode
- `cd <runbook-dir> && ./test.sh live` — run with actual changes/emails
- `cd <runbook-dir> && ./grant-permissions.sh` — assign Graph API permissions (requires Global Admin)

## Configuration

Each runbook directory has its own `.env.example`. Copy to `.env` and fill in values. Never commit `.env`.

## Code Conventions

- PowerShell: PascalCase functions, `Verb-Noun` naming, `-ErrorAction Stop`, `Write-Output`/`Write-Warning`/`Write-Error` for logging
- Bash: `set -euo pipefail`, proper quoting, shellcheck directives
- Commit messages: conventional prefixes (`feat:`, `fix:`, `docs:`, `chore:`), English
- Push directly to main (no feature branches)
- Code changes must always be reflected in the README

## New Runbooks

Mirror the existing pattern:
- One subdirectory per runbook (runbook + setup.sh + test.sh + grant-permissions.sh + .env.example)
- `[bool]$DryRun = $true` parameter (safe by default)
- Graph API via `Invoke-MgGraphRequest` with pagination (`Get-AllPages` helper)
- HTML email alerts via `Send-AlertMail`
- Companion `setup.sh` and `test.sh` scripts

## Gotchas

- On-prem synced accounts: Sponsor field is read-only — skip sponsor alerts for these
- Non-interactive sign-ins require `/beta/auditLogs/signIns` with `signInEventTypes` filter
- Graph permissions take ~5 min to propagate after granting
- Wrap arrays in `@()` to prevent PowerShell single-element unwrapping
- Use `ms-graph-endpoint-research` skill before writing Graph API code
