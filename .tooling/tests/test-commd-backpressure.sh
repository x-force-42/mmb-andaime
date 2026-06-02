#!/usr/bin/env bash
# Testes de backpressure / teto de concorrência do commd.sh (H5).
#
# Cobre:
#   R. reserve_slot — reserva atômica de slots:
#      R1 reserva até MMB_MAX_CONCURRENT (dests distintos) → sucesso
#      R2 acima do teto → rc 1 (full)
#      R3 mesmo dest já em-voo → rc 2 (dest-busy, sem gastar slot)
#   K. _reap_inflight — limpeza de tokens stale:
#      K1 PID morto → removido
#      K2 PID vivo → mantido
#      K3 token vazio fresco → mantido
#      K4 token vazio velho (> grace) → removido
#   D. gate do dispatch — adia sem perder:
#      D1 teto atingido → commd-dispatch-deferred (max-concurrent),
#         mensagem PERMANECE no inbox, NÃO é claimed, sem worker
#      D2 dest já em-voo → deferred (dest-busy), mensagem permanece
#
# Hermético: sandbox _MMB_TEST_MODE=1, funções chamadas direto. O gate do
# dispatch só é exercitado no caminho de ADIAR (que retorna antes de
# spawnar worker) — nenhum claude é iniciado.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX=$(mktemp -d /tmp/mmb-commd-bp-XXXXXX)
STATE_DIR="$SANDBOX/state"
LOG_DIR="$SANDBOX/logs"
INBOX_BASE="$SANDBOX/inbox"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$INBOX_BASE"
JOURNAL_LOG="$LOG_DIR/journal.jsonl"
JOURNAL_LOCK="$LOG_DIR/.journal.lock"
COMMD_LOG="$LOG_DIR/commd.log"
: > "$JOURNAL_LOG"; : > "$COMMD_LOG"

export _MMB_TEST_MODE=1
# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/commd.sh" || { echo "ERRO source commd.sh"; rm -rf "$SANDBOX"; exit 2; }
set +e

