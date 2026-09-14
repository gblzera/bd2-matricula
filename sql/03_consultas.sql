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
--
-- O QUE A AMPLIAÇÃO MUDOU AQUI (modelo de 41 tabelas):
--   · o nome do aluno e do professor vêm de `pessoa` [E2] — toda consulta que
--     exibe gente passa a ter mais uma junção, e isso é o preço explícito de
--     não repetir nome/CPF em duas tabelas;
--   · o professor da turma vem de `turma_professor` filtrando o TITULAR [E11];
--   · a sala vem de `predio` [E5] e pode ser NULL (turma EAD) [E12] — por isso
--     LEFT JOIN, não INNER: com INNER a turma EAD sumiria do relatório;
--   · média e frequência não existem mais como coluna: vêm de
--     `v_desempenho_matricula`, derivadas de nota/presenca [E14].
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/03_consultas.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


-- ============================================================================
-- CONSULTA 1 — Alunos por curso e campus (aquecimento)
-- Técnica: junções internas + agregação com FILTER (contagem condicional
-- sem precisar de duas subconsultas).
-- Leitura: distribuição de alunos ativos/inativos por curso.
-- ============================================================================
\echo '=== C1: alunos por curso e campus ==='
SELECT cp.nome_campus                                   AS campus,
       c.codigo_curso                                  AS curso,
       c.nome_curso                                    AS nome_curso,
       count(a.id_aluno) FILTER (WHERE a.status_aluno = 'ativo')     AS ativos,
       count(a.id_aluno) FILTER (WHERE a.status_aluno <> 'ativo')    AS inativos,
       count(a.id_aluno)                               AS total
FROM curso c
JOIN campus cp     ON cp.id_campus = c.id_campus
LEFT JOIN aluno a  ON a.id_curso = c.id_curso
GROUP BY cp.nome_campus, c.id_curso
ORDER BY cp.nome_campus, total DESC;

-- ============================================================================
-- CONSULTA 2 — Grade horária semanal de um aluno em 2026/2
-- Técnica: cadeia de 8 junções + uso do tipo range (lower/upper da faixa).
-- O aluno-alvo é escolhido dinamicamente: o mais matriculado do semestre.
-- Leitura: a agenda real do aluno, dia a dia, com sala e campus.
-- ============================================================================
\echo '=== C2: grade horária do aluno mais matriculado de 2026/2 ==='
WITH alvo AS (
  SELECT m.id_aluno
  FROM matricula m
  JOIN turma t           ON t.id_turma = m.id_turma
  JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
  WHERE pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2 AND m.status_matricula = 'confirmada'
  GROUP BY m.id_aluno
  ORDER BY count(*) DESC, m.id_aluno
  LIMIT 1
)
SELECT pa.nome_pessoa                                                          AS aluno,
       (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.dia_semana_turma_horario] AS dia,
       left(lower(th.faixa_turma_horario)::text, 5) || '–' ||
       left(upper(th.faixa_turma_horario)::text, 5)                            AS horario,
       d.codigo_disciplina                                                     AS disciplina,
       t.codigo_turma                                                          AS turma,
       coalesce(s.codigo_sala, '(EAD)')                                        AS sala,
       coalesce(pr.nome_predio, '—')                                           AS predio,
       coalesce(cp.nome_campus, t.modalidade_turma::text)                      AS campus,
       pp.nome_pessoa                                                          AS professor
FROM alvo
JOIN aluno a           ON a.id_aluno = alvo.id_aluno
JOIN pessoa pa         ON pa.id_pessoa = a.id_pessoa                     -- [E2]
JOIN matricula m       ON m.id_aluno = a.id_aluno AND m.status_matricula = 'confirmada'
JOIN turma t           ON t.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN turma_professor tp ON tp.id_turma = t.id_turma
                      AND tp.papel_turma_professor = 'titular'           -- [E11]
JOIN professor p       ON p.id_professor = tp.id_professor
JOIN pessoa pp         ON pp.id_pessoa = p.id_pessoa                     -- [E2]
JOIN turma_horario th  ON th.id_turma = t.id_turma
LEFT JOIN sala s       ON s.id_sala = th.id_sala                         -- NULL = EAD [E12]
LEFT JOIN predio pr    ON pr.id_predio = s.id_predio                     -- [E5]
LEFT JOIN campus cp    ON cp.id_campus = pr.id_campus
ORDER BY th.dia_semana_turma_horario, lower(th.faixa_turma_horario);

