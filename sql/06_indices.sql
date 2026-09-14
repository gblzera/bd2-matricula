-- ============================================================================
-- 06_indices.sql — Marco 2 · Índices com evidência EXPLAIN (ANALYZE, BUFFERS)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Exigência: >= 4 índices, incluindo ao menos 1 PARCIAL, com EXPLAIN antes e
-- depois de cada um. ESTE SCRIPT É O GERADOR DE EVIDÊNCIA: para cada índice
-- ele roda a consulta-alvo SEM o índice, cria o índice e roda DE NOVO — o
-- ganho aparece na saída (docs/evidencias/explain-indices.md guarda uma
-- execução comentada). Requer o volume do 05_volume_legado.sql (~33 mil
-- matrículas) para o ganho ser mensurável.
--
-- Índices que JÁ EXISTEM por causa das restrições (análise crítica):
--   · uq_matricula_aluno_turma [C2]  -> atende buscas por id_aluno (coluna líder)
--   · historico_id_matricula_key     -> atende o join 1:1 historico<->matricula
--   · ex_sala_sem_choque (GiST)      -> atende consultas de conflito de sala
--   · uq_matricula_id_turma [E13]    -> alvo das FKs compostas de nota/presenca
-- Por isso os índices abaixo cobrem OUTROS padrões de acesso do sistema.
--
-- O QUE A AMPLIAÇÃO MUDOU AQUI: o índice 3 mudou de casa. Ele indexava
-- historico.media_final_historico, uma coluna GERADA [C13]; com [E14] a média
-- deixou de ser coluna e virou derivação (v_desempenho_matricula). Uma view
-- não aceita índice — por isso a mv_historico_consolidado existe, e é ELA que
-- carrega o índice agora. É o custo da ampliação, pago no lugar certo.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/06_indices.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


DROP INDEX IF EXISTS idx_matricula_turma_confirmada;
DROP INDEX IF EXISTS idx_matricula_data_brin;
DROP INDEX IF EXISTS idx_consolidado_media;
DROP INDEX IF EXISTS idx_log_detalhe_gin;

-- Turma-alvo das medições: a turma legada com mais matrículas
SELECT m.id_turma AS turma_grande
FROM matricula m JOIN turma t ON t.id_turma = m.id_turma
WHERE t.codigo_turma LIKE 'LEG-%'
GROUP BY m.id_turma ORDER BY count(*) DESC, m.id_turma LIMIT 1 \gset
\echo 'Turma-alvo das medições:' :turma_grande

-- ============================================================================
-- ÍNDICE 1 (PARCIAL, exigido) — idx_matricula_turma_confirmada
-- Consulta-alvo: a CONTAGEM DE VAGAS de uma turma — o caminho mais quente do
-- sistema (toda matrícula passa por ela; é a leitura da transação do 07).
-- Por que parcial: a regra do domínio diz que SÓ status='confirmada' consome
-- vaga; o predicado WHERE grava essa regra no próprio índice, que fica menor
-- (não indexa canceladas/trancadas) e casa exatamente com a consulta.
-- ============================================================================
\echo ''
\echo '===== [1] ANTES (sem índice parcial) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
WHERE id_turma = :turma_grande AND status_matricula = 'confirmada';

CREATE INDEX idx_matricula_turma_confirmada
  ON matricula (id_turma)
  WHERE status_matricula = 'confirmada';

\echo '===== [1] DEPOIS (com idx_matricula_turma_confirmada) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
WHERE id_turma = :turma_grande AND status_matricula = 'confirmada';

-- ============================================================================
-- ÍNDICE 2 (BRIN) — idx_matricula_data_brin
-- Consulta-alvo: relatórios por janela de tempo (matrículas de um semestre).
-- Por que BRIN e não B-tree: data_matricula cresce junto com a ordem física
-- de inserção (correlação ~1). O BRIN guarda só o min/max de cada faixa de
-- páginas — ocupa KILOBYTES onde o B-tree ocuparia centenas de KB — e
-- descarta faixas inteiras fora da janela. Trade-off clássico de DW.
-- ============================================================================
\echo ''
\echo '===== [2] ANTES (sem BRIN) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
WHERE data_matricula >= '2022-01-01' AND data_matricula < '2022-04-01';

