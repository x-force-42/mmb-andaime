#!/usr/bin/env bash
# Reset total do andaime MMB — limpa estado em-voo nos 3 repos e na mensageria.
#
# Uso:
#   reset-all.sh [--dry-run] [--yes] [--no-archive] [--kill-claudes]
#
# Flags:
#   --dry-run        Mostra o que faria sem executar.
#   --yes            Pula confirmação interativa.
#   --no-archive     Deleta direto sem arquivar em .tooling/archive/<ts>/.
#   --kill-claudes   Envia C-c + /exit pros panes core/cockpit/aquarium da
#                    sessão tmux 'mmb' antes de começar (não toca master).
#
# Fases:
#   0.  (opcional) Encerra Claudes paralelos da sessão mmb.
#   0.5 Para commd daemon (sempre).
#   1.  Snapshot read-only do estado atual em .tooling/archive/<ts>/.
#   2.  Fecha PRs e issues abertos nos 3 repos (gh).
#   3.  Remove worktrees + deleta branches task/* (local e remoto).
#   4.  git reset --hard origin/main + remove .worktrees/ órfãos.
#   5.  Archive (ou delete) inbox/intents/state/journal/logs da mensageria.
#   6.  Verificação final.
#
# Idempotente: pode rodar quantas vezes quiser; só age sobre o que existe.

set -euo pipefail

MMB_ROOT="${MMB_ROOT:-/home/eliezer/llab/MMB}"
REPOS=(mmb-core mmb-cockpit mmb-aquarium)
GH_OWNER="${MMB_GH_OWNER:-x-force-42}"

DRY_RUN=0
ASSUME_YES=0
NO_ARCHIVE=0
KILL_CLAUDES=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --yes)          ASSUME_YES=1 ;;
    --no-archive)   NO_ARCHIVE=1 ;;
    --kill-claudes) KILL_CLAUDES=1 ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $arg" >&2; exit 2 ;;
  esac
done

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
ARCHIVE="$MMB_ROOT/.tooling/archive/$TS"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    eval "$@"
  fi
}

say()  { printf '\n=== %s ===\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  printf '\nProsseguir com reset total? [y/N] '
  read -r ans
  [[ "$ans" =~ ^[yY]$ ]] || { echo "abortado."; exit 1; }
}

# ── Fase 0.5 — parar commd ──────────────────────────────────────────────
phase_stop_commd() {
  say "Fase 0.5: parar commd"
  local pid_file="$MMB_ROOT/.tooling/state/commd.pid"
  if [ ! -f "$pid_file" ]; then
    echo "  commd não está rodando (sem pid file)"
    return
  fi
  local pid
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    echo "  → matando commd pid=$pid"
    run "kill '$pid'"
    run "rm -f '$pid_file'"
  else
    echo "  commd pid=$pid já morto — limpando pid file"
    run "rm -f '$pid_file'"
  fi
}

# ── Fase 0 — kill paralelos ─────────────────────────────────────────────
phase_kill_claudes() {
  say "Fase 0: encerrar Claudes paralelos da sessão mmb"
  if ! tmux has-session -t mmb 2>/dev/null; then
    echo "  sessão tmux 'mmb' não existe — pulando."
    return
  fi
  local my_pane="${TMUX_PANE:-}"
  for win in core cockpit aquarium; do
    local pane
    pane=$(tmux list-panes -t "mmb:$win" -F "#{pane_id}" 2>/dev/null | head -1 || true)
    [ -z "$pane" ] && continue
    [ "$pane" = "$my_pane" ] && { warn "skip own pane $pane"; continue; }
    echo "  → $win ($pane): C-c + /exit"
    if [ "$DRY_RUN" -eq 0 ]; then
      tmux send-keys -t "$pane" C-c
      sleep 0.3
      tmux send-keys -t "$pane" C-c
      sleep 0.3
      tmux send-keys -t "$pane" "/exit" Enter
    fi
  done
  [ "$DRY_RUN" -eq 0 ] && sleep 4
}

# ── Fase 1 — inventário ─────────────────────────────────────────────────
phase_inventory() {
  say "Fase 1: snapshot read-only → $ARCHIVE"
  run "mkdir -p '$ARCHIVE'"
  local inv="$ARCHIVE/pre-reset-inventory.md"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] write $inv"
    return
  fi
  {
    echo "# Pre-reset inventory — $TS"
    echo
    for repo in "${REPOS[@]}"; do
      echo "## $repo"
      echo
      echo "### PRs abertos"; echo '```'
      gh pr list --repo "$GH_OWNER/$repo" --state open --json number,title,headRefName 2>&1 || true
      echo '```'; echo
      echo "### Issues abertas"; echo '```'
      gh issue list --repo "$GH_OWNER/$repo" --state open --json number,title 2>&1 || true
      echo '```'; echo
      echo "### Worktrees"; echo '```'
      git -C "$MMB_ROOT/$repo" worktree list 2>&1 || true
      echo '```'; echo
      echo "### Branches locais"; echo '```'
      git -C "$MMB_ROOT/$repo" branch -vv 2>&1 || true
      echo '```'; echo
      echo "### Branches remotas task/*"; echo '```'
      git -C "$MMB_ROOT/$repo" branch -r 2>&1 | grep -E 'task/' || echo "(nenhuma)"
      echo '```'; echo
    done
  } > "$inv"
  echo "  → $inv ($(wc -l < "$inv") linhas)"
}

