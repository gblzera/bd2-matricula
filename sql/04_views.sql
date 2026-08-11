-- ============================================================================
-- 04_views.sql — Marco 2 · 3 views + 1 materialized view
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/04_views.sql
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

DROP VIEW IF EXISTS v_oferta_periodo, v_vagas_disponiveis, v_historico_aluno CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_indicadores;

-- ----------------------------------------------------------------------------
-- VIEW 1 — v_oferta_periodo: o catálogo público do período corrente.
-- "Corrente" é dinâmico (CURRENT_DATE dentro do período), não hardcoded.
-- Horários agregados numa string legível via LATERAL (turma sem horário
-- publicado ainda aparece — LEFT JOIN).
-- ----------------------------------------------------------------------------
CREATE VIEW v_oferta_periodo AS
SELECT pl.ano || '/' || pl.semestre        AS periodo,
       t.id                                AS turma_id,
       t.codigo                            AS turma,
       d.codigo                            AS disciplina,
       d.nome                              AS nome_disciplina,
       d.ch_total,
       p.nome                              AS professor,
       t.turno,
       t.vagas,
       h.encontros
FROM turma t
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                      AND CURRENT_DATE BETWEEN pl.data_inicio AND pl.data_fim
JOIN disciplina d      ON d.id = t.disciplina_id
JOIN professor p       ON p.id = t.professor_id
LEFT JOIN LATERAL (
  SELECT string_agg(
           (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.dia_semana]
           || ' ' || left(lower(th.faixa)::text, 5)
           || '–' || left(upper(th.faixa)::text, 5)
           || ' (' || s.codigo || ')',
           ' · ' ORDER BY th.dia_semana, lower(th.faixa)) AS encontros
  FROM turma_horario th
  JOIN sala s ON s.id = th.sala_id
  WHERE th.turma_id = t.id
) h ON true;
COMMENT ON VIEW v_oferta_periodo IS 'Catálogo de oferta do período letivo corrente, com horários agregados.';

-- ----------------------------------------------------------------------------
-- VIEW 2 — v_vagas_disponiveis: vagas − confirmadas por turma.
-- É a fonte de leitura da transação de matrícula (Marco 2 · concorrência):
-- centraliza a REGRA de contagem (só 'confirmada' consome vaga) num único
-- lugar, em vez de espalhá-la por consultas ad hoc.
-- ----------------------------------------------------------------------------
CREATE VIEW v_vagas_disponiveis AS
SELECT t.id                                                  AS turma_id,
       t.codigo                                              AS turma,
       pl.ano, pl.semestre,
       t.vagas,
       count(m.id) FILTER (WHERE m.status = 'confirmada')    AS confirmadas,
       t.vagas - count(m.id) FILTER (WHERE m.status = 'confirmada') AS vagas_livres
FROM turma t
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
LEFT JOIN matricula m  ON m.turma_id = t.id
GROUP BY t.id, pl.ano, pl.semestre;
COMMENT ON VIEW v_vagas_disponiveis IS 'Vagas livres por turma (regra: só status=confirmada consome vaga).';

-- ----------------------------------------------------------------------------
-- VIEW 3 — v_historico_aluno: histórico completo, pronto para o aluno consultar.
-- security_invoker = on (PG 15+): a view executa com as PERMISSÕES DE QUEM
-- CONSULTA, então as políticas de RLS do 08_seguranca.sql valem ATRAVÉS da
-- view. Sem isso, a view rodaria como o dono (superusuário bd2) e vazaria
-- o histórico de todos — exatamente o que o RLS deve impedir.
-- ----------------------------------------------------------------------------
CREATE VIEW v_historico_aluno WITH (security_invoker = on) AS
SELECT a.id                          AS aluno_id,
       a.matricula                   AS ra,
       a.nome                        AS aluno,
       pl.ano || '/' || pl.semestre  AS periodo,
       d.codigo                      AS disciplina,
       d.nome                        AS nome_disciplina,
       d.ch_total,
       h.nota_a1, h.nota_a2, h.nota_p3,
       h.frequencia,
       h.media_final,
       h.situacao,
       m.status                      AS status_matricula
