# mmb-andaime

Camada de orquestração cross-repo do ecossistema **Mr. Meeseeks Box (MMB)** — um experimento de desenvolvimento de software conduzido por múltiplos agentes Claude coordenados.

> O andaime não tem código de produção. Ele vive *sobre* os 3 repos de produto e os coordena.

---

## A proposta

O MMB investiga uma pergunta prática: **é possível conduzir o ciclo completo de desenvolvimento de software — do levantamento de requisitos ao PR mergeado — usando agentes Claude autônomos, com um humano apenas nos pontos de decisão estratégica?**

O ecossistema tem três produtos reais sendo desenvolvidos em paralelo:

| Repo | Descrição |
|---|---|
| [`mmb-core`](https://github.com/x-force-42/mmb-core) | Bot Discord + API REST + lógica Meeseeks (Python) |
| [`mmb-cockpit`](https://github.com/x-force-42/mmb-cockpit) | SPA de governança do ecossistema (React) |
| [`mmb-aquarium`](https://github.com/x-force-42/mmb-aquarium) | Visualização em tempo real dos agentes (PixiJS + áudio) |

O **andaime** é o que permite que agentes diferentes trabalhem nesses repos sem se atropelar — com rastreabilidade, isolamento e comunicação assíncrona.

---

## Arquitetura

### Hierarquia de agentes (4 camadas)

```
┌─────────────────────────────────────────────────────┐
│  Rick (humano)                                       │
│  Decide estratégia, aprova briefings, revisa PRs     │
└───────────────────┬─────────────────────────────────┘
                    │ conversa natural
┌───────────────────▼─────────────────────────────────┐
│  Master (sessão Claude na raiz /MMB/)                │
│  Recebe intenções, faz discovery, produz briefings,  │
│  coordena os 3 repos, acompanha épicos               │
└───────────────────┬─────────────────────────────────┘
                    │ mailbox (arquivos em .tooling/inbox/)
┌───────────────────▼─────────────────────────────────┐
│  Workers stateless (claude -p por mensagem)          │
│  Um por repo (core / cockpit / aquarium)             │
│  Materializam issues no GitHub, spawnam atômicos     │
└───────────────────┬─────────────────────────────────┘
                    │ git worktree por task
┌───────────────────▼─────────────────────────────────┐
│  Atômicos (claude em worktree efêmera)               │
│  Implementam a task, fazem commit, abrem PR, morrem  │
└─────────────────────────────────────────────────────┘
```

### O barramento de mensagens

O coração do andaime é um daemon simples (`commd.sh`) que assiste os diretórios de inbox com `inotifywait`. Quando o Master (ou qualquer camada) deposita uma mensagem via `msg.sh`, o daemon acorda instantaneamente e despacha um worker stateless (`claude -p`) para processá-la.

```
msg.sh core briefing <slug> <arquivo> <thread>
  └→ escreve .tooling/inbox/core/<ts>_<meta>.md
       └→ commd.sh detecta via inotifywait
            └→ worker.sh core <arquivo>
                 └→ claude -p [profile de orq] [mensagem]
```

Isso resolve o problema fundamental de comunicação: sessões Claude ociosas não acordam com `tmux send-keys`. Workers stateless, por design, só existem quando há trabalho.

### Isolamento por worktree

Cada task atômica roda em uma `git worktree` separada:

```
mmb-core/
├── (main checkout)
└── .worktrees/
    ├── 1.2-auth-refactor/     ← atômico A trabalhando aqui
    └── 1.3-rate-limiting/     ← atômico B trabalhando aqui
```

Dois atômicos podem trabalhar no mesmo repo simultaneamente sem conflito de working tree.

### Visualização em tempo real

O `aquario-bridge` (daemon Python) observa os logs do andaime e traduz eventos de ciclo de vida dos agentes para `AppMessage`, publicando via WebSocket no relay do `mmb-aquarium`. Cada worker que nasce vira uma criatura PixiJS; quando o PR é aberto, ela morre feliz.

```
logs/workers/<dest>.log  ──┐
state/agents.jsonl         ├──→ aquario-bridge.py ──→ ws://localhost:8080/ws ──→ PixiJS
state/heartbeats/*.alive  ─┘
```

---

## Design decisions

**Workers stateless em vez de sessões vivas.** Sessões Claude Code são interativas — o mecanismo de polling só roda dentro de um turn ativo. `claude -p` é um processo que começa, processa e termina. Mais simples, mais confiável, sem estado acumulado entre mensagens.

**Mailbox de arquivos em vez de filas.** Arquivos em disco são legíveis, auditáveis, versionáveis e não precisam de servidor. `inotifywait` é o único daemon necessário para transformar isso em push real.

**Git worktrees em vez de branches locais.** Permite que múltiplos atômicos trabalhem no mesmo repo em paralelo, cada um com seu próprio working directory, sem interferência.

**GitHub como fonte da verdade do estado em-voo.** Issues e PRs são a única fonte canônica do que está acontecendo. O andaime lê o estado via `gh`; não mantém banco de dados próprio.

**Agnosticismo do aquário.** O aquário recebe qualquer publisher que falar o protocolo `AppMessage` via WebSocket. O andaime faz a tradução de vocabulário; o aquário permanece desacoplado.

---

## Estrutura do repositório

```
/
├── CLAUDE.md                        ← instruções para a sessão Master
├── .tooling/
│   ├── bin/
│   │   ├── commd.sh                 ← daemon de despacho (inotifywait)
│   │   ├── worker.sh                ← worker stateless por mensagem
│   │   ├── msg.sh                   ← envia mensagem para inbox de um dest
│   │   ├── task-start.sh            ← cria worktree + branch para task
│   │   ├── task-end.sh              ← cleanup pós-merge
│   │   ├── task-abort.sh            ← cleanup pré-merge (descarta)
│   │   ├── spawn-atomic.sh          ← inicia agente atômico em worktree
│   │   ├── open-pr.sh               ← push + gh pr create (chamado pelo atômico)
│   │   ├── up.sh                    ← sobe sessão tmux com layout padrão
│   │   ├── smoke.sh                 ← testes de sanidade do método
│   │   ├── reset-all.sh             ← reset total do estado em-voo
│   │   ├── aquario-bridge.py        ← bridge de eventos → WebSocket
│   │   └── aquario-bridge.sh        ← wrapper com venv automático
│   ├── profiles/
│   │   ├── master.md                ← modus operandi do Master
│   │   ├── project-orchestrator.md  ← modus operandi dos workers
│   │   └── atomic-agent.md          ← protocolo dos atômicos
│   ├── config.sh                    ← knobs centrais (modelos, owner GH, timeouts)
│   ├── inbox/                       ← mailbox por destinatário
│   │   ├── master/
│   │   ├── core/
│   │   ├── cockpit/
│   │   └── aquarium/
│   ├── state/                       ← registry de agentes + heartbeats (runtime)
│   ├── logs/                        ← logs de workers e daemons (runtime)
│   └── intents/                     ← histórico de épicos (gitignored — runtime)
├── mmb-core/                        ← repo separado (não commitado aqui)
├── mmb-cockpit/                     ← repo separado (não commitado aqui)
└── mmb-aquarium/                    ← repo separado (não commitado aqui)
```

---

## Tecnologias

| Camada | Tecnologia |
|---|---|
| Agentes | [Claude Code CLI](https://claude.ai/code) (`claude`, `claude -p`) |
| Daemon de mensagens | `inotifywait` ([inotify-tools](https://github.com/inotify-tools/inotify-tools)) |
| Automação GitHub | [`gh` CLI](https://cli.github.com/) |
| Sessão / layout | [tmux](https://github.com/tmux/tmux) |
| Bridge de eventos | Python 3.11+ · asyncio · [websockets](https://websockets.readthedocs.io/) |
| Isolamento de tasks | Git worktrees (`git worktree`) |
| Orquestração | Bash puro (sem dependências extras) |

Os 3 repos de produto têm suas próprias stacks (Python/Discord, React, PixiJS) — esse repo não depende delas.

---

## Como rodar

### Pré-requisitos

```bash
# Ferramentas de sistema
sudo apt install inotify-tools tmux

# GitHub CLI autenticado
gh auth login

# Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Python 3.11+ (para aquario-bridge)
# O wrapper aquario-bridge.sh cria o venv automaticamente
```

### Setup inicial

```bash
# Clone os 4 repos lado a lado
git clone git@github.com:x-force-42/mmb-andaime.git MMB
cd MMB
git clone git@github.com:x-force-42/mmb-core.git
git clone git@github.com:x-force-42/mmb-cockpit.git
git clone git@github.com:x-force-42/mmb-aquarium.git

# Configure o GitHub owner se necessário
# edite .tooling/config.sh → MMB_GH_OWNER
```

### Subir o andaime

```bash
# Sobe sessão tmux com Master + commd + logs + aquário
.tooling/bin/up.sh

# Se você já é o Master (sessão Claude externa ao tmux):
.tooling/bin/up.sh --no-master-claude
```

### Smoke test

```bash
# Valida commd → worker → roundtrip (~90s)
.tooling/bin/smoke.sh comm

# Valida bridge → aquário visual (requer mmb-aquarium rodando)
.tooling/bin/smoke.sh aquario
```

### Reset

```bash
# Limpa todo o estado em-voo (PRs, issues, worktrees, inbox, logs)
.tooling/bin/reset-all.sh --yes
```

---

## Contribuindo

O projeto está em evolução ativa. As áreas mais abertas para contribuição:

- **Robustez do commd**: backpressure, dead-letter queue, retry com backoff
- **Métricas**: tempo por fase (discovery → briefing → PR → merge), taxa de falha por camada
- **Portabilidade**: hoje depende de Linux (`inotifywait`); suporte a macOS via `fswatch`
- **Modelos**: experimentos com diferentes modelos por camada (Opus no Master, Sonnet nos workers, Haiku nos atômicos)
- **aquario-bridge**: mais tipos de eventos visuais; integração com métricas de heartbeat

Issues e discussões no [repositório](https://github.com/x-force-42/mmb-andaime/issues).
