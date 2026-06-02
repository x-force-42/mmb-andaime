#!/usr/bin/env bash
# Abre PR no remoto (chamado pelo Agente Atômico ao terminar).
#
# Uso (rode de DENTRO da worktree):
#   .tooling/bin/open-pr.sh [--draft]
#
# Comportamento:
#   1. Valida invariantes (branch task/, working tree limpa, ao
#      menos 1 commit à frente do default branch).
#   2. git push origin HEAD.
#   3. gh pr create com:
#      - título derivado do último commit (Conventional Commits)
#      - body do template pr-body.md preenchido
#      - Closes #<sub-issue> se encontrar referência no body dos
#        commits ou no env GH_SUBISSUE.
#   4. Comenta na sub-issue avisando do PR.

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"
# shellcheck disable=SC1091
source "$TOOLING_DIR/bin/lib/pr-body.sh"

DRAFT_FLAG=""
if [ "${1:-}" = "--draft" ]; then
  DRAFT_FLAG="--draft"
fi

# ── Pré-flight de GH_SUBISSUE (antes do push) ─────────────────────
# Validar AGORA, não depois do push: PR sem Closes #N quebra o casamento
# PR↔issue no reconcile do mmb-logger, fazendo ciclos completos aparecerem
# como abortados. Falha antes do push deixa a árvore git intocada;
# falha depois deixa branch publicada sem PR.
#
# Caminho feliz: spawn-atomic.sh exporta GH_SUBISSUE quando spawna o atômico.
# Manual: rode com `GH_SUBISSUE=42 .tooling/bin/open-pr.sh`.

SUBISSUE="${GH_SUBISSUE:-}"
if ! mmb_validate_subissue_format "$SUBISSUE"; then
  cat >&2 <<EOF
ERRO: GH_SUBISSUE ausente ou inválido: '${SUBISSUE}'

  GH_SUBISSUE precisa ser o número da sub-issue (inteiro positivo).
  Caminho feliz: spawn-atomic.sh exporta GH_SUBISSUE automaticamente
  ao spawnar o atômico.

  Se você está rodando open-pr.sh manualmente:
    GH_SUBISSUE=<número-da-issue> $0 $*

  Por que falhamos antes do push: PR sem 'Closes #N' impede que o
  mmb-logger case PR↔issue, e ciclos concluídos aparecem como
  abortados no cockpit. Fonte do gap em .tooling/source-of-truth.md.
EOF
  exit 2
fi

# ── Pré-flight de MMB_SUITE_OUTPUT (guardrail A11) ────────────────
# Atômico precisa rodar a suíte de testes antes de abrir PR e passar
# o output literal via env var. Sem isso, a revisão fica refém da
# memória do atômico — bug do ux-refresh-v07 onde 3 PRs vieram sem
# evidência de testes no body apesar do Rick ter pedido explicitamente.
#
# Caminho feliz (atômico):
#   npm test 2>&1 | tee /tmp/suite.txt
#   [ "${PIPESTATUS[0]}" -eq 0 ] || { echo vermelho; exit 1; }
#   MMB_SUITE_OUTPUT=/tmp/suite.txt /MMB/.tooling/bin/open-pr.sh

SUITE_OUTPUT="${MMB_SUITE_OUTPUT:-}"
mmb_validate_suite_output "$SUITE_OUTPUT" && _suite_rc=0 || _suite_rc=$?
if [ "$_suite_rc" -ne 0 ]; then
  rc="$_suite_rc"
  case "$rc" in
    1) reason="MMB_SUITE_OUTPUT não setada (env var ausente ou vazia)" ;;
    2) reason="MMB_SUITE_OUTPUT='${SUITE_OUTPUT}' aponta pra arquivo que não existe" ;;
    3) reason="MMB_SUITE_OUTPUT='${SUITE_OUTPUT}' aponta pra arquivo vazio" ;;
    4) reason="MMB_SUITE_OUTPUT='${SUITE_OUTPUT}' tem menos de ${MMB_SUITE_MIN_BYTES:-100} bytes (suspeita de gaming)" ;;
    *) reason="MMB_SUITE_OUTPUT inválida (código $rc)" ;;
  esac
  cat >&2 <<EOF
