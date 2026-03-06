#!/usr/bin/env bash
#
# reconHarvest.sh (Kali-friendly + resumable + scope-guarded + report-heavy)
#
# Runs only for lab targets or targets listed in scope.txt when --run is used.
# Generates workspace + run_commands.sh always.
#
# Usage:
#   ./reconHarvest.sh <target>
#   ./reconHarvest.sh --run <target>
#   ./reconHarvest.sh --parallel <n> [--run] <target>
#   ./reconHarvest.sh --resume <workdir> [--run]
#
set -Eeuo pipefail

usage() {
  cat <<'EOL'
Usage:
  ./reconHarvest.sh <target>
  ./reconHarvest.sh --run <target>
  ./reconHarvest.sh --parallel <n> [--run] <target>
  ./reconHarvest.sh --resume <workdir> [--run]

Notes:
  - Workspaces: outputs/<target>/<timestamp>/
  - --resume expects that folder path
  - --run executes ONLY if:
      * target is lab (localhost/127.0.0.1/*.local), OR
      * target matches scope.txt (root domains or CIDRs)
  - Put scope.txt next to this script (recommended for company use).

Examples:
  ./reconHarvest.sh example.com
  ./reconHarvest.sh --run example.com
  ./reconHarvest.sh --parallel 80 --run localhost
  ./reconHarvest.sh --resume outputs/example.com/20260218141912 --run
EOL
  exit 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_positive_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

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

# ---------- install helpers ----------
ensure_go() {
  command_exists go && return 0
  echo "[*] Installing Go via apt…"
  is_kali_or_debian_like && apt_install golang
  command_exists go || { echo "[!] Go not found. Install Go and ensure GOPATH/bin is in PATH."; return 1; }
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
  local install_cmd="$2"
  command_exists "$binary" && return 0

  ensure_go
  echo "[*] Installing $binary…"
  set +e
  # shellcheck disable=SC2086
  eval $install_cmd
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

# ---------- scope / run guard ----------
is_lab_target_value() {
  local t="$1"
  [[ "$t" == "localhost" ]] && return 0
  [[ "$t" == "127.0.0.1" ]] && return 0
  [[ "$t" == *.local ]] && return 0
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="$SCRIPT_DIR/scope.txt"

scope_matches() {
  local target="$1"
  [[ -f "$SCOPE_FILE" ]] || return 1
  command_exists python3 || return 1

  python3 - "$target" "$SCOPE_FILE" <<'PY'
import sys, re, ipaddress

target = sys.argv[1].strip().lower()
scope_file = sys.argv[2]

def is_ip(s):
    try:
        ipaddress.ip_address(s)
        return True
    except Exception:
        return False

def norm_host(s):
    s = s.strip().lower()
    s = re.sub(r'^https?://', '', s)
    s = s.split('/')[0]
    s = s.split(':')[0]
    return s

t = norm_host(target)
t_is_ip = is_ip(t)

with open(scope_file, 'r', encoding='utf-8', errors='ignore') as f:
    entries = [line.strip() for line in f if line.strip() and not line.strip().startswith('#')]

for e in entries:
    e = e.strip().lower()
    if '/' in e:
        if t_is_ip:
            try:
                net = ipaddress.ip_network(e, strict=False)
                ip = ipaddress.ip_address(t)
                if ip in net:
                    sys.exit(0)
            except Exception:
                pass
        continue

    e = norm_host(e)
    if not e:
        continue
    if t == e or t.endswith("." + e):
        sys.exit(0)

sys.exit(1)
PY
}

# ---------- args ----------
RESUME_MODE=0
DO_RUN=0
TARGET=""
WORKDIR=""
PARALLEL_OVERRIDE=""

if [[ $# -lt 1 ]]; then usage; fi

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --run) DO_RUN=1; shift ;;
    --parallel)
      PARALLEL_OVERRIDE="${2:-}"
      [[ -n "${PARALLEL_OVERRIDE:-}" ]] || { echo "[!] --parallel requires a value."; usage; }
      is_positive_int "$PARALLEL_OVERRIDE" || { echo "[!] --parallel must be a positive integer."; usage; }
      shift 2
      ;;
    --resume)
      RESUME_MODE=1
      WORKDIR="${2:-}"
      [[ -n "${WORKDIR:-}" ]] || { echo "[!] --resume requires a workdir."; usage; }
      shift 2
      ;;
    -h|--help) usage ;;
    *)
      [[ $RESUME_MODE -eq 0 && -z "${TARGET:-}" ]] && TARGET="$1"
      shift
      ;;
  esac
done

OUT_BASE="outputs"

if [[ $RESUME_MODE -eq 1 ]]; then
  [[ -d "$WORKDIR" ]] || { echo "[!] Resume folder not found: $WORKDIR"; exit 1; }
  if [[ -z "${TARGET:-}" ]]; then
    TARGET="$(basename "$(dirname "$WORKDIR")" 2>/dev/null || true)"
    [[ -n "${TARGET:-}" ]] || TARGET="${WORKDIR##*/}"
  fi
else
  [[ -n "${TARGET:-}" ]] || usage
  TIMESTAMP="$(date +%Y%m%d%H%M%S)"
  WORKDIR="$OUT_BASE/$TARGET/$TIMESTAMP"
  mkdir -p "$WORKDIR"
fi

echo "[*] Working directory: $WORKDIR"
command_exists python3 || { echo "[!] python3 is required. Install python3."; exit 1; }

# ---------- tool install ----------
install_dirsearch_kali_safe
install_go_tool "ffuf"        "go install github.com/ffuf/ffuf/v2@latest"
install_go_tool "httpx"       "go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
install_go_tool "subfinder"   "go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
install_go_tool "assetfinder" "go install github.com/tomnomnom/assetfinder@latest"
install_go_tool "dnsx"        "go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
install_go_tool "katana"      "go install -v github.com/projectdiscovery/katana/cmd/katana@latest"
install_go_tool "gau"         "go install github.com/lc/gau/v2/cmd/gau@latest"
install_go_tool "nuclei"      "go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"

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

if [[ ! -f "$FFUF_DIR_WORDLIST" || ! -f "$FFUF_FILE_WORDLIST" || ! -f "$DIRSEARCH_WORDLIST" ]]; then
  cat > "$WORKDIR/minimal_wordlist.txt" <<'EOL'
admin
login
uploads
images
css
js
api
dashboard
graphql
swagger
actuator
EOL
  [[ -f "$FFUF_DIR_WORDLIST" ]] || FFUF_DIR_WORDLIST="$WORKDIR/minimal_wordlist.txt"
  [[ -f "$FFUF_FILE_WORDLIST" ]] || FFUF_FILE_WORDLIST="$WORKDIR/minimal_wordlist.txt"
  [[ -f "$DIRSEARCH_WORDLIST" ]] || DIRSEARCH_WORDLIST="$WORKDIR/minimal_wordlist.txt"
fi

STATE_DIR="$WORKDIR/.state"
mkdir -p "$STATE_DIR"

RUNFILE="$WORKDIR/run_commands.sh"
COMMANDS_MD="$WORKDIR/COMMANDS_USED.md"

# ---------- generate run_commands.sh safely (literal heredoc) ----------
cat > "$RUNFILE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="__TARGET__"
WORKDIR="__WORKDIR__"
STATE_DIR="__STATE_DIR__"
COMMANDS_MD="__COMMANDS_MD__"

PARALLEL_OVERRIDE="__PARALLEL_OVERRIDE__"

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
  [[ -n "$GOBIN" ]] && export PATH="$GOBIN:$PATH"
fi

have_bin() {
  local b="${1:-}"
  [[ -n "$b" ]] || return 1
  if [[ "$b" == */* ]]; then [[ -x "$b" ]] && return 0; return 1; fi
  command -v "$b" >/dev/null 2>&1
}

is_done() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { : > "$STATE_DIR/$1.done"; }

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

mkdir -p "$WORKDIR/logs" "$WORKDIR/ffuf" "$WORKDIR/dirsearch" "$WORKDIR/urls" "$WORKDIR/intel" "$STATE_DIR"
: > "$COMMANDS_MD" 2>/dev/null || true

PARALLEL="${PARALLEL_OVERRIDE:-30}"

NUCLEI_PHASE1_SEV="high,critical"
NUCLEI_PHASE1_TAGS="cves,misconfig,login,token-spray"
NUCLEI_CONCURRENCY="${NUCLEI_CONCURRENCY:-50}"
NUCLEI_MAX_HOST_ERROR="${NUCLEI_MAX_HOST_ERROR:-100}"

echo "[*] Recon for $TARGET"
echo "[*] Output: $WORKDIR"
echo "[*] Parallel: $PARALLEL"

# 0) nuclei templates update (best-effort, once)
if ! is_done "nuclei_templates"; then
  if have_bin "$NUCLEI_BIN"; then
    echo "[*] Updating nuclei templates (best-effort)…"
    run_cmd "nuclei templates update" "\"$NUCLEI_BIN\" -update-templates -silent || true"
  fi
  mark_done "nuclei_templates"
fi

# 1) subdomains
if ! is_done "subdomains"; then
  echo "[*] Subdomain enumeration…"
  : > "$WORKDIR/subfinder.txt"
  : > "$WORKDIR/assetfinder.txt"
  : > "$WORKDIR/all_subdomains.txt"

  if have_bin "$SUBFINDER_BIN"; then
    run_cmd "subfinder" "\"$SUBFINDER_BIN\" -d \"$TARGET\" -all -silent -o \"$WORKDIR/subfinder.txt\" || true"
  fi
  if have_bin "$ASSETFINDER_BIN"; then
    run_cmd "assetfinder" "\"$ASSETFINDER_BIN\" --subs-only \"$TARGET\" 2>/dev/null | sort -u > \"$WORKDIR/assetfinder.txt\" || true"
  fi

  cat "$WORKDIR/subfinder.txt" "$WORKDIR/assetfinder.txt" | sed '/^$/d' | sort -u > "$WORKDIR/all_subdomains.txt" || true
  mark_done "subdomains"
fi

# 2) dns resolve
if ! is_done "dnsx"; then
  echo "[*] DNS resolve…"
  : > "$WORKDIR/resolved_subdomains.txt"
  if have_bin "$DNSX_BIN"; then
    run_cmd "dnsx" "\"$DNSX_BIN\" -l \"$WORKDIR/all_subdomains.txt\" -silent -resp-only -o \"$WORKDIR/resolved_subdomains.txt\" || true"
  else
    sed '/^$/d' "$WORKDIR/all_subdomains.txt" > "$WORKDIR/resolved_subdomains.txt" || true
  fi
  mark_done "dnsx"
fi

# 3) http probe + tech json
if ! is_done "httpx"; then
  echo "[*] HTTP probing…"
  : > "$WORKDIR/httpx_results.txt"
  : > "$WORKDIR/httpx_results.json"
  : > "$WORKDIR/live_hosts.txt"

  if have_bin "$HTTPX_BIN"; then
    run_cmd "httpx text" "\"$HTTPX_BIN\" -l \"$WORKDIR/resolved_subdomains.txt\" -silent -status-code -content-length -title -tech-detect -threads 200 -timeout 5 -retries 1 -o \"$WORKDIR/httpx_results.txt\" || true"
    run_cmd "httpx json" "\"$HTTPX_BIN\" -l \"$WORKDIR/resolved_subdomains.txt\" -silent -json -tech-detect -threads 200 -timeout 5 -retries 1 -o \"$WORKDIR/httpx_results.json\" || true"
    awk '$2 != "400" {print $1}' "$WORKDIR/httpx_results.txt" | sed '/^$/d' > "$WORKDIR/live_hosts.txt" || true
  fi
  mark_done "httpx"
fi

# 4) per-host discovery
process_host() {
  local HOST="$1"
  [[ -z "$HOST" ]] && return 0
  local SAFE_NAME
  SAFE_NAME="$(echo "$HOST" | sed 's/[^A-Za-z0-9_.-]/_/g')"

  local DS_OUT="$WORKDIR/dirsearch/${SAFE_NAME}.txt"
  local FFUF_DIR_OUT="$WORKDIR/ffuf/${SAFE_NAME}.dirs.csv"
  local FFUF_FILE_OUT="$WORKDIR/ffuf/${SAFE_NAME}.files.csv"

  local DS_LOG="$WORKDIR/logs/${SAFE_NAME}.dirsearch.log"
  local FFUF_DIR_LOG="$WORKDIR/logs/${SAFE_NAME}.ffuf-dirs.log"
  local FFUF_FILE_LOG="$WORKDIR/logs/${SAFE_NAME}.ffuf-files.log"

  if [[ ! -s "$DS_OUT" ]]; then
    if have_bin "$DIRSEARCH_BIN"; then
      "$DIRSEARCH_BIN" -u "$HOST" -w "$DIRSEARCH_WORDLIST" -e php,html,js,txt,asp,aspx,jsp \
        -t 40 --timeout 5 --delay 0.05 --plain-text-report "$DS_OUT" >"$DS_LOG" 2>&1 || true
    else
      echo "[!] dirsearch missing" >"$DS_LOG"
    fi
  fi

  if have_bin "$FFUF_BIN"; then
    if [[ ! -s "$FFUF_DIR_OUT" ]]; then
      "$FFUF_BIN" -u "$HOST/FUZZ" -w "$FFUF_DIR_WORDLIST" -t 40 -timeout 5 -rate 50 \
        -mc 200,204,301,302,307,401,403 -of csv -o "$FFUF_DIR_OUT" >"$FFUF_DIR_LOG" 2>&1 || true
    fi
    if [[ ! -s "$FFUF_FILE_OUT" ]]; then
      "$FFUF_BIN" -u "$HOST/FUZZ" -w "$FFUF_FILE_WORDLIST" -t 40 -timeout 5 -rate 50 \
        -mc 200,204,301,302,307,401,403 -of csv -o "$FFUF_FILE_OUT" >"$FFUF_FILE_LOG" 2>&1 || true
    fi
  else
    echo "[!] ffuf missing" >"$FFUF_DIR_LOG"
  fi
}

export -f have_bin
export -f process_host
export WORKDIR FFUF_BIN DIRSEARCH_BIN FFUF_DIR_WORDLIST FFUF_FILE_WORDLIST DIRSEARCH_WORDLIST

if ! is_done "discovery"; then
  echo "[*] Per-host discovery (parallel=$PARALLEL)…"
  if [[ -s "$WORKDIR/live_hosts.txt" ]]; then
    grep -v '^\s*$' "$WORKDIR/live_hosts.txt" | xargs -r -P "$PARALLEL" -I{} bash -lc 'process_host "{}"'
  else
    echo "[!] live_hosts.txt empty; skipping."
  fi
  mark_done "discovery"
fi

# 5) URL discovery (katana + gau) + params
if ! is_done "urls"; then
  echo "[*] URL discovery…"
  : > "$WORKDIR/urls/katana_urls.txt"
  : > "$WORKDIR/urls/gau_urls.txt"
  : > "$WORKDIR/urls/urls_all.txt"
  : > "$WORKDIR/urls/urls_params.txt"

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
md.append("# Parameter Ranking (Juice)\n\n")
md.append("Scoring = frequency + juicy bonus.\n\n")
md.append("| Param | Count | Juicy | Examples |\n|---|---:|:---:|---|\n")
for score,k,n,isj in scored[:80]:
  ex = "<br>".join(examples[k])
  md.append(f"| `{k}` | {n} | {'✅' if isj else ''} | {ex} |\n")

open(out_md, "w", encoding="utf-8").write("".join(md))
open(out_json, "w", encoding="utf-8").write(json.dumps({
  "total_unique_params": len(cnt),
  "top": [{"param":k,"count":n,"juicy":(k.lower() in juicy)} for score,k,n,isj in scored[:200]]
}, indent=2))
PY

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
  mark_done "tech"
fi

# 7) Nuclei phase 1 (high/critical, selected tags)
if ! is_done "nuclei_phase1"; then
  echo "[*] Nuclei phase 1 (high/critical + selected tags)…"
  : > "$WORKDIR/nuclei_phase1.txt"
  : > "$WORKDIR/nuclei_phase1.jsonl"
  if have_bin "$NUCLEI_BIN" && [[ -s "$WORKDIR/live_hosts.txt" ]]; then
    run_cmd "nuclei phase1 txt" "\"$NUCLEI_BIN\" -l \"$WORKDIR/live_hosts.txt\" -severity \"$NUCLEI_PHASE1_SEV\" -tags \"$NUCLEI_PHASE1_TAGS\" -silent -rl 50 -c \"$NUCLEI_CONCURRENCY\" -max-host-error \"$NUCLEI_MAX_HOST_ERROR\" -timeout 5 -retries 1 -o \"$WORKDIR/nuclei_phase1.txt\" || true"
    run_cmd "nuclei phase1 jsonl" "\"$NUCLEI_BIN\" -l \"$WORKDIR/live_hosts.txt\" -severity \"$NUCLEI_PHASE1_SEV\" -tags \"$NUCLEI_PHASE1_TAGS\" -silent -rl 50 -c \"$NUCLEI_CONCURRENCY\" -max-host-error \"$NUCLEI_MAX_HOST_ERROR\" -timeout 5 -retries 1 -jsonl -o \"$WORKDIR/nuclei_phase1.jsonl\" || true"
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
dirsearch = os.path.join(workdir, "dirsearch")

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

if os.path.isdir(dirsearch):
  for fn in os.listdir(dirsearch):
    if not fn.endswith(".txt"): continue
    p=os.path.join(dirsearch,fn)
    try:
      for line in open(p,"r",encoding="utf-8",errors="ignore"):
        line=line.strip()
        if not line: continue
        parts=line.split()
        if len(parts) < 2: continue
        url=parts[0]; sc=parts[1]
        if not url: continue
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
  md.append(f"| {score} | {u} | {', '.join(sources)} |\n")

open(out_md,"w",encoding="utf-8").write("".join(md))
open(out_json,"w",encoding="utf-8").write(json.dumps([
  {"score":score,"url":u,"sources":sources} for score,u,sources in ranked[:2000]
], indent=2))
PY
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
print(f"- Endpoint ranking: `{os.path.join(workdir,'intel','endpoints_ranked.md')}`\n")

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
    "endpoints_ranked_md": os.path.join(workdir,"intel","endpoints_ranked.md"),
    "endpoints_ranked_json": os.path.join(workdir,"intel","endpoints_ranked.json"),
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
replace_in_file "$RUNFILE" "__PARALLEL_OVERRIDE__" "${PARALLEL_OVERRIDE:-}"

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

chmod +x "$RUNFILE"

echo "[*] Generated: $RUNFILE"

# ---------- run policy ----------
if [[ "$DO_RUN" -eq 1 ]]; then
  if is_lab_target_value "$TARGET"; then
    echo "[*] LAB target detected ($TARGET) — running."
    bash "$RUNFILE"
    exit 0
  fi

  if scope_matches "$TARGET"; then
    echo "[*] Target matches scope.txt — running."
    bash "$RUNFILE"
    exit 0
  fi

  echo "[!] Refusing to run: target does not match scope.txt and is not lab."
  echo "    Add it to scope.txt (root domain or CIDR) or run against lab targets."
  echo "    Workspace generated anyway: $WORKDIR"
  exit 0
fi

echo "[*] Workspace ready: $WORKDIR"
echo "[*] To run (in-scope/lab only):"
echo "    bash \"$RUNFILE\""
