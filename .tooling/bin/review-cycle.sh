#!/usr/bin/env bash
# Agregador do diário de bordo pro Orq Mestre ao fechar épico (v0.2).
#
# Lê .tooling/logs/journal.jsonl, filtra por epic, lista eventos
# error/critical SEM resolved correspondente, e propõe ações
# heurísticas. NÃO cria briefings, NÃO dispara nada. Saída
# apresentada pro Rick decidir.
#
# Uso:
#   review-cycle.sh <epic-slug>
#
# Saída:
#   - Tabela de erros não resolvidos no épico.
#   - Estatísticas: total de eventos, errors, critical, resolved.
#   - Sugestões heurísticas (eventos repetidos viram candidatos
#     a guardrail/refactor).

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

# Path do journal (env override pra testes; default = produção).
JOURNAL="${MMB_JOURNAL_PATH:-$TOOLING_DIR/logs/journal.jsonl}"

EPIC="${1:-}"
if [ -z "$EPIC" ]; then
  echo "Uso: $0 <epic-slug>" >&2
  exit 2
fi

if [ ! -f "$JOURNAL" ] || [ ! -s "$JOURNAL" ]; then
  echo "Journal vazio ou inexistente em $JOURNAL"
  exit 0
fi

# ── Extrai campos via grep/sed (POSIX, sem dep externa) ──────────

_field() {
  local line="$1" field="$2"
  printf '%s' "$line" \
    | grep -oE "\"${field}\":\"[^\"]*\"" \
    | head -1 \
    | sed -E "s/.*\"${field}\":\"([^\"]*)\".*/\1/" || true
}

# Filtra linhas do épico
EPIC_LINES=$(grep "\"epic\":\"$EPIC\"" "$JOURNAL" || true)

if [ -z "$EPIC_LINES" ]; then
  echo "Nenhum evento registrado pro épico '$EPIC'."
  exit 0
fi

# Identifica IDs resolvidos.
# grep sem match retorna 1 — sob `set -o pipefail` isso mata o script
# silenciosamente. Neutraliza no meio do pipe (mesmo padrão de
# _grep_count abaixo). Sed/sort lidam com input vazio sem reclamar.
RESOLVED_IDS=$(printf '%s\n' "$EPIC_LINES" \
  | { grep -oE '"resolves":"[^"]+"' || true; } \
  | sed -E 's/.*"resolves":"([^"]+)".*/\1/' \
  | sort -u)

# Errors / critical não-resolvidos
UNRESOLVED=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  sev=$(_field "$line" "sev")
  case "$sev" in
    error|critical) ;;
    *) continue ;;
  esac
  id=$(_field "$line" "id")
  if echo "$RESOLVED_IDS" | grep -qx "$id"; then
    continue
  fi
  UNRESOLVED+="$line"$'\n'
done <<< "$EPIC_LINES"

# ── Saída ─────────────────────────────────────────────────────────

# Conta linhas que casam um padrão. Neutraliza exit 1 de grep
# sem match antes que `set -o pipefail` mate o pipeline.
_grep_count() {
  local pattern="$1"
  local input="$2"
  printf '%s' "$input" | { grep -E "$pattern" || true; } | wc -l | tr -d ' '
}

TOTAL=$(_grep_count '.' "$EPIC_LINES")
N_ERR=$(_grep_count '"sev":"error"' "$EPIC_LINES")
N_CRIT=$(_grep_count '"sev":"critical"' "$EPIC_LINES")
N_RESOLVED=$(_grep_count '"resolves":' "$EPIC_LINES")
N_UNRESOLVED=$(_grep_count '.' "$UNRESOLVED")

echo "═══════════════════════════════════════════════════════════════"
echo "  Review-cycle: épico '$EPIC'"
echo "═══════════════════════════════════════════════════════════════"
echo
echo "Estatísticas:"
echo "  total de eventos:    $TOTAL"
echo "  errors:              $N_ERR"
echo "  critical:            $N_CRIT"
echo "  resolved (eventos):  $N_RESOLVED"
echo "  não resolvidos:      $N_UNRESOLVED"
echo

if [ "$N_UNRESOLVED" -eq 0 ]; then
  echo "✓ Nenhum erro pendente. Épico fechou limpo."
  exit 0
fi

echo "── Eventos não resolvidos ──────────────────────────────────"
echo
printf '%-22s %-8s %-12s %-20s %s\n' "TS (UTC)" "SEV" "AGENT" "EVENT" "ID"
printf '%s\n' "$(printf -- '-%.0s' {1..90})"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ts=$(_field "$line" "ts")
  sev=$(_field "$line" "sev")
  agent=$(_field "$line" "agent")
  event=$(_field "$line" "event")
  id=$(_field "$line" "id")
  msg=$(_field "$line" "msg")
  printf '%-22s %-8s %-12s %-20s %s\n' "$ts" "$sev" "$agent" "$event" "$id"
  printf '  msg: %s\n' "$msg"
done <<< "$UNRESOLVED"
echo

# ── Heurísticas de sugestão ───────────────────────────────────────

echo "── Sugestões heurísticas (não automáticas) ─────────────────"
echo

# 1) Eventos repetidos cross-épico (potencial guardrail)
echo "[1] Eventos repetidos NO HISTÓRICO INTEIRO do journal:"
# grep neutralizado: journal pode (raríssimo) não ter `"event":`
REPEATED=$({ grep -oE '"event":"[^"]+"' "$JOURNAL" || true; } \
  | sed -E 's/.*"event":"([^"]+)".*/\1/' \
  | sort | uniq -c | sort -rn \
  | awk '$1 >= 2 { printf "    %d×  %s\n", $1, $2 }')
if [ -n "$REPEATED" ]; then
  echo "$REPEATED"
  echo "    → considerar virar guardrail explícito em guardrails.md"
else
  echo "    (nenhum evento repetido — primeiro encontro com cada)"
fi
echo

# 2) Eventos só deste épico
echo "[2] Eventos únicos deste épico (potencial bug local):"
LOCAL_EVENTS=$(printf '%s\n' "$UNRESOLVED" \
  | { grep -oE '"event":"[^"]+"' || true; } \
  | sed -E 's/.*"event":"([^"]+)".*/\1/' \
  | sort -u)
if [ -n "$LOCAL_EVENTS" ]; then
  printf '%s\n' "$LOCAL_EVENTS" | sed 's/^/    - /'
else
  echo "    (sem eventos únicos)"
fi
echo

echo "── Próximos passos sugeridos ───────────────────────────────"
echo
echo "  • Apresentar este relatório pro Rick."
echo "  • Pra CADA evento não resolvido, decidir: ignorar, virar"
echo "    guardrail, virar épico de fortificação, ou retroativamente"
echo "    marcar como resolvido (log.sh info <event> ... --resolves <id>)."
echo "  • NUNCA auto-gerar briefings a partir daqui. Consentimento"
echo "    explícito do Rick é a regra (anti-overengineering)."
