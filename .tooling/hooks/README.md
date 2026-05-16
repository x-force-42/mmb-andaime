# Hooks do andaime MMB

Hooks do **Claude Code CLI** que rodam em qualquer sessão Claude aberta
no diretório `/MMB/`. Implementam enforcement técnico dos guardrails
documentados em [`../guardrails.md`](../guardrails.md) e o fluxo do
mestre não-cego (worker-master + injeção de pending-human).

## Instalação (idempotente)

```bash
.tooling/bin/bootstrap-hooks.sh
```

Registra os 2 hooks abaixo em `.claude/settings.local.json` da raiz
do projeto. Pode ser rodado múltiplas vezes — detecta hooks já
registrados (mesmo `command` path) e não duplica. Preserva hooks de
terceiros e outras keys do settings (model, etc).

Flags:
- `--dry-run` imprime o JSON resultante sem gravar
- `-h` / `--help` mostra uso

Após o bootstrap, **feche e reabra qualquer sessão Claude Code** rodando
neste projeto pra ativar os hooks.

> `.claude/` está em `.gitignore` (settings são per-machine). Cada dev
> roda o bootstrap localmente.

## Hooks registrados

### `block-pr-merge.sh` — enforcement de A10/A8

Hook **PreToolUse** com matcher `Bash`. Bloqueia `gh pr merge` e
`gh pr review --approve` em sessões atômicas (detectadas pela presença
de `MMB_AGENT_ID` no env). Sessões do Mestre, do Rick (terminal manual),
do worker-master e do orq local não têm `MMB_AGENT_ID` setado — o hook
é no-op transparente nelas.

**O que é bloqueado em sessão atômica:**

| Comando | Ação |
|---|---|
| `gh pr merge` (qualquer flag) | ❌ exit 2 |
| `gh pr merge --auto` | ❌ exit 2 |
| `gh pr review --approve` | ❌ exit 2 |
| Aninhados (`;`, `&&`, `\|`, `$()`, `\``) | ❌ exit 2 |

**O que continua liberado:**

| Comando | Razão |
|---|---|
| `gh pr view` / `gh pr list` | leitura, debug |
| `gh pr create` | atômico precisa pra abrir PR |
| `gh issue view` / `gh issue create` | leitura ou criação de issue |
| `gh pr review --comment` (sem `--approve`) | comment != approve |
| `git push` | atômico publica branch task/* |
| Qualquer comando não-`gh` | fora do escopo |

**Limitação conhecida:** se o atômico escreve um script com `gh pr merge`
dentro e roda `bash script.sh`, o hook vê só `bash script.sh` e libera.
Defesa-em-profundidade vs adversário determinado fica fora de escopo —
profile A10/A8 é primeira linha.

### `inject-pending-human.sh` — mestre não-cego

Hook **UserPromptSubmit**. Antes de cada prompt do Rick na sessão
Mestre, lê `.tooling/state/pending-human/*.md` (criados pelo
worker-master quando escala mensagem não-rotineira), prepende no
contexto envolto em:

```
<pending-human-msgs count=N>

=== entry: <basename1> ===
<conteúdo do arquivo 1>

=== entry: <basename2> ===
<conteúdo do arquivo 2>

</pending-human-msgs>
```

Arquivos processados são movidos pra `.processed/` (não deletados —
audit trail).

Também **reseta o indicador tmux** que `write-pending-human.sh` setou:
renomeia tab `master ⚠` → `master`, reseta `window-status-style`.

**Falha silenciosa:** qualquer erro inesperado no hook → exit 0 sem
output. NUNCA bloqueia o prompt.

**Vazio:** dir sem entradas → exit 0 silencioso. Custo amortizado por
prompt é < 5ms.

## Testes

```bash
bash .tooling/tests/test-hooks.sh                # 29 asserts (block-pr-merge)
bash .tooling/tests/test-inject-pending-human.sh # 21 asserts (inject)
bash .tooling/tests/test-bootstrap-hooks.sh      # 20 asserts (bootstrap)
```

Cobertura inclui idempotência do bootstrap, preservação de hooks de
terceiros, audit trail em `.processed/`, robustez (arquivo unreadable,
stdin vazio, JSON malformado).

## Verificação manual

1. **bootstrap rodou?**
   ```bash
   cat .claude/settings.local.json | jq '.hooks | keys'
   # esperado: ["PreToolUse", "UserPromptSubmit"]
   ```

2. **block-pr-merge ativo?**
   Numa sessão Claude no `/MMB/`, set `MMB_AGENT_ID=test` no env e peça
   pro agente rodar `gh pr merge 1`. Espera-se erro `BLOCKED:
   Guardrails A10/A8 ...`.

3. **inject-pending-human ativo?**
   Crie um arquivo dummy:
   ```bash
   .tooling/bin/write-pending-human.sh --no-tmux \
     --from cockpit --type question --subject teste \
     --thread foo <<< "teste manual"
   ```
   Reabra a sessão Claude e mande qualquer prompt — o conteúdo do
   pending-human aparece no início do contexto, e o arquivo se move
   pra `.tooling/state/pending-human/.processed/`.
