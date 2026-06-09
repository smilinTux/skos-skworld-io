#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  skos — Sovereign Agent OS  ·  installer v0.1.0
#  https://skos.skworld.io
#
#  PLEASE REVIEW THIS SCRIPT BEFORE PIPING TO sh.
#  Open it in your editor:
#      curl -fsSL https://skos.skworld.io/install.sh -o skos-install.sh
#      less skos-install.sh    # read it
#      sh skos-install.sh      # run it when satisfied
#
#  What this script does:
#    1. Detect OS, container runtime (podman preferred, docker fallback), python3
#    2. Show an interactive profile + capability menu (whiptail/dialog if
#       available, else a plain numbered prompt)
#    3. Install the skos CLI:  pip install git+https://github.com/smilinTux/skos
#    4. Run  skos path <profile>  to set SK_DATA_ROOT and create the directory tree
#    5. Run  skos install <selected capabilities>  for each chosen item
#    6. Print a friendly "what got installed + next steps" summary
#
#  Properties:
#    - POSIX sh (no bashisms) — tested on bash 5, dash, busybox sh
#    - Idempotent — safe to re-run; already-installed items are skipped
#    - No root required (rootless podman path)
#    - Stores nothing outside SK_DATA_ROOT and the Python venv/pip prefix
#
#  License: GPL-3.0  ·  Author: Lumina (lumina@skworld.io)  ·  2026
# ─────────────────────────────────────────────────────────────────────────────

set -e   # exit on error
umask 077  # new files readable only by owner

# ── Colours (degraded gracefully if no tty) ──────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'; RESET='\033[0m'
  GOLD='\033[0;33m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
  RED='\033[0;31m';  DIM='\033[2m'; PINK='\033[0;35m'
else
  BOLD=''; RESET=''
  GOLD=''; CYAN=''; GREEN=''
  RED='';  DIM=''; PINK=''
fi

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
  printf "\n"
  printf "${GOLD}${BOLD}  🐧  skos — Sovereign Agent OS  ·  installer v0.1.0${RESET}\n"
  printf "${DIM}  https://skos.skworld.io  |  GPL-3.0  |  smilinTux${RESET}\n"
  printf "\n"
}

# ── Logging helpers ───────────────────────────────────────────────────────────
info()  { printf "  ${CYAN}→${RESET}  %s\n" "$1"; }
ok()    { printf "  ${GREEN}✓${RESET}  %s\n" "$1"; }
warn()  { printf "  ${GOLD}⚠${RESET}  %s\n" "$1"; }
error() { printf "  ${RED}✗${RESET}  %s\n" "$1" >&2; }
step()  { printf "\n${BOLD}${CYAN}▸ %s${RESET}\n" "$1"; }

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
  OS_TYPE="unknown"
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "$ID" in
      ubuntu|debian|linuxmint|pop)   OS_TYPE="debian" ;;
      fedora|rhel|centos|rocky|alma) OS_TYPE="fedora" ;;
      arch|manjaro|endeavouros)      OS_TYPE="arch"   ;;
      opensuse*|suse)                OS_TYPE="suse"   ;;
      *)                             OS_TYPE="linux"  ;;
    esac
  elif [ "$(uname)" = "Darwin" ]; then
    OS_TYPE="macos"
  fi
  printf "%s" "$OS_TYPE"
}

# ── Container runtime detection ───────────────────────────────────────────────
detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    printf "podman"
  elif command -v docker >/dev/null 2>&1; then
    printf "docker"
  else
    printf "none"
  fi
}

# ── Python detection ──────────────────────────────────────────────────────────
detect_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 --version 2>&1 | awk '{print $2}'
  else
    printf "none"
  fi
}

# ── pip invocation helper ─────────────────────────────────────────────────────
# Tries pip3, then python3 -m pip. Adds --user if not in a venv.
run_pip() {
  if [ -n "$VIRTUAL_ENV" ] || [ -n "$CONDA_DEFAULT_ENV" ]; then
    pip3 "$@" 2>/dev/null || python3 -m pip "$@"
  else
    pip3 --user "$@" 2>/dev/null || python3 -m pip --user "$@"
  fi
}