-- pages_per_range=16: o default (128) criaria só ~3 faixas numa tabela de
-- ~390 páginas — granularidade grossa demais para podar. Com 16, ~25 faixas:
-- poda efetiva mantendo o índice minúsculo.
CREATE INDEX idx_matricula_data_brin
  ON matricula USING brin (data_matricula) WITH (pages_per_range = 16);

\echo '===== [2] DEPOIS (com idx_matricula_data_brin) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM matricula
WHERE data_matricula >= '2022-01-01' AND data_matricula < '2022-04-01';

-- ============================================================================
-- ÍNDICE 3 (B-tree) — idx_consolidado_media
-- Consulta-alvo: cortes por faixa de média (quadro de excelência >= 9,5,
-- alunos em risco < 4) — usados por coordenação e pela mv_indicadores.
-- B-tree clássico: predicado de desigualdade em coluna com boa seletividade
-- nas caudas da distribuição.
--
-- ONDE ELE MORA AGORA [E14]: em mv_historico_consolidado. Antes da ampliação
-- a média era coluna GERADA em historico e o índice ficava lá. Com a média
-- virando derivação de `nota`, o único lugar que aceita índice é a MV — que
-- é exatamente a razão de a MV existir. Repare no contraste: a MESMA consulta
-- direto na derivação (v_desempenho_matricula) NÃO tem como usar índice
-- nenhum, porque agrega ~60 mil notas a cada execução.
-- ============================================================================
\echo ''
\echo '===== [3] ANTES — na derivação (view): agrega nota a cada execução ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM v_desempenho_matricula WHERE media_final >= 9.5;

\echo '===== [3] ANTES — na MV, sem índice ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM mv_historico_consolidado WHERE media_final >= 9.5;

CREATE INDEX idx_consolidado_media
  ON mv_historico_consolidado (media_final);

\echo '===== [3] DEPOIS (com idx_consolidado_media) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM mv_historico_consolidado WHERE media_final >= 9.5;

-- ============================================================================
-- ÍNDICE 4 (GIN sobre JSONB — também é o BÔNUS do enunciado)
-- Consulta-alvo: auditoria por CONTEÚDO do log ("todos os eventos da turma
-- X"), usando o operador de contenção @> sobre jsonb.
-- Por que GIN + jsonb_path_ops: GIN indexa os elementos internos do
-- documento; a opclass jsonb_path_ops indexa só hashes de caminhos
-- (menor e mais rápida que a default), ao custo de suportar apenas @> —
-- exatamente o operador da consulta de auditoria.
-- ============================================================================
\echo ''
\echo '===== [4] ANTES (sem GIN) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM log_matricula WHERE detalhe_log_matricula @> '{"turma": "LEG-BD1-1"}';

CREATE INDEX idx_log_detalhe_gin
  ON log_matricula USING gin (detalhe_log_matricula jsonb_path_ops);

\echo '===== [4] DEPOIS (com idx_log_detalhe_gin) ====='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM log_matricula WHERE detalhe_log_matricula @> '{"turma": "LEG-BD1-1"}';

-- ============================================================================
-- Tamanhos: mostra o trade-off de espaço de cada estratégia
-- ============================================================================
\echo ''
\echo '=== Tamanho dos índices criados ==='
SELECT indexrelid::regclass AS indice,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
FROM pg_stat_user_indexes
WHERE indexrelname IN ('idx_matricula_turma_confirmada', 'idx_matricula_data_brin',
                       'idx_consolidado_media', 'idx_log_detalhe_gin')
ORDER BY pg_relation_size(indexrelid) DESC;
