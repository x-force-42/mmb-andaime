#!/usr/bin/env bash
# Smoke external (T11 do épico external-target-fortification, Wave 1).
#
# Valida que target `kind=external` é cidadão de primeira classe nos pontos
# de runtime do andaime cobertos pela Wave 1. Pontos que dependem de Wave 2
# (T1: send-status-pr-opened; T3: spawn-atomic prompt + tmux fallback)
# entram como **xfail explícitos** — o teste registra o que falha e por
# que, sem falhar a suíte global. Quando Wave 2 mergear, basta remover o
# xfail correspondente.
#
# Estratégia: usa um sandbox temporário pra adicionar target `external-fake`
# ao registry (mesmo padrão do grupo 4 de test-targets-registry.sh).
# Aciona helpers do registry + scripts de runtime em modo read-only/dry-run
# onde possível.
#
# Exit 0 se PASS + XFAIL esperados. Exit 1 em falha real.

set -u

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_MMB_ROOT="$(dirname "$TOOLING_DIR")"
LIB_FILE="$TOOLING_DIR/lib/targets.sh"

PASS=0
FAIL=0
XFAIL=0
N=0

pass() {
  N=$((N + 1)); PASS=$((PASS + 1))
  printf '✓ %2d: %s\n' "$N" "$1"
}
fail() {
  N=$((N + 1)); FAIL=$((FAIL + 1))
  printf '✗ %2d: %s\n' "$N" "$1" >&2
  [ -n "${2:-}" ] && printf '       %s\n' "$2" >&2
  exit 1
}
xfail() {
  N=$((N + 1)); XFAIL=$((XFAIL + 1))
  printf '∼ %2d: %s [XFAIL: %s]\n' "$N" "$1" "$2"
}

# ─── Sandbox: fixture de target externo ─────────────────────────

