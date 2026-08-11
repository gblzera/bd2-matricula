-- ============================================================================
-- 03_consultas.sql — Marco 1 · 10 consultas de complexidade crescente
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Obrigatórias do enunciado e onde estão:
--   · junção externa com agregação ................. consulta 3
--   · recursiva: árvore de pré-requisitos .......... consulta 5
--   · recursiva: disciplinas que o aluno pode cursar consulta 6
--   · janela: ranking e percentil .................. consulta 7
--   · janela: LAG para evolução do rendimento ...... consulta 8
--
-- Todas são autossuficientes (não dependem de ids fixos: alvos são escolhidos
-- por subconsulta) e rodam na carga do 02_carga.sql.
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/03_consultas.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- ============================================================================
-- CONSULTA 1 — Alunos por curso e campus (aquecimento)
-- Técnica: junções internas + agregação com FILTER (contagem condicional
-- sem precisar de duas subconsultas).
-- Leitura: distribuição de alunos ativos/inativos por curso.
-- ============================================================================
\echo '=== C1: alunos por curso e campus ==='
SELECT cp.nome                                   AS campus,
       c.codigo                                  AS curso,
       c.nome                                    AS nome_curso,
       count(a.id) FILTER (WHERE a.ativo)        AS ativos,
       count(a.id) FILTER (WHERE NOT a.ativo)    AS inativos,
       count(a.id)                               AS total
FROM curso c
JOIN campus cp     ON cp.id = c.campus_id
LEFT JOIN aluno a  ON a.curso_id = c.id
GROUP BY cp.nome, c.id
ORDER BY cp.nome, total DESC;

-- ============================================================================
-- CONSULTA 2 — Grade horária semanal de um aluno em 2026/2
-- Técnica: cadeia de 8 junções + uso do tipo range (lower/upper da faixa).
-- O aluno-alvo é escolhido dinamicamente: o mais matriculado do semestre.
-- Leitura: a agenda real do aluno, dia a dia, com sala e campus.
-- ============================================================================
\echo '=== C2: grade horária do aluno mais matriculado de 2026/2 ==='
WITH alvo AS (
  SELECT m.aluno_id
  FROM matricula m
  JOIN turma t           ON t.id = m.turma_id
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
  WHERE pl.ano = 2026 AND pl.semestre = 2 AND m.status = 'confirmada'
  GROUP BY m.aluno_id
  ORDER BY count(*) DESC, m.aluno_id
  LIMIT 1
)
SELECT a.nome                                                    AS aluno,
       (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.dia_semana] AS dia,
       left(lower(th.faixa)::text, 5) || '–' ||
       left(upper(th.faixa)::text, 5)                            AS horario,
       d.codigo                                                  AS disciplina,
       t.codigo                                                  AS turma,
       s.codigo                                                  AS sala,
       cp.nome                                                   AS campus,
       p.nome                                                    AS professor
FROM alvo
JOIN aluno a           ON a.id = alvo.aluno_id
JOIN matricula m       ON m.aluno_id = a.id AND m.status = 'confirmada'
JOIN turma t           ON t.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                      AND pl.ano = 2026 AND pl.semestre = 2
JOIN disciplina d      ON d.id = t.disciplina_id
JOIN professor p       ON p.id = t.professor_id
JOIN turma_horario th  ON th.turma_id = t.id
JOIN sala s            ON s.id = th.sala_id
JOIN campus cp         ON cp.id = s.campus_id
ORDER BY th.dia_semana, lower(th.faixa);

-- ============================================================================
-- CONSULTA 3 — Ocupação de TODAS as turmas de 2026/2         [OBRIGATÓRIA:
-- junção externa com agregação]
-- Técnica: LEFT JOIN turma→matricula. A turma COMP1-N1 não tem nenhuma
-- matrícula e SÓ aparece por causa da junção externa (com INNER JOIN ela
-- sumiria do relatório — teste trocar e comparar).
-- Leitura: painel de vagas para a secretaria; base da view de oferta (Marco 2).
-- ============================================================================
\echo '=== C3: ocupação das turmas 2026/2 (junção externa + agregação) ==='
SELECT t.codigo                                                   AS turma,
       d.nome                                                     AS disciplina,
       t.turno,
       t.vagas,
       count(m.id) FILTER (WHERE m.status = 'confirmada')         AS confirmadas,
       count(m.id) FILTER (WHERE m.status = 'trancada')           AS trancadas,
       t.vagas - count(m.id) FILTER (WHERE m.status = 'confirmada') AS vagas_livres,
       round(100.0 * count(m.id) FILTER (WHERE m.status = 'confirmada')
             / NULLIF(t.vagas, 0), 1)                             AS ocupacao_pct