ERRO: $reason

  Guardrail A11 — atômico abre PR com suíte verde no body.

  Antes de open-pr.sh, rode a suíte de testes do repo, capture o
  output, e exporte:

    # Pytest (logger):
    .venv/bin/pytest 2>&1 | tee /tmp/suite.txt
    [ "\${PIPESTATUS[0]}" -eq 0 ] || { echo "Suíte vermelha"; exit 1; }
    MMB_SUITE_OUTPUT=/tmp/suite.txt $0 $*

    # Vitest (cockpit / aquarium):
    npm test 2>&1 | tee /tmp/suite.txt
    [ "\${PIPESTATUS[0]}" -eq 0 ] || { echo "Suíte vermelha"; exit 1; }
    MMB_SUITE_OUTPUT=/tmp/suite.txt $0 $*

  Se a suíte falha: conserte ou marque xfail/skip explicitamente.
  Não tente abrir PR com suíte vermelha — revisão é bloqueada.

  Override pra script-de-dev local (NÃO usar em atômico):
    MMB_SUITE_MIN_BYTES=10 MMB_SUITE_OUTPUT=/tmp/x $0 ...
EOF
  exit 3
fi

TOPLEVEL=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
WORKTREE_NAME=$(basename "$TOPLEVEL")

# Invariantes
case "$BRANCH" in
  task/*) ;;
  *)
    echo "ERRO: branch atual ($BRANCH) não é task/<id>-<slug>."
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "ERRO: working tree suja. Commit ou stash antes de abrir PR."
  git status --short
  exit 1
fi

DEFAULT_BRANCH=$(mmb_default_branch)
echo "→ default branch: $DEFAULT_BRANCH"

AHEAD=$(git rev-list --count "$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo 0)
if [ "$AHEAD" -lt 1 ]; then
  echo "ERRO: branch sem commits à frente de $DEFAULT_BRANCH. Nada pra PR."
  exit 1
fi

# Push
echo "→ git push origin $BRANCH..."
git push -u origin "$BRANCH"

# Descobre repo no GitHub
REMOTE_URL=$(git config --get remote.origin.url)
# git@github.com:x-force-42/mmb-core.git → x-force-42/mmb-core
GH_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+)\.git$|\1|')

# Título do PR: último commit não-merge na branch
PR_TITLE=$(git log "$DEFAULT_BRANCH..HEAD" --no-merges --pretty=format:'%s' | tail -1)
if [ -z "$PR_TITLE" ]; then
  PR_TITLE=$(git log -1 --pretty=format:'%s')
fi

# Body — construído via lib pra testabilidade. SUBISSUE e SUITE_OUTPUT
# já validadas no pré-flight acima.
TMP_BODY=$(mktemp)
COMMITS_LIST=$(git log "$DEFAULT_BRANCH..HEAD" --no-merges --pretty=format:'- %s')
mmb_build_pr_body "$SUBISSUE" "$COMMITS_LIST" "$WORKTREE_NAME" "$SUITE_OUTPUT" > "$TMP_BODY"

# Idempotência (H1): se já existe PR pra esta branch (reprocesso /
# re-run após crash), reusa o existente em vez de chamar gh pr create —
# que erraria com "a pull request already exists". Best-effort: se o
# list falhar, cai pro create. `gh --jq` usa o jq embutido no gh (sem
# dependência externa).
EXISTING_PR=$(gh pr list --repo "$GH_REPO" --head "$BRANCH" --state all \
  --json url --jq '.[0].url // empty' 2>/dev/null || true)

if [ -n "$EXISTING_PR" ]; then
  PR_URL="$EXISTING_PR"
  echo "↺ PR já existe pra branch $BRANCH: $PR_URL"
  echo "  (idempotente — pulando gh pr create)"
else
  echo "→ gh pr create (base: $DEFAULT_BRANCH)..."
  PR_URL=$(gh pr create \
    --repo "$GH_REPO" \
    --title "$PR_TITLE" \
    --body-file "$TMP_BODY" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH" \
    $DRAFT_FLAG)
fi

rm -f "$TMP_BODY"

echo "✓ PR aberto: $PR_URL"

# Extrai número do PR da URL (https://github.com/org/repo/pull/N)
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || true)

# Notifica master via inbox — alimenta o logger (R3: pr-aberto → ciclo pr_aberto).
# Usa --allow-offline porque open-pr.sh roda no pane do atômico e o commd
# pode não estar visível neste contexto; a mensagem fica pendente e é
# drenada quando o daemon subir.
#
# B1.2 (v0.10+): chamada via wrapper `send-status-pr-opened.sh` em vez
# de `msg.sh` direto. Wrapper monta body com schema v0.4+ obrigatório
# (pr_url, pr_number, issue_number, suite_status) e auto-detecta
# suite_status via `gh pr view`. Antes, open-pr.sh emitia status com
# corpo "PR aberto: <URL>" sem schema, causando escala do worker-master
# (B1 reincidente — falsos positivos em pending-human).
if [ -n "$PR_NUMBER" ] && [ -n "${MMB_GH_OWNER:-}" ]; then
  THREAD="${EPIC_SLUG:-${MMB_AGENT_ID:-}}"
  if [ -n "$THREAD" ]; then
    # Deriva repo-short do GH_REPO ("x-force-42/mmb-cockpit" → "cockpit").
    REPO_FULL="${GH_REPO##*/}"
    REPO_SHORT="${REPO_FULL#mmb-}"

    MMB_TAB="${MMB_TAB:-atomic}" MMB_ALLOW_OFFLINE_ENQUEUE=1 \
      "$TOOLING_DIR/bin/send-status-pr-opened.sh" \
        "$REPO_SHORT" "$PR_NUMBER" "$SUBISSUE" "$THREAD" 2>/dev/null \
      && echo "✓ Status pr-aberto-${PR_NUMBER} enviado ao master (via wrapper)" \
      || echo "  (send-status-pr-opened.sh falhou; logger não vai registrar pr_aberto)"
  fi
