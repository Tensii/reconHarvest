#!/usr/bin/env bash
#
# reconHarvest.sh (Kali-friendly + resumable + report-heavy)
# Generates workspace + run_commands.sh always.
#
# Usage:
#   ./reconHarvest.sh <target>
#   ./reconHarvest.sh --run <target>
#   ./reconHarvest.sh [-o <name>] [--parallel <n>] [--run] [--skip-nuclei] <target>
#   ./reconHarvest.sh --resume <workdir> [--run]
#
set -Eeuo pipefail

usage() {
  cat <<'EOL'
Usage:
  ./reconHarvest.sh <target>
  ./reconHarvest.sh --run <target>
  ./reconHarvest.sh [-o <name>] [--parallel <n>] [--run] [--skip-nuclei] <target>
  ./reconHarvest.sh [--overwrite|--auto-suffix] [-o <name>] <target>
  ./reconHarvest.sh --resume <workdir> [--run]

Notes:
  - Supported environment: bash on Kali/Debian-like Linux
  - Workspaces: outputs/<target>/<run-name>/
  - Default run names are sequential numbers: 1, 2, 3, ...
  - Use -o/--output to set a custom run name
  - SecLists is required and will be installed before recon continues
  - --resume expects that folder path
  - --run executes the recon pipeline immediately
  - --skip-nuclei skips nuclei phases
  - --nuclei-severity / --nuclei-tags override default phase1 filters
  - --overwrite allows reusing existing -o output folder
  - --auto-suffix appends -2/-3 if chosen output folder exists

Examples:
  ./reconHarvest.sh example.com
  ./reconHarvest.sh --run example.com
  ./reconHarvest.sh -o initial-pass --run example.com
  ./reconHarvest.sh --parallel 80 --run localhost
  ./reconHarvest.sh --skip-nuclei --run example.com
  ./reconHarvest.sh --nuclei-severity critical --nuclei-tags cves --run example.com
  ./reconHarvest.sh --auto-suffix -o initial-pass --run example.com
  ./reconHarvest.sh --resume outputs/example.com/2 --run
EOL
}

usage_error() {
  usage
  exit 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_positive_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
is_valid_output_name() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]; }

# ---------- OS helpers ----------
is_kali_or_debian_like() {
  [[ -f /etc/os-release ]] || return 1
  grep -qiE 'kali|debian|ubuntu|parrot' /etc/os-release
}

require_sudo_if_needed() {
  if [[ $EUID -ne 0 ]]; then
    command_exists sudo || { echo "[!] sudo not found. Install sudo or run as root."; return 1; }
  fi
}

APT_UPDATED=0
apt_update_once() {
  [[ "$APT_UPDATED" -eq 1 ]] && return 0
  require_sudo_if_needed
  if command_exists sudo; then sudo apt-get update -y; else apt-get update -y; fi
  APT_UPDATED=1
}

apt_install() {
  apt_update_once
  if command_exists sudo; then sudo apt-get install -y "$@"; else apt-get install -y "$@"; fi
}

ensure_system_tool() {
  local binary="$1"
  local apt_pkg="${2:-$1}"
  command_exists "$binary" && return 0
  if is_kali_or_debian_like && command_exists apt-get; then
    echo "[*] Installing $binary via apt…"
    apt_install "$apt_pkg" >/dev/null 2>&1 || true
  fi
  command_exists "$binary" || { echo "[!] Required tool missing: $binary"; return 1; }
}

preflight_checks() {
  [[ -n "${BASH_VERSION:-}" ]] || { echo "[!] This script must be run with bash."; return 1; }
  is_kali_or_debian_like || echo "[!] Warning: this script is primarily supported on Kali/Debian-like Linux."

  local required_commands=(python3 grep sed awk sort xargs head find mktemp sha256sum)
  local cmd
  for cmd in "${required_commands[@]}"; do
    command_exists "$cmd" || { echo "[!] Required command missing: $cmd"; return 1; }
  done

  if [[ -n "${WORKDIR:-}" ]]; then
    mkdir -p "$WORKDIR" || { echo "[!] Failed to create workdir: $WORKDIR"; return 1; }
    : > "$WORKDIR/.write_test" || { echo "[!] Workdir is not writable: $WORKDIR"; return 1; }
    rm -f "$WORKDIR/.write_test"
  fi
}

# ---------- install helpers ----------
ensure_go_bin_path() {
  local gobin gopath
  if command_exists go; then
    gobin="$(go env GOBIN 2>/dev/null || true)"
    gopath="$(go env GOPATH 2>/dev/null || true)"
    if [[ -z "$gobin" && -n "$gopath" ]]; then
      gobin="$gopath/bin"
    fi
  fi
  [[ -z "$gobin" ]] && gobin="$HOME/go/bin"
  case ":$PATH:" in
    *":$gobin:"*) ;;
    *) export PATH="$gobin:$PATH" ;;
  esac
}

ensure_go() {
  command_exists go && { ensure_go_bin_path; return 0; }
  echo "[*] Installing Go via apt…"
  is_kali_or_debian_like && apt_install golang
  command_exists go || { echo "[!] Go not found. Install Go and ensure GOPATH/bin is in PATH."; return 1; }
  ensure_go_bin_path
}

ensure_pipx() {
  command_exists pipx && return 0
  echo "[*] Installing pipx (Kali-safe)…"
  if is_kali_or_debian_like; then
    apt_install pipx
  else
    echo "[!] Non-Debian system: install pipx manually + add ~/.local/bin to PATH."
    return 1
  fi
  export PATH="$HOME/.local/bin:$PATH"
  pipx ensurepath >/dev/null 2>&1 || true
  command_exists pipx || { echo "[!] pipx still not found after install."; return 1; }
}

ensure_seclists() {
  local base="/usr/share/seclists"
  local web_content="$base/Discovery/Web-Content"

  [[ -d "$web_content" ]] && return 0

  echo "[*] SecLists not found. Attempting installation…"

  if is_kali_or_debian_like && command_exists apt-get; then
    echo "[*] Trying apt install seclists…"
    apt_install seclists >/dev/null 2>&1 || true
    [[ -d "$web_content" ]] && return 0
  fi

  ensure_system_tool curl curl || return 1
  ensure_system_tool unzip unzip || return 1

  require_sudo_if_needed || return 1

  echo "[*] apt install did not provide SecLists. Downloading archive from GitHub…"
  local tmp_root tmp_zip tmp_extract
  tmp_root="$(mktemp -d)"
  tmp_zip="$tmp_root/seclists.zip"
  tmp_extract="$tmp_root/extracted"
  mkdir -p "$tmp_extract"

  if ! curl -L "https://github.com/danielmiessler/SecLists/archive/refs/heads/master.zip" -o "$tmp_zip"; then
    echo "[!] Failed to download SecLists from GitHub."
    rm -rf "$tmp_root"
    return 1
  fi

  if ! unzip -q "$tmp_zip" -d "$tmp_extract"; then
    echo "[!] Failed to extract SecLists archive."
    rm -rf "$tmp_root"
    return 1
  fi

  local extracted_dir
  extracted_dir="$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -name 'SecLists-*' | head -n 1)"
  [[ -n "${extracted_dir:-}" ]] || {
    echo "[!] Could not locate extracted SecLists directory."
    rm -rf "$tmp_root"
    return 1
  }

  if command_exists sudo; then
    sudo rm -rf "$base"
    sudo mkdir -p /usr/share
    sudo mv "$extracted_dir" "$base"
  else
    rm -rf "$base"
    mkdir -p /usr/share
    mv "$extracted_dir" "$base"
  fi

  rm -rf "$tmp_root"
  [[ -d "$web_content" ]] || {
    echo "[!] SecLists installation completed, but expected Web-Content directory is still missing."
    return 1
  }

  echo "[*] SecLists installed at $base"
}

