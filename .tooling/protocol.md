# Protocolo de comunicação entre sessões — MMB v3

> **⚠️ Atualização v0.3+ — workers stateless.** A peça "ping via
> `tmux send-keys`" foi removida. O wakeup do destinatário é
> responsabilidade do **`commd.sh`** — daemon central que faz
> `inotifywait` em `.tooling/inbox/` e dispara worker stateless
> (`worker.sh <dest> <file>`) por mensagem nova. Workers usam
> `claude -p` (modo print), processam UMA mensagem e morrem.
>
> Implicações:
> - Orq locais não são mais sessões Claude vivas; tabs `core/cockpit/aquarium`
>   do tmux viram só `tail -F` dos logs de worker.
> - Master continua sessão Claude interativa (Rick conversa com ele).
> - Atômicos continuam como estavam (panes efêmeros, open-pr.sh, kill-pane).
> - `msg.sh` continua sendo o helper único de envio — mas só grava
>   arquivo; não faz mais `tmux send-keys`.
>
> O resto deste doc descreve o modelo conceitual de mensageria
> (tipos, frontmatter, fluxos) que continua válido. Onde fala em
> "ping" / "polling-on-every-turn" / "session viva", é texto
> histórico — o commd cobre o que aquilo cobria, com mais robustez.

## Por que este doc existe

Sessões Claude são silos. Não há API nativa de "enviar mensagem
de uma sessão pra outra". O Claude Code CLI também não expõe
inter-session messaging.

Pra remover Rick do loop de relay humano, definimos este
protocolo de mensageria assíncrona baseado em **filesystem
+ daemon central (`commd`) + workers efêmeros (`claude -p`)**.

## Topologia

```
┌─────────────────────────────────────────────────────────────┐
│  RICK                                                        │
│  ↕ (conversa só com Mestre)                                  │
│                                                              │
│  MASTER (tab tmux: master)                                   │
│  ↕ (via msg.sh + inbox/master/)                              │
│                                                              │
│  CORE / COCKPIT / AQUARIUM (tabs respectivas)                │
│  ↓ (cria sub-issue no GitHub, spawna atômico)                │
│                                                              │
│  ATÔMICOS (panes efêmeros nas tabs dos projetos)             │
│  → leem issue como prompt, executam, abrem PR, encerram      │
│                                                              │
│  Rick revisa PR → mergeia                                    │
└─────────────────────────────────────────────────────────────┘
```

**Atômicos não participam do protocolo de mensagens.** Eles
recebem brief como prompt inicial via tmux send-keys e morrem
ao abrir PR.

## Estrutura física

```
.tooling/inbox/
├── master/       ← mensagens recebidas pelo Mestre
├── core/         ← recebidas pelo Orq de mmb-core
├── cockpit/      ← recebidas pelo Orq de mmb-cockpit
└── aquarium/     ← recebidas pelo Orq de mmb-aquarium
```

Cada arquivo é uma mensagem completa com frontmatter + corpo.
Nome do arquivo é ordenável por timestamp natural:

```
YYYY-MM-DDTHH-MM-SSZ_<from>_<type>_<subject-slug>.md
```

Exemplos:
- `2026-05-14T16-32-00Z_master_briefing_cleanup-scripts.md`
- `2026-05-14T16-45-12Z_core_status_pr-aberto-3.md`
- `2026-05-14T16-50-00Z_master_answer_brief-ambiguidade.md`

## Schema de mensagem

```markdown
---
from: <master|core|cockpit|aquarium>
to: <master|core|cockpit|aquarium>
type: <briefing|question|answer|status|error>
subject: <kebab-case-curto>
thread: <épico-slug ou conversation-id>   # opcional
created: <ISO8601 UTC>
---

# Corpo livre em markdown
```

### Tipos de mensagem

| Type | Quem envia | Pra quem | Pra quê |
|---|---|---|---|
| `briefing` | master | orq local | Trabalho novo: faça issue + spawn atômico |
| `question` | orq local | master | Brief ambíguo / decisão fora do meu escopo |
| `answer` | master | orq local | Resposta a uma `question` |
| `status` | orq local | master | Marco: issue criada / PR aberto / PR mergeado / task fechada |
| `error` | qualquer | master | Algo quebrou: spawn falhou, push rejeitado, etc |
| `propose` | filho | parent | "sugiro estender escopo / mudar abordagem" (v0.1+) |
| `accept-proposal` | parent | filho | "aceito a proposta, prossiga" (v0.1+) |
| `reject-proposal` | parent | filho | "rejeito; mantém escopo original" (v0.1+) |
| `cancel` | parent | filho | "abandone a task atual" (v0.1+) |

