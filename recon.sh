#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#   T R E C O N   ·   Termux Recon Suite   ·   v4.0
#   Interactive · Clean-screen · Result preview
# ============================================================

set -o pipefail

# ─────────────── TERMINAL ───────────────
if [[ -t 1 ]]; then
  IS_TTY=1
  R="\033[1;31m"; G="\033[1;32m"; Y="\033[1;33m"
  B="\033[1;34m"; M="\033[1;35m"; C="\033[1;36m"
  W="\033[1;37m"; D="\033[2m";    N="\033[0m"
else
  IS_TTY=0
  R=""; G=""; Y=""; B=""; M=""; C=""; W=""; D=""; N=""
fi

# ─────────────── CONFIG ───────────────
TARGET=""
OUTDIR=""
THREADS=50
SKIP_SECRETS=0
INSTALL_ONLY=0
VERBOSE=0
PREVIEW_COUNT=15
TOOLS_DIR="$HOME/.trecon"
SECRETFINDER_DIR="$TOOLS_DIR/SecretFinder"
LOG="$TOOLS_DIR/trecon.log"

# ─────────────── BOOTSTRAP ───────────────
safe_mkdir() {
  [[ -d "$1" ]] && return 0
  mkdir -p "$1" 2>/dev/null || { printf '[FATAL] Cannot create %s\n' "$1" >&2; exit 1; }
}
safe_mkdir "$TOOLS_DIR"
[[ -f "$LOG" ]] || : > "$LOG" 2>/dev/null || { printf '[FATAL] Cannot create log %s\n' "$LOG" >&2; exit 1; }

# ─────────────── PRINT HELPERS ───────────────
tprint()  { [[ $IS_TTY -eq 1 ]] && printf '%b' "$*" >&2 || printf '%s' "$*" >&2; }
tline()   { [[ $IS_TTY -eq 1 ]] && printf '%b\n' "$*" >&2 || printf '%s\n' "$*" >&2; }
logline() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

ok()   { tline "${G}  [+]${N} $*"; logline "OK   $*"; }
info() { tline "${B}  [*]${N} $*"; logline "INFO $*"; }
warn() { tline "${Y}  [!]${N} $*"; logline "WARN $*"; }
err()  { tline "${R}  [x]${N} $*"; logline "ERR  $*"; }

clear_screen() { [[ $IS_TTY -eq 1 ]] && printf '\033[2J\033[H' >&2; }

section() {
  tline ""
  tline "${B}+----------------------------------------------+${N}"
  tline "${B}|${N}  ${W}$1${N}"
  tline "${B}+----------------------------------------------+${N}"
}

stage() {
  tline ""
  tline "${C}>> ${W}$1${N}"
  tline "${D}   $2${N}"
}

die() {
  err "$1"
  tline ""
  tline "${R}   Aborting. See log: ${D}$LOG${N}"
  tline ""
  exit 1
}

# ─────────────── SPINNER ───────────────
SPIN_FRAMES=('|' '/' '-' '\')
SPIN_PID=""

spin_start() {
  local msg="$1"
  [[ $IS_TTY -eq 0 ]] && { info "$msg"; return; }
  (
    local i=0
    while :; do
      printf '\r%b  [%s]%b %s ' "$B" "${SPIN_FRAMES[$((i % 4))]}" "$N" "$msg" >&2
      i=$((i + 1)); sleep 0.15
    done
  ) &
  SPIN_PID=$!
}

spin_stop() {
  local status="$1" msg="$2"
  if [[ -n "$SPIN_PID" ]]; then
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    [[ $IS_TTY -eq 1 ]] && printf '\r\033[K' >&2
  fi
  case "$status" in
    ok)   ok   "$msg" ;;
    warn) warn "$msg" ;;
    *)    err  "$msg" ;;
  esac
}

progress_bar() {
  local current="$1" total="$2" label="${3:-}"
  [[ $IS_TTY -eq 0 ]] && return
  (( total == 0 )) && return
  local width=30
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar="" i
  for ((i=0; i<filled; i++)); do bar="${bar}#"; done
  for ((i=0; i<empty;  i++)); do bar="${bar}."; done
  printf '\r%b  [%s]%b %3d%% %s' "$C" "$bar" "$N" "$((current * 100 / total))" "$label" >&2
}

