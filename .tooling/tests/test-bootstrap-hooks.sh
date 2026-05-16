#!/usr/bin/env bash
# Testes do .tooling/bin/bootstrap-hooks.sh (B2B — andaime-fortification-v08).

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/bootstrap-hooks.sh"

SANDBOX=$(mktemp -d /tmp/mmb-boot-test-XXXXXX)
export MMB_CLAUDE_DIR="$SANDBOX/.claude"
SETTINGS="$MMB_CLAUDE_DIR/settings.local.json"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run_script() {
  MMB_CLAUDE_DIR="$MMB_CLAUDE_DIR" bash "$SCRIPT" "$@"
}

# Paths dos hooks pra comparação
BLOCK_PR_MERGE="$TOOLING_DIR/hooks/block-pr-merge.sh"
INJECT_PENDING="$TOOLING_DIR/hooks/inject-pending-human.sh"

# Helper: conta entradas com `command == $cmd` no event
count_hook() {
  local event="$1" cmd="$2"
  jq -r --arg ev "$event" --arg cmd "$cmd" '
    [.hooks?[$ev]?[]?.hooks[]? | select(.command == $cmd)] | length
  ' "$SETTINGS"
}

# ── 1. Settings ausente → cria com 2 hooks ───────────────────────

section_no_settings() {
  echo "── settings ausente ──"

  rm -rf "$MMB_CLAUDE_DIR"

  run_script >/dev/null

  [ -f "$SETTINGS" ] && pass "settings.local.json criado" || { fail "settings não existe"; return; }

  jq -e . "$SETTINGS" >/dev/null && pass "JSON válido" || fail "JSON inválido"

  if [ "$(count_hook PreToolUse "$BLOCK_PR_MERGE")" = "1" ]; then
    pass "PreToolUse block-pr-merge registrado"
  else
    fail "PreToolUse não registrado"
  fi

  if [ "$(count_hook UserPromptSubmit "$INJECT_PENDING")" = "1" ]; then
    pass "UserPromptSubmit inject-pending-human registrado"
  else
    fail "UserPromptSubmit não registrado"
  fi
}

# ── 2. Idempotência: rodar 2x não duplica ────────────────────────

section_idempotent() {
  echo "── idempotência ──"

  run_script >/dev/null  # 2ª vez

  if [ "$(count_hook PreToolUse "$BLOCK_PR_MERGE")" = "1" ]; then
    pass "block-pr-merge ainda count=1 após 2ª rodada"
  else
    fail "block-pr-merge duplicou"
  fi
  if [ "$(count_hook UserPromptSubmit "$INJECT_PENDING")" = "1" ]; then
    pass "inject-pending-human ainda count=1 após 2ª rodada"
  else
    fail "inject-pending-human duplicou"
  fi

  run_script >/dev/null  # 3ª vez
  if [ "$(count_hook PreToolUse "$BLOCK_PR_MERGE")" = "1" ] \
    && [ "$(count_hook UserPromptSubmit "$INJECT_PENDING")" = "1" ]; then
    pass "3ª rodada também idempotente"
  else
    fail "duplicou na 3ª rodada"
  fi
}

# ── 3. Settings existente com hooks de terceiros: preservar ──────