fi

# Comenta na sub-issue se conhecida
if [ -n "$SUBISSUE" ]; then
  gh issue comment "$SUBISSUE" \
    --repo "$GH_REPO" \
    --body "PR aberto: $PR_URL" 2>/dev/null \
    && echo "✓ Comentário postado na sub-issue #$SUBISSUE" \
    || echo "  (falhou comentar na sub-issue; siga sem isso)"
fi

echo
echo "Agente Atômico terminou."

# Deregistra no agent registry (v0.1). MMB_AGENT_ID é setado pelo
# spawn-atomic.sh; se ausente, segue sem deregister.
if [ -n "${MMB_AGENT_ID:-}" ]; then
  "$TOOLING_DIR/bin/agents.sh" deregister "$MMB_AGENT_ID" "pr-opened" || true
fi

# Auto-fechamento do pane: usa MMB_PANE_ID (injetado pelo spawn-atomic.sh)
# em vez de `tmux display-message`, que retorna o pane FOCADO pelo client
# e pode matar a sessão do master se o usuário estiver com ela em foco.
if [ -n "${TMUX:-}" ]; then
  PANE_ID="${MMB_PANE_ID:-}"
  if [ -n "$PANE_ID" ]; then
    echo "Pane $PANE_ID vai fechar em 8s (Ctrl-C pra cancelar)."
    ( sleep 8 && tmux kill-pane -t "$PANE_ID" ) &
  fi
fi
