# `ontology.md` — linguagem ubíqua do MMB

> **Autoridade.** Este é o contrato de **vocabulário** do MMB. Quando
> qualquer outro doc, profile, script ou schema nomeia um conceito do
> domínio, o nome canônico é o que está aqui. Em caso de divergência,
> este doc vence para a *escolha do termo* — `protocol.md`,
> `source-of-truth.md` e `guardrails.md` continuam vencendo para a
> *semântica* dos seus respectivos domínios.
>
> Este doc **não renomeia nada**. Ele declara os nomes canônicos e marca
> as divergências atuais como dívida (§6). Renames de identificadores,
> colunas de DB e literais load-bearing são tarefas separadas e vetadas,
> fora do escopo desta versão.

## Como usar

1. **Regra bilíngue (disciplinada).** Cada conceito tem **uma** forma PT
   e **uma** forma EN — nenhuma terceira. Use **PT em prosa e método**
   (docs, briefings, conversa com o Rick); use **EN em código e
   identificadores** (vars, funções, campos, enums). Nunca invente um
   sinônimo novo; se faltar um termo, adicione-o aqui primeiro.
2. **Palavras proibidas sem qualificação** (§5): `kind`, `id`,
   `registry`, `worker`, `master`, `ciclo`. Cada uma cobre vários
   conceitos — sempre qualifique (`target kind`, `task-id`, …).
3. **Conjuntos fechados** (§4) são verbatim e load-bearing: o código
   casa contra eles por regex/validação. Não derive variações.

---

## 1. Modelo de entidades

O modelo conceitual é coerente; o que estava fragmentado eram os nomes.
Esta é a forma canônica:

```
Rick (operador humano)
 │  intenção
 ▼
épico  (container de trabalho; slug viaja como `thread` na mensagem)
 │  briefing (spec de trabalho)
 ├── master-briefing      → artefato local, NÃO vira issue
 └── task-briefing        → vira o corpo da issue
                            │
                            ▼
                          issue (GitHub)  →  PR (GitHub)

Papéis (mecanismo entre parênteses):
  Mestre / Master            (sessão Claude interativa na raiz)
   └─ orquestrador de projeto (worker stateless, 1 por target)
       └─ atômico            (Claude efêmero em worktree)
  triador do Mestre          (worker stateless que tria o inbox do Mestre)

Canal:  mailbox (inbox/<dest>) → commd (daemon) → worker (claude -p)
Linkagem: âncora mmb-cycle-key (briefing ↔ issue ↔ PR ↔ transcript)

Projeção do logger:  épico → ciclo → evento
```

`1 épico → N ciclos → N eventos`. O **ciclo** é a unidade de trabalho
*projetada* pelo logger (uma por épico × target × despacho de briefing);
não confundir com o *fluxo* de desenvolvimento nem com o *procedimento*
de N fases de um papel (ver §5, "ciclo").

---

## 2. Glossário canônico

Colunas: **Conceito** · **PT** (prosa) · **EN** (código) · **Definição** ·
**Proibido** (formas a abandonar) · **Nota**.

### 2.1 Sistema e papéis

| Conceito | PT | EN | Definição | Proibido | Nota |
|---|---|---|---|---|---|
| A metodologia (o produto) | **método** | **method** | O conjunto de práticas de orquestração — o produto primário. | — | "o método é o produto; o runtime o instancia" |
| O sistema executável | **andaime** | **runtime** | A aparelhagem que instancia o método (`.tooling/` + daemons + scripts). | "scaffold", "camada cross-repo" como nome próprio | `andaime` é também o nome próprio (repo `mmb-andaime`) |
| Projeto orquestrado | **target** | **target** | Projeto sobre o qual o runtime opera; declarado no target registry. | "projeto-alvo", "repo de produto" como termo técnico | `kind ∈ internal | external | external-fake` |
| Operador | **Rick** / **operador humano** | **human operator** | Quem decide estratégia, aprova briefings, revisa e mergeia PRs. | — | Fala SÓ com o Mestre |
| Agente interativo de topo | **Mestre** | **Master** | Sessão Claude interativa na raiz; único interlocutor do Rick; faz curadoria, discovery, briefing, dispatch, fechamento. | "Orquestrador Mestre", "orq mestre", "Master/Mestre interativo" (só para desambiguar do triador do Mestre) | profile `master.md`; agent-id `master` |
| Triador do inbox do Mestre | **triador do Mestre** | **master triager** | Worker **stateless** que tria mensagens do `inbox/master/` (rotina→digest; senão→pending-human). **NÃO é o Mestre.** | `worker-master`, `master-worker` (aliases legados — dívida §6) | profile `master-worker.md` (nome de arquivo legado) |
| Agente de projeto | **orquestrador de projeto** (curto: **orq**) | **project orchestrator** | Worker stateless, um por target, invocado pelo commd por mensagem; cria sub-issue, spawna atômico, reporta status, escala dúvida. | "orq local", "orquestrador local", "dono executivo", "worker" (como nome do papel) | layer `project`; profile `project-orchestrator.md` |
| Agente executor | **atômico** | **atomic** | Claude efêmero em worktree; lê a issue como prompt, implementa, commita, abre PR, morre. Sem canal de comm. | "task atômica" (como nome do agente — isso é a unidade de trabalho) | layer `atomic`; profile `atomic-agent.md` |
| Projeção retrospectiva | **logger** | **logger** | SQLite + REST que *observa* artefatos canônicos e materializa histórico. Não autoritativo. | — | contrato em `source-of-truth.md` |

