#!/usr/bin/env bash
# Gera ui/index.html de cada fixture com o MESMO write_dashboard_html do
# ralph.sh (carregado como biblioteca, RALPH_LIB_ONLY=1). Rode de novo sempre
# que o dashboard mudar: as fixtures precisam ficar em sincronia com o heredoc.
#
# Captura: sirva .spec/features/ralph-painel-fiel-artefatos/ em 127.0.0.1 e
# abra /fixtures/<fixture>/ui/#visao-geral|#foco|#diagnostico — a pagina le
# ../state.json e ../events.jsonl da propria fixture.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
ralph="$root/scripts/ralph.sh"

[ -f "$ralph" ] || { echo "build.sh: ralph.sh nao encontrado em $ralph" >&2; exit 1; }

# O ralph.sh le os argumentos de entrada dele: carrega com a lista vazia.
set --
# shellcheck source=/dev/null
RALPH_LIB_ONLY=1 source "$ralph" > /dev/null
set -euo pipefail

n=0
for fixture in 01-visao-geral 02-foco 03-diagnostico 03-diagnostico-ok; do
  dir="$here/$fixture"
  [ -f "$dir/state.json" ] || { echo "build.sh: $dir/state.json ausente" >&2; exit 1; }
  mkdir -p "$dir/ui"
  UI_HTML="$dir/ui/index.html"
  write_dashboard_html
  n=$((n + 1))
  echo "gerado: ${UI_HTML#"$root/"}"
done
echo "$n fixtures geradas."
