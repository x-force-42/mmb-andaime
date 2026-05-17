#!/usr/bin/env bash
# Testes do .tooling/hooks/inject-digest-tail.sh
#
# Cobre os 8 casos definidos no mini-design aprovado:
#   1. digest vazio → não injeta
#   2. 3 marcos novos → injeta 3
#   3. segunda execução → não repete
#   4. >10 marcos → últimos 10 + indicador de omissão
#   5. task-fechada last_in_epic:true → NÃO entra (worker já mandou
#      pra pending-human; digest não tem essas entries com ✓)
#   6. pr-aberto suite_status != verde → NÃO entra (mesma razão)
#   7. cursor deletado → reinjeta histórico (limitado a 10)
#   8. bootstrap não duplica (testado em test-bootstrap-hooks.sh)

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$TOOLING_DIR/hooks/inject-digest-tail.sh"

SANDBOX=$(mktemp -d /tmp/mmb-digest-tail-XXXXXX)
export MMB_STATE_DIR="$SANDBOX/state"
mkdir -p "$MMB_STATE_DIR"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run_hook() {
  MMB_STATE_DIR="$MMB_STATE_DIR" bash "$HOOK" "$@"
}

# Helper: cria entry de digest. Args: file, time, from, type, subject, thread, glyph, action
add_entry() {
  local file="$1" time="$2" from="$3" type="$4" subject="$5" thread="$6" glyph="$7" action="$8"
  cat >> "$file" <<EOF
## ${time} · ${from} · ${type}:${subject} · thread=${thread}
${glyph} ${action}

EOF
}

reset_sandbox() {
  rm -rf "$MMB_STATE_DIR"
  mkdir -p "$MMB_STATE_DIR"
}

# ── 1. Digest vazio ─────────────────────────────────────────────

section_empty() {
  echo "── digest vazio ──"
  reset_sandbox
  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 com state vazio" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio com state vazio" || fail "stdout: [$out]"
}

# ── 2. 3 marcos novos ──────────────────────────────────────────

section_three_new() {
  echo "── 3 marcos novos ──"
  reset_sandbox

  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"
  add_entry "$digest" "18:24:21" "cockpit" "status" "issue-criada-15" "dark-mode" "✓" "digest atualizado, briefing #? → #15"
  add_entry "$digest" "18:35:17" "cockpit" "status" "pr-aberto-16" "dark-mode" "✓" "PR aberto https://github.com/x-force-42/mmb-cockpit/pull/16"
  add_entry "$digest" "18:37:57" "aquarium" "status" "pr-aberto-15" "dark-mode" "✓" "PR aberto https://.../pull/15"

  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q '<mestre-digest novos="3"' && pass "header com novos=3" || fail "header: $(echo "$out" | head -1)"
  local count
  count=$(echo "$out" | grep -c '^- ')
  [ "$count" = "3" ] && pass "3 linhas de marco" || fail "count=$count"
  echo "$out" | grep -q "issue-criada-15" && pass "contém issue-criada-15" || fail "faltou issue-criada-15"
  echo "$out" | grep -q "pr-aberto-16" && pass "contém pr-aberto-16" || fail "faltou pr-aberto-16"
}

# ── 3. Segunda execução não repete ─────────────────────────────

section_no_repeat() {
  echo "── segunda execução ──"
  # mantém estado do test anterior (cursor avançou)
  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 em rerun" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio em rerun" || fail "stdout não-vazio: [$out]"
}

# ── 4. >10 marcos: mostra últimos 10 + indicador ──────────────

section_overflow() {
  echo "── >10 marcos ──"
  reset_sandbox

  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"

  local i
  for i in $(seq 1 13); do
    # Tempos espaçados pra ordenar previsivelmente
    local hh=$(printf "%02d" $((10 + i)))
    add_entry "$digest" "${hh}:00:00" "cockpit" "status" "issue-criada-${i}" "epic-x" "✓" "digest update #${i}"
  done

  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0 com overflow" || fail "exit=$rc"
  echo "$out" | grep -q 'mostrando="últimos 10"' && pass "header indica truncamento" || fail "header não truncou: $(echo "$out" | head -1)"
  local count
  count=$(echo "$out" | grep -c '^- ')
  [ "$count" = "10" ] && pass "exatamente 10 linhas" || fail "count=$count"
  echo "$out" | grep -q '+3 marcos anteriores omitidos' && pass "indicador de 3 omitidos" || fail "sem indicador omissão"
  # Confirma que mostrou os MAIS RECENTES (issue-criada-13 sim, issue-criada-1 não)
  echo "$out" | grep -q "issue-criada-13" && pass "mostrou o mais recente" || fail "faltou issue-criada-13"
  echo "$out" | grep -q "issue-criada-1 " && fail "issue-criada-1 aparece (deveria estar omitido)" || pass "issue-criada-1 omitido"
}