### 2.2 Unidades de trabalho

| Conceito | PT | EN | Definição | Proibido | Nota |
|---|---|---|---|---|---|
| Necessidade do Rick | **intenção** | **intent** | A necessidade crua trazida ao Mestre, antes de virar épico. | "necessidade" como termo técnico | `epicos.intencao` = título do master-briefing; o dir `intents/` guarda briefings (misnomer — dívida §6) |
| Container de trabalho | **épico** | **epic** | Unidade que agrega ≥1 briefing/task; identificada por um slug. | "epico" sem acento em prosa | o slug viaja como `thread` na mensagem; `epicos`/`epic:` são os literais |
| Spec de trabalho | **briefing** | **briefing** | Documento que especifica o trabalho. | — | empréstimo; idêntico PT/EN |
| Briefing do Mestre | **master-briefing** | **master-briefing** | Artefato local em `intents/<date>-<slug>/`; **não** vira issue. | "briefing mestre", "briefing local" | template `master-briefing.md` |
| Briefing de task | **task-briefing** | **task-briefing** | Briefing por projeto; vira o corpo da sub-issue (prompt do atômico). | "briefing filho", "child briefing" | template `task-briefing.md` |
| Item formalizado no GitHub | **issue** | **issue** | Sub-issue materializada pelo orq via `create-task-issue.sh`; carrega âncora + labels. | "sub-issue do método" | — |
| Unidade de execução atômica | **task** / **tarefa** | **task** | Unidade discreta feita por um atômico em uma worktree; tem **task-id**. | "micro-task" | task-id `1.1`, `X1`; agent-id `<repo-short>-<task-id>` |
| Artefato de review | **PR** | **PR** (pull request) | Aberto pelo atômico via `open-pr.sh`; `Closes #N`; revisado/mergeado pelo Rick. | — | — |
| Unidade projetada pelo logger | **ciclo** | **cycle** | Linha da tabela `ciclos`: uma por (épico × target × despacho). | "ciclo principal", "ciclo de desenvolvimento" (esses são fluxo/procedimento — §5) | `ciclos.id = <epic>__<project>__<ts>` |
| Registro imutável de evento | **evento** | **event** | Linha da tabela `eventos`; projeção seletiva do journal/agents. | — | `eventos.kind` é enum fechado (§4) |
| Fluxo ponta-a-ponta | **fluxo de desenvolvimento** | **development flow** | O processo requisito→PR mergeado, inteiro. | "ciclo de desenvolvimento", "ciclo de trabalho" | desambigua "ciclo" |

### 2.3 Canal de mensageria

| Conceito | PT | EN | Definição | Proibido | Nota |
|---|---|---|---|---|---|
| Canal assíncrono | **mailbox** | **mailbox** | Mensageria por arquivos: um markdown por mensagem em `inbox/<dest>/`. | "barramento de mensagens", "mensageria" como nome técnico | spec em `protocol.md` |
| Diretório de entrada | **inbox** | **inbox** | `inbox/<dest>/`; também serve de audit trail. | "caixa de saída" | — |
| Destinatário | **destinatário** | **dest** | Endpoint de roteamento: `master` (papel) ou um target id. | — | frontmatter usa campos `to`/`from` (load-bearing) |
| Helper de envio | **msg.sh** | **msg.sh** | Único canal de envio: `msg.sh <to> <type> <subject> <body> [thread]`. | "tmux send-keys" (vetado, M4) | — |
| Daemon de despacho | **commd** | **commd** | `inotifywait` nos inboxes; dispara `worker.sh <dest> <file>` por mensagem nova. | "daemon central/simples/de mensagens" como nome | `commd.sh` |
| Processo efêmero | **worker** | **worker** | O `claude -p` stateless que o commd invoca por mensagem. **É o mecanismo**, não um papel — o papel que ele roda é orq ou triador do Mestre. | "worker" como nome de papel | `worker.sh` |
| Slug de agregação | **thread** | **thread** | Campo de frontmatter que carrega o **epic slug** (mesmo valor que o épico). No fluxo do método, `thread` é sempre o slug do épico. | tratar `thread` como conceito independente de épico no fluxo operacional | usos conversacionais/legados de `thread` NÃO servem para linkagem do logger |
| Âncora de linkagem | **âncora** | **anchor** (`mmb-cycle-key`) | Comentário HTML no corpo da issue; garante linkagem determinística briefing↔issue↔PR↔transcript. | "cycle-key" solto | spec em `source-of-truth.md`; chave `<epic>/<project>/<ts>` |

