#!/usr/bin/env bash
#
# ralph.sh
#
# Orquestrador que le um documento de fases, quebra em fases, e alimenta cada
# uma ao Codex CLI ou Claude Code para implementacao automatica.
#
# Invariantes:
#   1. Cada fase E cada ciclo de correcao roda em sessao NOVA, com prompt
#      auto-contido. Nunca reutiliza sessao.
#   2. Zero perguntas. Do inicio ao fim sem interacao humana.
#   3. Fase so e "completa" quando passa por 4 gates mecanicos, nunca pelo
#      exit code do engine.
#   4. Limite de uso -> espera o reset e re-executa a MESMA fase, sem consumir
#      ciclo de correcao.
#   5. Um commit por fase concluida.
#
# Agnostico de stack: a fase e o CLAUDE.md/AGENTS.md do projeto definem
# linguagem, framework, comandos e convencoes.
#
# Uso:
#   ./ralph.sh [opcoes] [caminho-do-arquivo]
#
# Opcoes:
#   --engine codex|claude    engine de implementacao (default: codex)
#   --from N                 comeca na fase N (limpa do progresso as fases >= N)
#   --keep-going             continua apos uma fase falhar (default: para)
#   --max-cycles N           ciclos de correcao por fase (default: 3)
#   --no-verify              desliga o gate 3 (equivale a RALPH_VERIFY=off)
#   --test-cmd "<cmd>"       comando de teste do projeto (gate 2)
#   --verbose                streama o progresso do engine no terminal
#   --quiet                  so o placar do ralph no terminal (DEFAULT)
#   --ui                     forca o painel ANSI (equivale a RALPH_UI=panel)
#   --no-ui                  forca o placar em linha corrida (RALPH_UI=plain)
#   --serve[=PORTA]          sobe um dashboard web local sobre o mesmo estado
#   --attach                 nao roda fase nenhuma: acompanha um run JA em
#                            andamento neste diretorio, republicando o status
#                            por task e a inferencia. Read-only sobre o run.
#
# Input (primeiro arquivo posicional). Sem argumento, resolve nesta ordem:
#   1. .spec/init/project-phases.md      (cadeia init)
#   2. .spec/project-phases.md           (repos pre-init, com aviso)
#
#   Um PHASES.md de feature tambem e input valido:
#     ./ralph.sh .spec/features/<slug>/PHASES.md
#
# Contrato de formato do input (validado no preflight):
#   - >= 1 heading `## Phase N: <titulo>`
#   - nenhum heading `## Phase ...` fora desse formato
#   - sub-fases em `### Phase N.M:` (nao viram sessao propria)
#   - qualquer outro `## ` encerra a captura da fase anterior
#
# Gates por fase (todos verdes -> commit; qualquer vermelho -> ciclo de correcao):
#   0. engine terminou de verdade (claude: is_error no JSON; codex: exit code)
#   1. a sessao escreveu codigo? SINAL, nao veredito — uma fase ja implementada
#      faz o engine (corretamente) nao escrever nada. Alimenta a causa do ciclo
#      de correcao quando um gate posterior reprova.
#   2. suite de testes do projeto, rodada PELO ralph (fora da sessao do agente)
#   3. sessao verificadora independente, read-only, task a task — o gate final,
#      roda em toda fase (RALPH_VERIFY=always, default). RALPH_VERIFY=auto
#      economiza: so roda quando o veredito do gate 2 nao basta — sessao que
#      nao escreveu nada (claim "ja implementada"), ciclo de correcao, ou
#      gate 2 desabilitado. --no-verify / RALPH_VERIFY=off desliga. No engine
#      claude o verificador usa um modelo barato (RALPH_VERIFY_MODEL, default:
#      haiku) — e leitura + checklist.
#
# Streams do engine (stdout != stderr — nunca unir):
#   .phases/logs/<fase>.<etapa>.log         stdout = RESPOSTA FINAL do engine.
#                                           Unica fonte de veredito dos gates.
#   .phases/logs/<fase>.<etapa>.stderr.log  stderr = progresso/telemetria.
#                                           Diagnostico apenas, nunca veredito.
# Medido no codex 0.146.0: uma sessao trivial deu 13 bytes de stdout (so a
# resposta final) contra 48894 de stderr (banner, eco do prompt, hooks, traces
# de exec). Unir os streams fazia o codex ecoar a resposta final nos dois e o
# gate 3 contar cada task duas vezes ("cobertura incompleta" com a fase inteira
# pronta). Por isso o gate 3 conta INDICES UNICOS de task, nao linhas: eco
# duplicado nao infla nem esconde cobertura, e INCOMPLETE sempre vence DONE no
# mesmo indice.
#
# Terminal (default --quiet): so o placar do ralph — fase, gates, commit. Os
# dois streams do engine vao INTEIROS para os logs, e um heartbeat periodico
# mostra o tempo decorrido e a ultima linha de progresso, para o run nao
# parecer travado. Gate vermelho ja imprime o tail dos dois streams no
# GATE_CAUSE. --verbose volta a streamar o progresso ao vivo.
#
# Estado estruturado (.phases/state.json + .phases/events.jsonl):
#   state.json    foto do agora — fase corrente, ciclo, veredito de cada gate,
#                 lista de fases com status, espera por limite, ultima linha de
#                 progresso do engine. Reescrito atomicamente (tmp + mv): um
#                 leitor concorrente nunca ve arquivo pela metade.
#   events.jsonl  append-only, uma linha JSON por transicao. Carrega os eventos
#                 gate_start/gate_end (com veredito e duracao) alem dos 7
#                 eventos que o RALPH_NOTIFY_CMD ja recebe.
# Sao CONTRATO, nao detalhe interno: o painel, o dashboard web e qualquer
# ferramenta externa leem esses arquivos. Nenhum deles parseia o placar humano.
#
# Painel ANSI (RALPH_UI, default auto):
#   auto    stdout e TTY -> painel; nao-TTY (nohup, CI, pipe) -> placar em
#           linha corrida, identico ao de sempre. --verbose sempre desliga o
#           painel (os dois streams ja ocupam o terminal).
#   panel   forca o painel (--ui)
#   plain   forca o placar em linha corrida (--no-ui)
#
# O painel roda no BUFFER ALTERNADO do terminal (ESC[?1049h), como vim ou less:
# ocupa a tela inteira enquanto o run acontece e, ao sair, devolve o terminal
# com o scrollback anterior intacto. E o que permite layout de altura variavel —
# a tabela cresce com o numero de fases e tasks do documento. Secoes:
#   cabecalho    projeto, engine, status, duracao, run id, pid
#   PROGRESSO    barras de fases concluidas e de tasks concluidas
#   TRABALHO     fase corrente, ciclo, gate ativo, atividade, ultimo erro
#   FASES/TASKS  tabela com uma linha por fase e uma por task, veredito por
#                gate na fase corrente, janela deslizante quando nao cabe
#   rodape       ultima linha de progresso do engine + ultimas mensagens
# Colunas caem por prioridade quando a largura aperta (Gates, depois Tentativa)
# e os dois quadros de cima empilham abaixo de 100 colunas.
#
# Status por task na tabela — quatro fontes, nesta ordem de autoridade:
#   1. fase concluida        todas as tasks dela sao Concluida
#   2. veredito do gate 3    DONE -> Concluida, INCOMPLETE -> Incompleta
#   3. checkbox `- [x]`      Declarada — o engine marcou a task no arquivo da
#                            fase ao fechar os testes dela. E o unico sinal que
#                            se move DURANTE a sessao; nao e veredito.
#   4. inferencia por ancora ~N% — quantos artefatos que a task nomeia ja
#                            existem no disco. Sempre prefixado por `~`.
# Uma fonte mais alta sempre sobrescreve a mais baixa: presenca de arquivo, e
# ate a palavra do engine, jamais viram veredito no lugar do gate 3.
#
# --attach: mesmo painel, sobre o .phases/ de um run que JA esta rodando (outro
# terminal). Nao roda fase, nao escreve codigo, nao commita — so republica
# tasks.txt/taskprog.txt e desenha. E o unico jeito de melhorar a leitura de um
# run em andamento: bash nao troca as funcoes de um processo vivo.
#
# Com o painel ativo o placar vai para .phases/ui/messages.log e aparece na area
# de mensagens. Ao sair do buffer alternado o placar inteiro do run e reimpresso
# na tela normal — sem isso ele existiria so no arquivo. Saida longa (causa de
# gate vermelho, relatorio final) sempre vem DEPOIS do ui_stop. Falha ao
# desenhar degrada para o placar: o painel nunca altera veredito de gate nem
# exit code.
#
# Dashboard web (--serve, opcional): escreve .phases/ui/index.html (auto-contido,
# sem CDN) e sobe `python3 -m http.server` preso a 127.0.0.1, na primeira porta
# livre a partir de RALPH_SERVE_PORT (default 7433). A URL sai uma vez no topo;
# o navegador NAO e aberto. O trap de saida mata o servidor. Sem python3 no
# PATH: aviso alto e o run segue normalmente, so com o painel.
#
# Gates verdes com a arvore limpa => a fase ja estava implementada em HEAD:
# marcada como feita, sem commit (nao ha o que commitar).
#
# Comando de teste (gate 2), primeira regra que resolver:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. deteccao por manifest:
#        Laravel Sail (artisan + vendor/bin/sail)  -> vendor/bin/sail test
#        composer.json com scripts.test            -> composer test
#        artisan                                   -> php artisan test
#        package.json com scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]      -> pytest
#        go.mod                                    -> go test ./...
#        Cargo.toml                                -> cargo test
#   4. nada resolvido -> aviso alto + gate 2 pulado (o gate 3 segura sozinho)
#
# Laravel Sail: a suite roda dentro do container, entao Sail tem precedencia
# sobre `composer test`. Containers parados -> abort no preflight (todo gate 2
# falharia, queimando ciclos de correcao).
#
# Variaveis de ambiente:
#   RALPH_TEST_CMD           comando de teste (gate 2); --test-cmd tem prioridade
#   RALPH_VERIFY             gate 3: always (default) | auto | off
#   RALPH_VERIFY_MODEL       modelo do verificador (default: haiku no claude)
#   RALPH_VERBOSE            1 = streama o progresso do engine (igual --verbose)
#   RALPH_HEARTBEAT          segundos entre heartbeats no modo quiet (default:
#                            60; 0 desliga)
#   RALPH_MAX_CYCLES         ciclos de correcao por fase (default: 3)
#   RALPH_MAX_LIMIT_WAITS    esperas consecutivas por limite, por fase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT fallback de espera em segundos (default: 1800)
#   RALPH_LIMIT_BUFFER       segundos extras apos o reset (default: 60)
#   RALPH_NOTIFY_CMD         comando de notificacao (opcional, vazio = desligado)
#   RALPH_UI                 painel: auto (default) | panel | plain
#   RALPH_UI_FPS             repinturas por segundo do painel (default: 2)
#   RALPH_UI_KEYS            1 (default) = navegacao por teclado na tabela do
#                            painel; 0 desliga (terminal que engole escapes)
#   RALPH_SERVE_PORT         primeira porta tentada por --serve (default: 7433)
#
# Notificacao (opcional): com RALPH_NOTIFY_CMD definido, o ralph chama
#   $RALPH_NOTIFY_CMD <evento> <mensagem>
# nos eventos run_start, phase_done, phase_failed, limit_hit, limit_over,
# limit_abort e run_done. Para acompanhar um run longo fora do terminal. Roda
# com timeout e o erro e engolido: notificacao e efeito colateral, nunca gate.
# Adaptador pronto para Telegram: scripts/notify-telegram.sh.
#
# Exportadas para o engine e para RALPH_NOTIFY_CMD:
#   RALPH_ENGINE             codex | claude
#   RALPH_PROJECT            nome do repo (distingue runs paralelos)
#   RALPH_PHASE_TITLE        titulo da fase corrente
#   RALPH_PHASE_NUM          numero da fase corrente
#   RALPH_PHASE_TOTAL        total de fases do run
#   RALPH_PHASE_ATTEMPT      ciclo corrente (1 = implementacao inicial)
#   RALPH_PHASE_MAX_ATTEMPTS igual a RALPH_MAX_CYCLES
#   RALPH_EVENT              evento corrente (so no processo de notificacao)
#
# Exit code: 0 = todas as fases verdes; 1 = alguma falhou ou abortou.
#
# Pre-requisitos:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Raiz de um repo git, com a arvore de trabalho limpa

set -euo pipefail

ENGINE="codex"
INPUT_FILE=""
FROM_PHASE=0
KEEP_GOING=false
TEST_CMD_FLAG=""
MAX_CYCLES="${RALPH_MAX_CYCLES:-3}"
VERIFY_MODE="${RALPH_VERIFY:-always}"
VERIFY_MODEL=""
VERBOSE=false
[ "${RALPH_VERBOSE:-0}" = "1" ] && VERBOSE=true
HEARTBEAT_SECS="${RALPH_HEARTBEAT:-60}"
UI_MODE="${RALPH_UI:-auto}"
SERVE=false
SERVE_PORT="${RALPH_SERVE_PORT:-7433}"
ATTACH=false
ATTACH_INTERVAL="${RALPH_ATTACH_INTERVAL:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)      ENGINE="$2"; shift 2 ;;
    --engine=*)    ENGINE="${1#*=}"; shift ;;
    --from)        FROM_PHASE="$2"; shift 2 ;;
    --from=*)      FROM_PHASE="${1#*=}"; shift ;;
    --max-cycles)  MAX_CYCLES="$2"; shift 2 ;;
    --max-cycles=*) MAX_CYCLES="${1#*=}"; shift ;;
    --test-cmd)    TEST_CMD_FLAG="$2"; shift 2 ;;
    --test-cmd=*)  TEST_CMD_FLAG="${1#*=}"; shift ;;
    --keep-going)  KEEP_GOING=true; shift ;;
    --no-verify)   VERIFY_MODE="off"; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --quiet)       VERBOSE=false; shift ;;
    --ui)          UI_MODE="panel"; shift ;;
    --no-ui)       UI_MODE="plain"; shift ;;
    --serve)       SERVE=true; shift ;;
    --serve=*)     SERVE=true; SERVE_PORT="${1#*=}"; shift ;;
    --attach)      ATTACH=true; shift ;;
    # Todo o cabecalho, ate a primeira linha de codigo: um intervalo fixo
    # (sed '2,70p') truncava o help sempre que a doc crescia.
    -h|--help)     awk 'NR > 1 && /^set -e/ { exit } NR > 1' "$0"; exit 0 ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

PHASES_DIR=".phases"
LOG_DIR=".phases/logs"
PROMPT_DIR=".phases/prompts"
MANIFEST="$PHASES_DIR/manifest.txt"
PROGRESS_FILE="$PHASES_DIR/.progress"

# Contrato publico de estado — ver o cabecalho. Tres consumidores: painel,
# dashboard web e qualquer ferramenta externa.
STATE_FILE="$PHASES_DIR/state.json"
EVENTS_FILE="$PHASES_DIR/events.jsonl"
UI_DIR="$PHASES_DIR/ui"
UI_MSG_FILE="$UI_DIR/messages.log"
# Inferencia por task. Em --attach vai para um arquivo proprio: o pintor do run
# original continua escrevendo o dele, e dois processos disputando o mesmo
# arquivo fariam os dois piscarem entre um resultado e outro.
UI_TASKPROG="$UI_DIR/taskprog.txt"
$ATTACH && UI_TASKPROG="$UI_DIR/taskprog.attach.txt"
# Numeros da janela desenhada no ultimo frame (start|total|budget|cur_row). O
# pintor precisa deles para mover a rolagem, e nao consegue le-los da memoria:
# ui_frame roda dentro de uma substituicao de comando. Mesmo motivo do taskprog
# para separar o do --attach: dois processos disputando o arquivo fariam a
# janela dos dois pular.
UI_VIEWPORT="$UI_DIR/.viewport"
$ATTACH && UI_VIEWPORT="$UI_DIR/.viewport.attach"
UI_HTML="$UI_DIR/index.html"

MAX_LIMIT_WAITS="${RALPH_MAX_LIMIT_WAITS:-20}"
LIMIT_WAIT_DEFAULT="${RALPH_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${RALPH_LIMIT_BUFFER:-60}"

NOTIFY_CMD="${RALPH_NOTIFY_CMD:-}"
NOTIFY_TIMEOUT="${RALPH_NOTIFY_TIMEOUT:-20}"
# Fora de um repo git o preflight aborta depois; o fallback existe so para o
# --help e para os modos de teste nao morrerem sob `set -e`.
PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel 2> /dev/null || pwd)")"

TEST_CMD=""
SAIL_BIN=""
LIMIT_WAITS=0

UI_ACTIVE=false
UI_PAINTER_PID=""
UI_FPS="${RALPH_UI_FPS:-2}"
# Navegacao por teclado na tabela. Nao viola a invariante 2 ("zero perguntas"):
# o run nunca espera por tecla — a leitura tem timeout e ela substitui o proprio
# sleep entre frames. Sem tecla, o comportamento e identico ao de antes.
UI_KEYS="${RALPH_UI_KEYS:-1}"
# Topo da janela da tabela: -1 = auto (segue a fase corrente), >= 0 = fixado
# pelo dev. Vive no processo do pintor, unico que le teclado.
UI_SCROLL=-1
UI_KEY=""
# Termios de antes do painel. O `read -s` do pintor desliga o eco e o restaura
# sozinho ao voltar — mas o pintor morre por sinal (ui_stop, Ctrl-C), e ai o
# restore nao acontece e o dev fica com um terminal mudo depois do run.
UI_TTY_STATE=""
SERVE_PID=""
SERVE_URL=""
RUN_START_EPOCH=0

