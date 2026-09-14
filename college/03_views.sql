-- ============================================================================
-- 03_views.sql — views and materialized views
-- College · English mirror of the Brazilian academic model
--
-- GENERATED FILE — do not edit by hand.
--   source: sql/04_views.sql   (Portuguese, the single source of truth)
--   run:    python3 scripts/gerar_college.py
--
-- SCOPE: schema + data only. Queries, views, indexes, transactions and the
-- security layer stay in the Portuguese repository — the security script
-- creates ROLES, which are CLUSTER-wide objects and would collide with the
-- ones already owned by the `matricula` database.
--
-- The structure is IDENTICAL to the Portuguese model: same 41 tables, same
-- columns, same constraints. Only the identifiers changed. Explanatory
-- comments were left in Portuguese on purpose — they carry the reasoning
-- behind each decision, and machine-translating that prose would degrade it.
--
-- VOCABULARY NOTE, because a literal translation would mislead an English
-- reader: in the Brazilian system `curso` is the degree a student graduates
-- with and `disciplina` is the subject taught in a term. The English academic
-- vocabulary maps these to PROGRAM and COURSE respectively — so
-- `curso -> program` and `disciplina -> course`. Translating `curso` as
-- "course" would collide with the other concept in every query.
-- ============================================================================
-- ============================================================================
-- 04_views.sql — Marco 2 · 3 views + 2 materialized views
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d enrollment < sql/04_views.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academic`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academic, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academic, public;


BEGIN;

DROP VIEW IF EXISTS v_term_offering, v_available_seats, v_student_record CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_course_indicators;
DROP MATERIALIZED VIEW IF EXISTS mv_academic_record;

-- ----------------------------------------------------------------------------
-- VIEW 1 — v_term_offering: o catálogo público do período corrente.
-- "Corrente" é dinâmico (CURRENT_DATE dentro do período), não hardcoded.
-- Horários agregados numa string legível via LATERAL (section semester horário
-- publicado ainda aparece — LEFT JOIN).
-- ----------------------------------------------------------------------------
CREATE VIEW v_term_offering AS
SELECT pl.year || '/' || pl.semester        AS term,
       t.section_id                                AS section_id,
       t.code                            AS section,
       d.code                            AS course,
       d.name                              AS name,
       d.total_hours,
       docentes.titular                          AS professor,
       docentes.equipe                           AS equipe_docente,
       t.shift,
       t.delivery_mode,
       t.seats,
       h.encontros
FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id
                      AND CURRENT_DATE BETWEEN pl.start_date AND pl.end_date
JOIN course d      ON d.course_id = t.course_id
-- [E11] o professor virou uma EQUIPE: o titular é quem aparece no catálogo, e
-- a equipe completa vai junto numa string (co-docência é a regra em laboratório).
LEFT JOIN LATERAL (
  SELECT max(pe.name) FILTER (WHERE tp.teaching_role = 'lead') AS titular,
         string_agg(pe.name || ' (' || tp.teaching_role || ')', ' · '
                    ORDER BY tp.teaching_role, pe.name)           AS equipe
  FROM section_professor tp
  JOIN professor p ON p.professor_id = tp.professor_id
  JOIN person pe   ON pe.person_id = p.person_id                    -- [E2]
  WHERE tp.section_id = t.section_id
) docentes ON true
LEFT JOIN LATERAL (
  SELECT string_agg(
           (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.weekday]
           || ' ' || left(lower(th.time_range)::text, 5)
           || '–' || left(upper(th.time_range)::text, 5)
           -- [E12] room NULL = section EAD: o catálogo diz isso em vez de sumir com a linha
           || ' (' || coalesce(s.code || '/' || pr.name, 'EAD') || ')',
           ' · ' ORDER BY th.weekday, lower(th.time_range)) AS encontros
  FROM section_schedule th
  LEFT JOIN room s   ON s.room_id = th.room_id
  LEFT JOIN building pr ON pr.building_id = s.building_id                 -- [E5]
  WHERE th.section_id = t.section_id
) h ON true;
COMMENT ON VIEW v_term_offering IS 'Catálogo de oferta do período letivo corrente, com horários agregados.';

-- ----------------------------------------------------------------------------
-- VIEW 2 — v_available_seats: seats − confirmadas por section.
-- É a fonte de leitura da transação de matrícula (Marco 2 · concorrência):
-- centraliza a REGRA de contagem (só 'confirmed' consome vaga) number único
-- lugar, em vez de espalhá-la por consultas ad hoc.
-- ----------------------------------------------------------------------------
CREATE VIEW v_available_seats AS
SELECT t.section_id                                                  AS section_id,
       t.code                                              AS section,
       pl.year, pl.semester,
       t.seats,
       count(m.enrollment_id) FILTER (WHERE m.status = 'confirmed')    AS confirmadas,
       t.seats - count(m.enrollment_id) FILTER (WHERE m.status = 'confirmed') AS vagas_livres
FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id
LEFT JOIN enrollment m  ON m.section_id = t.section_id
GROUP BY t.section_id, pl.year, pl.semester;
COMMENT ON VIEW v_available_seats IS 'Vagas livres por turma (regra: só status=confirmada consome vaga).';

-- ----------------------------------------------------------------------------
-- VIEW 3 — v_student_record: histórico completo, pronto para o student consultar.
-- security_invoker = on (PG 15+): a view executa com as PERMISSÕES DE QUEM
-- CONSULTA, então as políticas de RLS do 08_seguranca.sql valem ATRAVÉS da
-- view. Sem isso, a view rodaria como o dono (superusuário bd2) e vazaria
-- o histórico de todos — exatamente o que o RLS deve impedir.
-- ----------------------------------------------------------------------------
CREATE VIEW v_student_record WITH (security_invoker = on) AS
SELECT a.student_id                          AS student_id,
       a.enrollment_number                   AS ra,
       pe.name                      AS student,                    -- [E2]
       pl.year || '/' || pl.semester  AS term,
       d.code                      AS course,
       d.name                        AS name,
       d.total_hours,
       -- [E14] notas individuais em vez de três colunas fixas: a lista sai de
       -- `grade`, e média/frequência de v_enrollment_performance (mesma regra da P3).
       notas.detalhe                            AS notas,
       dm.attendance_rate,
       dm.final_grade,
       dm.used_makeup,
       h.outcome,
       h.closed_on,
       m.status                      AS status
FROM student a
JOIN person pe         ON pe.person_id = a.person_id
JOIN enrollment m       ON m.student_id = a.student_id
JOIN section t           ON t.section_id = m.section_id
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id
JOIN course d      ON d.course_id = t.course_id
LEFT JOIN academic_record h  ON h.enrollment_id = m.enrollment_id
LEFT JOIN v_enrollment_performance dm ON dm.enrollment_id = m.enrollment_id
LEFT JOIN LATERAL (
  SELECT string_agg(av.name || ' ' || n.value, ' · '
                    ORDER BY av.is_makeup, av.name) AS detalhe
  FROM grade n JOIN assessment av ON av.assessment_id = n.assessment_id
  WHERE n.enrollment_id = m.enrollment_id
) notas ON true
ORDER BY a.student_id, pl.year, pl.semester, d.code;
COMMENT ON VIEW v_student_record IS 'Histórico por aluno; security_invoker=on para o RLS valer através da view.';

-- ----------------------------------------------------------------------------
-- MATERIALIZED VIEW — mv_course_indicators: painel course × período.
--
-- POLÍTICA DE ATUALIZAÇÃO (justificativa exigida no enunciado):
--   Os indicadores agregam NOTAS e SITUAÇÕES, que só mudam em dois momentos
--   do semestre — lançamento de notas e fechamento do período. Não faz
--   sentido pagar o custo da agregação a cada consulta da coordenação
--   (view comum), nem manter refresh contínuo. Política adotada:
--     REFRESH MATERIALIZED VIEW CONCURRENTLY mv_course_indicators;
--   executado (a) após o fechamento de cada período letivo e (b) sob demanda
--   após cargas em lote — o 05_volume_legado.sql faz exatamente isso.
--   O CONCURRENTLY não bloqueia leituras durante o refresh e exige o índice
--   ÚNICO criado abaixo (ux_mv_indicators) — por isso ele existe.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_course_indicators AS
SELECT d.course_id                                                   AS course_id,
       pl.academic_term_id                                                  AS academic_term_id,
       d.code                                               AS course,
       pl.year, pl.semester,
       count(DISTINCT t.section_id)                                   AS turmas,
       sum(t.seats)                                           AS vagas_ofertadas,
       count(m.enrollment_id) FILTER (WHERE m.status = 'confirmed')     AS confirmadas,
       round(100.0 * count(m.enrollment_id) FILTER (WHERE m.status = 'confirmed')
             / NULLIF(sum(t.seats), 0), 1)                    AS ocupacao_pct,
       round(avg(dm.final_grade), 2)                                    AS media_geral,
       round(avg(dm.attendance_rate), 1)                                     AS frequencia_media,
       count(h.academic_record_id) FILTER (WHERE h.outcome = 'passed')     AS aprovados,
       count(h.academic_record_id) FILTER (WHERE h.outcome IN
             ('failed_grade', 'failed_attendance'))      AS reprovados,
       round(100.0 * count(h.academic_record_id) FILTER (WHERE h.outcome = 'passed')
             / NULLIF(count(h.academic_record_id) FILTER (WHERE h.outcome IN
               ('passed', 'failed_grade', 'failed_attendance')), 0), 1)
                                                              AS aprovacao_pct
FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id
JOIN course d      ON d.course_id = t.course_id
LEFT JOIN enrollment m  ON m.section_id = t.section_id
LEFT JOIN academic_record h  ON h.enrollment_id = m.enrollment_id
LEFT JOIN v_enrollment_performance dm ON dm.enrollment_id = m.enrollment_id     -- [E14]
GROUP BY d.course_id, pl.academic_term_id;

-- Exigido pelo REFRESH ... CONCURRENTLY (identifica cada linha unicamente)
CREATE UNIQUE INDEX ux_mv_indicators ON mv_course_indicators (course_id, academic_term_id);
COMMENT ON MATERIALIZED VIEW mv_course_indicators IS
  'Indicadores disciplina×período; refresh CONCURRENTLY pós-fechamento (política justificada no script).';

-- ----------------------------------------------------------------------------
-- MATERIALIZED VIEW 2 — mv_academic_record: o objeto que a ampliação
-- PROMETEU em [E14] e que paga a conta que ela criou.
--
-- Antes, `academic_record` guardava nota_a1/a2/p3, frequência e uma coluna GERADA
-- com a média — leitura de uma linha só. Depois de [E14], a mesma informação
-- exige agregar `grade` (n linhas) e `attendance` (dezenas por matrícula). O
-- ganho é modelagem correta (1FN, avaliações flexíveis); o custo é agregação
-- a cada leitura. Esta MV é onde esse custo é pago UMA vez por fechamento —
-- e é ela que sustenta o índice B-tree de faixa de média do 06_indices.sql,
-- que antes vivia na coluna gerada.
--
-- Mesma política de refresh da mv_course_indicators: pós-fechamento de período e
-- pós-carga em lote. O índice único abaixo é o que habilita CONCURRENTLY.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_academic_record AS
SELECT dm.enrollment_id,
       dm.student_id,
       dm.section_id,
       t.course_id,
       t.academic_term_id,
       dm.final_grade,
       dm.attendance_rate,
       dm.assessments_recorded,
       dm.used_makeup,
       h.outcome,
       h.closed_on
FROM v_enrollment_performance dm
JOIN section t          ON t.section_id = dm.section_id
LEFT JOIN academic_record h ON h.enrollment_id = dm.enrollment_id;

CREATE UNIQUE INDEX ux_mv_record_consolidated ON mv_academic_record (enrollment_id);
COMMENT ON MATERIALIZED VIEW mv_academic_record IS
  'Consolidado de média/frequência por matrícula [E14]; sucessor materializado da coluna gerada [C13].';

COMMIT;

\echo '=== Views criadas ==='
SELECT 'v_desempenho_matricula (01_ddl)' AS objeto, count(*) AS linhas FROM v_enrollment_performance UNION ALL
SELECT 'v_term_offering',               count(*)           FROM v_term_offering    UNION ALL
SELECT 'v_available_seats',            count(*)           FROM v_available_seats UNION ALL
SELECT 'v_student_record',              count(*)           FROM v_student_record   UNION ALL
SELECT 'mv_course_indicators',                 count(*)           FROM mv_course_indicators      UNION ALL
SELECT 'mv_academic_record',       count(*)           FROM mv_academic_record;
