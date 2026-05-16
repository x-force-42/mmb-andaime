#!/usr/bin/env bash
# Testes dos hooks do Claude Code em .tooling/hooks/.
#
# B2C — enforcement técnico dos guardrails A10/A8 via block-pr-merge.sh.
#
# Uso:
#   bash .tooling/tests/test-hooks.sh
#
# Requer `jq`. Exit 0 se todos os asserts passarem.

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK_BLOCK_PR_MERGE="$TOOLING_DIR/hooks/block-pr-merge.sh"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# Roda o hook com um JSON de tool call montado a partir de tool_name + command.
# Retorna apenas o exit code (stdout/stderr descartados).
#
# Uso: run_hook <agent_id> <tool_name> <command>
#   agent_id vazio = simula sessão SEM MMB_AGENT_ID (Mestre/Rick/manual).
run_hook() {
  local agent_id="$1" tool_name="$2" command="$3"
  local input
  input=$(jq -nc \
    --arg t "$tool_name" \
    --arg c "$command" \
    '{tool_name:$t, tool_input:{command:$c}}')

  set +e
  if [ -n "$agent_id" ]; then
    MMB_AGENT_ID="$agent_id" bash "$HOOK_BLOCK_PR_MERGE" <<<"$input" >/dev/null 2>&1
  else
    # `env -u MMB_AGENT_ID` garante remoção mesmo se herdou do shell.
    env -u MMB_AGENT_ID bash "$HOOK_BLOCK_PR_MERGE" <<<"$input" >/dev/null 2>&1
  fi
  local rc=$?
  set -e
  echo "$rc"
}

# Asserter conveniente.
assert_exit() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    pass "$label (exit=$got)"
  else
    fail "$label (esperado $expected, got $got)"
  fi
}

# ── 1. Bloqueia em sessão atômica ────────────────────────────────

section_blocks() {
  echo "── block-pr-merge: bloqueia em sessão atômica ──"

  assert_exit "gh pr merge"                                 2 "$(run_hook "cockpit-M4" "Bash" "gh pr merge 14")"
  assert_exit "gh pr merge --auto"                          2 "$(run_hook "logger-L2" "Bash" "gh pr merge --auto")"
  assert_exit "gh pr merge --squash --delete-branch"        2 "$(run_hook "logger-L2" "Bash" "gh pr merge --squash --delete-branch 9")"
  assert_exit "gh pr review --approve"                      2 "$(run_hook "cockpit-M4" "Bash" "gh pr review --approve 14")"
  assert_exit "gh pr review 14 --approve --body lgtm"       2 "$(run_hook "cockpit-M4" "Bash" "gh pr review 14 --approve --body lgtm")"

  # Comandos aninhados
  assert_exit "comando aninhado por ';' (true; gh pr merge)" 2 "$(run_hook "x-A1" "Bash" "true; gh pr merge 14")"
  assert_exit "comando aninhado por '&&'"                    2 "$(run_hook "x-A1" "Bash" "echo hi && gh pr merge 14")"
  assert_exit "subshell \$()"                                2 "$(run_hook "x-A1" "Bash" 'X=$(gh pr merge 14)')"
  assert_exit "subshell backtick"                            2 "$(run_hook "x-A1" "Bash" 'echo `gh pr merge 14`')"
  assert_exit "pipe"                                         2 "$(run_hook "x-A1" "Bash" "echo foo | gh pr merge 14")"
}

# ── 2. Permite quando NÃO é sessão atômica ───────────────────────

section_allows_non_atomic() {
  echo "── block-pr-merge: permite quando MMB_AGENT_ID não setado ──"

  assert_exit "gh pr merge sem agent_id (Mestre/Rick)"     0 "$(run_hook "" "Bash" "gh pr merge 14")"
  assert_exit "gh pr review --approve sem agent_id"        0 "$(run_hook "" "Bash" "gh pr review --approve 14")"
}