# ── 5. task-fechada last_in_epic:true não entra ──────────────
#
# Worker-master já mandou pra pending-human (não pro digest com ✓).
# Hook só vê o digest, então a regra é: digest com ✓ + whitelist passa.
# Se worker-master rotear ⚠ (escalada), não entra no mestre-digest.

section_escalated_not_in() {
  echo "── escalada (⚠) não entra ──"
  reset_sandbox

  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"
  # task-fechada last_in_epic:true → worker-master escalou (glyph ⚠)
  add_entry "$digest" "20:00:00" "cockpit" "status" "task-fechada-1.1" "epic-y" "⚠" "épico pronto pra fechamento (escalado pra pending-human)"
  # pr-aberto suite_status:vermelha → worker-master escalou (glyph ⚠)
  add_entry "$digest" "20:05:00" "core" "status" "pr-aberto-42" "epic-y" "⚠" "suite vermelha (escalado pra pending-human)"
  # rotina normal (controle): pr-aberto verde → deve entrar
  add_entry "$digest" "20:10:00" "cockpit" "status" "pr-aberto-43" "epic-y" "✓" "PR aberto suite verde"

  local out rc
  set +e
  out=$(run_hook 2>&1)
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "exit 0" || fail "exit=$rc"
  echo "$out" | grep -q 'novos="1"' && pass "só 1 entry (não 3)" || fail "header: $(echo "$out" | head -1)"
  echo "$out" | grep -q "pr-aberto-43" && pass "pr-aberto verde entrou" || fail "rotina verde faltou"
  echo "$out" | grep -q "task-fechada-1.1" && fail "task-fechada escalada vazou" || pass "task-fechada escalada filtrada"
  echo "$out" | grep -q "pr-aberto-42" && fail "pr-aberto vermelho vazou" || pass "pr-aberto vermelho filtrado"
}

# ── 6. Cursor deletado reinjeta histórico ─────────────────────

section_cursor_reset() {
  echo "── cursor deletado reinjeta ──"
  reset_sandbox

  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"
  add_entry "$digest" "10:00:00" "cockpit" "status" "issue-criada-100" "epic-z" "✓" "ação"
  add_entry "$digest" "11:00:00" "cockpit" "status" "issue-criada-101" "epic-z" "✓" "ação"

  # 1ª execução: vê 2
  set +e
  local out1=$(run_hook 2>&1)
  set -e
  echo "$out1" | grep -q 'novos="2"' && pass "1ª exec vê 2" || fail "1ª exec: $(echo "$out1" | head -1)"

  # 2ª execução: vê 0
  set +e
  local out2=$(run_hook 2>&1)
  set -e
  [ -z "$out2" ] && pass "2ª exec vazia" || fail "2ª exec não-vazia: [$out2]"

  # Deleta cursor
  rm -f "$MMB_STATE_DIR/digest-cursor-master.txt"

  # 3ª execução: vê 2 de novo
  set +e
  local out3=$(run_hook 2>&1)
  set -e
  echo "$out3" | grep -q 'novos="2"' && pass "cursor deletado reinjeta 2" || fail "reinjeção: $(echo "$out3" | head -1)"
}

# ── 7. Múltiplos dias: cursor cobre transição ─────────────────