FROM turma t
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                      AND pl.ano = 2026 AND pl.semestre = 2
JOIN disciplina d      ON d.id = t.disciplina_id
LEFT JOIN matricula m  ON m.turma_id = t.id
GROUP BY t.id, d.nome
ORDER BY ocupacao_pct DESC NULLS LAST, t.codigo;

-- ============================================================================
-- CONSULTA 4 — Desempenho histórico por disciplina (períodos encerrados)
-- Técnica: agregação com FILTER sobre múltiplas condições + HAVING para
-- descartar amostras pequenas + comparação de tupla (ano, semestre) < (2026,2).
-- Leitura: quais disciplinas mais reprovam — insumo direto para a consulta 10.
-- ============================================================================
\echo '=== C4: desempenho por disciplina (períodos encerrados) ==='
SELECT d.codigo,
       d.nome,
       count(h.id)                                               AS avaliacoes,
       round(avg(h.media_final), 2)                              AS media_geral,
       count(*) FILTER (WHERE h.situacao = 'aprovado')           AS aprovados,
       count(*) FILTER (WHERE h.situacao = 'reprovado_nota')     AS rep_nota,
       count(*) FILTER (WHERE h.situacao = 'reprovado_frequencia') AS rep_freq,
       round(100.0 * count(*) FILTER (WHERE h.situacao = 'aprovado')
             / count(*), 1)                                      AS aprovacao_pct
FROM disciplina d
JOIN turma t           ON t.disciplina_id = d.id
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                      AND (pl.ano, pl.semestre) < (2026, 2)
JOIN matricula m       ON m.turma_id = t.id
JOIN historico h       ON h.matricula_id = m.id
                      AND h.situacao IN ('aprovado', 'reprovado_nota', 'reprovado_frequencia')
GROUP BY d.id
HAVING count(h.id) >= 10
ORDER BY aprovacao_pct, d.codigo;

-- ============================================================================
-- CONSULTA 5 — Árvore COMPLETA de pré-requisitos de TABD      [OBRIGATÓRIA:
-- consulta recursiva — árvore de pré-requisitos]
-- Técnica: WITH RECURSIVE descendo a cadeia disciplina→requisito.
--   · caminho (array de ids) serve para (a) ordenar a árvore e (b) PROTEGER
--     CONTRA CICLOS — a constraint [C7] só barra o autociclo A→A; ciclos
--     A→B→A não são expressáveis em constraint, e esta consulta é a
--     ferramenta de auditoria para detectá-los.
--   · a indentação com repeat() torna a hierarquia visível no terminal.
-- Leitura: tudo que é preciso cursar (transitivamente) antes de TABD.
-- ============================================================================
\echo '=== C5: árvore de pré-requisitos de TABD (recursiva) ==='
WITH RECURSIVE arvore (node_id, nivel, caminho, vinculo) AS (
  -- âncora: a própria disciplina-alvo
  SELECT d.id, 0, ARRAY[d.id], NULL::vinculo_t
  FROM disciplina d
  WHERE d.codigo = 'TABD'
  UNION ALL
  -- passo: para cada nó, busca seus requisitos diretos
  SELECT p.requisito_id, a.nivel + 1, a.caminho || p.requisito_id, p.vinculo
  FROM arvore a
  JOIN pre_requisito p ON p.disciplina_id = a.node_id
  WHERE NOT p.requisito_id = ANY (a.caminho)      -- proteção contra ciclos
)
SELECT repeat('    ', a.nivel) || d.codigo AS arvore,
       d.nome,
       a.nivel,
       coalesce(a.vinculo::text, '(alvo)') AS vinculo
FROM arvore a
JOIN disciplina d ON d.id = a.node_id
ORDER BY a.caminho;

