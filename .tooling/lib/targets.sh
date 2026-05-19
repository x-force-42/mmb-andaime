#!/usr/bin/env bash
# Adaptador Bash do registry de targets do MMB (PR 1A).
#
# Fonte declarativa: $MMB_ROOT/.tooling/targets.json
# Schema: id, dest, repo, local_path, worker_profile, agent_layer,
#         tracked_by_logger (ver schema_version=1).
#
# Esta lib é READ-ONLY e PASSIVA: nenhum script runtime do andaime
# (worker.sh, commd.sh, reset-all.sh, etc) faz source dela na PR 1A.
# A integração com consumidores começa só na PR 1B.
#
# Convenções:
#   - `local_path` no JSON é relativo a MMB_ROOT. Sempre acesse via
#     `mmb_target_path` (que resolve pro absoluto).
#   - `master` NÃO é target; é uma role. Ele entra explicitamente em
#     `mmb_dests_list` (única mistura) mas nunca em `mmb_targets_list`.
#
# Uso (futuro, em consumidores):
#   source "$TOOLING_DIR/lib/targets.sh"
#   for t in $(mmb_targets_list); do ... done

# ─── Resolução de MMB_ROOT ──────────────────────────────────────
# Robusto a quem fez source: deriva do path do próprio arquivo.
# Permite override via env (útil em testes/smoke sandbox).
_mmb_targets_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MMB_ROOT:=$(cd "$_mmb_targets_lib_dir/../.." && pwd)}"
_MMB_TARGETS_FILE="$MMB_ROOT/.tooling/targets.json"

# Caches populados por mmb_targets_load.
_MMB_TARGETS_LOADED=0
_MMB_TARGETS_IDS=""
declare -A _MMB_TARGET_DEST
declare -A _MMB_TARGET_REPO
declare -A _MMB_TARGET_LOCAL_PATH
declare -A _MMB_TARGET_WORKER_PROFILE
declare -A _MMB_TARGET_AGENT_LAYER
declare -A _MMB_TARGET_TRACKED_BY_LOGGER

# ─── Internals ──────────────────────────────────────────────────

# Imprime erro pra stderr.
_mmb_targets_err() {
  printf 'targets.sh: %s\n' "$*" >&2
}

# Verifica python3 disponível. Sem ele, parser não funciona.
_mmb_targets_check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    _mmb_targets_err "python3 não encontrado no PATH (necessário pra parsear $_MMB_TARGETS_FILE)"
    return 1
  fi
}

# ─── API pública ────────────────────────────────────────────────

