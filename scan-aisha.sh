#!/usr/bin/env bash
#
# scan-aisha.sh — parametrický runner pro DockerScan v2 nad Aisha kontejnery.
#
# Vybere lokální image podle konvence názvu (výchozí: ^aisha-), pustí na každý
# `dockerscan` s volitelnou sadou scannerů, uloží per-image report + log a na
# konci vypíše souhrnnou tabulku. Vlastní exit kód = nejhorší nález napříč
# všemi image (0 čisto / 1 HIGH / 2 CRITICAL) → přímo použitelné v CI.
#
# Pozn.: DockerScan zapisuje SARIF do pevného souboru `dockerscan-report.sarif`
# v aktuálním adresáři. Každý sken proto běží ve svém vlastním výstupním
# podadresáři, aby se reporty nepřepisovaly (i při -j > 1).
#
# Kompatibilní s bash 3.2 (systémový /bin/bash na macOS).

set -u -o pipefail

# ── Výchozí hodnoty (přepsatelné parametry / env) ──────────────────────────
FILTER="${FILTER:-^aisha-}"          # regex nad "repo:tag" v `docker images`
SCANNERS="${SCANNERS:-}"             # prázdné = všechny scannery (výchozí nástroje)
FAIL_ON="${FAIL_ON:-critical}"      # none | high | critical — od čeho nenulový exit
OUTDIR="${OUTDIR:-scan-results}"    # kam ukládat reporty + souhrn
JOBS="${JOBS:-1}"                    # paralelní skeny
VERBOSITY="${VERBOSITY:--q}"        # -q | -v | "" (předává se do dockerscan)
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<'EOF'
scan-aisha.sh — parametrický DockerScan runner nad Aisha kontejnery

POUŽITÍ:
  ./scan-aisha.sh [volby]

VOLBY:
  -f, --filter <regex>    Výběr image podle "repo:tag" (výchozí: ^aisha-)
  -s, --scanners <list>   Scannery: cis,secrets,supplychain,vulnerabilities,runtime
                          (prázdné = všechny výchozí)
      --fail-on <úroveň>  none | high | critical  (výchozí: critical)
  -o, --output <dir>      Výstupní adresář (výchozí: scan-results)
  -j, --jobs <N>          Paralelní skeny (výchozí: 1)
  -v, --verbose           Podrobný výstup skenu (jinak tichý)
      --dry-run           Jen vypíše, co by se skenovalo
  -h, --help              Tato nápověda

PŘÍKLADY:
  ./scan-aisha.sh                                  # všechny aisha-* image, všechny scannery
  ./scan-aisha.sh -s secrets,vulnerabilities       # jen tajemství + CVE
  ./scan-aisha.sh -f '^aisha-local-svc-' -j 4      # jen mikroslužby, 4 paralelně
  ./scan-aisha.sh --fail-on high -o /tmp/reports   # CI: spadni už na HIGH
  ./scan-aisha.sh --dry-run                        # náhled výběru

EXIT KÓDY (agregát nejhoršího nálezu):
  0  čisto     1  nalezen HIGH     2  nalezen CRITICAL     3  chyba běhu
EOF
}

# ── Interní režim: sken jednoho image (volá si sám přes xargs) ─────────────
if [ "${1:-}" = "__scan_one" ]; then
  image="$2"
  safe="$(printf '%s' "$image" | tr '/:' '__')"
  dir="$OUTDIR/$safe"
  mkdir -p "$dir"

  # sestav argumenty
  args=""
  [ -n "$VERBOSITY" ] && args="$args $VERBOSITY"
  [ -n "$SCANNERS" ] && args="$args --scanners $SCANNERS"

  # spusť v izolovaném cwd → SARIF (dockerscan-report.sarif) padne sem
  start=$(date +%s 2>/dev/null || echo 0)
  ( cd "$dir" && dockerscan $args "$image" ) >"$dir/scan.log" 2>&1
  code=$?
  end=$(date +%s 2>/dev/null || echo 0)

  # Exit 1 je u dockerscanu přetížený (HIGH i chyba běhu, např. nedostupný
  # daemon). Rozlišíme podle markeru úspěšného skenu v logu.
  if grep -q 'SCAN RESULTS' "$dir/scan.log" 2>/dev/null; then
    case $code in
      0) status="CLEAN" ;;
      1) status="HIGH" ;;
      2) status="CRITICAL" ;;
      *) status="ERROR" ;;
    esac
  else
    status="ERROR"   # sken nedoběhl (socket, chybějící image, chyba nástroje)
  fi

  # jeden řádek do souhrnu: status <TAB> exit <TAB> sekundy <TAB> image
  printf '%s\t%s\t%s\t%s\n' "$status" "$code" "$((end - start))" "$image" \
    >> "$OUTDIR/summary.tsv"
  printf '  %-9s (exit %s, %ss)  %s\n' "$status" "$code" "$((end - start))" "$image"
  exit 0
fi

