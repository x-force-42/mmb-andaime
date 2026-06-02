#!/usr/bin/env bash
# Testes de idempotência do .tooling/bin/open-pr.sh (H1).
#
# Garantia: reprocessar a MESMA branch/head NÃO cria PR duplicado. Antes
# de `gh pr create`, o wrapper consulta `gh pr list --head "$BRANCH"`; se
# já existe PR pra aquela branch, reusa o existente e sai 0.
#
# Critérios de aceite (do Rick):
#   1. Primeira execução: cria PR.
#   2. Segunda execução, mesma branch: reusa PR existente, exit 0.
#   3. Branch diferente: cria PR novo.
#   4. Falha REAL de `gh pr create` continua sendo falha (exit != 0),
#      não é mascarada como idempotência.
#
# Estratégia hermética (sem GitHub real):
#   - repo git de verdade + remote BARE local ($SANDBOX/origin.git), pra
#     `git push -u origin` funcionar offline.
#   - origin/HEAD setado explicitamente (mmb_default_branch precisa dele).
#   - stub STATEFUL de `gh` (mini-GitHub) que guarda PRs por head-branch
#     em $MMB_TEST_GH_PR_STATE; `gh pr list --head B` devolve o url
#     existente; `gh pr create` registra e ecoa url. Falha sob demanda
#     via MMB_TEST_GH_PR_CREATE_FAIL=1.

set -uo pipefail

TOOLING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$TOOLING_DIR/bin/open-pr.sh"

SANDBOX=$(mktemp -d /tmp/mmb-openpr-idem-test-XXXXXX)
ORIGIN="$SANDBOX/origin.git"
WORK="$SANDBOX/work"
SUITE="$SANDBOX/suite.txt"
PR_STATE="$SANDBOX/gh-pr-state.tsv"
mkdir -p "$SANDBOX/bin"
: > "$PR_STATE"

# Suite output válido (>100 bytes, guardrail A11).
{
  echo "Test Suites: 3 passed, 3 total"
  echo "Tests:       17 passed, 17 total"
  echo "Snapshots:   0 total"
  echo "Time:        2.1 s, estimated 3 s"
  echo "Ran all test suites. Tudo verde."
} > "$SUITE"

# ── Stub stateful de gh ──────────────────────────────────────────
cat > "$SANDBOX/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${MMB_TEST_GH_PR_STATE:?MMB_TEST_GH_PR_STATE não setada}"
[ -f "$STATE" ] || : > "$STATE"

# extrai --head de qualquer posição
head=""
prev=""
for a in "$@"; do
  [ "$prev" = "--head" ] && head="$a"
  prev="$a"
done

case "${1:-} ${2:-}" in
  "pr list")
    # emula `--jq '.[0].url // empty'`: url da branch ou vazio
    awk -F'\t' -v b="$head" '$1==b{print $2; exit}' "$STATE"
    ;;
  "pr create")
    if [ "${MMB_TEST_GH_PR_CREATE_FAIL:-0}" = "1" ]; then
      echo "stub gh: pull request create failed (simulado)" >&2
      exit 1
    fi
    n=$(( $(wc -l < "$STATE") + 1 ))
    url="https://github.com/x-force-42/mmb-cockpit/pull/$n"
    printf '%s\t%s\n' "$head" "$url" >> "$STATE"
    printf '%s\n' "$url"
    ;;
  "issue comment")
    : # no-op (comentário na sub-issue)
    ;;
  *)
    : # defensivo: qualquer outra chamada de gh vira no-op
    ;;
esac
STUB_EOF
chmod +x "$SANDBOX/bin/gh"

export PATH="$SANDBOX/bin:$PATH"
export MMB_TEST_GH_PR_STATE="$PR_STATE"

