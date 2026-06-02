#!/usr/bin/env bash
# Testes do retry-budget / dead-letter do commd.sh (H3).
#
# Cobre (mapeado aos critérios de aceite):
#   R1  MMB_MAX_ATTEMPTS=0 → worker-exit vai direto pra .dead/, sem
#       sidecar, sem retry (criterio 4: comportamento pré-H3 preservado)
#   R2  worker-exit (MAX=3) incrementa attempts e NÃO vai pra .dead/;
#       cria sidecar op=dispatch (criterio 1)
#   R3  backoff não vencido → reconcile_retries_once NÃO re-despacha (crit 2)
#   R4  backoff vencido → reconcile_retries_once re-despacha (crit 2)
#   R5  esgotar attempts → vai pra .dead/ com commd-dead-letter
#       (reason + attempts) e limpa sidecar (criterios 3 e 7)
#   R6  timeout (137) → .dead/ sem retry, sem sidecar (criterio 5)
#   R7  sucesso (rc=0) limpa/neutraliza sidecar (criterio 6)
#   R8  move-failed → retry op=move re-tenta SÓ o arquivamento (sem rodar
#       o worker de novo) — leva pra .done/ e limpa sidecar (politica 1)
#   R9  sidecar órfão (mensagem sumiu) é limpo pelo poll
#
# Hermético: sandbox _MMB_TEST_MODE=1, funções chamadas direto, sem claude
# e sem GitHub. dispatch é stubbado pra não spawnar worker real.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX=$(mktemp -d /tmp/mmb-commd-retry-XXXXXX)
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
  echo "ERRO: falha ao sourcear commd.sh"; rm -rf "$SANDBOX"; exit 2
}
set +e

PROC="$INBOX_BASE/cockpit/.processing"
DONE="$INBOX_BASE/cockpit/.done"
DEAD="$INBOX_BASE/cockpit/.dead"

# Stub de dispatch: captura o path, NÃO spawna worker. Usado pelos testes
# de reconcile_retries_once (op=dispatch). finalize_dispatch não chama
# dispatch, então R1/R2/R5/R6/R7 não são afetados.
DISPATCH_CALLS="$SANDBOX/dispatch-calls.txt"
: > "$DISPATCH_CALLS"
dispatch() { printf '%s\n' "$1" >> "$DISPATCH_CALLS"; }

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