-- ============================================================================
-- CONSULTA 3 — Ocupação de TODAS as turmas de 2026/2         [OBRIGATÓRIA:
-- junção externa com agregação]
-- Técnica: LEFT JOIN turma→matricula. A turma COMP1-N1 não tem nenhuma
-- matrícula e SÓ aparece por causa da junção externa (com INNER JOIN ela
-- sumiria do relatório — teste trocar e comparar).
-- Leitura: painel de vagas_turma para a secretaria; base da view de oferta (Marco 2).
-- ============================================================================
\echo '=== C3: ocupação das turmas 2026/2 (junção externa + agregação) ==='
SELECT t.codigo_turma                                                   AS turma,
       d.nome_disciplina                                                     AS disciplina,
       t.turno_turma,
       t.vagas_turma,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')         AS confirmadas,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'trancada')           AS trancadas,
       t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada') AS vagas_livres,
       round(100.0 * count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')
             / NULLIF(t.vagas_turma, 0), 1)                             AS ocupacao_pct
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
LEFT JOIN matricula m  ON m.id_turma = t.id_turma
GROUP BY t.id_turma, d.nome_disciplina
ORDER BY ocupacao_pct DESC NULLS LAST, t.codigo_turma;

-- ============================================================================
-- CONSULTA 4 — Desempenho histórico por disciplina (períodos encerrados)
-- Técnica: agregação com FILTER sobre múltiplas condições + HAVING para
-- descartar amostras pequenas + comparação de tupla (ano, semestre) < (2026,2).
-- Leitura: quais disciplinas mais reprovam — insumo direto para a consulta 10.
-- ============================================================================
\echo '=== C4: desempenho por disciplina (períodos encerrados) ==='
SELECT d.codigo_disciplina,
       d.nome_disciplina,
       count(h.id_historico)                                               AS avaliacoes,
       round(avg(dm.media_final), 2)                                       AS media_geral,
       count(*) FILTER (WHERE h.situacao_historico = 'aprovado')           AS aprovados,
       count(*) FILTER (WHERE h.situacao_historico = 'reprovado_nota')     AS rep_nota,
       count(*) FILTER (WHERE h.situacao_historico = 'reprovado_frequencia') AS rep_freq,
       round(100.0 * count(*) FILTER (WHERE h.situacao_historico = 'aprovado')
             / count(*), 1)                                      AS aprovacao_pct
FROM disciplina d
JOIN turma t           ON t.id_disciplina = d.id_disciplina
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
JOIN matricula m       ON m.id_turma = t.id_turma
JOIN historico h       ON h.id_matricula = m.id_matricula
                      AND h.situacao_historico IN ('aprovado', 'reprovado_nota', 'reprovado_frequencia')
LEFT JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula     -- [E14]
GROUP BY d.id_disciplina
HAVING count(h.id_historico) >= 10
ORDER BY aprovacao_pct, d.codigo_disciplina;

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
  SELECT d.id_disciplina, 0, ARRAY[d.id_disciplina], NULL::vinculo_t
  FROM disciplina d
  WHERE d.codigo_disciplina = 'TABD'
  UNION ALL
  -- passo: para cada nó, busca seus requisitos diretos
  SELECT p.id_requisito, a.nivel + 1, a.caminho || p.id_requisito, p.vinculo_pre_requisito
  FROM arvore a
  JOIN pre_requisito p ON p.id_disciplina = a.node_id
  WHERE NOT p.id_requisito = ANY (a.caminho)      -- proteção contra ciclos
)
SELECT repeat('    ', a.nivel) || d.codigo_disciplina AS arvore,
       d.nome_disciplina,
       a.nivel,
       coalesce(a.vinculo::text, '(alvo)') AS vinculo
