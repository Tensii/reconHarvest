# reconHarvest

`reconHarvest` is a Kali-friendly reconnaissance orchestrator for authorized security testing.

It automates practical recon workflows (subdomain discovery, host probing, content discovery, URL collection, lightweight vuln triage) while keeping output organized, resumable, and reviewable.

> ⚠️ **Legal & Ethics**
> Use this tool **only** on systems you explicitly own or are authorized to test.
> Unauthorized scanning/testing may be illegal.

---

## Why reconHarvest?

Most recon scripts are either too basic or too fragile for repeated engagements.

`reconHarvest` focuses on:

- **Scope-aware execution**: run mode is guarded by lab-target checks or `scope.txt`
- **Resumable runs**: step markers in `.state/` prevent redoing completed work
- **Structured output**: consistent workspace layout per target + timestamp
- **Evidence-first workflow**: command logging and report-heavy outputs
- **Kali-friendly installation flow**: auto-installs common recon dependencies where possible

---

## Features

- Subdomain enumeration: `subfinder`, `assetfinder`
- DNS resolution: `dnsx`
- Live host/tech probe: `httpx`
- Content discovery:
  - `dirsearch`
  - `ffuf` (directories and files)
- URL discovery: `katana`, `gau`
- Nuclei phase 1 scan (focused severity/tags)
- Intelligence artifacts:
  - parameter ranking (`params_ranked.md/json`)
  - technology summary (`tech_summary.md/json`)
  - endpoint ranking (`endpoints_ranked.md/json`)
- Human + machine summaries:
  - `summary.md`
  - `summary.json`

---

## Installation

```bash
git clone https://github.com/Tensii/reconHarvest.git
cd reconHarvest
chmod +x reconHarvest.sh
```

### Requirements

- Bash 4+
- Python 3
- `gh` is **not required** to run the script itself
- On Kali/Debian-like systems, the script can auto-install many tools with `apt`/`go`/`pipx`

---

## Usage

```bash
./reconHarvest.sh <target>
./reconHarvest.sh --run <target>
./reconHarvest.sh --parallel <n> [--run] <target>
./reconHarvest.sh --resume <workdir> [--run]
```

### Examples

```bash
# Generate workspace only (no active scanning)
./reconHarvest.sh example.com

# Run recon for in-scope target or lab target
./reconHarvest.sh --run example.com

# Increase parallel workers
./reconHarvest.sh --parallel 80 --run localhost

# Resume previous run workspace
./reconHarvest.sh --resume outputs/example.com/20260218141912 --run
```

---

## Scope Guard (`scope.txt`)

When `--run` is used, execution is allowed only if:

1. Target is a lab-style target (`localhost`, `127.0.0.1`, `*.local`), **or**
2. Target matches entries in `scope.txt`.

Create `scope.txt` next to the script:

```txt
# Domains
example.com
corp.internal

# CIDRs
10.10.0.0/16
172.16.5.0/24
```

Matching supports:

- root domain + subdomains
- CIDR ranges (for IP targets)

---

## Output Structure

Each run creates:

```txt
outputs/<target>/<timestamp>/
```

Common artifacts:

- `run_commands.sh` - generated runnable workflow
- `COMMANDS_USED.md` - logged commands for traceability
- `all_subdomains.txt`, `resolved_subdomains.txt`, `live_hosts.txt`
- `httpx_results.txt`, `httpx_results.json`
- `ffuf/*.csv`, `dirsearch/*.txt`, `logs/*.log`
- `urls/` (katana, gau, merged, params)
- `intel/` (rankings + summaries)
- `nuclei_phase1.txt`, `nuclei_phase1.jsonl`
- `summary.md`, `summary.json`

---

## Operational Notes

- Empty nuclei output can be normal depending on target exposure and template filters.
- For better performance, tune `--parallel` based on CPU/network constraints.
- For enterprise usage, keep `scope.txt` under access control and change management.

---

## Roadmap Ideas

- profile modes (`safe`, `normal`, `aggressive`)
- optional notifications on completion/failure
- tool version snapshot file per run
- wildcard DNS detection and filtering

---

## Author

Built by [@Tensii](https://github.com/Tensii)