section_preserve_other_hooks() {
  echo "── preserva hooks de terceiros ──"

  rm -rf "$MMB_CLAUDE_DIR"
  mkdir -p "$MMB_CLAUDE_DIR"
  cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {"type": "command", "command": "/usr/local/bin/some-other-hook.sh"}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "/usr/local/bin/another-tool.sh"}
        ]
      }
    ]
  },
  "model": "claude-opus-4-7"
}
EOF

  run_script >/dev/null

  # Hooks de terceiros ainda presentes
  if [ "$(count_hook PreToolUse "/usr/local/bin/some-other-hook.sh")" = "1" ]; then
    pass "hook PreToolUse de terceiro preservado"
  else
    fail "hook de terceiro sumiu"
  fi
  if [ "$(count_hook UserPromptSubmit "/usr/local/bin/another-tool.sh")" = "1" ]; then
    pass "hook UserPromptSubmit de terceiro preservado"
  else
    fail "hook UserPromptSubmit de terceiro sumiu"
  fi

  # Settings não-hook preservado
  if [ "$(jq -r .model "$SETTINGS")" = "claude-opus-4-7" ]; then
    pass "outras keys do settings preservadas (model)"
  else
    fail "key não-hook foi removida"
  fi

  # Hooks MMB adicionados
  if [ "$(count_hook PreToolUse "$BLOCK_PR_MERGE")" = "1" ]; then
    pass "block-pr-merge adicionado ao lado dos existentes"
  else
    fail "block-pr-merge não adicionado"
  fi
}

# ── 4. Pré-existência de UM dos hooks MMB → adiciona só o outro ──

section_partial_state() {
  echo "── um hook MMB já registrado ──"

  rm -rf "$MMB_CLAUDE_DIR"
  mkdir -p "$MMB_CLAUDE_DIR"
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "$BLOCK_PR_MERGE"}
        ]
      }
    ]
  }
}
EOF

  run_script >/dev/null

  if [ "$(count_hook PreToolUse "$BLOCK_PR_MERGE")" = "1" ]; then
    pass "block-pr-merge existente não duplicado"
  else
    fail "block-pr-merge duplicou ou sumiu"
  fi
  if [ "$(count_hook UserPromptSubmit "$INJECT_PENDING")" = "1" ]; then
    pass "inject-pending-human adicionado (não estava)"
  else
    fail "inject-pending-human não adicionado"
  fi
}

# ── 5. JSON malformado → exit 3 sem escrever ─────────────────────

section_malformed() {
  echo "── JSON malformado ──"

  rm -rf "$MMB_CLAUDE_DIR"
  mkdir -p "$MMB_CLAUDE_DIR"
  echo "{ this is not json" > "$SETTINGS"
  local backup
  backup=$(cat "$SETTINGS")

  set +e
  run_script >/dev/null 2>&1
  rc=$?
  set -e

  [ "$rc" = "3" ] && pass "exit 3 com JSON inválido" || fail "exit=$rc esperado 3"
  if [ "$(cat "$SETTINGS")" = "$backup" ]; then
    pass "settings inválido NÃO foi sobrescrito"
  else
    fail "settings sobrescrito apesar de exit não-zero"
  fi
}

# ── 6. --dry-run não escreve ─────────────────────────────────────

section_dry_run() {
  echo "── --dry-run ──"

  rm -rf "$MMB_CLAUDE_DIR"

  local out rc
  set +e
  out=$(run_script --dry-run 2>&1)
  rc=$?
  set -e

  [ "$rc" = "0" ] && pass "--dry-run exit 0" || fail "exit=$rc"
  [ ! -f "$SETTINGS" ] && pass "--dry-run não gravou arquivo" || fail "settings foi gravado em dry-run"
  if echo "$out" | grep -q "dry-run, NÃO gravado"; then
    pass "--dry-run avisa que não gravou"
  else
    fail "mensagem dry-run ausente"
  fi
  if echo "$out" | grep -q "\"PreToolUse\""; then
    pass "--dry-run imprime JSON resultante"
  else
    fail "JSON não impresso em dry-run"
  fi
}

# ── 7. Args inválidos ────────────────────────────────────────────

section_invalid_args() {
  echo "── args inválidos ──"

  set +e
  run_script --bogus >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = "1" ] && pass "flag desconhecida → exit 1" || fail "exit=$rc esperado 1"
}

section_no_settings; echo
section_idempotent; echo
section_preserve_other_hooks; echo
section_partial_state; echo
section_malformed; echo
section_dry_run; echo
section_invalid_args; echo

echo "─────────────────────────────────"
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures de $ran"
  exit 1
fi
echo "OK: $ran/$ran"
