#!/usr/bin/env bash
# Testes das funções de journaling estruturado + watchdog do commd.sh
# (B1.3 e B1.2 do épico andaime-fortification-v08).
#
# Cobre:
#   - journal() emite JSON válido com auto-quote numérico vs string
#   - journal() escapa aspas em strings sem quebrar JSON
#   - extract_thread() lê frontmatter YAML simples e ignora body
#   - error_id() gera IDs únicos
#   - watchdog_check() detecta heartbeat stale, ignora fresh
#
# Uso:
#   bash .tooling/tests/test-commd-journal.sh
#
# Exit 0 se todos os asserts passarem; exit 1 com contagem caso contrário.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Sandbox isolado pra evitar tocar inbox/journal/state reais.
SANDBOX=$(mktemp -d /tmp/mmb-commd-test-XXXXXX)
STATE_DIR="$SANDBOX/state"
LOG_DIR="$SANDBOX/logs"
INBOX_BASE="$SANDBOX/inbox"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$INBOX_BASE"
JOURNAL_LOG="$LOG_DIR/journal.jsonl"
JOURNAL_LOCK="$LOG_DIR/.journal.lock"
COMMD_LOG="$LOG_DIR/commd.log"
: > "$JOURNAL_LOG"
: > "$COMMD_LOG"

# Override globals que o source vai querer escrever neles. Antes do source.
export _MMB_TEST_MODE=1

# Source commd.sh — agora respeita BASH_SOURCE guard.
# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/commd.sh" || {
  echo "ERRO: falha ao sourcear commd.sh"
  rm -rf "$SANDBOX"
  exit 2
}

failures=0
ran=0

pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# Helper: extrai 1ª linha do journal correspondente ao event.
journal_line() {
  local event="$1"
  grep -m1 "\"event\":\"$event\"" "$JOURNAL_LOG" 2>/dev/null
}

# Helper: valida que linha é JSON parseável (via python — mais robusto que jq).
is_valid_json() {
  python3 -c "import json,sys; json.loads(sys.argv[1])" "$1" 2>/dev/null
}

# ── journal() — auto-quote ───────────────────────────────────────

section_journal_quoting() {
  echo "── journal() auto-quote numeric vs string ──"

  : > "$JOURNAL_LOG"

  journal commd-test-num core m1.md "exit_code=42" "timeout_seconds=600"
  local line; line=$(journal_line "commd-test-num")
  if is_valid_json "$line"; then pass "linha numérica é JSON válido"; else fail "linha numérica inválida: $line"; fi
  if grep -q '"exit_code":42' <<<"$line"; then pass "número '42' sem aspas"; else fail "número '42' quotado"; fi
  if grep -q '"timeout_seconds":600' <<<"$line"; then pass "número '600' sem aspas"; else fail "número '600' quotado"; fi

  journal commd-test-str core m2.md "sev=error" "epic=ux-refresh-v07" "id=abc-123"
  line=$(journal_line "commd-test-str")
  if is_valid_json "$line"; then pass "linha de strings é JSON válido"; else fail "linha string inválida"; fi
  if grep -q '"sev":"error"' <<<"$line"; then pass "string 'error' quotada"; else fail "'error' sem aspas"; fi
  if grep -q '"epic":"ux-refresh-v07"' <<<"$line"; then pass "string 'ux-refresh-v07' quotada"; else fail "epic mal quotado"; fi

  journal commd-test-mix logger m3.md "sev=error" "kind=worker-timeout" "epic=foo" "id=xyz" "timeout_seconds=600"
  line=$(journal_line "commd-test-mix")
  if is_valid_json "$line"; then pass "linha mista (string + num) é JSON válido"; else fail "linha mista inválida"; fi
  if grep -q '"timeout_seconds":600' <<<"$line" && grep -q '"sev":"error"' <<<"$line"; then
    pass "mistura num/string preserva quoting correto"
  else
    fail "quoting misturado quebrou"
  fi

  # Float (raro mas suportado)
  journal commd-test-float core m4.md "ratio=0.95"
  line=$(journal_line "commd-test-float")
  if is_valid_json "$line"; then pass "float é JSON válido"; else fail "float inválido"; fi
  if grep -q '"ratio":0.95' <<<"$line"; then pass "float '0.95' sem aspas"; else fail "float quotado"; fi
}

section_journal_escaping() {
  echo "── journal() escape de strings ──"

  : > "$JOURNAL_LOG"

  # Strings com aspas e backslashes
  journal commd-test-esc core m5.md 'note=string com "aspas" dentro'
  local line; line=$(journal_line "commd-test-esc")
  if is_valid_json "$line"; then pass "aspas internas viram \\\" — JSON válido"; else fail "aspas internas quebram JSON: $line"; fi

  journal commd-test-bs core m6.md 'path=/tmp/x\y'
  line=$(journal_line "commd-test-bs")
  if is_valid_json "$line"; then pass "backslash escapado — JSON válido"; else fail "backslash inválido"; fi
}

# ── extract_thread() ─────────────────────────────────────────────

