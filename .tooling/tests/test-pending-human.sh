#!/usr/bin/env bash
# Testes do .tooling/bin/write-pending-human.sh (B2A — andaime-fortification-v08).
#
# Uso:
#   bash .tooling/tests/test-pending-human.sh
#
# Exit 0 se todos os asserts passarem.

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/write-pending-human.sh"

# Sandbox isolado pra não tocar state/pending-human real.
SANDBOX=$(mktemp -d /tmp/mmb-ph-test-XXXXXX)
export MMB_STATE_DIR="$SANDBOX/state"
mkdir -p "$MMB_STATE_DIR"

# Não mexer em tmux durante teste — sempre passa --no-tmux.

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Helper: roda script com body via stdin, retorna stdout (filepath).
run_script() {
  local body="$1"; shift
  bash "$SCRIPT" --no-tmux "$@" <<<"$body"
}

# ── 1. Caminho feliz ─────────────────────────────────────────────

section_happy_path() {
  echo "── caminho feliz ──"

  local out file
  out=$(run_script "Body content here" \
    --from cockpit --type question --subject rename-field \
    --thread ux-refresh-v07 --priority normal --source-msg "msg.md")
  file="$out"

  [ -f "$file" ] && pass "arquivo criado" || { fail "arquivo não criado: $file"; return; }

  if grep -q "^from: cockpit$" "$file"; then pass "frontmatter: from"; else fail "from ausente"; fi
  if grep -q "^type: question$" "$file"; then pass "frontmatter: type"; else fail "type ausente"; fi
  if grep -q "^subject: rename-field$" "$file"; then pass "frontmatter: subject"; else fail "subject ausente"; fi
  if grep -q "^thread: ux-refresh-v07$" "$file"; then pass "frontmatter: thread"; else fail "thread ausente"; fi
  if grep -q "^priority: normal$" "$file"; then pass "frontmatter: priority"; else fail "priority ausente"; fi
  if grep -q "^source-msg: msg.md$" "$file"; then pass "frontmatter: source-msg"; else fail "source-msg ausente"; fi
  if grep -q "^created: " "$file"; then pass "frontmatter: created"; else fail "created ausente"; fi
  if grep -q "^Body content here$" "$file"; then pass "body preservado"; else fail "body ausente"; fi

  # Filename pattern
  local basename
  basename=$(basename "$file")
  if [[ "$basename" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]+Z_cockpit_question_rename-field\.md$ ]]; then
    pass "filename casa padrão TS_from_type_subject.md"
  else
    fail "filename inesperado: $basename"
  fi
}

# ── 2. Sem source-msg (opcional) ─────────────────────────────────

section_optional_source_msg() {
  echo "── source-msg opcional ──"

  local file
  file=$(run_script "body" --from logger --type error --subject worker-timeout --thread foo)
  [ -f "$file" ] && pass "arquivo criado sem --source-msg" || fail "arquivo não criado"
  if ! grep -q "^source-msg:" "$file"; then pass "source-msg ausente do frontmatter quando não passado"; else fail "source-msg vazio escrito"; fi
}

# ── 3. Validações de args ────────────────────────────────────────

section_validations() {
  echo "── validações de args ──"

  set +e
  bash "$SCRIPT" --no-tmux --type status --subject s --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--from ausente → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from cockpit --subject s --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--type ausente → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from cockpit --type status --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--subject ausente → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from cockpit --type status --subject s <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--thread ausente → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from invalido --type status --subject s --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--from inválido → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from cockpit --type invalido --subject s --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--type inválido → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --from cockpit --type status --subject s --thread t --priority invalida <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--priority inválida → exit 1" || fail "esperado exit 1"

  bash "$SCRIPT" --no-tmux --bogus-flag X --from cockpit --type status --subject s --thread t <<<"body" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "flag desconhecida → exit 1" || fail "esperado exit 1"
  set -e
}

# ── 4. Subject com caracteres especiais — sanitização ────────────

section_subject_sanitization() {
  echo "── sanitização de subject ──"

  local file basename
  file=$(run_script "body" --from cockpit --type status --subject "pr-aberto-14" --thread t)
  basename=$(basename "$file")
  if echo "$basename" | grep -q "pr-aberto-14"; then
    pass "kebab-case preservado"
  else
    fail "subject sumiu: $basename"
  fi

  file=$(run_script "body" --from cockpit --type status --subject "bad/subject:com espaços" --thread t)
  basename=$(basename "$file")
  if echo "$basename" | grep -qE "_bad_subject_com_espa.+\.md$"; then
    pass "caracteres não-kebab são substituídos"
  else
    fail "sanitização inesperada: $basename"
  fi
}

# ── 5. Concorrência: 2 chamadas seguidas têm filenames distintos ─

section_unique_filenames() {
  echo "── filenames únicos ──"

  local f1 f2
  f1=$(run_script "first" --from cockpit --type status --subject s --thread t)
  f2=$(run_script "second" --from cockpit --type status --subject s --thread t)

  if [ "$f1" != "$f2" ]; then
    pass "2 chamadas consecutivas → filenames diferentes"
  else
    fail "filename idêntico: $f1"
  fi
}

# ── 6. Body vazio é permitido (frontmatter sozinho) ──────────────

section_empty_body() {
  echo "── body vazio ──"

  local file
  file=$(echo -n "" | bash "$SCRIPT" --no-tmux --from logger --type status --subject s --thread t)
  [ -f "$file" ] && pass "arquivo criado com body vazio" || fail "arquivo não criado"
  if grep -q "^---$" "$file"; then pass "frontmatter presente sem body"; else fail "frontmatter ausente"; fi
}

# ── 7. Tmux: --no-tmux nunca tenta ───────────────────────────────

section_no_tmux() {
  echo "── --no-tmux respeitado ──"

  # Sem MMB_TMUX_SESSION e com --no-tmux: nenhuma tentativa de tmux,
  # nenhum erro/output stray.
  local out
  out=$(MMB_TMUX_SESSION="" run_script "body" --from cockpit --type status --subject s --thread t 2>&1)
  if [ -f "$out" ]; then
    pass "--no-tmux + sessão sem tmux funciona"
  else
    fail "output não é arquivo: $out"
  fi

  # Stdout deve ser SÓ o filepath (1 linha)
  local lines
  lines=$(echo "$out" | wc -l)
  if [ "$lines" = "1" ]; then
    pass "stdout = 1 linha (filepath)"
  else
    fail "stdout = $lines linhas"
  fi
}

# ── runner ───────────────────────────────────────────────────────

section_happy_path; echo
section_optional_source_msg; echo
section_validations; echo
section_subject_sanitization; echo
section_unique_filenames; echo
section_empty_body; echo
section_no_tmux; echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