failures=0
ran=0
pass() { ran=$((ran+1)); printf '  ✓ %s\n' "$1"; }
fail() { ran=$((ran+1)); failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

git_quiet() { git -C "$WORK" "$@" >/dev/null 2>&1; }

setup_repo() {
  git init --bare -b main "$ORIGIN" >/dev/null 2>&1
  git init -b main "$WORK" >/dev/null 2>&1
  git_quiet config user.email "test@mmb.local"
  git_quiet config user.name "MMB Test"
  echo "# repo de teste" > "$WORK/README.md"
  git_quiet add -A
  git_quiet commit -m "chore: initial"
  git_quiet remote add origin "$ORIGIN"
  git_quiet push -u origin main
  # origin/HEAD explícito — mmb_default_branch depende disso.
  git_quiet symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# Cria branch task/<n> a partir de main com 1 commit à frente.
new_task_branch() {
  git_quiet checkout -b "$1" main
  echo "mudança em $1" > "$WORK/feature-$2.txt"
  git_quiet add -A
  git_quiet commit -m "feat: $2"
}

# Roda open-pr.sh de dentro da worktree, com env mínimo. Não seta
# EPIC_SLUG/MMB_AGENT_ID → pula send-status e deregister (sem tocar
# inbox real). Args extras passam env adicional inline (ex.: FAIL=1).
run_openpr() {
  # `env` interpreta os "$@" (ex.: MMB_TEST_GH_PR_CREATE_FAIL=1) como
  # atribuições em runtime. NÃO usar prefixo de atribuição direto: um
  # VAR=VAL vindo de expansão de "$@" vira NOME DE COMANDO (exit 127),
  # não atribuição — e o script de teste nem rodaria.
  (
    cd "$WORK"
    unset EPIC_SLUG MMB_AGENT_ID MMB_PANE_ID TMUX
    env GH_SUBISSUE=42 \
        MMB_SUITE_OUTPUT="$SUITE" \
        MMB_GH_OWNER=x-force-42 \
        "$@" \
        bash "$SCRIPT"
  )
}

state_lines() { wc -l < "$PR_STATE" | tr -d ' '; }
url_for() { awk -F'\t' -v b="$1" '$1==b{print $2; exit}' "$PR_STATE"; }

# ── bash -n ──────────────────────────────────────────────────────
echo "── bash -n ──"
bash -n "$SCRIPT" 2>/dev/null && pass "bash -n passa" || fail "bash -n falhou"

setup_repo

# ── 1. primeira execução cria PR ─────────────────────────────────
echo "── 1. primeira execução cria PR ──"
new_task_branch "task/1-foo" "foo"
set +e
OUT1=$(run_openpr 2>/dev/null); RC1=$?
set -e
[ "$RC1" = "0" ] && pass "exit 0" || fail "exit=$RC1"
[ "$(state_lines)" = "1" ] && pass "1 PR registrado" || fail "estado tem $(state_lines) PRs"
URL1=$(url_for "task/1-foo")
[ -n "$URL1" ] && pass "PR criado pra task/1-foo ($URL1)" || fail "nenhum PR pra task/1-foo"
printf '%s' "$OUT1" | grep -q "PR aberto:" && pass "stdout reporta 'PR aberto'" || fail "stdout não reporta criação"

# ── 2. reprocesso da MESMA branch reusa ──────────────────────────
echo "── 2. mesma branch reusa PR existente ──"
set +e
OUT2=$(run_openpr 2>/dev/null); RC2=$?
set -e
[ "$RC2" = "0" ] && pass "exit 0 (idempotente)" || fail "exit=$RC2"
[ "$(state_lines)" = "1" ] && pass "AINDA 1 PR (sem duplicata)" || fail "DUPLICOU: $(state_lines) PRs"
[ "$(url_for "task/1-foo")" = "$URL1" ] && pass "mesmo PR preservado" || fail "url mudou"
printf '%s' "$OUT2" | grep -q "já existe" && pass "stdout reporta reuso ('já existe')" || fail "não reportou reuso"

# ── 3. branch diferente cria PR novo ─────────────────────────────
echo "── 3. branch diferente cria PR novo ──"
new_task_branch "task/2-bar" "bar"
set +e
OUT3=$(run_openpr 2>/dev/null); RC3=$?
set -e
[ "$RC3" = "0" ] && pass "exit 0" || fail "exit=$RC3"
[ "$(state_lines)" = "2" ] && pass "2 PRs (criação legítima não bloqueada)" || fail "estado tem $(state_lines)"
[ -n "$(url_for "task/2-bar")" ] && pass "PR novo pra task/2-bar" || fail "nenhum PR pra task/2-bar"

# ── 4. falha real de gh pr create NÃO é mascarada ────────────────
echo "── 4. falha real de gh pr create continua sendo falha ──"
new_task_branch "task/3-baz" "baz"
set +e
OUT4=$(run_openpr MMB_TEST_GH_PR_CREATE_FAIL=1 2>/dev/null); RC4=$?
set -e
[ "$RC4" != "0" ] && pass "exit != 0 (falha propagada, rc=$RC4)" || fail "mascarou falha como sucesso (rc=0)"
# Prova que o open-pr.sh REALMENTE rodou (até o push) e só então o
# create falhou — não que o script deixou de rodar (que daria exit 127
# e um falso verde). O push acontece antes do create.
if git --git-dir="$ORIGIN" rev-parse --verify -q "refs/heads/task/3-baz" >/dev/null 2>&1; then
  pass "branch foi pushada (script rodou até o create)"
else
  fail "branch não chegou no origin — script não rodou (falso verde)"
fi
[ "$(state_lines)" = "2" ] && pass "nenhum PR registrado na falha (ainda 2)" || fail "estado mudou: $(state_lines)"
[ -z "$(url_for "task/3-baz")" ] && pass "task/3-baz sem PR (não criou)" || fail "criou PR apesar da falha"

# ── Runner ───────────────────────────────────────────────────────
echo ""
if [ "$failures" -eq 0 ]; then
  printf '✓ %d/%d testes passaram\n' "$ran" "$ran"
  exit 0
else
  printf '✗ %d/%d testes falharam\n' "$failures" "$ran"
  exit 1
fi
