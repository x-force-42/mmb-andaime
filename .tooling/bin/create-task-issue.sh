#!/usr/bin/env bash
# Cria sub-issue no GitHub com âncora mmb-cycle-key embutida.
#
# Wrapper de `gh issue create` que torna a relação briefing → issue
# determinística. Sem este wrapper (ou seu equivalente), o reconciler
# precisa cair em heurística pra casar issue com briefing, e o método
# regride pra "inferência 2.0". Spec da âncora em
# .tooling/source-of-truth.md.
#
# Uso:
#   create-task-issue.sh <repo> <briefing-file> [--title <título>]
#
#   <repo>           mmb-<id> de target registrado em .tooling/targets.json
#   <briefing-file>  caminho pro arquivo de inbox com frontmatter
#                    (.tooling/inbox/<short>/.../<ts>_master_briefing_<subject>.md)
#   --title          override do título da issue. Default: subject do
#                    briefing.
#
# Saída:
#   stdout: número da issue criada (ex: "42")
#   stderr: URL da issue + diagnósticos
#   exit 0: sucesso
#   exit 2: argumentos / frontmatter inválido
#   exit 3: falha do gh issue create
#
# Frontmatter esperado no briefing-file:
#   from: master
#   to: <id> de target registrado
#   type: briefing
#   subject: <kebab-case>
#   thread: <epic-slug>
#   created: <ISO8601>

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/lib/targets.sh"
mmb_targets_load || {
  echo "ERRO: registry de targets inválido. Abortando create-task-issue." >&2
  exit 2
}

# ── Args ──────────────────────────────────────────────────────────

REPO=""
BRIEFING=""
TITLE_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      TITLE_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO="$1"
      elif [ -z "$BRIEFING" ]; then
        BRIEFING="$1"
      else
        echo "ERRO: argumento posicional excedente: '$1'" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$BRIEFING" ]; then
  echo "Uso: $0 <repo> <briefing-file> [--title <título>]" >&2
  exit 2
fi

REPO_SHORT="${REPO#mmb-}"
if ! mmb_target_exists "$REPO_SHORT" || [ "$(mmb_target_repo "$REPO_SHORT")" != "$REPO" ]; then
  _VALID=$(mmb_targets_list | tr ' ' '\n' | sed 's/^/mmb-/' | tr '\n' '|' | sed 's/|$//')
  echo "ERRO: repo inválido '$REPO' (use $_VALID)" >&2
  exit 2
fi

if [ ! -f "$BRIEFING" ]; then
  echo "ERRO: briefing-file não existe: $BRIEFING" >&2
  exit 2
fi

# ── Parse frontmatter ─────────────────────────────────────────────
# Extrai pares "key: value" entre o primeiro e o segundo "---".
# Frontmatter inválido (sem --- de abertura/fechamento) = exit 2.

if ! head -1 "$BRIEFING" | grep -qE '^---[[:space:]]*$'; then
  echo "ERRO: briefing-file não começa com '---' (frontmatter ausente?)" >&2
  echo "       arquivo: $BRIEFING" >&2
  exit 2
fi

_fm() {
  awk -v key="$1" '
    /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
    count == 1 && $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*", "")
      print
      exit
    }
  ' "$BRIEFING"
}

FROM=$(_fm "from")
TO=$(_fm "to")
TYPE=$(_fm "type")
SUBJECT=$(_fm "subject")
THREAD=$(_fm "thread")
CREATED=$(_fm "created")

# ── Validações de frontmatter ─────────────────────────────────────

if [ "$FROM" != "master" ]; then
  echo "ERRO: briefing.from='$FROM', esperado 'master'." >&2
  echo "       Issues do método nascem de dispatch master→planner." >&2
  exit 2
fi

if [ "$TYPE" != "briefing" ]; then
  echo "ERRO: briefing.type='$TYPE', esperado 'briefing'." >&2
  exit 2
fi

if [ "$TO" != "$REPO_SHORT" ]; then
  echo "ERRO: briefing.to='$TO' mas repo='$REPO' (short='$REPO_SHORT')." >&2
  echo "       Briefing endereçado a outro projeto. Confira o dispatch do master." >&2
  exit 2
fi

if [ -z "$THREAD" ]; then
  echo "ERRO: briefing sem 'thread' no frontmatter. Sem épico, sem âncora." >&2
  echo "       Master deve sempre incluir thread em briefings (source-of-truth.md)." >&2
  exit 2
fi

if [ -z "$CREATED" ]; then
  echo "ERRO: briefing sem 'created' no frontmatter. Âncora exige timestamp determinístico." >&2
  exit 2
fi

if [ -z "$SUBJECT" ]; then
  echo "ERRO: briefing sem 'subject' no frontmatter." >&2
  exit 2
fi

# ── Constrói âncora + body ────────────────────────────────────────

BASENAME=$(basename "$BRIEFING")
CYCLE_KEY="${THREAD}/${REPO_SHORT}/${CREATED}"

# Extrai body do briefing (tudo após o segundo "---")
BRIEFING_BODY=$(awk '
  /^---[[:space:]]*$/ { count++; if (count == 2) { body = 1; next } }
  body { print }
' "$BRIEFING")

# Title: --title override, else subject
TITLE="${TITLE_OVERRIDE:-$SUBJECT}"

# Labels obrigatórias (per source-of-truth.md)
LABELS="task,project:${REPO},epic:${THREAD}"

# Body final = âncora + linha em branco + briefing body
TMP_BODY=$(mktemp -t mmb-issue-body.XXXXXX.md)
trap 'rm -f "$TMP_BODY"' EXIT

{
  printf '<!-- mmb-cycle-key: %s\n' "$CYCLE_KEY"
  printf '     mmb-briefing-file: %s -->\n' "$BASENAME"
  printf '\n'
  printf '%s\n' "$BRIEFING_BODY"
} > "$TMP_BODY"

# ── gh issue create ───────────────────────────────────────────────

# Owner GH per-target (PR 2B). Vem do registry; fallback para
# MMB_GH_OWNER global se entry com owner vazio.
TARGET_OWNER=$(mmb_target_owner "$REPO_SHORT")
GH_FULL="$TARGET_OWNER/$REPO"

echo "→ Criando issue em $GH_FULL" >&2
echo "  title:      $TITLE" >&2
echo "  labels:     $LABELS" >&2
echo "  cycle-key:  $CYCLE_KEY" >&2

if ! ISSUE_URL=$(gh issue create \
    --repo "$GH_FULL" \
    --title "$TITLE" \
    --label "$LABELS" \
    --body-file "$TMP_BODY" 2>&1); then
  echo "ERRO: gh issue create falhou:" >&2
  printf '%s\n' "$ISSUE_URL" >&2
  exit 3
fi

# Extrai número da URL (https://github.com/.../issues/N)
ISSUE_NUMBER=$(printf '%s' "$ISSUE_URL" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' | tail -1)

if [ -z "$ISSUE_NUMBER" ]; then
  echo "AVISO: não consegui extrair número da URL: $ISSUE_URL" >&2
  echo "       Issue foi criada mas o caller não tem o número." >&2
  exit 3
fi

echo "✓ Issue #$ISSUE_NUMBER criada: $ISSUE_URL" >&2

# stdout = só o número (pra pipe / captura)
printf '%s\n' "$ISSUE_NUMBER"