# Estado corrente, espelhado no state.json a cada state_sync.
ST_RUN_STATUS="starting"
ST_PHASE_NUM=0
ST_PHASE_SEQ=0
ST_PHASE_TOTAL=0
ST_PHASE_TITLE=""
ST_PHASE_STATUS="pending"
ST_PHASE_START=0
ST_CYCLE=0
ST_GATE0="pending"
ST_GATE1="pending"
ST_GATE2="pending"
ST_GATE3="pending"
ST_LIMIT_UNTIL=0
ST_LIMIT_WAITING=0
ST_STDERR_LOG=""
ST_ACTIVITY=""
ST_LAST_ERROR=""
ST_STAGE_START=0
ST_STDOUT_LOG=""
GATE_STARTED_AT=0
FAILED_NUMS=""
RALPH_PID=$$
RUN_ID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Com o painel ativo o placar nao vai para o terminal (o quadro ocupa as
# ultimas linhas e e repintado no lugar); vai para o messages.log, de onde o
# painel mostra as ultimas linhas. Sem painel o caminho e o de sempre, byte a
# byte — e o que mantem nohup/CI/pipe identicos ao ralph pre-painel.
ui_sink() {
  printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$UI_MSG_FILE" 2> /dev/null || true
}

log()     { if $UI_ACTIVE; then ui_sink info "$1"; else echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; fi; }
success() { if $UI_ACTIVE; then ui_sink ok   "$1"; else echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; fi; }
warn()    { if $UI_ACTIVE; then ui_sink warn "$1"; else echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; fi; }
fail()    { if $UI_ACTIVE; then ui_sink fail "$1"; else echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; fi; }

# ---------------------------------------------------------------------------
# Notificacao externa (opcional)
# ---------------------------------------------------------------------------

# notify <evento> <mensagem>
#
# No-op sem RALPH_NOTIFY_CMD. O comando externo roda sob `timeout` e com
# stdin fechado: um adaptador travado (rede lenta, prompt acidental) nao pode
# parar o run nem consumir o manifest lido pelo loop de fases. Todo erro e
# engolido — invariante: notificar nunca altera o resultado do run.
notify() {
  [ -n "$NOTIFY_CMD" ] || return 0
  local event="$1" message="${2:-}"

  RALPH_EVENT="$event" \
  RALPH_PROJECT="$PROJECT_NAME" \
  RALPH_ENGINE="$ENGINE" \
    timeout "$NOTIFY_TIMEOUT" \
    bash -c "$NOTIFY_CMD \"\$@\"" _ "$event" "$message" \
    > /dev/null 2>&1 < /dev/null || true

  return 0
}

# Primeira linha util do GATE_CAUSE, curta o bastante para caber numa celula do
# painel. O texto integral continua no terminal e nos logs.
gate_cause_summary() {
  printf '%s' "$GATE_CAUSE" | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-100 || true
}

format_duration() {
  local total_seconds=$1
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$seconds"
  else
    printf "%ds" "$seconds"
  fi
}

# ---------------------------------------------------------------------------
# Estado estruturado — .phases/state.json + .phases/events.jsonl
#
# CONTRATO PUBLICO. O painel, o dashboard web e ferramentas externas leem
# daqui; nenhum deles parseia o placar humano. Escrever estado nunca pode
# falhar o run: todo erro e engolido, igual ao notify.
# ---------------------------------------------------------------------------

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # Controles que sobraram quebrariam o JSON — o dashboard so precisa do texto.
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Ecoa o status de uma fase pelo numero, para o snapshot e para o painel.
phase_status_of() {
  local num="$1" file="$2"

  if [ "$num" -lt "$FROM_PHASE" ]; then
    echo "skipped"
  elif [ "$num" = "$ST_PHASE_NUM" ] && [ "$ST_PHASE_STATUS" = "running" ]; then
    echo "running"
  elif is_phase_done "$file"; then
    echo "done"
  elif [[ " ${FAILED_NUMS} " == *" $num "* ]]; then
    echo "failed"
  else
    echo "pending"
  fi
}

# Ultima linha nao-vazia do stderr do engine: prova de vida no painel e no web.
current_progress_line() {
  [ -n "$ST_STDERR_LOG" ] && [ -s "$ST_STDERR_LOG" ] || return 0
  grep -v '^[[:space:]]*$' "$ST_STDERR_LOG" 2> /dev/null | tail -n 1 | cut -c1-160 || true
}

# state.json reescrito por tmp + mv: `mv` no mesmo filesystem e atomico, entao
# um leitor concorrente ve a versao velha OU a nova, nunca meio arquivo. Escrever
# por cima do proprio state.json daria JSON invalido a quem lesse no meio.
state_sync() {
  [ -d "$PHASES_DIR" ] || return 0

  local tmp now progress
  now=$(date +%s)
  tmp="$STATE_FILE.tmp.$$"
  progress="$(current_progress_line)"

  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "project": "%s",\n'   "$(json_escape "$PROJECT_NAME")"
    printf '  "engine": "%s",\n'    "$ENGINE"
    printf '  "input": "%s",\n'     "$(json_escape "$INPUT_FILE")"
    printf '  "test_cmd": "%s",\n'  "$(json_escape "$TEST_CMD")"
    printf '  "started_at": %d,\n'  "$RUN_START_EPOCH"
    printf '  "updated_at": %d,\n'  "$now"
    printf '  "run_status": "%s",\n' "$ST_RUN_STATUS"
    printf '  "phase": {"num": %d, "seq": %d, "total": %d, "title": "%s", "status": "%s", "cycle": %d, "max_cycles": %d, "started_at": %d},\n' \
      "$ST_PHASE_NUM" "$ST_PHASE_SEQ" "$ST_PHASE_TOTAL" "$(json_escape "$ST_PHASE_TITLE")" \
      "$ST_PHASE_STATUS" "$ST_CYCLE" "$MAX_CYCLES" "$ST_PHASE_START"
    printf '  "gates": {"0": "%s", "1": "%s", "2": "%s", "3": "%s"},\n' \
      "$ST_GATE0" "$ST_GATE1" "$ST_GATE2" "$ST_GATE3"
    printf '  "limit": {"waiting": %s, "until": %d, "waits": %d, "max_waits": %d},\n' \
      "$([ "$ST_LIMIT_WAITING" = "1" ] && echo true || echo false)" \
      "$ST_LIMIT_UNTIL" "$LIMIT_WAITS" "$MAX_LIMIT_WAITS"
    printf '  "progress_line": "%s",\n' "$(json_escape "$progress")"
    printf '  "activity": "%s",\n'      "$(json_escape "$ST_ACTIVITY")"
    printf '  "last_error": "%s",\n'    "$(json_escape "$ST_LAST_ERROR")"
    printf '  "pid": %d,\n'             "$RALPH_PID"
    printf '  "run_id": "%s",\n'        "$(json_escape "$RUN_ID")"
    printf '  "phases": [\n'

    local first=1 file num title status
    if [ -f "$MANIFEST" ]; then
      while IFS='|' read -r file num title; do
        [ -n "$num" ] || continue
        status="$(phase_status_of "$num" "$file")"
        [ "$first" = "1" ] || printf ',\n'
        first=0
        printf '    {"num": %d, "title": "%s", "status": "%s"}' \
          "$num" "$(json_escape "$title")" "$status"
      done < <(manifest_entries)
    fi

    printf '\n  ]\n}\n'
  } > "$tmp" 2> /dev/null && mv -f "$tmp" "$STATE_FILE" 2> /dev/null || rm -f "$tmp" 2> /dev/null

  ui_state_cache
  return 0
}

# Cache achatado para o painel. O state.json e o contrato publico (JSON, pro
# web); o painel roda em bash sem jq garantido, entao le key=value daqui. Nao e
# duplicacao de contrato: e um indice privado, derivado do mesmo estado.
ui_state_cache() {
  local tmp="$UI_DIR/.state.tmp.$$"
  [ -d "$UI_DIR" ] || return 0

  {
    printf 'run_status=%s\n'  "$ST_RUN_STATUS"
    printf 'phase_num=%s\n'   "$ST_PHASE_NUM"
    printf 'phase_seq=%s\n'   "$ST_PHASE_SEQ"
    printf 'phase_total=%s\n' "$ST_PHASE_TOTAL"
    printf 'phase_title=%s\n' "${ST_PHASE_TITLE//$'\n'/ }"
    printf 'cycle=%s\n'       "$ST_CYCLE"
    printf 'max_cycles=%s\n'  "$MAX_CYCLES"
    printf 'phase_start=%s\n' "$ST_PHASE_START"
    printf 'gate0=%s\n'       "$ST_GATE0"
    printf 'gate1=%s\n'       "$ST_GATE1"
    printf 'gate2=%s\n'       "$ST_GATE2"
    printf 'gate3=%s\n'       "$ST_GATE3"
    printf 'test_cmd=%s\n'    "${TEST_CMD//$'\n'/ }"
    printf 'limit_waiting=%s\n' "$ST_LIMIT_WAITING"
    printf 'limit_until=%s\n' "$ST_LIMIT_UNTIL"
    printf 'progress=%s\n'    "$(current_progress_line)"
    printf 'activity=%s\n'    "${ST_ACTIVITY//$'\n'/ }"
    printf 'last_error=%s\n'  "${ST_LAST_ERROR//$'\n'/ }"
    printf 'stage_start=%s\n' "$ST_STAGE_START"
    printf 'stderr_log=%s\n'  "$ST_STDERR_LOG"
    printf 'stdout_log=%s\n'  "$ST_STDOUT_LOG"
    printf 'pid=%s\n'         "$RALPH_PID"
    printf 'run_id=%s\n'      "$RUN_ID"
    printf 'started=%s\n'     "$RUN_START_EPOCH"
    # O --attach desenha o painel de um run alheio: sem isso o cabecalho dele
    # mostraria a engine default em vez da que o run de verdade esta usando.
    printf 'engine=%s\n'      "$ENGINE"
    printf 'project=%s\n'     "$PROJECT_NAME"
  } > "$tmp" 2> /dev/null && mv -f "$tmp" "$UI_DIR/state.env" 2> /dev/null || rm -f "$tmp" 2> /dev/null

  local ptmp="$UI_DIR/.phases.tmp.$$"
  if [ -f "$MANIFEST" ]; then
    {
      local file num title
      while IFS='|' read -r file num title; do
        [ -n "$num" ] || continue
        printf '%s|%s|%s\n' "$num" "$(phase_status_of "$num" "$file")" "$title"
      done < <(manifest_entries)
    } > "$ptmp" 2> /dev/null && mv -f "$ptmp" "$UI_DIR/phases.txt" 2> /dev/null || rm -f "$ptmp" 2> /dev/null
  fi

  ui_tasks_cache
  return 0
}

# Rotulo curto de cada task de uma fase, na ordem em que aparecem — a MESMA
# posicao que o gate 3 usa como indice. Tira o markdown e o rotulo global
# (`T33 —`) que um PHASES.md multi-fase carrega.
extract_task_labels() {
  sed -nE 's/^[[:space:]]*- \[[ xX]\][[:space:]]*(.*)$/\1/p' "$PHASES_DIR/$1" 2> /dev/null \
    | sed -E 's/\*\*//g; s/^\*?T[0-9]+[[:space:]]*[—–-][[:space:]]*//; s/^Task:[[:space:]]*//; s/[[:space:]]+$//' \
    | awk 'NF { printf "%d|%s\n", ++n, $0 }'
}

# Bloco inteiro de uma task: a linha `- [ ]` mais as linhas de continuacao
# indentadas, ate a proxima task ou o fim do bloco.
#
# Ler so a linha do titulo era o motivo de a inferencia nunca sair do lugar: num
# PHASES.md de verdade o titulo e prosa ("Job assincrono de import") e TODO o
# artefato concreto — `Arquivos:`, `Testes:`, nomes de classe — vive nas
# continuacoes. Sem elas o conjunto de ancoras saia vazio.
extract_task_block() {
  local phase_file="$1" want="$2"
  awk -v want="$want" '
    /^[[:space:]]*- \[[ xX]\]/ {
      n++
      if (n > want) exit
      inblock = (n == want)
      if (inblock) { print; next }
    }
    # Linha nao indentada encerra o bloco (heading, paragrafo solto).
    inblock && /^[^[:space:]]/ { exit }
    inblock { print }
  ' "$PHASES_DIR/$phase_file" 2> /dev/null
}

# Ancoras de uma task: os identificadores de codigo que o bloco dela nomeia —
# conteudo entre crases, CamelCase, snake_case, caminhos e nomes de arquivo.
# Sao o unico elo entre a linguagem da task e o que aparece no disco.
#
# Caminho vence identificador: quando a task declara arquivos, sao eles que
# medem a task ("o artefato que ela nomeia ja existe?"). Identificador solto so
# entra quando nao ha nenhum caminho — senao um `WhatsappConnectionStatus`
# citado de passagem valeria tanto quanto o arquivo que a task cria.
extract_task_anchors() {
  local phase_file="$1" want="$2" block tokens paths
  block="$(extract_task_block "$phase_file" "$want")"
  [ -n "$block" ] || return 0

  # tr -c: qualquer coisa fora do alfabeto de caminho vira quebra de linha. Sem
  # isso um trecho entre crases com espacos (`status !== Foo::Bar`) viraria uma
  # ancora unica que jamais casa com um caminho.
  tokens="$(printf '%s' "$block" \
    | tr -c 'A-Za-z0-9_/.-' '\n' \
    | sed -E 's#^/+##; s/^[^A-Za-z0-9_]+//; s/[^A-Za-z0-9_/.-]+$//' \
    | awk 'length($0) >= 5' | sort -u)"

  # Candidato a caminho: tem extensao, ou tem barra E algum sinal de nome de
  # codigo (maiuscula ou underscore). So a barra nao basta — prosa tecnica em
  # portugues produz `try/catch` e `o/grupo`, que jamais casam com a arvore e
  # so diluiriam o percentual da task.
  paths="$(printf '%s\n' "$tokens" \
    | awk '$0 ~ /\.[A-Za-z0-9]{2,4}$/ || ($0 ~ /\// && $0 ~ /[A-Z_]/)' \
    | head -n 12)"
  if [ -n "$paths" ]; then
    printf '%s\n' "$paths"
    return 0
  fi

  printf '%s\n' "$tokens" \
    | awk '$0 ~ /[_\/.]/ || $0 ~ /[a-z][A-Z]/' \
    | head -n 12
}

# Estado do checkbox de cada task da fase: `indice|x` ou `indice| `.
#
# E o sinal de progresso que se move DURANTE a sessao — o engine e instruido a
# trocar `- [ ]` por `- [x]` quando os testes daquela task passam. Nao e
# veredito: o gate 3 confere task a task depois e sempre vence. `.phases/` esta
# em .git/info/exclude, entao marcar nao suja a arvore nem falsifica o gate 1.
extract_task_checks() {
  awk '
    match($0, /^[[:space:]]*- \[[ xX]\]/) {
      n++
      c = substr($0, RSTART + RLENGTH - 2, 1)
      printf "%d|%s\n", n, (c == "x" || c == "X") ? "x" : "-"
    }
  ' "$PHASES_DIR/$1" 2> /dev/null
}

# tasks.txt: fase|indice|status|rotulo. Uma linha por task de todas as fases.
#
# O status vem em ordem decrescente de autoridade:
#   1. fase concluida            => done
#   2. veredito do gate 3        => done | partial
#   3. checkbox `- [x]` na fase  => declared (o engine marcou; nao e veredito)
#   4. nada                      => pending
#
# O checkbox nunca sobrescreve veredito: uma task marcada pelo engine e depois
# reprovada pelo gate 3 tem que aparecer como Incompleta, e nao de verde.
ui_tasks_cache() {
  [ -f "$MANIFEST" ] || return 0
  local tmp="$UI_DIR/.tasks.tmp.$$"

  {
    local file num title idx label status vfile checks pstatus
    while IFS='|' read -r file num title; do
      [ -n "$num" ] || continue
      vfile="$UI_DIR/verdicts-$num.txt"
      pstatus="$(phase_status_of "$num" "$file")"
      checks="$(extract_task_checks "$file")"
      while IFS='|' read -r idx label; do
        [ -n "$idx" ] || continue
        if [ "$pstatus" = "done" ]; then
          status="done"
        elif [ -f "$vfile" ] && grep -q "^$idx|" "$vfile" 2> /dev/null; then
          case "$(grep "^$idx|" "$vfile" | tail -1 | cut -d'|' -f2)" in
            DONE) status="done" ;;
            *)    status="partial" ;;
          esac
        elif [ "$(printf '%s\n' "$checks" | awk -F'|' -v i="$idx" '$1 == i { print $2; exit }')" = "x" ]; then
          status="declared"
        else
          status="pending"
        fi
        printf '%s|%s|%s|%s\n' "$num" "$idx" "$status" "$label"
      done < <(extract_task_labels "$file")
    done < <(manifest_entries)
  } > "$tmp" 2> /dev/null && mv -f "$tmp" "$UI_DIR/tasks.txt" 2> /dev/null || rm -f "$tmp" 2> /dev/null

  return 0
}

# state_event <evento> [par chave=valor]...
# Uma linha JSON por transicao, append-only. Nunca reescrito: o historico do run
# e o que permite ao dashboard montar timeline e duracao por gate.
state_event() {
  [ -d "$PHASES_DIR" ] || return 0
  local event="$1"; shift

  {
    printf '{"ts": %d, "event": "%s", "phase": %d, "cycle": %d' \
      "$(date +%s)" "$(json_escape "$event")" "$ST_PHASE_NUM" "$ST_CYCLE"
    local kv key value
    for kv in "$@"; do
      key="${kv%%=*}"
      value="${kv#*=}"
      if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf ', "%s": %s' "$(json_escape "$key")" "$value"
      else
        printf ', "%s": "%s"' "$(json_escape "$key")" "$(json_escape "$value")"
      fi
    done
    printf '}\n'
  } >> "$EVENTS_FILE" 2> /dev/null || true

  state_sync
  return 0
}

# Os 7 eventos do hook tambem entram no events.jsonl: um consumidor externo ve
# a corrente inteira sem precisar registrar RALPH_NOTIFY_CMD.
notify_and_record() {
  state_event "$1" "message=$2"
  notify "$1" "$2"
}

# set_activity <texto>
#
# Atribuir a ST_ACTIVITY sem sincronizar era o bug do painel congelado: o
# state_sync so acontecia em transicao de evento (gate_start/gate_end), e o
# primeiro gate de uma fase so roda DEPOIS que o engine termina. A sessao de
# implementacao — a etapa mais longa do run — passava inteira sem republicar,
# entao o painel mostrava "preparando" por minutos.
set_activity() {
  ST_ACTIVITY="$1"
  ST_STAGE_START=$(date +%s)
  state_sync
}

gate_start() {
  GATE_STARTED_AT=$(date +%s)
  case "$1" in
    0) ST_GATE0="running" ;; 1) ST_GATE1="running" ;;
    2) ST_GATE2="running" ;; 3) ST_GATE3="running" ;;
  esac
  state_event gate_start "gate=$1"
}

# gate_end <gate> <veredito: pass|fail|skip>
gate_end() {
  local gate="$1" verdict="$2" duration=$(($(date +%s) - GATE_STARTED_AT))
  case "$gate" in
    0) ST_GATE0="$verdict" ;; 1) ST_GATE1="$verdict" ;;
    2) ST_GATE2="$verdict" ;; 3) ST_GATE3="$verdict" ;;
  esac
  state_event gate_end "gate=$gate" "verdict=$verdict" "duration=$duration"
}

# ---------------------------------------------------------------------------
# Painel ANSI — tela cheia (alternate screen buffer)
#
# Invariante: o painel e uma camada de APRESENTACAO. Nunca altera veredito de
# gate nem exit code, e qualquer falha ao desenhar cai para o placar.
#
# Por que alternate screen e nao um quadro de altura fixa: a tabela de fases e
# tasks cresce com o documento, e um quadro fixo so poderia repintar movendo o
# cursor N linhas para cima — N precisaria ser constante. Com o buffer alternado
# o painel manda na tela inteira, o layout pode ter qualquer altura, e ao sair o
# terminal volta com o scrollback anterior intacto.
#
# O placar (log/success/warn/fail) nao some: vai para .phases/ui/messages.log e
# as ultimas linhas aparecem no rodape do painel. Saida longa (causa de gate
# vermelho, relatorio final) e impressa DEPOIS de ui_stop, na tela normal.
# ---------------------------------------------------------------------------

UI_SPINNER='⣾⣽⣻⢿⡿⣟⣯⣷'

# Paleta do painel. Separada das cores do placar: o placar tem 4 niveis, o
# painel precisa de tom neutro para moldura e rotulo.
UI_C_FRAME='\033[38;5;238m'
UI_C_LABEL='\033[38;5;39m'
UI_C_TITLE='\033[1;38;5;45m'
UI_C_DIM='\033[38;5;245m'
UI_C_OK='\033[38;5;41m'
UI_C_RUN='\033[38;5;214m'
UI_C_ERR='\033[38;5;203m'
UI_C_PEND='\033[38;5;240m'
# Task que o engine declarou pronta mas nenhum gate confirmou ainda: verde
# apagado, distinto do verde de veredito.
UI_C_DECL='\033[38;5;29m'
UI_C_CUR='\033[48;5;53m'
UI_C_OFF='\033[0m'

