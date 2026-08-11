-- ============================================================================
-- 05_volume_legado.sql — Marco 2 · Volume histórico para análise de desempenho
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- POR QUE ESTE SCRIPT EXISTE: com as ~800 matrículas da carga curada do
-- Marco 1, o planner resolve tudo com seq scan e as evidências de EXPLAIN
-- exigidas no Marco 2 não mostram nada. Este script adiciona os semestres
-- LEGADOS 2020/1–2024/2 (3.000 ex-alunos, 400 turmas, ~40 mil matrículas com
-- histórico), 100% determinístico, SEM tocar nos cenários de 2025–2026
-- (TABD-N1 continua com 1 vaga livre; COMP1-N1 continua vazia).
--
-- Bônus de tabela: o histórico legado por ANO é exatamente o cenário que
-- motivaria particionamento (bônus do enunciado) — discutido em docs/.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/05_volume_legado.sql
-- Idempotente: remove o legado antes de recriar.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- Idempotência: apaga apenas o legado (períodos < 2025)
DELETE FROM matricula m USING turma t, periodo_letivo pl
WHERE t.id = m.turma_id AND pl.id = t.periodo_letivo_id AND pl.ano < 2025;
DELETE FROM turma t USING periodo_letivo pl
WHERE pl.id = t.periodo_letivo_id AND pl.ano < 2025;
DELETE FROM periodo_letivo WHERE ano < 2025;
DELETE FROM aluno WHERE email LIKE '%@legado.iesb.br';
DELETE FROM log_matricula WHERE usuario = 'carga_legado';
-- ...e também eventuais matrículas criadas pela demo de concorrência (07),
-- para a asserção do cenário TABD-N1 (7/8) valer em qualquer reexecução
DELETE FROM matricula WHERE data_matricula >= date_trunc('day', now());

-- Períodos legados: 2020/1 a 2024/2
INSERT INTO periodo_letivo (ano, semestre, data_inicio, data_fim)
SELECT y, s,
       make_date(y, CASE s WHEN 1 THEN 2 ELSE 8 END, 3),
       make_date(y, CASE s WHEN 1 THEN 7 ELSE 12 END, 15)
FROM generate_series(2020, 2024) AS y, generate_series(1, 2) AS s;

-- Ex-alunos: 3.000 (ingressos 2020–2022, ~80% já inativos/formados).
-- Chaves projetadas para NUNCA colidir com a carga base: matrícula usa faixa
-- de i 1000–3999, CPF usa base 2e10 (a base usa valores < 1,7e10).
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
INSERT INTO aluno (matricula, nome, cpf, email, nascimento,
                   curso_id, curriculo_id, ingresso, ativo)
SELECT
  (b.ano_ing * 10000 + b.i)::text,
  n.pn[1 + (b.i * 7) % 20] || ' ' || n.sn[1 + (b.i * 13) % 15],
  lpad((20000000000 + b.i::bigint * 104729)::text, 11, '0'),
  'egresso' || b.i || '@legado.iesb.br',
  DATE '1994-01-01' + (b.i * 211) % 3000,
  c.id,
  cu.id,
  make_date(b.ano_ing, 2, 1),
  (b.i % 5) = 0                       -- só ~20% ainda ativos
FROM base b
CROSS JOIN nomes n
JOIN curso c ON c.codigo = b.curso_cod
JOIN curriculo cu
  ON cu.curso_id = c.id
 AND cu.ano_vigencia = CASE WHEN b.curso_cod = 'CC' THEN 2024 ELSE 2025 END;
 -- simplificação: legados usam as matrizes mais antigas cadastradas

-- Turmas legadas: 40 por período (2 por disciplina), vagas 100, prof. round-robin
INSERT INTO turma (codigo, disciplina_id, periodo_letivo_id, professor_id, turno, vagas)
SELECT 'LEG-' || d.codigo || '-' || g.n,
       d.id, pl.id, p.id, 'noturno', 100
FROM periodo_letivo pl
CROSS JOIN disciplina d
CROSS JOIN generate_series(1, 2) AS g(n)
JOIN LATERAL (
  SELECT id FROM professor
  ORDER BY (id + d.id + pl.id + g.n) % 10, id
  LIMIT 1
) p ON true
WHERE pl.ano < 2025;

