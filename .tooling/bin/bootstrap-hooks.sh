#!/usr/bin/env bash
# bootstrap-hooks.sh — instalação idempotente dos hooks MMB em
# .claude/settings.local.json do projeto.
#
# Hooks registrados:
#   PreToolUse(Bash)  → block-pr-merge.sh       (guardrail A10/A8 técnico)
#   UserPromptSubmit  → inject-pending-human.sh (B2B do mestre não-cego)
#   UserPromptSubmit  → inject-digest-tail.sh   (rotinas do digest no Mestre)
#
# Idempotente: detecta hooks já registrados (mesmo command path) e
# não duplica. Preserva todos os outros hooks/settings existentes.
#
# Uso:
#   .tooling/bin/bootstrap-hooks.sh           # registra + grava
#   .tooling/bin/bootstrap-hooks.sh --dry-run # mostra JSON sem gravar
#
# Env override:
#   MMB_CLAUDE_DIR=/path  usa outro dir em vez de $MMB_ROOT/.claude

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"
CLAUDE_DIR="${MMB_CLAUDE_DIR:-$MMB_ROOT/.claude}"
SETTINGS_FILE="$CLAUDE_DIR/settings.local.json"

BLOCK_PR_MERGE="$TOOLING_DIR/hooks/block-pr-merge.sh"
INJECT_PENDING="$TOOLING_DIR/hooks/inject-pending-human.sh"
INJECT_DIGEST="$TOOLING_DIR/hooks/inject-digest-tail.sh"

DRY_RUN=0

usage() {
  cat >&2 <<EOF
Uso: $0 [--dry-run]

  Registra hooks do andaime MMB em:
    $SETTINGS_FILE

  Hooks registrados:
    PreToolUse(Bash)  → block-pr-merge.sh       (A10/A8)
    UserPromptSubmit  → inject-pending-human.sh (mestre não-cego)
    UserPromptSubmit  → inject-digest-tail.sh   (digest rotineiro)

  Idempotente: detecta hooks já registrados (mesmo command path)
  e não duplica. Preserva outros hooks/settings existentes.

  --dry-run  imprime JSON resultante sem gravar.

Env override:
  MMB_CLAUDE_DIR=/path  usa outro dir em vez de \$MMB_ROOT/.claude
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERRO: arg desconhecido: $arg" >&2; usage; exit 1 ;;
  esac
done

# Pré-flight
if ! command -v jq >/dev/null 2>&1; then
  echo "ERRO: jq não instalado (sudo apt install jq)" >&2
  exit 2
fi

for h in "$BLOCK_PR_MERGE" "$INJECT_PENDING" "$INJECT_DIGEST"; do
  if [ ! -x "$h" ]; then
    echo "ERRO: hook não existe ou não é executável: $h" >&2
    exit 2
  fi
done

# Lê settings atual (ou inicia vazio).
if [ -f "$SETTINGS_FILE" ]; then
  CURRENT=$(cat "$SETTINGS_FILE")
  if ! echo "$CURRENT" | jq -e . >/dev/null 2>&1; then
    echo "ERRO: $SETTINGS_FILE existe mas não é JSON válido." >&2
    echo "Conserte manualmente antes de rodar bootstrap." >&2
    exit 3
  fi
else
  CURRENT='{}'
fi

# Helper: adiciona hook se NÃO houver entrada já com mesmo command path.
# Match é por command (não por matcher) — se você já registrou
# block-pr-merge.sh com matcher diferente, respeitamos.
add_hook() {
  local event="$1" matcher="$2" command="$3"

  local exists
  exists=$(echo "$CURRENT" | jq -r --arg ev "$event" --arg cmd "$command" '
    [.hooks?[$ev]?[]?.hooks[]? | select(.command == $cmd)] | length
  ')

  if [ "${exists:-0}" -gt 0 ]; then
    printf '  ↪ já registrado: %s → %s\n' "$event" "$command"
    return
  fi

  printf '  + adicionando : %s matcher="%s" → %s\n' "$event" "$matcher" "$command"

  CURRENT=$(echo "$CURRENT" | jq \
    --arg ev "$event" \
    --arg matcher "$matcher" \
    --arg cmd "$command" '
    .hooks //= {} |
    .hooks[$ev] //= [] |
    .hooks[$ev] += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}]
  ')
}

echo "Bootstrap MMB hooks → $SETTINGS_FILE"
echo ""

add_hook "PreToolUse"       "Bash" "$BLOCK_PR_MERGE"
add_hook "UserPromptSubmit" ""     "$INJECT_PENDING"
add_hook "UserPromptSubmit" ""     "$INJECT_DIGEST"

echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== Settings resultante (dry-run, NÃO gravado) ==="
  echo "$CURRENT" | jq .
  exit 0
fi

mkdir -p "$CLAUDE_DIR"
# Grava via mv-atomico pra evitar truncate-half-write.
TMP=$(mktemp -p "$CLAUDE_DIR" .settings.tmp.XXXXXX)
echo "$CURRENT" | jq . > "$TMP"
mv "$TMP" "$SETTINGS_FILE"

echo "✓ Settings gravado em $SETTINGS_FILE"
echo ""
echo "Hooks ativam em novas sessões Claude Code abertas neste projeto."
echo "Pra ativar agora, feche e reabra a sessão atual."