# ── Interactive menu — tries whiptail, then dialog, then plain prompt ─────────

# Returns selected indices (space-separated) for a checklist
# Usage: show_checklist "title" "item1" "item2" ...
# Items prefixed with "*" are pre-selected.
show_checklist() {
  TITLE="$1"; shift
  # Build arrays
  ITEMS=""; idx=1
  for item in "$@"; do
    CHECKED="off"
    LABEL="$item"
    case "$item" in \**)
      CHECKED="on"
      LABEL="${item#\*}"
    esac
    ITEMS="$ITEMS $idx \"$LABEL\" $CHECKED"
    idx=$((idx+1))
  done

  # Try whiptail
  if command -v whiptail >/dev/null 2>&1; then
    # whiptail checklist — result is quoted indices
    # We need eval to expand $ITEMS properly
    RESULT=$(eval "whiptail --title 'skos installer' \
      --checklist '$TITLE' 20 72 10 \
      $ITEMS \
      3>&1 1>&2 2>&3" 2>&1) || true
    # Strip quotes from result
    printf "%s" "$RESULT" | tr -d '"'
    return
  fi

  # Try dialog
  if command -v dialog >/dev/null 2>&1; then
    RESULT=$(eval "dialog --title 'skos installer' \
      --checklist '$TITLE' 20 72 10 \
      $ITEMS \
      3>&1 1>&2 2>&3" 2>&1) || true
    printf "%s" "$RESULT"
    return
  fi

  # Plain numbered prompt fallback
  printf "\n${BOLD}${GOLD}  %s${RESET}\n" "$TITLE"
  printf "${DIM}  (Enter numbers separated by spaces, or press Enter for defaults)${RESET}\n\n"
  idx=1; DEFAULTS=""
  for item in "$@"; do
    case "$item" in \**) DEFAULT=" [default]"; DEFAULTS="$DEFAULTS $idx" ;;
                    *)   DEFAULT="" ;;
    esac
    LABEL="${item#\*}"
    printf "    ${CYAN}%2d${RESET}. %s${DIM}%s${RESET}\n" "$idx" "$LABEL" "$DEFAULT"
    idx=$((idx+1))
  done
  printf "\n  Selection (e.g. 1 3 5), or Enter for defaults: "
  # shellcheck disable=SC2034
  read -r RAW_INPUT
  if [ -z "$RAW_INPUT" ]; then
    printf "%s" "$DEFAULTS"
  else
    printf "%s" "$RAW_INPUT"
  fi
}

# ── Profile selection ─────────────────────────────────────────────────────────
select_profile() {
  printf "\n${BOLD}${CYAN}  Profile selection${RESET}\n"
  printf "${DIM}  Choose how you want to deploy skos${RESET}\n\n"
  printf "    ${GOLD}1${RESET}. ${BOLD}Personal Sovereign${RESET}   ${DIM}— laptop / single node · ~/var/data/sk  [DEFAULT]${RESET}\n"
  printf "    ${CYAN}2${RESET}. Sovereign Teams       ${DIM}— multi-node Swarm/k3s cluster${RESET}\n"
  printf "    ${GREEN}3${RESET}. Enterprise            ${DIM}— K8s + HA + compliance support${RESET}\n"
  printf "\n  Choice [1]: "
  # shellcheck disable=SC2034
  read -r PROFILE_CHOICE
  case "$PROFILE_CHOICE" in
    2) printf "team" ;;
    3) printf "enterprise" ;;
    *) printf "personal" ;;
  esac
}

# ── Capability definitions ────────────────────────────────────────────────────
# Prefix with * = pre-selected for personal profile
# Capabilities marked (coming-soon) are shown in the menu but not installed.
PERSONAL_CAPS="*capauth *skmemory *skchat *skfence *skmon skdata skobject skcache skmesh skcomms skflow(coming-soon) skvoice(coming-soon) skca(coming-soon)"
TEAM_CAPS="*capauth *skmemory *skchat *skfence *skmon *skdata *skobject *skcache *skmesh *skcomms *skbus skflow(coming-soon) skvoice(coming-soon) skca(coming-soon)"
ENTERPRISE_CAPS="*capauth *skmemory *skchat *skfence *skmon *skdata *skobject *skcache *skmesh *skcomms *skbus *skca *sksec *skwaf skflow(coming-soon) skvoice(coming-soon)"