### 2.4 Estado e autoridade

| Conceito | PT | EN | Definição | Autoridade |
|---|---|---|---|---|
| Estado em-voo | — | **GitHub** | Issues e PRs reais. | **Autoritativo** |
| Audit trail | **trilha de auditoria** | **audit trail** | Histórico de mensagens em `inbox/`. | Auditoria, não estado |
| Diário de bordo | **diário de bordo** | **journal** | Log estruturado de incidentes (`logs/journal.jsonl`, via `log.sh`). | Aprendizado, não estado |
| Registry de agentes | **registry de agentes** | **agent registry** | Spawn/deregister log (`state/agents.jsonl`). | Estado vivo de agentes |
| Registry de targets | **registry de targets** | **target registry** | Fonte declarativa dos targets (`targets.json`). | **Autoritativo** p/ targets |
| Projeção em DB | **projeção** | **projection** | `mmb-logger.db` (SQLite). | **Não** autoritativo |
| Visualização | **aquário** | **aquarium** | Viz em tempo real via `AppMessage`/WebSocket. | Apresentação |

---

## 3. Estados e ciclos de vida (valores canônicos)

| Domínio | Valores (verbatim) | Idioma | Onde |
|---|---|---|---|
| Status do épico | `aberto` · `fechado` | PT | `epicos.status` |
| Status do ciclo | `iniciado` · `planejado` · `pr_aberto` · `completo` · `abortado` | PT (`pr_aberto` é híbrido) | `ciclos.status` |
| Origem de abort | `heartbeat` · `manual` · `self` · `master` · `worker-exit` · `worker-timeout` · `stale` | EN | `ciclos.abort_origin` (`master` é dívida §6) |
| Veredito de suíte | `verde` · `vermelha` · `pulada` · `ausente` | PT | corpo de `status: pr-aberto-N` |
| Severidade (journal) | `warn` · `error` · `critical` | EN | `log.sh` |
| Severidade (eventos) | `info` · `warn` · `error` · `critical` | EN | `eventos.severity` |
| Glyph de digest | `✓` (rotina) · `⚠` (escalada) | — | fallbacks ASCII `+` / `!` aceitos |

---

## 4. Conjuntos fechados (verbatim — load-bearing)

> O código casa contra estes literais por regex/validação. Mudar qualquer
> um quebra o runtime — não derive variações.

- **Tipo de mensagem** (`msg.sh`): `briefing | question | answer | status | error`
- **Subjects de status** (`inject-digest-tail.sh`): `issue-criada-N | pr-aberto-N | task-fechada[-<id>]`
  - *(`atomico-respawnado` aparece em docs/profiles mas NÃO na whitelist do código — dívida §6)*
- **Agent layer** (registry + validação): `master | project | atomic`
- **Target kind** (`lib/targets.sh`): `internal | external | external-fake`
- **Campos do target registry** — obrigatórios: `id, dest, repo, local_path, worker_profile, agent_layer, tracked_by_logger`; opcionais: `owner, requires_github, kind, managed_by_reset`
- **Dirs de lifecycle** (`commd`): `.processing | .done | .dead`
- **Evento do agent registry** (`agents.jsonl`, campo `ev`): `spawn | deregister | heartbeat`
- **Eventos do commd no journal** (campo `event`): `commd-dispatch | commd-claim | commd-done | commd-worker-done | commd-dead | commd-worker-timeout | commd-worker-exit | commd-poll-recovered | commd-watchdog-kill`
  - sub-classificador `kind` (sev=error): `worker-timeout | worker-watchdog-kill | worker-exit | watchdog-stale`
- **`eventos.kind`** (logger): `state_change | msg_send | msg_receive | heartbeat_loss | atomic_spawn | atomic_deregister | pr_opened | journal_warn | journal_error | journal_critical`
- **AppMessage** (aquário): `type ∈ event | state`; `kind ∈ born | died_happy | died_defeated | freaking_out`
- **`source_key`** (logger): `journal:<ts>:<event>` · `agents:<id>:<ts>:<ev>` · `inbox:<abspath>`
- **Knobs**: `MMB_MODE ∈ normal | fast | balanced`; `MMB_TMUX_SPLIT ∈ -v | -h | win`; `priority ∈ normal | high | critical`

---

