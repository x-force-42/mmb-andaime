#!/usr/bin/env bash
# Testes do .tooling/hooks/inject-pending-human.sh (B2B —
# andaime-fortification-v08).

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$TOOLING_DIR/hooks/inject-pending-human.sh"
WRITE_SCRIPT="$TOOLING_DIR/bin/write-pending-human.sh"

SANDBOX=$(mktemp -d /tmp/mmb-inject-test-XXXXXX)
export MMB_STATE_DIR="$SANDBOX/state"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run_hook() {
  # Sem MMB_TMUX_SESSION → hook não tenta tmux. Mantém testes
  # hermético independentes de tmux disponível na máquina.
  MMB_STATE_DIR="$MMB_STATE_DIR" MMB_TMUX_SESSION="" bash "$HOOK" "$@"
}

# ── 1. Vazio: stdout vazio, exit 0 ───────────────────────────────

section_empty() {
  echo "── pending-human vazio ──"

  mkdir -p "$MMB_STATE_DIR/pending-human"
  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 com dir vazio" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio com dir vazio" || fail "stdout não-vazio: [$out]"

  # Sem dir nem hash: também silencioso
  rm -rf "$MMB_STATE_DIR/pending-human"
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 sem dir" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio sem dir" || fail "stdout não-vazio sem dir"
}

# ── 2. Uma entrada ───────────────────────────────────────────────

section_one_entry() {
  echo "── 1 entrada ──"

  rm -rf "$MMB_STATE_DIR/pending-human"
  mkdir -p "$MMB_STATE_DIR/pending-human"

  # Cria uma entrada via write-pending-human pra usar formato canônico
  MMB_STATE_DIR="$MMB_STATE_DIR" MMB_TMUX_SESSION="" \
    bash "$WRITE_SCRIPT" --no-tmux \
      --from cockpit --type question --subject rename-field \
      --thread ux-refresh-v07 --priority normal \
      <<<"## Resumo

Pode renomear o campo?" > /dev/null

  local out rc
  set +e
  out=$(run_hook)
  rc=$?
  set -e

  [ "$rc" = "0" ] && pass "exit 0 com 1 entrada" || fail "exit=$rc"
  if echo "$out" | grep -q "^<pending-human-msgs count=1>$"; then
    pass "abre tag <pending-human-msgs count=1>"
  else
    fail "tag de abertura ausente"
  fi
  if echo "$out" | grep -q "</pending-human-msgs>"; then
    pass "fecha tag </pending-human-msgs>"
  else
    fail "tag de fechamento ausente"
  fi
  if echo "$out" | grep -q "=== entry: .*_cockpit_question_rename-field.md ==="; then
    pass "separator com basename"
  else
    fail "separator ausente"
  fi
  if echo "$out" | grep -q "Pode renomear o campo"; then
    pass "body preservado"
  else
    fail "body ausente"
  fi
  if echo "$out" | grep -q "from: cockpit"; then
    pass "frontmatter preservado"
  else
    fail "frontmatter ausente"
  fi
}

# ── 3. Arquivo movido pra .processed/ ────────────────────────────

section_moved_to_processed() {
  echo "── arquivos movidos pra .processed/ ──"

  local pending_count processed_count
  pending_count=$(find "$MMB_STATE_DIR/pending-human" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)
  processed_count=$(find "$MMB_STATE_DIR/pending-human/.processed" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)

  [ "$pending_count" = "0" ] && pass "pending-human/ ficou vazio após hook" || fail "pending: $pending_count"
  [ "$processed_count" = "1" ] && pass "1 arquivo em .processed/" || fail "processed: $processed_count"
}

# ── 4. 2 entradas: ordem cronológica preservada ──────────────────

