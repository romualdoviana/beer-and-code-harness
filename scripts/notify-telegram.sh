#!/usr/bin/env bash
#
# Adaptador de notificacao do ralph.sh para o Telegram Bot API.
#
# O ralph.sh chama este script via RALPH_NOTIFY_CMD a cada evento relevante do
# run. O objetivo e acompanhar pelo celular um run longo (madrugada, multiplos
# projetos em paralelo) sem abrir o terminal.
#
# Uso:
#   export RALPH_NOTIFY_CMD="$HOME/.claude/scripts/notify-telegram.sh"
#   ./ralph.sh .spec/features/<slug>/PHASES.md
#
#   ./notify-telegram.sh --setup    descobre o chat_id (nao imprime o token)
#   ./notify-telegram.sh --test     envia uma mensagem de teste
#
# Credenciais: NUNCA literais neste arquivo. Resolvidas nesta ordem:
#   1. env TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID
#   2. arquivo de config: $RALPH_NOTIFY_ENV_FILE
#      (default: ~/.config/ralph-notify/telegram.env, permissao 600)
#
# argv:
#   $1  evento: run_start | phase_done | phase_failed | limit_hit | limit_over
#               | limit_abort | run_done
#   $2  mensagem ja formatada pelo ralph.sh
#
# Contexto lido do ambiente exportado pelo ralph.sh:
#   RALPH_PROJECT RALPH_ENGINE RALPH_PHASE_NUM RALPH_PHASE_TOTAL
#   RALPH_PHASE_TITLE RALPH_EVENT RALPH_OUTCOME RALPH_RUN_ID
#   RALPH_PHASE_ATTEMPT RALPH_PHASE_MAX_ATTEMPTS RALPH_GATE2 RALPH_GATE3
#   RALPH_TEST_SCOPE RALPH_LOG_PATH
#
# Invariante: exit 0 SEMPRE. Falha de rede, token ausente ou erro da API nunca
# derrubam o run do ralph — a notificacao e um efeito colateral, nao um gate.

set -uo pipefail

ENV_FILE="${RALPH_NOTIFY_ENV_FILE:-$HOME/.config/ralph-notify/telegram.env}"
# Override serve para teste sem rede e para quem roda um Bot API server local.
API_BASE="${RALPH_NOTIFY_API_BASE:-https://api.telegram.org}"

warn() { echo "[notify-telegram] $1" >&2; }

# ---------------------------------------------------------------------------
# Credenciais
# ---------------------------------------------------------------------------

load_credentials() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    if [ -f "$ENV_FILE" ]; then
      set +u
      # Configuracao local escolhida em runtime; nao e uma dependencia do repo.
      # shellcheck disable=SC1090
      . "$ENV_FILE"
      set -u
    fi
  fi

  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    warn "TELEGRAM_BOT_TOKEN ausente (env ou $ENV_FILE). Notificacao ignorada."
    return 1
  fi
  return 0
}

require_chat_id() {
  if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    warn "TELEGRAM_CHAT_ID ausente. Rode: $0 --setup"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Formatacao
# ---------------------------------------------------------------------------

# parse_mode=HTML exige escape de & < > — titulos de fase vindos do PHASES.md
# podem conter qualquer um dos tres, e um escape faltando devolve HTTP 400
# (mensagem perdida). A ordem importa: & antes de < e >.
html_escape() {
  printf '%s' "${1:-}" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

event_icon() {
  case "$1" in
    run_start)    echo "🚀" ;;
    phase_done)   echo "✅" ;;
    phase_failed) echo "❌" ;;
    limit_hit)    echo "⏳" ;;
    limit_over)   echo "▶️" ;;
    limit_abort)  echo "🛑" ;;
    run_done)     echo "🏁" ;;
    *)            echo "🔔" ;;
  esac
}

# Limita ANTES do escape HTML: cortar uma entidade pela metade perde o envio.
# O orcamento conservador considera ate 2 unidades UTF-16 por caractere.
short_text() {
  local text="$1" max="$2"
  text="$(printf '%s' "$text" | tr -d '\000-\010\013-\037\177')"
  if [ "${#text}" -gt "$max" ]; then
    printf '%s [mensagem truncada]' "${text:0:$max}"
  else
    printf '%s' "$text"
  fi
}

event_title() {
  case "$1" in
    run_start) printf 'Execução iniciada' ;;
    phase_done) printf 'Fase concluída' ;;
    phase_failed)
      if [ "${RALPH_OUTCOME:-}" = environment ]; then printf 'Interrompida pelo ambiente'
      else printf 'Fase falhou'; fi ;;
    limit_hit) printf 'Aguardando limite de uso' ;;
    limit_over) printf 'Execução retomada' ;;
    limit_abort) printf 'Execução interrompida por limite' ;;
    run_done)
      case "${RALPH_OUTCOME:-}" in
        environment) printf 'Interrompida pelo ambiente' ;;
        failed|aborted) printf 'Execução encerrada com falhas' ;;
        done) printf 'Execução concluída' ;;
        *) printf 'Execução encerrada' ;;
      esac ;;
    *) printf 'Atualização do Ralph' ;;
  esac
}

