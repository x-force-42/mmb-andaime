#!/usr/bin/env bash
# inject-digest-tail.sh — hook UserPromptSubmit do Claude Code.
#
# Lê os digests diários do worker-master (state/digest-YYYY-MM-DD.md)
# e injeta no contexto do próximo prompt do Mestre interativo um
# resumo dos marcos rotineiros (✓) que ainda não foram vistos.
#
# Cursor monotônico em state/digest-cursor-master.txt (ISO8601 UTC)
# evita repetição.
#
# Filtra:
#   - apenas entries com glyph ✓ (rotina; worker-master já mandou
#     escalações pra pending-human)
#   - apenas type=status (briefing/question/error não passam pelo
#     digest, mas defensivo)
#   - apenas subjects da whitelist: issue-criada-N, pr-aberto-N,
#     task-fechada(-id)
#
# Limita a 10 marcos por injeção. Se houver mais, mostra últimos 10
# e indica quantos ficaram fora.
#
# Protocolo de hook UserPromptSubmit:
#   - stdout vira contexto do prompt
#   - exit 0 sempre (mesmo em falha) — nunca bloquear o usuário
#
# Configuração: .claude/settings.local.json (use bootstrap-hooks.sh).

set -uo pipefail

# Guard de contexto (B2 do plano de fortificações, 2026-05-17):
# Hooks UserPromptSubmit rodam em QUALQUER claude que use esta
# .claude/settings.local.json — inclusive `claude -p` de workers
# stateless invocados pelo commd. O invariante:
#
#   Hooks destinados ao Master interativo NÃO podem produzir
#   efeitos colaterais quando rodando em worker stateless.
#
# Identidades canônicas (validadas via env):
#   - Master interativo: MMB_AGENT_ID=master    (setado pelo up.sh)
#   - Worker stateless:  MMB_AGENT_ID=<dest>-<pid>  (worker.sh:202)
# Qualquer valor diferente de "master" = worker → sai sem efeito.
if [ -n "${MMB_AGENT_ID:-}" ] && [ "$MMB_AGENT_ID" != "master" ]; then
  exit 0
fi

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
[ -f "$TOOLING_DIR/config.sh" ] && source "$TOOLING_DIR/config.sh" 2>/dev/null || true

STATE_DIR="${MMB_STATE_DIR:-$TOOLING_DIR/state}"
CURSOR_FILE="$STATE_DIR/digest-cursor-master.txt"
CURSOR_LOCK="$STATE_DIR/.digest-cursor.lock"
MAX_ENTRIES="${MMB_DIGEST_MAX_ENTRIES:-10}"

[ -d "$STATE_DIR" ] || exit 0

# Cursor default: epoch. Primeira execução vê tudo histórico
# (limitado a MAX_ENTRIES).
CURSOR="1970-01-01T00:00:00Z"
if [ -f "$CURSOR_FILE" ]; then
  CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null || echo "$CURSOR")
fi

