#!/usr/bin/env bash
# Agent registry append-only do andaime MMB (v0.1).
#
# Mantém estado vivo dos agentes (master, orqs locais, atômicos) num
# log append-only em .tooling/state/agents.jsonl + heartbeats em
# .tooling/state/heartbeats/<id>.alive (mtime).
#
# Filosofia: estado atual = redução do log. Mesma filosofia do
# inbox/ e do journal futuro. À prova de race via flock.
#
# Uso:
#   agents.sh register   <id> <parent> <pane> [task] [epic] [model]
#   agents.sh deregister <id> <reason>
#   agents.sh heartbeat  <id>
#   agents.sh list       [--all]              # default: vivos; --all: tudo
#   agents.sh status     <id>
#   agents.sh check-children <parent> [--threshold seconds]
#
# Schema do registry (JSON Lines, uma entrada por linha):
#   {"ts":"<ISO8601>","ev":"spawn|deregister|heartbeat",
#    "id":"<agent-id>","parent":"<parent-id>","pane":"<tmux-ref>",
#    "pid":<int>,"task":"<id>","epic":"<slug>","reason":"<str>"}
#
# Convenções:
# - agent-id de orq:     master | core | cockpit | aquarium | logger
# - agent-id de atômico: <repo-short>-<task-id> (ex: core-X1)

set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLING_DIR/config.sh"

STATE_DIR="$TOOLING_DIR/state"
REGISTRY="$STATE_DIR/agents.jsonl"
HEARTBEATS_DIR="$STATE_DIR/heartbeats"
LOCK="$STATE_DIR/.registry.lock"

mkdir -p "$STATE_DIR" "$HEARTBEATS_DIR"
[ -f "$REGISTRY" ] || : > "$REGISTRY"

# ── Helpers ───────────────────────────────────────────────────────

# Escreve evento no registry de forma atomic via flock.
# Args: <json-string>
_append_event() {
  local json="$1"
  (
    flock --timeout 5 9 || { echo "agents.sh: flock timeout em $LOCK" >&2; exit 11; }
    printf '%s\n' "$json" >> "$REGISTRY"
  ) 9>>"$LOCK"
}