ui_should_activate() {
  # --verbose ocupa o terminal com os dois streams do engine: o painel sairia
  # por cima do output ao vivo.
  $VERBOSE && return 1
  [ "$UI_MODE" = "plain" ] && return 1
  # Sem TTY (nohup, CI, pipe) nenhuma sequencia de escape pode sair — nem com
  # RALPH_UI=panel. Redirecionar um painel para arquivo produz lixo binario.
  [ -t 1 ] || return 1
  return 0
}

ui_term_cols() {
  local n
  n=$(tput cols 2> /dev/null || echo 80)
  [[ "$n" =~ ^[0-9]+$ ]] || n=80
  [ "$n" -lt 40 ] && n=40
  echo "$n"
}

ui_term_lines() {
  local n
  n=$(tput lines 2> /dev/null || echo 24)
  [[ "$n" =~ ^[0-9]+$ ]] || n=24
  [ "$n" -lt 10 ] && n=10
  echo "$n"
}

# Trunca e preenche pelo numero de CARACTERES. Nunca receba texto com escape
# aqui: `${#s}` contaria os bytes do escape e a coluna sairia do lugar. Para
# celula colorida, meca o texto plain com ui_padlen e concatene a cor por fora.
ui_cell() {
  local text="$1" width="$2"
  [ "$width" -lt 1 ] && width=1
  if [ "${#text}" -gt "$width" ]; then
    text="${text:0:$((width - 1))}…"
  fi
  printf '%s%*s' "$text" $((width - ${#text})) ''
}

ui_padlen() { local t="$1" w="$2"; local n=$((w - ${#t})); [ "$n" -lt 0 ] && n=0; printf '%*s' "$n" ''; }

ui_rule() { local n="$1" ch="${2:-─}"; local i=0; while [ "$i" -lt "$n" ]; do printf '%s' "$ch"; i=$((i + 1)); done; }

# Barra de progresso. Denominador 0 (fase sem task declarada) nao pode virar
# divisao por zero nem barra cheia enganosa.
ui_bar() {
  local done="$1" total="$2" width="$3"
  local filled=0 pct=0
  if [ "$total" -gt 0 ] 2> /dev/null; then
    pct=$((done * 100 / total))
    filled=$((done * width / total))
  fi
  [ "$filled" -gt "$width" ] && filled=$width
  printf '%b%s%b%b%s%b %3d%%' \
    "$UI_C_OK" "$(ui_rule "$filled" '█')" "$UI_C_OFF" \
    "$UI_C_PEND" "$(ui_rule $((width - filled)) '░')" "$UI_C_OFF" "$pct"
}

ui_status_label() {
  case "$1" in
    done)     printf '%b✓ Concluída%b'  "$UI_C_OK"   "$UI_C_OFF" ;;
    running)  printf '%b▶ Em execução%b' "$UI_C_RUN"  "$UI_C_OFF" ;;
    failed)   printf '%b✗ Falhou%b'      "$UI_C_ERR"  "$UI_C_OFF" ;;
    skipped)  printf '%b» Pulada%b'      "$UI_C_DIM"  "$UI_C_OFF" ;;
    partial)  printf '%b! Incompleta%b'  "$UI_C_ERR"  "$UI_C_OFF" ;;
    declared) printf '%b✓ Declarada%b'   "$UI_C_DECL" "$UI_C_OFF" ;;
    *)        printf '%b· Pendente%b'    "$UI_C_PEND" "$UI_C_OFF" ;;
  esac
}
# Status de uma task da fase corrente. O veredito do gate 3, quando existe,
# SEMPRE vence a inferencia: presenca de arquivo nao e prova de implementacao.
# `~` marca o que e inferido, para nao passar por veredito.
ui_task_state() {
  local status="$1" pct="$2" active="$3"
  case "$status" in
    done|partial|failed|declared) printf '%s' "$status"; return ;;
  esac
  [ -z "$pct" ] && { printf 'pending'; return; }
  [ "$active" = "1" ] && { printf 'active:%s' "$pct"; return; }
  [ "$pct" -gt 0 ] 2> /dev/null && { printf 'partialpct:%s' "$pct"; return; }
  printf 'pending'
}
ui_task_plain() {
  case "$1" in
    active:*)     printf '▶ ~%s%%' "${1#active:}" ;;
    partialpct:*) printf '◐ ~%s%%' "${1#partialpct:}" ;;
    *)            ui_status_plain "$1" ;;
  esac
}
ui_task_label() {
  case "$1" in
    active:*)     printf '%b▶ ~%s%%%b' "$UI_C_RUN"  "${1#active:}" "$UI_C_OFF" ;;
    partialpct:*) printf '%b◐ ~%s%%%b' "$UI_C_DIM"  "${1#partialpct:}" "$UI_C_OFF" ;;
    *)            ui_status_label "$1" ;;
  esac
}

ui_status_plain() {
  case "$1" in
    done) printf '✓ Concluída' ;; running) printf '▶ Em execução' ;;
    failed) printf '✗ Falhou' ;;  skipped) printf '» Pulada' ;;
    partial) printf '! Incompleta' ;; declared) printf '✓ Declarada' ;;
    *) printf '· Pendente' ;;
  esac
}

# So marcas de largura 1. Caractere East-Asian Wide (⏭ U+23ED, ⏸ U+23F8) conta
# 1 em ${#s} e ocupa 2 colunas: a borda direita anda para fora.
ui_gate_mark()  {
  case "$1" in pass) printf '✓' ;; fail) printf '✗' ;; skip) printf '⊘' ;;
               running) printf '%s' "$2" ;; *) printf '·' ;; esac
}
ui_gate_color() {
  case "$1" in pass) printf '%b' "$UI_C_OK" ;; fail) printf '%b' "$UI_C_ERR" ;;
               running) printf '%b' "$UI_C_RUN" ;; skip) printf '%b' "$UI_C_DIM" ;;
               *) printf '%b' "$UI_C_PEND" ;; esac
}

# Le o cache achatado que o state_sync grava. Popula UIV_* no escopo do chamador.
ui_load_state() {
  UIV_run_status=""; UIV_phase_num=0; UIV_phase_seq=0; UIV_phase_total=0
  UIV_phase_title=""; UIV_cycle=0; UIV_max_cycles=0; UIV_phase_start=0
  UIV_gate0=""; UIV_gate1=""; UIV_gate2=""; UIV_gate3=""; UIV_test_cmd=""
  UIV_limit_waiting=0; UIV_limit_until=0; UIV_progress=""; UIV_activity=""
  UIV_last_error=""; UIV_pid=""; UIV_run_id=""; UIV_started=0
  UIV_stage_start=0; UIV_stderr_log=""; UIV_stdout_log=""
  UIV_engine=""; UIV_project=""

  [ -f "$UI_DIR/state.env" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      run_status) UIV_run_status="$v" ;;   phase_num) UIV_phase_num="$v" ;;
      phase_seq) UIV_phase_seq="$v" ;;     phase_total) UIV_phase_total="$v" ;;
      phase_title) UIV_phase_title="$v" ;; cycle) UIV_cycle="$v" ;;
      max_cycles) UIV_max_cycles="$v" ;;   phase_start) UIV_phase_start="$v" ;;
      gate0) UIV_gate0="$v" ;; gate1) UIV_gate1="$v" ;;
      gate2) UIV_gate2="$v" ;; gate3) UIV_gate3="$v" ;;
      test_cmd) UIV_test_cmd="$v" ;;       limit_waiting) UIV_limit_waiting="$v" ;;
      limit_until) UIV_limit_until="$v" ;; progress) UIV_progress="$v" ;;
      activity) UIV_activity="$v" ;;       last_error) UIV_last_error="$v" ;;
      pid) UIV_pid="$v" ;;                 run_id) UIV_run_id="$v" ;;
      started) UIV_started="$v" ;;         stage_start) UIV_stage_start="$v" ;;
      stderr_log) UIV_stderr_log="$v" ;;   stdout_log) UIV_stdout_log="$v" ;;
      engine) UIV_engine="$v" ;;           project) UIV_project="$v" ;;
    esac
  done < "$UI_DIR/state.env"
}

# --- secoes -----------------------------------------------------------------
# Cada secao ecoa linhas prontas. Somar uma secao nova ao painel e escrever mais
# uma funcao e chama-la em ui_frame — o layout nao tem altura fixa a respeitar.

ui_sec_header() {
  local w="$1"
  local status_txt status_col
  case "$UIV_run_status" in
    running)  status_txt="▶ Em execução"; status_col="$UI_C_RUN" ;;
    done)     status_txt="✓ Concluído";   status_col="$UI_C_OK" ;;
    failed)   status_txt="✗ Falhou";      status_col="$UI_C_ERR" ;;
    aborted)  status_txt="✗ Abortado";    status_col="$UI_C_ERR" ;;
    *)        status_txt="· Iniciando";   status_col="$UI_C_PEND" ;;
  esac
  [ "$UIV_limit_waiting" = "1" ] && { status_txt="~ Aguardando limite"; status_col="$UI_C_RUN"; }

  local elapsed="—"
  [ "${UIV_started:-0}" -gt 0 ] 2> /dev/null && elapsed="$(format_duration $(($(date +%s) - UIV_started)))"

  printf '%bRALPH%b\n' "$UI_C_TITLE" "$UI_C_OFF"
  # Larguras proporcionais: em terminal estreito o header nao pode passar de w,
  # senao o proprio terminal quebra a linha e todo o resto do frame desce.
  local c1=$((w / 4)) c2=12
  [ "$c1" -gt 30 ] && c1=30
  [ "$c1" -lt 10 ] && c1=10

  printf '%bProjeto:%b %s  %bEngine:%b %s  %bStatus:%b %b%s%b\n' \
    "$UI_C_LABEL" "$UI_C_OFF" "$(ui_cell "$PROJECT_NAME" "$c1")" \
    "$UI_C_LABEL" "$UI_C_OFF" "$(ui_cell "$ENGINE" "$c2")" \
    "$UI_C_LABEL" "$UI_C_OFF" "$status_col" "$status_txt" "$UI_C_OFF"
  printf '%bDuração:%b %s  %bRun:%b    %s  %bPID:%b    %s\n' \
    "$UI_C_LABEL" "$UI_C_OFF" "$(ui_cell "$elapsed" "$c1")" \
    "$UI_C_LABEL" "$UI_C_OFF" "$(ui_cell "$UIV_run_id" "$c2")" \
    "$UI_C_LABEL" "$UI_C_OFF" "$UIV_pid"
  printf '\n'
}

