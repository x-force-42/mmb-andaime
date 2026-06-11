#!/usr/bin/env bash
# Testes herméticos do lib de liveness por PID (H4) — bin/lib/heartbeat.sh.
#
# Cobre a regra de decisão do heartbeat por PID + o fallback por mtime:
#   A. mmb_heartbeat_alive() — predicado puro:
#      A1 PID vivo + LOG ausente        → vivo  (PID vence ausência de log)
#      A2 PID vivo + LOG stale          → vivo  (PID VENCE mtime stale) [central]
#      A3 PID morto + LOG fresco        → morto (PID presente é autoritativo,
#                                                NÃO cai no fallback)
#      A4 sem PID + LOG fresco          → vivo  (fallback compat)
#      A5 sem PID + LOG stale           → morto (fallback = comportamento antigo)
#      A6 sem PID + LOG ausente         → morto
#      A7 PID vazio + LOG fresco        → vivo  (lixo → fallback seguro)
#      A8 PID não-numérico + LOG stale  → morto (lixo → fallback seguro)
#      A9 PID "0" + LOG fresco          → vivo  (0 inválido → fallback seguro)
#   B. mmb_heartbeat_tick_once() — efeito sobre o arquivo que o WATCHDOG consome:
#      B1 PID vivo + LOG stale  → hb_file TOCADO  (worker vivo silencioso
#                                                  mantém heartbeat fresco) [central]
#      B2 PID morto             → hb_file NÃO tocado (não mantém heartbeat)
#      B3 sem PID + LOG fresco  → hb_file TOCADO  (fallback)
#      B4 sem PID + LOG stale   → hb_file NÃO tocado (fallback compat)
#
# Hermético: sandbox em /tmp, processos reais de curta/longa duração pra
# PID vivo/morto, sem claude e sem GitHub.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/lib/heartbeat.sh" || {
  echo "ERRO: falha ao sourcear lib/heartbeat.sh"
  exit 2
}

SANDBOX=$(mktemp -d /tmp/mmb-heartbeat-XXXXXX)
LOG="$SANDBOX/worker.log"
PIDF="$SANDBOX/heartbeat.pid"
HBF="$SANDBOX/heartbeat.txt"
WINDOW=120

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# Processo vivo de longa duração e um PID já morto (reusados nos casos).
sleep 120 & ALIVE_PID=$!
( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true

cleanup() { kill "$ALIVE_PID" 2>/dev/null || true; rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Helpers de fixture
fresh_log() { : > "$LOG"; }                              # mtime = agora
stale_log() { : > "$LOG"; touch -d "600 seconds ago" "$LOG"; }
no_log()    { rm -f "$LOG"; }

# ── bash -n ──────────────────────────────────────────────────────
echo "── bash -n ──"
bash -n "$TOOLING_DIR/bin/lib/heartbeat.sh" 2>/dev/null && pass "heartbeat.sh: bash -n passa" || fail "heartbeat.sh bash -n falhou"
bash -n "$TOOLING_DIR/bin/worker.sh" 2>/dev/null && pass "worker.sh: bash -n passa" || fail "worker.sh bash -n falhou"

# ── A. mmb_heartbeat_alive() ─────────────────────────────────────
echo "── A. mmb_heartbeat_alive() ──"

echo "$ALIVE_PID" > "$PIDF"; no_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && pass "A1: PID vivo + LOG ausente → vivo" || fail "A1: devia ser vivo"

echo "$ALIVE_PID" > "$PIDF"; stale_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && pass "A2: PID vivo + LOG stale → vivo (PID vence mtime)" || fail "A2: devia ser vivo"

echo "$DEAD_PID" > "$PIDF"; fresh_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && fail "A3: PID morto + LOG fresco caiu no fallback (devia ser morto)" || pass "A3: PID morto + LOG fresco → morto (PID autoritativo)"

rm -f "$PIDF"; fresh_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && pass "A4: sem PID + LOG fresco → vivo (fallback)" || fail "A4: devia ser vivo"

rm -f "$PIDF"; stale_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && fail "A5: sem PID + LOG stale devia ser morto" || pass "A5: sem PID + LOG stale → morto (fallback antigo)"

rm -f "$PIDF"; no_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && fail "A6: sem PID + sem LOG devia ser morto" || pass "A6: sem PID + sem LOG → morto"

: > "$PIDF"; fresh_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && pass "A7: PID vazio + LOG fresco → vivo (fallback seguro)" || fail "A7: devia cair no fallback vivo"

printf 'lixo-nao-numerico\n' > "$PIDF"; stale_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && fail "A8: PID não-numérico devia cair no fallback (morto c/ log stale)" || pass "A8: PID não-numérico + LOG stale → morto (fallback seguro)"

echo "0" > "$PIDF"; fresh_log
mmb_heartbeat_alive "$PIDF" "$LOG" "$WINDOW" && pass "A9: PID '0' + LOG fresco → vivo (0 inválido → fallback)" || fail "A9: devia cair no fallback vivo"

# ── B. mmb_heartbeat_tick_once() (efeito no arquivo do watchdog) ──
echo "── B. mmb_heartbeat_tick_once() ──"

# Marca hb_file como antigo; "tocado" = mtime avançou.
touched() { local before=$1; local after; after=$(stat -c %Y "$HBF" 2>/dev/null || echo 0); [ "$after" -gt "$before" ]; }
age_hb()  { : > "$HBF"; touch -d "500 seconds ago" "$HBF"; stat -c %Y "$HBF"; }

b=$(age_hb); echo "$ALIVE_PID" > "$PIDF"; stale_log
mmb_heartbeat_tick_once "$PIDF" "$LOG" "$WINDOW" "$HBF"
touched "$b" && pass "B1: PID vivo + LOG stale → hb TOCADO (vivo silencioso mantém heartbeat)" || fail "B1: hb não foi tocado"

b=$(age_hb); echo "$DEAD_PID" > "$PIDF"; fresh_log
mmb_heartbeat_tick_once "$PIDF" "$LOG" "$WINDOW" "$HBF"
touched "$b" && fail "B2: PID morto tocou o hb (não devia)" || pass "B2: PID morto → hb NÃO tocado"

b=$(age_hb); rm -f "$PIDF"; fresh_log
mmb_heartbeat_tick_once "$PIDF" "$LOG" "$WINDOW" "$HBF"
touched "$b" && pass "B3: sem PID + LOG fresco → hb TOCADO (fallback)" || fail "B3: hb não foi tocado"

b=$(age_hb); rm -f "$PIDF"; stale_log
mmb_heartbeat_tick_once "$PIDF" "$LOG" "$WINDOW" "$HBF"
touched "$b" && fail "B4: sem PID + LOG stale tocou o hb (não devia)" || pass "B4: sem PID + LOG stale → hb NÃO tocado (fallback compat)"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
