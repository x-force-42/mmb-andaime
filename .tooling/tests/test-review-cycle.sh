#!/usr/bin/env bash
# Testes do .tooling/bin/review-cycle.sh
#
# Cobre regressão do bug "exit 1 silencioso" (épico dark-mode 2026-05-16):
# set -euo pipefail + grep sem match no pipeline mataria o script sem
# nenhuma mensagem ao usuário. Casos:
#
#   1. bash -n verde (parse válido).
#   2. journal inexistente → mensagem clara, exit 0.
#   3. journal vazio → mensagem clara, exit 0.
#   4. épico sem eventos → "Nenhum evento" + exit 0.
#   5. épico inexistente → mesmo comportamento de "sem eventos" + exit 0.
#   6. épico com eventos error não-resolvidos → renderiza linha + exit 0.
#   7. épico com todos eventos resolved → "nenhum erro pendente" + exit 0.
#   8. épico com event sem "msg" → não quebra (regressão do _field).
#   9. exit 2 quando arg ausente (interface).

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/review-cycle.sh"

SANDBOX=$(mktemp -d /tmp/mmb-review-test-XXXXXX)
JOURNAL="$SANDBOX/journal.jsonl"
export MMB_JOURNAL_PATH="$JOURNAL"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run() {
  MMB_JOURNAL_PATH="$JOURNAL" bash "$SCRIPT" "$@"
}

reset_journal() {
  rm -f "$JOURNAL"
}

# ── 1. bash -n ──────────────────────────────────────────────────

section_lint() {
  echo "── bash -n ──"
  if bash -n "$SCRIPT" 2>/dev/null; then
    pass "bash -n passa"
  else
    fail "bash -n falhou"
  fi
}

# ── 2. journal inexistente ──────────────────────────────────────

section_no_journal() {
  echo "── journal inexistente ──"
  reset_journal
  local out rc
  set +e
  out=$(run dark-mode 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q "Journal vazio ou inexistente" && pass "mensagem clara" || fail "msg: [$out]"
}

# ── 3. journal vazio ────────────────────────────────────────────

section_empty_journal() {
  echo "── journal vazio ──"
  reset_journal
  : > "$JOURNAL"
  local out rc
  set +e
  out=$(run dark-mode 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q "Journal vazio ou inexistente" && pass "mensagem clara" || fail "msg: [$out]"
}

# ── 4. épico sem eventos ────────────────────────────────────────

section_no_events_for_epic() {
  echo "── épico sem eventos ──"
  reset_journal
  cat > "$JOURNAL" <<'EOF'
{"ts":"2026-05-16T10:00:00Z","sev":"error","event":"x","epic":"outro","id":"e-1"}
EOF
  local out rc
  set +e
  out=$(run dark-mode 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q "Nenhum evento registrado pro épico 'dark-mode'" && pass "mensagem específica" || fail "msg: [$out]"
}

# ── 5. épico inexistente ────────────────────────────────────────

section_unknown_epic() {
  echo "── épico inexistente ──"
  reset_journal
  cat > "$JOURNAL" <<'EOF'
{"ts":"2026-05-16T10:00:00Z","sev":"error","event":"x","epic":"outro","id":"e-1"}
EOF
  local out rc
  set +e
  out=$(run xyz-inexistente 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q "Nenhum evento registrado pro épico 'xyz-inexistente'" && pass "mensagem específica" || fail "msg: [$out]"
}

# ── 6. épico com error não-resolvido ────────────────────────────
# Reprodução do bug original: 1 evento error sem campo `resolves` →
# antes do fix, grep retornava 1 e set -e + pipefail matava o script
# em silêncio.

section_error_unresolved() {
  echo "── épico com error não-resolvido (regressão do bug) ──"
  reset_journal
  cat > "$JOURNAL" <<'EOF'
{"ts":"2026-05-16T20:10:07Z","agent":"commd","sev":"error","event":"commd-worker-exit","msg":"watchdog kill","epic":"alvo","id":"e-watchdog-1"}
EOF
  local out rc
  set +e
  out=$(run alvo 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 (era 1 silencioso antes do fix)" || fail "exit=$rc"
  echo "$out" | grep -q "Review-cycle: épico 'alvo'" && pass "header renderizado" || fail "header faltou"
  echo "$out" | grep -q "errors:              1" && pass "stats: 1 error" || fail "stats incorretos"
  echo "$out" | grep -q "não resolvidos:      1" && pass "1 não resolvido" || fail "unresolved count incorreto"
  echo "$out" | grep -q "commd-worker-exit" && pass "linha do evento renderizada" || fail "evento faltou"
  echo "$out" | grep -q "Sugestões heurísticas" && pass "sugestões aparecem" || fail "sugestões faltou"
}

# ── 7. épico com todos resolved ────────────────────────────────

section_all_resolved() {
  echo "── épico com tudo resolvido ──"
  reset_journal
  cat > "$JOURNAL" <<'EOF'
{"ts":"2026-05-16T10:00:00Z","sev":"error","event":"x","epic":"alvo","id":"e-1"}
{"ts":"2026-05-16T11:00:00Z","sev":"warn","event":"resolved","epic":"alvo","id":"e-2","resolves":"e-1"}
EOF
  local out rc
  set +e
  out=$(run alvo 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q "Nenhum erro pendente" && pass "mensagem 'épico limpo'" || fail "msg: [$out]"
}

# ── 8. event sem msg (regressão do _field) ──────────────────────

section_event_without_msg() {
  echo "── event sem campo msg ──"
  reset_journal
  cat > "$JOURNAL" <<'EOF'
{"ts":"2026-05-16T10:00:00Z","sev":"error","event":"x","epic":"alvo","id":"e-1"}
EOF
  local out rc
  set +e
  out=$(run alvo 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 com event sem msg" || fail "exit=$rc"
  echo "$out" | grep -q "Sugestões heurísticas" && pass "renderizou até o fim" || fail "saída truncada"
}

# ── 9. arg ausente → exit 2 + uso ──────────────────────────────

section_missing_arg() {
  echo "── arg ausente ──"
  local out rc
  set +e
  out=$(run 2>&1)
  rc=$?
  set -e
  [ "$rc" = "2" ] && pass "exit 2 com arg ausente" || fail "exit=$rc"
  echo "$out" | grep -q "Uso:" && pass "mostra usage" || fail "usage faltou"
}

# ── Run ────────────────────────────────────────────────────────

section_lint
section_no_journal
section_empty_journal
section_no_events_for_epic
section_unknown_epic
section_error_unresolved
section_all_resolved
section_event_without_msg
section_missing_arg

echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