# Robust dirsearch installer/repairer for pipx environments.
# Fixes: ModuleNotFoundError: pkg_resources (needs setuptools inside the pipx venv).
install_dirsearch_kali_safe() {
  ensure_pipx
  export PATH="$HOME/.local/bin:$PATH"

  # Helper: inject/upgrade setuptools (and wheel) inside the dirsearch pipx venv.
  # Uses runpip because it's more reliable than inject in some environments.
  _dirsearch_fix_venv() {
    # Best-effort, keep quiet unless something is really broken.
    pipx runpip dirsearch install -U setuptools wheel >/dev/null 2>&1 || true
    pipx inject dirsearch setuptools >/dev/null 2>&1 || true
  }

  if command_exists dirsearch; then
    # dirsearch exists — repair venv deps (pkg_resources) without noise.
    _dirsearch_fix_venv

    # Smoke test: ensure pkg_resources import works inside the venv environment.
    # If it still fails, recreate the venv.
    if ! dirsearch --help >/dev/null 2>&1; then
      echo "[!] dirsearch appears installed but broken. Recreating pipx venv…"
      pipx uninstall dirsearch >/dev/null 2>&1 || true
      pipx install dirsearch >/dev/null 2>&1 || pipx install dirsearch
      _dirsearch_fix_venv
    fi

    command_exists dirsearch || {
      echo "[!] dirsearch not found after repair. Try: export PATH=\$HOME/.local/bin:\$PATH"
      return 1
    }
    return 0
  fi

  echo "[*] Installing dirsearch via pipx (Kali-safe)…"
  if pipx list 2>/dev/null | grep -qi '^package dirsearch'; then
    pipx upgrade dirsearch >/dev/null 2>&1 || true
  else
    pipx install dirsearch >/dev/null 2>&1 || pipx install dirsearch
  fi

  # Ensure pkg_resources exists (setuptools) in the pipx venv
  _dirsearch_fix_venv

  # Validate it actually runs
  if ! dirsearch --help >/dev/null 2>&1; then
    echo "[!] dirsearch installed but not runnable. Recreating pipx venv…"
    pipx uninstall dirsearch >/dev/null 2>&1 || true
    pipx install dirsearch >/dev/null 2>&1 || pipx install dirsearch
    _dirsearch_fix_venv
  fi

  command_exists dirsearch || {
    echo "[!] dirsearch not found after pipx install. Try: export PATH=\$HOME/.local/bin:\$PATH"
    return 1
  }
  return 0
}

install_go_tool() {
  local binary="$1"
  shift
  command_exists "$binary" && return 0

  ensure_go
  echo "[*] Installing $binary…"
  set +e
  "$@"
  local rc=$?
  set -e

  local gopath
  gopath="$(go env GOPATH 2>/dev/null || true)"
  [[ -n "${gopath:-}" ]] && export PATH="$gopath/bin:$PATH"

  command_exists "$binary" && return 0

  if [[ $rc -ne 0 ]] && is_kali_or_debian_like && command_exists apt-get; then
    echo "[!] Go install for $binary failed. Trying apt fallback…"
    apt_install "$binary" >/dev/null 2>&1 || true
  fi

  command_exists "$binary" || { echo "[!] Failed to install $binary"; return 1; }
  return 0
}

resolve_go_tool() {
  local name="$1"
  local gobin gopath
  if command_exists go; then
    gobin="$(go env GOBIN 2>/dev/null || true)"
    if [[ -n "$gobin" && -x "$gobin/$name" ]]; then echo "$gobin/$name"; return 0; fi
    gopath="$(go env GOPATH 2>/dev/null || true)"
    if [[ -n "$gopath" && -x "$gopath/bin/$name" ]]; then echo "$gopath/bin/$name"; return 0; fi
  fi
  [[ -x "$HOME/go/bin/$name" ]] && { echo "$HOME/go/bin/$name"; return 0; }
  command -v "$name" 2>/dev/null || true
}

resolve_tool() { command -v "$1" 2>/dev/null || true; }

next_run_name() {
  local target_dir="$1"
  local max=0
  local path base

  [[ -d "$target_dir" ]] || {
    printf '1\n'
    return 0
  }

  for path in "$target_dir"/*; do
    [[ -d "$path" ]] || continue
    base="$(basename "$path")"
    if [[ "$base" =~ ^[0-9]+$ ]] && (( base > max )); then
      max="$base"
    fi
  done

  printf '%s\n' "$((max + 1))"
}


# ---------- args ----------
RESUME_MODE=0
DO_RUN=0
TARGET=""
WORKDIR=""
PARALLEL_OVERRIDE=""
OUTPUT_NAME=""
OVERWRITE_OUTPUT=0
AUTO_SUFFIX_OUTPUT=0
SKIP_NUCLEI=0
NUCLEI_SEV_OVERRIDE=""
NUCLEI_TAGS_OVERRIDE=""

if [[ $# -lt 1 ]]; then usage_error; fi

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --run) DO_RUN=1; shift ;;
    --skip-nuclei) SKIP_NUCLEI=1; shift ;;
    --nuclei-severity)
      [[ $# -ge 2 ]] || { echo "[!] --nuclei-severity requires a value."; usage_error; }
      [[ "${2:-}" != -* ]] || { echo "[!] --nuclei-severity requires a value, not another flag."; usage_error; }
      NUCLEI_SEV_OVERRIDE="${2:-}"
      shift 2
      ;;
    --nuclei-tags)
      [[ $# -ge 2 ]] || { echo "[!] --nuclei-tags requires a value."; usage_error; }
      [[ "${2:-}" != -* ]] || { echo "[!] --nuclei-tags requires a value, not another flag."; usage_error; }
      NUCLEI_TAGS_OVERRIDE="${2:-}"
      shift 2
      ;;
    --overwrite) OVERWRITE_OUTPUT=1; shift ;;
    --auto-suffix) AUTO_SUFFIX_OUTPUT=1; shift ;;
    -o|--output)
      [[ $RESUME_MODE -eq 0 ]] || { echo "[!] -o/--output cannot be used with --resume."; usage_error; }
      [[ $# -ge 2 ]] || { echo "[!] -o/--output requires a value."; usage_error; }
      [[ "${2:-}" != -* ]] || { echo "[!] -o/--output requires a name, not another flag."; usage_error; }
      OUTPUT_NAME="${2:-}"
      is_valid_output_name "$OUTPUT_NAME" || { echo "[!] Output name may contain only letters, numbers, dots, underscores, and hyphens."; usage_error; }
      shift 2
      ;;
    --parallel)
      [[ $# -ge 2 ]] || { echo "[!] --parallel requires a value."; usage_error; }
      [[ "${2:-}" != -* ]] || { echo "[!] --parallel requires a numeric value, not another flag."; usage_error; }
      PARALLEL_OVERRIDE="${2:-}"
      is_positive_int "$PARALLEL_OVERRIDE" || { echo "[!] --parallel must be a positive integer."; usage_error; }
      shift 2
      ;;
    --resume)
      [[ $RESUME_MODE -eq 0 ]] || { echo "[!] --resume specified more than once."; usage_error; }
      [[ -z "${TARGET:-}" ]] || { echo "[!] --resume cannot be combined with a target positional argument."; usage_error; }
      [[ $# -ge 2 ]] || { echo "[!] --resume requires a workdir."; usage_error; }
      [[ "${2:-}" != -* ]] || { echo "[!] --resume requires a workdir, not another flag."; usage_error; }
      RESUME_MODE=1
      WORKDIR="${2:-}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --*)
      echo "[!] Unknown flag: $1"
      usage_error
      ;;
    *)
      if [[ $RESUME_MODE -eq 1 ]]; then
        echo "[!] Extra positional argument not allowed with --resume: $1"
        usage_error
      fi
      if [[ -n "${TARGET:-}" ]]; then
        echo "[!] Extra positional argument: $1"
        usage_error
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

OUT_BASE="outputs"

if [[ $RESUME_MODE -eq 1 && $OVERWRITE_OUTPUT -eq 1 ]]; then
  echo "[!] --overwrite cannot be used with --resume."
  usage_error
fi
if [[ $RESUME_MODE -eq 1 && $AUTO_SUFFIX_OUTPUT -eq 1 ]]; then
  echo "[!] --auto-suffix cannot be used with --resume."
  usage_error
fi
if [[ $OVERWRITE_OUTPUT -eq 1 && $AUTO_SUFFIX_OUTPUT -eq 1 ]]; then
  echo "[!] Use either --overwrite or --auto-suffix, not both."
  usage_error
fi

if [[ $RESUME_MODE -eq 1 ]]; then
  [[ -d "$WORKDIR" ]] || { echo "[!] Resume folder not found: $WORKDIR"; exit 1; }
  if [[ -z "${TARGET:-}" ]]; then
    TARGET="$(basename "$(dirname "$WORKDIR")" 2>/dev/null || true)"
    [[ -n "${TARGET:-}" ]] || TARGET="${WORKDIR##*/}"
  fi