# ── Fase 2 — gh close (paralelo) ────────────────────────────────────────
phase_github_close() {
  say "Fase 2: fechar PRs e issues abertos"
  local cmt="cleanup/reset do andaime — $TS"
  local pids=()
  for repo in "${REPOS[@]}"; do
    local full="$GH_OWNER/$repo"
    local prs issues
    prs=$(gh pr list --repo "$full" --state open --json number -q '.[].number' 2>/dev/null || echo "")
    issues=$(gh issue list --repo "$full" --state open --json number -q '.[].number' 2>/dev/null || echo "")
    for n in $prs; do
      echo "  $full PR #$n"
      if [ "$DRY_RUN" -eq 0 ]; then
        gh pr close "$n" --repo "$full" --comment "$cmt" &
        pids+=($!)
      fi
    done
    for n in $issues; do
      echo "  $full issue #$n"
      if [ "$DRY_RUN" -eq 0 ]; then
        gh issue close "$n" --repo "$full" --comment "$cmt" &
        pids+=($!)
      fi
    done
  done
  [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}"
}

# ── Fase 3 — worktrees + branches ───────────────────────────────────────
phase_worktrees_branches() {
  say "Fase 3: worktrees e branches task/*"
  for repo in "${REPOS[@]}"; do
    local r="$MMB_ROOT/$repo"
    echo "  >> $repo"
    # Remove worktrees não-principais
    local wts
    wts=$(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -v "^$r$" || true)
    for wt in $wts; do
      echo "    worktree remove $wt"
      run "git -C '$r' worktree remove --force '$wt'"
    done
    run "git -C '$r' worktree prune"
    # Branches locais task/*
    local local_brs
    local_brs=$(git -C "$r" branch --format '%(refname:short)' 2>/dev/null | grep -E '^task/' || true)
    for br in $local_brs; do
      echo "    branch -D $br"
      run "git -C '$r' branch -D '$br'"
    done
    # Branches remotos task/*
    local remote_brs
    remote_brs=$(git -C "$r" branch -r --format '%(refname:short)' 2>/dev/null | grep -E '^origin/task/' | sed 's#^origin/##' || true)
    for br in $remote_brs; do
      echo "    push --delete $br"
      run "git -C '$r' push origin --delete '$br' || true"
    done
  done
}

# ── Fase 4 — reset main ─────────────────────────────────────────────────
phase_reset_main() {
  say "Fase 4: reset --hard origin/main + cleanup órfãos"
  for repo in "${REPOS[@]}"; do
    local r="$MMB_ROOT/$repo"
    echo "  >> $repo"
    run "git -C '$r' checkout main"
    run "git -C '$r' fetch origin"
    run "git -C '$r' reset --hard origin/main"
    if [ -d "$r/.worktrees" ]; then
      run "rm -rf '$r/.worktrees'"
    fi
    # Limpa task files não-rastreados (de atômicos que rodaram em main)
    run "git -C '$r' clean -fd docs/tasks/ 2>/dev/null || true"
  done
}