# Carrega targets.json em caches. Idempotente (re-source = re-parse).
# Falha rápida (return 1) com mensagem se JSON inválido ou ausente.
mmb_targets_load() {
  _mmb_targets_check_python || return 1

  if [ ! -f "$_MMB_TARGETS_FILE" ]; then
    _mmb_targets_err "arquivo não existe: $_MMB_TARGETS_FILE"
    return 1
  fi

  # Parse via python3 → linhas TSV: id<TAB>dest<TAB>repo<TAB>local_path<TAB>worker_profile<TAB>agent_layer<TAB>tracked_by_logger
  # Validação de tipo + presença feita aqui; validação semântica (unicidade,
  # filesystem) fica em mmb_targets_validate.
  local tsv
  if ! tsv=$(python3 - "$_MMB_TARGETS_FILE" <<'PY' 2>&1
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"ERR: JSON inválido em {path}: {e}", file=sys.stderr); sys.exit(2)
except OSError as e:
    print(f"ERR: não consegui ler {path}: {e}", file=sys.stderr); sys.exit(2)

if not isinstance(data, dict):
    print("ERR: raiz não é objeto JSON", file=sys.stderr); sys.exit(2)
if data.get("schema_version") != 1:
    print(f"ERR: schema_version esperado 1, achei {data.get('schema_version')!r}", file=sys.stderr); sys.exit(2)
targets = data.get("targets")
if not isinstance(targets, list) or not targets:
    print("ERR: targets ausente ou não-array não-vazio", file=sys.stderr); sys.exit(2)

REQUIRED = ("id", "dest", "repo", "local_path", "worker_profile", "agent_layer", "tracked_by_logger")
for i, t in enumerate(targets):
    if not isinstance(t, dict):
        print(f"ERR: target[{i}] não é objeto", file=sys.stderr); sys.exit(2)
    extra = set(t) - set(REQUIRED)
    if extra:
        print(f"ERR: target[{i}] tem campos extras: {sorted(extra)}", file=sys.stderr); sys.exit(2)
    missing = [k for k in REQUIRED if k not in t]
    if missing:
        print(f"ERR: target[{i}] sem campos: {missing}", file=sys.stderr); sys.exit(2)
    for k in REQUIRED[:-1]:  # strings
        v = t[k]
        if not isinstance(v, str) or not v:
            print(f"ERR: target[{i}].{k} não é string não-vazia ({v!r})", file=sys.stderr); sys.exit(2)
    if not isinstance(t["tracked_by_logger"], bool):
        print(f"ERR: target[{i}].tracked_by_logger não é booleano ({t['tracked_by_logger']!r})", file=sys.stderr); sys.exit(2)
    # Saída TSV (sem TABs nos valores; garantido pelo schema kebab-case).
    bool_str = "true" if t["tracked_by_logger"] else "false"
    print("\t".join((t["id"], t["dest"], t["repo"], t["local_path"],
                     t["worker_profile"], t["agent_layer"], bool_str)))
PY
  ); then
    _mmb_targets_err "falha ao parsear targets.json"
    printf '%s\n' "$tsv" >&2
    return 1
  fi

  # Reset caches (idempotente sob re-source).
  _MMB_TARGETS_IDS=""
  unset _MMB_TARGET_DEST _MMB_TARGET_REPO _MMB_TARGET_LOCAL_PATH \
        _MMB_TARGET_WORKER_PROFILE _MMB_TARGET_AGENT_LAYER _MMB_TARGET_TRACKED_BY_LOGGER
  declare -gA _MMB_TARGET_DEST _MMB_TARGET_REPO _MMB_TARGET_LOCAL_PATH \
              _MMB_TARGET_WORKER_PROFILE _MMB_TARGET_AGENT_LAYER _MMB_TARGET_TRACKED_BY_LOGGER

  local id dest repo lp wp al tbl
  while IFS=$'\t' read -r id dest repo lp wp al tbl; do
    [ -z "$id" ] && continue
    _MMB_TARGET_DEST[$id]="$dest"
    _MMB_TARGET_REPO[$id]="$repo"
    _MMB_TARGET_LOCAL_PATH[$id]="$lp"
    _MMB_TARGET_WORKER_PROFILE[$id]="$wp"
    _MMB_TARGET_AGENT_LAYER[$id]="$al"
    _MMB_TARGET_TRACKED_BY_LOGGER[$id]="$tbl"
    _MMB_TARGETS_IDS="$_MMB_TARGETS_IDS $id"
  done <<< "$tsv"

  # Trim leading space.
  _MMB_TARGETS_IDS="${_MMB_TARGETS_IDS# }"
  _MMB_TARGETS_LOADED=1
  return 0
}

# Garante que o load rodou. Auto-loads se ainda não. Falha → return 1.
_mmb_targets_ensure_loaded() {
  [ "$_MMB_TARGETS_LOADED" -eq 1 ] && return 0
  mmb_targets_load
}

# Lista os ids de targets, space-separated, na ordem do JSON.
# Exemplo: "cockpit aquarium logger"
mmb_targets_list() {
  _mmb_targets_ensure_loaded || return 1
  printf '%s\n' "$_MMB_TARGETS_IDS"
}

# Lista os dests ativos (targets + master, que é role fixa).
# `master` é hardcoded propositalmente — não é target.
# Exemplo: "master cockpit aquarium logger"
mmb_dests_list() {
  _mmb_targets_ensure_loaded || return 1
  local dests="master"
  local id
  for id in $_MMB_TARGETS_IDS; do
    dests="$dests ${_MMB_TARGET_DEST[$id]}"
  done
  printf '%s\n' "$dests"
}

# Existe target com este id?
mmb_target_exists() {
  local id="${1:-}"
  [ -z "$id" ] && return 1
  _mmb_targets_ensure_loaded || return 1
  [ -n "${_MMB_TARGET_REPO[$id]:-}" ]
}