# Moldura com titulo centralizado, no estilo do mockup.
ui_box_top() {
  local w="$1" title="$2"
  local inner=$((w - 2))
  local t=" $title "
  local left=$(((inner - ${#t}) / 2))
  local right=$((inner - ${#t} - left))
  [ "$left" -lt 0 ] && { left=0; right=0; t="${t:0:$inner}"; }
  printf '%b┌%s%b %b%s%b %b%s┐%b\n' \
    "$UI_C_FRAME" "$(ui_rule "$left")" "$UI_C_OFF" \
    "$UI_C_LABEL" "$title" "$UI_C_OFF" \
    "$UI_C_FRAME" "$(ui_rule "$right")" "$UI_C_OFF"
}
ui_box_bot() { printf '%b└%s┘%b\n' "$UI_C_FRAME" "$(ui_rule $(($1 - 2)))" "$UI_C_OFF"; }
# Linha de conteudo. <plain> so para medir, <colored> e o que sai na tela.
ui_box_row() {
  local w="$1" plain="$2" colored="$3"
  local inner=$((w - 4))
  if [ "${#plain}" -gt "$inner" ]; then
    plain="${plain:0:$((inner - 1))}…"
    colored="$plain"
  fi
  printf '%b│%b %b%s %b│%b\n' \
    "$UI_C_FRAME" "$UI_C_OFF" "$colored" "$(ui_padlen "$plain" "$inner")" \
    "$UI_C_FRAME" "$UI_C_OFF"
}

ui_sec_progress_lines() {
  local w="$1"
  local pdone=0 ptotal=0 tdone=0 ttotal=0 num status
  while IFS='|' read -r num status _; do
    [ -n "$num" ] || continue
    ptotal=$((ptotal + 1))
    [ "$status" = "done" ] && pdone=$((pdone + 1))
  done < "$UI_DIR/phases.txt" 2> /dev/null
  while IFS='|' read -r _ _ status _; do
    [ -n "$status" ] || continue
    ttotal=$((ttotal + 1))
    [ "$status" = "done" ] && tdone=$((tdone + 1))
  done < "$UI_DIR/tasks.txt" 2> /dev/null

  local barw=$((w - 26))
  [ "$barw" -lt 8 ] && barw=8
  [ "$barw" -gt 30 ] && barw=30

  # O plain mede as MESMAS pecas do colorido: contar `0/2` (3 caracteres)
  # enquanto o colorido imprime `ui_cell ... 6` desalinha a borda em 3 colunas.
  local rf rt
  rf="$(ui_cell "$pdone/$ptotal" 6)"
  rt="$(ui_cell "$tdone/$ttotal" 6)"
  ui_box_row "$w" \
    "Fases  $rf  [$(ui_rule "$barw" '#') 100%]" \
    "$(printf '%bFases%b  %s  [%s]' "$UI_C_LABEL" "$UI_C_OFF" "$rf" "$(ui_bar "$pdone" "$ptotal" "$barw")")"
  ui_box_row "$w" \
    "Tasks  $rt  [$(ui_rule "$barw" '#') 100%]" \
    "$(printf '%bTasks%b  %s  [%s]' "$UI_C_LABEL" "$UI_C_OFF" "$rt" "$(ui_bar "$tdone" "$ttotal" "$barw")")"
}

ui_sec_current_lines() {
  local w="$1"
  local gate_now="—"
  if [ "$UIV_limit_waiting" = "1" ]; then
    local left=$((UIV_limit_until - $(date +%s)))
    [ "$left" -lt 0 ] && left=0
    gate_now="retoma em $(format_duration "$left")"
  else
    [ "$UIV_gate0" = "running" ] && gate_now="G0"
    [ "$UIV_gate1" = "running" ] && gate_now="G1"
    [ "$UIV_gate2" = "running" ] && gate_now="G2"
    [ "$UIV_gate3" = "running" ] && gate_now="G3"
  fi

  ui_box_row "$w" "Fase:  $UIV_phase_num · $UIV_phase_title" \
    "$(printf '%bFase:%b  %s · %s' "$UI_C_LABEL" "$UI_C_OFF" "$UIV_phase_num" "$UIV_phase_title")"
  ui_box_row "$w" "Ciclo: $UIV_cycle/$UIV_max_cycles   Gate: $gate_now" \
    "$(printf '%bCiclo:%b %s/%s   %bGate:%b %s' "$UI_C_LABEL" "$UI_C_OFF" "$UIV_cycle" "$UIV_max_cycles" "$UI_C_LABEL" "$UI_C_OFF" "$gate_now")"
  ui_box_row "$w" "Atividade: ${UIV_activity:-—}" \
    "$(printf '%bAtividade:%b %s' "$UI_C_LABEL" "$UI_C_OFF" "${UIV_activity:-—}")"
  ui_box_row "$w" "Último erro: ${UIV_last_error:-—}" \
    "$(printf '%bÚltimo erro:%b %b%s%b' "$UI_C_LABEL" "$UI_C_OFF" \
       "$([ -n "$UIV_last_error" ] && printf '%b' "$UI_C_ERR" || printf '%b' "$UI_C_DIM")" \
       "${UIV_last_error:-—}" "$UI_C_OFF")"
}

# Duas colunas quando cabe, empilhadas quando nao. `paste` alinharia mal com
# escapes de cor, entao cada lado e renderizado em buffer e casado por indice.
ui_sec_panels() {
  local w="$1"
  if [ "$w" -lt 100 ]; then
    ui_box_top "$w" "PROGRESSO";     ui_sec_progress_lines "$w"; ui_box_bot "$w"
    ui_box_top "$w" "TRABALHO ATUAL"; ui_sec_current_lines "$w"; ui_box_bot "$w"
    return 0
  fi

  local lw=$(((w - 2) / 2)) rw
  rw=$((w - 2 - lw))

  local left=() right=() line
  while IFS= read -r line; do left+=("$line"); done < <(ui_box_top "$lw" "PROGRESSO"; ui_sec_progress_lines "$lw"; ui_box_bot "$lw")
  while IFS= read -r line; do right+=("$line"); done < <(ui_box_top "$rw" "TRABALHO ATUAL"; ui_sec_current_lines "$rw"; ui_box_bot "$rw")

  local n=${#left[@]}
  [ ${#right[@]} -gt "$n" ] && n=${#right[@]}
  local i blank_l blank_r
  blank_l="$(printf '%*s' "$lw" '')"
  blank_r="$(printf '%*s' "$rw" '')"
  for ((i = 0; i < n; i++)); do
    printf '%s  %s\n' "${left[$i]:-$blank_l}" "${right[$i]:-$blank_r}"
  done
}

ui_sec_table() {
  local w="$1" budget="$2"
  local spin="$3"

  # Colunas caem por prioridade quando a largura aperta: Gates primeiro (o
  # cabecalho ja mostra o gate corrente), depois Tentativa.
  local c_id=4 c_status=15 c_try=10 c_gates=24
  local show_gates=1 show_try=1
  [ "$w" -lt 96 ] && { show_gates=0; c_gates=0; }
  [ "$w" -lt 74 ] && { show_try=0; c_try=0; }
  # Um espaco entre colunas: (n_cols - 1) separadores, e n_cols muda quando
  # Tentativa/Gates caem. Constante fixa aqui estourava a linha, e o
  # ui_box_row truncava a coluna Gates inteira com reticencia.
  local n_cols=$((3 + show_try + show_gates))
  local c_name=$((w - 4 - c_id - c_status - c_try - c_gates - (n_cols - 1)))
  [ "$c_name" -lt 12 ] && c_name=12

  local head_plain head_col
  head_plain="$(ui_cell 'ID' "$c_id") $(ui_cell 'Fase / Task' "$c_name") $(ui_cell 'Status' "$c_status")"
  [ "$show_try" = 1 ]   && head_plain+=" $(ui_cell 'Tentativa' "$c_try")"
  [ "$show_gates" = 1 ] && head_plain+=" $(ui_cell 'Gates' "$c_gates")"
  head_col="$(printf '%b%s%b' "$UI_C_LABEL" "$head_plain" "$UI_C_OFF")"

  # Monta as linhas: fase seguida das suas tasks.
  local rows_plain=() rows_col=() cur_row=-1
  local num status title tnum tstatus tlabel
  while IFS='|' read -r num status title; do
    [ -n "$num" ] || continue

    local gates_plain="" gates_col=""
    if [ "$show_gates" = 1 ]; then
      if [ "$num" = "$UIV_phase_num" ]; then
        local g gv
        for g in 0 1 2 3; do
          case "$g" in 0) gv="$UIV_gate0" ;; 1) gv="$UIV_gate1" ;; 2) gv="$UIV_gate2" ;; 3) gv="$UIV_gate3" ;; esac
          gates_plain+="G$g $(ui_gate_mark "$gv" "$spin") "
          gates_col+="$(printf '%bG%s%b %b%s%b ' "$UI_C_DIM" "$g" "$UI_C_OFF" "$(ui_gate_color "$gv")" "$(ui_gate_mark "$gv" "$spin")" "$UI_C_OFF")"
        done
      elif [ "$status" = "done" ]; then
        gates_plain="G0 ✓ G1 ✓ G2 ✓ G3 ✓ "
        gates_col="$(printf '%bG0 ✓ G1 ✓ G2 ✓ G3 ✓%b ' "$UI_C_OK" "$UI_C_OFF")"
      else
        gates_plain="G0 · G1 · G2 · G3 · "
        gates_col="$(printf '%bG0 · G1 · G2 · G3 ·%b ' "$UI_C_PEND" "$UI_C_OFF")"
      fi
    fi

    local try="-"
    [ "$num" = "$UIV_phase_num" ] && try="$UIV_cycle"
    [ "$status" = "done" ] && [ "$num" != "$UIV_phase_num" ] && try="1"

    local rp rc
    rp="$(ui_cell "F$num" "$c_id") $(ui_cell "$title" "$c_name") $(ui_cell "$(ui_status_plain "$status")" "$c_status")"
    rc="$(ui_cell "F$num" "$c_id") $(ui_cell "$title" "$c_name") $(ui_status_label "$status")$(ui_padlen "$(ui_status_plain "$status")" "$c_status")"
    if [ "$show_try" = 1 ]; then
      rp+=" $(ui_cell "$try" "$c_try")"; rc+=" $(ui_cell "$try" "$c_try")"
    fi
    if [ "$show_gates" = 1 ]; then
      rp+=" $(ui_cell "$gates_plain" "$c_gates")"
      rc+=" $gates_col$(ui_padlen "$gates_plain" "$c_gates")"
    fi

    [ "$num" = "$UIV_phase_num" ] && cur_row=${#rows_plain[@]}
    rows_plain+=("$rp"); rows_col+=("$rc")

    while IFS='|' read -r _p tnum tstatus tlabel; do
      local tp tc tpct="" tact="" tstate
      if [ "$num" = "$UIV_phase_num" ] && [ -f "$UI_TASKPROG" ]; then
        local prow
        prow="$(grep "^$tnum|" "$UI_TASKPROG" 2> /dev/null | head -1 || true)"
        tpct="$(printf '%s' "$prow" | cut -d'|' -f2)"
        tact="$(printf '%s' "$prow" | cut -d'|' -f3)"
      fi
      tstate="$(ui_task_state "$tstatus" "$tpct" "$tact")"
      tp="$(ui_cell "T$tnum" "$c_id") $(ui_cell "  ↳ $tlabel" "$c_name") $(ui_cell "$(ui_task_plain "$tstate")" "$c_status")"
      tc="$(ui_cell "T$tnum" "$c_id") $(printf '%b%s%b' "$UI_C_DIM" "$(ui_cell "  ↳ $tlabel" "$c_name")" "$UI_C_OFF") $(ui_task_label "$tstate")$(ui_padlen "$(ui_task_plain "$tstate")" "$c_status")"
      [ "$show_try" = 1 ]   && { tp+=" $(ui_cell '-' "$c_try")";   tc+=" $(ui_cell '-' "$c_try")"; }
      [ "$show_gates" = 1 ] && { tp+=" $(ui_cell '-' "$c_gates")"; tc+=" $(ui_cell '-' "$c_gates")"; }
      rows_plain+=("$tp"); rows_col+=("$tc")
    done < <(grep "^$num|" "$UI_DIR/tasks.txt" 2> /dev/null || true)
  done < <(cat "$UI_DIR/phases.txt" 2> /dev/null || true)

  # Janela deslizante. Em auto (UI_SCROLL < 0), com mais linhas do que
  # orcamento, centraliza na fase corrente em vez de cortar sempre o fim. Com o
  # dev navegando, o topo e dele — e so dele ate pedir auto de volta.
  local total=${#rows_plain[@]} start=0
  if [ "$UI_SCROLL" -ge 0 ] 2> /dev/null; then
    start="$UI_SCROLL"
  elif [ "$total" -gt "$budget" ] && [ "$cur_row" -ge 0 ]; then
    start=$((cur_row - budget / 2))
  fi
  start="$(ui_scroll_fit "$start" "$total" "$budget")"

  # Publica o que ESTE frame desenhou. Sem isso o pintor moveria a janela no
  # escuro: ele nao monta as linhas e nao sabe nem quantas existem.
  printf '%s|%s|%s|%s\n' "$start" "$total" "$budget" "$cur_row" \
    > "$UI_VIEWPORT" 2> /dev/null || true

  ui_box_top "$w" "FASES E TASKS"
  ui_box_row "$w" "$head_plain" "$head_col"
  printf '%b├%s┤%b\n' "$UI_C_FRAME" "$(ui_rule $((w - 2)))" "$UI_C_OFF"
  local i last=$((start + budget))
  [ "$last" -gt "$total" ] && last=$total
  for ((i = start; i < last; i++)); do
    if [ "$i" = "$cur_row" ]; then
      printf '%b│%b%b %s %b%b│%b\n' "$UI_C_FRAME" "$UI_C_OFF" "$UI_C_CUR" \
        "$(ui_cell "${rows_plain[$i]}" $((w - 4)))" "$UI_C_OFF" "$UI_C_FRAME" "$UI_C_OFF"
    else
      ui_box_row "$w" "${rows_plain[$i]}" "${rows_col[$i]}"
    fi
  done
  # Rodape so quando ha linha escondida — que e exatamente quando a dica de
  # navegacao importa. Fora disso a moldura fica limpa.
  if [ "$total" -gt "$last" ] || [ "$start" -gt 0 ]; then
    local foot="  … $total linhas, mostrando $((start + 1))–$last"
    if [ "$UI_KEYS" = "1" ]; then
      if [ "$UI_SCROLL" -ge 0 ] 2> /dev/null; then foot+=" · manual · a = auto"
      else foot+=" · ↑↓ rolar · a = auto"; fi
    fi
    ui_box_row "$w" "$foot" "$(printf '%b%s%b' "$UI_C_DIM" "$foot" "$UI_C_OFF")"
  fi
  ui_box_bot "$w"
}

# Clampa o topo da janela ao intervalo valido. Fora dele a tabela desenharia
# linhas vazias no fim (start alto demais) ou esconderia o comeco sem motivo.
# Com menos linhas que orcamento o unico topo valido e 0.
ui_scroll_fit() {
  local start="$1" total="$2" budget="$3"
  local max=$((total - budget))
  [ "$max" -lt 0 ] && max=0
  [ "$start" -gt "$max" ] && start="$max"
  [ "$start" -lt 0 ] && start=0
  printf '%s' "$start"
}

# ui_infer_tasks — qual task esta sendo trabalhada, e quanto dela ja apareceu.
#
# HEURISTICA, e o painel a rotula como tal. O engine roda numa sessao opaca:
# nenhum evento diz em que task ele esta. O que existe de concreto e (a) o texto
# da task, que nomeia identificadores de codigo, e (b) a arvore mudando. Casar
# um com o outro da o sinal mais honesto disponivel — "os artefatos que esta
# task nomeia ja existem no disco" — e nada mais forte que isso.
#
# NAO substitui o gate 3: presenca de arquivo nao e prova de implementacao
# correta. Por isso o veredito do gate 3, quando existe, sempre vence.
#
# Escreve $UI_TASKPROG: indice|pct|ativa(0|1)
ui_infer_tasks() {
  local phase_num="$1"
  local out="$UI_TASKPROG" tmp="$UI_TASKPROG.tmp.$$"
  local pf
  pf="$(printf 'phase-%02d.md' "$phase_num" 2> /dev/null)"
  [ -n "$phase_num" ] && [ "$phase_num" -gt 0 ] 2> /dev/null || { : > "$out" 2> /dev/null; return 0; }
  [ -f "$PHASES_DIR/$pf" ] || { : > "$out" 2> /dev/null; return 0; }

  local anchors="$UI_DIR/.anchors.$$" paths="$UI_DIR/.paths.$$"
  : > "$anchors"

  # Conta as tasks UMA vez e itera 1..N. A versao anterior decidia parar dentro
  # do laco a partir do resultado do proprio extract_*: uma task sem ancora
  # abortava a varredura e as seguintes nunca eram medidas.
  local ntasks n=1 a one
  ntasks="$(grep -cE '^[[:space:]]*- \[[ xX]\]' "$PHASES_DIR/$pf" 2> /dev/null || true)"
  [[ "$ntasks" =~ ^[0-9]+$ ]] || ntasks=0
  [ "$ntasks" -gt 40 ] && ntasks=40
  while [ "$n" -le "$ntasks" ]; do
    a="$(extract_task_anchors "$pf" "$n")"
    if [ -n "$a" ]; then
      while IFS= read -r one; do
        [ -n "$one" ] && printf '%s\t%s\n' "$n" "$one" >> "$anchors"
      done <<< "$a"
    fi
    n=$((n + 1))
  done

  # Nenhuma task nomeou artefato: nao ha o que inferir, e sair AQUI e
  # obrigatorio. O awk de duas passadas abaixo separa os arquivos por FNR/NR;
  # com o primeiro arquivo vazio ele lia o universo de caminhos como se fosse a
  # lista de ancoras — foi assim que o taskprog.txt de um run real virou 60 KB
  # de linhas `caminho|0|0` e a tabela ficou Pendente do inicio ao fim.
  if [ ! -s "$anchors" ]; then
    : > "$out" 2> /dev/null
    rm -f "$anchors" 2> /dev/null
    return 0
  fi

  # Universo de caminhos: o que o git rastreia mais o que acabou de mudar. O
  # segundo e o que faz a inferencia se mexer durante a sessao.
  {
    git ls-files 2> /dev/null || true
    git status --porcelain -uall 2> /dev/null | awk '{ $1=""; sub(/^ /,""); print }' || true
  } > "$paths" 2> /dev/null

  # Arquivo tocado mais recentemente: e ele que aponta a task ativa.
  local newest=""
  newest="$(git status --porcelain -uall 2> /dev/null | awk '{ $1=""; sub(/^ /,""); print }' \
    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done \
    | xargs -r ls -1t 2> /dev/null | head -n 1 || true)"

  # FILENAME, e nao NR == FNR: a separacao tem que vir do arquivo que esta
  # sendo lido, nunca de uma contagem que empata quando um dos dois e vazio.
  awk -F'\t' -v newest="$newest" -v af="$anchors" '
    FILENAME == af { idx[FNR] = $1; anc[FNR] = $2; total[$1]++; na = FNR; next }
    {
      for (i = 1; i <= na; i++) {
        if (!hit[i] && anc[i] != "" && index($0, anc[i])) hit[i] = 1
      }
    }
    END {
      for (i = 1; i <= na; i++) {
        if (hit[i]) matched[idx[i]]++
        if (newest != "" && anc[i] != "" && index(newest, anc[i])) active[idx[i]] = 1
      }
      for (t in total) {
        pct = int(matched[t] * 100 / total[t])
        printf "%s|%d|%d\n", t, pct, (t in active ? 1 : 0)
      }
    }
  ' "$anchors" "$paths" 2> /dev/null | sort -n > "$tmp" && mv -f "$tmp" "$out" 2> /dev/null

  rm -f "$anchors" "$paths" "$tmp" 2> /dev/null
  return 0
}

ui_human_bytes() {
  local b="${1:-0}"
  if   [ "$b" -ge 1048576 ] 2> /dev/null; then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
  elif [ "$b" -ge 1024 ]    2> /dev/null; then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
  else printf '%s B' "$b"; fi
}

# Secao AO VIVO — a resposta para "esta travado ou trabalhando?".
#
# Tudo aqui e medido PELO PINTOR a cada frame, nao publicado pelo processo
# principal: durante a sessao do engine o principal fica bloqueado em run_split
# e nao tem como republicar nada. Os numeros vem de tres fontes que mudam
# sozinhas — o tamanho dos dois logs do engine, a arvore de trabalho do git, e o
# tail do stderr. Sem isso a tela fica estatica justamente na etapa mais longa.
ui_sec_live() {
  local w="$1"
  local inner=$((w - 4))

  local stage_el="—"
  [ "${UIV_stage_start:-0}" -gt 0 ] 2> /dev/null && \
    stage_el="$(format_duration $(($(date +%s) - UIV_stage_start)))"

  ui_box_top "$w" "AO VIVO"

  ui_box_row "$w" "Etapa: ${UIV_activity:-—} · $stage_el" \
    "$(printf '%bEtapa:%b %s · %b%s%b' "$UI_C_LABEL" "$UI_C_OFF" "${UIV_activity:-—}" "$UI_C_RUN" "$stage_el" "$UI_C_OFF")"

  # Taxa de saida: engine vivo escreve; engine travado nao. O delta e a unica
  # prova barata de atividade quando a CLI nao emite progresso legivel.
  local rate="—"
  [ "${UIL_RATE:-}" != "" ] && rate="$UIL_RATE"
  local left="Saída do engine: $(ui_human_bytes "${UIL_BYTES:-0}")  ↑ $rate"
  local right="Árvore: ${UIL_DIRTY_N:-0} arquivo(s) tocado(s)"
  local gap=$((inner - ${#left} - ${#right}))
  if [ "$gap" -lt 2 ]; then
    ui_box_row "$w" "$left" "$(printf '%bSaída do engine:%b %s  %b↑ %s%b' "$UI_C_LABEL" "$UI_C_OFF" "$(ui_human_bytes "${UIL_BYTES:-0}")" "$UI_C_OK" "$rate" "$UI_C_OFF")"
    ui_box_row "$w" "$right" "$(printf '%bÁrvore:%b %s arquivo(s) tocado(s)' "$UI_C_LABEL" "$UI_C_OFF" "${UIL_DIRTY_N:-0}")"
  else
    ui_box_row "$w" "$left$(printf '%*s' "$gap" '')$right" \
      "$(printf '%bSaída do engine:%b %s  %b↑ %s%b%*s%bÁrvore:%b %s arquivo(s) tocado(s)' \
         "$UI_C_LABEL" "$UI_C_OFF" "$(ui_human_bytes "${UIL_BYTES:-0}")" "$UI_C_OK" "$rate" "$UI_C_OFF" \
         "$gap" '' "$UI_C_LABEL" "$UI_C_OFF" "${UIL_DIRTY_N:-0}")"
  fi

  # Ultima linha de progresso lida AO VIVO do stderr. Engine que nao streama
  # (claude -p --output-format json) deixa isso vazio para sempre — nesse caso
  # diga ha quanto tempo esta em silencio em vez de repetir "aguardando".
  local prog="${UIL_TAIL:-}"
  if [ -n "$prog" ]; then
    ui_box_row "$w" "· $prog" "$(printf '%b· %s%b' "$UI_C_DIM" "$prog" "$UI_C_OFF")"
  else
    ui_box_row "$w" "· engine em silêncio há $stage_el (esta CLI não streama progresso)" \
      "$(printf '%b· engine em silêncio há %s (esta CLI não streama progresso)%b' "$UI_C_PEND" "$stage_el" "$UI_C_OFF")"
  fi

  # Task inferida: o `~` e deliberado. E palpite fundamentado em arquivo real,
  # nao veredito — quem julga a task e o gate 3.
  case "${UIV_activity:-}" in implementando*|corrigindo*) ;; *) UIL_ACTIVE_TASK="" ;; esac
  if [ -n "${UIL_ACTIVE_TASK:-}" ]; then
    ui_box_row "$w" "Task ativa (~): $UIL_ACTIVE_TASK" \
      "$(printf '%bTask ativa%b %b(~)%b: %b%s%b' "$UI_C_LABEL" "$UI_C_OFF" "$UI_C_DIM" "$UI_C_OFF" "$UI_C_RUN" "$UIL_ACTIVE_TASK" "$UI_C_OFF")"
  fi

  [ -n "${UIL_DIRTY_FILES:-}" ] && \
    ui_box_row "$w" "↳ $UIL_DIRTY_FILES" "$(printf '%b↳ %s%b' "$UI_C_DIM" "$UIL_DIRTY_FILES" "$UI_C_OFF")"

  ui_box_bot "$w"
}

ui_sec_messages() {
  local w="$1" msg_budget="$2"
  [ "$msg_budget" -lt 1 ] && return 0
  local ts level text
  while IFS=$'\t' read -r ts level text; do
    local col="$UI_C_DIM"
    case "$level" in ok) col="$UI_C_OK" ;; warn) col="$UI_C_RUN" ;; fail) col="$UI_C_ERR" ;; esac
    printf '%b%s%b %b%s%b\n' "$UI_C_DIM" "$ts" "$UI_C_OFF" "$col" "$(ui_cell "$text" $((w - 10)))" "$UI_C_OFF"
  done < <(tail -n "$msg_budget" "$UI_MSG_FILE" 2> /dev/null || true)
}

# Desenha o frame inteiro. Altura livre: quem limita e o orcamento passado a
# tabela, calculado a partir do que as outras secoes consomem.
ui_frame() {
  local tick="${1:-0}"
  local w h spin
  w=$(ui_term_cols); h=$(ui_term_lines)
  spin="${UI_SPINNER:$((tick % 8)):1}"
  ui_load_state

  local header_h=4 panels_h=6 live_h=7 msgs_h=2 table_chrome=5
  [ "$w" -lt 100 ] && panels_h=12
  local budget=$((h - header_h - panels_h - live_h - msgs_h - table_chrome))
  [ "$budget" -lt 3 ] && budget=3

  ui_sec_header "$w"
  ui_sec_panels "$w"
  ui_sec_table "$w" "$budget" "$spin"
  ui_sec_live "$w"
  ui_sec_messages "$w" "$msgs_h"
}

# ui_read_key <timeout> — espera o intervalo do frame E captura uma tecla.
#
# O `read` faz as duas coisas de uma vez, entao ele SUBSTITUI o sleep do laco:
# sem tecla ele volta no timeout, com tecla ele volta antes e a tela responde na
# hora. Nada aqui bloqueia o run — quem le teclado e o pintor, o processo
# principal segue nos gates sem saber que existe teclado.
#
# -s (sem eco) tambem conserta um efeito colateral antigo: tecla digitada
# durante o painel aparecia como lixo por cima da moldura.
ui_read_key() {
  local timeout="$1" k="" c="" seq="" i
  UI_KEY=""
  IFS= read -rsn1 -t "$timeout" k 2> /dev/null || true
  [ -n "$k" ] || return 0
  if [ "$k" != $'\033' ]; then UI_KEY="$k"; return 0; fi

  # Seta/PgUp chegam como CSI (ESC [ ... final) ou SS3 (ESC O final). Le BYTE A
  # BYTE ate o terminador, nunca um bloco de tamanho fixo: com a tecla repetindo
  # ha mais de uma sequencia na fila, e um bloco engoliria o ESC da proxima —
  # as duas setas viravam uma sequencia desconhecida e a janela travava depois
  # de andar uma linha.
  IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
  case "$c" in
    '[' | 'O') seq="$k$c" ;;
    *) UI_KEY="$k$c"; return 0 ;;
  esac
  for ((i = 0; i < 6; i++)); do
    c=""
    IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
    [ -n "$c" ] || break
    seq+="$c"
    case "$c" in [A-Za-z~]) break ;; esac
  done
  UI_KEY="$seq"
  return 0
}

# Aplica a tecla a janela da tabela. Os numeros vem do ultimo frame desenhado —
# o pintor nao monta as linhas, entao nao tem como saber sozinho quantas sao.
ui_apply_key() {
  local key="$1"
  [ -n "$key" ] || return 0

  local vp start=0 total=0 budget=3
  vp="$(cat "$UI_VIEWPORT" 2> /dev/null || true)"
  if [ -n "$vp" ]; then
    IFS='|' read -r start total budget _ <<< "$vp"
  fi
  [[ "$start"  =~ ^-?[0-9]+$ ]] || start=0
  [[ "$total"  =~ ^[0-9]+$ ]]   || total=0
  [[ "$budget" =~ ^[0-9]+$ ]]   || budget=3
  [ "$budget" -lt 1 ] && budget=1

  # Ja em manual, a base e o proprio UI_SCROLL, nao o start do ultimo frame: com
  # a tecla repetindo, varias teclas chegam entre dois frames e o start ficaria
  # velho — a janela andaria uma linha e travaria. O start do frame so serve na
  # PRIMEIRA tecla depois do auto, para sair de onde a janela esta em vez de
  # saltar para o topo.
  local base="$UI_SCROLL" delta=0 target=""
  [ "$base" -lt 0 ] && base="$start"
  case "$key" in
    $'\033[A' | $'\033OA' | k | K) delta=-1 ;;
    $'\033[B' | $'\033OB' | j | J) delta=1 ;;
    $'\033[5~')                    delta=$((-budget)) ;;
    $'\033[6~' | ' ')              delta=$budget ;;
    g | $'\033[H' | $'\033[1~')    target=0 ;;
    G | $'\033[F' | $'\033[4~')    target=$((total - budget)) ;;
    a | A)
      # Volta para auto: a janela passa a seguir a fase corrente de novo.
      UI_SCROLL=-1
      return 0
      ;;
    *) return 0 ;;
  esac

  if [ -n "$target" ]; then UI_SCROLL="$target"
  else UI_SCROLL=$((base + delta)); fi
  UI_SCROLL="$(ui_scroll_fit "$UI_SCROLL" "$total" "$budget")"
  return 0
}