-- Matrículas legadas: ~80 alunos por turma, seleção determinística por hash.
-- ORDER BY período garante ordem física correlacionada com data_matricula —
-- é isso que faz o índice BRIN do 06_indices.sql brilhar.
WITH legadas AS (
  SELECT t.id AS turma_id, t.disciplina_id, pl.data_inicio,
         row_number() OVER (ORDER BY pl.data_inicio, t.id) AS trn
  FROM turma t
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id AND pl.ano < 2025
),
escolhas AS (
  SELECT l.turma_id, l.data_inicio, k.k,
         1000 + (l.trn * 53 + k.k * 17) % 3000 AS i_egresso   -- i do e-mail determinístico
  FROM legadas l
  CROSS JOIN generate_series(1, 80) AS k(k)
)
INSERT INTO matricula (aluno_id, turma_id, data_matricula, status)
SELECT a.id, e.turma_id,
       (e.data_inicio - 10)::timestamptz + make_interval(hours => (e.k * 3)::int),
       CASE WHEN e.k % 17 = 0 THEN 'cancelada'
            WHEN e.k % 13 = 0 THEN 'trancada'
            ELSE 'confirmada' END::status_mat_t
FROM escolhas e
JOIN aluno a ON a.email = 'egresso' || e.i_egresso || '@legado.iesb.br'
ORDER BY e.data_inicio, e.turma_id, e.k
ON CONFLICT (aluno_id, turma_id) DO NOTHING;

-- Histórico legado: mesmas fórmulas determinísticas da carga base
INSERT INTO historico (matricula_id, nota_a1, nota_a2, nota_p3, frequencia, situacao)
SELECT m.id, x.a1, x.a2,
       CASE WHEN (0.4 * x.a1 + 0.6 * x.a2) < 5 AND m.aluno_id % 3 <> 0 THEN x.p3 END,
       x.freq, 'cursando'
FROM matricula m
JOIN turma tu          ON tu.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = tu.periodo_letivo_id AND pl.ano < 2025
CROSS JOIN LATERAL (
  SELECT round((3   + ((m.aluno_id * 37 + m.turma_id * 11) % 71) / 10.0)::numeric, 1) AS a1,
         round((3.5 + ((m.aluno_id * 29 + m.turma_id * 13) % 66) / 10.0)::numeric, 1) AS a2,
         round((4   + ((m.aluno_id * 41 + m.turma_id * 7)  % 56) / 10.0)::numeric, 1) AS p3,
         (60 + (m.aluno_id * 7 + m.turma_id * 3) % 41)::numeric                       AS freq
) AS x
WHERE m.status <> 'cancelada';

UPDATE historico h
SET situacao = CASE
                 WHEN m.status = 'trancada' THEN 'trancado'
                 WHEN h.frequencia < 75     THEN 'reprovado_frequencia'
                 WHEN h.media_final >= 5    THEN 'aprovado'
                 ELSE 'reprovado_nota'
               END::situacao_t
FROM matricula m
JOIN turma tu          ON tu.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = tu.periodo_letivo_id AND pl.ano < 2025
WHERE m.id = h.matricula_id;

-- Auditoria do legado (engorda log_matricula p/ a evidência do índice GIN)
INSERT INTO log_matricula (matricula_id, acao, ocorrido_em, usuario, detalhe)
SELECT m.id, 'matricula_criada', m.data_matricula, 'carga_legado',
       jsonb_build_object('turma', tu.codigo, 'origem', 'legado',
                          'status_inicial', m.status::text)
FROM matricula m
JOIN turma tu          ON tu.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = tu.periodo_letivo_id AND pl.ano < 2025;

COMMIT;

-- Estatísticas frescas para o planner (essencial antes das evidências de EXPLAIN)
ANALYZE;

-- Política de refresh da MV em ação: carga em lote concluída => refresh
REFRESH MATERIALIZED VIEW mv_indicadores;

DO $$
DECLARE n_mat int; n_conf_tabd int;
BEGIN
  SELECT count(*) INTO n_mat FROM matricula;
  SELECT count(*) INTO n_conf_tabd FROM matricula m JOIN turma t ON t.id = m.turma_id
  WHERE t.codigo = 'TABD-N1' AND m.status = 'confirmada';
  IF n_mat < 30000 THEN RAISE EXCEPTION 'Volume insuficiente: % matrículas', n_mat; END IF;
  IF n_conf_tabd <> 7 THEN RAISE EXCEPTION 'Cenário TABD-N1 corrompido: % confirmadas', n_conf_tabd; END IF;
  RAISE NOTICE 'Volume legado OK: % matrículas no total; TABD-N1 intacta (7/8).', n_mat;
END $$;

\echo '=== Volumes após carga legada ==='
SELECT 'aluno' AS tabela, count(*) FROM aluno            UNION ALL
SELECT 'turma',           count(*) FROM turma            UNION ALL
SELECT 'matricula',       count(*) FROM matricula        UNION ALL
SELECT 'historico',       count(*) FROM historico        UNION ALL
SELECT 'log_matricula',   count(*) FROM log_matricula;