else
  [[ -n "${TARGET:-}" ]] || usage_error
  TARGET_DIR="$OUT_BASE/$TARGET"
  RUN_NAME="${OUTPUT_NAME:-$(next_run_name "$TARGET_DIR")}"
  WORKDIR="$TARGET_DIR/$RUN_NAME"

  if [[ -e "$WORKDIR" ]]; then
    if [[ $OVERWRITE_OUTPUT -eq 1 ]]; then
      echo "[*] Reusing existing output directory due to --overwrite: $WORKDIR"
    elif [[ $AUTO_SUFFIX_OUTPUT -eq 1 ]]; then
      base_name="$RUN_NAME"
      i=2
      while [[ -e "$TARGET_DIR/${base_name}-$i" ]]; do
        i=$((i+1))
      done
      RUN_NAME="${base_name}-$i"
      WORKDIR="$TARGET_DIR/$RUN_NAME"
      echo "[*] Output exists, using auto-suffixed directory: $WORKDIR"
      mkdir -p "$WORKDIR"
    else
      echo "[!] Output directory already exists: $WORKDIR"
      echo "    Use --overwrite to reuse it or --auto-suffix to create a new name."
      exit 1
    fi
  else
    mkdir -p "$WORKDIR"
  fi
fi

echo "[*] Working directory: $WORKDIR"
preflight_checks || exit 1
ensure_go_bin_path

# ---------- required datasets ----------
ensure_seclists || { echo "[!] SecLists is required and could not be installed."; exit 1; }

# ---------- tool install ----------
install_dirsearch_kali_safe
install_go_tool "ffuf"        go install github.com/ffuf/ffuf/v2@latest
install_go_tool "httpx"       go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
install_go_tool "subfinder"   go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
install_go_tool "assetfinder" go install github.com/tomnomnom/assetfinder@latest
install_go_tool "dnsx"        go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest
install_go_tool "katana"      go install -v github.com/projectdiscovery/katana/cmd/katana@latest
install_go_tool "gau"         go install github.com/lc/gau/v2/cmd/gau@latest
install_go_tool "nuclei"      go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest

FFUF_BIN="$(resolve_go_tool ffuf)"
HTTPX_BIN="$(resolve_go_tool httpx)"
SUBFINDER_BIN="$(resolve_go_tool subfinder)"
ASSETFINDER_BIN="$(resolve_go_tool assetfinder)"
DNSX_BIN="$(resolve_go_tool dnsx)"
KATANA_BIN="$(resolve_go_tool katana)"
GAU_BIN="$(resolve_go_tool gau)"
NUCLEI_BIN="$(resolve_go_tool nuclei)"
DIRSEARCH_BIN="$(resolve_tool dirsearch)"

# ---------- wordlists ----------
SECLISTS_BASE="/usr/share/seclists/Discovery/Web-Content"
RAFT_DIR="$SECLISTS_BASE/raft-medium-directories.txt"
RAFT_FILES="$SECLISTS_BASE/raft-medium-files.txt"
DIRLIST_MED="$SECLISTS_BASE/directory-list-2.3-medium.txt"
COMMON="$SECLISTS_BASE/common.txt"

FFUF_DIR_WORDLIST="$RAFT_DIR"; [[ -f "$FFUF_DIR_WORDLIST" ]] || FFUF_DIR_WORDLIST="$COMMON"
FFUF_FILE_WORDLIST="$RAFT_FILES"; [[ -f "$FFUF_FILE_WORDLIST" ]] || FFUF_FILE_WORDLIST="$COMMON"
DIRSEARCH_WORDLIST="$DIRLIST_MED"; [[ -f "$DIRSEARCH_WORDLIST" ]] || DIRSEARCH_WORDLIST="$COMMON"

[[ -f "$FFUF_DIR_WORDLIST" ]] || { echo "[!] Missing required SecLists wordlist: $FFUF_DIR_WORDLIST"; exit 1; }
[[ -f "$FFUF_FILE_WORDLIST" ]] || { echo "[!] Missing required SecLists wordlist: $FFUF_FILE_WORDLIST"; exit 1; }
[[ -f "$DIRSEARCH_WORDLIST" ]] || { echo "[!] Missing required SecLists wordlist: $DIRSEARCH_WORDLIST"; exit 1; }

STATE_DIR="$WORKDIR/.state"
mkdir -p "$STATE_DIR"

RUNFILE="$WORKDIR/run_commands.sh"
COMMANDS_MD="$WORKDIR/COMMANDS_USED.md"
STATUS_JSON="$WORKDIR/stage_status.jsonl"
ERRORS_JSON="$WORKDIR/errors.jsonl"

# ---------- generate run_commands.sh safely (literal heredoc) ----------
cat > "$RUNFILE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="__TARGET__"
WORKDIR="__WORKDIR__"
STATE_DIR="__STATE_DIR__"
COMMANDS_MD="__COMMANDS_MD__"
STATUS_JSON="__STATUS_JSON__"
ERRORS_JSON="__ERRORS_JSON__"

PARALLEL_OVERRIDE="__PARALLEL_OVERRIDE__"
SKIP_NUCLEI="__SKIP_NUCLEI__"
NUCLEI_SEV_OVERRIDE="__NUCLEI_SEV_OVERRIDE__"
NUCLEI_TAGS_OVERRIDE="__NUCLEI_TAGS_OVERRIDE__"

FFUF_BIN="__FFUF_BIN__"
HTTPX_BIN="__HTTPX_BIN__"
SUBFINDER_BIN="__SUBFINDER_BIN__"
ASSETFINDER_BIN="__ASSETFINDER_BIN__"
DNSX_BIN="__DNSX_BIN__"
KATANA_BIN="__KATANA_BIN__"
GAU_BIN="__GAU_BIN__"
NUCLEI_BIN="__NUCLEI_BIN__"
DIRSEARCH_BIN="__DIRSEARCH_BIN__"

FFUF_DIR_WORDLIST="__FFUF_DIR_WORDLIST__"
FFUF_FILE_WORDLIST="__FFUF_FILE_WORDLIST__"
DIRSEARCH_WORDLIST="__DIRSEARCH_WORDLIST__"

export PATH="$HOME/.local/bin:$PATH"
if command -v go >/dev/null 2>&1; then
  GOBIN="$(go env GOBIN 2>/dev/null || true)"
  if [[ -z "$GOBIN" ]]; then
    GOPATH="$(go env GOPATH 2>/dev/null || true)"
    [[ -n "$GOPATH" ]] && GOBIN="$GOPATH/bin"
  fi
  [[ -z "$GOBIN" ]] && GOBIN="$HOME/go/bin"
  case ":$PATH:" in
    *":$GOBIN:"*) ;;
    *) export PATH="$GOBIN:$PATH" ;;
  esac
fi

