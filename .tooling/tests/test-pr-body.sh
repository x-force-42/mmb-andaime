#!/usr/bin/env bash
# Testes do lib .tooling/bin/lib/pr-body.sh e do guard de GH_SUBISSUE
# em .tooling/bin/open-pr.sh.
#
# Uso:
#   bash .tooling/tests/test-pr-body.sh
#
# Exit 0 se todos os asserts passarem; exit 1 com contagem caso contrário.

set -uo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/lib/pr-body.sh"

failures=0
ran=0

pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# ── mmb_validate_subissue_format ─────────────────────────────────

section_validate() {
  echo "── mmb_validate_subissue_format ──"

  if mmb_validate_subissue_format "42"; then pass "aceita '42'"; else fail "rejeitou '42'"; fi
  if mmb_validate_subissue_format "1"; then pass "aceita '1'"; else fail "rejeitou '1'"; fi
  if mmb_validate_subissue_format "999999"; then pass "aceita '999999'"; else fail "rejeitou '999999'"; fi

  if ! mmb_validate_subissue_format ""; then pass "rejeita ''"; else fail "aceitou ''"; fi
  if ! mmb_validate_subissue_format "abc"; then pass "rejeita 'abc'"; else fail "aceitou 'abc'"; fi
  if ! mmb_validate_subissue_format "0"; then pass "rejeita '0' (não-positivo)"; else fail "aceitou '0'"; fi
  if ! mmb_validate_subissue_format "-1"; then pass "rejeita '-1'"; else fail "aceitou '-1'"; fi
  if ! mmb_validate_subissue_format "42a"; then pass "rejeita '42a'"; else fail "aceitou '42a'"; fi
  if ! mmb_validate_subissue_format "1.5"; then pass "rejeita '1.5'"; else fail "aceitou '1.5'"; fi
  if ! mmb_validate_subissue_format "#42"; then pass "rejeita '#42'"; else fail "aceitou '#42'"; fi
  if ! mmb_validate_subissue_format " 42"; then pass "rejeita ' 42' (leading space)"; else fail "aceitou ' 42'"; fi
}

# ── mmb_build_pr_body ────────────────────────────────────────────

section_build() {
  echo "── mmb_build_pr_body ──"

  local body
  body=$(mmb_build_pr_body "42" "- feat: x" "1-1-publisher-contract")

  if grep -q "^Closes #42$" <<<"$body"; then
    pass "body contém 'Closes #42' como linha"
  else
    fail "body falta 'Closes #42' (saída: $body)"
  fi

  if grep -q "^- feat: x$" <<<"$body"; then
    pass "body contém lista de commits"
  else
    fail "body falta lista de commits"
  fi

  if grep -q "worktree: \`1-1-publisher-contract\`" <<<"$body"; then
    pass "body contém nome da worktree no rodapé"
  else
    fail "body falta worktree name"
  fi

  if grep -q "## O que mudou" <<<"$body"; then
    pass "body tem seção '## O que mudou'"
  else
    fail "body falta '## O que mudou'"
  fi

  if grep -q "## Origem" <<<"$body"; then
    pass "body tem seção '## Origem'"
  else
    fail "body falta '## Origem'"
  fi
}

# ── open-pr.sh: pre-flight de GH_SUBISSUE falha antes de qualquer push ──

section_openpr_preflight() {
  echo "── open-pr.sh pre-flight de GH_SUBISSUE ──"

  local script="$TOOLING_DIR/bin/open-pr.sh"
  local tmp out

  # /tmp não é repo git — se chegasse a tentar git rev-parse, falharia com 128.
  # Esperamos exit 2 (nossa validação) ANTES de qualquer git op.

  tmp=$(cd /tmp && GH_SUBISSUE="" bash "$script" 2>&1 >/dev/null)
  if [ $? -eq 0 ]; then :; fi  # appease set -e

  out=$(cd /tmp && GH_SUBISSUE="" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "2" ]; then pass "exit 2 quando GH_SUBISSUE vazio"; else fail "exit=$rc esperado 2 (vazio)"; fi

  out=$(cd /tmp && GH_SUBISSUE="abc" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "2" ]; then pass "exit 2 quando GH_SUBISSUE='abc'"; else fail "exit=$rc esperado 2 (abc)"; fi

  out=$(cd /tmp && GH_SUBISSUE="0" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "2" ]; then pass "exit 2 quando GH_SUBISSUE='0'"; else fail "exit=$rc esperado 2 (0)"; fi

  out=$(cd /tmp && GH_SUBISSUE="-5" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "2" ]; then pass "exit 2 quando GH_SUBISSUE='-5'"; else fail "exit=$rc esperado 2 (-5)"; fi

  # Mensagem de erro precisa explicar o motivo
  out=$(cd /tmp && GH_SUBISSUE="" bash "$script" 2>&1)
  if grep -q "GH_SUBISSUE ausente ou inválido" <<<"$out"; then
    pass "mensagem de erro identifica GH_SUBISSUE"
  else
    fail "mensagem de erro genérica (saída: $(head -3 <<<"$out"))"
  fi

  # Valor válido: cai pra exit do git rev-parse (128), mas isso prova
  # que a validação passou — fail-loud não foi disparado.
  out=$(cd /tmp && GH_SUBISSUE="42" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" != "2" ]; then
    pass "GH_SUBISSUE=42 passa pela validação (exit=$rc, não é 2)"
  else
    fail "GH_SUBISSUE=42 ainda dispara fail-loud (exit=2)"
  fi
}

# ── runner ───────────────────────────────────────────────────────

section_validate
echo
section_build
echo
section_openpr_preflight
echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
