#!/usr/bin/env python3
"""aquario-bridge — andaime publisher pro mmb-aquarium.

Escuta sinais do andaime MMB em runtime e publica AppMessages no relay
WebSocket do aquário (ws-relay.mjs). Workers stateless e atômicos viram
"criaturas" visíveis no aquário PixiJS.

Mapeamento (decidido na entrevista round 2 de 2026-05-15):

  WORKERS (orq core/cockpit/aquarium):
    commd.log "dispatch: dest=X file=Y"         -> event/born
    workers/<dest>.log "worker X DONE"          -> event/died_happy
    workers/<dest>.log "worker X EXIT=N" (N!=0) -> event/died_defeated

  ATÔMICOS:
    agents.jsonl ev=spawn parent in {orq}       -> event/born
    state/heartbeats/<id>.alive mtime fresca    -> state {health: ~1.0}
    state/heartbeats/<id>.alive mtime atrasada  -> event/freaking_out
    journal.jsonl event=pr-opened               -> event/died_happy
    agents.jsonl ev=deregister reason!=pr-open  -> event/died_defeated

  Convenção de nome (no AppMessage.name):
    worker  -> "[W] worker-<dest>-<pid>"
    atomic  -> "[A] atomic-<task-id>"
    (mmb-core publishers do futuro usam name livre sem prefixo).

Uso:
  aquario-bridge.py                # roda foreground
  RELAY_URL=ws://host:PORT/path aquario-bridge.py

Saída: logs por stderr (vai pra logs/aquario-bridge.log via redirect
no up.sh). Sem PID file — vida atrelada ao processo/tab tmux.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any

import websockets

# ─── Configuração ────────────────────────────────────────────────────────

TOOLING_DIR = Path(__file__).resolve().parent.parent
STATE_DIR = TOOLING_DIR / "state"
LOGS_DIR = TOOLING_DIR / "logs"
HEARTBEATS_DIR = STATE_DIR / "heartbeats"

COMMD_LOG = LOGS_DIR / "commd.log"
WORKERS_DIR = LOGS_DIR / "workers"
AGENTS_JSONL = STATE_DIR / "agents.jsonl"
JOURNAL_JSONL = LOGS_DIR / "journal.jsonl"

RELAY_URL = os.environ.get("RELAY_URL", "ws://localhost:8080/ws")
HEARTBEAT_TIMEOUT = int(os.environ.get("MMB_HEARTBEAT_TIMEOUT", "600"))
HEARTBEAT_POLL_INTERVAL = 5  # segundos
ORQ_NAMES = {"master", "core", "cockpit", "aquarium"}


def log(msg: str) -> None:
    """Log estruturado mínimo — stderr pra não poluir stdout (que é livre)."""
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


# ─── Fila e cliente WebSocket ─────────────────────────────────────────────


async def ws_sender(queue: "asyncio.Queue[dict[str, Any]]") -> None:
    """Drena a queue e publica cada item no relay. Auto-reconnect."""
    backoff = 1.0
    while True:
        try:
            log(f"ws: connecting to {RELAY_URL}")
            async with websockets.connect(RELAY_URL) as ws:
                log("ws: connected")
                backoff = 1.0
                while True:
                    msg = await queue.get()
                    await ws.send(json.dumps(msg))
                    log(f"ws: sent {msg.get('type')}/{msg.get('kind', msg.get('id', '?'))}")
        except (
            ConnectionRefusedError,
            websockets.exceptions.ConnectionClosed,
            OSError,
        ) as e:
            log(f"ws: disconnected ({type(e).__name__}: {e}); retry in {backoff}s")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


# ─── Tail de arquivo append-only (linha a linha) ──────────────────────────


async def tail_file(path: Path, on_line) -> None:
    """Segue um arquivo append-only. Chama on_line(line) por nova linha.

    Politica:
      - Se arquivo não existe, espera até criar.
      - Começa do FIM (não reprocessa histórico).
      - Re-abre se truncar (mtime/size shrink).
      - Cooperativo via asyncio.sleep entre reads.
    """
    while True:
        if not path.exists():
            log(f"tail: aguardando criação de {path}")
            await asyncio.sleep(2)
            continue
        try:
            with path.open("r", encoding="utf-8", errors="replace") as f:
                f.seek(0, 2)  # EOF
                last_size = f.tell()
                log(f"tail: seguindo {path} (size={last_size})")
                while True:
                    line = f.readline()
                    if line:
                        try:
                            on_line(line.rstrip("\n"))
                        except Exception as e:
                            log(f"tail: handler erro em {path}: {e}")
                        continue
                    # Sem mais linhas — checa truncate
                    await asyncio.sleep(0.5)
                    try:
                        cur_size = path.stat().st_size
                    except FileNotFoundError:
                        log(f"tail: {path} sumiu, re-abrindo")
                        break
                    if cur_size < last_size:
                        log(f"tail: {path} truncou ({last_size}->{cur_size}), re-abrindo")
                        break
                    last_size = cur_size
        except Exception as e:
            log(f"tail: erro abrindo {path}: {e}; retry em 2s")
            await asyncio.sleep(2)


# ─── Parsers ──────────────────────────────────────────────────────────────

# commd.log: "[2026-05-15T03:14:55Z] dispatch: dest=aquarium file=...."
RE_DISPATCH = re.compile(
    r"\] dispatch: dest=(?P<dest>\S+) file=(?P<file>\S+)"
)

# workers/<dest>.log: "[ts] worker <dest> DONE", "EXIT=N", ou "TIMEOUT after Ns"
RE_WORKER_DONE = re.compile(
    r"\] worker (?P<dest>\S+) DONE\s*$"
)
RE_WORKER_EXIT = re.compile(
    r"\] worker (?P<dest>\S+) EXIT=(?P<code>\d+)\s*$"
)
RE_WORKER_TIMEOUT = re.compile(
    r"\] worker (?P<dest>\S+) TIMEOUT after \d+s\s*$"
)
# Cabeçalho do worker tem o pid: "[ts] worker <dest> pid=NNNN"
RE_WORKER_HEAD = re.compile(
    r"\] worker (?P<dest>\S+) pid=(?P<pid>\d+)\s*$"
)


class Bridge:
    """Estado mínimo + tradução pra AppMessage."""

    def __init__(self, queue: "asyncio.Queue[dict[str, Any]]"):
        self.queue = queue
        # worker_pid_by_dest: pra associar DONE/EXIT ao born correto
        self.worker_pid_by_dest: dict[str, deque[int]] = {}
        # active_workers: id -> {file, name}
        self.active_workers: dict[str, dict[str, Any]] = {}
        # active_atomics: id -> {name, task, last_health, last_state}
        self.active_atomics: dict[str, dict[str, Any]] = {}

    # ── Workers ──────────────────────────────────────────────────────────

    def on_commd_line(self, line: str) -> None:
        m = RE_DISPATCH.search(line)
        if not m:
            return
        dest = m.group("dest")
        file_basename = m.group("file")
        # PID real do worker virá no header do log do worker (event-pid).
        # Aqui só lembramos que houve dispatch; o "born" emite no worker.log.

    def on_worker_log_line(self, dest: str, line: str) -> None:
        # Header com pid → emite born
        m = RE_WORKER_HEAD.search(line)
        if m:
            pid = int(m.group("pid"))
            wid = f"worker-{dest}-{pid}"
            self.active_workers[wid] = {"dest": dest, "pid": pid}
            self.queue.put_nowait({
                "type": "event",
                "id": wid,
                "kind": "born",
                "name": f"[W] {wid}",
                "task": f"processing in {dest}",
            })
            self.worker_pid_by_dest.setdefault(dest, deque()).append(pid)
            return
        # DONE → died_happy do worker mais antigo desse dest
        m = RE_WORKER_DONE.search(line)
        if m:
            self._finish_worker(dest, kind="died_happy")
            return
        # TIMEOUT after Ns → died_defeated (worker estourou MMB_WORKER_TIMEOUT,
        # commd já moveu pra .dead/). Tem que vir antes do EXIT porque o
        # worker.sh loga TIMEOUT em vez de EXIT=124/137 quando timeout.
        m = RE_WORKER_TIMEOUT.search(line)
        if m:
            self._finish_worker(dest, kind="died_defeated")
            return
        # EXIT=N → died_defeated
        m = RE_WORKER_EXIT.search(line)
        if m:
            self._finish_worker(dest, kind="died_defeated")
            return

    def _finish_worker(self, dest: str, kind: str) -> None:
        q = self.worker_pid_by_dest.get(dest)
        if not q:
            log(f"finish: nenhum worker ativo pra dest={dest}")
            return
        pid = q.popleft()
        wid = f"worker-{dest}-{pid}"
        self.active_workers.pop(wid, None)
        self.queue.put_nowait({
            "type": "event",
            "id": wid,
            "kind": kind,
        })

    # ── Atômicos (via agents.jsonl) ──────────────────────────────────────

    def on_agents_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            log(f"agents: JSON inválido: {line[:80]}")
            return
        kind = ev.get("ev")
        aid = ev.get("id")
        if not aid or aid in ORQ_NAMES:
            # Só interessa atômicos (não os próprios orqs)
            return
        if kind == "spawn":
            task = ev.get("task", "")
            epic = ev.get("epic", "")
            aqid = f"atomic-{aid}"
            self.active_atomics[aid] = {
                "task": task,
                "epic": epic,
                "born_at": time.time(),
                "last_state_health": None,
            }
            self.queue.put_nowait({
                "type": "event",
                "id": aqid,
                "kind": "born",
                "name": f"[A] {aid}",
                "task": task or epic or "(no task)",
            })
        elif kind == "deregister":
            if aid not in self.active_atomics:
                return
            reason = ev.get("reason", "")
            aqid = f"atomic-{aid}"
            self.active_atomics.pop(aid, None)
            kind_out = "died_happy" if "pr-opened" in reason else "died_defeated"
            self.queue.put_nowait({
                "type": "event",
                "id": aqid,
                "kind": kind_out,
            })

    # ── Atômicos (via journal.jsonl — pr-opened) ─────────────────────────

    def on_journal_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            return
        if ev.get("event") != "pr-opened":
            return
        task = ev.get("task", "")
        # task no journal vem como o ID que agents.sh usa (ex: aquarium-1.1)
        if task not in self.active_atomics:
            log(f"journal: pr-opened pra task '{task}' sem registro ativo; emite mesmo assim")
        aqid = f"atomic-{task}"
        self.active_atomics.pop(task, None)
        self.queue.put_nowait({
            "type": "event",
            "id": aqid,
            "kind": "died_happy",
        })

    # ── Heartbeats (poll) ────────────────────────────────────────────────

    async def heartbeat_loop(self) -> None:
        """Roda em background; pra cada atômico ativo, calcula health e
        emite state ou freaking_out conforme heartbeat."""
        while True:
            await asyncio.sleep(HEARTBEAT_POLL_INTERVAL)
            now = time.time()
            for aid, meta in list(self.active_atomics.items()):
                hb_file = HEARTBEATS_DIR / f"{aid}.alive"
                if not hb_file.exists():
                    continue
                try:
                    age = now - hb_file.stat().st_mtime
                except FileNotFoundError:
                    continue
                aqid = f"atomic-{aid}"
                if age > HEARTBEAT_TIMEOUT:
                    # zumbi
                    if meta.get("last_state_health") != "freaking":
                        meta["last_state_health"] = "freaking"
                        self.queue.put_nowait({
                            "type": "event",
                            "id": aqid,
                            "kind": "freaking_out",
                        })
                else:
                    # health = 1 - (age / TIMEOUT)
                    h = max(0.0, min(1.0, 1.0 - (age / HEARTBEAT_TIMEOUT)))
                    # Só emite se mudou meaningfully (delta > 0.1)
                    last = meta.get("last_state_health")
                    if isinstance(last, str) or last is None or abs(last - h) > 0.1:
                        meta["last_state_health"] = h
                        self.queue.put_nowait({
                            "type": "state",
                            "id": aqid,
                            "health": h,
                        })


# ─── Main ─────────────────────────────────────────────────────────────────


async def main() -> None:
    log(f"aquario-bridge inicializando")
    log(f"  RELAY_URL={RELAY_URL}")
    log(f"  TOOLING_DIR={TOOLING_DIR}")
    log(f"  HEARTBEAT_TIMEOUT={HEARTBEAT_TIMEOUT}s")

    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
    bridge = Bridge(queue)

    # Garante diretórios/arquivos pra tail não falhar
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    WORKERS_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    HEARTBEATS_DIR.mkdir(parents=True, exist_ok=True)
    COMMD_LOG.touch(exist_ok=True)
    AGENTS_JSONL.touch(exist_ok=True)
    JOURNAL_JSONL.touch(exist_ok=True)

    tasks = [
        asyncio.create_task(ws_sender(queue), name="ws_sender"),
        asyncio.create_task(
            tail_file(COMMD_LOG, bridge.on_commd_line), name="tail_commd"
        ),
        asyncio.create_task(
            tail_file(AGENTS_JSONL, bridge.on_agents_line), name="tail_agents"
        ),
        asyncio.create_task(
            tail_file(JOURNAL_JSONL, bridge.on_journal_line), name="tail_journal"
        ),
        asyncio.create_task(bridge.heartbeat_loop(), name="heartbeat_loop"),
    ]

    # Tails dos worker logs (um por papel)
    for dest in ("master", "core", "cockpit", "aquarium"):
        log_path = WORKERS_DIR / f"{dest}.log"
        log_path.touch(exist_ok=True)
        # closure: captura dest por argumento default
        def make_handler(d=dest):
            return lambda line: bridge.on_worker_log_line(d, line)
        tasks.append(
            asyncio.create_task(
                tail_file(log_path, make_handler()),
                name=f"tail_worker_{dest}",
            )
        )

    log(f"bridge: {len(tasks)} tasks rodando")

    try:
        await asyncio.gather(*tasks)
    except (KeyboardInterrupt, asyncio.CancelledError):
        log("bridge: shutdown")
        for t in tasks:
            t.cancel()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
