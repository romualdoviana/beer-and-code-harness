#!/usr/bin/env bash
#
# ralph-watch.sh
#
# Painel de acompanhamento do ralph.sh, num segundo terminal.
#
# Nao tem renderizador proprio: mostra o MESMO painel do run (mesmas telas,
# regioes, textos, cores, mouse e teclas), desenhado pelo proprio ralph.sh a
# partir do estado que ele escreve em .phases/. Assim o watch nunca diverge do
# painel do run.
#
#   - modo ao vivo: vira `ralph.sh --attach` no repo (q sai sem tocar no run)
#   - --once: carrega o ralph.sh como biblioteca (RALPH_LIB_ONLY=1), desenha
#     UM frame com ui_frame e sai, sem escrever nada em .phases/
#
# Uso:
#   ./ralph-watch.sh [opcoes] [caminho-do-repo]
#
# Opcoes:
#   --once              desenha um frame e sai (util em script/teste)
#   --interval N        segundos entre republicacoes do attach (default: 3)
#   --no-color          remove o ANSI do frame do --once
#   --color             mantem o ANSI do --once mesmo sem terminal (teste)
#
# Variaveis de ambiente:
#   RALPH_BIN          caminho do ralph.sh (default: o irmao deste arquivo)
#   RALPH_WATCH_COLS   fixa a largura do --once (teste, pipe)
#   RALPH_WATCH_LINES  fixa a altura do --once

set -uo pipefail

REPO="."
ONCE=false
INTERVAL=""
USE_COLOR=true
FORCE_COLOR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)       ONCE=true; shift ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --interval=*) INTERVAL="${1#*=}"; shift ;;
    --no-color)   USE_COLOR=false; shift ;;
    --color)      FORCE_COLOR=true; shift ;;
    -h|--help)    sed -n '2,29p' "$0"; exit 0 ;;
    *)            REPO="$1"; shift ;;
  esac
done

# --color mantem o ANSI quando a saida nao e um terminal (teste, arquivo).
$FORCE_COLOR || [ -t 1 ] || USE_COLOR=false

RALPH_SH="${RALPH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph.sh}"
if [ ! -f "$RALPH_SH" ]; then
  echo "ralph-watch: ralph.sh nao encontrado em $RALPH_SH (defina RALPH_BIN)." >&2
  exit 1
fi
RALPH_SH="$(cd "$(dirname "$RALPH_SH")" && pwd)/$(basename "$RALPH_SH")"

if ! cd "$REPO" 2> /dev/null; then
  echo "ralph-watch: repo inexistente: $REPO" >&2
  exit 1
fi

if ! $ONCE; then
  [ -n "$INTERVAL" ] && export RALPH_ATTACH_INTERVAL="$INTERVAL"
  exec bash "$RALPH_SH" --attach
fi

if [ ! -f .phases/ui/state.env ]; then
  echo "Nenhum estado em .phases/ui/state.env — o ralph ja rodou neste repo?" >&2
  exit 1
fi

# O ralph.sh parseia "$@" ao carregar: argumentos do watch virariam o documento
# de entrada dele. Carrega com a lista vazia.
set --
# shellcheck source=/dev/null
RALPH_LIB_ONLY=1 source "$RALPH_SH" > /dev/null 2>&1 || {
  echo "ralph-watch: falha ao carregar $RALPH_SH" >&2
  exit 1
}
set +eu

# Chamadas pelo ui_frame do ralph.sh carregado acima.
# shellcheck disable=SC2317,SC2329
if [ -n "${RALPH_WATCH_COLS:-}" ]; then
  ui_term_cols() { echo "$RALPH_WATCH_COLS"; }
fi
# shellcheck disable=SC2317,SC2329
if [ -n "${RALPH_WATCH_LINES:-}" ]; then
  ui_term_lines() { echo "$RALPH_WATCH_LINES"; }
fi

# Leitor puro: o mapa de cliques e a janela das listas que o ui_frame grava vao
# para um diretorio descartavel, nunca para .phases/.
WATCH_TMP="$(mktemp -d)"
trap 'rm -rf "$WATCH_TMP"' EXIT
# shellcheck disable=SC2034  # lidas pelo ui_frame do ralph.sh
UI_HITMAP="$WATCH_TMP/.hitmap"
# shellcheck disable=SC2034
UI_VIEWPORT="$WATCH_TMP/.viewport"

frame="$(ui_frame 0 2> /dev/null)"
if $USE_COLOR; then
  printf '%s\n' "$frame"
else
  printf '%s\n' "$frame" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'
fi
exit 0