ui_start() {
  ui_should_activate || return 0

  mkdir -p "$UI_DIR" 2> /dev/null || return 0
  # Em --attach o messages.log e do run alheio: truncar apagaria o placar dele.
  if ! $ATTACH; then
    : > "$UI_MSG_FILE" 2> /dev/null || return 0
  fi
  UI_ACTIVE=true
  # O attach nunca publica estado: ele so le o do run que esta acompanhando.
  $ATTACH || state_sync

  # 1049h = buffer alternado + cursor salvo; 25l = cursor escondido. Ao sair,
  # 1049l devolve a tela anterior com o scrollback do dev intacto.
  printf '\033[?1049h\033[?25l\033[2J'

  local tick_interval="0.5"
  [ "$UI_FPS" -gt 0 ] 2> /dev/null && tick_interval="$(awk -v f="$UI_FPS" 'BEGIN{printf "%.2f", 1/f}')"

  # O laco virou funcao para poder receber `< /dev/tty`: rodado com `&` num
  # script (job control desligado), o bash redireciona a entrada de qualquer
  # comando assincrono para /dev/null — sem o redirect explicito nenhuma tecla
  # chegaria aqui. O `&` ja forka: o corpo da funcao roda em subshell proprio,
  # entao as variaveis do laco seguem isoladas do processo principal SEM
  # precisar de um `( )` interno. E precisa ser assim: `$!` guarda o PID do
  # fork do `&`, e so dele. Um `( )` a mais dentro da funcao criaria um NETO —
  # `ui_stop` mataria o pai, o neto sobreviveria orfao e continuaria pintando
  # por cima da tela normal depois do 1049l, engolindo o relatorio final.
  if [ "$UI_KEYS" = "1" ] && [ -r /dev/tty ]; then
    UI_TTY_STATE="$(stty -g < /dev/tty 2> /dev/null || true)"
    ui_painter_loop "$tick_interval" < /dev/tty &
  else
    UI_KEYS=0
    ui_painter_loop "$tick_interval" &
  fi
  UI_PAINTER_PID=$!
}

ui_painter_loop() {
  local tick_interval="$1"
  # Grupo `{ }`, nao subshell `( )`: `{ }` nao forka. O unico fork e o do `&`
  # em ui_start, entao o PID que ele guarda e exatamente o deste laco — e o
  # kill do ui_stop acerta quem pinta.
  {
    local tick=0 frame
    # As medicoes vivem AQUI, no corpo do loop, e nao dentro de ui_frame: a
    # chamada abaixo e uma substituicao de comando, ou seja, roda num subshell
    # filho — variaveis atribuidas la dentro morrem no fim do frame e nenhuma
    # taxa poderia ser calculada. Atribuidas aqui, elas persistem entre ticks e
    # o subshell as herda.
    local prev_bytes=0 prev_ts=0 last_heavy=0 now_ts sl ol b1 b2 delta dt
    while true; do
      sl=""; ol=""
      if [ -f "$UI_DIR/state.env" ]; then
        sl="$(sed -n 's/^stderr_log=//p' "$UI_DIR/state.env" | tail -1)"
        ol="$(sed -n 's/^stdout_log=//p' "$UI_DIR/state.env" | tail -1)"
      fi

      b1=0; b2=0
      [ -n "$sl" ] && [ -f "$sl" ] && b1=$(wc -c < "$sl" 2> /dev/null || echo 0)
      [ -n "$ol" ] && [ -f "$ol" ] && b2=$(wc -c < "$ol" 2> /dev/null || echo 0)
      UIL_BYTES=$((b1 + b2))

      now_ts=$(date +%s)
      if [ "$prev_ts" -gt 0 ] && [ "$now_ts" -gt "$prev_ts" ]; then
        delta=$((UIL_BYTES - prev_bytes)); [ "$delta" -lt 0 ] && delta=0
        dt=$((now_ts - prev_ts))
        UIL_RATE="$(ui_human_bytes $((delta / dt)))/s"
        prev_bytes=$UIL_BYTES; prev_ts=$now_ts
      elif [ "$prev_ts" -eq 0 ]; then
        prev_bytes=$UIL_BYTES; prev_ts=$now_ts; UIL_RATE="—"
      fi

      UIL_TAIL=""
      [ -n "$sl" ] && [ -s "$sl" ] && \
        UIL_TAIL="$(grep -v '^[[:space:]]*$' "$sl" 2> /dev/null | tail -n 1 | cut -c1-200 || true)"

      # git status varre a arvore inteira: a 2 fps num repo grande isso pesaria.
      # A cada ~3s e sinal de vida suficiente e custo desprezivel. O corte e por
      # RELOGIO, nao por contagem de tick: com teclado o tick anda mais rapido
      # que o frame (a tecla encurta a espera) e `tick % 6` dispararia a
      # varredura a cada seta apertada.
      if [ $((now_ts - last_heavy)) -ge 3 ]; then
        last_heavy=$now_ts
        local dirty
        dirty="$(git status --porcelain -uall 2> /dev/null || true)"
        UIL_DIRTY_N="$(printf '%s' "$dirty" | grep -c . || true)"
        UIL_DIRTY_FILES="$(printf '%s' "$dirty" | awk '{ $1=""; sub(/^ /,""); print }' \
          | tail -n 3 | paste -sd',' - | sed 's/,/, /g' | cut -c1-160 || true)"

        local pnum
        pnum="$(sed -n 's/^phase_num=//p' "$UI_DIR/state.env" 2> /dev/null | tail -1)"

        # Republicar tasks.txt AQUI, e nao so no state_sync, e o que faz o
        # checkbox aparecer. Durante a sessao do engine o processo principal
        # fica bloqueado em run_split e nao sincroniza nada por minutos —
        # justamente quando as tasks vao sendo marcadas. O pintor le
        # PROGRESS_FILE e os arquivos de fase do disco, entao nao depende do
        # estado congelado que herdou no fork.
        ui_tasks_cache 2> /dev/null || true
        ui_infer_tasks "${pnum:-0}" 2> /dev/null || true

        UIL_ACTIVE_TASK=""
        if [ -f "$UI_TASKPROG" ]; then
          local ai apct
          ai="$(awk -F'|' '$3 == 1 { print $1; exit }' "$UI_TASKPROG" 2> /dev/null || true)"
          if [ -n "$ai" ]; then
            apct="$(awk -F'|' -v i="$ai" '$1 == i { print $2; exit }' "$UI_TASKPROG" 2> /dev/null || true)"
            UIL_ACTIVE_TASK="T$ai · $(grep "^${pnum}|${ai}|" "$UI_DIR/tasks.txt" 2> /dev/null | head -1 | cut -d'|' -f4 | cut -c1-70) · ${apct}%"
          fi
        fi
      fi

      # Falha ao desenhar nao pode matar o pintor nem o run: o painel e
      # apresentacao, o veredito vive no state e nos logs.
      frame="$(ui_frame "$tick" 2> /dev/null || true)"
      if [ -n "$frame" ]; then
        # H = cursor no topo; 2K por linha; J apaga o resto da tela. Sem o J,
        # um frame mais curto que o anterior deixaria lixo embaixo.
        printf '\033[H%s\033[J' "$(printf '%s\n' "$frame" | sed 's/$/\x1b[0K/')"
      fi
      tick=$((tick + 1))

      # Espera do frame e leitura de tecla sao a MESMA chamada: com teclado
      # ligado o read cobre o intervalo e ainda responde na hora quando o dev
      # aperta algo. Sem teclado, sleep — o custo e o mesmo de antes.
      if [ "$UI_KEYS" = "1" ]; then
        ui_read_key "$tick_interval"
        if [ -n "$UI_KEY" ]; then ui_apply_key "$UI_KEY"; fi
      else
        sleep "$tick_interval"
      fi
    done
  }
}

# Sai do buffer alternado antes de qualquer saida longa (causa de gate vermelho,
# relatorio final). A partir daqui o placar volta a rolar na tela normal.
ui_stop() {
  $UI_ACTIVE || return 0
  UI_ACTIVE=false

  if [ -n "$UI_PAINTER_PID" ]; then
    kill "$UI_PAINTER_PID" 2> /dev/null || true
    wait "$UI_PAINTER_PID" 2> /dev/null || true
    # Pintor vivo depois daqui e o pior defeito possivel do painel: ele repinta
    # POR CIMA da tela normal ja restaurada, apaga o relatorio final a cada
    # frame e o run parece travado com o painel congelado na tela. O `wait` so
    # cobre filho direto; se sobrou alguem (sinal perdido, read preso), SIGKILL.
    if kill -0 "$UI_PAINTER_PID" 2> /dev/null; then
      kill -9 "$UI_PAINTER_PID" 2> /dev/null || true
      wait "$UI_PAINTER_PID" 2> /dev/null || true
    fi
    UI_PAINTER_PID=""
  fi

  if [ -n "$UI_TTY_STATE" ]; then
    stty "$UI_TTY_STATE" < /dev/tty 2> /dev/null || true
    UI_TTY_STATE=""
  fi

  # 0m antes de sair: o pintor pode ter morrido no meio de um frame, com cor
  # aberta. O SGR atravessa a troca de buffer — sem o reset o relatorio final
  # sairia tingido com a ultima cor do painel.
  printf '\033[0m\033[?25h\033[?1049l'

  # O painel viveu numa tela que acabou de ser descartada. Sem reimprimir, o
  # dev perde o placar inteiro do run — ele existe so no messages.log.
  if [ -s "$UI_MSG_FILE" ]; then
    local ts level text
    while IFS=$'\t' read -r ts level text; do
      case "$level" in
        ok)   echo -e "${GREEN}[$ts] $text${NC}" ;;
        warn) echo -e "${YELLOW}[$ts] $text${NC}" ;;
        fail) echo -e "${RED}[$ts] $text${NC}" ;;
        *)    echo -e "${BLUE}[$ts]${NC} $text" ;;
      esac
    done < "$UI_MSG_FILE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Dashboard web (--serve)
# ---------------------------------------------------------------------------

port_free() {
  local port="$1"
  # Conexao bem-sucedida => alguem ja escuta ali.
  (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null && { exec 3<&- 2> /dev/null; return 1; }
  return 0
}

serve_start() {
  $SERVE || return 0

  if ! command -v python3 &> /dev/null; then
    warn "--serve pedido, mas python3 nao esta no PATH: dashboard web desabilitado."
    warn "O run segue normalmente; o estado continua em $STATE_FILE e $EVENTS_FILE."
    return 0
  fi

  if ! [[ "$SERVE_PORT" =~ ^[0-9]+$ ]] || [ "$SERVE_PORT" -lt 1 ] || [ "$SERVE_PORT" -gt 65535 ]; then
    warn "Porta invalida para --serve: '$SERVE_PORT'. Usando 7433."
    SERVE_PORT=7433
  fi

  mkdir -p "$UI_DIR" 2> /dev/null || return 0
  write_dashboard_html

  local port="$SERVE_PORT" limit=$((SERVE_PORT + 100)) found=""
  while [ "$port" -le "$limit" ]; do
    if port_free "$port"; then found="$port"; break; fi
    port=$((port + 1))
  done

  if [ -z "$found" ]; then
    warn "Nenhuma porta livre entre $SERVE_PORT e $limit: dashboard web desabilitado."
    return 0
  fi

  # Preso a 127.0.0.1: o diretorio servido tem prompts e logs do run, e nada
  # disso pode sair da maquina.
  python3 -m http.server "$found" --bind 127.0.0.1 --directory "$PHASES_DIR" \
    > /dev/null 2>&1 < /dev/null &
  SERVE_PID=$!
  SERVE_URL="http://127.0.0.1:$found/ui/"

  # Servidor morto ja no arranque (porta tomada na corrida) nao pode deixar
  # uma URL mentirosa no topo do run.
  sleep 1
  if ! kill -0 "$SERVE_PID" 2> /dev/null; then
    warn "O servidor do dashboard nao subiu na porta $found: dashboard web desabilitado."
    SERVE_PID=""
    SERVE_URL=""
    return 0
  fi

  return 0
}

# Auto-contido de proposito: sem CDN, sem fonte remota, sem fetch externo. O
# unico dado que a pagina busca sao os dois arquivos de estado do proprio run.
write_dashboard_html() {
  cat > "$UI_HTML" <<'HTML'
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ralph</title>
<style>
  :root {
    --bg: #0f1115; --panel: #171a21; --line: #262b36; --fg: #e6e9ef;
    --muted: #8b93a5; --ok: #3fb950; --run: #d29922; --err: #f85149;
    --skip: #6e7681; --accent: #58a6ff;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    padding: 1.5rem;
  }
  h1 { font-size: 1.1rem; margin: 0 0 .25rem; font-weight: 600; }
  .sub { color: var(--muted); margin-bottom: 1.25rem; font-size: .85rem; }
  .card {
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 8px; padding: 1rem; margin-bottom: 1rem;
  }
  .card h2 {
    font-size: .75rem; text-transform: uppercase; letter-spacing: .08em;
    color: var(--muted); margin: 0 0 .75rem; font-weight: 600;
  }
  .headline { display: flex; flex-wrap: wrap; gap: 1rem; align-items: baseline; }
  .headline .title { font-size: 1.25rem; font-weight: 600; }
  .headline .meta { color: var(--muted); }
  .gates { display: flex; flex-wrap: wrap; gap: .5rem; }
  .gate {
    border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .7rem; display: flex; gap: .5rem; align-items: center;
  }
  .phases { display: grid; gap: .35rem; }
  .phase { display: flex; gap: .6rem; align-items: baseline; }
  .phase .n { color: var(--muted); min-width: 2.5rem; }
  .dot { width: .6rem; height: .6rem; border-radius: 50%; display: inline-block; flex: none; }
  .s-done .dot, .s-pass { background: var(--ok); }
  .s-running .dot, .s-run { background: var(--run); }
  .s-failed .dot, .s-fail { background: var(--err); }
  .s-skipped .dot, .s-skip { background: var(--skip); }
  .s-pending .dot, .s-pending2 { background: var(--line); }
  .s-done { color: var(--fg); } .s-pending { color: var(--muted); }
  .s-running { color: var(--run); font-weight: 600; }
  .s-failed { color: var(--err); } .s-skipped { color: var(--skip); }
  pre {
    margin: 0; white-space: pre-wrap; word-break: break-word;
    color: var(--muted); font-size: .85rem;
  }
  table { width: 100%; border-collapse: collapse; font-size: .85rem; }
  th, td { text-align: left; padding: .3rem .5rem; border-bottom: 1px solid var(--line); }
  th { color: var(--muted); font-weight: 600; }
  td.num { text-align: right; color: var(--muted); }
  .scroll { max-height: 22rem; overflow-y: auto; overflow-x: auto; }
  .banner {
    border-radius: 6px; padding: .6rem .8rem; margin-bottom: 1rem;
    background: #2d2410; border: 1px solid #6b4f0f; color: #e3b341;
  }
  .off { opacity: .55; }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f6f7f9; --panel: #fff; --line: #dfe3ea; --fg: #1b1f27;
      --muted: #626b7d; --ok: #1a7f37; --run: #9a6700; --err: #cf222e; --skip: #8c959f;
    }
    .banner { background: #fff8e5; border-color: #e3c168; color: #7a5c00; }
  }
</style>
</head>
<body>
  <h1 id="title">ralph</h1>
  <div class="sub" id="subtitle">carregando…</div>
  <div id="stale" class="banner" hidden></div>

  <div class="card">
    <h2>Fase corrente</h2>
    <div class="headline">
      <span class="title" id="phase-title">—</span>
      <span class="meta" id="phase-meta"></span>
    </div>
    <div style="margin-top:.75rem" class="gates" id="gates"></div>
    <pre id="test-cmd" style="margin-top:.75rem"></pre>
    <pre id="progress" style="margin-top:.5rem"></pre>
  </div>

  <div class="card">
    <h2>Fases</h2>
    <div class="phases" id="phases"></div>
  </div>

  <div class="card">
    <h2>Timeline</h2>
    <div class="scroll">
      <table>
        <thead><tr><th>hora</th><th>evento</th><th>fase</th><th>detalhe</th><th class="num">dur.</th></tr></thead>
        <tbody id="timeline"></tbody>
      </table>
    </div>
  </div>

<script>
const GATE_LABEL = {
  0: 'engine concluiu', 1: 'sessao escreveu', 2: 'suite do projeto', 3: 'verificacao independente'
};
const CLS = { pass: 's-pass', fail: 's-fail', running: 's-run', skip: 's-skip', pending: 's-pending2' };

function fmtDur(s) {
  if (s == null || isNaN(s)) return '';
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  if (h) return `${h}h ${m}m ${r}s`;
  if (m) return `${m}m ${r}s`;
  return `${r}s`;
}
function fmtTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString('pt-BR', { hour12: false });
}
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