# Lista digest files em ordem cronológica. Glob falha silenciosa se
# nenhum existir.
shopt -s nullglob
DIGESTS=("$STATE_DIR"/digest-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md)
shopt -u nullglob
[ ${#DIGESTS[@]} -eq 0 ] && exit 0

# Filtra digests cuja data >= dia do cursor (otimização — evita ler
# meses de histórico). Comparação lexicográfica funciona com YYYY-MM-DD.
CURSOR_DAY="${CURSOR:0:10}"
RELEVANT=()
for d in "${DIGESTS[@]}"; do
  bn=$(basename "$d")
  day="${bn:7:10}"  # digest-YYYY-MM-DD.md
  if [[ "$day" > "$CURSOR_DAY" || "$day" == "$CURSOR_DAY" ]]; then
    RELEVANT+=("$d")
  fi
done
[ ${#RELEVANT[@]} -eq 0 ] && exit 0

# Whitelist de subjects (regex bash). Tudo fora não injeta.
SUBJECT_OK_RE='^(issue-criada-[0-9]+|pr-aberto-[0-9]+|task-fechada(-[A-Za-z0-9._-]+)?)$'

# ── Parse das entries ────────────────────────────────────────────
#
# Formato canônico de entry no digest (gerado por append-digest.sh):
#
#   ## HH:MM:SS · <from> · <type>:<subject> · thread=<slug>
#   <glyph> <ação curta>
#   <linha vazia>
#
# Lê linha-a-linha. Acumula state machine.

NEW_ENTRIES_TS=()
NEW_ENTRIES_LINE=()
LAST_CONSIDERED_TS="$CURSOR"

parse_digest() {
  local file="$1"
  local bn day
  bn=$(basename "$file")
  day="${bn:7:10}"

  local in_header=0 header_line=""
  local time from type subject thread glyph action ts
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\ ·\ ([a-z]+)\ ·\ ([a-z]+):([^ ]+)\ ·\ thread=(.+)$ ]]; then
      time="${BASH_REMATCH[1]}"
      from="${BASH_REMATCH[2]}"
      type="${BASH_REMATCH[3]}"
      subject="${BASH_REMATCH[4]}"
      thread="${BASH_REMATCH[5]}"
      in_header=1
      header_line="$line"
      continue
    fi
    if [ "$in_header" = "1" ] && [[ "$line" =~ ^(✓|⚠|\+|!)\ (.+)$ ]]; then
      glyph="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[2]}"
      in_header=0

      ts="${day}T${time}Z"

      # Avança "last considered" sempre que processamos entry no range
      # válido — mesmo as descartadas. Isso impede re-leitura no
      # próximo turn.
      if [[ "$ts" > "$CURSOR" ]]; then
        if [[ "$ts" > "$LAST_CONSIDERED_TS" ]]; then
          LAST_CONSIDERED_TS="$ts"
        fi

        # Filtro: só rotina (✓), só status, só whitelist de subjects.
        if [ "$glyph" = "✓" ] && [ "$type" = "status" ] \
           && [[ "$subject" =~ $SUBJECT_OK_RE ]]; then
          # Formato de uma linha: ts curto + repo + subject + thread + ação
          NEW_ENTRIES_TS+=("$ts")
          NEW_ENTRIES_LINE+=("- ${time}Z ${from} ${subject} (${thread}) — ${action}")
        fi
      fi
    fi
  done < "$file"
}

for d in "${RELEVANT[@]}"; do
  parse_digest "$d"
done

TOTAL=${#NEW_ENTRIES_LINE[@]}
[ "$TOTAL" -eq 0 ] && exit 0

# Limita a MAX_ENTRIES (mostra os últimos N — mais recentes).
SKIPPED=0
START_IDX=0
if [ "$TOTAL" -gt "$MAX_ENTRIES" ]; then
  SKIPPED=$((TOTAL - MAX_ENTRIES))
  START_IDX=$SKIPPED
fi

# ── Output ───────────────────────────────────────────────────────

{
  if [ "$SKIPPED" -gt 0 ]; then
    printf '<mestre-digest novos="%d" mostrando="últimos %d" desde="%s">\n' \
      "$TOTAL" "$MAX_ENTRIES" "$CURSOR"
  else
    printf '<mestre-digest novos="%d" desde="%s">\n' "$TOTAL" "$CURSOR"
  fi
  for ((i=START_IDX; i<TOTAL; i++)); do
    printf '%s\n' "${NEW_ENTRIES_LINE[i]}"
  done
  if [ "$SKIPPED" -gt 0 ]; then
    printf '[+%d marcos anteriores omitidos — ver %s]\n' \
      "$SKIPPED" "$STATE_DIR/digest-*.md"
  fi
  printf '</mestre-digest>\n'
}

# Avança cursor pro último considerado (não só injetado). Locked.
mkdir -p "$STATE_DIR" 2>/dev/null
(
  flock --timeout 5 9 || exit 0
  echo "$LAST_CONSIDERED_TS" > "$CURSOR_FILE.tmp" 2>/dev/null
  mv "$CURSOR_FILE.tmp" "$CURSOR_FILE" 2>/dev/null || true
) 9>>"$CURSOR_LOCK"

exit 0
