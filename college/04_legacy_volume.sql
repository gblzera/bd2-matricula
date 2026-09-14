-- ============================================================================
-- 04_legacy_volume.sql — legacy terms 2020-2024, for query-plan evidence
-- College · English mirror of the Brazilian academic model
--
-- GENERATED FILE — do not edit by hand.
--   source: sql/05_volume_legado.sql   (Portuguese, the single source of truth)
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
-- 05_volume_legado.sql — Marco 2 · Volume histórico para análise de desempenho
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- POR QUE ESTE SCRIPT EXISTE: com as ~800 matrículas da carga curada do
-- Marco 1, o planner resolve tudo com seq scan e as evidências de EXPLAIN
-- exigidas no Marco 2 não mostram nada. Este script adiciona os semestres
-- LEGADOS 2020/1–2024/2 (3.000 ex-alunos, 400 turmas, ~32 mil matrículas e
-- ~60 mil notas), 100% determinístico, SEM tocar nos cenários de 2025–2026
-- (TABD-N1 continua com 1 vaga livre; COMP1-N1 continua vazia).
--
-- O QUE O LEGADO RECONSTITUI — E O QUE NÃO RECONSTITUI (decisão registrada):
--   Reconstitui: person/student, section, docência, matrícula, avaliação, grade e
--   a situação consolidada. É o acervo acadêmico que uma secretaria realmente
--   guarda por 10 anos.
--   NÃO reconstitui: grade de horários, aulas e presenças. Esse dado não
--   existe number acervo de 2020 com essa granularidade, e inventá-lo (a) exigiria
--   alocar 400 turmas em 9 salas semester violar o EXCLUDE de choque [C10], e
--   (b) não acrescentaria nada à evidência de desempenho, que vem de
--   enrollment/grade. Consequência assumida: a frequência das matrículas legadas
--   é NULL e a situação delas é decidida SÓ pela média — o que a consulta de
--   reprovação por frequência mostra apenas para 2025–2026.
--
-- Bônus de tabela: o histórico legado por ANO é exatamente o cenário que
-- motivaria particionamento (bônus do enunciado) — discutido em docs/.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d enrollment < sql/05_volume_legado.sql
-- Idempotente: remove o legado antes de recriar.
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academic`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academic, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academic, public;


BEGIN;

-- ----------------------------------------------------------------------------
-- Idempotência: apaga apenas o legado. A ordem importa — o modelo ampliado
-- amarra grade e attendance à matrícula por FK COMPOSTA [E13], que NÃO tem
-- ON DELETE CASCADE de propósito: grade de student não some por acidente.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _turmas_legado ON COMMIT DROP AS
SELECT t.section_id FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id
WHERE pl.year < 2025;

DELETE FROM grade      WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM attendance  WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM class_meeting      WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM assessment WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM enrollment_log
 WHERE detail @> '{"origem": "carga_legado"}';
DELETE FROM academic_record h USING enrollment m
 WHERE m.enrollment_id = h.enrollment_id AND m.section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM enrollment       WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM section_professor WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM section_schedule   WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM section           WHERE section_id IN (SELECT section_id FROM _turmas_legado);
DELETE FROM enrollment_window pm USING academic_term pl
 WHERE pl.academic_term_id = pm.academic_term_id AND pl.year < 2025;
DELETE FROM academic_term WHERE year < 2025;

-- ex-alunos: identificados pelo domínio de e-mail da person [E2]
CREATE TEMP TABLE _pessoas_legado ON COMMIT DROP AS
SELECT person_id FROM person WHERE email LIKE '%@legado.iesb.br';
DELETE FROM credit_transfer a USING student al
 WHERE al.student_id = a.student_id AND al.person_id IN (SELECT person_id FROM _pessoas_legado);
DELETE FROM student    WHERE person_id IN (SELECT person_id FROM _pessoas_legado);
DELETE FROM app_user  WHERE person_id IN (SELECT person_id FROM _pessoas_legado);
DELETE FROM person   WHERE person_id IN (SELECT person_id FROM _pessoas_legado);

-- ...e também eventuais matrículas criadas pela demo de concorrência (07),
-- para a asserção do cenário TABD-N1 (7/8) valer em qualquer reexecução
DELETE FROM attendance p USING enrollment m
 WHERE m.enrollment_id = p.enrollment_id AND m.enrolled_at >= date_trunc('day', now());
DELETE FROM grade n USING enrollment m
 WHERE m.enrollment_id = n.enrollment_id AND m.enrolled_at >= date_trunc('day', now());
DELETE FROM enrollment WHERE enrolled_at >= date_trunc('day', now());

-- ----------------------------------------------------------------------------
-- Períodos legados: 2020/1 a 2024/2
-- ----------------------------------------------------------------------------
INSERT INTO academic_term (year, semester, start_date, end_date)
SELECT y, s,
       make_date(y, CASE s WHEN 1 THEN 2 ELSE 8 END, 3),
       make_date(y, CASE s WHEN 1 THEN 7 ELSE 12 END, 15)
FROM generate_series(2020, 2024) AS y, generate_series(1, 2) AS s;

-- ----------------------------------------------------------------------------
-- Ex-alunos: 3.000 pessoas + 3.000 alunos (ingressos 2020–2022).
-- Chaves projetadas para NUNCA colidir com a carga base: matrícula usa faixa
-- de i 1000–3999, CPF usa base 2e10 (a base usa < 1,7e10, docentes 9e10).
-- person.address_id fica NULL: endereço de egresso não é dado que o acervo
-- guarde, e a coluna é anulável justamente para isso [E1].
-- ----------------------------------------------------------------------------
WITH base AS (
  SELECT i,
         CASE WHEN i % 10 < 6 THEN 'CC'
              WHEN i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2020 + (i % 3)      AS ano_ing
  FROM generate_series(1000, 3999) AS g(i)
),
nomes AS (
  SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
               'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
               'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
         ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
               'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
               'Gomes','Martins']                                AS sn
)
INSERT INTO person (address_id, name, email, cpf, birth_date)
SELECT NULL,
       n.pn[1 + (b.i * 7) % 20] || ' ' || n.sn[1 + (b.i * 13) % 15],
       'egresso' || b.i || '@legado.iesb.br',
       lpad((20000000000 + b.i::bigint * 104729)::text, 11, '0')::char(11),
       DATE '1994-01-01' + (b.i * 211) % 3000
FROM base b CROSS JOIN nomes n;

WITH base AS (
  SELECT i,
         CASE WHEN i % 10 < 6 THEN 'CC'
              WHEN i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2020 + (i % 3)      AS ano_ing
  FROM generate_series(1000, 3999) AS g(i)
)
INSERT INTO student (person_id, program_id, curriculum_id, enrollment_number, admission_date, admission_type, status)
SELECT p.person_id, c.program_id, cu.curriculum_id,
       (b.ano_ing * 10000 + b.i)::text,
       make_date(b.ano_ing, 2, 1),
       (ARRAY['entrance_exam','national_exam','transfer','second_degree'])[1 + b.i % 4]::admission_type,
       -- egresso: a maioria já formou; uma parte evadiu; ~20% seguem ativos
       CASE WHEN b.i % 5 = 0 THEN 'active'
            WHEN b.i % 7 = 0 THEN 'dropped_out'
            ELSE 'graduated' END::student_status
FROM base b
JOIN person p ON p.email = 'egresso' || b.i || '@legado.iesb.br'
JOIN program c  ON c.code = b.curso_cod
JOIN curriculum cu
  ON cu.program_id = c.program_id
 AND cu.effective_year = CASE WHEN b.curso_cod = 'CC' THEN 2024 ELSE 2025 END;
 -- simplificação: legados usam as matrizes mais antigas cadastradas

-- ----------------------------------------------------------------------------
-- Turmas legadas: 40 por período (2 por course), seats 100, docência
-- round-robin. O titular entra em section_professor [E11] — a coluna
-- section.professor_id não existe mais.
-- ----------------------------------------------------------------------------
INSERT INTO section (course_id, academic_term_id, code, seats, shift, delivery_mode)
SELECT d.course_id, pl.academic_term_id,
       'LEG-' || d.code || '-' || g.n, 100, 'evening', 'on_campus'
FROM academic_term pl
CROSS JOIN course d
CROSS JOIN generate_series(1, 2) AS g(n)
WHERE pl.year < 2025;

INSERT INTO section_professor (section_id, professor_id, hours, teaching_role)
SELECT t.section_id, p.professor_id, d.total_hours, 'lead'
FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id AND pl.year < 2025
JOIN course d      ON d.course_id = t.course_id
JOIN LATERAL (
  SELECT professor_id FROM professor
  ORDER BY (professor_id + t.course_id + t.academic_term_id) % 10, professor_id
  LIMIT 1
) p ON true;

-- ----------------------------------------------------------------------------
-- Matrículas legadas: ~80 alunos por section, seleção determinística por hash.
-- ORDER BY período garante ordem física correlacionada com enrolled_at —
-- é isso que faz o índice BRIN do 06_indices.sql brilhar.
-- ----------------------------------------------------------------------------
WITH legadas AS (
  SELECT t.section_id AS section_id, t.course_id, pl.start_date,
         row_number() OVER (ORDER BY pl.start_date, t.section_id) AS trn
  FROM section t
  JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id AND pl.year < 2025
),
escolhas AS (
  SELECT l.section_id, l.start_date, k.k,
         1000 + (l.trn * 53 + k.k * 17) % 3000 AS i_egresso   -- i do e-mail determinístico
  FROM legadas l
  CROSS JOIN generate_series(1, 80) AS k(k)
)
INSERT INTO enrollment (student_id, section_id, enrolled_at, status)
SELECT a.student_id, e.section_id,
       (e.start_date - 10)::timestamptz + make_interval(hours => (e.k * 3)::int),
       CASE WHEN e.k % 17 = 0 THEN 'cancelled'
            WHEN e.k % 13 = 0 THEN 'suspended'
            ELSE 'confirmed' END::enrollment_status
FROM escolhas e
JOIN person p ON p.email = 'egresso' || e.i_egresso || '@legado.iesb.br'
JOIN student a  ON a.person_id = p.person_id
ORDER BY e.start_date, e.section_id, e.k
ON CONFLICT (student_id, section_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Avaliações e notas legadas [E14] — mesmas fórmulas da carga base, para que
-- a média continue reproduzível. É esta tabela (`grade`, ~60 mil linhas) que
-- alimenta a mv_academic_record e o índice de faixa de média.
-- ----------------------------------------------------------------------------
INSERT INTO assessment (section_id, name, weight, assessment_date, is_makeup)
SELECT t.section_id, v.name, v.weight, pl.start_date + v.day, v.is_makeup
FROM section t
JOIN academic_term pl ON pl.academic_term_id = t.academic_term_id AND pl.year < 2025
CROSS JOIN (VALUES ('A1', 4.00, 60, false), ('A2', 6.00, 120, false), ('P3', 6.00, 135, true))
  AS v(name, weight, day, is_makeup);

INSERT INTO grade (assessment_id, enrollment_id, section_id, value)
SELECT av.assessment_id, m.enrollment_id, m.section_id,
       CASE av.name
         WHEN 'A1' THEN round((3   + ((m.student_id * 37 + m.section_id * 11) % 71) / 10.0)::numeric, 1)
         WHEN 'A2' THEN round((3.5 + ((m.student_id * 29 + m.section_id * 13) % 66) / 10.0)::numeric, 1)
         ELSE           round((4   + ((m.student_id * 41 + m.section_id * 7)  % 56) / 10.0)::numeric, 1)
       END
FROM enrollment m
JOIN section tu          ON tu.section_id = m.section_id
JOIN academic_term pl ON pl.academic_term_id = tu.academic_term_id AND pl.year < 2025
JOIN assessment av      ON av.section_id = m.section_id
WHERE m.status = 'confirmed'
  AND (NOT av.is_makeup
       OR ((0.4 * round((3   + ((m.student_id * 37 + m.section_id * 11) % 71) / 10.0)::numeric, 1)
          + 0.6 * round((3.5 + ((m.student_id * 29 + m.section_id * 13) % 66) / 10.0)::numeric, 1)) < 5
           AND m.student_id % 3 <> 0));

-- ----------------------------------------------------------------------------
-- Histórico consolidado do legado. Sem presença, a frequência é NULL e a
-- situação sai só da média — declarado no cabeçalho deste script.
-- ----------------------------------------------------------------------------
INSERT INTO academic_record (enrollment_id, closed_on, outcome)
SELECT m.enrollment_id, pl.end_date,
       CASE WHEN m.status = 'suspended' THEN 'suspended'
            WHEN dm.final_grade >= 5            THEN 'passed'
            ELSE 'failed_grade' END::academic_outcome
FROM enrollment m
JOIN section tu          ON tu.section_id = m.section_id
JOIN academic_term pl ON pl.academic_term_id = tu.academic_term_id AND pl.year < 2025
LEFT JOIN v_enrollment_performance dm ON dm.enrollment_id = m.enrollment_id
WHERE m.status <> 'cancelled';

-- ----------------------------------------------------------------------------
-- Auditoria do legado (engorda enrollment_log p/ a evidência do índice GIN).
-- log_action é DML; o evento de negócio vai no jsonb — que é o que o GIN indexa.
-- ----------------------------------------------------------------------------
INSERT INTO enrollment_log (enrollment_id, app_user_id, occurred_at, action, detail)
SELECT m.enrollment_id, u.app_user_id, m.enrolled_at, 'insert',
       jsonb_build_object('evento', 'matricula_criada', 'section', tu.code,
                          'origem', 'carga_legado', 'status_inicial', m.status::text)
FROM enrollment m
JOIN section tu          ON tu.section_id = m.section_id
JOIN academic_term pl ON pl.academic_term_id = tu.academic_term_id AND pl.year < 2025
LEFT JOIN app_user u    ON u.login = 'bd2';

COMMIT;

-- Estatísticas frescas para o planner (essencial antes das evidências de EXPLAIN)
ANALYZE;

-- Política de refresh das MVs em ação: carga em lote concluída => refresh
REFRESH MATERIALIZED VIEW mv_course_indicators;
REFRESH MATERIALIZED VIEW mv_academic_record;

DO $$
DECLARE n_mat int; n_conf_tabd int; n_notas int; n_pessoas int;
BEGIN
  SELECT count(*) INTO n_mat    FROM enrollment;
  SELECT count(*) INTO n_notas  FROM grade;
  SELECT count(*) INTO n_pessoas FROM person;
  SELECT count(*) INTO n_conf_tabd FROM enrollment m JOIN section t ON t.section_id = m.section_id
   WHERE t.code = 'TABD-N1' AND m.status = 'confirmed';
  IF n_mat   < 30000 THEN RAISE EXCEPTION 'Volume insuficiente: % matrículas', n_mat; END IF;
  IF n_notas < 50000 THEN RAISE EXCEPTION 'Volume insuficiente: % notas', n_notas; END IF;
  IF n_conf_tabd <> 7 THEN RAISE EXCEPTION 'Cenário TABD-N1 corrompido: % confirmadas', n_conf_tabd; END IF;
  RAISE NOTICE 'Volume legado OK: % pessoas, % matrículas, % notas; TABD-N1 intacta (7/8).',
    n_pessoas, n_mat, n_notas;
END $$;

\echo '=== Volumes após carga legada ==='
SELECT 'person' AS tabela, count(*) FROM person                UNION ALL
SELECT 'student',            count(*) FROM student                 UNION ALL
SELECT 'section',            count(*) FROM section                 UNION ALL
SELECT 'enrollment',        count(*) FROM enrollment             UNION ALL
SELECT 'assessment',        count(*) FROM assessment             UNION ALL
SELECT 'grade',             count(*) FROM grade                  UNION ALL
SELECT 'attendance',         count(*) FROM attendance              UNION ALL
SELECT 'academic_record',        count(*) FROM academic_record             UNION ALL
SELECT 'enrollment_log',    count(*) FROM enrollment_log         UNION ALL
SELECT 'mv_academic_record', count(*) FROM mv_academic_record
ORDER BY tabela;