### Contrato semântico dos `status` (v0.4+)

Mensagens `type: status` carregam marcos do ciclo de vida de uma task.
O `subject` segue convenção `<marco>-<N>`, onde `N` é o número da
issue/PR no GitHub. O **body** tem payload obrigatório por marco —
permite ao worker-master fazer matching exato sem heurística, sem
escalar pending-human por falso positivo.

Payload é markdown livre, mas precisa **conter literalmente** os
campos listados abaixo (uma linha por campo no padrão
`<chave>: <valor>`). Campos opcionais podem vir em prosa adicional.

#### `status: issue-criada-<N>`

Emitido pelo orq local após `gh issue create` materializar a
sub-issue do épico.

| Campo | Forma | Obrigatório |
|---|---|---|
| `issue_url` | URL absoluta `https://github.com/<owner>/<repo>/issues/<N>` | sim |
| `issue_number` | N (mesmo do subject) | sim |
| `repo` | `mmb-core` \| `mmb-cockpit` \| `mmb-aquarium` \| `mmb-logger` | sim |
| `thread` | slug do épico (mesmo do frontmatter) | sim |

Exemplo de body:
```
issue_url: https://github.com/x-force-42/mmb-cockpit/issues/15
issue_number: 15
repo: mmb-cockpit
thread: dark-mode

Atômico 1.1 spawnado em worktree mmb-cockpit/.worktrees/1.1-dark-mode.
```

#### `status: pr-aberto-<N>`

Emitido pelo orq local após detectar que o atômico abriu PR (ou
emitido pelo próprio atômico via `open-pr.sh`, dependendo da fase).
`<N>` é o número do **PR**.

| Campo | Forma | Obrigatório |
|---|---|---|
| `pr_url` | URL absoluta `https://github.com/<owner>/<repo>/pull/<N>` | sim |
| `pr_number` | N (mesmo do subject) | sim |
| `issue_number` | N da sub-issue que o PR fecha | sim |
| `suite_status` | `verde` \| `vermelha` \| `pulada` (justificar `pulada` no PR body) | sim |

Notas:
- Evidência literal da suíte mora no **PR body** (guardrail A11) —
  status só carrega o veredicto resumido. Worker-master usa
  `suite_status` pra decidir se escala (`vermelha`/`pulada` →
  pending-human; `verde` → digest).

#### `status: task-fechada-<id>` / `status: pr-mergeado-<N>`

Emitido pelo orq local após observar merge do PR + cleanup do
worktree (`task-end.sh`).

| Campo | Forma | Obrigatório |
|---|---|---|
| `pr_url` | URL absoluta do PR mergeado | sim |
| `pr_number` | N do PR | sim |
| `issue_number` | N da sub-issue (fechada por `Closes #N`) | sim |
| `merged_at` | ISO8601 UTC do merge (de `gh pr view`) | sim |
| `last_in_epic` | `true` \| `false` — última task do épico? | sim |

`last_in_epic: true` sinaliza ao worker-master que pode propor
fechamento do épico no próximo digest pro Mestre.

#### Status sem schema

`status: <marco>-...` cujo prefixo não esteja na tabela acima é
tratado como livre. Worker-master pode logar `warn` mas não escala.
Adicionar novo marco aqui antes de emitir do orq.

#### Por que schema mínimo, não JSON

Mensagens são markdown lidas por humanos durante debug. JSON puro
quebra o "abro o arquivo e entendo" — chave-valor em linhas separadas
preserva legibilidade e é trivial de parsear via grep/awk no
worker-master.

### Mapeamento informal → FIPA-ACL (v0.1+)

Pra observabilidade futura e alinhamento com literatura
de multi-agent systems, as performativas atuais mapeiam pra
FIPA-ACL assim:

| Nosso  | FIPA-ACL | Speech act |
|---|---|---|
| `briefing`         | `request`         | "execute X" |
| `question`         | `query-if` / `query-ref` | "decida X" |
| `answer`           | `inform-ref`      | "X = Y" |
| `status`           | `inform`          | "informo que Y aconteceu" |
| `error`            | `failure`         | "falhei em X porque Z" |
| `propose`          | `propose`         | proposta |
| `accept-proposal`  | `accept-proposal` | aceitação |
| `reject-proposal`  | `reject-proposal` | rejeição |
| `cancel`           | `cancel`          | cancelamento |

## Polling-on-every-turn é a garantia de entrega (v0.1+)

