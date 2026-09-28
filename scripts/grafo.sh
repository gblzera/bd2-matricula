#!/usr/bin/env bash
# Grafo de conhecimento do projeto, com o Graphify.
#
# O que ele responde que o draw.io NÃO responde: impacto. "Quem lê a tabela
# matricula?" atravessa scripts, views e funções do banco de uma vez —
# enquanto o diagrama mostra a estrutura, não quem depende de quem no código.
#
#   ./scripts/grafo.sh                      constrói/atualiza o grafo
#   ./scripts/grafo.sh afeta matricula      quem depende de matricula
#   ./scripts/grafo.sh explica turma        vizinhança de um nó
#   ./scripts/grafo.sh hubs                 nós mais conectados
#
# Tudo local: extração por AST (tree-sitter) e introspecção do PostgreSQL,
# sem chamada de LLM — por isso o --code-only e o --no-label. A saída vai
# para graphify-out/, que está no .gitignore: é derivado, não fonte.
#
# LIMITE CONHECIDO, para não confundir com o modelo lógico: a introspecção do
# Postgres mapeia tabelas, views, funções e FKs, mas NÃO traz coluna. Para
# coluna, tipo e cardinalidade, o diagrama é docs/modelo-tabelas.drawio.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=".graphify-venv"
PY="${PYTHON_GRAPHIFY:-/opt/homebrew/bin/python3.12}"
DSN="${DATABASE_URL:-postgresql://bd2:bd2@localhost:5432/matricula}"
GRAFO="graphify-out/graph.json"

if [ ! -x "$VENV/bin/graphify" ]; then
  command -v "$PY" >/dev/null || { echo "Python >=3.10 não encontrado. Defina PYTHON_GRAPHIFY."; exit 1; }
  echo "Criando $VENV (primeira vez)…"
  "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check "graphifyy[sql,postgres]"
fi
G="$VENV/bin/graphify"

case "${1:-construir}" in
  construir)
    "$G" extract . --code-only --out . --postgres "$DSN"
    "$G" cluster-only . --no-label
    echo ""
    echo "Pronto: graphify-out/GRAPH_REPORT.md e graphify-out/graph.html"
    ;;
  afeta)   "$G" affected "${2:?uso: grafo.sh afeta <tabela>}" \
             --relation references --relation reads_from --depth "${3:-2}" --graph "$GRAFO" ;;
  explica) "$G" explain  "${2:?uso: grafo.sh explica <nó>}" --graph "$GRAFO" ;;
  hubs)    "$G" god-nodes --top "${2:-15}" --graph "$GRAFO" ;;
  *) echo "uso: $0 [construir|afeta <tabela>|explica <nó>|hubs [n]]"; exit 1 ;;
esac