# Acesso genérico a campo. Uso:
#   mmb_target_field cockpit repo      → mmb-cockpit
#   mmb_target_field cockpit dest      → cockpit
# Exit 2 se id ou campo inválidos.
mmb_target_field() {
  local id="${1:-}" field="${2:-}"
  if [ -z "$id" ] || [ -z "$field" ]; then
    _mmb_targets_err "uso: mmb_target_field <id> <campo>"
    return 2
  fi
  _mmb_targets_ensure_loaded || return 1
  if ! mmb_target_exists "$id"; then
    _mmb_targets_err "target desconhecido: $id"
    return 2
  fi
  case "$field" in
    dest)               printf '%s\n' "${_MMB_TARGET_DEST[$id]}" ;;
    repo)               printf '%s\n' "${_MMB_TARGET_REPO[$id]}" ;;
    local_path)         printf '%s\n' "${_MMB_TARGET_LOCAL_PATH[$id]}" ;;
    worker_profile)     printf '%s\n' "${_MMB_TARGET_WORKER_PROFILE[$id]}" ;;
    agent_layer)        printf '%s\n' "${_MMB_TARGET_AGENT_LAYER[$id]}" ;;
    tracked_by_logger)  printf '%s\n' "${_MMB_TARGET_TRACKED_BY_LOGGER[$id]}" ;;
    *)
      _mmb_targets_err "campo desconhecido: $field (use dest|repo|local_path|worker_profile|agent_layer|tracked_by_logger)"
      return 2
      ;;
  esac
}

# Açúcar: repo GH do target.
mmb_target_repo() {
  mmb_target_field "${1:-}" repo
}

# Açúcar: caminho absoluto local do target (MMB_ROOT/local_path).
mmb_target_path() {
  local id="${1:-}"
  local lp
  lp=$(mmb_target_field "$id" local_path) || return $?
  printf '%s\n' "$MMB_ROOT/$lp"
}

# Validador semântico (chamado pelo test, mas usável standalone).
# Checa: schema OK, unicidade, filesystem coerente, agent_layer válido,
# worker_profile existe em .tooling/profiles/, regressão guard contra
# `core` aparecer no registry.
# Exit 0 = válido, 1 = erro (mensagens em stderr).
mmb_targets_validate() {
  _mmb_targets_ensure_loaded || return 1

  local rc=0
  local id

  # Unicidade de id, dest, repo.
  local ids="" dests="" repos=""
  for id in $_MMB_TARGETS_IDS; do
    case " $ids "  in *" $id "*)                      _mmb_targets_err "id duplicado: $id"; rc=1 ;; esac
    case " $dests " in *" ${_MMB_TARGET_DEST[$id]} "*) _mmb_targets_err "dest duplicado: ${_MMB_TARGET_DEST[$id]}"; rc=1 ;; esac
    case " $repos " in *" ${_MMB_TARGET_REPO[$id]} "*) _mmb_targets_err "repo duplicado: ${_MMB_TARGET_REPO[$id]}"; rc=1 ;; esac
    ids="$ids $id"
    dests="$dests ${_MMB_TARGET_DEST[$id]}"
    repos="$repos ${_MMB_TARGET_REPO[$id]}"
  done

  # id matches ^[a-z][a-z0-9-]{1,30}$
  for id in $_MMB_TARGETS_IDS; do
    if ! [[ "$id" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
      _mmb_targets_err "id inválido (esperado ^[a-z][a-z0-9-]{1,30}\$): $id"
      rc=1
    fi
  done

  # agent_layer ∈ {master, project, atomic}
  for id in $_MMB_TARGETS_IDS; do
    case "${_MMB_TARGET_AGENT_LAYER[$id]}" in
      master|project|atomic) ;;
      *) _mmb_targets_err "target $id: agent_layer inválido '${_MMB_TARGET_AGENT_LAYER[$id]}'"; rc=1 ;;
    esac
  done

  # worker_profile existe em .tooling/profiles/
  for id in $_MMB_TARGETS_IDS; do
    local prof="$MMB_ROOT/.tooling/profiles/${_MMB_TARGET_WORKER_PROFILE[$id]}"
    if [ ! -f "$prof" ]; then
      _mmb_targets_err "target $id: worker_profile não existe ($prof)"
      rc=1
    fi
  done

  # local_path/.git existe (repo git)
  for id in $_MMB_TARGETS_IDS; do
    local lp="$MMB_ROOT/${_MMB_TARGET_LOCAL_PATH[$id]}"
    if [ ! -d "$lp/.git" ]; then
      _mmb_targets_err "target $id: local_path/.git não existe ($lp/.git)"
      rc=1
    fi
  done

  # Regressão guard: 'core' não pode aparecer em ids/dests/repos.
  for tok in $_MMB_TARGETS_IDS $dests $repos; do
    case "$tok" in
      core|mmb-core)
        _mmb_targets_err "regressão: '$tok' apareceu no registry (era lixo morto)"
        rc=1
        ;;
    esac
  done

  return $rc
}