FROM arvore a
JOIN disciplina d ON d.id_disciplina = a.node_id
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
  SELECT m.id_aluno AS id_aluno, a.id_curriculo, p.nome_pessoa AS nome_aluno
  FROM matricula m
  JOIN historico h ON h.id_matricula = m.id_matricula AND h.situacao_historico = 'aprovado'
  JOIN aluno a     ON a.id_aluno = m.id_aluno
  JOIN pessoa p    ON p.id_pessoa = a.id_pessoa                            -- [E2]
  GROUP BY m.id_aluno, a.id_curriculo, p.nome_pessoa
  ORDER BY count(*) DESC, m.id_aluno
  LIMIT 1
),
aprovadas AS (                          -- conjunto-base: o que ele já aprovou
  SELECT DISTINCT t.id_disciplina
  FROM matricula m
  JOIN turma t     ON t.id_turma = m.id_turma
  JOIN historico h ON h.id_matricula = m.id_matricula
  WHERE m.id_aluno = (SELECT id_aluno FROM alvo) AND h.situacao_historico = 'aprovado'
),
expansao (nivel, feitas, novas) AS (
  SELECT 0,
         ARRAY(SELECT id_disciplina FROM aprovadas ORDER BY 1),
         ARRAY(SELECT id_disciplina FROM aprovadas ORDER BY 1)
  UNION ALL
  SELECT e.nivel + 1, e.feitas || x.novas, x.novas
  FROM expansao e
  CROSS JOIN LATERAL (
    SELECT ARRAY(
      SELECT cd.id_disciplina
      FROM curriculo_disciplina cd
      WHERE cd.id_curriculo = (SELECT id_curriculo FROM alvo)
        AND cd.id_disciplina <> ALL (e.feitas)          -- ainda não feita
        AND NOT EXISTS (                                -- nenhum pré-req pendente
              SELECT 1
              FROM pre_requisito p
              WHERE p.id_disciplina = cd.id_disciplina
                AND p.vinculo_pre_requisito = 'pre_requisito'
                AND NOT (p.id_requisito = ANY (e.feitas)))
      ORDER BY cd.id_disciplina
    ) AS novas
  ) x
  WHERE cardinality(x.novas) > 0 AND e.nivel < 12       -- término garantido
)
SELECT (SELECT nome_aluno FROM alvo)               AS aluno,
       e.nivel                               AS onda,
       CASE e.nivel WHEN 1 THEN 'PODE CURSAR JÁ'
                    ELSE 'destrava na onda ' || e.nivel END AS quando,
       d.codigo_disciplina,
       d.nome_disciplina,
       cd.periodo_curriculo_disciplina                            AS periodo_sugerido,
       cd.tipo_curriculo_disciplina
FROM expansao e
CROSS JOIN LATERAL unnest(e.novas) AS n(id_disciplina)
JOIN disciplina d            ON d.id_disciplina = n.id_disciplina
JOIN curriculo_disciplina cd ON cd.id_disciplina = d.id_disciplina
                            AND cd.id_curriculo = (SELECT id_curriculo FROM alvo)
WHERE e.nivel >= 1
ORDER BY e.nivel, d.codigo_disciplina;

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
  SELECT a.id_aluno, a.matricula_aluno, p.nome_pessoa AS nome_aluno, c.codigo_curso AS curso,
         round(sum(dm.media_final * d.ch_total_disciplina) / sum(d.ch_total_disciplina), 2) AS cr,
         count(*) AS disciplinas_avaliadas
  FROM aluno a
  JOIN pessoa p    ON p.id_pessoa = a.id_pessoa                            -- [E2]
  JOIN curso c     ON c.id_curso = a.id_curso
  JOIN matricula m ON m.id_aluno = a.id_aluno
  JOIN turma t     ON t.id_turma = m.id_turma
  JOIN disciplina d ON d.id_disciplina = t.id_disciplina
  JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula        -- [E14]
                                AND dm.media_final IS NOT NULL
  GROUP BY a.id_aluno, p.nome_pessoa, c.codigo_curso
  HAVING count(*) >= 3
)
SELECT curso, matricula_aluno, nome_aluno, cr, disciplinas_avaliadas,   -- matrícula desambigua homônimos
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
  SELECT m.id_aluno,
         pl.ano_periodo_letivo, pl.semestre_periodo_letivo,
         pl.ano_periodo_letivo || '/' || pl.semestre_periodo_letivo       AS periodo,
         round(avg(dm.media_final), 2)       AS media_periodo
  FROM matricula m
  JOIN turma t           ON t.id_turma = m.id_turma
  JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
  JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula        -- [E14]
                                AND dm.media_final IS NOT NULL
  GROUP BY m.id_aluno, pl.ano_periodo_letivo, pl.semestre_periodo_letivo
)
SELECT a.matricula_aluno,                    -- desambigua homônimos (nomes se repetem na carga)
       pe.nome_pessoa AS nome_aluno,
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
JOIN aluno a  ON a.id_aluno = md.id_aluno
JOIN pessoa pe ON pe.id_pessoa = a.id_pessoa                                -- [E2]
WHERE md.id_aluno IN (SELECT id_aluno FROM medias GROUP BY id_aluno HAVING count(*) >= 3)
WINDOW w AS (PARTITION BY md.id_aluno ORDER BY md.ano_periodo_letivo, md.semestre_periodo_letivo)
ORDER BY pe.nome_pessoa, a.matricula_aluno, md.ano_periodo_letivo, md.semestre_periodo_letivo
LIMIT 40;