SANDBOX=$(mktemp -d -t mmb-extsmoke.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# Repo git fake fora do MMB_ROOT (simula campo-premiado).
EXT_REPO="$SANDBOX/external-fake-repo"
git init -q -b main "$EXT_REPO" >/dev/null
(
  cd "$EXT_REPO"
  git config user.email "test@local" && git config user.name "test"
  echo "external target sandbox" > README.md
  mkdir -p docs/tasks
  echo "# T1 — smoke fixture" > docs/tasks/T1-smoke-fixture.md
  git add -A && git commit -q -m "init"
)

# Tooling sandbox: copia targets.json + adiciona entry external-fake.
SAND_TOOLING="$SANDBOX/.tooling"
mkdir -p "$SAND_TOOLING/profiles" "$SAND_TOOLING/lib"
cp "$TOOLING_DIR/lib/targets.sh" "$SAND_TOOLING/lib/"
cp "$TOOLING_DIR/profiles/project-orchestrator.md" "$SAND_TOOLING/profiles/"

python3 <<PY > "$SAND_TOOLING/targets.json"
import json
data = {
    "schema_version": 1,
    "targets": [
        {
            "id": "ext-fake",
            "dest": "ext-fake",
            "repo": "external-fake-repo",
            "local_path": "$EXT_REPO",
            "worker_profile": "project-orchestrator.md",
            "agent_layer": "project",
            "tracked_by_logger": True,
            "owner": "test-owner",
            "requires_github": False,
            "kind": "external",
            "managed_by_reset": False,
        }
    ],
}
print(json.dumps(data, indent=2))
PY

export MMB_ROOT="$SANDBOX"

# ─── Grupo 1: registry resolve target externo corretamente ──────

# shellcheck disable=SC1090
source "$SAND_TOOLING/lib/targets.sh"
mmb_targets_load >/dev/null \
  && pass "registry sandbox carrega com entry external" \
  || fail "registry sandbox carrega com entry external" "$(mmb_targets_load 2>&1 | head -3)"

[ "$(mmb_target_kind ext-fake)" = "external" ] \
  && pass "kind == external" \
  || fail "kind == external" "achei: $(mmb_target_kind ext-fake)"

resolved_path=$(mmb_target_path ext-fake)
[ "$resolved_path" = "$EXT_REPO" ] \
  && pass "mmb_target_path resolve absoluto fora de MMB_ROOT" \
  || fail "mmb_target_path resolve absoluto" "esperado: $EXT_REPO, achei: $resolved_path"

[ "$(mmb_target_repo ext-fake)" = "external-fake-repo" ] \
  && pass "mmb_target_repo == external-fake-repo (sem prefixo mmb-)" \
  || fail "mmb_target_repo == external-fake-repo"

[ "$(mmb_target_owner ext-fake)" = "test-owner" ] \
  && pass "mmb_target_owner respeita owner per-target" \
  || fail "mmb_target_owner" "achei: $(mmb_target_owner ext-fake)"

# ─── Grupo 2: profile do atomic-agent não tem mais /MMB/ literal ─

literal_count=$(grep -cE '^[^#]*[^$]\{?\bMMB_TOOLING|/MMB/' "$TOOLING_DIR/profiles/atomic-agent.md" | head -1 || echo 0)
# Contagem-alvo: 0 ocorrências de `/MMB/` puro (sem ${MMB_TOOLING:-...} de fallback).
raw_mmb=$(grep -cE '(^|[^:}])/MMB/' "$TOOLING_DIR/profiles/atomic-agent.md" || true)
# `/MMB/` dentro do fallback `${MMB_TOOLING:-/MMB/.tooling}` é OK e contado.
# A regex acima exclui o caso `:-/MMB/` (precedido de `:-` que vira `}`/etc).
# Aceita até 4 ocorrências (os 6 fallbacks contém `/MMB/.tooling` que casa).
# Verificação alternativa mais semântica: literais `/MMB/` *fora* de fallback.
bad=$(grep -nE '(^|\s)/MMB/' "$TOOLING_DIR/profiles/atomic-agent.md" \
      | grep -vE '\$\{MMB_TOOLING:-/MMB/' || true)
if [ -z "$bad" ]; then
  pass "atomic-agent.md: nenhum /MMB/ literal fora de fallback ${MMB_TOOLING:-...}"
else
  fail "atomic-agent.md: /MMB/ literal solto" "$(echo "$bad" | head -3)"
fi

# ─── Grupo 3: dependências Wave 2 (xfail explícitos) ────────────

# T1 (send-status-pr-opened.sh): pr_url ainda é construído com prefixo mmb-.
if grep -q 'REPO_FULL="mmb-${REPO_SHORT}"' "$TOOLING_DIR/bin/send-status-pr-opened.sh"; then
  xfail "send-status-pr-opened.sh produz pr_url correto pra target externo" \
        "T1 Wave 2: linhas 125/140 hardcodam REPO_FULL=mmb-\${REPO_SHORT}"
else
  pass "send-status-pr-opened.sh pr_url respeita registry"
fi

# T3 (spawn-atomic.sh): prompt hardcoda /MMB/ e fallback tmux silencioso.
if grep -q "Leia /MMB/.tooling/profiles/atomic-agent.md" "$TOOLING_DIR/bin/spawn-atomic.sh"; then
  xfail "spawn-atomic.sh prompt usa path portável (não /MMB/ literal)" \
        "T3 Wave 2: linha ~144 ainda hardcoda /MMB/ no prompt"
else
  pass "spawn-atomic.sh prompt usa path portável"
fi

# T10 (Closes cross-repo): regex em derive.py do logger (path real, não sandbox).
DERIVE="$REAL_MMB_ROOT/mmb-logger/src/mmb_logger/reconcile/derive.py"
if [ -f "$DERIVE" ]; then
  # Aceita pass quando regex contém grupo opcional pra owner/repo.
  if grep -qE 'Closes.*\\\(.*\\\)/.*\\\(.*\\\).*#|owner.*repo.*#' "$DERIVE"; then
    pass "logger derive.py _CLOSES_RE aceita formato cross-repo"
  else
    xfail "logger derive.py _CLOSES_RE aceita cross-repo (Closes owner/repo#N)" \
          "T10 pendente: PR do épico logger-external-target-linkage não mergeado"
  fi
else
  xfail "logger derive.py acessível pra inspeção" "$DERIVE não existe"
fi

# T8 (audit.py linkagem): mmb- prefix hardcoded.
AUDIT="$REAL_MMB_ROOT/mmb-logger/src/mmb_logger/reconcile/audit.py"
if [ -f "$AUDIT" ]; then
  if grep -q 'project_full = f"mmb-{project_short}"' "$AUDIT"; then
    xfail "logger audit.py _find_ciclo_by_epic_project resolve target externo" \
          "T8 pendente: audit.py:211 ainda hardcoda f\"mmb-{project_short}\""
  else
    pass "logger audit.py resolve target externo via registry"
  fi
else
  xfail "logger audit.py acessível pra inspeção" "$AUDIT não existe"
fi

# T9 (backfill agent_sessions): pattern deve usar short_to_repo helper.
# Linha `legacy = f"mmb-{rec.project}"` é OK como fallback retrocompat
# quando coexiste com a importação de short_to_repo.
BACKFILL="$REAL_MMB_ROOT/mmb-logger/src/mmb_logger/backfill/agent_sessions.py"
if [ -f "$BACKFILL" ]; then
  if grep -q "from mmb_logger.targets import .*short_to_repo" "$BACKFILL"; then
    pass "logger backfill/agent_sessions.py resolve target externo via registry"
  else
    xfail "logger backfill/agent_sessions.py resolve target externo" \
          "T9 pendente: short_to_repo helper não importado"
  fi
fi

# ─── Resumo ─────────────────────────────────────────────────────

echo
printf 'SMOKE EXTERNAL: PASS=%d  XFAIL=%d  FAIL=%d  TOTAL=%d\n' \
       "$PASS" "$XFAIL" "$FAIL" "$N"

# XFAIL é estado conhecido/aceito de Wave 1; só falha em FAIL real.
if [ "$FAIL" -gt 0 ]; then
  echo "FALHA: regressão em comportamento já corrigido. Investigar." >&2
  exit 1
fi
exit 0
