#!/usr/bin/env bash
# Valida o registry declarativo de targets (PR 1A).
#
# Roda 22 assertivas em 6 grupos:
#   1. Sanidade do arquivo JSON
#   2. Schema por entry
#   3. Unicidade
#   4. Consistência com filesystem
#   5. Semântica vs estado atual (cockpit/aquarium/logger + master)
#   6. Drift detector contra inbox/
#
# Exit 0 = todas passaram. Exit 1 = primeira falha + diagnóstico.

set -u

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MMB_ROOT="$(dirname "$TOOLING_DIR")"
TARGETS_FILE="$TOOLING_DIR/targets.json"
LIB_FILE="$TOOLING_DIR/lib/targets.sh"

PASS=0
FAIL=0
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

# Quase tudo precisa da lib carregada. Não fail-rápido aqui — deixamos
# o grupo 1 reportar erros do JSON antes de tentar usar a lib.
# shellcheck disable=SC1090
source "$LIB_FILE" 2>/dev/null || true

# ─── Grupo 1: sanidade do arquivo ──────────────────────────────

[ -f "$TARGETS_FILE" ] \
  && pass "targets.json existe em .tooling/" \
  || fail "targets.json existe em .tooling/" "esperado: $TARGETS_FILE"

python3 -m json.tool "$TARGETS_FILE" >/dev/null 2>&1 \
  && pass "targets.json é JSON válido" \
  || fail "targets.json é JSON válido" "$(python3 -m json.tool "$TARGETS_FILE" 2>&1 | head -3)"

sv=$(python3 -c "import json; print(json.load(open('$TARGETS_FILE'))['schema_version'])" 2>/dev/null)
[ "$sv" = "1" ] \
  && pass "schema_version == 1" \
  || fail "schema_version == 1" "achei: $sv"

n_targets=$(python3 -c "import json; d=json.load(open('$TARGETS_FILE')); print(len(d.get('targets', [])))" 2>/dev/null)
[ -n "$n_targets" ] && [ "$n_targets" -gt 0 ] \
  && pass "targets é array não-vazio ($n_targets entradas)" \
  || fail "targets é array não-vazio" "achei: $n_targets"

# ─── Carregar lib agora (depende do JSON válido confirmado acima) ──

mmb_targets_load \
  || fail "mmb_targets_load executa sem erro" "ver stderr"
# load() bem-sucedido já valida grupo 2 (schema por entry: campos
# obrigatórios, tipos, sem extras). Reportamos como uma assertiva agregada.
pass "schema por entry: campos obrigatórios, tipos, sem extras (validado em load)"

# ─── Grupo 2 complementar: regras de forma ─────────────────────

for id in $(mmb_targets_list); do
  if ! [[ "$id" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
    fail "id matches ^[a-z][a-z0-9-]{1,30}\$" "id inválido: $id"
  fi
done
pass "todos os ids matcham ^[a-z][a-z0-9-]{1,30}\$"

for id in $(mmb_targets_list); do
  al=$(mmb_target_field "$id" agent_layer)
  case "$al" in
    master|project|atomic) ;;
    *) fail "agent_layer ∈ {master,project,atomic}" "$id tem '$al'" ;;
  esac
done
pass "agent_layer de todos os targets ∈ {master,project,atomic}"

for id in $(mmb_targets_list); do
  wp=$(mmb_target_field "$id" worker_profile)
  prof="$TOOLING_DIR/profiles/$wp"
  [ -f "$prof" ] \
    || fail "worker_profile aponta para arquivo existente" "$id: $prof não existe"
done
pass "worker_profile de todos os targets existe em .tooling/profiles/"

# ─── Grupo 3: unicidade ────────────────────────────────────────

ids=$(mmb_targets_list)
uniq_ids=$(printf '%s\n' $ids | sort -u | wc -l)
total_ids=$(printf '%s\n' $ids | wc -l)
[ "$uniq_ids" -eq "$total_ids" ] \
  && pass "ids únicos ($total_ids targets, $uniq_ids únicos)" \
  || fail "ids únicos" "$total_ids vs $uniq_ids"

