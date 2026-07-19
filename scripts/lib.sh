#!/usr/bin/env bash
# Shared helpers for the parental-control scripts. Source this, don't execute it.
set -euo pipefail

# Resolve repo root regardless of where a script is invoked from.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/.." && pwd)"

# Load central settings.
# shellcheck disable=SC1091
source "${REPO_ROOT}/config/settings.env"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must run as root (use sudo)."
}

# Read a list file, dropping comments and blank lines, trimming whitespace.
read_list() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
    | grep -v '^$' || true
}

# Where the live (installed) configs live vs. the repo copies.
installed_allowlist() { echo "${ALLOWLIST}"; }
installed_yt()        { echo "${YT_ALLOWLIST}"; }
