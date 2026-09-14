#!/usr/bin/env bash
# =============================================================================
# Exporta docs/modelo-tabelas.drawio em alta resolução (PNG escala 3) e em SVG
# (vetorial — zoom infinito, abre em qualquer navegador). Também divide a
# página 1 em duas metades para slides/impressão.
#
# Requer o draw.io desktop:  brew install --cask drawio
# Rodar sempre que o .drawio mudar. Uso: ./scripts/exportar_diagramas.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DRAWIO="/Applications/draw.io.app/Contents/MacOS/draw.io"
[ -x "$DRAWIO" ] || { echo "draw.io desktop não encontrado — brew install --cask drawio"; exit 1; }

for p in 1 2; do
  "$DRAWIO" --export --format png --scale 3 --page-index $p \
    --output "docs/modelo-tabelas-p$p.png" docs/modelo-tabelas.drawio >/dev/null 2>&1
  "$DRAWIO" --export --format svg --page-index $p \
    --output "docs/modelo-tabelas-p$p.svg" docs/modelo-tabelas.drawio >/dev/null 2>&1
  echo "página $p exportada (png escala 3 + svg)"
done

# Divide a página 1 (muito larga) em duas metades com 150px de sobreposição
W=$(sips -g pixelWidth  docs/modelo-tabelas-p1.png | awk 'END{print $2}')
H=$(sips -g pixelHeight docs/modelo-tabelas-p1.png | awk 'END{print $2}')
sips -c "$H" $((W/2+150)) --cropOffset 0 0            docs/modelo-tabelas-p1.png --out docs/modelo-tabelas-p1-esquerda.png >/dev/null
sips -c "$H" $((W/2+150)) --cropOffset 0 $((W/2-150)) docs/modelo-tabelas-p1.png --out docs/modelo-tabelas-p1-direita.png  >/dev/null
echo "página 1 dividida em esquerda/direita (${W}x${H} px no total)"