# ── 3. Permite comandos não-destrutivos (mesmo em atômico) ───────

section_allows_neutral() {
  echo "── block-pr-merge: permite comandos não-destrutivos ──"

  assert_exit "gh pr view"                                 0 "$(run_hook "cockpit-M4" "Bash" "gh pr view 14")"
  assert_exit "gh pr list"                                 0 "$(run_hook "cockpit-M4" "Bash" "gh pr list")"
  assert_exit "gh pr create (atômico precisa pra abrir PR)" 0 "$(run_hook "cockpit-M4" "Bash" "gh pr create --title X --body Y")"
  assert_exit "gh issue view"                              0 "$(run_hook "cockpit-M4" "Bash" "gh issue view 13")"
  assert_exit "gh issue create"                            0 "$(run_hook "cockpit-M4" "Bash" "gh issue create --title X")"
  assert_exit "gh pr review --comment (sem --approve)"     0 "$(run_hook "cockpit-M4" "Bash" "gh pr review 14 --comment --body note")"
  assert_exit "npm test"                                   0 "$(run_hook "cockpit-M4" "Bash" "npm test")"
  assert_exit "git push"                                   0 "$(run_hook "cockpit-M4" "Bash" "git push origin HEAD")"
}

# ── 4. Robustez ──────────────────────────────────────────────────

section_robustness() {
  echo "── block-pr-merge: robustez ──"

  assert_exit "tool_name=Read → ignora"                    0 "$(run_hook "cockpit-M4" "Read" "doesnt matter")"
  assert_exit "tool_name=Write → ignora"                   0 "$(run_hook "cockpit-M4" "Write" "doesnt matter")"

  # stdin vazio / JSON malformado: hook não pode travar
  set +e
  echo "" | MMB_AGENT_ID=x bash "$HOOK_BLOCK_PR_MERGE" >/dev/null 2>&1
  rc=$?
  set -e
  assert_exit "stdin vazio → exit 0 (não trava)"           0 "$rc"

  set +e
  echo "not json" | MMB_AGENT_ID=x bash "$HOOK_BLOCK_PR_MERGE" >/dev/null 2>&1
  rc=$?
  set -e
  assert_exit "JSON malformado → exit 0 (não trava)"       0 "$rc"
}

# ── 5. Falsos positivos / anti-overmatching ──────────────────────

section_anti_overmatch() {
  echo "── block-pr-merge: não overmatcha similares ──"

  # `mygh pr merge` (substring com prefixo errado) — não deveria bloquear,
  # mas honestamente é melhor ser conservador. Quanto vale o false positive?
  # Tem MMB_AGENT_ID setado E parece comando real. Bloqueia, é mais seguro.
  # → Documentado como comportamento esperado: melhor 1 FP raro que 1 FN.
  #
  # Aqui só testamos cenários onde de fato NÃO há `gh pr merge` real:

  assert_exit "echo sem gh"                                0 "$(run_hook "cockpit-M4" "Bash" "echo 'gh-pr-merge is bad'")"
  assert_exit "comentário em string sem gh"                0 "$(run_hook "cockpit-M4" "Bash" "echo 'note about merge'")"
  assert_exit "merge sem gh pr (git merge)"                0 "$(run_hook "cockpit-M4" "Bash" "git merge feature-x")"
  assert_exit "approve em outro contexto (sem --approve flag)" 0 "$(run_hook "cockpit-M4" "Bash" "echo 'approve this idea'")"
  assert_exit "gh pr review --approve em comentário shell" 2 "$(run_hook "cockpit-M4" "Bash" "# gh pr review --approve")"
  # ↑ Bloqueado: o hook não interpreta `#` shell-comment. Conservador-safe;
  #   atômico não escreve comentários shell em tool calls com intenção
  #   relevante.
}

# ── runner ───────────────────────────────────────────────────────

section_blocks
echo
section_allows_non_atomic
echo
section_allows_neutral
echo
section_robustness
echo
section_anti_overmatch
echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