# ─────────────── UTILS ───────────────
is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_quiet() {
  if (( VERBOSE )); then "$@"; else "$@" >> "$LOG" 2>&1; fi
}

# ─────────────── INTERACTIVE PROMPT ───────────────
prompt_target() {
  clear_screen
  tline "${C}"
  tline "  _____ ____  _____ ____ ___  _   _ "
  tline " |_   _|  _ \\| ____/ ___/ _ \\| \\ | |"
  tline "   | | | |_) |  _|| |  | | | |  \\| |"
  tline "   | | |  _ <| |__| |__| |_| | |\\  |"
  tline "   |_| |_| \\_\\_____\\____\\___/|_| \\_|"
  tline "${N}"
  tline "${D}   Termux Recon Suite  ·  v4.0${N}"
  tline "${M}   ---------------------------------------------${N}"
  tline ""
  tline "${W}   Enter target domain (e.g. example.com):${N}"
  tprint "${C}   > ${N}"
  read -r TARGET
  TARGET="$(printf '%s' "$TARGET" | tr -d '[:space:]')"
  [[ -z "$TARGET" ]] && die "No target entered."
  # Strip protocol if pasted
  TARGET="${TARGET#http://}"
  TARGET="${TARGET#https://}"
  TARGET="${TARGET%%/*}"
  [[ "$TARGET" == *.* ]] || die "Invalid domain: $TARGET"
}

prompt_threads() {
  tline ""
  tline "${W}   Threads for httpx (default 50):${N}"
  tprint "${C}   > ${N}"
  read -r input
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  [[ -z "$input" ]] && { THREADS=50; return 0; }
  is_uint "$input" || die "Threads must be a number."
  THREADS="$input"
}

prompt_secrets() {
  tline ""
  tline "${W}   Enable secret scanning? Slower but finds API keys.${N}"
  tline "${D}   [y] Yes   [n] No  (default: n)${N}"
  tprint "${C}   > ${N}"
  read -r input
  case "${input,,}" in
    y|yes) SKIP_SECRETS=0 ;;
    *)     SKIP_SECRETS=1 ;;
  esac
}

# ─────────────── ARG PARSING (still supported for power users) ───────────────
usage() {
  clear_screen
  tline "${W}USAGE${N}"
  tline "  ${C}trecon${N}                       (interactive mode)"
  tline "  ${C}trecon${N} <domain> [options]    (fast mode)"
  tline ""
  tline "${W}OPTIONS${N}"
  tline "  ${C}-o, --output${N} <dir>     Custom output directory"
  tline "  ${C}-t, --threads${N} <n>      Threads (default: 50)"
  tline "  ${C}--no-secrets${N}           Skip SecretFinder stage"
  tline "  ${C}--install-only${N}         Install dependencies and exit"
  tline "  ${C}-v, --verbose${N}          Show raw command output"
  tline "  ${C}-h, --help${N}             Show this help"
  tline ""
  exit 0
}

INTERACTIVE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage ;;
    -o|--output)    [[ -z "${2:-}" ]] && die "-o needs a value"; OUTDIR="$2"; shift 2 ;;
    -t|--threads)   [[ -z "${2:-}" ]] && die "-t needs a value"; THREADS="$2"; shift 2 ;;
    -v|--verbose)   VERBOSE=1; shift ;;
    --no-secrets)   SKIP_SECRETS=1; shift ;;
    --install-only) INSTALL_ONLY=1; INTERACTIVE=0; shift ;;
    -*)             die "Unknown option: $1" ;;
    *)              if [[ -z "$TARGET" ]]; then TARGET="$1"; INTERACTIVE=0; else die "Multiple targets not supported."; fi
                    shift ;;
  esac
done

# ─────────────── ENV CHECKS ───────────────
require_termux() { [[ -d /data/data/com.termux ]] || warn "Not running inside Termux - continuing anyway."; }
check_pkg_manager() { have_cmd pkg || die "pkg not found. This tool requires Termux."; }

check_disk() {
  local kb mb
  kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  is_uint "$kb" || kb=$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  if ! is_uint "$kb"; then warn "Could not read free disk space."; return 0; fi
  mb=$((kb / 1024))
  (( mb < 500 )) && die "Low disk space: ${mb}MB free (need 500MB)."
  ok "Disk space: ${mb}MB free"
}

