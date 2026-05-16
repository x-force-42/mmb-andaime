#!/usr/bin/env bash
# Testes do .tooling/bin/append-digest.sh (B2A — andaime-fortification-v08).

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/append-digest.sh"

SANDBOX=$(mktemp -d /tmp/mmb-digest-test-XXXXXX)
export MMB_STATE_DIR="$SANDBOX/state"

TODAY=$(date -u +%Y-%m-%d)
DIGEST="$MMB_STATE_DIR/digest-${TODAY}.md"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run_script() {
  bash "$SCRIPT" "$@"
}

# ── 1. Cria arquivo do dia + header ──────────────────────────────

section_creates_file() {
  echo "── cria arquivo com header ──"

  rm -f "$DIGEST"
  run_script --from cockpit --type status --subject pr-aberto-14 \
             --thread ux-refresh-v07 --glyph "✓" --action "digest atualizado"

  [ -f "$DIGEST" ] && pass "arquivo criado" || { fail "arquivo não existe"; return; }
  if head -1 "$DIGEST" | grep -q "^# Digest — ${TODAY}$"; then
    pass "header tem data UTC"
  else
    fail "header inesperado: $(head -1 "$DIGEST")"
  fi
}

# ── 2. Append correto ────────────────────────────────────────────

section_append_entry() {
  echo "── append de entrada ──"

  if grep -q "## .* · cockpit · status:pr-aberto-14 · thread=ux-refresh-v07" "$DIGEST"; then
    pass "linha de cabeçalho da entrada"
  else
    fail "cabeçalho ausente"
  fi
  if grep -q "^✓ digest atualizado$" "$DIGEST"; then
    pass "linha de ação com glyph"
  else
    fail "linha de ação ausente"
  fi
}

# ── 3. Não duplica header em chamadas subsequentes ───────────────

section_no_duplicate_header() {
  echo "── não duplica header ──"

  run_script --from logger --type status --subject issue-criada-8 \
             --thread ux-refresh-v07 --glyph "✓" --action "tickbox marked"

  local header_count
  header_count=$(grep -c "^# Digest — " "$DIGEST")
  if [ "$header_count" = "1" ]; then
    pass "exatamente 1 header (não duplica)"
  else
    fail "headers = $header_count"
  fi

  # E manteve a entrada antiga
  if grep -q "pr-aberto-14" "$DIGEST"; then
    pass "entrada antiga preservada"
  else
    fail "entrada antiga sumiu"
  fi
}

# ── 4. Glyph escalado ⚠ ──────────────────────────────────────────

section_escalation_glyph() {
  echo "── glyph escalado ──"

  run_script --from aquarium --type error --subject worker-timeout \
             --thread ux-refresh-v07 --glyph "⚠" --action "ESCALADO → pending-human/foo.md"

  if grep -q "^⚠ ESCALADO" "$DIGEST"; then
    pass "linha com ⚠ presente"
  else
    fail "linha com ⚠ ausente"
  fi
}

# ── 5. Validações ────────────────────────────────────────────────

section_validations() {
  echo "── validações ──"

  set +e
  run_script --type status --subject s --thread t --glyph "✓" --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--from ausente → exit 1" || fail "esperado 1"

  run_script --from x --subject s --thread t --glyph "✓" --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--type ausente → exit 1" || fail "esperado 1"

  run_script --from x --type s --thread t --glyph "✓" --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--subject ausente → exit 1" || fail "esperado 1"

  run_script --from x --type s --subject sb --glyph "✓" --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--thread ausente → exit 1" || fail "esperado 1"

  run_script --from x --type s --subject sb --thread t --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--glyph ausente → exit 1" || fail "esperado 1"

  run_script --from x --type s --subject sb --thread t --glyph "✓" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--action ausente → exit 1" || fail "esperado 1"

  run_script --from x --type s --subject sb --thread t --glyph BAD --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "--glyph inválido → exit 1" || fail "esperado 1"

  run_script --bogus X --from x --type s --subject sb --thread t --glyph "✓" --action a >/dev/null 2>&1
  [ $? -eq 1 ] && pass "flag desconhecida → exit 1" || fail "esperado 1"
  set -e
}

# ── 6. Concorrência: 5 writers paralelos não corrompem ───────────

section_concurrency() {
  echo "── concorrência com flock ──"

  rm -f "$DIGEST"

  # Dispara 10 chamadas em paralelo
  for i in $(seq 1 10); do
    run_script --from cockpit --type status --subject "pr-aberto-$i" \
               --thread parallel-test --glyph "✓" --action "entry $i" &
  done
  wait

  # Conta entradas — devem ser exatamente 10
  local entries
  entries=$(grep -c "^## .* · cockpit · status:pr-aberto-" "$DIGEST" || echo 0)
  if [ "$entries" = "10" ]; then
    pass "10 chamadas paralelas → 10 entradas no arquivo"
  else
    fail "esperado 10, got $entries"
  fi

  # Sem linhas intercaladas: para cada cabeçalho `^## `, próxima linha
  # começa com glyph + espaço + "entry"
  local intercalated=0
  awk '
    /^## / { expect_action=1; next }
    expect_action && /^[✓⚠] entry [0-9]+$/ { expect_action=0; next }
    expect_action && /^$/ { expect_action=0; mismatch=1; next }
    expect_action && /./ { mismatch++ }
    END { exit mismatch }
  ' "$DIGEST"
  if [ $? -eq 0 ]; then
    pass "linhas não intercaladas (flock funcionou)"
  else
    fail "linhas intercaladas — flock falhou"
  fi
}

section_creates_file; echo
section_append_entry; echo
section_no_duplicate_header; echo
section_escalation_glyph; echo
section_validations; echo
section_concurrency; echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