-- ============================================================================
--- CONSULTA 6 — Disciplinas que um aluno JÁ PODE cursar (e projeção da cadeia)
-- [OBRIGATÓRIA: consulta recursiva — disciplinas que o aluno já pode cursar]
-- Técnica: recursão por NÍVEIS carregando um ARRAY acumulado.
--   · nível 0 = disciplinas já aprovadas pelo aluno;
--   · nível 1 = PODE CURSAR JÁ: todos os pré-requisitos estão no conjunto;
--   · nível n = destrava após cursar o nível n-1 (projeção de futuro).
--   Por que o array? O PostgreSQL proíbe referenciar o CTE recursivo em
--   subconsulta/agregação dentro do passo recursivo; carregar o conjunto
--   acumulado como array na própria linha contorna isso de forma elegante.
--   Co-requisitos (vinculo <> 'pre_requisito') não bloqueiam a liberação.
-- Leitura: o "plano de matrícula" possível do aluno, semestre a semestre.
-- ============================================================================
\echo '=== C6: disciplinas liberadas para o aluno com mais aprovações (recursiva) ==='
WITH RECURSIVE
alvo AS (                               -- aluno com mais disciplinas aprovadas
  SELECT m.aluno_id AS id, a.curriculo_id, a.nome
  FROM matricula m
  JOIN historico h ON h.matricula_id = m.id AND h.situacao = 'aprovado'
  JOIN aluno a     ON a.id = m.aluno_id
  GROUP BY m.aluno_id, a.curriculo_id, a.nome
  ORDER BY count(*) DESC, m.aluno_id
  LIMIT 1
),
aprovadas AS (                          -- conjunto-base: o que ele já aprovou
  SELECT DISTINCT t.disciplina_id
  FROM matricula m
  JOIN turma t     ON t.id = m.turma_id
  JOIN historico h ON h.matricula_id = m.id
  WHERE m.aluno_id = (SELECT id FROM alvo) AND h.situacao = 'aprovado'
),
expansao (nivel, feitas, novas) AS (
  SELECT 0,
         ARRAY(SELECT disciplina_id FROM aprovadas ORDER BY 1),
         ARRAY(SELECT disciplina_id FROM aprovadas ORDER BY 1)
  UNION ALL
  SELECT e.nivel + 1, e.feitas || x.novas, x.novas
  FROM expansao e
  CROSS JOIN LATERAL (
    SELECT ARRAY(
      SELECT cd.disciplina_id
      FROM curriculo_disciplina cd
      WHERE cd.curriculo_id = (SELECT curriculo_id FROM alvo)
        AND cd.disciplina_id <> ALL (e.feitas)          -- ainda não feita
        AND NOT EXISTS (                                -- nenhum pré-req pendente
              SELECT 1
              FROM pre_requisito p
              WHERE p.disciplina_id = cd.disciplina_id
                AND p.vinculo = 'pre_requisito'
                AND NOT (p.requisito_id = ANY (e.feitas)))
      ORDER BY cd.disciplina_id
    ) AS novas
  ) x
  WHERE cardinality(x.novas) > 0 AND e.nivel < 12       -- término garantido
)
SELECT (SELECT nome FROM alvo)               AS aluno,
       e.nivel                               AS onda,
       CASE e.nivel WHEN 1 THEN 'PODE CURSAR JÁ'
                    ELSE 'destrava na onda ' || e.nivel END AS quando,
       d.codigo,
       d.nome,
       cd.periodo                            AS periodo_sugerido,
       cd.tipo
FROM expansao e
CROSS JOIN LATERAL unnest(e.novas) AS n(disciplina_id)
JOIN disciplina d            ON d.id = n.disciplina_id
JOIN curriculo_disciplina cd ON cd.disciplina_id = d.id
                            AND cd.curriculo_id = (SELECT curriculo_id FROM alvo)
WHERE e.nivel >= 1
ORDER BY e.nivel, d.codigo;