check_network() {
  stage "Connectivity" "Verifying internet access..."
  spin_start "Checking network"
  local online=0
  if have_cmd curl && timeout 6 curl -fs --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null; then online=1; fi
  if (( online == 0 )) && have_cmd ping && timeout 6 ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then online=1; fi
  if (( online == 0 )) && have_cmd wget && timeout 6 wget -q --timeout=5 -O /dev/null https://1.1.1.1 2>/dev/null; then online=1; fi
  if (( online == 1 )); then spin_stop ok "Internet reachable"
  else spin_stop err "No internet"; die "No internet connection."; fi
}

# ─────────────── INSTALLERS ───────────────
pkg_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then ok "Packages present: $*"; return 0; fi
  info "Missing: ${missing[*]}"
  spin_start "Installing ${#missing[@]} package(s)"
  if run_quiet pkg install -y "${missing[@]}"; then
    spin_stop ok "Installed: ${missing[*]}"
  else
    spin_stop err "pkg install failed"
    die "Install failed."
  fi
}

ensure_path() {
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOBIN="${GOBIN:-$PREFIX/bin}"
  case ":$PATH:" in
    *":$GOBIN:"*) ;;
    *) export PATH="$PATH:$GOBIN:$GOPATH/bin" ;;
  esac
}

go_install() {
  local bin="$1" pkg="$2"
  if have_cmd "$bin"; then ok "$bin already installed"; return 0; fi
  spin_start "go install $bin"
  if run_quiet go install "$pkg"; then
    hash -r 2>/dev/null
    if have_cmd "$bin"; then spin_stop ok "$bin installed"; return 0; fi
    spin_stop warn "$bin not on PATH"
    return 1
  fi
  spin_stop warn "go install failed for $bin"
  return 1
}

install_requirements() {
  clear_screen
  section "DEPENDENCY CHECK"

  stage "Base packages" "git, python, curl, golang"
  pkg_install git python curl golang

  stage "Go toolchain" "Verifying Go environment"
  ensure_path
  go version >/dev/null 2>&1 || die "Go not functional."
  ok "Go: $(go version | awk '{print $3}')"

  stage "Recon tools" "subfinder, httpx, katana, waybackurls"
  go_install subfinder "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" || true
  go_install httpx     "github.com/projectdiscovery/httpx/cmd/httpx@latest"             || true
  go_install katana    "github.com/projectdiscovery/katana/cmd/katana@latest"           || true
  go_install waybackurls "github.com/tomnomnom/waybackurls@latest"                     || true

  if (( SKIP_SECRETS == 0 )); then
    stage "SecretFinder" "Python-based JS scanner"
    if [[ ! -d "$SECRETFINDER_DIR/.git" ]]; then
      rm -rf "$SECRETFINDER_DIR" 2>/dev/null
      spin_start "Cloning SecretFinder"
      if run_quiet git clone --depth 1 https://github.com/m4ll0k/SecretFinder.git "$SECRETFINDER_DIR"; then
        spin_stop ok "SecretFinder cloned"
      else
        spin_stop warn "Clone failed - disabling secrets"
        SKIP_SECRETS=1
      fi
    else
      ok "SecretFinder present"
    fi
    if (( SKIP_SECRETS == 0 )); then
      spin_start "Python deps"
      python -c "import requests"     >/dev/null 2>&1 || pip install -q requests     >> "$LOG" 2>&1 || warn "requests install failed"
      python -c "import jsbeautifier" >/dev/null 2>&1 || pip install -q jsbeautifier >> "$LOG" 2>&1 || warn "jsbeautifier install failed"
      spin_stop ok "Python deps ready"
    fi
  fi
}

# ─────────────── OUTPUT ───────────────
init_output() {
  [[ -z "$OUTDIR" ]] && OUTDIR="recon_${TARGET}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUTDIR" || die "Cannot create output dir: $OUTDIR"
  : > "$OUTDIR/subs.txt"
  : > "$OUTDIR/live.txt"
  : > "$OUTDIR/urls.txt"
  : > "$OUTDIR/crawled.txt"
  : > "$OUTDIR/secrets.txt"
  ok "Output dir: $OUTDIR"
}