dests=""
for id in $ids; do dests="$dests $(mmb_target_field "$id" dest)"; done
uniq_dests=$(printf '%s\n' $dests | sort -u | wc -l)
total_dests=$(printf '%s\n' $dests | wc -l)
[ "$uniq_dests" -eq "$total_dests" ] \
  && pass "dests únicos" \
  || fail "dests únicos" "$total_dests vs $uniq_dests"

repos=""
for id in $ids; do repos="$repos $(mmb_target_field "$id" repo)"; done
uniq_repos=$(printf '%s\n' $repos | sort -u | wc -l)
total_repos=$(printf '%s\n' $repos | wc -l)
[ "$uniq_repos" -eq "$total_repos" ] \
  && pass "repos únicos" \
  || fail "repos únicos" "$total_repos vs $uniq_repos"

# ─── Grupo 4: consistência com filesystem ──────────────────────

# Usa mmb_target_path (não MMB_ROOT/$lp literal) para suportar local_path
# absoluto — necessário para targets externos (kind=external/external-fake).
for id in $ids; do
  lp=$(mmb_target_path "$id")
  [ -d "$lp/.git" ] \
    || fail "local_path/.git existe" "$id: $lp/.git ausente"
done
pass "local_path/.git existe para todos os targets"

# ─── Grupo 5: semântica vs estado atual ────────────────────────

# Sanity: lista contém os 3 internos atuais (cockpit/aquarium/logger).
# Targets externos adicionais são aceitos — só checamos os mínimos.
actual_targets=" $(mmb_targets_list) "
for required in cockpit aquarium logger; do
  case "$actual_targets" in
    *" $required "*) ;;
    *) fail "mmb_targets_list contém $required" "achei: $actual_targets" ;;
  esac
done
pass "mmb_targets_list contém cockpit, aquarium, logger (atuais: $(echo $actual_targets))"

actual_dests=" $(mmb_dests_list) "
for required in master cockpit aquarium logger; do
  case "$actual_dests" in
    *" $required "*) ;;
    *) fail "mmb_dests_list contém $required" "achei: $actual_dests" ;;
  esac
done
pass "mmb_dests_list contém master + 3 internos (atuais: $(echo $actual_dests))"

if printf '%s\n%s\n' "$actual_targets" "$actual_dests" | grep -qw core; then
  fail "regressão guard: 'core' ausente das listas" "achei 'core' em targets ou dests"
fi
pass "regressão guard: 'core' não aparece em mmb_targets_list nem em mmb_dests_list"

[ "$(mmb_target_repo cockpit)" = "mmb-cockpit" ] \
  && pass "mmb_target_repo cockpit == mmb-cockpit" \
  || fail "mmb_target_repo cockpit == mmb-cockpit" "achei: $(mmb_target_repo cockpit)"

path_cockpit=$(mmb_target_path cockpit)
[ -d "$path_cockpit" ] && [[ "$path_cockpit" == */mmb-cockpit ]] \
  && pass "mmb_target_path cockpit é diretório existente terminado em /mmb-cockpit" \
  || fail "mmb_target_path cockpit é diretório existente terminado em /mmb-cockpit" "achei: $path_cockpit"

# ─── Grupo 5b: campos opcionais PR 2A ──────────────────────────

[ "$(mmb_target_owner cockpit)" = "x-force-42" ] \
  && pass "mmb_target_owner cockpit == x-force-42" \
  || fail "mmb_target_owner cockpit == x-force-42" "achei: $(mmb_target_owner cockpit)"

[ "$(mmb_target_requires_github cockpit)" = "true" ] \
  && pass "mmb_target_requires_github cockpit == true" \
  || fail "mmb_target_requires_github cockpit == true" "achei: $(mmb_target_requires_github cockpit)"

[ "$(mmb_target_kind cockpit)" = "internal" ] \
  && pass "mmb_target_kind cockpit == internal" \
  || fail "mmb_target_kind cockpit == internal" "achei: $(mmb_target_kind cockpit)"

[ "$(mmb_target_managed_by_reset cockpit)" = "true" ] \
  && pass "mmb_target_managed_by_reset cockpit == true" \
  || fail "mmb_target_managed_by_reset cockpit == true"

