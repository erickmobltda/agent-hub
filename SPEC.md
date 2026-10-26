# SPEC — Hub de agentes Claude Code sobre tmux

> Nome do projeto: **a definir** (pergunte ao usuário antes de criar arquivos). Neste documento ele aparece como `<app>`.

## 1. Objetivo

Centralizar em um único lugar do tmux a visão e o controle de vários agentes Claude Code rodando em paralelo, cada um numa task própria, com seu git worktree.

O usuário quer:
- Ver em tempo real todos os agentes, agrupados, com o estado de cada um (trabalhando / esperando resposta / pronto).
- Selecionar um agente e "entrar" nele (pular para a window, focar o pane do Claude, opcionalmente zoom).
- Conversar com um Claude "orquestrador" pedindo coisas como "abre um agente pra corrigir X no repo Y", e ele criar tudo.
- Nada de firula visual (sem avatares/bonequinhos). Só terminal.

Inspiração: [agent-deck](https://github.com/asheshgoplani/agent-deck). Não é dependência, mas o projeto replica a ideia de dashboard + conductor. Ele foi descartado por política de segurança da empresa: binário Go de terceiro, daemon e banco. Este projeto deve ser **só bash + ferramentas já instaladas + recursos oficiais do Claude Code e do tmux**.

## 2. Ambiente alvo

- macOS. Terminal Ghostty, rodando tmux dentro.
- Versões instaladas (verificadas em 2026-10-24): tmux 3.6b, fzf 0.73.1 (Homebrew), git 2.54.0, jq 1.8.1, Claude Code 2.1.310, bash 3.2.57. O `doctor` valida recursos, não versão exata.
- **Os scripts devem funcionar no bash 3.2** (o do macOS). Ou seja, nada de `declare -A`, `mapfile`/`readarray`, `${var,,}` e afins.
- Assuma utilitários **BSD** (`sed -i ''`, `date` BSD). Não use flags exclusivas do GNU.

## 3. Princípios / restrições (não negociáveis)

1. **Sem banco, sem daemon, sem arquivo de estado.** O tmux é a fonte da verdade:
   - **grupo (epic) = session do tmux**
   - **agente = window do tmux**, dentro da session do grupo
   - metadados derivados (diretório do pane + git) ou guardados em **user options** do tmux (`@...`)
   - **v2 (§17):** exceção aprovada — um arquivo `agent-hub` no git dir privado de cada worktree guarda grupo/task, para as tasks sobreviverem a um restart do tmux. Ele some junto com o worktree.
2. **Só recursos oficiais e documentados** do Claude Code (hooks, skills, CLI), do tmux e do fzf. Antes de usar qualquer recurso, **verifique na documentação oficial** da versão instalada:
   - Claude Code: https://code.claude.com/docs
   - tmux: `man tmux`
   - fzf: `man fzf` / `fzf --help`

   Não invente flags nem eventos.
3. **Rede:** só `git fetch` e instalação de dependências **com consentimento explícito** do usuário.
4. **Nunca destruir trabalho:** antes de remover um worktree ou branch, checar se há alterações sem commit, commits sem push ou stash, e pedir confirmação.
5. **Instalação idempotente e reversível:**
   - backup antes de editar `~/.claude/settings.json` e `~/.tmux.conf`
   - blocos delimitados por marcadores
   - `uninstall` desfaz tudo
6. **Hooks nunca podem travar nem quebrar o Claude:** rápidos, sempre saem com código 0, viram no-op fora do tmux (`$TMUX_PANE` vazio).
7. **Sem suposições:** quando faltar informação, perguntar ao usuário.

## 4. Checagem de dependências (`doctor`)

Executada na instalação, no primeiro uso e sob demanda.

| Dependência | Obrigatória | Checagem |
|---|---|---|
| tmux | sim | `command -v tmux` + `tmux -V`. Validar que a versão suporta os recursos usados (pane options `set -p`, `display-popup`); conferir no man da versão instalada |
| fzf | sim | `command -v fzf` + `fzf --version`. Validar os recursos usados (ex.: `reload`, `--listen`, preview) |
| git | sim | `command -v git` + `git --version` (precisa de `git worktree`) |
| jq | sim | `command -v jq` |
| claude | sim | `command -v claude` + `claude --version` (precisa de hooks) |
| bash | sim | `bash --version` (só informativo; o código já é compatível com 3.2) |
| curl | condicional | só se o refresh do fzf usar `--listen` (vem com o macOS) |
| Homebrew | opcional | `command -v brew`, usado para oferecer a instalação |

Se faltar algo:
- Se o `brew` existir, **perguntar**: "Instalar `<pkg>` com `brew install <pkg>`? [s/N]". Se sim, executar. Se não, imprimir o comando.
- Se o `brew` não existir, imprimir o comando de instalação sugerido e o link oficial da ferramenta.
- Dependência obrigatória faltando → abortar com mensagem clara. Opcional faltando → só avisar.

## 5. Configuração (primeiro uso + ajuste depois)

Arquivo: `~/.config/<app>/config`, formato `chave=valor`.

**Não fazer `source`** do arquivo. Faça o parse linha a linha (é input de usuário; evita execução de código).

| Chave | Descrição | Default sugerido |
|---|---|---|
| `repos_roots` | uma ou mais pastas (separadas por `:`) onde ficam os repos | — (perguntar) |
| `branch_prefix` | prefixo da branch (`""` permitido) | — (perguntar; sugerir `feature/`, `feat/`, vazio) |
| `base_branch` | branch base | `main` (o usuário confirmou: sempre `main`) |
| `worktree_location` | `sibling`, `subdirectory` ou caminho absoluto | — (perguntar) |
| `claude_pane_pct` | % de altura do pane do Claude na window da task | `70` |
| `hq_session` | nome da session do hub | `hq` |

**Primeiro uso (setup guiado):** quando o config não existir, perguntar com opções sugeridas mais um campo livre:
- **Pasta(s) dos repos:** sugerir candidatas detectadas, ex. pastas em `~` com muitos subdiretórios contendo `.git`. Não varrer o disco inteiro.
- **Prefixo de branch.**
- **Local dos worktrees:**
  - `sibling` → `<pai_do_repo>/<repo>--<task>`
  - `subdirectory` → `<repo>/.worktrees/<task>`. Avisar que precisa estar no `.gitignore` do repo, sem editar o `.gitignore` sem permissão.
  - caminho custom → `<path>/<repo>/<task>`

Esse setup pode rodar tanto no terminal (prompt interativo) quanto pelo orquestrador (via AskUserQuestion do Claude).

**Ajuste depois:** subcomando `config get|set|show`, e o orquestrador altera quando o usuário pedir ("muda o prefixo de branch para feat/").

## 6. Modelo de dados (tmux como fonte da verdade)

| Informação | Origem |
|---|---|
| Grupo / epic | nome da session (`#{session_name}`) |
| Nome da task | nome da window (`#{window_name}`) |
| Worktree | diretório do pane do Claude (`#{pane_current_path}`) |
| Repo | derivado via git a partir do worktree (ex.: `git rev-parse --git-common-dir` → repo principal) |
| Branch | `git -C <dir> branch --show-current` |
| Estado | user option de pane `@agent_status` |
| Momento da última mudança de estado | user option de pane `@agent_since` (epoch) |

User options (doc oficial: `man tmux`, seção OPTIONS, "user options"):
- **`@agent_status`**: `working` | `waiting` | `done`. A presença dela é o que identifica um pane como agente.
- **`@agent_since`**: epoch em segundos da última mudança de estado. Serve para ordenar e mostrar "esperando há 5m".

Nada mais é guardado. User options se perdem quando o servidor tmux morre; isso é aceito (ver §13).

## 7. Layout das windows de task

Cada task é uma window na session do grupo:

```
window "<task>"  (session = grupo)
┌─────────────────────────────────┐
│ claude            (70%)         │  ← cwd = worktree
├─────────────────────────────────┤
│ shell             (30%)         │  ← cwd = worktree
└─────────────────────────────────┘
```

- Se a session do grupo não existir, ela é criada.
- Nome da window = nome da task. Se colidir dentro da session, perguntar outro nome.
- O Claude é aberto com `claude` puro (o usuário não quer flags). Se houver prompt inicial, passar da forma documentada na CLI oficial (confirmar se `claude "<prompt>"` inicia o modo interativo com o prompt).

## 8. Hook de status (Claude Code → tmux)

Um script `hooks/status-hook.sh`, registrado no `~/.claude/settings.json` (merge com `jq`, preservando os hooks existentes, com backup).

Mapeamento **confirmado na doc oficial** (code.claude.com/docs/en/hooks) e aprovado:

| Evento | Estado |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | `working` (PostToolUse limpa o waiting após uma permissão aprovada) |
| `PreToolUse` com `tool_name` `AskUserQuestion` ou `ExitPlanMode` | `waiting` |
| `PermissionRequest` (imediato); `Notification` com `permission_prompt`, `elicitation_dialog`, `agent_needs_input` | `waiting` |
| `Stop`, `StopFailure` | `done` |
| `SessionEnd` | remover `@agent_status` e `@agent_since` |
| `Notification` `idle_prompt` | ignorado |

Limitações aceitas: a doc não diz se o hook herda `$TMUX_PANE` (validado por teste manual); Esc não dispara `Stop`, então o estado fica `working` até o próximo prompt.

Regras:
- Gravar com `tmux set -p -t "$TMUX_PANE" @agent_status <estado>` e atualizar `@agent_since` só quando o estado mudar.
- `$TMUX_PANE` vazio → sair 0 sem fazer nada.
- Ler o stdin com `jq`. Se não conseguir parsear, sair 0.
- Rápido: sem rede, sem `sleep`, sem chamadas lentas de git.
- O pane do orquestrador (session `hq`) também dispara hooks. O dashboard ignora a session `hq`.

## 9. Session hub (`hq`)

Layout proposto (ajustável; confirmar com o usuário):

```
session "hq", window única
┌──────────────────────────┬─────────────────────────────┐
│ dashboard (fzf)          │ preview do agente           │  ← pane superior (≈65%)
│ ▾ development (3) ⏳1     │ (capture-pane das últimas   │
│   ⏳ backend-api  svc-a   │  linhas do Claude)          │
│   ✅ testing      svc-b   │                             │
│   ⚙  docs        svc-c   │                             │
│ ▾ devops (1)             │                             │
│   ⚙  docker-setup infra  │                             │
├──────────────────────────┴─────────────────────────────┤
│ Claude orquestrador                                    │  ← pane inferior (≈35%)
└────────────────────────────────────────────────────────┘
```

O preview é o painel de preview do próprio fzf, dentro do pane superior.

### 9.1 Dashboard (fzf)

- **Fonte:** `tmux list-windows -a` / `list-panes -a` com `-F`, filtrando os panes que têm `@agent_status` e excluindo a `hq_session`.
- **Agrupado por session.** Cabeçalho do grupo com contagem total e de esperando.
- **Linha do agente:** ícone de estado, nome da window, repo (derivado) e tempo desde `@agent_since`.
- **Ordem dentro do grupo:** `waiting` > `done` > `working`. Ordem dos grupos: os que têm `waiting` primeiro.
- **Ícones:** texto/Unicode simples (ex.: ⏳ waiting, ✅ done, ⚙ working). Sem animação.
- **Preview:** `tmux capture-pane -p -t <pane_do_claude>` (últimas N linhas).
- **Teclas:**
  - `Enter` → `switch-client` para a session, `select-window`, `select-pane` no pane do Claude.
  - Uma tecla de zoom opcional (`resize-pane -Z`).
  - Uma tecla para recarregar manualmente.
- **Atualização automática:** a lista e o preview devem refletir mudanças em ≤ ~2s.
  - Preferir refresh disparado por evento: o hook avisa o fzf, ex. `fzf --listen` + `curl` local. **Verificar na doc do fzf 0.74** o mecanismo recomendado.
  - Alternativa aceitável: refresh periódico leve.
  - Proibido loop que consuma CPU de forma relevante.

### 9.2 Popup e status bar

> **Decisão (2026-10-24):** popup fora do MVP (o agent-deck não tem). Sem atalhos de tmux, exceto **Ctrl+Q → hq** (`bind -n C-q`), que só age em sessions marcadas com `@agent_hub`; nas outras, o C-q é repassado ao programa. Os itens abaixo ficam como referência para a v2.

- **Popup:** o mesmo dashboard via `tmux display-popup -E`, chamado por atalho de qualquer lugar. `Enter` pula para o agente e fecha o popup.
- **Atalho de volta:** uma tecla que leva ao `hq` de qualquer lugar.
- **Status bar:** segmento com contagem por estado (ex.: `⏳2 ✅1 ⚙3`), anexado ao `status-right` existente sem sobrescrever. Usar `#()` e o intervalo de status já configurado, ou outro mecanismo documentado.
- **Atalhos:** definir com o usuário (perguntar antes); nada hardcoded que conflite com o `.tmux.conf` dele. Checar conflitos com os binds atuais (`tmux list-keys`).

## 10. Orquestrador (Claude no `hq`)

Uma **skill do Claude Code** (escopo de usuário, `~/.claude/skills/<app>/SKILL.md`; conferir o formato na doc oficial de skills).

Ela ensina o Claude a operar o `<app>` **chamando os scripts do projeto**, em vez de reimplementar a lógica de git/tmux na conversa. O usuário não digita comandos; quem chama é o Claude, ou os atalhos do tmux.

Fluxos:

1. **Criar agente**: "quero um agente pra X no repo Y".
   - Perguntar, com opções clicáveis mais campo livre (AskUserQuestion), o que não foi dito:
     - **grupo:** sessions existentes ou novo
     - **repo:** lista a partir de `repos_roots`
     - **nome da task:** sugerir um slug a partir do pedido
   - Chamar `new`, que faz:
     - `git fetch origin <base_branch>`
     - `git worktree add -b <prefix><task> <path> origin/<base_branch>`
     - session/window + layout 70/30
     - `claude` com o prompt inicial, se houver
   - Confirmar ao usuário onde ficou.
2. **Listar / status**: "como estão os agentes?" → resumo a partir do `list`.
3. **Fechar**: o usuário pede, ou o agente sugere ao terminar.
   - Chamar `close <grupo>/<task>`. Ele verifica alterações sem commit, commits sem push e stash.
   - Se houver pendência: mostrar e **pedir confirmação**.
   - Depois: `kill-window`, `git worktree remove`. A branch só é apagada se o usuário confirmar, e nunca com `-D` sem confirmação explícita.
4. **Mover de grupo**: "move a task X pro grupo Y" → `move-window`, criando a session destino se preciso.
5. **Configurar**: "muda o prefixo de branch" → `config set`.
6. **Setup inicial**: se o config não existir, conduzir o §5.

A skill também deve instruir os **agentes das tasks** a sugerirem, quando terminarem, que o usuário feche a task pelo orquestrador. Opcional; confirmar com o usuário se entra no MVP.

## 11. Interface dos scripts (uso interno)

Um entrypoint único `bin/<app>` com subcomandos:

| Subcomando | Função |
|---|---|
| `doctor` | checa dependências (§4) |
| `setup` | setup guiado (§5) |
| `config get\|set\|show` | lê/altera o config |
| `new --group G --repo R --task T [--prompt P]` | cria o agente (§10.1) |
| `list [--format tsv\|json]` | lista os agentes (para o dashboard e o orquestrador) |
| `close G/T [--yes]` | fecha a task com checagens (§10.3) |
| `move G/T --to G2` | muda de grupo |
| `dash` | roda o dashboard fzf |
| `popup` | abre o dashboard em `display-popup` |
| `hq` | cria ou anexa a session hub com o layout do §9 |
| `status-bar` | imprime o segmento do status bar |
| `hook <evento>` | ponto de entrada do hook do Claude (§8) |

Saídas pensadas para o Claude: códigos de saída consistentes e mensagens de erro claras em uma linha.

## 12. Instalação / desinstalação

- **`install.sh`:**
  1. roda o `doctor`
  2. copia ou linka o projeto para um local estável (perguntar onde; sugerir `~/.local/share/<app>` + link em `~/.local/bin`)
  3. faz merge dos hooks no `~/.claude/settings.json`, com backup e sem duplicar se rodar de novo
  4. instala a skill
  5. adiciona ao `~/.tmux.conf` um bloco entre `# >>> <app> >>>` e `# <<< <app> <<<`, com backup e mostrando o diff antes, perguntando se aplica
  6. sugere `tmux source-file ~/.tmux.conf`
- **`uninstall.sh`:** remove os hooks (só os do `<app>`), a skill e o bloco do `.tmux.conf`. Não toca em worktrees, branches ou sessions existentes.
- Checar se managed settings da empresa bloqueiam hooks de usuário. Se houver indício disso, avisar.

## 13. tmux-resurrect / continuum (opcional, documentar no README)

- O resurrect restaura sessions, windows, panes, layout e diretórios, mas **não** salva user options.
  - Grupo, task, repo e branch sobrevivem porque são derivados.
  - O estado volta vazio até o próximo evento de hook. Isso é aceito.
- Para reabrir o Claude: `set -g @resurrect-processes '"~claude->claude --continue"'`. **Não confirmado** com que nome o processo do Claude aparece no macOS; testar e documentar. Confirmar também o comportamento do `--continue` na doc oficial.
- Se no futuro for preciso persistir algo não derivável, usar os hooks oficiais do resurrect (`@resurrect-hook-post-save-layout`, `@resurrect-hook-pre-restore-pane-processes`).

## 14. Testes

- **Testes em bash puro** (sem bats, para não adicionar dependência), num **servidor tmux isolado** (`tmux -L <app>-test`) e com **repos git temporários** em `mktemp -d`.
- **Cobrir:**
  - parse do config
  - `doctor` com dependência ausente (PATH manipulado)
  - `new` (branch, worktree, window, layout)
  - hook (grava e limpa as options; no-op sem `$TMUX_PANE`)
  - `list` (filtro, agrupamento, ordem)
  - `close` (bloqueia com pendência, remove limpo sem pendência)
  - `move`
  - merge idempotente do `settings.json`
- Rodar `shellcheck` se estiver instalado (opcional, não é dependência).
- **Teste manual final:** criar dois grupos com duas tasks cada, simular os estados e validar dashboard, popup, status bar e o pulo para a window.

## 15. Fora do escopo do MVP (v2+)

- Outros CLIs (Codex, Cursor etc.).
- Aviso ativo ao orquestrador quando um agente terminar ou travar (via cross-session messaging oficial do Claude Code).
- Estado "pronto e visto" vs "pronto e não visto" (`@agent_notified`).
- Detecção de estado lendo o próprio Claude (ex.: `claude agents --json`) em vez de hooks.
- Gerenciamento de MCP e skills por agente (usa o que estiver configurado no repo).
- Merge automático ao fechar, fork de sessão, custos, notificações por Telegram/Slack, UI web.
- Subgrupos.

## 16. Decisões (resolvidas em 2026-10-24)

1. Nome: **`agent-hub`**. Instalação por symlink: `~/.local/bin/agent-hub` → repo; skill linkada em `~/.claude/skills/agent-hub`.
2. Atalhos: só **Ctrl+Q** (volta ao hq, só em sessions de agente). Sem popup. No dashboard: Enter/duplo clique (pular), alt-enter (pular + zoom), ctrl-r (recarregar).
3. Layout do `hq`: como no §9.
4. Sugestão de fechar a task ao terminar: fora do MVP.
5. Refresh: híbrido. O hook empurra `reload` via `fzf --listen=<socket Unix>` + `curl --unix-socket`, e há um loop de 2s (só enquanto o dash está aberto) que faz `reload+refresh-preview`.

## 17. v2 (decisões de 2026-10-26)

Motivo: o `agent-hub hq` abria o tmux vazio. O tmux-continuum restaurava a session `hq` como dois zsh comuns (o resurrect não guarda user options nem os processos), e o `hq` só montava o layout quando a session não existia. O mesmo restore escondia os agentes do dashboard e quebrava o Ctrl+Q nessas sessions.

Decisões (perguntadas ao usuário e aprovadas):
1. **Uma tecla só no tmux: Ctrl+Q** (root table, configurável em `hub_key`) abre um **popup** com todos os agentes e as sessions comuns; Ctrl+Q de novo fecha. Substitui o §9.2 e a decisão 2 do §16.
2. **Dashboard:** digitar filtra, Enter abre, Tab abre um menu de ações, e Ctrl+letra são atalhos (n novo, s enviar, x fechar, o PR, g mover, z zoom, r atualizar). Linhas planas `grupo/task`, sem cabeçalho de grupo. É o mesmo dashboard no hub e no popup. Enter num agente parado o retoma (`claude --continue`).
3. **GitHub (gh):** número, estado e CI do PR por agente, e abrir o PR no browser. Um cache local é atualizado em background no máximo 1x/min por repo; `github=auto|off`. Isso amplia a regra de rede do §3.3.
4. **Persistência:** marcador `<repo>/.git/worktrees/<id>/agent-hub` (`group=`, `task=`, `worktree=`), escrito no `new`, atualizado no `move` e apagado pelo próprio git com o worktree. Worktrees da v1 no caminho padrão do agent-hub são adotadas: o grupo é a session da window restaurada, ou o nome do repo.
5. **Escopo:** agentes Claude e sessions tmux comuns. Outros CLIs de IA ficam fora; o comando do agente é configurável (`agent_cmd`).

Mudanças técnicas:
- **O hub se conserta sozinho.** Os panes são identificados por `@agent_hub_role`. Se faltarem os dois, uma nova window `hub` substitui as windows que só têm shells parados; a session e o cliente ficam. Se faltar um, ele é recriado. Um orquestrador que saiu é reiniciado. O `heal` roda após cada restore do tmux-resurrect (`@resurrect-hook-post-restore-all`, só se estiver vazio).
- **Claude é iniciado por `agent-hub run`**, executado direto pelo tmux, em vez de `send-keys`. O prompt chega intacto como argumento, e quando o Claude sai o pane vira um shell de login. O orquestrador recebe o papel via `--append-system-prompt`, sem gastar um turno.
- **Estados do hook:**
  - SessionStart → idle (com `source=compact`, ignorado);
  - UserPromptSubmit e PostToolUse → working;
  - permissão, pergunta, plano e input MCP → waiting, com `@agent_note` dizendo o quê;
  - Stop → done;
  - StopFailure → error;
  - SessionEnd com `clear` ou `resume` → ignorado; nos outros casos, stopped.
  - O comando registrado termina em `|| true`: exit 2 num PreToolUse bloquearia as ferramentas. O hook não imprime nada no stdout.
- **Listagem:** uma chamada `tmux list-panes`, mais um awk (`lib/rows.awk`) que lê os marcadores, o HEAD dos worktrees e o cache do gh, sem nenhum `git` por refresh. O fzf atualiza a cada 5s quando o usuário está parado, e na hora a cada evento do hook (`--listen`).
- **No tmux.conf fica uma linha** (`run-shell '<repo>/agent-hub.tmux'`), no fim do arquivo, depois do tpm. O `tmux-init` faz o bind da tecla e adiciona ` #{E:@agent_hub_status}` ao `status-right` uma única vez; o segmento é um formato puro do tmux, sem processo. Não sobrescreve bind alheio e mantém o `#(continuum_save.sh)`.
- **`close`:** faz o trabalho de git antes e mata a window por último; quem estava olhando a task vai para o hub em vez de ser desconectado. **`new`** descobre o branch base (`origin/HEAD`), funciona offline e sem remote, e cria o branch sem tracking.
- **Novos comandos:** `open`, `send` (recusa quando o agente espera resposta), `peek`, `heal`, `config edit`, e `new` interativo num terminal.
- **Não usar `@resurrect-processes` para o claude:** o agent-hub já retoma com `claude --continue`.