gate_text() {
  case "$1" in
    pass) printf 'aprovado' ;; fail) printf 'falhou' ;;
    skip) printf 'não executado' ;; running) printf 'em execução' ;;
    *) printf 'aguardando' ;;
  esac
}

build_text() {
  local event="$1" message="$2" icon project engine phase_line title log_path
  local phase_total="${RALPH_PHASE_TOTAL:-?}" max_attempts="${RALPH_PHASE_MAX_ATTEMPTS:-?}"
  icon=$(event_icon "$event")
  if [ "${RALPH_OUTCOME:-}" = environment ]; then icon='⚠️'
  elif [ "$event" = run_done ] && [ "${RALPH_OUTCOME:-}" = failed ]; then icon='❌'; fi
  project=$(html_escape "$(short_text "${RALPH_PROJECT:-projeto}" 64)")
  engine=$(html_escape "$(short_text "${RALPH_ENGINE:-}" 24)")
  title=$(event_title "$event")
  printf '%s <b>%s</b>\n<b>%s</b>\n' "$icon" "$project" "$title"

  # Eventos do run nunca herdam fase, ciclo ou gates da ultima fase.
  if [ "$event" != run_done ] && [ "$event" != run_start ] && [ -n "${RALPH_PHASE_NUM:-}" ]; then
    phase_line="Fase ${RALPH_PHASE_NUM:0:6}/${phase_total:0:6}"
    phase_line+=" · $(short_text "${RALPH_PHASE_TITLE:-}" 96)"
    printf '\n%s\n' "$(html_escape "$phase_line")"
    if [ -n "${RALPH_PHASE_ATTEMPT:-}" ]; then
      printf 'Ciclo: %s/%s\n' "$(html_escape "${RALPH_PHASE_ATTEMPT:0:6}")" \
        "$(html_escape "${max_attempts:0:6}")"
    fi
    if [ "$event" = phase_done ] || [ "$event" = phase_failed ]; then
      if [ "${RALPH_OUTCOME:-}" = environment ]; then
        printf 'G2: indisponível (sem veredito sobre o código)\n'
      else
        printf 'G2: %s · G3: %s\n' "$(gate_text "${RALPH_GATE2:-}")" "$(gate_text "${RALPH_GATE3:-}")"
      fi
      case "${RALPH_TEST_SCOPE:-}" in
        full) printf 'Suite: completa\n' ;; scoped) printf 'Suite: escopada\n' ;;
        skip) printf 'Suite: não executada\n' ;;
      esac
    fi
  fi
  printf '\n%s\n' "$(html_escape "$(short_text "$message" 1000)")"

  case "$event" in
    phase_failed|limit_abort)
      log_path="$(short_text "${RALPH_LOG_PATH:-.phases/logs/}" 160)"
      printf '\nLog: <code>%s</code>\n' "$(html_escape "$log_path")"
      ;;
  esac
  if [ "$event" = phase_failed ] && [ "${RALPH_OUTCOME:-}" = environment ]; then
    printf 'Próximo passo: restabelecer os serviços e retomar o Ralph.\n'
  fi
  printf '\n<code>%s · %s</code>\n' "${engine:-ralph}" "$(date '+%d/%m %H:%M')"
  [ -n "${RALPH_RUN_ID:-}" ] && printf '<code>%s</code>\n' "$(html_escape "$(short_text "$RALPH_RUN_ID" 32)")"
  return 0
}

# ---------------------------------------------------------------------------
# Envio
# ---------------------------------------------------------------------------