-- ============================================================================
-- CONSULTA 7 — Ranking de rendimento com percentil por curso   [OBRIGATÓRIA:
-- função de janela com ranking e percentil]
-- Técnica: CR ponderado pela carga horária (média ponderada, não simples) e
-- três janelas PARTITION BY curso: RANK (posição, com empates), PERCENT_RANK
-- (percentil 0–100: "está à frente de X% dos colegas do curso") e NTILE(4)
-- (quartil). HAVING >= 3 disciplinas para o ranking ser justo.
-- Leitura: os melhores alunos de cada curso, comparáveis dentro do curso.
-- ============================================================================
\echo '=== C7: ranking + percentil de rendimento por curso (janela) ==='
WITH rendimento AS (
  SELECT a.id, a.matricula, a.nome, c.codigo AS curso,
         round(sum(h.media_final * d.ch_total) / sum(d.ch_total), 2) AS cr,
         count(*) AS disciplinas_avaliadas
  FROM aluno a
  JOIN curso c     ON c.id = a.curso_id
  JOIN matricula m ON m.aluno_id = a.id
  JOIN turma t     ON t.id = m.turma_id
  JOIN disciplina d ON d.id = t.disciplina_id
  JOIN historico h ON h.matricula_id = m.id AND h.media_final IS NOT NULL
  GROUP BY a.id, c.codigo
  HAVING count(*) >= 3
)
SELECT curso, matricula, nome, cr, disciplinas_avaliadas,   -- matrícula desambigua homônimos
       rank()         OVER (PARTITION BY curso ORDER BY cr DESC)      AS posicao,
       round((percent_rank() OVER (PARTITION BY curso ORDER BY cr))::numeric
             * 100, 1)                                                AS percentil,
       ntile(4)       OVER (PARTITION BY curso ORDER BY cr DESC)      AS quartil
FROM rendimento
ORDER BY curso, posicao
LIMIT 30;

-- ============================================================================
-- CONSULTA 8 — Evolução do rendimento período a período        [OBRIGATÓRIA:
-- função de janela com LAG]
-- Técnica: média por aluno×período; LAG traz a média do período ANTERIOR na
-- mesma linha (janela nomeada com WINDOW), permitindo delta e tendência.
-- Mostra alunos com >= 3 períodos avaliados (CTE reutilizada no filtro).
-- Leitura: quem está melhorando, quem está caindo — e quanto.
-- ============================================================================
\echo '=== C8: evolução do rendimento com LAG (janela) ==='
WITH medias AS (
  SELECT m.aluno_id,
         pl.ano, pl.semestre,
         pl.ano || '/' || pl.semestre       AS periodo,
         round(avg(h.media_final), 2)       AS media_periodo
  FROM matricula m
  JOIN turma t           ON t.id = m.turma_id
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
  JOIN historico h       ON h.matricula_id = m.id AND h.media_final IS NOT NULL
  GROUP BY m.aluno_id, pl.ano, pl.semestre
)
SELECT a.matricula,                    -- desambigua homônimos (nomes se repetem na carga)
       a.nome,
       md.periodo,
       md.media_periodo,
       lag(md.media_periodo) OVER w                          AS media_anterior,
       round(md.media_periodo - lag(md.media_periodo) OVER w, 2) AS variacao,
       CASE
         WHEN lag(md.media_periodo) OVER w IS NULL                 THEN '· primeiro período'
         WHEN md.media_periodo - lag(md.media_periodo) OVER w >  0.5 THEN '▲ melhora'
         WHEN md.media_periodo - lag(md.media_periodo) OVER w < -0.5 THEN '▼ queda'
         ELSE '≈ estável'
       END AS tendencia
FROM medias md
JOIN aluno a ON a.id = md.aluno_id
WHERE md.aluno_id IN (SELECT aluno_id FROM medias GROUP BY aluno_id HAVING count(*) >= 3)
WINDOW w AS (PARTITION BY md.aluno_id ORDER BY md.ano, md.semestre)
ORDER BY a.nome, a.matricula, md.ano, md.semestre
LIMIT 40;

