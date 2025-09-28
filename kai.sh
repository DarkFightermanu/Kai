#!/usr/bin/env bash
# ffuf sequential fuzz with spacious remaining percent display + printed command/wordlist
# Usage: ./s.sh <subdomains.txt> <wordlist.txt> [extra-ffuf-args]
# Requires: ffuf; optional: pv (for exact per-wordlist progress)

set -euo pipefail
IFS=$'\n\t'

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <subdomains.txt> <wordlist.txt> [extra-ffuf-args]"
  exit 2
fi

SUBDOM_FILE="$1"
WORDLIST="$2"
shift 2
EXTRA_ARGS=("$@")

if [[ ! -f "$SUBDOM_FILE" ]]; then
  echo "Subdomain file not found: $SUBDOM_FILE" >&2
  exit 3
fi
if [[ ! -f "$WORDLIST" ]]; then
  echo "Wordlist file not found: $WORDLIST" >&2
  exit 3
fi
if ! command -v ffuf >/dev/null 2>&1; then
  echo "ffuf not installed or not in PATH" >&2
  exit 4
fi

# detect pv + ffuf stdin support
PV_AVAILABLE=false
if command -v pv >/dev/null 2>&1; then PV_AVAILABLE=true; fi

FFUF_SUPPORTS_STDIN=false
if ffuf -h 2>&1 | grep -q '\-w'; then FFUF_SUPPORTS_STDIN=true; fi

USE_PV_AND_STDIN=false
if $PV_AVAILABLE && $FFUF_SUPPORTS_STDIN; then USE_PV_AND_STDIN=true; fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTDIR="ffuf-results_$TIMESTAMP"
mkdir -p "$OUTDIR"

# base ffuf args (we include -w where needed)
FFUF_BASE=( -recursion -recursion-depth 3 -ic -v -mc 200 -H "User-Agent: Mozilla/5.0" )

TOTAL=$(wc -l < "$SUBDOM_FILE" | tr -d ' ')
COUNTER=0

print_header() {
  printf "\n==============================================\n"
  printf "%s\n" "$1"
  printf "==============================================\n"
}

# helper to print a safely quoted command
print_cmd() {
  # $@ is command array
  printf "%s" ""
  for arg in "$@"; do
    printf "%q " "$arg"
  done
  printf "\n"
}

while IFS= read -r RAW_SUB; do
  COUNTER=$((COUNTER+1))
  SUB=$(echo "$RAW_SUB" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|/*$||')
  if [[ -z "$SUB" ]] || [[ "$SUB" =~ ^# ]]; then
    continue
  fi

  print_header "[$COUNTER/$TOTAL] Starting: $SUB"

  SAFE_NAME=$(echo "$SUB" | sed 's/[^A-Za-z0-9._-]/_/g')
  DOMAIN_OUTDIR="$OUTDIR/$SAFE_NAME"
  mkdir -p "$DOMAIN_OUTDIR"
  LOGFILE="$DOMAIN_OUTDIR/${SAFE_NAME}.log"

  if [[ "$SUB" =~ ^https?:// ]]; then
    URL_TEMPLATE="$SUB/FUZZ"
  else
    URL_TEMPLATE="https://$SUB/FUZZ"
  fi

  WORDS_TOTAL=$(wc -l < "$WORDLIST" | tr -d ' ')
  [[ $WORDS_TOTAL -le 0 ]] && WORDS_TOTAL=1

  echo "Using wordlist: $WORDLIST (lines: $WORDS_TOTAL)"

  if $USE_PV_AND_STDIN; then
    echo "Using pv -> ffuf streaming mode (exact per-wordlist progress)"
    # ffuf reads from stdin with -w -:FUZZ
    FFUF_CMD=(ffuf -u "$URL_TEMPLATE" -w -:FUZZ "${FFUF_BASE[@]}" "${EXTRA_ARGS[@]}")

    # print the exact command
    printf "Running command: "
    print_cmd "${FFUF_CMD[@]}"
    printf "pv -l -s %s %s | " "$WORDS_TOTAL" "$WORDLIST"
    print_cmd "${FFUF_CMD[@]}"

    # run pv feeding the wordlist into ffuf; ffuf output goes to logfile
    pv -l -s "$WORDS_TOTAL" -N "$SAFE_NAME" "$WORDLIST" | "${FFUF_CMD[@]}" > "$LOGFILE" 2>&1 &

    FFUF_PID=$!
    wait "$FFUF_PID" || true
    echo ""
    echo "Finished: $SUB -- log: $LOGFILE"

  else
    echo "pv/stdin streaming unavailable — using heuristic progress (approximate)"
    TMP_JSON=$(mktemp)
    # include -w <wordlist:FUZZ> in fallback
    FFUF_CMD=(ffuf -u "$URL_TEMPLATE" -w "$WORDLIST:FUZZ" -o "$TMP_JSON" -of json "${FFUF_BASE[@]}" "${EXTRA_ARGS[@]}")

    # print the exact command
    printf "Running command: "
    print_cmd "${FFUF_CMD[@]}"

    ( echo "Running: ffuf -u $URL_TEMPLATE -w $WORDLIST" ; "${FFUF_CMD[@]}" ) > "$LOGFILE" 2>&1 &
    FFUF_PID=$!

    last_pct=-1
    while kill -0 "$FFUF_PID" >/dev/null 2>&1; do
      sleep 1
      if [[ -f "$TMP_JSON" ]]; then
        results_count=$(grep -o '"status"' "$TMP_JSON" 2>/dev/null | wc -l || true)
      else
        results_count=0
      fi
      remaining=$(( WORDS_TOTAL - results_count ))
      [[ $remaining -lt 0 ]] && remaining=0
      pct_done=$(( results_count * 100 / WORDS_TOTAL ))
      pct_remaining=$(( 100 - pct_done ))

      if [[ $pct_remaining -ne $last_pct ]]; then
        printf "\n    Subdomain : %s\n" "$SUB"
        printf "    Wordlist  : %s (total lines: %d)\n" "$(basename "$WORDLIST")" "$WORDS_TOTAL"
        printf "    Tried     : %d\n" "$results_count"
        printf "    Remaining : %d (%d%%)\n" "$remaining" "$pct_remaining"
        printf "    Log file  : %s\n\n" "$LOGFILE"
        last_pct=$pct_remaining
      fi
    done

    wait "$FFUF_PID" || true
    rm -f "$TMP_JSON" || true
    echo "Finished: $SUB -- log: $LOGFILE"
  fi

  sleep 1
done < "$SUBDOM_FILE"

print_header "All done. Results: $OUTDIR"
echo "IMPORTANT: Only scan targets you own or have explicit permission to test."