send_message() {
  local text="$1" http_code

  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 --retry 3 --retry-delay 2 --retry-connrefused \
    -X POST "${API_BASE}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "link_preview_options={\"is_disabled\":true}" 2>/dev/null)

  if [ "$http_code" != "200" ]; then
    warn "sendMessage devolveu HTTP ${http_code:-sem-resposta}."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Modos utilitarios
# ---------------------------------------------------------------------------

# GET num metodo da API. A URL carrega o token, entao nunca e ecoada — nem em
# mensagem de erro.
api_get() {
  curl -sS --max-time 15 "${API_BASE}/bot${TELEGRAM_BOT_TOKEN}/$1" 2>/dev/null
}

# json_str <json> <jq_expr> <regex_fallback_do_valor>
json_str() {
  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$1" | jq -r "$2 // empty" 2> /dev/null
  else
    printf '%s' "$1" | grep -oE "$3" | head -1 | sed 's/.*: *"\?//; s/"\?$//'
  fi
}

api_ok()    { grep -q '"ok":[[:space:]]*true' <<< "$1"; }
api_error() { json_str "$1" '.description' '"description":[^,}]*'; }

# Nunca ecoa o token: so o que o dev precisa copiar para o .env.
do_setup() {
  local me bot_name webhook hook_url updates chats

  me=$(api_get getMe)
  if [ -z "$me" ]; then
    warn "Sem resposta da API. Verifique a rede (proxy/VPN/DNS no WSL)."
    return 0
  fi
  if ! api_ok "$me"; then
    warn "A API rejeitou o token: $(api_error "$me")"
    warn "Pegue o token novamente no @BotFather (/mybots -> API Token) e regrave em:"
    warn "    $ENV_FILE"
    return 0
  fi

  bot_name=$(json_str "$me" '.result.username' '"username":[^,}]*')
  echo "Bot autenticado: @${bot_name:-?}"

  # Com webhook ativo o Telegram entrega os updates no webhook, e getUpdates
  # responde 409/vazio para sempre — causa silenciosa de "nenhum chat_id".
  webhook=$(api_get getWebhookInfo)
  hook_url=$(json_str "$webhook" '.result.url' '"url":[^,}]*')
  if [ -n "$hook_url" ]; then
    warn "Este bot tem webhook ativo: $hook_url"
    warn "Enquanto ele existir, getUpdates nao devolve nada. Para remover:"
    warn "    curl -s \"\$API/bot\$TOKEN/deleteWebhook\"   (ou desligue no seu n8n)"
  fi

  echo
  echo "Passo 1 — abra https://t.me/${bot_name:-seu_bot} e envie /start (ou qualquer texto)."
  echo "Passo 2 — enter aqui para ler o chat_id."
  read -r _ < /dev/tty

  updates=$(api_get getUpdates)
  if ! api_ok "$updates"; then
    warn "getUpdates falhou: $(api_error "$updates")"
    return 0
  fi

  if command -v jq > /dev/null 2>&1; then
    chats=$(printf '%s' "$updates" | jq -r '
      [ .result[]? | (.message // .edited_message // .channel_post
                      // .my_chat_member // .callback_query.message) | .chat? ]
      | map(select(. != null))
      | unique_by(.id)[]
      | "chat_id=\(.id)  tipo=\(.type)  nome=\(.first_name // .title // "-")"
    ' 2> /dev/null)
  else
    chats=$(printf '%s' "$updates" \
      | grep -oE '"chat":\{"id":-?[0-9]+' | grep -oE '\-?[0-9]+' \
      | sort -u | sed 's/^/chat_id=/')
  fi

  if [ -z "$chats" ]; then
    warn "Nenhuma conversa encontrada. Causas, em ordem de frequencia:"
    warn "  1. A mensagem nao foi enviada para @${bot_name:-seu_bot} (confira o @)."
    warn "  2. Voce apertou enter antes de a mensagem chegar — rode de novo."
    warn "  3. Os updates ja foram consumidos por outra leitura (getUpdates com"
    warn "     offset, um n8n ligado, ou este comando rodado 2x). Mande uma NOVA"
    warn "     mensagem e rode de novo."
    [ -n "$hook_url" ] && warn "  4. O webhook acima esta capturando tudo."
    return 0
  fi

  echo
  echo "$chats"
  echo
  echo "Grave o valor em $ENV_FILE:"
  echo "    TELEGRAM_CHAT_ID=<o chat_id acima>"
}

do_test() {
  require_chat_id || return 0
  RALPH_PROJECT="${RALPH_PROJECT:-teste-notificacao}"
  RALPH_PHASE_NUM="${RALPH_PHASE_NUM:-1}"
  RALPH_PHASE_TOTAL="${RALPH_PHASE_TOTAL:-1}"
  RALPH_PHASE_TITLE="${RALPH_PHASE_TITLE:-Mensagem de teste}"
  RALPH_ENGINE="${RALPH_ENGINE:-claude}"

  if send_message "$(build_text phase_done "Canal Telegram configurado.")"; then
    echo "Mensagem de teste enviada."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  load_credentials || return 0

  case "${1:-}" in
    --setup) do_setup; return 0 ;;
    --test)  do_test;  return 0 ;;
    "")      warn "Evento ausente. Uso: $0 <evento> <mensagem>"; return 0 ;;
  esac

  require_chat_id || return 0

  local event="$1" message="${2:-}"
  send_message "$(build_text "$event" "$message")" || true
  return 0
}

main "$@"
exit 0