**Ping é otimização de latência, não fonte da verdade.**
Toda sessão Claude (master, orq, atômico) **lê o próprio inbox
no início de cada turn**, independente de ter recebido ping
ou não. Razão: `tmux send-keys` pode falhar (sessão em
"thinking", input bufferizado sem submit). Polling fecha o gap.

Operacional:
```bash
# No início de cada turn, antes de qualquer ação:
ls -1t .tooling/inbox/$MMB_TAB/ | grep -v '^\.'
```

Arquivos prefixados com `.` (ex: `.lock`) são infra do
protocolo, não mensagens — polling deve ignorar.

Profiles instruem cada papel a fazer esse polling. Guardrails
M5/L8/A6 proíbem pular.

## O ping

`msg.sh` grava o arquivo no inbox do destinatário e envia 2-3
linhas via `tmux send-keys` pra tab dele:

```
MSG [master->core] briefing: cleanup-scripts
  inbox: /home/eliezer/llab/MMB/.tooling/inbox/core/2026-05-14T16-32-00Z_master_briefing_cleanup-scripts.md
```

**Por que o ping é ASCII puro (sem emoji, sem aspas):** o
`tmux send-keys` atravessa shell layers. Quanto mais simples o
payload, menor o risco de quoting bug. Prefixo `MSG ` é
distintivo o suficiente pros profiles instruírem agentes a
reconhecer.

Profiles ensinam: "quando você ver linha começando com `MSG `
seguida de `inbox: <path>`, leia o arquivo e aja conforme o
`type`."

## Helper único: `msg.sh`

Único ponto de envio. Centraliza:
- Validação de campos (`to`, `type`).
- Detecção do remetente (via env `MMB_TAB` ou nome da tab tmux).
- Escrita atômica do arquivo, **serializada por `flock(1)`**
  (v0.1+) — múltiplos remetentes concorrentes ao mesmo inbox
  não corrompem nada.
- Envio do ping pra tab correta (window 0, sempre — orq local
  mora ali; atômicos vivem em panes >0 e não recebem mensagens).

Uso:
```bash
msg.sh <to> <type> <subject-slug> <body-file> [thread]
```

## Fluxos canônicos

### Fluxo 1 — briefing single-repo

```
Rick → master pane: "limpar scripts X do mmb-core"
master:
  1. lê repo read-only
  2. produz briefing em .tooling/intents/<date>-<slug>/briefing-core.md
  3. msg.sh core briefing <slug> <briefing-file> <slug>

core (recebe ping):
  1. lê arquivo no inbox
  2. lê briefing apontado (ou inline, depende)
  3. cria sub-issue no GitHub (labels: task, project:mmb-core)
  4. spawn-atomic.sh mmb-core <id> <issue-number>
  5. msg.sh master status issue-criada <body> <slug>

atômico (pane novo):
  1. lê issue como prompt
  2. executa, commita, push
  3. open-pr.sh → push + gh pr create + kill-pane em 8s

core (detecta PR):
  msg.sh master status pr-aberto <body> <slug>

Rick → revisa PR, mergeia.

core (próxima vez que checar):
  1. task-end.sh
  2. msg.sh master status task-fechada <body> <slug>

master:
  marca épico como fechado em .tooling/intents/<date>-<slug>/
```

### Fluxo 2 — escalação de dúvida

```
core (lendo briefing):
  "esse brief diz pra rename X mas X é importado por Y em outro repo
   — fora do escopo da minha task, escalando"

core: msg.sh master question rename-cross-repo <pergunta> <thread>

master (recebe ping):
  1. lê pergunta
  2. avalia: pode decidir sozinho?
     - se sim: msg.sh core answer rename-cross-repo <decisão>
     - se não: conversa com Rick na própria tab master
  3. responde

core (recebe answer):
  prossegue com a decisão
```

### Fluxo 3 — cross-repo

```
master:
  1. produz briefing mestre em .tooling/intents/<date>-<slug>/master-briefing.md
  2. produz N child briefings (1 por projeto)
  3. msg.sh core briefing <slug> <core-briefing>  thread=<slug>
  4. msg.sh cockpit briefing <slug> <cockpit-briefing>  thread=<slug>
  5. (se houver deps cross-repo, briefings carregam requires)

cada orq local: idem fluxo 1, em paralelo
master: agrega status pelo thread
```

## Garantias e limitações

**Garantias:**
- Ordem natural por timestamp no nome do arquivo.
- Persistência total: mensagens sobrevivem a crash de sessão.
- Audit trail completo em `inbox/`.
- Visibilidade: Rick vê os pings em todas as tabs.