journal_event_for_file() {
  grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "\"file\":\"$2\""
}
journal_event_has() {
  grep "\"event\":\"$1\"" "$JOURNAL_LOG" 2>/dev/null | grep -q "$2"
}
clean() {
  rm -f "$PROC"/* 2>/dev/null
  rm -f "$STATE_DIR/heartbeat-cockpit.txt"
  mkdir -p "$DONE" "$DEAD"
  : > "$DISPATCH_CALLS"
  : > "$JOURNAL_LOG"
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "── bash -n ──"
bash -n "$TOOLING_DIR/bin/commd.sh" 2>/dev/null && pass "commd.sh: bash -n passa" || fail "bash -n falhou"

# ── R1: MAX=0 → worker-exit direto pra .dead/, sem retry (crit 4) ──
echo "── R1: MMB_MAX_ATTEMPTS=0 (comportamento pré-H3) ──"
clean
f="$PROC/msg-r1.md"; echo x > "$f"
MMB_MAX_ATTEMPTS=0 finalize_dispatch 1 "$f" cockpit msg-r1.md
[ -f "$DEAD/msg-r1.md" ] && pass "R1: foi pra .dead/ (sem retry)" || fail "R1: não foi pra .dead/"
[ ! -f "$f.attempts" ] && pass "R1: sem sidecar" || fail "R1: sidecar criado com MAX=0"
journal_event_for_file commd-retry-scheduled msg-r1.md && fail "R1: agendou retry com MAX=0" || pass "R1: sem retry-scheduled"
journal_event_for_file commd-worker-exit msg-r1.md && pass "R1: commd-worker-exit emitido" || fail "R1: sem worker-exit"

# ── R2: worker-exit (MAX=3) incrementa attempts, não vai pra .dead (crit 1) ──
echo "── R2: worker-exit retentável agenda retry ──"
clean
f="$PROC/msg-r2.md"; echo x > "$f"
MMB_MAX_ATTEMPTS=3 MMB_RETRY_BACKOFF_BASE=60 finalize_dispatch 1 "$f" cockpit msg-r2.md
[ -f "$f" ] && pass "R2: PERMANECE em .processing/" || fail "R2: sumiu de .processing/"
[ ! -f "$DEAD/msg-r2.md" ] && pass "R2: NÃO foi direto pra .dead/" || fail "R2: foi pra .dead/"
[ -f "$f.attempts" ] && pass "R2: sidecar criado" || fail "R2: sem sidecar"
read -r a ra op tg rrc rs < "$f.attempts"
[ "$a" = "1" ] && pass "R2: attempts=1" || fail "R2: attempts=$a"
[ "$op" = "dispatch" ] && pass "R2: op=dispatch" || fail "R2: op=$op"
journal_event_for_file commd-retry-scheduled msg-r2.md && pass "R2: commd-retry-scheduled emitido" || fail "R2: sem retry-scheduled"
journal_event_for_file commd-worker-exit msg-r2.md && pass "R2: commd-worker-exit (verdade) emitido" || fail "R2: sem worker-exit"

# ── R3: backoff não vencido → não re-despacha (crit 2) ──
echo "── R3: backoff futuro não é reprocessado ──"
clean
f="$PROC/msg-r3.md"; echo x > "$f"
future=$(( $(date +%s) + 100000 ))
retry_sidecar_write "$f.attempts" 1 "$future" dispatch - 1 worker-exit
MMB_MAX_ATTEMPTS=3 MMB_WATCHDOG_STALE_SECONDS=5 reconcile_retries_once
grep -q "msg-r3.md" "$DISPATCH_CALLS" && fail "R3: re-despachou com backoff futuro" || pass "R3: backoff futuro → não re-despachado"

# ── R4: backoff vencido → re-despacha (crit 2) ──
echo "── R4: backoff vencido é reprocessado ──"
clean
f="$PROC/msg-r4.md"; echo x > "$f"
past=$(( $(date +%s) - 10 ))
retry_sidecar_write "$f.attempts" 1 "$past" dispatch - 1 worker-exit
MMB_MAX_ATTEMPTS=3 MMB_WATCHDOG_STALE_SECONDS=5 reconcile_retries_once
grep -q "msg-r4.md" "$DISPATCH_CALLS" && pass "R4: backoff vencido → re-despachado" || fail "R4: não re-despachou"
journal_event_for_file commd-retry-attempt msg-r4.md && pass "R4: commd-retry-attempt emitido" || fail "R4: sem retry-attempt"

# ── R5: esgotar attempts → .dead/ + dead-letter (crit 3, 7) ──
echo "── R5: esgotar orçamento → dead-letter ──"
clean
f="$PROC/msg-r5.md"; echo x > "$f"
retry_sidecar_write "$f.attempts" 2 0 dispatch - 1 worker-exit   # attempts=2; próxima falha → 3 == MAX
MMB_MAX_ATTEMPTS=3 finalize_dispatch 1 "$f" cockpit msg-r5.md
[ -f "$DEAD/msg-r5.md" ] && pass "R5: foi pra .dead/ ao esgotar (3/3)" || fail "R5: não foi pra .dead/"
[ ! -f "$f.attempts" ] && pass "R5: sidecar limpo após dead-letter" || fail "R5: sidecar remanescente"
journal_event_for_file commd-dead-letter msg-r5.md && pass "R5: commd-dead-letter emitido" || fail "R5: sem dead-letter"
journal_event_has commd-dead-letter '"attempts":3' && pass "R5: attempts=3 no journal" || fail "R5: attempts errado"
journal_event_has commd-dead-letter '"kind":"worker-exit"' && pass "R5: reason preservado no journal" || fail "R5: reason ausente"

# ── R6: timeout (137) → .dead/ sem retry (crit 5) ──
echo "── R6: timeout não entra em retry ──"
clean
f="$PROC/msg-r6.md"; echo x > "$f"
MMB_MAX_ATTEMPTS=3 finalize_dispatch 137 "$f" cockpit msg-r6.md
[ -f "$DEAD/msg-r6.md" ] && pass "R6: timeout → .dead/" || fail "R6: não foi pra .dead/"
[ ! -f "$f.attempts" ] && pass "R6: sem sidecar (não retentado)" || fail "R6: criou sidecar"
journal_event_for_file commd-retry-scheduled msg-r6.md && fail "R6: agendou retry pra timeout" || pass "R6: sem retry-scheduled"
journal_event_for_file commd-worker-timeout msg-r6.md && pass "R6: commd-worker-timeout emitido" || fail "R6: sem worker-timeout"

# ── R7: sucesso limpa sidecar (crit 6) ──
echo "── R7: .done neutraliza sidecar ──"
clean
f="$PROC/msg-r7.md"; echo x > "$f"
retry_sidecar_write "$f.attempts" 1 0 dispatch - 1 worker-exit   # sidecar remanescente de tentativa anterior
MMB_MAX_ATTEMPTS=3 finalize_dispatch 0 "$f" cockpit msg-r7.md
[ -f "$DONE/msg-r7.md" ] && pass "R7: sucesso → .done/" || fail "R7: não foi pra .done/"
[ ! -f "$f.attempts" ] && pass "R7: sidecar neutralizado no sucesso" || fail "R7: sidecar sobreviveu"
journal_event_for_file commd-done msg-r7.md && pass "R7: commd-done emitido" || fail "R7: sem commd-done"

# ── R8: move-failed → retry op=move sem reexecutar worker (politica 1) ──
echo "── R8: retry de arquivamento (op=move) não roda worker ──"
clean
f="$PROC/msg-r8.md"; echo x > "$f"
rm -rf "$DONE"                                  # quebra o destino → move falha
MMB_MAX_ATTEMPTS=3 finalize_dispatch 0 "$f" cockpit msg-r8.md
journal_event_for_file commd-done msg-r8.md && fail "R8: commd-done com move falho" || pass "R8: sem commd-done (move falhou)"
[ -f "$f.attempts" ] && pass "R8: sidecar de move criado" || fail "R8: sem sidecar"
read -r a ra op tg rrc rs < "$f.attempts"
{ [ "$op" = "move" ] && [ "$tg" = "done" ]; } && pass "R8: op=move target=done" || fail "R8: op=$op target=$tg"
# Conserta destino + força ready_at no passado, dispara o retry.
mkdir -p "$DONE"
retry_sidecar_write "$f.attempts" 1 "$(( $(date +%s) - 5 ))" move done 0 move-failed
: > "$DISPATCH_CALLS"; : > "$JOURNAL_LOG"
MMB_MAX_ATTEMPTS=3 MMB_WATCHDOG_STALE_SECONDS=5 reconcile_retries_once
[ -f "$DONE/msg-r8.md" ] && pass "R8: retry de move levou pra .done/" || fail "R8: move não concluiu"
[ ! -f "$f.attempts" ] && pass "R8: sidecar limpo após move ok" || fail "R8: sidecar remanescente"
journal_event_for_file commd-done msg-r8.md && pass "R8: commd-done emitido no move ok" || fail "R8: sem commd-done"
grep -q "msg-r8.md" "$DISPATCH_CALLS" && fail "R8: worker foi re-executado (op=move não deveria)" || pass "R8: worker NÃO re-executado (op=move)"

# ── R9: sidecar órfão é limpo ──
echo "── R9: sidecar órfão (mensagem sumiu) ──"
clean
sc="$PROC/ghost.md.attempts"
retry_sidecar_write "$sc" 1 0 dispatch - 1 worker-exit   # sem ghost.md
MMB_MAX_ATTEMPTS=3 MMB_WATCHDOG_STALE_SECONDS=5 reconcile_retries_once
[ ! -f "$sc" ] && pass "R9: sidecar órfão removido" || fail "R9: sidecar órfão remanescente"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