count_lines() {
  if [[ -f "$1" ]]; then wc -l < "$1" 2>/dev/null | tr -d ' '; else echo 0; fi
}

# ─────────────── STAGES ───────────────
stage_subfinder() {
  clear_screen
  section "STEP 1 / 5 - SUBDOMAIN ENUMERATION"
  local out="$OUTDIR/subs.txt"
  if ! have_cmd subfinder; then warn "subfinder missing - using target only"; echo "$TARGET" > "$out"; return 0; fi
  spin_start "Running subfinder on $TARGET"
  run_quiet subfinder -d "$TARGET" -silent -all -o "$out" && spin_stop ok "subfinder finished" || spin_stop warn "subfinder issue"
  echo "$TARGET" >> "$out"
  sort -u "$out" -o "$out" 2>/dev/null || true
  info "Subdomains found: $(count_lines "$out")"
}

stage_httpx() {
  clear_screen
  section "STEP 2 / 5 - LIVE HOST PROBING"
  local out="$OUTDIR/live.txt"
  if ! have_cmd httpx; then warn "httpx missing - skipping"; return 0; fi
  if [[ ! -s "$OUTDIR/subs.txt" ]]; then warn "No subdomains"; return 0; fi
  info "Probing $(count_lines "$OUTDIR/subs.txt") hosts with httpx"
  spin_start "Running httpx (may take a minute)"
  if httpx -silent -threads "$THREADS" -timeout 8 -retries 2 \
        -title -status-code -tech-detect -o "$out" \
        < "$OUTDIR/subs.txt" >> "$LOG" 2>&1; then
    spin_stop ok "httpx finished"
  else
    spin_stop warn "httpx partial failure"
  fi
  info "Live hosts: $(count_lines "$out")"
}

stage_wayback() {
  clear_screen
  section "STEP 3 / 5 - HISTORICAL URL HARVEST"
  local out="$OUTDIR/urls.txt"
  if ! have_cmd waybackurls; then warn "waybackurls missing - skipping"; return 0; fi
  spin_start "Harvesting URLs from Wayback Machine"
  if cat "$OUTDIR/subs.txt" | waybackurls 2>> "$LOG" | sort -u > "$out"; then
    spin_stop ok "waybackurls finished"
  else
    spin_stop warn "waybackurls issue"
  fi
  info "URLs harvested: $(count_lines "$out")"
}

stage_katana() {
  clear_screen
  section "STEP 4 / 5 - CRAWLING LIVE HOSTS"
  local out="$OUTDIR/crawled.txt"
  if ! have_cmd katana; then
    warn "katana missing - skipping crawl"
    warn "Fix: pkg install golang && go install github.com/projectdiscovery/katana/cmd/katana@latest"
    return 0
  fi
  if [[ ! -s "$OUTDIR/live.txt" ]]; then warn "No live hosts to crawl"; return 0; fi
  spin_start "Crawling with katana (depth 3)"
  if awk '{print $1}' "$OUTDIR/live.txt" \
        | katana -silent -d 3 -jc -kf all -o "$out" >> "$LOG" 2>&1; then
    spin_stop ok "katana finished"
  else
    spin_stop warn "katana partial failure"
  fi
  info "Crawled endpoints: $(count_lines "$out")"
}

stage_secrets() {
  clear_screen
  section "STEP 5 / 5 - SECRET SCANNING"
  local out="$OUTDIR/secrets.txt"
  if (( SKIP_SECRETS == 1 )); then warn "Skipped (disabled)"; return 0; fi
  if [[ ! -f "$SECRETFINDER_DIR/SecretFinder.py" ]]; then warn "SecretFinder not installed - skipping"; return 0; fi

  cat "$OUTDIR/urls.txt" "$OUTDIR/crawled.txt" 2>/dev/null \
    | grep -Ei '\.js(\?|$)' | sort -u > "$OUTDIR/js_endpoints.txt" || true

  local total; total=$(count_lines "$OUTDIR/js_endpoints.txt")
  if (( total == 0 )); then warn "No JS endpoints found"; return 0; fi

  info "Scanning $total JS files"
  local i=0 url
  while IFS= read -r url; do
    ((i++))
    progress_bar "$i" "$total" "scanning JS files"
    python "$SECRETFINDER_DIR/SecretFinder.py" -i "$url" -o cli 2>/dev/null \
      | grep -v '^$' >> "$out" || true
  done < "$OUTDIR/js_endpoints.txt"
  [[ $IS_TTY -eq 1 ]] && printf '\r\033[K' >&2
  info "Potential secrets: $(count_lines "$out")"
}