**Limitações conhecidas:**
- **Sem ACK obrigatório:** quem envia não sabe se quem recebeu
  processou. Mitigação primária: polling-on-every-turn cobre
  o caso "ping perdido"; receptor envia `status` em marcos.
- **Sem retry automático:** mensagens ficam no inbox até serem
  lidas pelo polling do receptor. Pings que não chegaram
  (Claude em thinking, sessão crashada) viram entrega
  garantida no próximo turn.
- **Sem queue size limit:** inbox pode acumular. Cleanup
  manual ou via script futuro.
- **`MMB_TAB` env não está garantido:** detecção via nome de
  window pode falhar se você renomear as tabs. Solução: setar
  `MMB_TAB=master` (ou core/etc) no início de cada sessão via
  `up.sh`.

## Diário de bordo compartilhado (v0.2+)

Além de mensagens entre agentes, o andaime mantém **journal
estruturado de eventos** que merecem retrospectiva:

- `.tooling/logs/journal.jsonl` — append-only, schema v1.
- `.tooling/bin/log.sh` — helper único:
  ```bash
  log.sh <sev> <event> "<msg>" [--epic X] [--task Y] [--resolves <id>]
  ```
- `.tooling/bin/review-cycle.sh <epic-slug>` — agrega + propõe
  fortificações ao fim de cada épico. Master apresenta pro
  Rick, **Rick decide** (anti-overengineering).

**Relação log ↔ msg:**
- `msg.sh` é canal **operacional** (alguém precisa agir agora).
- `log.sh` é canal **de aprendizado** (registra pra agregação
  retrospectiva).
- Erros importantes vão nos dois: `msg.sh master error` pra
  desbloquear + `log.sh error` pra review-cycle ver depois.

**Severidades:** `warn` | `error` | `critical`. Eventos `info`
ficam fora — journal é pra coisas que mereceriam fortificação.

## Agent registry e supervision (v0.1+)

Além do canal de mensagens, o andaime mantém **registro vivo
de agentes**:

- `.tooling/state/agents.jsonl` — log append-only de eventos
  `spawn`/`deregister`. Estado atual = redução do log.
- `.tooling/state/heartbeats/<agent-id>.alive` — touch file,
  mtime indica "vivo recente". Atômicos chamam `agents.sh
  heartbeat` antes de cada commit; orqs chamam no início de
  cada turn ocioso.
- `.tooling/bin/agents.sh` — helper único:
  - `agents.sh register <id> <parent> <pane> [task] [epic]`
  - `agents.sh deregister <id> <reason>`
  - `agents.sh heartbeat <id>`
  - `agents.sh list [--all]`
  - `agents.sh status <id>`
  - `agents.sh check-children <parent> [--threshold N]`

**Convenções de agent-id:**
- Orq mestre: `master`
- Orq de projeto: `core` / `cockpit` / `aquarium`
- Atômico: `<repo-short>-<task-id>` (ex: `core-X1`)

**Supervision tick:** orq local roda `agents.sh check-children
<seu-id>` periodicamente (ver profile do orq). Filhos com
heartbeat > `MMB_HEARTBEAT_TIMEOUT` (default 600s) são
considerados zumbis → `task-abort.sh` automático + `error`
pro mestre.

## Evolução pra MCP (Model Context Protocol)

Este protocolo é deliberadamente simples — FS + ping. Funciona
mas tem limites quando o sistema cresce:

- Sem auth/autorização (qualquer sessão escreve em qualquer
  inbox).
- Sem schema validation além das checagens de `msg.sh`.
- Difícil de estender pra agentes fora da máquina.

Quando isso virar um problema (provavelmente após 5+ épicos
multi-repo paralelos), migrar pra **MCP server custom**:

- Cada Claude session se conecta a um servidor MCP local
  (`stdio` ou HTTP).
- Tools expostas: `send_message(to, type, subject, body)`,
  `list_inbox()`, `read_message(id)`.
- Receptor ainda precisa de algum tipo de notificação ativa
  (MCP é request/response). Mantém `tmux send-keys` ou usa
  long-polling.
- Vantagens: schema typed (pydantic), auth opcional,
  observabilidade via MCP server logs, expansível.

**Caminho de migração:** o conceito (mensagens com type/from/to/body)
sobrevive. O que muda é a implementação do `msg.sh` (vira
chamada de tool MCP) e o read do inbox (vira `list_inbox()` tool).
Profiles e fluxos canônicos seguem idênticos.

Não migrar agora. Migrar quando o custo do FS for maior que o
custo de manter um MCP server.
