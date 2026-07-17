#!/bin/sh

# POSIX entry point for Git Bash. PowerShell owns validation and persistence;
# exec preserves every argument and returns its real exit status.
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || exit 69

if ! command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' 'RECEIPT_EVENT_FAILED code=powershell-missing' >&2
    exit 69
fi

exec pwsh -NoLogo -NoProfile -File "$script_dir/receipt-event.ps1" "$@"