## 5. Palavras proibidas sem qualificação (anti-homônimos)

Estas palavras cobrem múltiplos conceitos. Na prosa, **sempre qualifique**:

| Palavra | Sentidos que ela carrega | Use sempre |
|---|---|---|
| **kind** | target (internal/external) · evento (`eventos.kind`) · sub-classificador do journal · lifecycle do aquário (born/died) | "target kind" · "event kind" · "lifecycle kind" |
| **id** | task-id · agent-id · ciclo-id · epic-id/slug · target-id | o id qualificado |
| **registry** | target registry (`targets.json`) · agent registry (`agents.jsonl`) | "target registry" · "agent registry" |
| **worker** | mecanismo (`claude -p`) · papel orq · papel triador do Mestre | "worker" só p/ o mecanismo; nomeie o papel |
| **master** | Mestre (interativo) · triador do Mestre (`worker-master`, legado) · agent-id/inbox/tab `master` · branch git `master` | "Mestre" · "triador do Mestre" · "inbox do Mestre" · "branch master" |
| **ciclo** | unidade do logger (`ciclos`) · procedimento de N fases de um papel · fluxo de desenvolvimento | "ciclo" só p/ o logger; "procedimento"/"fluxo" p/ os outros |

---

## 6. Inconsistências conhecidas (dívida — adiada pro rename)

Documentadas aqui para honestidade; **não** corrigidas nesta versão
(decisão: glossário primeiro, renomeio depois). Cada item é candidato a
task de rename/fix vetada separadamente.

**Nível 1 — perigos de correção (verificar antes de renomear):**

1. **`mmb-cycle-key`: `/` na âncora vs `__` no `ciclos.id`.** A âncora usa
   `<epic>/<project>/<ts>`; `ciclos.id` usa `<epic>__<project>__<ts>`. O
   doc afirma que "casam". **Verificar** se o reconcile transforma `/`→`__`
   (então é só encoding confuso) ou não (então é bug de matching).
2. **`core` fantasma**: `msg.sh` ainda documenta/infere `core` como
   `to`/`from`, mas o target registry o bane ("lixo morto"). `msg.sh core`
   falha na validação.
3. **Dois schemas de journal no mesmo arquivo**: `log.sh` escreve
   `{agent,epic,task,sev,event,…}`; `commd.sh` escreve `{dest,file,pid,event,…}`.
4. **Agent-id dúbio**: worker registra `<dest>-w-<pid>` no agent registry
   mas exporta `MMB_AGENT_ID=<dest>-<pid>` (sem `-w-`).
5. **`event=pr-opened`** consumido pelo aquário **não é escrito** por
   nenhum script da camada de runtime.

**Nível 2 — campos com nomes divergentes p/ o mesmo conceito (deferir):**

6. **Verbo de evento tem 3 nomes**: `eventos.kind` (DB) vs `event` (journal
   commd) vs `ev` (journal log.sh / agents). O parser já carrega shim
   `event||ev`.
7. **Severidade**: `severity` no DB/Pydantic vs `sev` no journal.
8. **`dest` vs `to`** (mesmo destinatário) · **`thread` vs `epic`** (mesmo slug)
   — duplas que o código já ponteia.
9. **Morte/abort em 4 vocabulários disjuntos**: `abort_origin` (DB) ≠
   `reason` (agents) ≠ `commd-worker-exit` (journal) ≠ `died_*` (aquário).
10. **`abort_origin` inclui `master`** no schema/Pydantic mas não está
    documentado na seção de sinais de abort do `source-of-truth.md`.

**Nível 3 — bilíngue e misnomers (cosmético):**

11. **`pr_opened` / `pr-aberto` / `pr_aberto`**: mesmo evento, 3 grafias
    (EN snake / PT kebab / PT-EN snake) em superfícies diferentes.
12. **`intents/`** guarda briefings, não "intenções" — misnome de diretório.
13. **`atomico-respawnado`**: termo de doc sem contraparte no código.
14. **Papel `triador do Mestre`**: nome canônico novo (PT `triador do Mestre`,
    EN `master triager`). Os aliases legados `worker-master`/`master-worker` e
    o arquivo de profile `master-worker.md` ainda não foram renomeados —
    rename adiado (toca `worker.sh`, que carrega o profile pelo nome).

---

## 7. Como este doc evolui

- Novo conceito do domínio → adicione a linha aqui **antes** de usá-lo em
  código ou doc.
- Resolveu uma dívida da §6 (rename/fix) → mova o termo para a forma
  canônica nas tabelas e remova o item da §6.
- Relação com os outros contratos: `protocol.md` (semântica da
  mensageria), `source-of-truth.md` (semântica da projeção/DB),
  `guardrails.md` (comportamentos vetados). Este doc governa apenas a
  **escolha do nome**; eles governam o **significado**.
