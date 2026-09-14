#!/usr/bin/env bash
# =============================================================================
# Exporta os diagramas .drawio de docs/ em alta resolução (PNG escala 3) e em
# SVG (vetorial — zoom infinito, abre em qualquer navegador). Divide a página 1
# do modelo principal em duas metades para slides/impressão.
#
# O ENTREGÁVEL é o próprio .drawio (vetorial, sempre nítido no draw.io);
# estes exports são para embutir em documentos/slides sem perder qualidade.
#
# Requer o draw.io desktop:  brew install --cask drawio
# Rodar sempre que um .drawio mudar. Uso: ./scripts/exportar_diagramas.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DRAWIO="/Applications/draw.io.app/Contents/MacOS/draw.io"
[ -x "$DRAWIO" ] || { echo "draw.io desktop não encontrado — brew install --cask drawio"; exit 1; }

exportar() {                       # exportar <arquivo.drawio> <prefixo-saida>
  local arq="$1" pre="$2"
  local paginas
  paginas=$(grep -c '<diagram' "$arq")
  for ((p=1; p<=paginas; p++)); do
    "$DRAWIO" --export --format png --scale 3 --page-index $p \
      --output "${pre}-p${p}.png" "$arq" >/dev/null 2>&1
    "$DRAWIO" --export --format svg --page-index $p \
      --output "${pre}-p${p}.svg" "$arq" >/dev/null 2>&1
    echo "$arq página $p → ${pre}-p${p}.{png,svg}"
  done
}

exportar docs/modelo-tabelas.drawio docs/modelo-tabelas   # oficial (português)
exportar docs/modelo-college.drawio docs/modelo-college   # derivado (inglês)

# Divide a página 1 do modelo principal (muito larga) em duas metades
W=$(sips -g pixelWidth  docs/modelo-tabelas-p1.png | awk 'END{print $2}')
H=$(sips -g pixelHeight docs/modelo-tabelas-p1.png | awk 'END{print $2}')
sips -c "$H" $((W/2+150)) --cropOffset 0 0            docs/modelo-tabelas-p1.png --out docs/modelo-tabelas-p1-esquerda.png >/dev/null
sips -c "$H" $((W/2+150)) --cropOffset 0 $((W/2-150)) docs/modelo-tabelas-p1.png --out docs/modelo-tabelas-p1-direita.png  >/dev/null
echo "página 1 do modelo principal dividida em esquerda/direita (${W}x${H} px)"
