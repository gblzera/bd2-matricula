#!/usr/bin/env bash
# Monta entrega_marco1.sql: os scripts do Marco 1 num arquivo só.
#
# O professor pediu no Classroom que "o SQL deve ser executado em única vez".
# O repositório continua com os scripts numerados (exigência 4.3 do enunciado);
# este arquivo é a mesma coisa concatenada, para rodar numa só execução.
# Gerado, nunca editado à mão — senão diverge da fonte.
set -euo pipefail
cd "$(dirname "$0")/.."

SAIDA=entrega_marco1.sql
PARTES=(sql/01_ddl.sql sql/02_carga.sql sql/02b_geografia_ibge.sql sql/03_consultas.sql)

{
  echo "-- ============================================================================"
  echo "-- entrega_marco1.sql — Marco 1 completo, para executar DE UMA VEZ SÓ."
  echo "-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica"
  echo "--"
  echo "-- ARQUIVO GERADO por scripts/gerar_entrega.sh — não editar à mão."
  echo "-- É a concatenação, na ordem de execução, de:"
  printf -- "--   %s\n" "${PARTES[@]}"
  echo "--"
  echo "-- Como rodar (cria o banco do zero; o script recria o schema sozinho):"
  echo "--   createdb matricula"
  echo "--   psql -v ON_ERROR_STOP=1 -d matricula -f entrega_marco1.sql"
  echo "--"
  echo "-- O que ele faz, nesta ordem: cria as 41 tabelas com as restrições; carrega"
  echo "-- 120 alunos, 34 turmas e 796 matrículas (mínimos do enunciado: 100/6/300),"
  echo "-- mais a geografia do IBGE; e roda as 10 consultas comentadas, entre elas as"
  echo "-- 5 obrigatórias — junção externa com agregação (C3), as duas recursivas"
  echo "-- (C5 e C6), ranking com percentil (C7) e LAG (C8)."
  echo "--"
  echo "-- Gerado em $(date +%Y-%m-%d) a partir do commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')."
  echo "-- ============================================================================"
  echo ""
  for p in "${PARTES[@]}"; do
    echo ""
    echo "-- ############################################################################"
    echo "-- ### $p"
    echo "-- ############################################################################"
    echo ""
    cat "$p"
  done
} > "$SAIDA"

echo "$SAIDA: $(wc -l < "$SAIDA") linhas, a partir de ${#PARTES[@]} scripts"