section_two_entries_ordered() {
  echo "── 2 entradas em ordem cronológica ──"

  rm -rf "$MMB_STATE_DIR/pending-human"
  mkdir -p "$MMB_STATE_DIR/pending-human"

  # Cria com timestamps espaçados (sleep entre as duas)
  MMB_STATE_DIR="$MMB_STATE_DIR" MMB_TMUX_SESSION="" \
    bash "$WRITE_SCRIPT" --no-tmux \
      --from cockpit --type question --subject first \
      --thread t <<<"first body" > /dev/null
  sleep 0.05  # garante timestamps distintos
  MMB_STATE_DIR="$MMB_STATE_DIR" MMB_TMUX_SESSION="" \
    bash "$WRITE_SCRIPT" --no-tmux \
      --from logger --type error --subject second \
      --thread t <<<"second body" > /dev/null

  local out
  out=$(run_hook)

  if echo "$out" | grep -q "^<pending-human-msgs count=2>$"; then
    pass "count=2 na tag"
  else
    fail "count incorreto"
  fi

  # Posição relativa: "first" deve aparecer antes de "second"
  local first_pos second_pos
  first_pos=$(echo "$out" | grep -n "first body" | head -1 | cut -d: -f1)
  second_pos=$(echo "$out" | grep -n "second body" | head -1 | cut -d: -f1)
  if [ -n "$first_pos" ] && [ -n "$second_pos" ] && [ "$first_pos" -lt "$second_pos" ]; then
    pass "ordem cronológica preservada (first antes de second)"
  else
    fail "ordem errada: first@$first_pos second@$second_pos"
  fi

  # Ambas movidas pra .processed/. Note: section_two_entries_ordered
  # fez `rm -rf pending-human` no início, então .processed/ foi
  # apagado também — count reinicia em 2.
  local processed_count
  processed_count=$(find "$MMB_STATE_DIR/pending-human/.processed" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)
  if [ "$processed_count" = "2" ]; then
    pass "2 arquivos movidos pra .processed/"
  else
    fail "processed: $processed_count, esperado 2"
  fi
}

# ── 5. Idempotência: rodar 2x não duplica nem reprocessa ─────────

section_idempotent() {
  echo "── idempotência ──"

  # Limpa pending. Já processou tudo no teste anterior.
  local out_first out_second
  out_first=$(run_hook)
  out_second=$(run_hook)

  [ -z "$out_first" ] && pass "1ª chamada com pending vazio: stdout vazio" || fail "stdout não-vazio na 1ª"
  [ -z "$out_second" ] && pass "2ª chamada subsequente: stdout vazio" || fail "stdout não-vazio na 2ª"
}

# ── 6. Conteúdo do .processed/ — arquivos não-deletados ──────────

section_audit_trail() {
  echo "── audit trail em .processed/ ──"

  # Lista um arquivo e confirma que tem o frontmatter + body
  local sample
  sample=$(find "$MMB_STATE_DIR/pending-human/.processed" -maxdepth 1 -type f -name '*first*' 2>/dev/null | head -1)
  [ -n "$sample" ] && pass "arquivo first preservado em .processed/" || { fail "first não encontrado"; return; }

  if grep -q "first body" "$sample"; then
    pass "body de first preservado em .processed/"
  else
    fail "body perdido em .processed/"
  fi
  if grep -q "^from: cockpit$" "$sample"; then
    pass "frontmatter de first preservado"
  else
    fail "frontmatter perdido"
  fi
}

# ── 7. Robustez: falha silenciosa em condições degeneradas ───────

section_robustness() {
  echo "── robustez ──"

  # Arquivo não-legível (chmod 000): hook não trava
  rm -rf "$MMB_STATE_DIR/pending-human"
  mkdir -p "$MMB_STATE_DIR/pending-human"
  local bad="$MMB_STATE_DIR/pending-human/2026-bad.md"
  echo "unreadable" > "$bad"
  chmod 000 "$bad" 2>/dev/null || true

  local rc
  set +e
  run_hook >/dev/null 2>&1
  rc=$?
  # cleanup: chmod de volta antes de mexer; arquivo pode ter sido movido
  for candidate in "$bad" "$MMB_STATE_DIR/pending-human/.processed/$(basename "$bad")"; do
    [ -e "$candidate" ] && chmod 644 "$candidate" 2>/dev/null
  done
  set -e
  [ "$rc" = "0" ] && pass "exit 0 com arquivo unreadable" || fail "exit=$rc com arquivo unreadable"
}

section_empty; echo
section_one_entry; echo
section_moved_to_processed; echo
section_two_entries_ordered; echo
section_idempotent; echo
section_audit_trail; echo
section_robustness; echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