failures=0; ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }
journal_event_for_file() { grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "\"file\":\"$2\""; }
journal_event_has()      { grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "$2"; }
clean_inflight()         { rm -f "$INFLIGHT_DIR"/* 2>/dev/null; }
inflight_count()         { find "$INFLIGHT_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "── bash -n ──"
bash -n "$TOOLING_DIR/bin/commd.sh" 2>/dev/null && pass "commd.sh: bash -n passa" || fail "bash -n falhou"

# ── R. reserve_slot ───────────────────────────────────────────────
echo "── R. reserve_slot ──"
clean_inflight
ok=1
for d in d1 d2 d3 d4; do
  t=$(MMB_MAX_CONCURRENT=4 reserve_slot "$d"); rc=$?
  { [ "$rc" = 0 ] && [ -n "$t" ]; } || ok=0
done
[ "$ok" = 1 ] && pass "R1: reservou 4 dests distintos (rc 0 + token)" || fail "R1: falhou em reservar até o teto"
[ "$(inflight_count)" = "4" ] && pass "R1: 4 tokens no inflight" || fail "R1: count=$(inflight_count)"
t5=$(MMB_MAX_CONCURRENT=4 reserve_slot d5); rc5=$?
[ "$rc5" = "1" ] && pass "R2: 5º dest acima do teto → rc 1 (full)" || fail "R2: rc=$rc5 (esperado 1)"
[ -z "$t5" ] && pass "R2: sem token quando full" || fail "R2: ecoou token indevido"

clean_inflight
ta=$(MMB_MAX_CONCURRENT=4 reserve_slot cockpit); rca=$?
tb=$(MMB_MAX_CONCURRENT=4 reserve_slot cockpit); rcb=$?
[ "$rca" = "0" ] && pass "R3: 1ª reserva de cockpit ok" || fail "R3: rca=$rca"
[ "$rcb" = "2" ] && pass "R3: 2ª reserva do MESMO dest → rc 2 (dest-busy)" || fail "R3: rcb=$rcb (esperado 2)"
[ "$(inflight_count)" = "1" ] && pass "R3: dest-busy não gastou slot extra (1 token)" || fail "R3: count=$(inflight_count)"

# ── K. _reap_inflight ─────────────────────────────────────────────
echo "── K. _reap_inflight ──"
clean_inflight
# PID comprovadamente morto: spawna e espera terminar.
sh -c 'exit 0' & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid"  > "$INFLIGHT_DIR/dead--x"
echo "$$"        > "$INFLIGHT_DIR/alive--x"
: > "$INFLIGHT_DIR/freshempty--x"
: > "$INFLIGHT_DIR/oldempty--x"; touch -d "120 seconds ago" "$INFLIGHT_DIR/oldempty--x"
MMB_INFLIGHT_GRACE=60 _reap_inflight
[ ! -f "$INFLIGHT_DIR/dead--x" ]       && pass "K1: token de PID morto removido" || fail "K1: dead remanescente"
[ -f "$INFLIGHT_DIR/alive--x" ]        && pass "K2: token de PID vivo mantido" || fail "K2: alive removido"
[ -f "$INFLIGHT_DIR/freshempty--x" ]   && pass "K3: token vazio fresco mantido" || fail "K3: fresh removido"
[ ! -f "$INFLIGHT_DIR/oldempty--x" ]   && pass "K4: token vazio velho (>grace) removido" || fail "K4: old remanescente"

# ── D. gate do dispatch (caminho de adiar) ────────────────────────
echo "── D. dispatch defere sem perder ──"
# D1 — teto global atingido (4 tokens de OUTROS dests; cockpit livre mas full)
clean_inflight; : > "$JOURNAL_LOG"
for d in logger aquarium expense-web expense-api; do echo "$$" > "$INFLIGHT_DIR/${d}--t"; done
mkdir -p "$INBOX_BASE/cockpit"
msg1="$INBOX_BASE/cockpit/2026-06-02T00-00-00Z_master_briefing_bp1.md"
echo "test" > "$msg1"
MMB_MAX_CONCURRENT=4 dispatch "$msg1"
[ -f "$msg1" ] && pass "D1: mensagem PERMANECE no inbox (não perdida)" || fail "D1: mensagem sumiu"
[ ! -f "$INBOX_BASE/cockpit/.processing/$(basename "$msg1")" ] && pass "D1: NÃO foi claimed (.processing vazio)" || fail "D1: foi claimed"
journal_event_for_file commd-dispatch-deferred "$(basename "$msg1")" && pass "D1: commd-dispatch-deferred emitido" || fail "D1: sem evento deferred"
journal_event_has commd-dispatch-deferred '"reason":"max-concurrent"' && pass "D1: reason=max-concurrent" || fail "D1: reason errado"
journal_event_for_file commd-dispatch "$(basename "$msg1")" && fail "D1: emitiu commd-dispatch (não devia)" || pass "D1: NÃO emitiu commd-dispatch"

# D2 — dest cockpit já em-voo (1 token), teto não atingido
clean_inflight; : > "$JOURNAL_LOG"
echo "$$" > "$INFLIGHT_DIR/cockpit--t"
msg2="$INBOX_BASE/cockpit/2026-06-02T00-00-01Z_master_briefing_bp2.md"
echo "test" > "$msg2"
MMB_MAX_CONCURRENT=4 dispatch "$msg2"
[ -f "$msg2" ] && pass "D2: mensagem permanece no inbox" || fail "D2: mensagem sumiu"
journal_event_has commd-dispatch-deferred '"reason":"dest-busy"' && pass "D2: deferred reason=dest-busy" || fail "D2: reason errado"
journal_event_for_file commd-dispatch "$(basename "$msg2")" && fail "D2: emitiu commd-dispatch (não devia)" || pass "D2: NÃO emitiu commd-dispatch"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"; exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"; exit 1
fi
