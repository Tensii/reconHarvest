# reconHarvest
`reconHarvest` is a Kali-friendly reconnaissance orchestrator for authorized security testing.

It automates practical recon workflows such as subdomain discovery, host probing, content discovery, URL collection, and lightweight vulnerability triage, while keeping output organized, resumable, and easy to review.


## Overview
Many recon scripts are either too minimal for repeated use or too brittle once a workflow grows. `reconHarvest` is designed to be practical for real engagement prep:

- resumable execution with stage markers
- generated, reviewable command flow
- organized workspace output per target and timestamp
- automatic setup for common dependencies where possible
- report-focused output for both humans and follow-up tooling

## Current behavior
The current script:

- can generate a workspace without running active recon
- can execute immediately with `--run`
- supports resuming an existing workspace with `--resume`
- supports custom run names with `-o` / `--output`
- uses sequential run names per target by default such as `1`, `2`, `3`
- validates arguments more strictly than before
- logs stage status to `stage_status.jsonl`
- normalizes dirsearch findings into `intel/dirsearch_normalized.json`

Note: the script no longer enforces a `scope.txt` execution guard. If you need hard scoping controls, add them back as a local policy requirement before using the tool in sensitive environments.

## Features
- Subdomain enumeration:
  - `subfinder`
  - `assetfinder`
- DNS resolution:
  - `dnsx`
- Live host and technology probing:
  - `httpx`
- Content discovery:
  - `dirsearch`
  - `ffuf` for directory and file discovery
- URL discovery:
  - `katana`
  - `gau`
- Focused nuclei phase 1 scan
- Intelligence artifacts:
  - parameter ranking
  - technology summary
  - endpoint ranking
  - normalized dirsearch output
- Human-readable and machine-readable summaries
- Stage status tracking across the generated runner

## Installation
```bash path=null start=null
git clone https://github.com/Tensii/reconHarvest.git
cd reconHarvest
chmod +x reconHarvest.sh
```

Default behavior:

- first run for a target becomes `outputs/<target>/1/`
- second run becomes `outputs/<target>/2/`
- third run becomes `outputs/<target>/3/`

If you want a readable name instead, use:

```bash path=null start=null
./reconHarvest.sh -o initial-pass example.com
```

## Requirements
Minimum runtime expectations:

- Bash 4+
- Python 3
- Kali/Debian-like Linux is the intended environment

The script can install or repair several dependencies automatically using:

- `apt`
- `go`
- `pipx`

It also checks for SecLists and will attempt:

1. `apt install seclists`
2. GitHub ZIP download fallback
3. minimal bundled wordlist fallback if SecLists still is not usable

## Usage
```bash path=null start=null
./reconHarvest.sh <target>
./reconHarvest.sh --run <target>
./reconHarvest.sh [-o <name>] [--parallel <n>] [--run] <target>
./reconHarvest.sh --resume <workdir> [--run]
```

## Examples
```bash path=null start=null
# Generate the first workspace for the target as outputs/example.com/1
./reconHarvest.sh example.com

# Generate and immediately run recon
./reconHarvest.sh --run example.com
# Use a custom workspace name
./reconHarvest.sh -o initial-pass --run example.com

# Run with a higher worker count
./reconHarvest.sh --parallel 80 --run example.com

# Resume an existing workspace
./reconHarvest.sh --resume outputs/example.com/2 --run
```

## Output layout
Each run creates a workspace in:

```text
outputs/<target>/<run-name>/
```

Common artifacts include:

- `run_commands.sh` — generated runnable workflow
- `COMMANDS_USED.md` — commands logged for traceability
- `stage_status.jsonl` — per-stage completion, fallback, and skip states
- `all_subdomains.txt`
- `resolved_subdomains.txt`
- `live_hosts.txt`
- `httpx_results.txt`
- `httpx_results.json`
- `ffuf/*.csv`
- `dirsearch/*.txt`
- `logs/*.log`
- `urls/`
- `intel/params_ranked.md`
- `intel/params_ranked.json`
- `intel/tech_summary.md`
- `intel/tech_summary.json`
- `intel/dirsearch_normalized.json`
- `intel/endpoints_ranked.md`
- `intel/endpoints_ranked.json`
- `nuclei_phase1.txt`
- `nuclei_phase1.jsonl`
- `summary.md`
- `summary.json`

## Stage model
The generated runner executes in broad stages:

1. nuclei template update
2. subdomain enumeration
3. DNS resolution
4. HTTP probing
5. per-host discovery
6. URL collection and parameter ranking
7. technology correlation
8. focused nuclei triage
9. endpoint ranking
10. summary generation

Completed stages are tracked in `.state/`, so resumed runs avoid repeating finished work unless you remove the marker files.

## Tooling notes
- `dirsearch` is installed via `pipx` and repaired if the environment is broken
- several Go-based tools are installed automatically if missing
- `httpx` live hosts are derived from JSON output rather than brittle text parsing
- host-specific output names include a short hash suffix to avoid filename collisions

## Operational notes
- empty nuclei output can be normal if no matching findings exist for the chosen filters
- if SecLists is unavailable, the script falls back to a minimal generated wordlist
- the generated runner performs its own runtime checks before scanning
- parallelism should be tuned to your system and network conditions

## Limitations
- designed primarily for Kali/Debian-like Linux environments
- relies on a number of external tools and network access for auto-install behavior
- does not currently enforce hard target scope restrictions by itself

## Suggested workflow
```bash path=null start=null
# 1. Create workspace and inspect generated commands
./reconHarvest.sh example.com
# 2. Review outputs/<target>/1/run_commands.sh
# 2. Review outputs/<target>/<timestamp>/run_commands.sh

# 3. Run it
bash outputs/example.com/1/run_commands.sh
```

Or run immediately:

```bash path=null start=null
./reconHarvest.sh --run example.com
```

## Roadmap ideas
- profile modes such as `safe`, `normal`, and `aggressive`
- optional notifications on completion or failure
- version snapshot per run
- wildcard DNS detection and filtering
- optional separate config file for tunables

## Author
Built by [@Tensii](https://github.com/Tensii)