FROM aluno a
JOIN matricula m       ON m.aluno_id = a.id
JOIN turma t           ON t.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
JOIN disciplina d      ON d.id = t.disciplina_id
LEFT JOIN historico h  ON h.matricula_id = m.id
ORDER BY a.id, pl.ano, pl.semestre, d.codigo;
COMMENT ON VIEW v_historico_aluno IS 'Histórico por aluno; security_invoker=on para o RLS valer através da view.';

-- ----------------------------------------------------------------------------
-- MATERIALIZED VIEW — mv_indicadores: painel disciplina × período.
--
-- POLÍTICA DE ATUALIZAÇÃO (justificativa exigida no enunciado):
--   Os indicadores agregam NOTAS e SITUAÇÕES, que só mudam em dois momentos
--   do semestre — lançamento de notas e fechamento do período. Não faz
--   sentido pagar o custo da agregação a cada consulta da coordenação
--   (view comum), nem manter refresh contínuo. Política adotada:
--     REFRESH MATERIALIZED VIEW CONCURRENTLY mv_indicadores;
--   executado (a) após o fechamento de cada período letivo e (b) sob demanda
--   após cargas em lote — o 05_volume_legado.sql faz exatamente isso.
--   O CONCURRENTLY não bloqueia leituras durante o refresh e exige o índice
--   ÚNICO criado abaixo (ux_mv_indicadores) — por isso ele existe.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_indicadores AS
SELECT d.id                                                   AS disciplina_id,
       pl.id                                                  AS periodo_letivo_id,
       d.codigo                                               AS disciplina,
       pl.ano, pl.semestre,
       count(DISTINCT t.id)                                   AS turmas,
       sum(t.vagas)                                           AS vagas_ofertadas,
       count(m.id) FILTER (WHERE m.status = 'confirmada')     AS confirmadas,
       round(100.0 * count(m.id) FILTER (WHERE m.status = 'confirmada')
             / NULLIF(sum(t.vagas), 0), 1)                    AS ocupacao_pct,
       round(avg(h.media_final), 2)                           AS media_geral,
       count(h.id) FILTER (WHERE h.situacao = 'aprovado')     AS aprovados,
       count(h.id) FILTER (WHERE h.situacao IN
             ('reprovado_nota', 'reprovado_frequencia'))      AS reprovados,
       round(100.0 * count(h.id) FILTER (WHERE h.situacao = 'aprovado')
             / NULLIF(count(h.id) FILTER (WHERE h.situacao IN
               ('aprovado', 'reprovado_nota', 'reprovado_frequencia')), 0), 1)
                                                              AS aprovacao_pct
FROM turma t
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
JOIN disciplina d      ON d.id = t.disciplina_id
LEFT JOIN matricula m  ON m.turma_id = t.id
LEFT JOIN historico h  ON h.matricula_id = m.id
GROUP BY d.id, pl.id;

-- Exigido pelo REFRESH ... CONCURRENTLY (identifica cada linha unicamente)
CREATE UNIQUE INDEX ux_mv_indicadores ON mv_indicadores (disciplina_id, periodo_letivo_id);
COMMENT ON MATERIALIZED VIEW mv_indicadores IS
  'Indicadores disciplina×período; refresh CONCURRENTLY pós-fechamento (política justificada no script).';

COMMIT;

\echo '=== Views criadas ==='
SELECT 'v_oferta_periodo'    AS objeto, count(*) AS linhas FROM v_oferta_periodo    UNION ALL
SELECT 'v_vagas_disponiveis',           count(*)           FROM v_vagas_disponiveis UNION ALL
SELECT 'v_historico_aluno',             count(*)           FROM v_historico_aluno   UNION ALL
SELECT 'mv_indicadores',                count(*)           FROM mv_indicadores;