async function tick() {
  let state;
  try {
    state = await (await fetch('../state.json?t=' + Date.now(), { cache: 'no-store' })).json();
  } catch (e) {
    document.getElementById('subtitle').textContent = 'estado indisponivel — o run terminou ou o servidor caiu';
    return;
  }

  document.getElementById('title').textContent = `ralph · ${state.project}`;
  document.getElementById('subtitle').textContent =
    `engine ${state.engine} · ${state.input} · ${state.run_status} · decorrido ${fmtDur(state.updated_at - state.started_at)}`;

  const stale = document.getElementById('stale');
  if (state.limit && state.limit.waiting) {
    stale.hidden = false;
    const left = state.limit.until ? fmtDur(state.limit.until - Math.floor(Date.now() / 1000)) : 'tempo desconhecido';
    stale.textContent = `Limite de uso atingido. Retomando a MESMA fase em ${left} (espera ${state.limit.waits}/${state.limit.max_waits}). Nenhuma acao necessaria.`;
  } else {
    stale.hidden = true;
  }

  const p = state.phase || {};
  document.getElementById('phase-title').textContent = p.title || '—';
  document.getElementById('phase-meta').textContent = p.num
    ? `fase ${p.seq}/${p.total} · ciclo ${p.cycle}/${p.max_cycles} · ${fmtDur(state.updated_at - p.started_at)}`
    : '';

  const gates = document.getElementById('gates');
  gates.replaceChildren();
  for (const g of [0, 1, 2, 3]) {
    const st = (state.gates || {})[g] || 'pending';
    const box = el('div', 'gate' + (st === 'pending' ? ' off' : ''));
    box.append(el('span', 'dot ' + (CLS[st] || CLS.pending)), el('span', null, `gate ${g} — ${GATE_LABEL[g]}`));
    gates.append(box);
  }

  document.getElementById('test-cmd').textContent =
    state.test_cmd ? `gate 2: ${state.test_cmd}` : 'gate 2 desabilitado (nenhum comando de teste resolvido)';
  document.getElementById('progress').textContent = state.progress_line ? '· ' + state.progress_line : '';

  const list = document.getElementById('phases');
  list.replaceChildren();
  for (const ph of state.phases || []) {
    const row = el('div', 'phase s-' + ph.status);
    row.append(el('span', 'dot'), el('span', 'n', String(ph.num)), el('span', null, ph.title));
    list.append(row);
  }

  let lines = [];
  try {
    const raw = await (await fetch('../events.jsonl?t=' + Date.now(), { cache: 'no-store' })).text();
    lines = raw.trim().split('\n').filter(Boolean).map(JSON.parse);
  } catch (e) { /* events sao opcionais para a pagina renderizar */ }

  const tb = document.getElementById('timeline');
  tb.replaceChildren();
  for (const ev of lines.slice(-200).reverse()) {
    const tr = el('tr');
    let detail = ev.message || '';
    if (ev.event === 'gate_start') detail = `gate ${ev.gate} — ${GATE_LABEL[ev.gate]}`;
    if (ev.event === 'gate_end') detail = `gate ${ev.gate} — ${ev.verdict}`;
    tr.append(
      el('td', null, fmtTime(ev.ts)),
      el('td', null, ev.event),
      el('td', null, ev.phase ? String(ev.phase) : ''),
      el('td', null, detail),
      el('td', 'num', ev.duration != null ? fmtDur(ev.duration) : '')
    );
    tb.append(tr);
  }
}

tick();
setInterval(tick, 1500);
</script>
</body>
</html>
HTML
}

serve_stop() {
  [ -n "$SERVE_PID" ] || return 0
  kill "$SERVE_PID" 2> /dev/null || true
  wait "$SERVE_PID" 2> /dev/null || true
  SERVE_PID=""
  return 0
}

# Um trap so para os dois: Ctrl-C nao pode deixar cursor escondido nem servidor
# orfao segurando a porta.
cleanup_ui() {
  ui_stop
  serve_stop
}

# ---------------------------------------------------------------------------
# --attach — acompanhar um run JA em andamento
#
# Bash nao troca as funcoes de um processo vivo: um run que comecou continua
# rodando, ate o fim, o codigo com que subiu. Corrigir o painel no meio de um
# run so e possivel por fora — um segundo processo, com o codigo novo, lendo o
# mesmo .phases/ e republicando o que a tabela le.
#
# Read-only sobre o run: nao roda fase, nao chama engine, nao commita, nao
# escreve state.env nem messages.log. Sair do attach nao mexe no run.
# ---------------------------------------------------------------------------

attach_task_tally() {
  awk -F'|' '
    { t++; if ($3 == "done") d++; else if ($3 == "declared") k++ }
    END { printf "%d/%d concluidas, %d declaradas", d + 0, t + 0, k + 0 }
  ' "$UI_DIR/tasks.txt" 2> /dev/null || true
}

attach_run() {
  if [ ! -f "$MANIFEST" ]; then
    fail "--attach: nao ha run neste diretorio ($MANIFEST ausente)."
    fail "Rode o --attach no MESMO diretorio de trabalho do run que voce quer acompanhar."
    exit 1
  fi

  ui_load_state
  [ -n "${UIV_project:-}" ] && PROJECT_NAME="$UIV_project"
  [ -n "${UIV_engine:-}" ] && ENGINE="$UIV_engine"

  log "attach: run ${UIV_run_id:-?} (pid ${UIV_pid:-?}) — projeto $PROJECT_NAME"
  log "attach: republicando status por task a cada ${ATTACH_INTERVAL}s; Ctrl-C sai sem tocar no run"

  trap cleanup_ui EXIT INT TERM
  ui_start

  local st pnum
  while :; do
    ui_load_state
    st="${UIV_run_status:-}"
    pnum="${UIV_phase_num:-0}"

    # Com painel, quem republica e o proprio pintor a cada ~3s. Sem painel
    # (nao-TTY, --no-ui) o attach continua util: republica e resume em texto.
    if ! $UI_ACTIVE; then
      ui_tasks_cache 2> /dev/null || true
      ui_infer_tasks "$pnum" 2> /dev/null || true
      log "attach: fase ${pnum} · $(attach_task_tally) · ${UIV_activity:-—}"
    fi

    case "$st" in
      done | failed | aborted)
        log "attach: run $st — encerrando."
        break
        ;;
    esac

    # PID sumido = run morto sem publicar estado final (kill -9, terminal
    # fechado). Sem isso o attach ficaria desenhando um run que nao existe.
    if [ -n "${UIV_pid:-}" ] && [ "${UIV_pid}" -gt 0 ] 2> /dev/null \
      && ! kill -0 "$UIV_pid" 2> /dev/null; then
      warn "attach: processo ${UIV_pid} do run nao existe mais — encerrando."
      break
    fi

    sleep "$ATTACH_INTERVAL"
  done

  ui_stop
  return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

resolve_input_file() {
  if [ -n "$INPUT_FILE" ]; then
    return 0
  fi

  if [ -f ".spec/init/project-phases.md" ]; then
    INPUT_FILE=".spec/init/project-phases.md"
  elif [ -f ".spec/project-phases.md" ]; then
    INPUT_FILE=".spec/project-phases.md"
    warn "Usando .spec/project-phases.md (layout pre-init). O padrao atual e .spec/init/project-phases.md."
  else
    fail "Nenhum documento de fases encontrado."
    fail "Esperado .spec/init/project-phases.md (rode /init:project-phases) ou passe o caminho como argumento."
    exit 1
  fi
}

validate_input_format() {
  local top_level
  top_level=$(grep -cE '^## Phase [0-9]+: ' "$INPUT_FILE" || true)

  if [ "$top_level" -lt 1 ]; then
    fail "Contrato de formato violado: nenhum heading '## Phase N: <titulo>' em $INPUT_FILE"
    fail "ralph quebra o documento por esse heading. Corrija o documento antes de rodar."
    exit 1
  fi

  local malformed
  malformed=$(grep -E '^## Phase' "$INPUT_FILE" | grep -vE '^## Phase [0-9]+: ' || true)
  if [ -n "$malformed" ]; then
    fail "Contrato de formato violado: headings '## Phase' fora do formato '## Phase N: <titulo>':"
    echo "$malformed" | sed 's/^/    /'
    fail "Uma fase com heading torto some silenciosamente do run. Corrija antes de gastar tokens."
    exit 1
  fi

  log "Formato do input OK ($top_level fases declaradas)"
}

exclude_phases_dir() {
  local exclude_file
  exclude_file="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF '/.phases/' "$exclude_file" 2>/dev/null; then
    echo '/.phases/' >> "$exclude_file"
    log "Registrado /.phases/ em .git/info/exclude (nao mexe no .gitignore do projeto)"
  fi
}

# Laravel Sail: a suite roda DENTRO do container. Rodar `composer test` /
# `php artisan test` no host falha (sem PHP, sem banco, sem rede do compose).
# Ecoa o caminho do binario sail quando o projeto usa Sail.
detect_sail() {
  [ -f artisan ] || return 1
  if [ -x vendor/bin/sail ]; then
    echo "vendor/bin/sail"
    return 0
  fi
  # Sail declarado no composer.json mas vendor/ ainda nao instalado.
  if [ -f composer.json ] && grep -qF 'laravel/sail' composer.json; then
    echo "vendor/bin/sail"
    return 0
  fi
  return 1
}

# Containers de pe? O wrapper do sail imprime "Sail is not running." e sai != 0.
sail_running() {
  local out rc=0
  out=$("$SAIL_BIN" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

# O comando de teste invoca o sail? Olha o executavel (1o token), nao a string
# inteira: um caminho como /tmp/sail-fixture/test.sh nao usa sail.
test_cmd_uses_sail() {
  local first="${TEST_CMD%% *}"
  [ "$(basename -- "$first")" = "sail" ]
}

# Gate 2 so tem valor se rodar de verdade. Sail com containers parados falha
# toda fase e queima ciclos de correcao inuteis — aborta antes da 1a sessao.
check_sail_running() {
  [ -n "$SAIL_BIN" ] || return 0
  test_cmd_uses_sail || return 0

  if [ ! -x "$SAIL_BIN" ]; then
    fail "Laravel Sail detectado, mas $SAIL_BIN nao existe."
    fail "Rode a instalacao de dependencias do projeto (ex: composer install) antes."
    exit 1
  fi

  if ! sail_running; then
    fail "Laravel Sail detectado, mas os containers nao estao de pe."
    fail "A suite de testes (gate 2) roda dentro do container e falharia em toda fase."
    fail "Suba o ambiente antes de rodar o ralph:"
    fail "    $SAIL_BIN up -d"
    exit 1
  fi

  log "Sail: containers de pe"
}

resolve_test_cmd() {
  SAIL_BIN="$(detect_sail || true)"

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — comando de teste (--test-cmd): $TEST_CMD"
    check_sail_running
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — comando de teste (RALPH_TEST_CMD): $TEST_CMD"
    check_sail_running
    return 0
  fi

  # Sail vem ANTES de composer/npm: num projeto Laravel dockerizado o host nao
  # tem PHP nem acesso ao banco, e `composer test` mentiria como gate.
  if [ -n "$SAIL_BIN" ]; then
    TEST_CMD="$SAIL_BIN test"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    TEST_CMD="composer test"
  elif [ -f artisan ]; then
    TEST_CMD="php artisan test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    TEST_CMD="npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    TEST_CMD="pytest"
  elif [ -f go.mod ]; then
    TEST_CMD="go test ./..."
  elif [ -f Cargo.toml ]; then
    TEST_CMD="cargo test"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — comando de teste (detectado): $TEST_CMD"
    check_sail_running
  else
    warn "Gate 2 DESABILITADO: nenhum comando de teste resolvido."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify tambem desligou o gate 3: NENHUMA validacao mecanica ativa."
    else
      warn "Passe --test-cmd '<cmd>' ou defina RALPH_TEST_CMD. O gate 3 (verificador) roda em toda fase."
    fi
  fi
}

preflight_checks() {
  if [[ "$ENGINE" != "codex" && "$ENGINE" != "claude" ]]; then
    fail "Engine invalida: $ENGINE. Use 'codex' ou 'claude'."
    exit 1
  fi

  if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --from: '$FROM_PHASE'. Use um numero inteiro (ex: --from 5)."
    exit 1
  fi

  if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    fail "Valor invalido para --max-cycles: '$MAX_CYCLES'. Use um inteiro >= 1."
    exit 1
  fi

  if ! [[ "$HEARTBEAT_SECS" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para RALPH_HEARTBEAT: '$HEARTBEAT_SECS'. Use um inteiro >= 0 (0 desliga)."
    exit 1
  fi

  case "$VERIFY_MODE" in
    auto|always|off) ;;
    *)
      fail "Valor invalido para RALPH_VERIFY: '$VERIFY_MODE'. Use auto, always ou off."
      exit 1
      ;;
  esac

  case "$UI_MODE" in
    auto|panel|plain) ;;
    *)
      fail "Valor invalido para RALPH_UI: '$UI_MODE'. Use auto, panel ou plain."
      exit 1
      ;;
  esac

  # Verificacao e leitura + checklist: nao precisa do modelo de implementacao.
  # No codex nao ha default seguro de modelo barato — so aplica se pedido.
  if [ -n "${RALPH_VERIFY_MODEL:-}" ]; then
    VERIFY_MODEL="$RALPH_VERIFY_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    VERIFY_MODEL="haiku"
  fi

  if ! command -v "$ENGINE" &> /dev/null; then
    if [[ "$ENGINE" == "codex" ]]; then
      fail "codex CLI nao encontrado. Instale com: npm install -g @openai/codex"
    else
      fail "Claude Code CLI nao encontrado. Instale com: npm install -g @anthropic-ai/claude-code"
    fi
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
    fail "Requer um repositorio git."
    exit 1
  fi

  resolve_input_file

  if [ ! -f "$INPUT_FILE" ]; then
    fail "Arquivo nao encontrado: $INPUT_FILE"
    exit 1
  fi

  validate_input_format
  exclude_phases_dir

  # Arvore limpa: 'git add -A' da primeira fase engoliria trabalho nao commitado.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Arvore de trabalho suja. ralph commita por fase e engoliria suas mudancas."
    fail "Commite ou stashe antes de rodar:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd

  success "Pre-checks OK (engine: $ENGINE, input: $INPUT_FILE)"
}

# ---------------------------------------------------------------------------
# Split + progresso
# ---------------------------------------------------------------------------

manifest_entries() { grep -v '^#' "$MANIFEST" || true; }

split_phases() {
  log "Quebrando $INPUT_FILE em fases..."

  local new_stamp old_stamp="" progress_backup=""
  new_stamp="$(basename "$INPUT_FILE")@sha256:$(sha256sum "$INPUT_FILE" | cut -c1-12)"

  if [ -f "$MANIFEST" ]; then
    old_stamp=$(sed -n '1s/^# stamp: //p' "$MANIFEST")
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    progress_backup=$(cat "$PROGRESS_FILE")
  fi

  rm -rf "$PHASES_DIR"
  mkdir -p "$PHASES_DIR" "$LOG_DIR" "$PROMPT_DIR" "$UI_DIR"

  # events.jsonl e o historico DESTE run: zerado junto com o resto do .phases/.
  : > "$EVENTS_FILE"
  : > "$UI_MSG_FILE"

  # Progresso sobrevive entre execucoes, mas so vale para o MESMO input.
  if [ -n "$progress_backup" ]; then
    if [ -n "$old_stamp" ] && [ "$old_stamp" = "$new_stamp" ]; then
      printf '%s\n' "$progress_backup" > "$PROGRESS_FILE"
      log "Progresso anterior preservado (input inalterado)"
    else
      warn "O documento de fases mudou desde a ultima execucao — progresso zerado."
      warn "Fases marcadas como feitas pertenciam a outro plano."
    fi
  fi

  echo "# stamp: $new_stamp" > "$MANIFEST"

  local current_file=""
  local phase_count=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^##[[:space:]]+Phase[[:space:]]+([0-9]+):[[:space:]]*(.*)$ ]]; then
      phase_count=$((phase_count + 1))

      local phase_num="${BASH_REMATCH[1]}"
      local phase_title="${BASH_REMATCH[2]}"
      phase_title="$(echo "$phase_title" | sed 's/[[:space:]]*$//')"

      local slug
      slug=$(printf 'phase-%02d' "$phase_num")

      current_file="$PHASES_DIR/${slug}.md"
      echo "$line" > "$current_file"
      echo "${slug}.md|${phase_num}|${phase_title}" >> "$MANIFEST"
      continue
    fi

    # Heading nivel 2 que nao e "## Phase N:" (ex: "## Open Questions"):
    # encerra a captura para nao vazar a secao para a ultima fase.
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      current_file=""
      continue
    fi

    if [ -n "$current_file" ]; then
      echo "$line" >> "$current_file"
    fi
  done < "$INPUT_FILE"

  success "$phase_count fases extraidas"
}

is_phase_done() {
  local phase_file="$1"
  [ -f "$PROGRESS_FILE" ] && grep -qxF "$phase_file" "$PROGRESS_FILE"
}

mark_phase_done() {
  echo "$1" >> "$PROGRESS_FILE"
}

# --from N tambem limpa do progresso as fases >= N (re-rodar de proposito).
apply_from_override() {
  [ "$FROM_PHASE" -gt 1 ] || return 0
  [ -f "$PROGRESS_FILE" ] || return 0

  local kept="" file num _rest
  while IFS='|' read -r file num _rest; do
    if [ "$num" -lt "$FROM_PHASE" ] && grep -qxF "$file" "$PROGRESS_FILE"; then
      kept+="$file"$'\n'
    fi
  done < <(manifest_entries)

  printf '%s' "$kept" > "$PROGRESS_FILE"
  log "--from $FROM_PHASE: progresso das fases >= $FROM_PHASE limpo"
}

# ---------------------------------------------------------------------------
# Prompts (auto-contidos — cada sessao e nova)
# ---------------------------------------------------------------------------