# Fixture: registry temporário com target externo (local_path absoluto +
# owner vazio). Sub-shell isolada para não poluir o cache global do test.
_tmp_target_dir=$(mktemp -d)
mkdir -p "$_tmp_target_dir/.git"  # placeholder
_tmp_registry=$(mktemp)
cat > "$_tmp_registry" <<JSON
{
  "schema_version": 1,
  "targets": [
    {
      "id": "ext-fake",
      "dest": "ext-fake",
      "repo": "weather-cli",
      "local_path": "$_tmp_target_dir",
      "worker_profile": "project-orchestrator.md",
      "agent_layer": "project",
      "tracked_by_logger": false,
      "owner": "",
      "requires_github": false,
      "kind": "external-fake",
      "managed_by_reset": false
    }
  ]
}
JSON

abs_path=$(
  bash <<EOF
source "$LIB_FILE"
_MMB_TARGETS_FILE="$_tmp_registry"
MMB_GH_OWNER=fallback-org
mmb_targets_load >/dev/null && mmb_target_path ext-fake
EOF
)
[ "$abs_path" = "$_tmp_target_dir" ] \
  && pass "local_path absoluto resolve direto (sem prefixar MMB_ROOT)" \
  || fail "local_path absoluto resolve direto" "achei: '$abs_path' esperado: '$_tmp_target_dir'"

owner_fb=$(
  bash <<EOF
source "$LIB_FILE"
_MMB_TARGETS_FILE="$_tmp_registry"
MMB_GH_OWNER=fallback-org
mmb_targets_load >/dev/null && mmb_target_owner ext-fake
EOF
)
[ "$owner_fb" = "fallback-org" ] \
  && pass "mmb_target_owner com owner vazio usa MMB_GH_OWNER" \
  || fail "mmb_target_owner com owner vazio usa MMB_GH_OWNER" "achei: '$owner_fb'"

ext_kind=$(
  bash <<EOF
source "$LIB_FILE"
_MMB_TARGETS_FILE="$_tmp_registry"
mmb_targets_load >/dev/null && mmb_target_kind ext-fake
EOF
)
[ "$ext_kind" = "external-fake" ] \
  && pass "mmb_target_kind external-fake aceito" \
  || fail "mmb_target_kind external-fake aceito" "achei: '$ext_kind'"

rm -rf "$_tmp_target_dir" "$_tmp_registry"

if mmb_target_exists cockpit && ! mmb_target_exists nao-existe-mesmo; then
  pass "mmb_target_exists: 'cockpit' exit 0, 'nao-existe-mesmo' exit ≠ 0"
else
  fail "mmb_target_exists comportamento esperado" "cockpit ou nao-existe-mesmo retornou errado"
fi

# Validador semântico agregado (extras: agent_layer, profile, .git, 'core').
mmb_targets_validate \
  && pass "mmb_targets_validate exit 0 (validação semântica agregada)" \
  || fail "mmb_targets_validate exit 0" "ver stderr acima"

# ─── Grupo 6: drift detector contra inbox/ ─────────────────────

# (a) Cada dest tem diretório em inbox/.
for d in $(mmb_dests_list); do
  [ -d "$TOOLING_DIR/inbox/$d" ] \
    || fail "inbox/<dest>/ existe para cada dest" "ausente: $TOOLING_DIR/inbox/$d"
done
pass "inbox/<dest>/ existe para cada dest de mmb_dests_list"

# (b) Cada diretório em inbox/ está em mmb_dests_list.
# Ignora arquivos ocultos (.lock, .gitkeep). Estes seriam falsos
# positivos — mas mmb_dests_list é space-separated; usamos word-match
# pra evitar match parcial.
dests_words=" $(mmb_dests_list) "
orfaos=""
for d in "$TOOLING_DIR"/inbox/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  case "$name" in .*) continue ;; esac
  case "$dests_words" in
    *" $name "*) ;;
    *) orfaos="$orfaos $name" ;;
  esac
done
if [ -n "$orfaos" ]; then
  fail "nenhum subdir órfão em inbox/ (não listado em mmb_dests_list)" \
       "órfãos:$orfaos — remova manualmente ou adicione ao registry"
fi
pass "nenhum subdir órfão em inbox/ (drift contra mmb_dests_list)"

# ─── Resumo ────────────────────────────────────────────────────

echo
printf '────────────────────────────────────────────\n'
printf '  %d assertivas: %d ✓  %d ✗\n' "$N" "$PASS" "$FAIL"
printf '────────────────────────────────────────────\n'

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