# ─────────────── PREVIEW RESULTS ───────────────
preview_file() {
  local file="$1" title="$2" color="$3"
  local total; total=$(count_lines "$file")
  tline ""
  tline "${color}--- $title ($total) ---${N}"
  if (( total == 0 )); then
    tline "${D}   (none)${N}"
    return
  fi
  head -n "$PREVIEW_COUNT" "$file" | while IFS= read -r line; do
    tline "${D}   ${line}${N}"
  done
  if (( total > PREVIEW_COUNT )); then
    tline "${D}   ... and $((total - PREVIEW_COUNT)) more in $file${N}"
  fi
}

show_results() {
  clear_screen
  section "RESULTS FOR $TARGET"

  preview_file "$OUTDIR/live.txt"    "LIVE HOSTS"        "$G"
  preview_file "$OUTDIR/subs.txt"    "SUBDOMAINS"        "$C"

  if [[ -s "$OUTDIR/urls.txt" ]]; then
    preview_file "$OUTDIR/urls.txt"  "WAYBACK URLS"      "$B"
  fi
  if [[ -s "$OUTDIR/crawled.txt" ]]; then
    preview_file "$OUTDIR/crawled.txt" "CRAWLED ENDPOINTS" "$B"
  fi
  if (( SKIP_SECRETS == 0 )) && [[ -s "$OUTDIR/secrets.txt" ]]; then
    preview_file "$OUTDIR/secrets.txt" "POTENTIAL SECRETS" "$M"
  fi
}

# ─────────────── SUMMARY ───────────────
summary() {
  section "SUMMARY"
  local s l u c k
  s=$(count_lines "$OUTDIR/subs.txt")
  l=$(count_lines "$OUTDIR/live.txt")
  u=$(count_lines "$OUTDIR/urls.txt")
  c=$(count_lines "$OUTDIR/crawled.txt")
  k=$(count_lines "$OUTDIR/secrets.txt")
  tline "  Subdomains:          ${C}${s}${N}"
  tline "  Live hosts:          ${C}${l}${N}"
  tline "  Wayback URLs:        ${C}${u}${N}"
  tline "  Crawled endpoints:   ${C}${c}${N}"
  tline "  Potential secrets:   ${M}${k}${N}"
  tline ""
  tline "  ${W}How to view the files:${N}"
  tline "    ${G}cd $OUTDIR${N}"
  tline "    ${G}cat live.txt${N}        # Live hosts + tech stack"
  tline "    ${G}cat subs.txt${N}        # All subdomains"
  tline "    ${G}cat urls.txt${N}        # Historical URLs"
  if [[ -s "$OUTDIR/crawled.txt" ]]; then
    tline "    ${G}cat crawled.txt${N}     # Endpoints from crawling"
  fi
  if [[ -s "$OUTDIR/secrets.txt" ]]; then
    tline "    ${G}cat secrets.txt${N}     # Possible API keys"
  fi
  tline ""
  tline "  ${D}Full log: $LOG${N}"
}

# ─────────────── MAIN ───────────────
main() {
  clear_screen

  # Interactive target prompt if no args given
  if (( INTERACTIVE == 1 && INSTALL_ONLY == 0 )); then
    prompt_target
    prompt_threads
    prompt_secrets
    clear_screen
  fi

  section "TARGET: $TARGET"
  require_termux
  check_pkg_manager
  check_disk
  check_network

  install_requirements

  if (( INSTALL_ONLY == 1 )); then
    section "INSTALL COMPLETE"
    ok "All dependencies ready."
    info "Run: trecon   (interactive mode)"
    tline ""
    exit 0
  fi

  [[ -z "$TARGET" ]] && die "No target specified."
  init_output

  local start end
  start=$(date +%s)

  stage_subfinder
  stage_httpx
  stage_wayback
  stage_katana
  stage_secrets

  end=$(date +%s)

  # Results preview
  show_results

  # Summary + how-to
  summary
  tline ""
  ok "Recon complete in $((end - start)) seconds."
  tline ""
}

main "$@"