# O unico sinal de progresso POR TASK que existe durante a sessao.
#
# O engine roda opaco: nenhum evento diz em que task ele esta, e os gates so
# falam no fim da fase. Sem isso o operador olha a tabela por 20 minutos e ve
# tudo Pendente enquanto o run trabalha. Marcar e barato e reversivel.
#
# Nao vira veredito em lugar nenhum: o gate 3 confere task a task depois e
# sobrescreve o checkbox. E `.phases/` esta em .git/info/exclude, entao marcar
# nao muda a assinatura da arvore nem faz o gate 1 achar que a sessao escreveu
# codigo.
progress_marking_rules() {
  local phase_file="$1"
  [ -n "$phase_file" ] || return 0

  cat <<MARK

## Marque o progresso enquanto trabalha (obrigatorio)
O arquivo desta fase e \`$PHASES_DIR/$phase_file\`.
Assim que uma task estiver implementada E com os testes dela (quando a task
listar algum) passando, edite
esse arquivo e troque \`- [ ]\` por \`- [x]\` NA LINHA daquela task — uma de
cada vez, no momento em que ela fecha.
- Nao marque antecipado, nao marque em lote no fim da sessao.
- Nao altere mais nada nesse arquivo: so o caractere do checkbox.
- Marcar nao substitui verificacao: um verificador independente confere task a
  task depois e o veredito dele vence a marcacao.
MARK
}

context_preamble() {
  local phase_file="${1:-}"

  cat <<'PREAMBLE'
## Descubra a stack e as convencoes antes de escrever codigo
Este projeto pode ser de qualquer linguagem ou framework. NAO assuma nenhuma
stack. Antes de comecar, LEIA os que existirem, nesta ordem:
1. AGENTS.md ou CLAUDE.md — convencoes, comandos e regras do projeto
2. .spec/init/project-description.md — descricao geral do projeto
3. .spec/init/user-stories.md — user stories
4. .spec/init/database-schema.md — modelo de dados
5. os documentos citados no proprio texto da fase (ex: SPEC.md/PLAN.md da feature)
Use os comandos de build, teste e execucao definidos por esses documentos e pelo
tooling ja presente no repositorio. Se o projeto tiver uma ferramenta de memoria
ou contexto configurada, use-a para entender o historico.
PREAMBLE

  # O gate 2 roda ESTE comando. Se o agente rodar outro (ex: `php artisan test`
  # no host de um projeto Sail), ele ve verde e o gate ve vermelho.
  progress_marking_rules "$phase_file"

  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## Comando de teste deste projeto"
    echo "Rode a suite SEMPRE com:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "Este e o comando exato usado para validar a fase. Nao use outro runner"
    echo "nem rode os testes por fora dele."
    if [ -n "$SAIL_BIN" ]; then
      echo "O projeto usa Laravel Sail: artisan, composer, php e testes rodam DENTRO"
      echo "do container, via '$SAIL_BIN <cmd>'. Nunca rode essas ferramentas no host."
    fi
  fi
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior implementando uma fase deste projeto."
    echo
    context_preamble "$phase_file"
    cat <<'TASK'

## Sua tarefa agora
Implemente COMPLETAMENTE a fase descrita abaixo.

Para cada item:
1. Implemente o codigo completo (nao deixe TODOs ou placeholders)
2. Crie EXATAMENTE os testes listados no campo `Testes:` da task, seguindo o
   framework de testes do projeto. Task com `Testes: none` NAO leva teste — a
   verificacao dela e por inspecao do codigo contra os acceptance criteria
3. Rode os testes com o comando de teste do projeto
4. Se um teste falhar, corrija o codigo e rode novamente
5. So passe pro proximo item quando os testes passarem

## Regras obrigatorias
- Use SEMPRE os comandos, o runner de testes e as ferramentas ja adotados pelo
  projeto (nao introduza uma stack ou ferramenta nova por conta propria)
- NAO escreva teste alem do que a task lista. Teste extra "por seguranca" —
  getter, cast, relacao declarada, "a classe existe", label cosmetico, default
  de config, mesmo ramo reafirmado em outra camada — e ruido: reprova revisao e
  nao ajuda gate nenhum. Se um comportamento sem cobertura te preocupa, anote
  no relatorio final em vez de criar o teste por conta propria
- Testes e fixtures/factories devem criar todas as dependencias necessarias
- Nomes de classes, arquivos e metodos devem seguir EXATAMENTE o que esta descrito
- Nao pule nenhum item marcado com [ ]
- Ao final, valide que toda a suite de testes da fase passa

## Fase a implementar
TASK
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de correcao: auto-contido. Carrega a fase inteira + a causa REAL
# da falha (nunca "os testes falharam" generico).
build_fix_prompt() {
  local phase_file="$1" cycle="$2" gate="$3" cause="$4"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior corrigindo uma fase parcialmente implementada."
    echo
    context_preamble "$phase_file"
    cat <<'INTRO'

## Situacao
Uma sessao anterior tentou implementar a fase abaixo e NAO passou na verificacao.
Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo atual
antes de mudar qualquer coisa.

## Regras obrigatorias
- Corrija APENAS o que falta. Nao reimplemente o que ja esta correto e testado.
- Nao deixe TODOs, placeholders ou testes pulados.
- Rode a suite de testes do projeto ao final e garanta que ela passa.
INTRO
    echo
    echo "## Motivo da falha ($gate)"
    echo '```'
    echo "$cause"
    echo '```'
    echo
    echo "## Fase a completar"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

build_verify_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.verify-${cycle}.txt"

  {
    cat <<'VERIFY'
RALPH_VERIFY

Voce e um verificador independente. NAO escreva, edite ou crie nenhum arquivo.
Seu unico trabalho e ler o codigo real e dizer o que esta feito e o que nao esta.

Para CADA task marcada com `- [ ]` ou `- [x]` na fase abaixo, na ordem em que
aparecem, confira os acceptance criteria contra o codigo real (arquivos, classes,
testes, rotas, migrations — o que a task exigir) e emita EXATAMENTE UMA linha:

TASK <n>: DONE
TASK <n>: INCOMPLETE — <o que falta>

Regras:
- <n> e a POSICAO da task na fase: 1 para a primeira, 2 para a segunda, e assim
  por diante. Se a task tiver rotulo proprio no texto (ex.: `T33 —`), IGNORE o
  numero do rotulo — use sempre a posicao.
- Uma linha TASK para cada task, sem excecao, sem agrupar.
- Nao repita um indice e nao pule nenhum: exatamente uma linha por task, na
  ordem, sem resumo nem repeticao do bloco no final.
- Nao emita nenhum outro texto alem das linhas TASK.
- Comandos de suite podem demorar VARIOS minutos. Rode cada um com o maior
  timeout que a ferramenta permitir e ESPERE terminar antes de dar veredito.
  Nao rode em background, nao abandone processo em execucao.
- JAMAIS encerre com relatorio parcial ou texto tipo "aguardando": enquanto
  um comando exigido por uma task nao terminou, a verificacao nao acabou.
- Codigo ausente, TODO ou placeholder => INCOMPLETE.
- Teste: cobre so o que a task LISTA no campo `Testes:`. Teste listado e que nao
  existe (ou nao passa) => INCOMPLETE. Task com `Testes: none` => verifique os
  acceptance criteria lendo o codigo real; ausencia de teste NAO e motivo de
  INCOMPLETE nela. Nunca exija teste que a task nao pediu.
- IGNORE o estado do checkbox. `- [x]` e declaracao de quem implementou, nao
  prova: uma task marcada pode estar incompleta e uma task nao marcada pode
  estar pronta. So o codigo real decide.
- Na duvida, INCOMPLETE.

## Fase a verificar
VERIFY
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Logs do engine — stdout (resposta final) e stderr (progresso) SEPARADOS
# ---------------------------------------------------------------------------

# Caminho do log de stderr que acompanha um log de stdout.
stderr_log_for() {
  local log_file="$1"
  echo "${log_file%.log}.stderr.log"
}

# Tail para DIAGNOSTICO (GATE_CAUSE): junta os dois streams porque o erro real
# do engine costuma sair no stderr. Nunca use isto para decidir gate.
engine_tail() {
  local log_file="$1" lines="${2:-40}"
  local err_log
  err_log="$(stderr_log_for "$log_file")"

  tail -n "$lines" "$log_file" 2>/dev/null || true
  if [ -s "$err_log" ]; then
    echo "--- stderr do engine (progresso, nao e veredito) ---"
    tail -n "$lines" "$err_log" 2>/dev/null || true
  fi
}

# Heartbeat do modo quiet: prova de vida enquanto o engine trabalha em silencio.
# Mostra o tempo decorrido e a ultima linha de progresso (truncada) — sem ele,
# uma fase longa e indistinguivel de um run travado.
HEARTBEAT_PID=""

start_heartbeat() {
  local err_log="$1" label="$2"
  HEARTBEAT_PID=""
  $VERBOSE && return 0
  [ "$HEARTBEAT_SECS" -gt 0 ] 2> /dev/null || return 0

  (
    local waited=0 last
    while true; do
      sleep "$HEARTBEAT_SECS"
      waited=$((waited + HEARTBEAT_SECS))
      last=$(grep -v '^[[:space:]]*$' "$err_log" 2> /dev/null | tail -n 1 | cut -c1-100 || true)
      if [ -n "$last" ]; then
        log "$label — $(format_duration "$waited") | $last"
      else
        log "$label — $(format_duration "$waited")"
      fi
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  [ -n "$HEARTBEAT_PID" ] || return 0
  kill "$HEARTBEAT_PID" 2> /dev/null || true
  wait "$HEARTBEAT_PID" 2> /dev/null || true
  HEARTBEAT_PID=""
}

# run_split <stdout_log> <stderr_log> <stdin_file> <cmd> [args...]
#
# Roda o comando com os streams separados:
#   stdout -> <stdout_log>   (resposta final; o que os gates parseiam)
#   stderr -> <stderr_log>   (progresso; so diagnostico)
#
# Quiet (default): nenhum dos dois vai para o terminal — os logs guardam tudo e
# o GATE_CAUSE ja imprime o tail dos dois quando um gate reprova. Redirect
# direto, sem FIFO: nada para sincronizar.
#
# Verbose: os dois saem ao vivo. O stderr passa por um FIFO com um `tee` de PID
# conhecido, e nao por process substitution: `wait` no PID garante que o arquivo
# esta completo antes de qualquer gate ler. Com >(...) havia corrida — o gate
# podia ler um stderr.log ainda pela metade.
run_split() {
  local out_log="$1" err_log="$2" stdin_file="$3"
  shift 3

  local rc=0

  if ! $VERBOSE; then
    "$@" < "$stdin_file" > "$out_log" 2> "$err_log" || rc=$?
    return "$rc"
  fi

  local fifo_dir fifo tee_pid
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-stderr.XXXXXX")"
  fifo="$fifo_dir/stderr"
  mkfifo "$fifo"

  tee "$err_log" < "$fifo" >&2 &
  tee_pid=$!

  "$@" < "$stdin_file" 2> "$fifo" | tee "$out_log" || rc=$?

  wait "$tee_pid" 2> /dev/null || true
  rm -rf "$fifo_dir"

  return "$rc"
}

# ---------------------------------------------------------------------------
# Limite de uso (item 5) — so olha o FIM do log, com padroes por engine
# ---------------------------------------------------------------------------

# Ecoa o epoch de reset se encontrado, "0" para limite sem horario.
# Retorna 0 quando detecta limite, 1 quando nao ha limite.
detect_usage_limit() {
  local log_file="$1"
  local tail_txt pattern epoch err_log

  err_log="$(stderr_log_for "$log_file")"

  # A mensagem de limite sai no FIM da execucao. Olhar o log inteiro faz output
  # de teste do projeto ("429", "Too Many Requests") disparar espera de 30min.
  # Le os DOIS streams: dependendo da CLI e da versao, o aviso de limite cai no
  # stdout (claude, dentro do JSON) ou no stderr (codex).
  tail_txt=$(
    {
      tail -n 20 "$log_file" 2>/dev/null || true
      [ -f "$err_log" ] && { tail -n 20 "$err_log" 2>/dev/null || true; }
    } || true
  )

  if [[ "$ENGINE" == "claude" ]]; then
    pattern='usage limit reached'
  else
    pattern='rate limit reached|quota exceeded|usage limit reached'
  fi

  grep -qiE "$pattern" <<< "$tail_txt" || return 1

  epoch=$(grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' <<< "$tail_txt" \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)

  if [ -z "$epoch" ]; then
    epoch=$(grep -oiE 'reset[a-z ]*[0-9]{10,13}' <<< "$tail_txt" \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  echo "${epoch:-0}"
  return 0
}

wait_for_reset() {
  local epoch="$1"
  local now wait_secs
  now=$(date +%s)

  LIMIT_WAITS=$((LIMIT_WAITS + 1))
  if [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ]; then
    ST_RUN_STATUS="aborted"
    fail "Limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    fail "Abortando em vez de dormir indefinidamente."
    notify_and_record limit_abort \
      "Run abortado: limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    ui_stop
    exit 1
  fi

  local reset_note
  if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -gt 0 ]; then
    if [ "${#epoch}" -ge 13 ]; then
      epoch=$((epoch / 1000))
    fi
    wait_secs=$((epoch - now + LIMIT_BUFFER))
    if [ "$wait_secs" -lt "$LIMIT_BUFFER" ]; then
      wait_secs=$LIMIT_BUFFER
    fi
    reset_note="Reset previsto para $(date -d "@$epoch" '+%d/%m %H:%M')."
    warn "Limite de uso atingido. Reset previsto para $(date -d "@$epoch" '+%d/%m %H:%M:%S')."
  else
    wait_secs=$LIMIT_WAIT_DEFAULT
    reset_note="Sem horario de reset no output; usando espera fallback."
    warn "Limite de uso atingido. Sem horario de reset no output; aguardando fallback."
  fi

  warn "Espera $LIMIT_WAITS/$MAX_LIMIT_WAITS — aguardando $(format_duration "$wait_secs") ate retomar a MESMA fase..."

  ST_LIMIT_WAITING=1
  ST_LIMIT_UNTIL=$((now + wait_secs))
  set_activity "aguardando o reset do limite de uso"
  notify_and_record limit_hit \
    "Limite de uso atingido. $reset_note Dormindo $(format_duration "$wait_secs") e retomando a MESMA fase (espera $LIMIT_WAITS/$MAX_LIMIT_WAITS). Nenhuma acao necessaria."

  local remaining=$wait_secs chunk
  while [ "$remaining" -gt 0 ]; do
    chunk=60
    [ "$remaining" -lt 60 ] && chunk=$remaining
    sleep "$chunk"
    remaining=$((remaining - chunk))
    [ "$remaining" -gt 0 ] && log "Retomando em $(format_duration "$remaining")..."
  done

  ST_LIMIT_WAITING=0
  ST_LIMIT_UNTIL=0
  success "Reset provavelmente concluido. Retomando execucao."
  notify_and_record limit_over "Limite liberado. Retomando a fase automaticamente."
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Loop de resiliencia a limite de uso: nao consome ciclo de correcao.
run_engine() {
  local prompt_file="$1" log_file="$2" mode="$3"

  export RALPH_ENGINE="$ENGINE"
  export RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES"

  local err_log
  err_log="$(stderr_log_for "$log_file")"
  # O painel mede o crescimento dos dois streams para provar que o engine esta
  # vivo mesmo quando ele nao escreve nada legivel no stderr.
  ST_STDERR_LOG="$err_log"
  ST_STDOUT_LOG="$log_file"

  local model_args=()
  if [[ "$mode" == "verify" ]] && [ -n "$VERIFY_MODEL" ]; then
    model_args=(--model "$VERIFY_MODEL")
  fi

  local hb_label
  if [[ "$mode" == "verify" ]]; then
    hb_label="$ENGINE verificando a fase ${RALPH_PHASE_NUM:-?}"
  else
    hb_label="$ENGINE implementando a fase ${RALPH_PHASE_NUM:-?} (ciclo ${RALPH_PHASE_ATTEMPT:-1})"
  fi

  while true; do
    local rc=0

    : > "$err_log"
    start_heartbeat "$err_log" "$hb_label"

    # stdout e stderr vao para arquivos DIFERENTES. Unir os dois (2>&1) fazia
    # o progresso do engine entrar no log parseado pelos gates — e no codex a
    # resposta final aparece nos dois streams, duplicando as linhas TASK.
    if [[ "$ENGINE" == "codex" ]]; then
      if [[ "$mode" == "verify" ]]; then
        run_split "$log_file" "$err_log" "$prompt_file" \
          codex exec --sandbox read-only "${model_args[@]}" - || rc=$?
      else
        run_split "$log_file" "$err_log" "$prompt_file" \
          codex exec --sandbox danger-full-access - || rc=$?
      fi
    else
      # stdin /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      if [[ "$mode" == "verify" ]]; then
        run_split "$log_file" "$err_log" /dev/null \
          env -u CLAUDECODE claude --dangerously-skip-permissions \
          "${model_args[@]}" \
          -p "$(cat "$prompt_file")" \
          --allowedTools "Read,Glob,Grep" \
          --output-format text || rc=$?
      else
        # JSON: o exit code do CLI e sinal fraco; o gate 0 le is_error.
        run_split "$log_file" "$err_log" /dev/null \
          env -u CLAUDECODE claude --dangerously-skip-permissions \
          -p "$(cat "$prompt_file")" \
          --output-format json || rc=$?
      fi
    fi

    stop_heartbeat

    local reset_epoch
    if reset_epoch=$(detect_usage_limit "$log_file"); then
      wait_for_reset "$reset_epoch"
      continue
    fi

    return "$rc"
  done
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# Gate 0 — o engine terminou de verdade?
# Preenche GATE_CAUSE quando vermelho.
GATE_CAUSE=""

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  # O veredito sai SO do stdout (resposta final). O stderr entra apenas no
  # diagnostico: telemetria de progresso nao decide gate.
  if [[ "$ENGINE" == "claude" ]]; then
    if ! grep -qF '"type":"result"' "$log_file" && ! grep -qF '"type": "result"' "$log_file"; then
      GATE_CAUSE="O engine terminou sem emitir um resultado. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      return 1
    fi
    if grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' "$log_file"; then
      GATE_CAUSE="O engine reportou is_error=true. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      return 1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O engine saiu com codigo $rc. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
    return 1
  fi

  return 0
}

# Assinatura da arvore: rastreados (status + diff) e nao-rastreados (conteudo).
# Sem mutar o index.
tree_signature() {
  {
    git status --porcelain
    git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum 2> /dev/null
  } 2> /dev/null | sha256sum | cut -c1-16
}

# Gate 1 — esta sessao escreveu codigo?
#
# SINAL, nao veredito. Uma fase pode ja estar implementada antes da sessao
# (tasks `[x]`, run anterior commitada, dev implementou a mao). Nesse caso o
# engine correto NAO escreve nada, e reprovar aqui seria um falso negativo:
# so os gates 2 e 3 sabem se o codigo esta completo.
#
# O retorno alimenta a causa do ciclo de correcao ("a sessao nao escreveu
# nada") quando algum gate posterior reprova.
gate1_session_wrote() {
  local sig_before="$1"
  [ "$(tree_signature)" != "$sig_before" ]
}

# Gate 2 — a suite do projeto passa, rodada PELO ralph (fora da sessao do agente)?
gate2_tests_pass() {
  local test_log="$1"

  gate_start 2

  if [ -z "$TEST_CMD" ]; then
    gate_end 2 skip
    return 0
  fi

  set_activity "executando a suite do projeto"
  log "Gate 2 — rodando a suite do projeto: $TEST_CMD"
  local rc=0
  # < /dev/null: sail test (docker compose exec) anexa stdin e consumiria o
  # stream de quem chamou, alem de poder travar esperando input.
  bash -c "$TEST_CMD" < /dev/null > "$test_log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O comando de teste do projeto ('$TEST_CMD') falhou com codigo $rc. Saida:"$'\n'"$(tail -n 200 "$test_log")"
    gate_end 2 fail
    return 1
  fi

  success "Gate 2 — suite verde"
  gate_end 2 pass
  return 0
}

# Gate 3 — sessao verificadora independente, read-only, task a task.
# O gate final: roda em toda fase por default (always). Modo auto economiza,
# rodando so quando o veredito do gate 2 nao basta:
#   - a sessao nao escreveu nada (claim "ja implementada" — so a verificacao
#     independente confirma isso sem confiar na palavra do engine)
#   - ciclo de correcao (a fase ja reprovou uma vez)
#   - gate 2 desabilitado (sem suite, o verificador e o unico gate)
# GATE3_RAN diz ao caminho "ja implementada" quais gates de fato validaram HEAD.
GATE3_RAN=0

gate3_independent_verify() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}.log"

  GATE3_RAN=0
  local remapped_labels=0
  gate_start 3

  case "$VERIFY_MODE" in
    off)
      log "Gate 3 pulado (--no-verify)"
      gate_end 3 skip
      return 0
      ;;
    auto)
      if [ "$cycle" -eq 1 ] && [ "$session_wrote" -eq 1 ] && [ -n "$TEST_CMD" ]; then
        log "Gate 3 pulado: a sessao escreveu codigo e a suite passou (RALPH_VERIFY=always para rodar sempre)"
        gate_end 3 skip
        return 0
      fi
      ;;
  esac

  local expected
  expected=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 pulado: a fase nao declara nenhuma task '- [ ]'"
    gate_end 3 skip
    return 0
  fi

  GATE3_RAN=1
  set_activity "verificacao independente ($expected tasks)"
  log "Gate 3 — sessao verificadora independente ($expected tasks${VERIFY_MODEL:+, modelo: $VERIFY_MODEL})"

  local prompt_file
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  run_engine "$prompt_file" "$verify_log" verify || true

  # SO o stdout do verificador (resposta final). O progresso vive no
  # .stderr.log e nunca e parseado: no codex a resposta final tambem sai no
  # stderr, e ler os dois duplicava toda linha TASK.
  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$verify_log" \
    | grep -E '^TASK[[:space:]]+[0-9]+[[:space:]]*:[[:space:]]*(DONE|INCOMPLETE)' || true)

  local emitted
  emitted=$(printf '%s' "$task_lines" | grep -c . || true)

  if [ "$emitted" -eq 0 ]; then
    GATE_CAUSE="O verificador independente nao emitiu nenhuma linha 'TASK <n>: DONE|INCOMPLETE' — nao foi possivel confirmar que a fase esta completa. Ultimas linhas do verificador:"$'\n'"$(engine_tail "$verify_log" 40)"
    gate_end 3 fail
    return 1
  fi

  # Cobertura se mede em INDICES UNICOS, nao em linhas. O modelo repete linha
  # (retry, resumo no fim) e cada repeticao inflava a contagem: 2 tasks viravam
  # "4 de 2 — cobertura incompleta" com a fase inteira pronta.
  local indices parsed
  indices=$(printf '%s\n' "$task_lines" \
    | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*$/\1/p' \
    | sort -n -u)
  parsed=$(printf '%s' "$indices" | grep -c . || true)

  if [ "$emitted" -gt "$parsed" ]; then
    log "Gate 3 — $emitted linhas TASK emitidas, $parsed indice(s) unico(s) (duplicatas ignoradas)"
  fi

  # Indice fora de 1..expected: o verificador inventou task ou desalinhou a
  # numeracao. Contar isso como cobertura mascararia uma task real nao vista.
  local out_of_range
  out_of_range=$(printf '%s\n' "$indices" | awk -v max="$expected" 'NF && ($1 + 0 < 1 || $1 + 0 > max)' | tr '\n' ' ')

  # Fases fatiadas de um PHASES.md multi-fase carregam rotulos globais nas
  # tasks (ex.: 'T33'..'T35' na fase 9). Mesmo instruido a usar posicao, o
  # verificador tende a copiar o rotulo visivel. Se TODO indice emitido casa
  # com um rotulo da fase, a cobertura e verificavel do mesmo jeito:
  # remapeia rotulo -> posicao em vez de reprovar por "fora do intervalo".
  if [ -n "${out_of_range// /}" ]; then
    local labels label_count remapped
    labels=$(sed -nE 's/^[[:space:]]*- \[[ x]\][[:space:]]*\**T0*([0-9]+).*$/\1/p' "$PHASES_DIR/$phase_file")
    label_count=$(printf '%s' "$labels" | grep -c . || true)
    if [ "$label_count" -eq "$expected" ]; then
      remapped=$(awk '
        NR == FNR { if (NF) pos[$1 + 0] = ++n; next }
        NF { if (($1 + 0) in pos) print pos[$1 + 0]; else print "X" }
      ' <(printf '%s\n' "$labels") <(printf '%s\n' "$indices"))
      if ! printf '%s\n' "$remapped" | grep -qx 'X'; then
        indices=$(printf '%s\n' "$remapped" | sort -n -u)
        out_of_range=""
        remapped_labels=1
        log "Gate 3 — verificador emitiu rotulos das tasks em vez de posicoes; remapeado rotulo -> posicao (1..$expected)"
      fi
    fi
  fi

  if [ -n "${out_of_range// /}" ]; then
    GATE_CAUSE="O verificador emitiu indice(s) de task fora do intervalo 1..$expected: ${out_of_range%% }. A numeracao nao bate com a fase — nao da para confirmar cobertura. Linhas emitidas:"$'\n'"$task_lines"
    gate_end 3 fail
    return 1
  fi

  # Duplicata nao pode esconder buraco: 'TASK 1' duas vezes e nenhum 'TASK 2'
  # da 2 linhas para 2 tasks, mas cobre so metade da fase.
  # Publica o veredito POR TASK para o painel e o dashboard. Apresentacao pura:
  # o gate ja decidiu abaixo; isto so torna visivel QUAL task travou.
  # Quando houve remapeamento rotulo -> posicao, os indices de `indices` estao
  # normalizados mas os de `task_lines` nao: misturar os dois pintaria de verde
  # uma task incompleta. Nesse caso nao publica nada — pendente e honesto.
  if [ "$remapped_labels" -eq 0 ]; then
    {
      printf '%s\n' "$indices"    | awk 'NF { print $1 "|DONE" }'
      printf '%s\n' "$task_lines" | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*INCOMPLETE.*/\1|INCOMPLETE/p'
    } > "$UI_DIR/verdicts-${ST_PHASE_NUM}.txt" 2> /dev/null || true
  else
    rm -f "$UI_DIR/verdicts-${ST_PHASE_NUM}.txt" 2> /dev/null || true
  fi

  local missing
  missing=$(printf '%s\n' "$indices" \
    | awk -v max="$expected" 'NF{seen[$1 + 0] = 1} END{for (i = 1; i <= max; i++) if (!(i in seen)) printf "%d ", i}')

  if [ -n "${missing// /}" ]; then
    GATE_CAUSE="O verificador cobriu $parsed de $expected tasks — faltou veredito para a(s) task(s): ${missing%% }. Linhas emitidas:"$'\n'"$task_lines"
    gate_end 3 fail
    return 1
  fi

  # INCOMPLETE vence DONE no mesmo indice: se o verificador se contradisse
  # sobre a mesma task, o gate fica vermelho. Falso vermelho custa um ciclo de
  # correcao; falso verde commita codigo quebrado.
  local incomplete
  incomplete=$(printf '%s\n' "$task_lines" | grep 'INCOMPLETE' | awk '!seen[$2]++' || true)

  if [ -n "$incomplete" ]; then
    GATE_CAUSE="O verificador independente encontrou tasks incompletas:"$'\n'"$incomplete"
    gate_end 3 fail
    return 1
  fi

  success "Gate 3 — $parsed/$expected tasks confirmadas no codigo"
  gate_end 3 pass
  return 0
}

# ---------------------------------------------------------------------------
# Execucao de fase
# ---------------------------------------------------------------------------

commit_phase() {
  local phase_num="$1" phase_title="$2"
  git add -A
  if git diff --cached --quiet; then
    fail "Nada para commitar apos os gates — estado inesperado."
    return 1
  fi
  git commit -q -m "feat(phase-${phase_num}): ${phase_title}"
  log "Commit criado: feat(phase-${phase_num}): ${phase_title}"
}

commit_wip() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): incomplete — see .phases/logs/"
  warn "Commit wip criado para a fase $phase_num — a proxima fase parte de arvore limpa"
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"
  export RALPH_PROJECT="$PROJECT_NAME"

  LIMIT_WAITS=0
  GATE_CAUSE=""
  ST_LAST_ERROR=""

  ST_PHASE_NUM="$phase_num"
  ST_PHASE_SEQ="$seq"
  ST_PHASE_TOTAL="$total"
  ST_PHASE_TITLE="$phase_title"
  ST_PHASE_STATUS="running"
  ST_PHASE_START="$phase_start"
  ST_CYCLE=1
  state_event phase_start "title=$phase_title" "seq=$seq" "total=$total"

  $UI_ACTIVE || echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"

  local cycle=1
  while [ "$cycle" -le "$MAX_CYCLES" ]; do
    export RALPH_PHASE_ATTEMPT="$cycle"
    ST_CYCLE="$cycle"
    # Ciclo novo revalida tudo: gates do ciclo anterior nao valem mais.
    ST_GATE0="pending"; ST_GATE1="pending"; ST_GATE2="pending"; ST_GATE3="pending"
    [ "$cycle" -gt 1 ] && warn "Ciclo de correcao $cycle/$MAX_CYCLES..."

    local prompt_file log_file rc=0 sig_before
    log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"

    if [ "$cycle" -eq 1 ]; then
      prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
    else
      prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    sig_before=$(tree_signature)
    if [ "$cycle" -eq 1 ]; then
      set_activity "implementando a fase"
    else
      set_activity "corrigindo a fase (ciclo $cycle/$MAX_CYCLES)"
    fi
    run_engine "$prompt_file" "$log_file" impl || rc=$?

    GATE_CAUSE=""

    # Gate 1 e sinal, nao veredito: uma fase ja implementada faz o engine
    # (corretamente) nao escrever nada. Quem decide sao os gates 2 e 3.
    # O sinal tambem alimenta o modo auto do gate 3: sessao sem escrita e
    # exatamente o caso em que a verificacao independente e obrigatoria.
    local no_change_note="" session_wrote=1
    gate_start 1
    if ! gate1_session_wrote "$sig_before"; then
      session_wrote=0
      no_change_note="A sessao anterior terminou sem alterar nenhum arquivo. "
      warn "Gate 1 — a sessao nao escreveu nada; validando o codigo existente"
      # Sinal, nao veredito: 'skip' e o unico rotulo honesto aqui. Marcar 'fail'
      # pintaria de vermelho o caso legitimo da fase ja implementada.
      gate_end 1 skip
    else
      gate_end 1 pass
    fi

    # Gate 0 fora da cadeia if/elif: precisa registrar o veredito no estado
    # ANTES de decidir o fluxo, e a cadeia so aceita um comando por ramo.
    local gate0_ok=1
    gate_start 0
    if gate0_engine_finished "$log_file" "$rc"; then
      gate_end 0 pass
    else
      gate_end 0 fail
      gate0_ok=0
    fi

    if [ "$gate0_ok" -eq 0 ]; then
      LAST_GATE="gate 0 — engine nao concluiu"
      ST_LAST_ERROR="$(gate_cause_summary)"
      fail "Gate 0 vermelho"
    elif ! gate2_tests_pass "$LOG_DIR/${phase_file%.md}.test-${cycle}.log"; then
      LAST_GATE="gate 2 — suite de testes do projeto"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      ST_LAST_ERROR="$(gate_cause_summary)"
      fail "Gate 2 vermelho — testes do projeto falharam"
    elif ! gate3_independent_verify "$phase_file" "$cycle" "$session_wrote"; then
      LAST_GATE="gate 3 — verificacao independente"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      ST_LAST_ERROR="$(gate_cause_summary)"
      fail "Gate 3 vermelho — implementacao incompleta"
    else
      local phase_duration=$(($(date +%s) - phase_start))

      # Gates verdes e nada a commitar => a fase ja estava implementada em HEAD
      # (run anterior commitada, tasks [x], codigo escrito a mao).
      if [ -z "$(git status --porcelain)" ]; then
        success "Phase $phase_num: $phase_title — JA IMPLEMENTADA (nada a commitar)"
        if [ "$GATE3_RAN" -eq 1 ]; then
          log "Gates 2 e 3 verdes contra o codigo em HEAD; nenhum commit criado."
        else
          log "Gate 2 verde contra o codigo em HEAD; nenhum commit criado."
        fi
        mark_phase_done "$phase_file"
        ST_PHASE_STATUS="done"
        notify_and_record phase_done \
          "Fase ja estava implementada em HEAD — gates verdes, nenhum commit criado."
        return 0
      fi

      success "Phase $phase_num: $phase_title — COMPLETA ($(format_duration "$phase_duration"))"
      if ! commit_phase "$phase_num" "$phase_title"; then
        LAST_GATE="commit"
        ST_PHASE_STATUS="failed"
        FAILED_NUMS+=" $phase_num"
        notify_and_record phase_failed \
          "Gates verdes, mas o commit da fase falhou. O run parou aqui."
        return 1
      fi
      mark_phase_done "$phase_file"
      ST_PHASE_STATUS="done"
      notify_and_record phase_done \
        "Fase COMPLETA em $(format_duration "$phase_duration") — commitada. Restam $((total - seq)) fase(s)."
      return 0
    fi

    # So se chega aqui com gate vermelho. No modo quiet o progresso do engine
    # nao passou pelo terminal: diga onde ele esta antes de gastar outro ciclo.
    if ! $VERBOSE; then
      log "Progresso do engine: $(stderr_log_for "$log_file")"
    fi

    cycle=$((cycle + 1))
  done

  local phase_duration=$(($(date +%s) - phase_start))
  ST_PHASE_STATUS="failed"
  FAILED_NUMS+=" $phase_num"
  # O dump da causa tem ate 40 linhas — nao cabe na area de mensagens do painel.
  # Desmonta o quadro antes e deixa a saida rolar como sempre.
  ui_stop
  fail "Phase $phase_num: $phase_title — FALHOU apos $MAX_CYCLES ciclos ($(format_duration "$phase_duration"))"
  fail "Ultima causa ($LAST_GATE):"
  printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
  fail "Logs em: $LOG_DIR/${phase_file%.md}.*"

  # O trabalho parcial fica na arvore; o preflight da proxima execucao exige
  # arvore limpa. Diga o que fazer em vez de deixar o dev descobrir no abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "O trabalho parcial desta fase ficou na arvore. Antes de re-rodar o ralph:"
    warn "    commite (o ralph revalida a fase e segue) ou 'git checkout -- . && git clean -fd' (descarta)"
  fi

  # GATE_CAUSE carrega ate 40 linhas de log; a notificacao leva so o suficiente
  # para o dev decidir se vale abrir o terminal.
  local cause_summary
  cause_summary=$(printf '%s' "$GATE_CAUSE" | head -n 2 | cut -c1-240 || true)
  notify_and_record phase_failed \
    "FALHOU apos $MAX_CYCLES ciclos ($(format_duration "$phase_duration")). Ultimo gate: ${LAST_GATE:-?}. ${cause_summary}"

  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""

main() {
  # --attach nao executa fase nenhuma: nao passa por preflight (nao exige
  # arvore limpa, nem engine no PATH, nem comando de teste) e nao toca no
  # documento de entrada. Sai antes de qualquer coisa que escreva.
  if $ATTACH; then
    attach_run
    exit 0
  fi

  # Ctrl-C ou abort do preflight nao pode deixar cursor escondido nem servidor
  # orfao segurando a porta.
  trap cleanup_ui EXIT INT TERM

  preflight_checks
  split_phases
  apply_from_override
  serve_start

  local total_phases
  total_phases=$(manifest_entries | wc -l)

  if [ "$total_phases" -eq 0 ]; then
    fail "Nenhuma fase extraida de $INPUT_FILE."
    exit 1
  fi

  if [ "$FROM_PHASE" -gt "$total_phases" ]; then
    fail "--from $FROM_PHASE excede o total de fases ($total_phases)."
    exit 1
  fi

  echo ""
  log "$total_phases fases para implementar (engine: $ENGINE, max-cycles: $MAX_CYCLES)"
  [ "$FROM_PHASE" -gt 1 ] && log "Iniciando a partir da fase $FROM_PHASE"
  [ -n "$SERVE_URL" ] && success "Dashboard web: $SERVE_URL"
  echo ""

  local file num title
  local pending=0
  while IFS='|' read -r file num title; do
    if [ "$num" -lt "$FROM_PHASE" ]; then
      echo -e "  ${BLUE}[$num] $title (pulada por --from)${NC}"
    elif is_phase_done "$file"; then
      echo -e "  ${GREEN}[$num] $title (ja completada)${NC}"
    else
      echo -e "  ${YELLOW}[$num] $title${NC}"
      pending=$((pending + 1))
    fi
  done < <(manifest_entries)

  local start_time
  start_time=$(date +%s)
  RUN_START_EPOCH=$start_time
  RUN_ID="run-$RALPH_PID"
  ST_RUN_STATUS="running"
  ST_ACTIVITY="preparando"
  ST_STAGE_START=$start_time
  ST_PHASE_TOTAL="$total_phases"
  echo ""
  log "Inicio: $(date '+%d/%m/%Y %H:%M:%S')"

  # A lista de fases fica fora da mensagem de proposito: um documento com dezenas
  # de fases estouraria o limite de 4096 chars do Telegram.
  notify_and_record run_start \
    "Run iniciado: $pending de $total_phases fase(s) a executar (engine: $ENGINE, max-cycles: $MAX_CYCLES). Input: $INPUT_FILE"

  # O painel sobe so aqui: preflight e a lista inicial de fases sao saida
  # normal, e o quadro tem que ficar sendo as ultimas linhas do terminal.
  ui_start

  local seq=0
  local failed_phases=() skipped_phases=() completed_phases=()

  # fd 3, nunca stdin: comandos do corpo (claude -p, sail test / docker compose
  # exec) leem stdin quando nao e TTY e engoliriam o resto do manifest — o run
  # pararia apos a primeira fase.
  while IFS='|' read -r -u 3 file num title; do
    seq=$((seq + 1))

    if [ "$num" -lt "$FROM_PHASE" ]; then
      log "Pulando Phase $num: $title (antes de --from $FROM_PHASE)"
      skipped_phases+=("$title")
      continue
    fi

    if is_phase_done "$file"; then
      log "Pulando Phase $num: $title (ja completada)"
      skipped_phases+=("$title")
      continue
    fi

    if run_phase "$file" "$num" "$title" "$seq" "$total_phases"; then
      completed_phases+=("$title")
    else
      failed_phases+=("$title")
      if $KEEP_GOING; then
        warn "--keep-going: seguindo para a proxima fase"
        commit_wip "$num"
      else
        warn "Parando na primeira fase que falhou (use --keep-going para continuar)"
        break
      fi
    fi
  done 3< <(manifest_entries)

  local end_time total_duration
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))

  ST_PHASE_STATUS="idle"
  ST_ACTIVITY="encerrado"
  ST_STAGE_START=$(date +%s)
  if [ ${#failed_phases[@]} -gt 0 ]; then ST_RUN_STATUS="failed"; else ST_RUN_STATUS="done"; fi
  # O relatorio final e saida longa e rolante: o painel sai de cena antes.
  ui_stop
  state_sync

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RELATORIO FINAL (engine: $ENGINE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local phase
  if [ ${#completed_phases[@]} -gt 0 ]; then
    echo ""
    success "Completadas (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do printf '    %b%s%b\n' "$GREEN" "$phase" "$NC"; done
  fi

  if [ ${#skipped_phases[@]} -gt 0 ]; then
    echo ""
    log "Puladas (${#skipped_phases[@]}):"
    for phase in "${skipped_phases[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#failed_phases[@]} -gt 0 ]; then
    echo ""
    fail "Falharam (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do printf '    %b%s%b\n' "$RED" "$phase" "$NC"; done
    echo ""
    fail "Verifique os logs em $LOG_DIR/"
  fi

  echo ""
  log "Inicio: $(date -d "@$start_time" '+%d/%m/%Y %H:%M:%S')"
  log "Fim:    $(date -d "@$end_time" '+%d/%m/%Y %H:%M:%S')"
  log "Duracao total: $(format_duration "$total_duration")"
  echo ""

  local run_summary
  run_summary="Run encerrado em $(format_duration "$total_duration"): ${#completed_phases[@]} completa(s), ${#failed_phases[@]} falharam, ${#skipped_phases[@]} pulada(s)."
  if [ ${#failed_phases[@]} -gt 0 ]; then
    run_summary="$run_summary Falharam: $(printf '%s; ' "${failed_phases[@]}")"
  fi
  notify_and_record run_done "$run_summary"

  # O estado final fica em disco para inspecao depois do run; so o servidor cai.
  if [ -n "$SERVE_URL" ]; then
    log "Dashboard encerrado. Estado final em $STATE_FILE e $EVENTS_FILE."
  fi
  serve_stop

  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

main