have_bin() {
  local b="${1:-}"
  [[ -n "$b" ]] || return 1
  if [[ "$b" == */* ]]; then [[ -x "$b" ]] && return 0; return 1; fi
  command -v "$b" >/dev/null 2>&1
}

is_positive_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

runner_preflight_checks() {
  local required_commands=(bash python3 sed sort xargs awk sha256sum timeout)
  local cmd
  for cmd in "${required_commands[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "[!] Required command missing in runner environment: $cmd"
      exit 1
    }
  done
}

safe_name_for_host() {
  local host="$1"
  local digest
  digest="$(printf '%s' "$host" | sha256sum | awk '{print substr($1,1,12)}')"
  host="$(printf '%s' "$host" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##')"
  host="$(printf '%s' "$host" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  host="${host#_}"
  host="${host%%_}"
  [[ -n "$host" ]] || host="host"
  printf '%s__%s\n' "$host" "$digest"
}

is_done() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { : > "$STATE_DIR/$1.done"; }

record_stage_status() {
  local stage="$1" status="$2" detail="${3:-}"
  python3 - "$STATUS_JSON" "$stage" "$status" "$detail" <<'PY' || true
import datetime, json, sys
path, stage, status, detail = sys.argv[1:5]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "stage": stage,
        "status": status,
        "detail": detail,
    }) + "\n")
PY
}

record_error() {
  local stage="$1" tool="$2" host="$3" message="$4"
  python3 - "$ERRORS_JSON" "$stage" "$tool" "$host" "$message" <<'PY' || true
import datetime, json, sys
path, stage, tool, host, message = sys.argv[1:6]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "stage": stage,
        "tool": tool,
        "host": host,
        "message": message,
    }) + "\n")
PY
}

log_cmd() {
  local label="$1"; shift
  local cmd="$*"
  {
    echo "## $label"
    echo
    echo '```bash'
    echo "$cmd"
    echo '```'
    echo
  } >> "$COMMANDS_MD"
}

run_cmd() {
  local label="$1"; shift
  local cmd="$*"
  log_cmd "$label" "$cmd"
  bash -lc "$cmd"
}

init_output_files() {
  local path
  for path in "$@"; do
    : > "$path"
  done
}

write_missing_log() {
  local message="$1"; shift
  local path
  for path in "$@"; do
    printf '%s\n' "$message" > "$path"
  done
}

normalize_dirsearch_reports() {
  python3 - "$WORKDIR" <<'PY' || true
import json, os, re, sys
workdir = sys.argv[1]
src_dir = os.path.join(workdir, "dirsearch")
out_path = os.path.join(workdir, "intel", "dirsearch_normalized.json")
os.makedirs(os.path.join(workdir, "intel"), exist_ok=True)
rows = []
if os.path.isdir(src_dir):
    for fn in sorted(os.listdir(src_dir)):
        if not fn.endswith(".txt"):
            continue
        path = os.path.join(src_dir, fn)
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = re.search(r'(?P<url>https?://\S+).*?\b(?P<status>[1-5][0-9]{2})\b', line)
                if not m:
                    m = re.search(r'(?P<status>[1-5][0-9]{2}).*?(?P<url>https?://\S+)', line)
                if not m:
                    continue
                rows.append({
                    "source_file": fn,
                    "url": m.group("url").rstrip(".,;"),
                    "status": m.group("status"),
                    "raw": line,
                })
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(rows, f, indent=2)
PY
}

mkdir -p "$WORKDIR/logs" "$WORKDIR/ffuf" "$WORKDIR/dirsearch" "$WORKDIR/urls" "$WORKDIR/intel" "$STATE_DIR"
: > "$COMMANDS_MD" 2>/dev/null || true
: > "$STATUS_JSON" 2>/dev/null || true
: > "$ERRORS_JSON" 2>/dev/null || true

runner_preflight_checks

PARALLEL="${PARALLEL_OVERRIDE:-30}"
if ! is_positive_int "$PARALLEL"; then
  echo "[!] Invalid PARALLEL value: $PARALLEL"
  exit 1
fi

NUCLEI_PHASE1_SEV="${NUCLEI_SEV_OVERRIDE:-high,critical}"
NUCLEI_PHASE1_TAGS="${NUCLEI_TAGS_OVERRIDE:-cves,misconfig,login,token-spray}"
NUCLEI_CONCURRENCY="${NUCLEI_CONCURRENCY:-50}"
NUCLEI_MAX_HOST_ERROR="${NUCLEI_MAX_HOST_ERROR:-100}"
PER_HOST_TIMEOUT_SEC="${PER_HOST_TIMEOUT_SEC:-300}"
BACKOFF_TRIGGER_FAILURES="${BACKOFF_TRIGGER_FAILURES:-25}"

echo "[*] Recon for $TARGET"
echo "[*] Output: $WORKDIR"
echo "[*] Parallel: $PARALLEL"

# 0) nuclei templates update (best-effort, once)
if ! is_done "nuclei_templates"; then
  if [[ "$SKIP_NUCLEI" == "1" ]]; then
    record_stage_status "nuclei_templates" "skipped" "skip-nuclei enabled"
  elif have_bin "$NUCLEI_BIN"; then
    echo "[*] Updating nuclei templates (best-effort)…"
    run_cmd "nuclei templates update" "\"$NUCLEI_BIN\" -update-templates -silent || true"
    record_stage_status "nuclei_templates" "completed" "templates update attempted"
  else
    record_stage_status "nuclei_templates" "skipped" "nuclei missing"
  fi
  mark_done "nuclei_templates"
fi

# 1) subdomains
if ! is_done "subdomains"; then
  echo "[*] Subdomain enumeration…"
  init_output_files "$WORKDIR/subfinder.txt" "$WORKDIR/assetfinder.txt" "$WORKDIR/all_subdomains.txt"

  if have_bin "$SUBFINDER_BIN"; then
    run_cmd "subfinder" "\"$SUBFINDER_BIN\" -d \"$TARGET\" -all -silent -o \"$WORKDIR/subfinder.txt\" || true"
  fi
  if have_bin "$ASSETFINDER_BIN"; then
    run_cmd "assetfinder" "\"$ASSETFINDER_BIN\" --subs-only \"$TARGET\" 2>/dev/null | sort -u > \"$WORKDIR/assetfinder.txt\" || true"
  fi

  cat "$WORKDIR/subfinder.txt" "$WORKDIR/assetfinder.txt" | sed '/^$/d' | sort -u > "$WORKDIR/all_subdomains.txt" || true
  record_stage_status "subdomains" "completed" "merged passive subdomain sources"
  mark_done "subdomains"
fi

# 2) dns resolve
if ! is_done "dnsx"; then
  echo "[*] DNS resolve…"
  init_output_files "$WORKDIR/resolved_subdomains.txt"
  if have_bin "$DNSX_BIN"; then
    DNSX_RAW="$WORKDIR/dnsx_raw.txt"
    init_output_files "$DNSX_RAW"
    run_cmd "dnsx" "\"$DNSX_BIN\" -l \"$WORKDIR/all_subdomains.txt\" -silent -o \"$DNSX_RAW\" || true"
    python3 - "$DNSX_RAW" "$WORKDIR/resolved_subdomains.txt" "$WORKDIR/intel/dns_host_ip_map.json" <<'PY' || true
import json, re, sys
raw_path, resolved_path, map_path = sys.argv[1:4]
hosts = []
mp = {}
try:
  with open(raw_path, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
      line=line.strip()
      if not line:
        continue
      # dnsx lines can be like:
      # sub.example.com [1.2.3.4]
      # sub.example.com A 1.2.3.4
      parts=line.split()
      host=parts[0].strip()
      if host:
        hosts.append(host)
      ips=set(re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', line))
      if host and ips:
        mp.setdefault(host, set()).update(ips)
except FileNotFoundError:
  pass
hosts=sorted(set(h for h in hosts if h))
with open(resolved_path, 'w', encoding='utf-8') as f:
  for h in hosts:
    f.write(h + '\n')
out={k: sorted(v) for k,v in sorted(mp.items())}
with open(map_path, 'w', encoding='utf-8') as f:
  json.dump(out, f, indent=2)
PY
    record_stage_status "dnsx" "completed" "dnsx resolution attempted (hostnames preserved)"
  else
    sed '/^$/d' "$WORKDIR/all_subdomains.txt" > "$WORKDIR/resolved_subdomains.txt" || true
    record_stage_status "dnsx" "fallback" "dnsx missing; copied subdomains as resolved hosts"
  fi
  mark_done "dnsx"
fi

# 3) http probe + tech json
if ! is_done "httpx"; then
  echo "[*] HTTP probing…"
  init_output_files "$WORKDIR/httpx_results.txt" "$WORKDIR/httpx_results.json" "$WORKDIR/live_hosts.txt"

  if have_bin "$HTTPX_BIN"; then
    run_cmd "httpx text" "\"$HTTPX_BIN\" -l \"$WORKDIR/resolved_subdomains.txt\" -silent -status-code -content-length -title -tech-detect -threads 200 -timeout 5 -retries 1 -o \"$WORKDIR/httpx_results.txt\" || true"
    run_cmd "httpx json" "\"$HTTPX_BIN\" -l \"$WORKDIR/resolved_subdomains.txt\" -silent -json -tech-detect -threads 200 -timeout 5 -retries 1 -o \"$WORKDIR/httpx_results.json\" || true"
    python3 - "$WORKDIR/httpx_results.json" "$WORKDIR/live_hosts.txt" <<'PY' || true
import json, sys
src, dst = sys.argv[1], sys.argv[2]
hosts = []
try:
    with open(src, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            status = obj.get("status_code")
            url = (obj.get("url") or obj.get("input") or "").strip()
            if url and status != 400:
                hosts.append(url)
except FileNotFoundError:
    pass
with open(dst, "w", encoding="utf-8") as f:
    for host in sorted(set(hosts)):
        f.write(host + "\n")
PY
    record_stage_status "httpx" "completed" "httpx probe attempted and live hosts derived from json"
  else
    sed '/^$/d' "$WORKDIR/resolved_subdomains.txt" > "$WORKDIR/live_hosts.txt" || true
    record_stage_status "httpx" "fallback" "httpx missing; reused resolved hosts"
  fi
  mark_done "httpx"
fi

# 4) per-host discovery
process_host_phase() {
  local HOST="$1"
  local PHASE="$2" # dirsearch|ffuf_dirs|ffuf_files
  [[ -z "$HOST" ]] && return 0
  local SAFE_NAME
  SAFE_NAME="$(safe_name_for_host "$HOST")"

  local DS_OUT="$WORKDIR/dirsearch/${SAFE_NAME}.txt"
  local FFUF_DIR_OUT="$WORKDIR/ffuf/${SAFE_NAME}.dirs.csv"
  local FFUF_FILE_OUT="$WORKDIR/ffuf/${SAFE_NAME}.files.csv"

  local DS_LOG="$WORKDIR/logs/${SAFE_NAME}.dirsearch.log"
  local FFUF_DIR_LOG="$WORKDIR/logs/${SAFE_NAME}.ffuf-dirs.log"
  local FFUF_FILE_LOG="$WORKDIR/logs/${SAFE_NAME}.ffuf-files.log"

  local had_error=0 rc=0

  if [[ "$PHASE" == "dirsearch" ]]; then
    if [[ ! -s "$DS_OUT" ]]; then
      if have_bin "$DIRSEARCH_BIN"; then
        timeout --signal=TERM "${PER_HOST_TIMEOUT_SEC}s" \
          "$DIRSEARCH_BIN" -u "$HOST" -w "$DIRSEARCH_WORDLIST" -e php,html,js,txt,asp,aspx,jsp \
          -t 40 --timeout 5 --delay 0.05 --plain-text-report "$DS_OUT" >"$DS_LOG" 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
          had_error=1
          if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            record_error "discovery" "dirsearch" "$HOST" "timeout"
          else
            record_error "discovery" "dirsearch" "$HOST" "exit_code=$rc"
          fi
        fi
      else
        write_missing_log "[!] dirsearch missing" "$DS_LOG"
        record_error "discovery" "dirsearch" "$HOST" "binary_missing"
        had_error=1
      fi
    fi
  fi

  if [[ "$PHASE" == "ffuf_dirs" || "$PHASE" == "ffuf_files" ]]; then
    if have_bin "$FFUF_BIN"; then
      if [[ "$PHASE" == "ffuf_dirs" && ! -s "$FFUF_DIR_OUT" ]]; then
        timeout --signal=TERM "${PER_HOST_TIMEOUT_SEC}s" \
          "$FFUF_BIN" -u "$HOST/FUZZ" -w "$FFUF_DIR_WORDLIST" -t 40 -timeout 5 -rate 50 \
          -mc 200,204,301,302,307,401,403 -of csv -o "$FFUF_DIR_OUT" >"$FFUF_DIR_LOG" 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
          had_error=1
          if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            record_error "discovery" "ffuf_dirs" "$HOST" "timeout"
          else
            record_error "discovery" "ffuf_dirs" "$HOST" "exit_code=$rc"
          fi
        fi
      fi

      if [[ "$PHASE" == "ffuf_files" && ! -s "$FFUF_FILE_OUT" ]]; then
        timeout --signal=TERM "${PER_HOST_TIMEOUT_SEC}s" \
          "$FFUF_BIN" -u "$HOST/FUZZ" -w "$FFUF_FILE_WORDLIST" -t 40 -timeout 5 -rate 50 \
          -mc 200,204,301,302,307,401,403 -of csv -o "$FFUF_FILE_OUT" >"$FFUF_FILE_LOG" 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
          had_error=1
          if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            record_error "discovery" "ffuf_files" "$HOST" "timeout"
          else
            record_error "discovery" "ffuf_files" "$HOST" "exit_code=$rc"
          fi
        fi
      fi
    else
      write_missing_log "[!] ffuf missing" "$FFUF_DIR_LOG" "$FFUF_FILE_LOG"
      record_error "discovery" "$PHASE" "$HOST" "binary_missing"
      had_error=1
    fi
  fi

  return $had_error
}

run_discovery_phase() {
  local phase="$1"
  local done_marker="$2"
  local phase_parallel="$PARALLEL"

  if is_done "$done_marker"; then
    echo "[*] Discovery phase '$phase' already done; skipping."
    return 0
  fi

  mapfile -t hosts < <(grep -v '^\s*$' "$WORKDIR/live_hosts.txt" 2>/dev/null || true)
  local total="${#hosts[@]}"
  if [[ "$total" -eq 0 ]]; then
    echo "[!] live_hosts.txt empty; skipping discovery phase '$phase'."
    mark_done "$done_marker"
    return 0
  fi

  echo "[*] Running discovery phase '$phase' (parallel=$phase_parallel, hosts=$total)…"

  local i=0 running=0 completed=0 failures=0
  local start_ts now elapsed
  start_ts="$(date +%s)"

  while [[ $i -lt $total || $running -gt 0 ]]; do
    while [[ $i -lt $total && $running -lt $phase_parallel ]]; do
      host="${hosts[$i]}"
      ( process_host_phase "$host" "$phase" ) &
      i=$((i+1))
      running=$((running+1))
    done

    if [[ $running -gt 0 ]]; then
      if wait -n; then
        :
      else
        failures=$((failures+1))
      fi
      completed=$((completed+1))
      running=$((running-1))

      now="$(date +%s)"
      elapsed=$((now - start_ts))
      if [[ $completed -eq $total || $((completed % 10)) -eq 0 ]]; then
        echo "[*] discovery:$phase progress $completed/$total hosts, failures=$failures, elapsed=${elapsed}s"
      fi
    fi
  done

  record_stage_status "discovery_$phase" "completed" "hosts=$total failures=$failures"

  # Backoff if too noisy
  if [[ $failures -ge $BACKOFF_TRIGGER_FAILURES && $PARALLEL -gt 5 ]]; then
    PARALLEL=$((PARALLEL / 2))
    [[ $PARALLEL -lt 5 ]] && PARALLEL=5
    echo "[!] High failure count in phase '$phase' ($failures). Backing off parallel to $PARALLEL for next phases."
    record_stage_status "discovery_backoff" "applied" "phase=$phase failures=$failures new_parallel=$PARALLEL"
  fi

  mark_done "$done_marker"
}

export -f have_bin
export -f is_positive_int
export -f safe_name_for_host
export -f write_missing_log
export -f record_error
export -f process_host_phase
export WORKDIR FFUF_BIN DIRSEARCH_BIN FFUF_DIR_WORDLIST FFUF_FILE_WORDLIST DIRSEARCH_WORDLIST PER_HOST_TIMEOUT_SEC ERRORS_JSON

if ! is_done "discovery"; then
  echo "[*] Per-host discovery (parallel=$PARALLEL)…"
  run_discovery_phase "dirsearch" "discovery_dirsearch"
  run_discovery_phase "ffuf_dirs" "discovery_ffuf_dirs"
  run_discovery_phase "ffuf_files" "discovery_ffuf_files"

  normalize_dirsearch_reports
  record_stage_status "discovery" "completed" "per-host dirsearch/ffuf attempted"
  mark_done "discovery"
fi

# 5) URL discovery (katana + gau) + params
if ! is_done "urls"; then
  echo "[*] URL discovery…"
  init_output_files "$WORKDIR/urls/katana_urls.txt" "$WORKDIR/urls/gau_urls.txt" "$WORKDIR/urls/urls_all.txt" "$WORKDIR/urls/urls_params.txt"

  if have_bin "$KATANA_BIN" && [[ -s "$WORKDIR/live_hosts.txt" ]]; then
    run_cmd "katana" "\"$KATANA_BIN\" -list \"$WORKDIR/live_hosts.txt\" -silent -nc -kf all -o \"$WORKDIR/urls/katana_urls.txt\" || true"
  fi
  if have_bin "$GAU_BIN"; then
    run_cmd "gau" "\"$GAU_BIN\" --subs \"$TARGET\" 2>/dev/null | sed '/^$/d' | sort -u > \"$WORKDIR/urls/gau_urls.txt\" || true"
  fi

  cat "$WORKDIR/urls/katana_urls.txt" "$WORKDIR/urls/gau_urls.txt" 2>/dev/null | sed '/^$/d' | sort -u > "$WORKDIR/urls/urls_all.txt" || true
  grep -E '\?.+=' "$WORKDIR/urls/urls_all.txt" 2>/dev/null | sort -u > "$WORKDIR/urls/urls_params.txt" || true

  python3 - "$WORKDIR" <<'PY' || true
import os, re, urllib.parse, collections, json, sys
workdir = sys.argv[1]
params_file = os.path.join(workdir, "urls", "urls_params.txt")
out_md = os.path.join(workdir, "intel", "params_ranked.md")
out_json = os.path.join(workdir, "intel", "params_ranked.json")
os.makedirs(os.path.join(workdir, "intel"), exist_ok=True)

def esc_md(value):
  return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>")

juicy = {
  "id","ids","uid","user","user_id","account","acct","email","phone",
  "token","access_token","refresh_token","auth","jwt","session","sid","key","api_key",
  "redirect","return","returnurl","next","callback","url","dest","destination","continue",
  "file","path","download","doc","document","template","view",
  "q","s","search","query","filter","sort","order",
  "page","limit","offset","cursor","from","to","start","end",
  "lang","locale","debug","test"
}

cnt = collections.Counter()
examples = collections.defaultdict(list)

if not os.path.exists(params_file) or os.path.getsize(params_file) == 0:
  open(out_md, "w").write("# Parameter Ranking (Juice)\n\n_No param URLs found._\n")
  open(out_json, "w").write(json.dumps({"total_unique_params": 0, "top": []}, indent=2))
  raise SystemExit(0)

with open(params_file, "r", encoding="utf-8", errors="ignore") as f:
  for line in f:
    u = line.strip()
    if not u:
      continue
    try:
      p = urllib.parse.urlsplit(u)
      qs = urllib.parse.parse_qsl(p.query, keep_blank_values=True)
      for k,v in qs:
        k2 = k.strip()
        if not k2:
          continue
        cnt[k2] += 1
        if len(examples[k2]) < 3:
          examples[k2].append(u)
    except Exception:
      continue

scored = []
for k, n in cnt.items():
  score = n + (50 if k.lower() in juicy else 0)
  scored.append((score, k, n, (k.lower() in juicy)))
scored.sort(reverse=True)

md = []
md.append("# Parameter Ranking (Readable)\n\n")
md.append(f"- Total unique params: **{len(cnt)}**\n")
md.append(f"- Juicy/security-relevant params: **{sum(1 for k in cnt if k.lower() in juicy)}**\n\n")
md.append("Legend: ✅ = security-relevant keyword match\n\n")

for idx, (score,k,n,isj) in enumerate(scored, 1):
  md.append(f"## {idx}. `{esc_md(k)}` {'✅' if isj else ''}\n")
  md.append(f"- Count: **{n}**\n")
  exs = examples.get(k, [])
  if exs:
    md.append("- Examples:\n")
    for ex in exs:
      ex = ex if len(ex) <= 180 else (ex[:177] + "...")
      md.append(f"  - `{esc_md(ex)}`\n")
  md.append("\n")

open(out_md, "w", encoding="utf-8").write("".join(md))
open(out_json, "w", encoding="utf-8").write(json.dumps({
  "total_unique_params": len(cnt),
  "top": [{"param":k,"count":n,"juicy":(k.lower() in juicy)} for score,k,n,isj in scored]
}, indent=2))
PY

  record_stage_status "urls" "completed" "katana/gau url collection and param ranking generated"
  mark_done "urls"
fi

# 6) Tech correlation
if ! is_done "tech"; then
  echo "[*] Tech correlation…"
  python3 - "$WORKDIR" <<'PY' || true
import json, os, collections, sys
workdir = sys.argv[1]
jpath = os.path.join(workdir, "httpx_results.json")
out_md = os.path.join(workdir, "intel", "tech_summary.md")
out_json = os.path.join(workdir, "intel", "tech_summary.json")
os.makedirs(os.path.join(workdir,"intel"), exist_ok=True)

if not os.path.exists(jpath) or os.path.getsize(jpath) == 0:
  open(out_md,"w").write("# Tech Summary\n\n_No httpx_results.json found._\n")
  open(out_json,"w").write(json.dumps({"error":"no httpx json"}, indent=2))
  raise SystemExit(0)

tech_cnt = collections.Counter()
webserver_cnt = collections.Counter()
status_cnt = collections.Counter()

with open(jpath,"r",encoding="utf-8",errors="ignore") as f:
  for line in f:
    line=line.strip()
    if not line: continue
    try:
      o=json.loads(line)
    except Exception:
      continue
    for t in (o.get("tech") or []):
      tech_cnt[str(t)] += 1
    ws = o.get("webserver")
    if ws: webserver_cnt[str(ws)] += 1
    sc = o.get("status_code")
    if sc is not None: status_cnt[str(sc)] += 1

md=[]
md.append("# Tech Summary (from httpx)\n\n")
md.append("## Top Technologies\n\n| Tech | Count |\n|---|---:|\n")
for k,v in tech_cnt.most_common(30):
  md.append(f"| {k} | {v} |\n")

md.append("\n## Webservers\n\n| Webserver | Count |\n|---|---:|\n")
for k,v in webserver_cnt.most_common(20):
  md.append(f"| {k} | {v} |\n")

md.append("\n## Status Codes\n\n| Status | Count |\n|---|---:|\n")
for k,v in status_cnt.most_common(20):
  md.append(f"| {k} | {v} |\n")

open(out_md,"w",encoding="utf-8").write("".join(md))
open(out_json,"w",encoding="utf-8").write(json.dumps({
  "tech_top": tech_cnt.most_common(100),
  "webserver_top": webserver_cnt.most_common(100),
  "status_top": status_cnt.most_common(100),
}, indent=2))
PY
  record_stage_status "tech" "completed" "tech correlation generated from httpx json"
  mark_done "tech"
fi

# 6b) Tech ↔ host mapping for actionable triage
if ! is_done "tech_host_mapping"; then
  echo "[*] Mapping tech/webservers to hosts…"
  python3 - "$WORKDIR" <<'PY' || true
import json, os, collections, sys
workdir = sys.argv[1]
httpx_json = os.path.join(workdir, "httpx_results.json")
intel = os.path.join(workdir, "intel")
os.makedirs(intel, exist_ok=True)

tech_to_hosts = collections.defaultdict(set)
ws_to_hosts = collections.defaultdict(set)
host_rows = []

if os.path.exists(httpx_json):
  with open(httpx_json, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
      line=line.strip()
      if not line:
        continue
      try:
        o=json.loads(line)
      except Exception:
        continue
      host=(o.get("url") or o.get("input") or "").strip()
      if not host:
        continue
      techs=[str(t) for t in (o.get("tech") or []) if str(t).strip()]
      ws=str(o.get("webserver") or "").strip()
      sc=o.get("status_code")
      for t in techs:
        tech_to_hosts[t].add(host)
      if ws:
        ws_to_hosts[ws].add(host)
      host_rows.append({
        "host": host,
        "status_code": sc,
        "webserver": ws,
        "tech": sorted(set(techs))
      })

# JSON outputs
with open(os.path.join(intel, "tech_to_hosts.json"), "w", encoding="utf-8") as f:
  json.dump({k: sorted(v) for k,v in sorted(tech_to_hosts.items(), key=lambda x: (-len(x[1]), x[0].lower()))}, f, indent=2)
with open(os.path.join(intel, "webserver_to_hosts.json"), "w", encoding="utf-8") as f:
  json.dump({k: sorted(v) for k,v in sorted(ws_to_hosts.items(), key=lambda x: (-len(x[1]), x[0].lower()))}, f, indent=2)
with open(os.path.join(intel, "tech_by_host.json"), "w", encoding="utf-8") as f:
  json.dump(sorted(host_rows, key=lambda x: x["host"]), f, indent=2)

# Markdown outputs
with open(os.path.join(intel, "tech_to_hosts.md"), "w", encoding="utf-8") as f:
  f.write("# Technology → Hosts\n\n")
  for tech, hosts in sorted(tech_to_hosts.items(), key=lambda x: (-len(x[1]), x[0].lower())):
    f.write(f"## {tech} ({len(hosts)})\n")
    for h in sorted(hosts):
      f.write(f"- {h}\n")
    f.write("\n")

with open(os.path.join(intel, "webserver_to_hosts.md"), "w", encoding="utf-8") as f:
  f.write("# Webserver → Hosts\n\n")
  for ws, hosts in sorted(ws_to_hosts.items(), key=lambda x: (-len(x[1]), x[0].lower())):
    f.write(f"## {ws} ({len(hosts)})\n")
    for h in sorted(hosts):
      f.write(f"- {h}\n")
    f.write("\n")

with open(os.path.join(intel, "tech_by_host.md"), "w", encoding="utf-8") as f:
  f.write("# Host → Tech/Webserver\n\n")
  f.write("| Host | Status | Webserver | Tech |\n|---|---:|---|---|\n")
  for row in sorted(host_rows, key=lambda x: x["host"]):
    host=row["host"].replace("|", "\\|")
    ws=(row.get("webserver") or "").replace("|", "\\|")
    tech=", ".join(row.get("tech") or []).replace("|", "\\|")
    sc=row.get("status_code")
    f.write(f"| {host} | {sc if sc is not None else ''} | {ws} | {tech} |\n")

# legacy/version focused shortlist
legacy_markers=("nginx/", "apache/", "iis/", "microsoft-iis/", "php/", "jquery:", "prototype")
legacy=[]
for row in host_rows:
  ws=(row.get("webserver") or "").lower()
  techs=[t.lower() for t in (row.get("tech") or [])]
  blob=" ".join([ws] + techs)
  if any(m in blob for m in legacy_markers):
    legacy.append(row)

with open(os.path.join(intel, "hosts_with_legacy_versions.md"), "w", encoding="utf-8") as f:
  f.write("# Hosts with Versioned/Legacy-Looking Tech\n\n")
  if not legacy:
    f.write("_No obvious versioned/legacy signatures found._\n")
  else:
    for row in sorted(legacy, key=lambda x: x["host"]):
      f.write(f"- {row['host']} | webserver={row.get('webserver') or '-'} | tech={', '.join(row.get('tech') or [])}\n")
PY
  record_stage_status "tech_host_mapping" "completed" "generated tech/webserver to host mapping"
  mark_done "tech_host_mapping"
fi

# 7) Nuclei phase 1 (high/critical, selected tags)
if ! is_done "nuclei_phase1"; then
  echo "[*] Nuclei phase 1 (severity=$NUCLEI_PHASE1_SEV tags=$NUCLEI_PHASE1_TAGS)…"
  init_output_files "$WORKDIR/nuclei_phase1.txt" "$WORKDIR/nuclei_phase1.jsonl"
  if [[ "$SKIP_NUCLEI" == "1" ]]; then
    record_stage_status "nuclei_phase1" "skipped" "skip-nuclei enabled"
  elif have_bin "$NUCLEI_BIN" && [[ -s "$WORKDIR/live_hosts.txt" ]]; then
    run_cmd "nuclei phase1 txt" "\"$NUCLEI_BIN\" -l \"$WORKDIR/live_hosts.txt\" -severity \"$NUCLEI_PHASE1_SEV\" -tags \"$NUCLEI_PHASE1_TAGS\" -silent -rl 50 -c \"$NUCLEI_CONCURRENCY\" -max-host-error \"$NUCLEI_MAX_HOST_ERROR\" -timeout 5 -retries 1 -o \"$WORKDIR/nuclei_phase1.txt\" || true"
    run_cmd "nuclei phase1 jsonl" "\"$NUCLEI_BIN\" -l \"$WORKDIR/live_hosts.txt\" -severity \"$NUCLEI_PHASE1_SEV\" -tags \"$NUCLEI_PHASE1_TAGS\" -silent -rl 50 -c \"$NUCLEI_CONCURRENCY\" -max-host-error \"$NUCLEI_MAX_HOST_ERROR\" -timeout 5 -retries 1 -jsonl -o \"$WORKDIR/nuclei_phase1.jsonl\" || true"
    record_stage_status "nuclei_phase1" "completed" "phase1 nuclei scan attempted"
  else
    record_stage_status "nuclei_phase1" "skipped" "nuclei missing or no live hosts"
  fi
  mark_done "nuclei_phase1"
fi

# 8) Endpoint ranking
if ! is_done "endpoint_ranking"; then
  echo "[*] Endpoint ranking…"
  python3 - "$WORKDIR" <<'PY' || true
import os, re, csv, json, collections, sys
workdir = sys.argv[1]
urls_all = os.path.join(workdir, "urls", "urls_all.txt")
ffuf_dir = os.path.join(workdir, "ffuf")
dirsearch_json = os.path.join(workdir, "intel", "dirsearch_normalized.json")

out_md = os.path.join(workdir, "intel", "endpoints_ranked.md")
out_json = os.path.join(workdir, "intel", "endpoints_ranked.json")
os.makedirs(os.path.join(workdir,"intel"), exist_ok=True)

juicy_path_kw = [
  "admin","login","signin","signup","oauth","sso","callback","redirect",
  "api","graphql","swagger","openapi","actuator","console",
  "upload","download","export","import","backup",
  "debug","test","staging","internal",
  ".git",".env","config","backup","old","dev"
]

def esc_md(value):
  return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>")

def score_url(u):
  s=0
  lu=u.lower()
  if any(k in lu for k in juicy_path_kw): s+=30
  if "?" in u: s+=15
  if re.search(r'\b(id|token|redirect|url|next|callback|file|path|key|api_key|auth)\b', lu): s+=25
  return s

candidates = collections.defaultdict(lambda: {"score":0,"sources":set()})

if os.path.exists(urls_all):
  for line in open(urls_all, "r", encoding="utf-8", errors="ignore"):
    u=line.strip()
    if not u: continue
    candidates[u]["score"] += score_url(u)
    candidates[u]["sources"].add("urls")

def ingest_ffuf(path, label):
  try:
    with open(path, newline='', encoding="utf-8", errors="ignore") as f:
      r=csv.reader(f)
      header=next(r, None)
      for row in r:
        if len(row) < 3: continue
        url=row[0]; sc=row[2]
        if not url: continue
        add=10
        if sc.startswith("2"): add+=20
        if sc.startswith("3"): add+=10
        if sc in ("401","403"): add+=8
        candidates[url]["score"] += add + score_url(url)
        candidates[url]["sources"].add(label)
  except Exception:
    return

if os.path.isdir(ffuf_dir):
  for fn in os.listdir(ffuf_dir):
    if fn.endswith(".csv"):
      ingest_ffuf(os.path.join(ffuf_dir, fn), "ffuf")

if os.path.exists(dirsearch_json):
  try:
    with open(dirsearch_json, "r", encoding="utf-8", errors="ignore") as f:
      data = json.load(f)
    for row in data:
      url = str(row.get("url") or "").strip()
      sc = str(row.get("status") or "").strip()
      if not url or not sc:
        continue
      add=8
      if sc.startswith("2"): add+=18
      if sc.startswith("3"): add+=10
      candidates[url]["score"] += add + score_url(url)
      candidates[url]["sources"].add("dirsearch")
  except Exception:
    pass

ranked = sorted(
  ((v["score"], u, sorted(v["sources"])) for u,v in candidates.items()),
  reverse=True
)

md=[]
md.append("# Endpoint Ranking (triage)\n\n")
md.append("| Score | URL | Sources |\n|---:|---|---|\n")
for score,u,sources in ranked[:200]:
  md.append(f"| {score} | {esc_md(u)} | {esc_md(', '.join(sources))} |\n")

open(out_md,"w",encoding="utf-8").write("".join(md))
open(out_json,"w",encoding="utf-8").write(json.dumps([
  {"score":score,"url":u,"sources":sources} for score,u,sources in ranked[:2000]
], indent=2))
PY
  record_stage_status "endpoint_ranking" "completed" "endpoint ranking generated"
  mark_done "endpoint_ranking"
fi

# 9) summary.md + summary.json
echo "[*] Building summary.md…"
SUMMARY_MD="$WORKDIR/summary.md"
python3 - "$WORKDIR" <<'PY' > "$SUMMARY_MD" || true
import os, datetime, sys

workdir = sys.argv[1]
target = os.path.basename(os.path.dirname(workdir))
gen = datetime.datetime.now().isoformat(sep=" ", timespec="seconds")

def count_lines(p):
  try:
    with open(p,'r',encoding='utf-8',errors='ignore') as f:
      return sum(1 for x in f if x.strip())
  except Exception:
    return 0

paths = {
  "all_subdomains": os.path.join(workdir,"all_subdomains.txt"),
  "resolved_subdomains": os.path.join(workdir,"resolved_subdomains.txt"),
  "live_hosts": os.path.join(workdir,"live_hosts.txt"),
  "urls_all": os.path.join(workdir,"urls","urls_all.txt"),
  "urls_params": os.path.join(workdir,"urls","urls_params.txt"),
  "nuclei_phase1": os.path.join(workdir,"nuclei_phase1.txt"),
}

print(f"# Recon Summary for {target}\n")
print(f"- Generated: {gen}")
print(f"- Workspace: `{workdir}`\n")

print("## Counts\n")
print(f"- Subdomains: **{count_lines(paths['all_subdomains'])}**")
print(f"- Resolved: **{count_lines(paths['resolved_subdomains'])}**")
print(f"- Live hosts: **{count_lines(paths['live_hosts'])}**")
print(f"- URLs (all): **{count_lines(paths['urls_all'])}**")
print(f"- URLs (with params): **{count_lines(paths['urls_params'])}**")
print(f"- Nuclei findings (phase1): **{count_lines(paths['nuclei_phase1'])}**\n")

print("## Intelligence Views\n")
print(f"- Param juice ranking: `{os.path.join(workdir,'intel','params_ranked.md')}`")
print(f"- Tech summary: `{os.path.join(workdir,'intel','tech_summary.md')}`")
print(f"- Tech to hosts: `{os.path.join(workdir,'intel','tech_to_hosts.md')}`")
print(f"- Webserver to hosts: `{os.path.join(workdir,'intel','webserver_to_hosts.md')}`")
print(f"- Host tech mapping: `{os.path.join(workdir,'intel','tech_by_host.md')}`")
print(f"- Legacy/version shortlist: `{os.path.join(workdir,'intel','hosts_with_legacy_versions.md')}`")
print(f"- DNS host→IP map: `{os.path.join(workdir,'intel','dns_host_ip_map.json')}`")
print(f"- Normalized dirsearch data: `{os.path.join(workdir,'intel','dirsearch_normalized.json')}`")
print(f"- Endpoint ranking: `{os.path.join(workdir,'intel','endpoints_ranked.md')}`")
print(f"- Stage status log: `{os.path.join(workdir,'stage_status.jsonl')}`\n")

print("## Notes\n")
print("- Empty nuclei output can be normal if filters are tight (high/critical + limited tags) and there are no matching known issues.")
print("- Use endpoint/param rankings to prioritize manual testing.\n")
PY

python3 - "$WORKDIR" <<'PY' > "$WORKDIR/summary.json" || true
import json, os, glob, sys
workdir = sys.argv[1]
def gl(p): return sorted(glob.glob(os.path.join(workdir,p)))
out = {
  "workdir": workdir,
  "subdomains": os.path.join(workdir,"all_subdomains.txt"),
  "resolved": os.path.join(workdir,"resolved_subdomains.txt"),
  "live_hosts": os.path.join(workdir,"live_hosts.txt"),
  "httpx": {
    "text": os.path.join(workdir,"httpx_results.txt"),
    "jsonl": os.path.join(workdir,"httpx_results.json"),
  },
  "urls": {
    "katana": os.path.join(workdir,"urls","katana_urls.txt"),
    "gau": os.path.join(workdir,"urls","gau_urls.txt"),
    "all": os.path.join(workdir,"urls","urls_all.txt"),
    "params": os.path.join(workdir,"urls","urls_params.txt"),
  },
  "nuclei": {
    "phase1_text": os.path.join(workdir,"nuclei_phase1.txt"),
    "phase1_jsonl": os.path.join(workdir,"nuclei_phase1.jsonl"),
  },
  "intel": {
    "params_ranked_md": os.path.join(workdir,"intel","params_ranked.md"),
    "params_ranked_json": os.path.join(workdir,"intel","params_ranked.json"),
    "tech_summary_md": os.path.join(workdir,"intel","tech_summary.md"),
    "tech_summary_json": os.path.join(workdir,"intel","tech_summary.json"),
    "tech_to_hosts_md": os.path.join(workdir,"intel","tech_to_hosts.md"),
    "tech_to_hosts_json": os.path.join(workdir,"intel","tech_to_hosts.json"),
    "webserver_to_hosts_md": os.path.join(workdir,"intel","webserver_to_hosts.md"),
    "webserver_to_hosts_json": os.path.join(workdir,"intel","webserver_to_hosts.json"),
    "tech_by_host_md": os.path.join(workdir,"intel","tech_by_host.md"),
    "tech_by_host_json": os.path.join(workdir,"intel","tech_by_host.json"),
    "hosts_with_legacy_versions_md": os.path.join(workdir,"intel","hosts_with_legacy_versions.md"),
    "dirsearch_normalized_json": os.path.join(workdir,"intel","dirsearch_normalized.json"),
    "dns_host_ip_map_json": os.path.join(workdir,"intel","dns_host_ip_map.json"),
    "endpoints_ranked_md": os.path.join(workdir,"intel","endpoints_ranked.md"),
    "endpoints_ranked_json": os.path.join(workdir,"intel","endpoints_ranked.json"),
  },
  "status": {
    "stage_status_jsonl": os.path.join(workdir,"stage_status.jsonl"),
    "errors_jsonl": os.path.join(workdir,"errors.jsonl"),
  },
  "artifacts": {
    "ffuf_csv": gl("ffuf/*.csv"),
    "dirsearch_txt": gl("dirsearch/*.txt"),
    "logs": gl("logs/*.log"),
  }
}
print(json.dumps(out, indent=2))
PY

echo "[*] Done."
echo "[*] Summary: $WORKDIR/summary.md"
EOF

# inject placeholders safely (no shell eval inside file)
replace_in_file() {
  local file="$1" from="$2" to="$3"
  python3 - "$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path,'r',encoding='utf-8',errors='ignore') as f:
  s=f.read()
s=s.replace(old,new)
with open(path,'w',encoding='utf-8') as f:
  f.write(s)
PY
}

replace_in_file "$RUNFILE" "__TARGET__" "$TARGET"
replace_in_file "$RUNFILE" "__WORKDIR__" "$WORKDIR"
replace_in_file "$RUNFILE" "__STATE_DIR__" "$STATE_DIR"
replace_in_file "$RUNFILE" "__COMMANDS_MD__" "$COMMANDS_MD"
replace_in_file "$RUNFILE" "__STATUS_JSON__" "$STATUS_JSON"
replace_in_file "$RUNFILE" "__ERRORS_JSON__" "$ERRORS_JSON"
replace_in_file "$RUNFILE" "__PARALLEL_OVERRIDE__" "${PARALLEL_OVERRIDE:-}"
replace_in_file "$RUNFILE" "__SKIP_NUCLEI__" "$SKIP_NUCLEI"
replace_in_file "$RUNFILE" "__NUCLEI_SEV_OVERRIDE__" "$NUCLEI_SEV_OVERRIDE"
replace_in_file "$RUNFILE" "__NUCLEI_TAGS_OVERRIDE__" "$NUCLEI_TAGS_OVERRIDE"

replace_in_file "$RUNFILE" "__FFUF_BIN__" "$FFUF_BIN"
replace_in_file "$RUNFILE" "__HTTPX_BIN__" "$HTTPX_BIN"
replace_in_file "$RUNFILE" "__SUBFINDER_BIN__" "$SUBFINDER_BIN"
replace_in_file "$RUNFILE" "__ASSETFINDER_BIN__" "$ASSETFINDER_BIN"
replace_in_file "$RUNFILE" "__DNSX_BIN__" "$DNSX_BIN"
replace_in_file "$RUNFILE" "__KATANA_BIN__" "$KATANA_BIN"
replace_in_file "$RUNFILE" "__GAU_BIN__" "$GAU_BIN"
replace_in_file "$RUNFILE" "__NUCLEI_BIN__" "$NUCLEI_BIN"
replace_in_file "$RUNFILE" "__DIRSEARCH_BIN__" "$DIRSEARCH_BIN"

replace_in_file "$RUNFILE" "__FFUF_DIR_WORDLIST__" "$FFUF_DIR_WORDLIST"
replace_in_file "$RUNFILE" "__FFUF_FILE_WORDLIST__" "$FFUF_FILE_WORDLIST"
replace_in_file "$RUNFILE" "__DIRSEARCH_WORDLIST__" "$DIRSEARCH_WORDLIST"

python3 - "$RUNFILE" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8', errors='ignore')
leftovers = sorted(set(re.findall(r'__[A-Z0-9_]+__', text)))
if leftovers:
    raise SystemExit("[!] Unreplaced placeholders in runfile: " + ", ".join(leftovers))
PY

chmod +x "$RUNFILE"

echo "[*] Generated: $RUNFILE"

# ---------- run policy ----------
if [[ "$DO_RUN" -eq 1 ]]; then
  echo "[*] Running recon for $TARGET…"
  bash "$RUNFILE"
  exit 0
fi

echo "[*] Workspace ready: $WORKDIR"
echo "[*] To run:"
echo "    bash \"$RUNFILE\""