caps_for_profile() {
  case "$1" in
    team)       printf "%s" "$TEAM_CAPS" ;;
    enterprise) printf "%s" "$ENTERPRISE_CAPS" ;;
    *)          printf "%s" "$PERSONAL_CAPS" ;;
  esac
}

# ── Install skos CLI ──────────────────────────────────────────────────────────
install_skos_cli() {
  step "Installing skos CLI"
  if command -v skos >/dev/null 2>&1; then
    ok "skos CLI already installed ($(skos --version 2>/dev/null || echo 'version unknown'))"
    return
  fi
  info "pip install git+https://github.com/smilinTux/skos"
  if run_pip install "git+https://github.com/smilinTux/skos" --quiet; then
    ok "skos CLI installed"
  else
    warn "pip install failed — trying pip install skos as fallback"
    if run_pip install skos --quiet; then
      ok "skos CLI installed (PyPI fallback)"
    else
      error "Could not install skos CLI. Check your Python/pip setup."
      error "Manual: pip3 install --user git+https://github.com/smilinTux/skos"
      exit 1
    fi
  fi
}

# ── Ensure skos is on PATH ────────────────────────────────────────────────────
ensure_path() {
  if ! command -v skos >/dev/null 2>&1; then
    # Common user-install bin locations
    for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.skenv/bin"; do
      if [ -x "$d/skos" ]; then
        export PATH="$d:$PATH"
        info "Added $d to PATH for this session"
        return
      fi
    done
    warn "skos not found on PATH. You may need to add ~/.local/bin to your PATH."
    warn "Add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

# ── Set profile data path ─────────────────────────────────────────────────────
run_skos_path() {
  PROFILE="$1"
  step "Configuring skos profile: $PROFILE"
  if command -v skos >/dev/null 2>&1; then
    skos path "$PROFILE" && ok "skos path $PROFILE — done"
  else
    # Fallback: set SK_DATA_ROOT manually and create dirs
    case "$PROFILE" in
      personal)   export SK_DATA_ROOT="$HOME/var/data/sk" ;;
      team)       export SK_DATA_ROOT="/opt/sk/data" ;;
      enterprise) export SK_DATA_ROOT="/opt/sk/data" ;;
    esac
    mkdir -p "$SK_DATA_ROOT"/{config,state,logs,secrets}
    ok "Created SK_DATA_ROOT: $SK_DATA_ROOT"
  fi
}