section_multiday() {
  echo "── múltiplos dias ──"
  reset_sandbox

  local d1="$MMB_STATE_DIR/digest-2026-05-15.md"
  local d2="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-15" > "$d1"
  echo "" >> "$d1"
  add_entry "$d1" "23:00:00" "cockpit" "status" "issue-criada-200" "ontem" "✓" "ação"

  echo "# Digest — 2026-05-16" > "$d2"
  echo "" >> "$d2"
  add_entry "$d2" "01:00:00" "cockpit" "status" "issue-criada-201" "hoje" "✓" "ação"

  set +e
  local out=$(run_hook 2>&1)
  set -e
  echo "$out" | grep -q 'novos="2"' && pass "vê entries de 2 dias" || fail "multi-dia: $(echo "$out" | head -1)"
  echo "$out" | grep -q "issue-criada-200" && pass "vê dia anterior" || fail "faltou dia anterior"
  echo "$out" | grep -q "issue-criada-201" && pass "vê dia atual" || fail "faltou dia atual"
}

# ── 8. Subject fora da whitelist é ignorado ──────────────────

section_unknown_subject() {
  echo "── subject fora da whitelist ──"
  reset_sandbox

  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"
  # Subject não-whitelistado mas com glyph ✓ — defensivo
  add_entry "$digest" "15:00:00" "core" "status" "experimento-x" "epic-y" "✓" "ação"
  add_entry "$digest" "15:01:00" "core" "status" "issue-criada-300" "epic-y" "✓" "ação"

  set +e
  local out=$(run_hook 2>&1)
  set -e
  echo "$out" | grep -q 'novos="1"' && pass "só whitelistado entrou" || fail "header: $(echo "$out" | head -1)"
  echo "$out" | grep -q "issue-criada-300" && pass "whitelisted presente" || fail "whitelisted faltou"
  echo "$out" | grep -q "experimento-x" && fail "subject estranho vazou" || pass "subject estranho filtrado"
}

# ── Run ───────────────────────────────────────────────────────

section_worker_guard() {
  echo "── guard MMB_AGENT_ID (B2) ──"
  reset_sandbox

  # Cria digest com entries que SERIAM injetadas no Master
  local digest="$MMB_STATE_DIR/digest-2026-05-16.md"
  echo "# Digest — 2026-05-16" > "$digest"
  echo "" >> "$digest"
  add_entry "$digest" "10:00:00" "cockpit" "status" "issue-criada-500" "guard-test" "✓" "ação"
  add_entry "$digest" "11:00:00" "cockpit" "status" "pr-aberto-501" "guard-test" "✓" "PR aberto"

  # Estado de referência ANTES de rodar com MMB_AGENT_ID setado.
  [ ! -f "$MMB_STATE_DIR/digest-cursor-master.txt" ] && pass "pré: cursor não existe" || fail "pré: cursor já existe"
  local digest_md5_before
  digest_md5_before=$(md5sum "$digest" | awk '{print $1}')

  # Rodar como worker (MMB_AGENT_ID setado conforme worker.sh:202).
  local out rc
  set +e
  out=$(MMB_AGENT_ID="cockpit-12345" MMB_STATE_DIR="$MMB_STATE_DIR" bash "$HOOK" 2>&1)
  rc=$?
  set -e

  # (a) Hook saiu sem efeito.
  [ "$rc" = "0" ] && pass "exit 0 com MMB_AGENT_ID=worker" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio (sem <mestre-digest> injetado)" || fail "stdout vazou: [$out]"

  # (b) Cursor não foi criado/atualizado.
  [ ! -f "$MMB_STATE_DIR/digest-cursor-master.txt" ] && pass "cursor inalterado (não criado)" || fail "cursor foi criado/tocado pelo worker"

  # (c) Digest inalterado (md5).
  local digest_md5_after
  digest_md5_after=$(md5sum "$digest" | awk '{print $1}')
  [ "$digest_md5_before" = "$digest_md5_after" ] && pass "digest md5 inalterado" || fail "digest foi modificado"

  # (d) Sanity check: Master (sem env) AINDA vê as 2 entries — confirma
  # que o guard é o único filtro, não a ausência das entries.
  set +e
  out=$(MMB_STATE_DIR="$MMB_STATE_DIR" bash "$HOOK" 2>&1)
  set -e
  echo "$out" | grep -q 'novos="2"' && pass "Master (sem env) ainda vê as 2 entries — guard é o único filtro" || fail "Master também não vê — guard não está isolado"
}

section_empty
section_three_new
section_no_repeat
section_overflow
section_escalated_not_in
section_cursor_reset
section_multiday
section_unknown_subject
section_worker_guard

echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
