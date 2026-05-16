#!/usr/bin/env bash
# Testes do lib .tooling/bin/lib/pr-body.sh e dos guards em open-pr.sh
# (GH_SUBISSUE — A1, e MMB_SUITE_OUTPUT — A11).
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

# Fixture: arquivo de suíte verde válido pra reutilizar em vários testes.
mk_valid_suite() {
  local tf
  tf=$(mktemp)
  cat > "$tf" <<EOF
tests/test_alpha.py::test_one PASSED                                 [ 25%]
tests/test_alpha.py::test_two PASSED                                 [ 50%]
tests/test_beta.py::test_three PASSED                                [ 75%]
tests/test_beta.py::test_four PASSED                                 [100%]
========================= 4 passed in 0.42s ==============================
EOF
  echo "$tf"
}

# ── mmb_validate_subissue_format ─────────────────────────────────

section_validate_subissue() {
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

# ── mmb_validate_suite_output (A11) ──────────────────────────────

section_validate_suite() {
  echo "── mmb_validate_suite_output (A11) ──"

  local tf

  # Códigos de erro distintos por motivo
  mmb_validate_suite_output "" && fail "aceitou arg vazio" || {
    [ $? -eq 1 ] && pass "rc=1 quando arg vazio" || fail "rc errado pra arg vazio"
  }
  mmb_validate_suite_output "/nonexistent/path/x.txt" && fail "aceitou arquivo missing" || {
    [ $? -eq 2 ] && pass "rc=2 quando arquivo não existe" || fail "rc errado pra missing"
  }

  tf=$(mktemp); : > "$tf"
  mmb_validate_suite_output "$tf" && fail "aceitou arquivo vazio" || {
    [ $? -eq 3 ] && pass "rc=3 quando arquivo vazio" || fail "rc errado pra empty"
  }
  rm "$tf"

  tf=$(mktemp); echo "tiny" > "$tf"
  mmb_validate_suite_output "$tf" && fail "aceitou < 100 bytes" || {
    [ $? -eq 4 ] && pass "rc=4 quando < MMB_SUITE_MIN_BYTES" || fail "rc errado pra tiny"
  }
  rm "$tf"

  # Override do mínimo: valida com 10 bytes
  tf=$(mktemp); echo "ten chars" > "$tf"
  if MMB_SUITE_MIN_BYTES=5 mmb_validate_suite_output "$tf"; then
    pass "aceita arquivo curto com MMB_SUITE_MIN_BYTES baixo"
  else
    fail "rejeitou arquivo válido sob override"
  fi
  rm "$tf"

  # Arquivo válido
  tf=$(mk_valid_suite)
  if mmb_validate_suite_output "$tf"; then
    pass "aceita arquivo válido (> 100 bytes)"
  else
    fail "rejeitou arquivo válido"
  fi
  rm "$tf"
}

# ── mmb_build_pr_body ────────────────────────────────────────────

section_build() {
  echo "── mmb_build_pr_body ──"

  local body suite_file
  suite_file=$(mk_valid_suite)
  body=$(mmb_build_pr_body "42" "- feat: x" "1-1-publisher-contract" "$suite_file")

  if grep -q "^Closes #42$" <<<"$body"; then
    pass "body contém 'Closes #42' como linha"
  else
    fail "body falta 'Closes #42'"
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

  if grep -q "## Suíte verde" <<<"$body"; then
    pass "body tem seção '## Suíte verde' (A11)"
  else
    fail "body falta '## Suíte verde'"
  fi

  if grep -q "test_one PASSED" <<<"$body"; then
    pass "body embute output literal da suíte"
  else
    fail "body falta conteúdo da suíte"
  fi

  if grep -q "## Origem" <<<"$body"; then
    pass "body tem seção '## Origem'"
  else
    fail "body falta '## Origem'"
  fi

  rm "$suite_file"

  # Truncamento em 4KB
  local large_file body_size
  large_file=$(mktemp)
  yes "PASS" | head -c 5000 > "$large_file"
  body=$(mmb_build_pr_body "42" "- feat: x" "wt" "$large_file")
  body_size=$(printf '%s' "$body" | wc -c)
  if [ "$body_size" -lt 5000 ]; then
    pass "body trunca suíte > 4KB (got ${body_size} bytes)"
  else
    fail "body não truncou (${body_size} bytes pra suíte de 5000)"
  fi
  if grep -q "truncado em 4KB" <<<"$body"; then
    pass "body inclui nota de truncamento"
  else
    fail "body sem nota de truncamento"
  fi
  rm "$large_file"
}

# ── open-pr.sh: pre-flight de GH_SUBISSUE falha antes de qualquer push ──

section_openpr_preflight_subissue() {
  echo "── open-pr.sh pre-flight de GH_SUBISSUE ──"

  local script="$TOOLING_DIR/bin/open-pr.sh"
  local out rc

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

  out=$(cd /tmp && GH_SUBISSUE="" bash "$script" 2>&1)
  if grep -q "GH_SUBISSUE ausente ou inválido" <<<"$out"; then
    pass "mensagem de erro identifica GH_SUBISSUE"
  else
    fail "mensagem de erro genérica"
  fi
}

# ── open-pr.sh: pre-flight de MMB_SUITE_OUTPUT (A11) ─────────────

section_openpr_preflight_suite() {
  echo "── open-pr.sh pre-flight de MMB_SUITE_OUTPUT (A11) ──"

  local script="$TOOLING_DIR/bin/open-pr.sh"
  local out rc tf

  # GH_SUBISSUE válido pra passar o 1º guard; foco aqui é o A11.
  out=$(cd /tmp && GH_SUBISSUE="42" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "3" ]; then pass "exit 3 quando MMB_SUITE_OUTPUT ausente"; else fail "exit=$rc esperado 3 (unset)"; fi

  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "3" ]; then pass "exit 3 quando MMB_SUITE_OUTPUT vazio"; else fail "exit=$rc esperado 3 (vazio)"; fi

  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="/nonexistent/x" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "3" ]; then pass "exit 3 quando arquivo missing"; else fail "exit=$rc esperado 3 (missing)"; fi

  tf=$(mktemp); : > "$tf"
  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="$tf" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "3" ]; then pass "exit 3 quando arquivo vazio"; else fail "exit=$rc esperado 3 (vazio file)"; fi
  rm "$tf"

  tf=$(mktemp); echo "tiny" > "$tf"
  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="$tf" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" = "3" ]; then pass "exit 3 quando < 100 bytes"; else fail "exit=$rc esperado 3 (tiny)"; fi
  rm "$tf"

  # Mensagens específicas por motivo
  out=$(cd /tmp && GH_SUBISSUE="42" bash "$script" 2>&1)
  if grep -q "MMB_SUITE_OUTPUT não setada" <<<"$out"; then
    pass "mensagem identifica unset"
  else
    fail "mensagem unset genérica"
  fi

  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="/nonexistent" bash "$script" 2>&1)
  if grep -q "Guardrail A11" <<<"$out"; then
    pass "mensagem cita Guardrail A11"
  else
    fail "mensagem sem ref a A11"
  fi

  # Valor válido: passa o pré-flight A11. Subsequente vai falhar em git
  # rev-parse (cd /tmp não é repo) — mas isso prova que A11 não fez exit.
  tf=$(mk_valid_suite)
  out=$(cd /tmp && GH_SUBISSUE="42" MMB_SUITE_OUTPUT="$tf" bash "$script" 2>&1)
  rc=$?
  if [ "$rc" != "3" ]; then
    pass "valid file passa o pré-flight A11 (exit=$rc != 3)"
  else
    fail "valid file ainda dispara A11 (exit=3)"
  fi
  rm "$tf"
}

# ── runner ───────────────────────────────────────────────────────

section_validate_subissue
echo
section_validate_suite
echo
section_build
echo
section_openpr_preflight_subissue
echo
section_openpr_preflight_suite
echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