# ── Fase 5 — mensageria ─────────────────────────────────────────────────
phase_messaging() {
  say "Fase 5: archive + reset mensageria"
  local tooling="$MMB_ROOT/.tooling"

  if [ "$NO_ARCHIVE" -eq 0 ]; then
    run "mkdir -p '$ARCHIVE/inbox' '$ARCHIVE/intents' '$ARCHIVE/state' '$ARCHIVE/logs/workers'"
    for d in master core cockpit aquarium; do
      run "mkdir -p '$ARCHIVE/inbox/$d'"
      if [ "$DRY_RUN" -eq 0 ]; then
        find "$tooling/inbox/$d" -maxdepth 1 -name '*.md' \
          -exec mv {} "$ARCHIVE/inbox/$d/" \; 2>/dev/null || true
      else
        echo "  [dry-run] mv inbox/$d/*.md → archive"
      fi
      # Lifecycle subdirs (v0.3+): .processing/.done/.dead/. .dead/ é
      # postmortem — preservado no archive, sempre.
      for sub in .processing .done .dead; do
        run "mkdir -p '$ARCHIVE/inbox/$d/$sub'"
        if [ "$DRY_RUN" -eq 0 ]; then
          find "$tooling/inbox/$d/$sub" -maxdepth 1 -name '*.md' \
            -exec mv {} "$ARCHIVE/inbox/$d/$sub/" \; 2>/dev/null || true
        else
          echo "  [dry-run] mv inbox/$d/$sub/*.md → archive"
        fi
      done
    done
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -d "$tooling/intents" ] && find "$tooling/intents" -maxdepth 1 -mindepth 1 \
        -not -name '.gitkeep' -exec mv {} "$ARCHIVE/intents/" \; 2>/dev/null || true
      [ -f "$tooling/state/agents.jsonl" ] && cp -a "$tooling/state/agents.jsonl" "$ARCHIVE/state/" && : > "$tooling/state/agents.jsonl"
      [ -d "$tooling/state/heartbeats" ] && cp -a "$tooling/state/heartbeats" "$ARCHIVE/state/" 2>/dev/null || true
      [ -f "$tooling/logs/journal.jsonl" ] && cp -a "$tooling/logs/journal.jsonl" "$ARCHIVE/logs/" && : > "$tooling/logs/journal.jsonl"
      # Worker + daemon logs
      for f in "$tooling/logs/workers/"*.log; do
        [ -f "$f" ] || continue
        cp -a "$f" "$ARCHIVE/logs/workers/"
        : > "$f"
      done
      for logfile in commd.log aquario-bridge.log; do
        if [ -f "$tooling/logs/$logfile" ]; then
          cp -a "$tooling/logs/$logfile" "$ARCHIVE/logs/"
          : > "$tooling/logs/$logfile"
        fi
      done
    else
      echo "  [dry-run] mv intents/*, archive state/journal"
      echo "  [dry-run] archive + truncate logs/workers/*.log commd.log aquario-bridge.log"
    fi
  else
    # delete direto
    for d in master core cockpit aquarium; do
      run "find '$tooling/inbox/$d' -maxdepth 1 -name '*.md' -delete"
      for sub in .processing .done .dead; do
        run "find '$tooling/inbox/$d/$sub' -maxdepth 1 -name '*.md' -delete 2>/dev/null || true"
      done
    done
    run "find '$tooling/intents' -maxdepth 1 -mindepth 1 -not -name '.gitkeep' -exec rm -rf {} +"
    run ": > '$tooling/state/agents.jsonl'"
    run ": > '$tooling/logs/journal.jsonl'"
    run "find '$tooling/logs/workers' -name '*.log' -exec truncate -s0 {} +"
    for logfile in commd.log aquario-bridge.log; do
      run ": > '$tooling/logs/$logfile' 2>/dev/null || true"
    done
  fi
  # heartbeats sempre vão (são touch files temporários)
  run "find '$tooling/state/heartbeats' -maxdepth 1 -name '*.alive' -delete"
}

# ── Fase 6 — verificação ────────────────────────────────────────────────
phase_verify() {
  say "Fase 6: verificação"
  local ok=1
  for repo in "${REPOS[@]}"; do
    local r="$MMB_ROOT/$repo"
    local extra
    extra=$(git -C "$r" branch --format '%(refname:short)' | grep -v '^main$' || true)
    local wts
    wts=$(git -C "$r" worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$r$" || true)
    local dirty
    dirty=$(git -C "$r" status --porcelain || true)
    if [ -n "$extra$wts$dirty" ]; then
      ok=0
      echo "  ⚠ $repo: branches='$extra' worktrees='$wts' dirty='$dirty'"
    else
      echo "  ✓ $repo limpo"
    fi
  done
  for repo in "${REPOS[@]}"; do
    local prs issues
    prs=$(gh pr list --repo "$GH_OWNER/$repo" --state open --json number -q 'length' 2>/dev/null || echo "?")
    issues=$(gh issue list --repo "$GH_OWNER/$repo" --state open --json number -q 'length' 2>/dev/null || echo "?")
    if [ "$prs" != "0" ] || [ "$issues" != "0" ]; then
      ok=0
      echo "  ⚠ $repo GitHub: PRs=$prs issues=$issues"
    else
      echo "  ✓ $repo GitHub limpo"
    fi
  done
  for d in master core cockpit aquarium; do
    local n
    # Conta top-level + lifecycle subdirs (.processing/.done/.dead)
    n=$(find "$MMB_ROOT/.tooling/inbox/$d" -maxdepth 2 -name '*.md' 2>/dev/null | wc -l)
    [ "$n" -ne 0 ] && { ok=0; echo "  ⚠ inbox/$d: $n msg files"; } || echo "  ✓ inbox/$d limpo"
  done
  [ "$ok" -eq 1 ] && echo "  ✓ reset OK" || { echo "  ⚠ reset com pendências"; return 1; }
}

# ── main ────────────────────────────────────────────────────────────────
echo "MMB reset-all — $TS"
echo "  MMB_ROOT=$MMB_ROOT"
echo "  ARCHIVE=$ARCHIVE"
echo "  flags: dry-run=$DRY_RUN yes=$ASSUME_YES no-archive=$NO_ARCHIVE kill-claudes=$KILL_CLAUDES"
confirm

[ "$KILL_CLAUDES" -eq 1 ] && phase_kill_claudes
phase_stop_commd
phase_inventory
phase_github_close
phase_worktrees_branches
phase_reset_main
phase_messaging
phase_verify

echo
echo "✓ reset-all concluído. Archive: $ARCHIVE"