# ── Parsování argumentů ────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--filter)   FILTER="$2"; shift 2 ;;
    -s|--scanners) SCANNERS="$2"; shift 2 ;;
    --fail-on)     FAIL_ON="$2"; shift 2 ;;
    -o|--output)   OUTDIR="$2"; shift 2 ;;
    -j|--jobs)     JOBS="$2"; shift 2 ;;
    -v|--verbose)  VERBOSITY="-v"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Neznámá volba: $1" >&2; usage >&2; exit 3 ;;
  esac
done

# ── Preflight ──────────────────────────────────────────────────────────────
command -v dockerscan >/dev/null 2>&1 || { echo "✗ dockerscan není na PATH" >&2; exit 3; }
command -v docker     >/dev/null 2>&1 || { echo "✗ docker není na PATH" >&2; exit 3; }

# dockerscan míří napevno na /var/run/docker.sock a neřídí se docker kontextem.
# Když DOCKER_HOST není nastaven a default socket neexistuje, odvodíme endpoint
# z aktivního kontextu (typicky Docker Desktop: ~/.docker/run/docker.sock).
if [ -z "${DOCKER_HOST:-}" ] && [ ! -S /var/run/docker.sock ]; then
  ctx_host=$(docker context inspect 2>/dev/null \
               | grep -m1 '"Host"' | sed 's/.*"Host": *"\([^"]*\)".*/\1/')
  if [ -n "$ctx_host" ]; then
    export DOCKER_HOST="$ctx_host"
    echo "ℹ DOCKER_HOST odvozen z kontextu: $DOCKER_HOST"
  fi
fi

# ── Výběr image podle konvence názvu ───────────────────────────────────────
images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
           | grep -E "$FILTER" | grep -v '<none>' | sort -u)

if [ -z "$images" ]; then
  echo "Žádný image neodpovídá filtru: $FILTER" >&2
  exit 3
fi

count=$(printf '%s\n' "$images" | wc -l | tr -d ' ')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DockerScan runner  •  filtr: $FILTER  •  $count image"
echo "  scannery: ${SCANNERS:-<všechny>}   jobs: $JOBS   fail-on: $FAIL_ON"
echo "  výstup:   $OUTDIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$DRY_RUN" = "1" ]; then
  printf '%s\n' "$images" | sed 's/^/  • /'
  echo "(dry-run: nic se nespustí)"
  exit 0
fi

# čerstvý výstupní adresář + souhrn
mkdir -p "$OUTDIR"
: > "$OUTDIR/summary.tsv"

# exportuj konfiguraci pro workery (__scan_one běží v subshellu přes xargs);
# DOCKER_HOST se dědí, pokud byl výše nastaven/odvozen
export SCANNERS VERBOSITY OUTDIR

# ── Běh: sekvenčně (JOBS=1) nebo paralelně přes xargs -P ───────────────────
if [ "$JOBS" -le 1 ]; then
  printf '%s\n' "$images" | while IFS= read -r img; do
    "$0" __scan_one "$img"
  done
else
  printf '%s\n' "$images" | xargs -P "$JOBS" -I{} "$0" __scan_one {}
fi

# ── Souhrn ─────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SOUHRN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sort "$OUTDIR/summary.tsv" | awk -F'\t' '{ printf "  %-9s  %s\n", $1, $4 }'

n_crit=$(awk -F'\t' '$1=="CRITICAL"' "$OUTDIR/summary.tsv" | wc -l | tr -d ' ')
n_high=$(awk -F'\t' '$1=="HIGH"'     "$OUTDIR/summary.tsv" | wc -l | tr -d ' ')
n_err=$(awk  -F'\t' '$1=="ERROR"'    "$OUTDIR/summary.tsv" | wc -l | tr -d ' ')
n_clean=$(awk -F'\t' '$1=="CLEAN"'   "$OUTDIR/summary.tsv" | wc -l | tr -d ' ')

echo "─────────────────────────────────────────────────────────────"
printf '  CRITICAL: %s   HIGH: %s   CLEAN: %s   ERROR: %s\n' \
  "$n_crit" "$n_high" "$n_clean" "$n_err"
echo "  Reporty:  $OUTDIR/<image>/dockerscan-report.sarif (+ scan.log)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Agregovaný exit kód dle --fail-on ──────────────────────────────────────
if [ "$n_err" -gt 0 ]; then
  # chyby běhu nemaskuj úspěchem, ale nepřebij závažnější nález níže
  :
fi

case "$FAIL_ON" in
  critical) [ "$n_crit" -gt 0 ] && exit 2; [ "$n_err" -gt 0 ] && exit 3; exit 0 ;;
  high)     [ "$n_crit" -gt 0 ] && exit 2; [ "$n_high" -gt 0 ] && exit 1; [ "$n_err" -gt 0 ] && exit 3; exit 0 ;;
  none)     exit 0 ;;
  *) echo "Neplatné --fail-on: $FAIL_ON (none|high|critical)" >&2; exit 3 ;;
esac
