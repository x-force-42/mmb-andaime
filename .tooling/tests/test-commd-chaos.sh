#!/usr/bin/env bash
# Testes de injeção de falha (chaos) do commd.sh (H2).
#
# Cobre o "estado honesto" e o sweep de órfãos frios:
#   A. move_msg() — mv com captura de rc:
#      A1 sucesso → rc 0, arquivo movido, sem commd-move-failed
#      A2 falha (dir-alvo inexistente) → rc 1, commd-move-failed, arquivo FICA
#   B. finalize_dispatch() — estado honesto por rc:
#      B1 rc=0 ok → commd-done + commd-worker-done, arquivo em .done/
#      B2 rc=0 com .done/ quebrado → NÃO mente (sem commd-done),
#         commd-move-failed, arquivo FICA em .processing/
#      B3 rc=137 (timeout) ok → commd-dead + commd-worker-timeout
#      B4 rc=1 com .dead/ quebrado → commd-worker-exit (sempre),
#         commd-move-failed, SEM commd-dead, arquivo FICA
#   C. reconcile_processing_once() — sweep (dispatch stubbado):
#      C1 órfão frio → re-despachado + commd-processing-recovered
#      C2 arquivo jovem → ignorado (pode ter worker vivo)
#      C3 órfão frio mas heartbeat fresco → ignorado (worker vivo)
#
# Hermético: sandbox _MMB_TEST_MODE=1, funções chamadas direto, sem
# claude e sem GitHub. dispatch é stubbado na seção C pra não spawnar
# worker real.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX=$(mktemp -d /tmp/mmb-commd-chaos-XXXXXX)
STATE_DIR="$SANDBOX/state"
LOG_DIR="$SANDBOX/logs"
INBOX_BASE="$SANDBOX/inbox"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$INBOX_BASE"
JOURNAL_LOG="$LOG_DIR/journal.jsonl"
JOURNAL_LOCK="$LOG_DIR/.journal.lock"
COMMD_LOG="$LOG_DIR/commd.log"
: > "$JOURNAL_LOG"
: > "$COMMD_LOG"

export _MMB_TEST_MODE=1

# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/commd.sh" || {
  echo "ERRO: falha ao sourcear commd.sh"
  rm -rf "$SANDBOX"
  exit 2
}
# commd.sh ativa `set -e`; o teste usa rc explícito — desliga pra não
# abortar em comandos que retornam !=0 de propósito.
set +e

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# Verdadeiro se há linha de journal com aquele event E aquele file.
journal_event_for_file() {
  grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "\"file\":\"$2\""
}
# Verdadeiro se há linha com event + um campo k:v literal.
journal_event_has() {
  grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "$2"
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ── bash -n ──────────────────────────────────────────────────────
echo "── bash -n ──"
bash -n "$TOOLING_DIR/bin/commd.sh" 2>/dev/null && pass "commd.sh: bash -n passa" || fail "bash -n falhou"

# ── A. move_msg() ────────────────────────────────────────────────
echo "── A. move_msg() ──"

: > "$JOURNAL_LOG"
fa1="$INBOX_BASE/cockpit/.processing/msg-a1.md"
echo "a1" > "$fa1"
move_msg "$fa1" "$INBOX_BASE/cockpit/.done" cockpit msg-a1.md done; rc=$?
[ "$rc" = 0 ] && pass "A1: sucesso retorna 0" || fail "A1: rc=$rc"
[ -f "$INBOX_BASE/cockpit/.done/msg-a1.md" ] && pass "A1: arquivo em .done/" || fail "A1: não foi pra .done/"
[ ! -f "$fa1" ] && pass "A1: saiu de .processing/" || fail "A1: ainda em .processing/"
journal_event_for_file commd-move-failed msg-a1.md && fail "A1: emitiu move-failed no sucesso" || pass "A1: sem commd-move-failed"

: > "$JOURNAL_LOG"
fa2="$INBOX_BASE/cockpit/.processing/msg-a2.md"
echo "a2" > "$fa2"
move_msg "$fa2" "$INBOX_BASE/cockpit/.dir-inexistente" cockpit msg-a2.md done; rc=$?
[ "$rc" = 1 ] && pass "A2: falha retorna 1" || fail "A2: rc=$rc"
[ -f "$fa2" ] && pass "A2: arquivo PERMANECE em .processing/" || fail "A2: sumiu de .processing/"
journal_event_for_file commd-move-failed msg-a2.md && pass "A2: commd-move-failed emitido" || fail "A2: sem commd-move-failed"
journal_event_has commd-move-failed '"kind":"move-failed"' && pass "A2: kind=move-failed" || fail "A2: kind errado"
journal_event_has commd-move-failed '"sev":"error"' && pass "A2: sev=error" || fail "A2: sev errado"

# ── B. finalize_dispatch() ───────────────────────────────────────
echo "── B. finalize_dispatch() ──"
# Estado honesto do H2 é a semântica SEM retry. O H3 tornou o retry o
# default (MMB_MAX_ATTEMPTS=3); aqui fixamos 0 pra testar o caminho H2
# isolado (worker-exit → .dead direto). O retry tem teste próprio
# (test-commd-retry.sh).
MMB_MAX_ATTEMPTS=0

# B1 — rc=0 caminho feliz
: > "$JOURNAL_LOG"
fb1="$INBOX_BASE/cockpit/.processing/msg-b1.md"; echo b1 > "$fb1"
finalize_dispatch 0 "$fb1" cockpit msg-b1.md
journal_event_for_file commd-done msg-b1.md && pass "B1: commd-done emitido" || fail "B1: sem commd-done"
journal_event_for_file commd-worker-done msg-b1.md && pass "B1: commd-worker-done emitido" || fail "B1: sem commd-worker-done"
[ -f "$INBOX_BASE/cockpit/.done/msg-b1.md" ] && pass "B1: arquivo em .done/" || fail "B1: não foi pra .done/"

# B2 — rc=0 mas .done/ quebrado → NÃO mente
: > "$JOURNAL_LOG"
fb2="$INBOX_BASE/cockpit/.processing/msg-b2.md"; echo b2 > "$fb2"
rm -rf "$INBOX_BASE/cockpit/.done"
finalize_dispatch 0 "$fb2" cockpit msg-b2.md
journal_event_for_file commd-done msg-b2.md && fail "B2: MENTIU (commd-done com move falho)" || pass "B2: NÃO emitiu commd-done (honesto)"
journal_event_for_file commd-move-failed msg-b2.md && pass "B2: commd-move-failed emitido" || fail "B2: sem commd-move-failed"
[ -f "$fb2" ] && pass "B2: arquivo PERMANECE em .processing/" || fail "B2: sumiu"
mkdir -p "$INBOX_BASE/cockpit/.done"

# B3 — rc=137 (timeout) caminho feliz
: > "$JOURNAL_LOG"
fb3="$INBOX_BASE/cockpit/.processing/msg-b3.md"; echo b3 > "$fb3"
finalize_dispatch 137 "$fb3" cockpit msg-b3.md
journal_event_for_file commd-dead msg-b3.md && pass "B3: commd-dead emitido (move ok)" || fail "B3: sem commd-dead"
journal_event_for_file commd-worker-timeout msg-b3.md && pass "B3: commd-worker-timeout emitido" || fail "B3: sem worker-timeout"
journal_event_has commd-worker-timeout '"kind":"worker-timeout"' && pass "B3: kind=worker-timeout" || fail "B3: kind errado"
[ -f "$INBOX_BASE/cockpit/.dead/msg-b3.md" ] && pass "B3: arquivo em .dead/" || fail "B3: não foi pra .dead/"

# B4 — rc=1 (exit) com .dead/ quebrado
: > "$JOURNAL_LOG"
fb4="$INBOX_BASE/cockpit/.processing/msg-b4.md"; echo b4 > "$fb4"
rm -rf "$INBOX_BASE/cockpit/.dead"
finalize_dispatch 1 "$fb4" cockpit msg-b4.md
journal_event_for_file commd-worker-exit msg-b4.md && pass "B4: commd-worker-exit emitido (verdade do worker, sempre)" || fail "B4: sem worker-exit"
journal_event_for_file commd-move-failed msg-b4.md && pass "B4: commd-move-failed emitido" || fail "B4: sem move-failed"
journal_event_for_file commd-dead msg-b4.md && fail "B4: MENTIU (commd-dead com move falho)" || pass "B4: NÃO emitiu commd-dead (honesto)"
[ -f "$fb4" ] && pass "B4: arquivo PERMANECE em .processing/" || fail "B4: sumiu"
mkdir -p "$INBOX_BASE/cockpit/.dead"

# ── C. reconcile_processing_once() — sweep ───────────────────────
echo "── C. reconcile_processing_once() (sweep) ──"

# Stub de dispatch: captura o path, NÃO spawna worker real.
DISPATCH_CALLS="$SANDBOX/dispatch-calls.txt"
: > "$DISPATCH_CALLS"
dispatch() { printf '%s\n' "$1" >> "$DISPATCH_CALLS"; }

: > "$JOURNAL_LOG"

# C1 — cockpit: órfão frio, sem heartbeat
rm -f "$STATE_DIR/heartbeat-cockpit.txt"
c1="$INBOX_BASE/cockpit/.processing/msg-c1-cold.md"; echo c1 > "$c1"; touch -d "120 seconds ago" "$c1"
# C2 — logger: arquivo jovem (mtime = agora), sem heartbeat
rm -f "$STATE_DIR/heartbeat-logger.txt"
c2="$INBOX_BASE/logger/.processing/msg-c2-young.md"; echo c2 > "$c2"
# C3 — aquarium: órfão frio MAS heartbeat fresco (worker vivo)
c3="$INBOX_BASE/aquarium/.processing/msg-c3-coldlive.md"; echo c3 > "$c3"; touch -d "120 seconds ago" "$c3"
touch "$STATE_DIR/heartbeat-aquarium.txt"

# Thresholds pequenos: min_age = 2 + 1 = 3s; heartbeat fresco se < 5s.
MMB_WORKER_TIMEOUT=2
MMB_PROCESSING_SWEEP_GRACE=1
MMB_WATCHDOG_STALE_SECONDS=5
reconcile_processing_once

grep -q "msg-c1-cold.md" "$DISPATCH_CALLS" && pass "C1: órfão frio re-despachado" || fail "C1: órfão frio NÃO despachado"
journal_event_for_file commd-processing-recovered msg-c1-cold.md && pass "C1: commd-processing-recovered emitido" || fail "C1: sem evento de recuperação"
grep -q "msg-c2-young.md" "$DISPATCH_CALLS" && fail "C2: arquivo jovem foi despachado" || pass "C2: arquivo jovem ignorado (< min_age)"
grep -q "msg-c3-coldlive.md" "$DISPATCH_CALLS" && fail "C3: órfão com heartbeat fresco despachado (worker vivo!)" || pass "C3: órfão com worker vivo ignorado"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
