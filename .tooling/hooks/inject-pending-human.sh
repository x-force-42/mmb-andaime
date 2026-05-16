#!/usr/bin/env bash
# inject-pending-human.sh — hook UserPromptSubmit do Claude Code.
#
# Lê .tooling/state/pending-human/ a cada submit do prompt. Se houver
# entradas, prepende no contexto do prompt e move pra .processed/.
# Reseta o indicador visual da tab master no tmux.
#
# Protocolo de hook UserPromptSubmit:
#   - stdout do hook é injetado no contexto do prompt (Claude lê)
#   - exit 0: prompt segue normalmente
#   - exit 2: bloqueia o prompt (NÃO QUEREMOS isso aqui)
#
# Falha silenciosa: qualquer erro inesperado → exit 0 sem output.
# Hook NUNCA deve bloquear o usuário ou poluir o contexto com lixo.
#
# Configuração: .claude/settings.local.json (use bootstrap-hooks.sh).

set -uo pipefail  # NÃO -e: preferimos exit 0 mesmo em falha parcial

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
[ -f "$TOOLING_DIR/config.sh" ] && source "$TOOLING_DIR/config.sh" 2>/dev/null || true

STATE_DIR="${MMB_STATE_DIR:-$TOOLING_DIR/state}"
PENDING_DIR="${MMB_PENDING_HUMAN_DIR:-$STATE_DIR/pending-human}"
PROCESSED_DIR="$PENDING_DIR/.processed"

# Dir não existe → no-op silencioso.
[ -d "$PENDING_DIR" ] || exit 0

# Lista arquivos non-hidden, ordem cronológica via sort
# (timestamp-prefixed filename garante ordem natural).
mapfile -t FILES < <(find "$PENDING_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

# Sem pendências → silent exit.
[ ${#FILES[@]} -eq 0 ] && exit 0

mkdir -p "$PROCESSED_DIR" 2>/dev/null || exit 0

# Prepende bloco estruturado no stdout (vira contexto do prompt).
COUNT=${#FILES[@]}
{
  echo "<pending-human-msgs count=${COUNT}>"
  for f in "${FILES[@]}"; do
    bn=$(basename "$f")
    echo ""
    echo "=== entry: ${bn} ==="
    echo ""
    cat "$f" 2>/dev/null || echo "(leitura falhou: $bn)"
  done
  echo ""
  echo "</pending-human-msgs>"
}

# Move processados pra .processed/. Falha individual não trava o resto.
for f in "${FILES[@]}"; do
  bn=$(basename "$f")
  mv "$f" "$PROCESSED_DIR/$bn" 2>/dev/null || true
done

# Reseta indicador tmux da tab master. Best-effort, no-op se inacessível.
# write-pending-human.sh renomeia "master" → "master ⚠" + bg=red; aqui
# revertemos os dois. Se a tab tem outro nome ou não existe, ignora.
if command -v tmux >/dev/null 2>&1; then
  SESSION="${MMB_TMUX_SESSION:-mmb}"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    # Procura window cujo nome seja "master" ou "master ⚠"; renomeia
    # se for o caso "marcado".
    win_names=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null || echo "")
    if echo "$win_names" | grep -qx "master ⚠"; then
      tmux rename-window -t "${SESSION}:master ⚠" "master" 2>/dev/null || true
    fi
    # Reset do style. -u desfaz a opção (volta ao default da sessão).
    if echo "$win_names" | grep -qE '^master( ⚠)?$'; then
      tmux set-window-option -t "${SESSION}:master" -u window-status-style 2>/dev/null || true
      tmux set-window-option -t "${SESSION}:master" -u window-status-current-style 2>/dev/null || true
    fi
  fi
fi

exit 0
