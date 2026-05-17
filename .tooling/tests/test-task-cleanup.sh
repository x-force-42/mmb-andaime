#!/usr/bin/env bash
# Testes do helper `mmb_delete_orphan_task_file` em config.sh.
#
# Cobre os 3 cenários do lifecycle proposto (fix dos órfãos em
# docs/tasks/ pós-merge):
#
#   1. arquivo untracked → deletado.
#   2. arquivo tracked → preservado.
#   3. arquivo ausente → no-op (não falha).
#
# Plus:
#   4. arquivo vazio como arg → no-op (não falha).
#   5. invocação em repo git real (sandbox) — smoke do helper inteiro.

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

SANDBOX=$(mktemp -d /tmp/mmb-task-cleanup-test-XXXXXX)

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ── Setup: repo git fake com estrutura mínima ────────────────────

setup_repo() {
  local repo_path="$1"
  rm -rf "$repo_path"
  mkdir -p "$repo_path/docs/tasks"
  git -C "$repo_path" init -q -b main
  git -C "$repo_path" config user.email "test@example.com"
  git -C "$repo_path" config user.name "Test"
  # commit inicial vazio pra ter HEAD
  git -C "$repo_path" commit --allow-empty -q -m "init"
}

# ── 1. Arquivo untracked → deletado ──────────────────────────────

section_untracked_deleted() {
  echo "── arquivo untracked → deletado ──"
  local repo="$SANDBOX/repo-untracked"
  setup_repo "$repo"
  local task_file="$repo/docs/tasks/X1-foo.md"
  echo "scratch" > "$task_file"

  # confirma untracked antes
  if git -C "$repo" ls-files --error-unmatch "docs/tasks/X1-foo.md" >/dev/null 2>&1; then
    fail "pré: arquivo deveria ser untracked"
    return
  fi
  pass "pré: arquivo é untracked"

  # invoca helper de dentro do repo (cwd certo pra git ls-files)
  local out
  out=$(cd "$repo" && mmb_delete_orphan_task_file "docs/tasks/X1-foo.md" "repo-fake" 2>&1)

  [ -f "$task_file" ] && fail "arquivo NÃO foi deletado" || pass "arquivo deletado"
  echo "$out" | grep -q "Arquivo de task untracked removido" && pass "log: 'untracked removido'" || fail "log inesperado: [$out]"
}

# ── 2. Arquivo tracked → preservado ──────────────────────────────

section_tracked_preserved() {
  echo "── arquivo tracked → preservado ──"
  local repo="$SANDBOX/repo-tracked"
  setup_repo "$repo"
  local task_file="$repo/docs/tasks/M3-keep.md"
  echo "conteúdo committado" > "$task_file"
  git -C "$repo" add docs/tasks/M3-keep.md
  git -C "$repo" commit -q -m "feat: add M3 brief"

  # confirma tracked antes
  if ! git -C "$repo" ls-files --error-unmatch "docs/tasks/M3-keep.md" >/dev/null 2>&1; then
    fail "pré: arquivo deveria ser tracked"
    return
  fi
  pass "pré: arquivo é tracked"

  local out
  out=$(cd "$repo" && mmb_delete_orphan_task_file "docs/tasks/M3-keep.md" "repo-fake" 2>&1)

  [ -f "$task_file" ] && pass "arquivo preservado" || fail "arquivo foi deletado incorretamente"
  echo "$out" | grep -q "está tracked — preservado" && pass "log: 'tracked — preservado'" || fail "log inesperado: [$out]"
}

# ── 3. Arquivo ausente → no-op sem falha ────────────────────────

section_absent_noop() {
  echo "── arquivo ausente → no-op ──"
  local repo="$SANDBOX/repo-absent"
  setup_repo "$repo"

  local out rc
  set +e
  out=$(cd "$repo" && mmb_delete_orphan_task_file "docs/tasks/ZZ-nonexistent.md" "repo-fake" 2>&1)
  rc=$?
  set -e

  [ "$rc" = "0" ] && pass "exit 0 com arquivo ausente" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio (sem log de ação)" || fail "stdout inesperado: [$out]"
}

# ── 4. Arg vazio → no-op sem falha (set -e safe) ────────────────

section_empty_arg() {
  echo "── arg vazio → no-op ──"
  local repo="$SANDBOX/repo-empty-arg"
  setup_repo "$repo"

  local out rc
  set +e
  out=$(cd "$repo" && mmb_delete_orphan_task_file "" "repo-fake" 2>&1)
  rc=$?
  set -e

  [ "$rc" = "0" ] && pass "exit 0 com arg vazio" || fail "exit=$rc"
  [ -z "$out" ] && pass "stdout vazio com arg vazio" || fail "stdout inesperado: [$out]"
}

# ── 5. Compatível com set -e do caller ──────────────────────────
#
# Os callers (task-end.sh / task-abort.sh) rodam com `set -euo
# pipefail`. O helper precisa retornar 0 em todos os caminhos
# acima pra não derrubar o caller. Já coberto pelos asserts de
# rc=0 nos casos 3 e 4; este caso simula caller com set -e
# explicitamente.

section_set_e_compatible() {
  echo "── compatível com set -e do caller ──"
  local repo="$SANDBOX/repo-set-e"
  setup_repo "$repo"

  local rc
  set +e
  ( set -euo pipefail; cd "$repo" && mmb_delete_orphan_task_file "" "x" >/dev/null )
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "arg vazio + set -e: caller sobrevive" || fail "set -e derrubou: rc=$rc"

  set +e
  ( set -euo pipefail; cd "$repo" && mmb_delete_orphan_task_file "docs/tasks/ABSENT.md" "x" >/dev/null )
  rc=$?
  set -e
  [ "$rc" = "0" ] && pass "ausente + set -e: caller sobrevive" || fail "set -e derrubou: rc=$rc"
}

# ── Run ─────────────────────────────────────────────────────────

section_untracked_deleted
section_tracked_preserved
section_absent_noop
section_empty_arg
section_set_e_compatible

echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
