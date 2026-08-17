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
#   $1  evento: phase_done | phase_failed | limit_hit | limit_over
#               | limit_abort | run_done
#   $2  mensagem ja formatada pelo ralph.sh
#
# Contexto lido do ambiente exportado pelo ralph.sh:
#   RALPH_PROJECT RALPH_ENGINE RALPH_PHASE_NUM RALPH_PHASE_TOTAL
#   RALPH_PHASE_TITLE RALPH_EVENT
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
      # shellcheck disable=SC1090
      set +u; . "$ENV_FILE"; set -u
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

# Monta o corpo da mensagem. Rodando varios projetos em paralelo, o nome do
# projeto e a primeira coisa que precisa ser legivel na notificacao do celular.
build_text() {
  local event="$1" message="$2"
  local icon project phase_line engine

  icon=$(event_icon "$event")
  project=$(html_escape "${RALPH_PROJECT:-projeto}")
  engine=$(html_escape "${RALPH_ENGINE:-}")

  printf '%s <b>%s</b>\n' "$icon" "$project"

  # Eventos de run, nao de fase. run_done ainda carrega RALPH_PHASE_* da ultima
  # fase, e run_start pode herda-los do ambiente do shell que chamou o ralph —
  # exibi-los daria a impressao de um evento de fase.
  if [ "$event" != "run_done" ] && [ "$event" != "run_start" ] \
    && [ -n "${RALPH_PHASE_NUM:-}" ]; then
    phase_line="Fase ${RALPH_PHASE_NUM}"
    [ -n "${RALPH_PHASE_TOTAL:-}" ] && phase_line="${phase_line}/${RALPH_PHASE_TOTAL}"
    [ -n "${RALPH_PHASE_TITLE:-}" ] && phase_line="${phase_line} — ${RALPH_PHASE_TITLE}"
    printf '<i>%s</i>\n' "$(html_escape "$phase_line")"
  fi

  printf '\n%s\n' "$(html_escape "$message")"

  [ -n "$engine" ] && printf '\n<code>engine: %s | %s</code>\n' \
    "$engine" "$(date '+%d/%m %H:%M')"
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