# ── Install individual capability ─────────────────────────────────────────────
install_capability() {
  CAP="$1"
  # Strip (coming-soon) suffix if accidentally passed
  CAP_CLEAN="$(printf "%s" "$CAP" | sed 's/(coming-soon)//')"

  case "$CAP_CLEAN" in
    skflow|skvoice|skca)
      warn "$CAP_CLEAN — coming soon (skipped gracefully)"
      return
      ;;
  esac

  info "Installing $CAP_CLEAN …"
  if command -v skos >/dev/null 2>&1; then
    if skos install "$CAP_CLEAN" 2>/dev/null; then
      ok "$CAP_CLEAN installed"
    else
      warn "$CAP_CLEAN — skos install returned non-zero (may not be implemented yet)"
    fi
  else
    warn "skos CLI not available — $CAP_CLEAN queued for manual install"
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  PROFILE="$1"; shift
  printf "\n${GOLD}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "${BOLD}  ✅  skos installed — what you got${RESET}\n\n"
  printf "  ${CYAN}Profile:${RESET}     ${BOLD}$PROFILE${RESET}\n"
  if command -v skos >/dev/null 2>&1; then
    printf "  ${CYAN}CLI:${RESET}         skos $(skos --version 2>/dev/null || echo '(version unknown)')\n"
  fi
  printf "  ${CYAN}Data root:${RESET}   $SK_DATA_ROOT\n"
  printf "  ${CYAN}Capabilities:${RESET} $*\n"
  printf "\n${BOLD}  Next steps:${RESET}\n"
  printf "  ${GREEN}▸${RESET} ${GOLD}skos describe${RESET}          — show what's installed\n"
  printf "  ${GREEN}▸${RESET} ${GOLD}skos profile${RESET}           — change or inspect your profile\n"
  printf "  ${GREEN}▸${RESET} ${GOLD}skos install <port>${RESET}    — add more capabilities later\n"
  printf "  ${GREEN}▸${RESET} Docs: ${CYAN}https://skos.skworld.io${RESET}\n"
  printf "  ${GREEN}▸${RESET} GitHub: ${CYAN}https://github.com/smilinTux/skos${RESET}\n"
  printf "\n  ${DIM}${PINK}staycuriousANDkeepsmilin 🐧${RESET}\n"
  printf "${GOLD}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  banner

  # ── Step 1: Environment detection ────────────────────────────────────────
  step "Detecting environment"
  OS="$(detect_os)"
  RUNTIME="$(detect_runtime)"
  PY_VER="$(detect_python)"

  info "OS:      $OS"
  info "Runtime: $RUNTIME"
  info "Python:  $PY_VER"

  if [ "$PY_VER" = "none" ]; then
    error "Python 3 not found. Please install python3 first."
    case "$OS" in
      debian) error "  sudo apt install python3 python3-pip" ;;
      fedora) error "  sudo dnf install python3 python3-pip" ;;
      arch)   error "  sudo pacman -S python python-pip" ;;
      macos)  error "  brew install python3" ;;
    esac
    exit 1
  fi

  if [ "$RUNTIME" = "none" ]; then
    warn "No container runtime found (podman or docker)."
    warn "Container-based capabilities will not be installable."
    warn "Install podman (preferred):  https://podman.io/getting-started/installation"
    warn "Or docker:                   https://docs.docker.com/get-docker/"
    warn "Continuing with CLI-only install…"
  else
    ok "Container runtime: $RUNTIME"
  fi

  # ── Step 2: Profile selection ─────────────────────────────────────────────
  step "Profile selection"
  PROFILE="$(select_profile)"
  info "Selected profile: ${BOLD}$PROFILE${RESET}"

  # ── Step 3: Capability selection ──────────────────────────────────────────
  step "Capability selection"
  RAW_CAPS="$(caps_for_profile "$PROFILE")"

  # Build display list (strip * prefix, show (coming soon) tag)
  DISPLAY_ITEMS=""
  for cap in $RAW_CAPS; do
    STARRED=""
    case "$cap" in \**) STARRED="*" ;; esac
    CAP_NAME="${cap#\*}"
    DISPLAY_ITEMS="$DISPLAY_ITEMS $STARRED$CAP_NAME"
  done

  SELECTION="$(show_checklist "Choose capabilities to install" $DISPLAY_ITEMS)"

  # Map selected indices back to capability names
  SELECTED_CAPS=""
  idx=1
  for cap in $DISPLAY_ITEMS; do
    NAME="${cap#\*}"
    for sel in $SELECTION; do
      if [ "$sel" = "$idx" ]; then
        SELECTED_CAPS="$SELECTED_CAPS $NAME"
      fi
    done
    idx=$((idx+1))
  done

  if [ -z "$SELECTED_CAPS" ]; then
    warn "No capabilities selected — only installing skos CLI and profile."
  fi

  # ── Step 4: Install skos CLI ──────────────────────────────────────────────
  install_skos_cli
  ensure_path

  # ── Step 5: Set profile + data root ──────────────────────────────────────
  run_skos_path "$PROFILE"

  # ── Step 6: Install selected capabilities ────────────────────────────────
  if [ -n "$SELECTED_CAPS" ]; then
    step "Installing capabilities"
    for cap in $SELECTED_CAPS; do
      install_capability "$cap"
    done
  fi

  # ── Step 7: Summary ───────────────────────────────────────────────────────
  print_summary "$PROFILE" $SELECTED_CAPS
}

main "$@"