-- ============================================================================
-- CONSULTA 9 — Choques de horário nas matrículas de 2026/2
-- Técnica: autojunção de matrícula (m2.turma_id > m1.turma_id evita pares
-- duplicados) + sobreposição de ranges com && sobre o tipo criado em [C1],
-- agregada por PAR de turmas em conflito (visão executiva; para a lista
-- nominal, basta trocar o GROUP BY pelos alunos).
-- Ponto de análise crítica: a restrição de exclusão [C10] protege a SALA;
-- o choque de horário do ALUNO é regra de negócio que constraint não alcança
-- (atravessa 3 tabelas) — esta consulta o detecta, e o tratamento definitivo
-- entra na transação de matrícula do Marco 2.
-- Leitura: pares de turmas sobrepostas e quantos alunos são afetados por cada um.
-- ============================================================================
\echo '=== C9: choques de horário de alunos em 2026/2 (range && + agregação) ==='
SELECT (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[h1.dia_semana] AS dia,
       t1.codigo || ' (' || left(lower(h1.faixa)::text, 5) || '–'
                 || left(upper(h1.faixa)::text, 5) || ')' AS turma_a,
       t2.codigo || ' (' || left(lower(h2.faixa)::text, 5) || '–'
                 || left(upper(h2.faixa)::text, 5) || ')' AS turma_b,
       count(DISTINCT m1.aluno_id)                        AS alunos_afetados
FROM matricula m1
JOIN matricula m2      ON m2.aluno_id = m1.aluno_id
                      AND m2.turma_id > m1.turma_id
                      AND m1.status = 'confirmada' AND m2.status = 'confirmada'
JOIN turma t1          ON t1.id = m1.turma_id
JOIN turma t2          ON t2.id = m2.turma_id
                      AND t2.periodo_letivo_id = t1.periodo_letivo_id
JOIN periodo_letivo pl ON pl.id = t1.periodo_letivo_id
                      AND pl.ano = 2026 AND pl.semestre = 2
JOIN turma_horario h1  ON h1.turma_id = t1.id
JOIN turma_horario h2  ON h2.turma_id = t2.id
                      AND h2.dia_semana = h1.dia_semana
                      AND h1.faixa && h2.faixa          -- sobreposição de ranges
GROUP BY h1.dia_semana, t1.codigo, h1.faixa, t2.codigo, h2.faixa
ORDER BY alunos_afetados DESC, dia, turma_a;

-- ============================================================================
-- CONSULTA 10 — Disciplinas-gargalo do currículo (painel executivo)
-- Técnica: combina TUDO — (a) CTE recursiva calcula o fecho transitivo
-- INVERSO dos pré-requisitos (quantas disciplinas cada uma destrava, direta
-- ou indiretamente; UNION sem ALL deduplica e encerra mesmo com diamantes);
-- (b) agregação calcula a taxa de reprovação histórica; (c) janela DENSE_RANK
-- ordena a criticidade = destravadas × taxa de reprovação.
-- Leitura: reprovar nelas atrasa o curso inteiro — prioridade de monitoria.
-- ============================================================================
\echo '=== C10: disciplinas-gargalo (recursiva + agregação + janela) ==='
WITH RECURSIVE dependentes AS (
  SELECT p.requisito_id AS base_id, p.disciplina_id AS dependente_id
  FROM pre_requisito p
  WHERE p.vinculo = 'pre_requisito'
  UNION                                       -- sem ALL: deduplica diamantes
  SELECT dep.base_id, p.disciplina_id
  FROM dependentes dep
  JOIN pre_requisito p ON p.requisito_id = dep.dependente_id
                      AND p.vinculo = 'pre_requisito'
),
destravas AS (
  SELECT base_id, count(DISTINCT dependente_id) AS destrava
  FROM dependentes
  GROUP BY base_id
),
reprovacao AS (
  SELECT t.disciplina_id,
         count(*)                                                    AS avaliacoes,
         round(100.0 * count(*) FILTER (WHERE h.situacao IN
               ('reprovado_nota', 'reprovado_frequencia')) / count(*), 1) AS reprovacao_pct
  FROM turma t
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                        AND (pl.ano, pl.semestre) < (2026, 2)
  JOIN matricula m       ON m.turma_id = t.id
  JOIN historico h       ON h.matricula_id = m.id
                        AND h.situacao IN ('aprovado', 'reprovado_nota', 'reprovado_frequencia')
  GROUP BY t.disciplina_id
)
SELECT d.codigo,
       d.nome,
       coalesce(ds.destrava, 0)                            AS disciplinas_que_destrava,
       r.avaliacoes,
       r.reprovacao_pct,
       round(coalesce(ds.destrava, 0) * r.reprovacao_pct / 100.0, 2) AS indice_criticidade,
       dense_rank() OVER (ORDER BY coalesce(ds.destrava, 0) * r.reprovacao_pct DESC) AS prioridade
FROM reprovacao r
JOIN disciplina d    ON d.id = r.disciplina_id
LEFT JOIN destravas ds ON ds.base_id = d.id
ORDER BY prioridade, d.codigo
LIMIT 15;