section_extract_thread() {
  echo "── extract_thread() ──"

  local tf

  # Mensagem normal com thread
  tf=$(mktemp)
  cat > "$tf" <<EOF
---
from: master
to: logger
type: briefing
subject: foo
thread: ux-refresh-v07
created: 2026-05-16T11:48:12Z
---

Body content. thread: bogus (este é body, não frontmatter)
EOF
  local got; got=$(extract_thread "$tf")
  if [ "$got" = "ux-refresh-v07" ]; then pass "extrai 'thread:' do frontmatter"; else fail "got [$got]"; fi
  rm "$tf"

  # Sem thread
  tf=$(mktemp)
  cat > "$tf" <<EOF
---
from: master
to: logger
type: briefing
---
no thread
EOF
  got=$(extract_thread "$tf")
  if [ -z "$got" ]; then pass "string vazia quando thread ausente"; else fail "got [$got] esperava ''"; fi
  rm "$tf"

  # Arquivo inexistente
  got=$(extract_thread "/nonexistent/path")
  if [ -z "$got" ]; then pass "string vazia pra arquivo inexistente"; else fail "got [$got]"; fi

  # Thread com whitespace
  tf=$(mktemp)
  cat > "$tf" <<EOF
---
thread:   meu-epic-com-espacos
---
EOF
  got=$(extract_thread "$tf")
  if [ "$got" = "meu-epic-com-espacos" ]; then pass "trim leading whitespace"; else fail "got [$got]"; fi
  rm "$tf"
}

# ── error_id() ───────────────────────────────────────────────────

section_error_id() {
  echo "── error_id() ──"

  local id1 id2
  id1=$(error_id logger worker-timeout)
  id2=$(error_id logger worker-timeout)

  if [ -n "$id1" ]; then pass "gera id não-vazio"; else fail "id vazio"; fi
  if [ "$id1" != "$id2" ]; then pass "ids consecutivos diferem (RANDOM)"; else fail "ids iguais ($id1)"; fi
  if grep -qE "^[0-9]{8}T[0-9]{6}Z-logger-worker-timeout-[0-9]+$" <<<"$id1"; then
    pass "formato 'TIMESTAMP-dest-kind-N'"
  else
    fail "formato inesperado: $id1"
  fi
}

# ── watchdog_check() ─────────────────────────────────────────────

section_watchdog() {
  echo "── watchdog_check() ──"

  : > "$JOURNAL_LOG"

  # Setup: heartbeat stale (5s no passado, vamos pôr threshold 2s)
  local hb_stale="$STATE_DIR/heartbeat-cockpit.txt"
  local hb_fresh="$STATE_DIR/heartbeat-aquarium.txt"
  touch -d "5 seconds ago" "$hb_stale"
  touch "$hb_fresh"

  # Override do threshold pra teste rápido
  MMB_WATCHDOG_STALE_SECONDS=2 watchdog_check

  if [ ! -f "$hb_stale" ]; then
    pass "heartbeat stale foi removido (defensivo se trap falhar)"
  else
    fail "heartbeat stale ainda existe"
  fi

  if [ -f "$hb_fresh" ]; then
    pass "heartbeat fresh preservado"
  else
    fail "heartbeat fresh removido sem razão"
  fi

  local line; line=$(journal_line "commd-watchdog-kill")
  if [ -n "$line" ]; then pass "evento commd-watchdog-kill emitido"; else fail "evento ausente"; fi
  if is_valid_json "$line"; then pass "evento é JSON válido"; else fail "evento inválido: $line"; fi
  if grep -q '"sev":"error"' <<<"$line"; then pass "evento tem sev=error"; else fail "evento sem sev=error"; fi
  if grep -q '"kind":"watchdog-stale"' <<<"$line"; then pass "evento tem kind=watchdog-stale"; else fail "evento sem kind"; fi
  if grep -q '"dest":"cockpit"' <<<"$line"; then pass "evento identifica dest=cockpit"; else fail "dest errado"; fi

  # Hermeticidade: o teste NÃO pode ter tocado paths reais.
  # Antes do fix do _MMB_TEST_MODE no commd.sh, o source reescrevia
  # STATE_DIR/LOG_DIR/JOURNAL_LOG pros paths de produção, e este
  # teste poluía o journal real com entries com stale_seconds=5 /
  # threshold=2.
  local real_state="$TOOLING_DIR/state"
  local real_journal="$TOOLING_DIR/logs/journal.jsonl"
  if [ "$STATE_DIR" != "$real_state" ]; then
    pass "STATE_DIR preservado como sandbox ($STATE_DIR)"
  else
    fail "STATE_DIR aponta pra produção — teste não é hermético"
  fi
  if [ "$JOURNAL_LOG" != "$real_journal" ]; then
    pass "JOURNAL_LOG preservado como sandbox ($JOURNAL_LOG)"
  else
    fail "JOURNAL_LOG aponta pra produção — teste não é hermético"
  fi
  if [ ! -f "$real_state/heartbeat-cockpit.txt" ]; then
    pass "heartbeat-cockpit real não foi tocado pelo teste"
  else
    fail "heartbeat-cockpit real existe — teste vazou estado"
  fi
}

# ── runner ───────────────────────────────────────────────────────

section_journal_quoting
echo
section_journal_escaping
echo
section_extract_thread
echo
section_error_id
echo
section_watchdog
echo

echo "─────────────────────────────────"
rm -rf "$SANDBOX"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