-- ============================================================================
-- CONSULTA 9 — Choques de horário nas matrículas de 2026/2
-- Técnica: autojunção de matrícula (m2.id_turma > m1.id_turma evita pares
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
SELECT (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[h1.dia_semana_turma_horario] AS dia,
       t1.codigo_turma || ' (' || left(lower(h1.faixa_turma_horario)::text, 5) || '–'
                 || left(upper(h1.faixa_turma_horario)::text, 5) || ')' AS turma_a,
       t2.codigo_turma || ' (' || left(lower(h2.faixa_turma_horario)::text, 5) || '–'
                 || left(upper(h2.faixa_turma_horario)::text, 5) || ')' AS turma_b,
       count(DISTINCT m1.id_aluno)                        AS alunos_afetados
FROM matricula m1
JOIN matricula m2      ON m2.id_aluno = m1.id_aluno
                      AND m2.id_turma > m1.id_turma
                      AND m1.status_matricula = 'confirmada' AND m2.status_matricula = 'confirmada'
JOIN turma t1          ON t1.id_turma = m1.id_turma
JOIN turma t2          ON t2.id_turma = m2.id_turma
                      AND t2.id_periodo_letivo = t1.id_periodo_letivo
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t1.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN turma_horario h1  ON h1.id_turma = t1.id_turma
JOIN turma_horario h2  ON h2.id_turma = t2.id_turma
                      AND h2.dia_semana_turma_horario = h1.dia_semana_turma_horario
                      AND h1.faixa_turma_horario && h2.faixa_turma_horario          -- sobreposição de ranges
GROUP BY h1.dia_semana_turma_horario, t1.codigo_turma, h1.faixa_turma_horario, t2.codigo_turma, h2.faixa_turma_horario
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
  SELECT p.id_requisito AS base_id, p.id_disciplina AS dependente_id
  FROM pre_requisito p
  WHERE p.vinculo_pre_requisito = 'pre_requisito'
  UNION                                       -- sem ALL: deduplica diamantes
  SELECT dep.base_id, p.id_disciplina
  FROM dependentes dep
  JOIN pre_requisito p ON p.id_requisito = dep.dependente_id
                      AND p.vinculo_pre_requisito = 'pre_requisito'
),
destravas AS (
  SELECT base_id, count(DISTINCT dependente_id) AS destrava
  FROM dependentes
  GROUP BY base_id
),
reprovacao AS (
  SELECT t.id_disciplina,
         count(*)                                                    AS avaliacoes,
         round(100.0 * count(*) FILTER (WHERE h.situacao_historico IN
               ('reprovado_nota', 'reprovado_frequencia')) / count(*), 1) AS reprovacao_pct
  FROM turma t
  JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                        AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
  JOIN matricula m       ON m.id_turma = t.id_turma
  JOIN historico h       ON h.id_matricula = m.id_matricula
                        AND h.situacao_historico IN ('aprovado', 'reprovado_nota', 'reprovado_frequencia')
  GROUP BY t.id_disciplina
)
SELECT d.codigo_disciplina,
       d.nome_disciplina,
       coalesce(ds.destrava, 0)                            AS disciplinas_que_destrava,
       r.avaliacoes,
       r.reprovacao_pct,
       round(coalesce(ds.destrava, 0) * r.reprovacao_pct / 100.0, 2) AS indice_criticidade,
       dense_rank() OVER (ORDER BY coalesce(ds.destrava, 0) * r.reprovacao_pct DESC) AS prioridade
FROM reprovacao r
JOIN disciplina d    ON d.id_disciplina = r.id_disciplina
LEFT JOIN destravas ds ON ds.base_id = d.id_disciplina
ORDER BY prioridade, d.codigo_disciplina
LIMIT 15;