# Escapa string pra JSON (aspas, backslash, controle).
_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Monta uma linha JSON a partir de pares key=value (string).
# Args: ts ev id [parent=...] [pane=...] [pid=...] [task=...] [epic=...] [reason=...]
_build_json() {
  local ts="$1" ev="$2" id="$3"; shift 3
  printf '{"ts":"%s","ev":"%s","id":"%s"' \
    "$(_json_str "$ts")" "$(_json_str "$ev")" "$(_json_str "$id")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    [ -z "$val" ] && continue
    if [[ "$key" == "pid" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
      printf ',"%s":%s' "$key" "$val"
    else
      printf ',"%s":"%s"' "$key" "$(_json_str "$val")"
    fi
  done
  printf '}'
}

# Reduz o registry: pra cada ID, mantém o ÚLTIMO evento.
# Saída: JSONL com 1 linha por ID (sua última transição).
_reduce_last() {
  awk '
    {
      # Extrai "id":"..." da linha. Match POSIX.
      if (match($0, /"id":"[^"]*"/)) {
        idstr = substr($0, RSTART+6, RLENGTH-7)
        last[idstr] = $0
      }
    }
    END { for (k in last) print last[k] }
  ' "$REGISTRY"
}

# Extrai um campo escalar (string ou número) de uma linha JSON simples.
# Args: <json-line> <campo>
_field() {
  local line="$1" field="$2"
  # String: "field":"value"
  local val
  val=$(printf '%s' "$line" \
    | grep -oE "\"${field}\":\"[^\"]*\"" \
    | head -1 \
    | sed -E "s/.*\"${field}\":\"([^\"]*)\".*/\1/" || true)
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return
  fi
  # Número: "field":123
  printf '%s' "$line" \
    | grep -oE "\"${field}\":[0-9]+" \
    | head -1 \
    | sed -E "s/.*\"${field}\":([0-9]+).*/\1/" || true
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Comandos ──────────────────────────────────────────────────────

cmd_register() {
  local id="${1:-}" parent="${2:-}" pane="${3:-}" task="${4:-}" epic="${5:-}" model="${6:-}"
  if [ -z "$id" ] || [ -z "$parent" ] || [ -z "$pane" ]; then
    echo "Uso: agents.sh register <id> <parent> <pane> [task] [epic] [model]" >&2
    exit 2
  fi
  local pid="${MMB_AGENT_PID:-$$}"
  local json
  json=$(_build_json "$(_now_iso)" "spawn" "$id" \
    "parent=$parent" "pane=$pane" "pid=$pid" "task=$task" "epic=$epic" "model=$model")
  _append_event "$json"
  : > "$HEARTBEATS_DIR/$id.alive"
  echo "✓ registered: $id (parent=$parent pane=$pane${model:+ model=$model})"
}

cmd_deregister() {
  local id="${1:-}" reason="${2:-}"
  if [ -z "$id" ] || [ -z "$reason" ]; then
    echo "Uso: agents.sh deregister <id> <reason>" >&2
    exit 2
  fi
  local json
  json=$(_build_json "$(_now_iso)" "deregister" "$id" "reason=$reason")
  _append_event "$json"
  rm -f "$HEARTBEATS_DIR/$id.alive"
  echo "✓ deregistered: $id ($reason)"
}

cmd_heartbeat() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "Uso: agents.sh heartbeat <id>" >&2
    exit 2
  fi
  : > "$HEARTBEATS_DIR/$id.alive"
}

cmd_list() {
  local mode="vivos"
  [ "${1:-}" = "--all" ] && mode="todos"

  printf '%-20s %-10s %-12s %-12s %s\n' \
    "ID" "STATUS" "PARENT" "TASK" "ÚLTIMO HEARTBEAT"
  printf '%s\n' "$(printf -- '-%.0s' {1..78})"

  local line id ev parent task hb_path hb_age
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    id=$(_field "$line" "id")
    ev=$(_field "$line" "ev")
    parent=$(_field "$line" "parent")
    task=$(_field "$line" "task")

    if [ "$ev" = "spawn" ]; then
      hb_path="$HEARTBEATS_DIR/$id.alive"
      if [ -f "$hb_path" ]; then
        local mt now
        mt=$(stat -c %Y "$hb_path" 2>/dev/null || stat -f %m "$hb_path")
        now=$(date +%s)
        hb_age="$((now - mt))s atrás"
      else
        hb_age="(sem heartbeat)"
      fi
      printf '%-20s %-10s %-12s %-12s %s\n' \
        "$id" "vivo" "${parent:--}" "${task:--}" "$hb_age"
    elif [ "$mode" = "todos" ]; then
      printf '%-20s %-10s %-12s %-12s %s\n' \
        "$id" "$ev" "${parent:--}" "${task:--}" "—"
    fi
  done < <(_reduce_last | sort)
}

cmd_status() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "Uso: agents.sh status <id>" >&2
    exit 2
  fi
  local line
  line=$(_reduce_last | grep "\"id\":\"$id\"" | head -1 || true)
  if [ -z "$line" ]; then
    echo "agent '$id' não encontrado no registry."
    exit 3
  fi
  echo "$line"
  local hb="$HEARTBEATS_DIR/$id.alive"
  if [ -f "$hb" ]; then
    local mt now
    mt=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb")
    now=$(date +%s)
    echo "heartbeat_age: $((now - mt))s"
  else
    echo "heartbeat: ausente"
  fi
}

cmd_check_children() {
  local parent="${1:-}"
  local threshold="${MMB_HEARTBEAT_TIMEOUT:-600}"
  if [ "${2:-}" = "--threshold" ] && [ -n "${3:-}" ]; then
    threshold="$3"
  fi
  if [ -z "$parent" ]; then
    echo "Uso: agents.sh check-children <parent> [--threshold seconds]" >&2
    exit 2
  fi

  local found_stuck=0
  local line id ev p_ev hb mt now age
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ev=$(_field "$line" "ev")
    [ "$ev" != "spawn" ] && continue
    p_ev=$(_field "$line" "parent")
    [ "$p_ev" != "$parent" ] && continue
    id=$(_field "$line" "id")
    hb="$HEARTBEATS_DIR/$id.alive"
    if [ ! -f "$hb" ]; then
      echo "STUCK: $id (sem heartbeat algum)"
      found_stuck=1
      continue
    fi
    mt=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb")
    now=$(date +%s)
    age=$((now - mt))
    if [ "$age" -gt "$threshold" ]; then
      echo "STUCK: $id (heartbeat ${age}s > threshold ${threshold}s)"
      found_stuck=1
    fi
  done < <(_reduce_last)

  if [ "$found_stuck" -eq 0 ]; then
    echo "OK: nenhum filho zumbi sob '$parent' (threshold ${threshold}s)"
  fi
  return $found_stuck
}

# ── Dispatch ──────────────────────────────────────────────────────

CMD="${1:-}"
shift || true

case "$CMD" in
  register)        cmd_register "$@" ;;
  deregister)      cmd_deregister "$@" ;;
  heartbeat)       cmd_heartbeat "$@" ;;
  list)            cmd_list "$@" ;;
  status)          cmd_status "$@" ;;
  check-children)  cmd_check_children "$@" ;;
  ""|-h|--help|help)
    cat <<'EOF'
agents.sh — Agent registry do andaime MMB (v0.1)

Comandos:
  register   <id> <parent> <pane> [task] [epic]
  deregister <id> <reason>
  heartbeat  <id>
  list       [--all]
  status     <id>
  check-children <parent> [--threshold seconds]

Schema do registry: .tooling/state/agents.jsonl (append-only).
Heartbeats: .tooling/state/heartbeats/<id>.alive (mtime).
EOF
    [ -z "$CMD" ] && exit 1 || exit 0
    ;;
  *)
    echo "agents.sh: comando desconhecido '$CMD'. Use --help." >&2
    exit 2
    ;;
esac
