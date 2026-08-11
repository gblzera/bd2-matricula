-- ============================================================================
-- 02_carga.sql — Marco 1 · Carga de dados
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Requisitos do enunciado: >= 100 alunos, >= 6 turmas, >= 300 matrículas
-- (generate_series permitido). Esta carga produz ~120 alunos, 34 turmas em
-- 4 períodos letivos (2025/1 a 2026/2) e ~700 matrículas com histórico.
--
-- A carga é 100% DETERMINÍSTICA (aritmética modular, sem random()):
-- reexecutar produz exatamente os mesmos dados — importante para
-- reproduzibilidade das consultas e das evidências de EXPLAIN do Marco 2.
--
-- Cenários plantados de propósito (usados pelas consultas e pelo Marco 2):
--   · TABD-N1 (2026/2) com 8 vagas e 7 confirmadas  -> 1 vaga p/ disputa (Marco 2)
--   · COMP1-N1 (2026/2) sem nenhuma matrícula       -> junção externa (consulta 3)
--   · alunos com 3-4 semestres de notas             -> LAG/evolução (consulta 8)
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/02_carga.sql
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- Idempotência: limpa dados preservando o esquema
TRUNCATE log_matricula, historico, matricula, turma_horario, turma, feriado,
         curriculo_disciplina, pre_requisito, aluno, curriculo, sala, curso,
         disciplina, professor, periodo_letivo, campus
RESTART IDENTITY CASCADE;

-- ----------------------------------------------------------------------------
-- Estrutura institucional
-- ----------------------------------------------------------------------------
INSERT INTO campus (nome, cidade) VALUES
  ('Asa Sul',   'Brasília'),
  ('Asa Norte', 'Brasília');

INSERT INTO curso (codigo, nome, grau, ch_total, campus_id)
SELECT v.codigo, v.nome, v.grau, v.ch, c.id
FROM (VALUES
  ('CC',  'Ciência da Computação',                  'bacharelado', 3200, 'Asa Sul'),
  ('SI',  'Sistemas de Informação',                 'bacharelado', 3000, 'Asa Sul'),
  ('ADS', 'Análise e Desenvolvimento de Sistemas',  'tecnologo',   2400, 'Asa Norte')
) AS v(codigo, nome, grau, ch, campus)
JOIN campus c ON c.nome = v.campus;

INSERT INTO curriculo (curso_id, ano_vigencia, ativo)
SELECT c.id, v.ano, v.ativo
FROM (VALUES
  ('CC', 2024, false),   -- matriz antiga (ingressantes 2024/2025)
  ('CC', 2026, true),    -- matriz vigente
  ('SI', 2025, true),
  ('ADS', 2025, true)
) AS v(curso, ano, ativo)
JOIN curso c ON c.codigo = v.curso;

-- ----------------------------------------------------------------------------
-- Catálogo de disciplinas (ch_total é coluna gerada — não se insere)
-- ----------------------------------------------------------------------------
INSERT INTO disciplina (codigo, nome, ch_teorica, ch_pratica) VALUES
  ('ALG1',  'Algoritmos e Programação',              60, 30),
  ('MAT1',  'Matemática Discreta',                   60,  0),
  ('ED1',   'Estruturas de Dados',                   60, 30),
  ('POO1',  'Programação Orientada a Objetos',       60, 30),
  ('LFA',   'Linguagens Formais e Autômatos',        60,  0),
  ('BD1',   'Banco de Dados I',                      60, 30),
  ('SO1',   'Sistemas Operacionais',                 60, 30),
  ('IA1',   'Inteligência Artificial',               60, 30),
  ('BD2',   'Banco de Dados II',                     60, 30),
  ('ENG1',  'Engenharia de Software',                60,  0),
  ('COMP1', 'Compiladores',                          60, 30),
  ('TABD',  'Tópicos Avançados em Banco de Dados',   30, 30),
  ('LBD2',  'Laboratório de Banco de Dados',          0, 60),
  ('RED1',  'Redes de Computadores',                 60, 30),
  ('ETI',   'Ética e Cidadania',                     30,  0),
  ('EMP',   'Empreendedorismo',                      30,  0),
  ('GPI',   'Gestão de Projetos de TI',              60,  0),
  ('SIG',   'Sistemas de Informação Gerenciais',     60,  0),
  ('WEB1',  'Desenvolvimento Web',                   30, 60),
  ('EST1',  'Probabilidade e Estatística',           60,  0);

-- Cadeia de pré-requisitos (profundidade 4: TABD -> BD2 -> BD1 -> ED1 -> ALG1)
-- e um co-requisito (LBD2 acompanha BD2) — exercitados nas consultas 5 e 6.
INSERT INTO pre_requisito (disciplina_id, requisito_id, vinculo)
SELECT d.id, r.id, v.vinculo::vinculo_t
FROM (VALUES
  ('ED1',   'ALG1', 'pre_requisito'),
  ('POO1',  'ALG1', 'pre_requisito'),
  ('LFA',   'MAT1', 'pre_requisito'),
  ('BD1',   'ED1',  'pre_requisito'),
  ('SO1',   'ED1',  'pre_requisito'),
  ('IA1',   'ED1',  'pre_requisito'),
  ('IA1',   'MAT1', 'pre_requisito'),
  ('BD2',   'BD1',  'pre_requisito'),
  ('ENG1',  'POO1', 'pre_requisito'),
  ('COMP1', 'LFA',  'pre_requisito'),
  ('COMP1', 'ED1',  'pre_requisito'),
  ('TABD',  'BD2',  'pre_requisito'),
  ('LBD2',  'BD2',  'co_requisito')
) AS v(disc, req, vinculo)
JOIN disciplina d ON d.codigo = v.disc
JOIN disciplina r ON r.codigo = v.req;

-- ----------------------------------------------------------------------------
-- Grades curriculares (curriculo_disciplina)
-- ----------------------------------------------------------------------------
INSERT INTO curriculo_disciplina (curriculo_id, disciplina_id, periodo, tipo)
SELECT cu.id, d.id, v.periodo, v.tipo::tipo_disc_t
FROM (VALUES
  -- CC 2026 (vigente)
  ('CC', 2026, 'ALG1', 1, 'obrigatoria'), ('CC', 2026, 'MAT1', 1, 'obrigatoria'),
  ('CC', 2026, 'ETI',  1, 'obrigatoria'), ('CC', 2026, 'ED1',  2, 'obrigatoria'),
  ('CC', 2026, 'POO1', 2, 'obrigatoria'), ('CC', 2026, 'EST1', 2, 'obrigatoria'),
  ('CC', 2026, 'BD1',  3, 'obrigatoria'), ('CC', 2026, 'LFA',  3, 'obrigatoria'),
  ('CC', 2026, 'WEB1', 3, 'obrigatoria'), ('CC', 2026, 'BD2',  4, 'obrigatoria'),
  ('CC', 2026, 'SO1',  4, 'obrigatoria'), ('CC', 2026, 'ENG1', 4, 'obrigatoria'),
  ('CC', 2026, 'IA1',  5, 'obrigatoria'), ('CC', 2026, 'TABD', 5, 'optativa'),
  ('CC', 2026, 'LBD2', 5, 'optativa'),    ('CC', 2026, 'COMP1',6, 'obrigatoria'),
  ('CC', 2026, 'RED1', 6, 'obrigatoria'), ('CC', 2026, 'GPI',  6, 'eletiva'),
  -- CC 2024 (matriz antiga — sem TABD/LBD2)
  ('CC', 2024, 'ALG1', 1, 'obrigatoria'), ('CC', 2024, 'MAT1', 1, 'obrigatoria'),
  ('CC', 2024, 'ETI',  1, 'obrigatoria'), ('CC', 2024, 'ED1',  2, 'obrigatoria'),
  ('CC', 2024, 'POO1', 2, 'obrigatoria'), ('CC', 2024, 'EST1', 2, 'obrigatoria'),
  ('CC', 2024, 'BD1',  3, 'obrigatoria'), ('CC', 2024, 'LFA',  3, 'obrigatoria'),
  ('CC', 2024, 'EMP',  3, 'eletiva'),     ('CC', 2024, 'BD2',  4, 'obrigatoria'),
  ('CC', 2024, 'SO1',  4, 'obrigatoria'), ('CC', 2024, 'ENG1', 4, 'obrigatoria'),
  ('CC', 2024, 'IA1',  5, 'obrigatoria'), ('CC', 2024, 'COMP1',5, 'obrigatoria'),
  ('CC', 2024, 'RED1', 5, 'obrigatoria'), ('CC', 2024, 'WEB1', 6, 'obrigatoria'),
  ('CC', 2024, 'GPI',  6, 'obrigatoria'),
  -- SI 2025
  ('SI', 2025, 'ALG1', 1, 'obrigatoria'), ('SI', 2025, 'MAT1', 1, 'obrigatoria'),
  ('SI', 2025, 'SIG',  1, 'obrigatoria'), ('SI', 2025, 'POO1', 2, 'obrigatoria'),
  ('SI', 2025, 'EST1', 2, 'obrigatoria'), ('SI', 2025, 'EMP',  2, 'eletiva'),
  ('SI', 2025, 'BD1',  3, 'obrigatoria'), ('SI', 2025, 'WEB1', 3, 'obrigatoria'),
  ('SI', 2025, 'ENG1', 4, 'obrigatoria'), ('SI', 2025, 'GPI',  4, 'obrigatoria'),
  ('SI', 2025, 'BD2',  5, 'optativa'),    ('SI', 2025, 'ETI',  5, 'obrigatoria'),
  -- ADS 2025
  ('ADS', 2025, 'ALG1', 1, 'obrigatoria'), ('ADS', 2025, 'ETI',  1, 'obrigatoria'),
  ('ADS', 2025, 'POO1', 2, 'obrigatoria'), ('ADS', 2025, 'WEB1', 2, 'obrigatoria'),
  ('ADS', 2025, 'BD1',  3, 'obrigatoria'), ('ADS', 2025, 'RED1', 3, 'obrigatoria'),
  ('ADS', 2025, 'GPI',  4, 'obrigatoria'), ('ADS', 2025, 'EMP',  4, 'eletiva')
) AS v(curso, ano, disc, periodo, tipo)
JOIN curso c      ON c.codigo = v.curso
JOIN curriculo cu ON cu.curso_id = c.id AND cu.ano_vigencia = v.ano
JOIN disciplina d ON d.codigo = v.disc;

-- ----------------------------------------------------------------------------
-- Professores e períodos letivos
-- ----------------------------------------------------------------------------
INSERT INTO professor (matricula, nome, email, titulacao) VALUES
  ('P0001', 'Marcos Tanaka',     'marcos.tanaka@iesb.br',     'doutorado'),
  ('P0002', 'Luciana Prado',     'luciana.prado@iesb.br',     'doutorado'),
  ('P0003', 'André Vieira',      'andre.vieira@iesb.br',      'mestrado'),
  ('P0004', 'Camila Duarte',     'camila.duarte@iesb.br',     'doutorado'),
  ('P0005', 'Ricardo Nóbrega',   'ricardo.nobrega@iesb.br',   'mestrado'),
  ('P0006', 'Sofia Rezende',     'sofia.rezende@iesb.br',     'especializacao'),
  ('P0007', 'Tiago Sales',       'tiago.sales@iesb.br',       'mestrado'),
  ('P0008', 'Vera Lúcia Pinto',  'vera.pinto@iesb.br',        'doutorado'),
  ('P0009', 'Paulo César Lima',  'paulo.lima@iesb.br',        'mestrado'),
  ('P0010', 'Helena Barros',     'helena.barros@iesb.br',     'especializacao');

INSERT INTO periodo_letivo (ano, semestre, data_inicio, data_fim) VALUES
  (2025, 1, DATE '2025-02-03', DATE '2025-07-05'),
  (2025, 2, DATE '2025-08-04', DATE '2025-12-20'),
  (2026, 1, DATE '2026-02-02', DATE '2026-07-04'),
  (2026, 2, DATE '2026-08-03', DATE '2026-12-19');   -- período corrente

-- ----------------------------------------------------------------------------
-- Salas — note "T101" nos DOIS campi: é legal graças ao UNIQUE(campus,codigo) [C4]
-- ----------------------------------------------------------------------------
INSERT INTO sala (campus_id, codigo, capacidade, tipo)
SELECT c.id, v.codigo, v.cap, v.tipo::tipo_sala_t
FROM (VALUES
  ('Asa Sul',   'T101', 60, 'teorica'),
  ('Asa Sul',   'T102', 60, 'teorica'),
  ('Asa Sul',   'T103', 45, 'teorica'),
  ('Asa Sul',   'L201', 25, 'laboratorio'),
  ('Asa Sul',   'L202', 25, 'laboratorio'),
  ('Asa Sul',   'AUD1', 120,'auditorio'),
  ('Asa Norte', 'T101', 50, 'teorica'),
  ('Asa Norte', 'T102', 40, 'teorica'),
  ('Asa Norte', 'L101', 25, 'laboratorio')
) AS v(campus, codigo, cap, tipo)
JOIN campus c ON c.nome = v.campus;

-- ----------------------------------------------------------------------------
-- Turmas: 4 períodos, 34 turmas (mínimo exigido: 6)
-- ----------------------------------------------------------------------------
INSERT INTO turma (codigo, disciplina_id, periodo_letivo_id, professor_id, turno, vagas)
SELECT v.codigo, d.id, pl.id, pr.id, v.turno::turno_t, v.vagas
FROM (VALUES
  -- 2025/1
  (2025, 1, 'ALG1',  'ALG1-N1',  'P0001', 'noturno',  50),
  (2025, 1, 'MAT1',  'MAT1-N1',  'P0002', 'noturno',  50),
  (2025, 1, 'ED1',   'ED1-N1',   'P0003', 'noturno',  40),
  (2025, 1, 'POO1',  'POO1-N1',  'P0004', 'noturno',  40),
  (2025, 1, 'BD1',   'BD1-N1',   'P0005', 'noturno',  40),
  (2025, 1, 'ETI',   'ETI-M1',   'P0006', 'matutino', 60),
  -- 2025/2
  (2025, 2, 'ED1',   'ED1-N1',   'P0003', 'noturno',  40),
  (2025, 2, 'POO1',  'POO1-N1',  'P0004', 'noturno',  40),
  (2025, 2, 'BD1',   'BD1-N1',   'P0005', 'noturno',  40),
  (2025, 2, 'SO1',   'SO1-N1',   'P0007', 'noturno',  35),
  (2025, 2, 'LFA',   'LFA-N1',   'P0008', 'noturno',  35),
  (2025, 2, 'EST1',  'EST1-M1',  'P0002', 'matutino', 45),
  (2025, 2, 'EMP',   'EMP-M1',   'P0006', 'matutino', 60),
  -- 2026/1
  (2026, 1, 'BD1',   'BD1-N1',   'P0005', 'noturno',  40),
  (2026, 1, 'BD2',   'BD2-N1',   'P0001', 'noturno',  35),
  (2026, 1, 'ENG1',  'ENG1-N1',  'P0004', 'noturno',  40),
  (2026, 1, 'SO1',   'SO1-N1',   'P0007', 'noturno',  35),
  (2026, 1, 'IA1',   'IA1-N1',   'P0009', 'noturno',  30),
  (2026, 1, 'RED1',  'RED1-N1',  'P0010', 'noturno',  35),
  (2026, 1, 'WEB1',  'WEB1-M1',  'P0003', 'matutino', 30),
  -- 2026/2 (período corrente — a "grade viva")
  (2026, 2, 'ALG1',  'ALG1-M1',  'P0001', 'matutino', 45),
  (2026, 2, 'ALG1',  'ALG1-N1',  'P0001', 'noturno',  50),
  (2026, 2, 'ED1',   'ED1-M1',   'P0003', 'matutino', 40),
  (2026, 2, 'POO1',  'POO1-N1',  'P0004', 'noturno',  40),
  (2026, 2, 'BD1',   'BD1-M1',   'P0005', 'matutino', 35),
  (2026, 2, 'BD1',   'BD1-N1',   'P0005', 'noturno',  35),
  (2026, 2, 'BD2',   'BD2-N1',   'P0001', 'noturno',  30),
  (2026, 2, 'ENG1',  'ENG1-N1',  'P0004', 'noturno',  40),
  (2026, 2, 'IA1',   'IA1-N1',   'P0009', 'noturno',  30),
  (2026, 2, 'LFA',   'LFA-M1',   'P0008', 'matutino', 35),
  (2026, 2, 'TABD',  'TABD-N1',  'P0001', 'noturno',   8),  -- disputa da última vaga (Marco 2)
  (2026, 2, 'COMP1', 'COMP1-N1', 'P0010', 'noturno',  25),  -- ficará SEM matrículas (consulta 3)
  (2026, 2, 'LBD2',  'LBD2-N1',  'P0005', 'noturno',  20),
  (2026, 2, 'WEB1',  'WEB1-M1',  'P0003', 'matutino', 30)
) AS v(ano, sem, disc, codigo, prof, turno, vagas)
JOIN periodo_letivo pl ON pl.ano = v.ano AND pl.semestre = v.sem
JOIN disciplina d      ON d.codigo = v.disc
JOIN professor pr      ON pr.matricula = v.prof;

-- ----------------------------------------------------------------------------
-- Horários: 2 encontros semanais por turma, gerados deterministicamente.
-- Combinações (par de dias × faixa) e sala rotacionada por rn garantem que a
-- restrição de exclusão [C10] passe. Faixas: matutino 08:00/10:00, noturno
-- 19:00/20:50 — duração 1h40.
-- ----------------------------------------------------------------------------
WITH t AS (
  SELECT tu.id AS turma_id, tu.periodo_letivo_id, tu.turno,
         row_number() OVER (PARTITION BY tu.periodo_letivo_id, tu.turno
                            ORDER BY tu.codigo) - 1 AS rn
  FROM turma tu
), s AS (
  SELECT id AS sala_id, row_number() OVER (ORDER BY campus_id, codigo) - 1 AS sn
  FROM sala
)
INSERT INTO turma_horario (turma_id, periodo_letivo_id, sala_id, dia_semana, faixa)
SELECT t.turma_id, t.periodo_letivo_id, s.sala_id, d.dia,
       CASE
         WHEN t.turno = 'matutino' AND (t.rn / 2) % 2 = 0 THEN timerange(TIME '08:00', TIME '09:40')
         WHEN t.turno = 'matutino'                        THEN timerange(TIME '10:00', TIME '11:40')
         WHEN (t.rn / 2) % 2 = 0                          THEN timerange(TIME '19:00', TIME '20:40')
         ELSE                                                  timerange(TIME '20:50', TIME '22:30')
       END AS faixa
FROM t
JOIN s ON s.sn = t.rn % 9                                   -- 9 salas cadastradas
CROSS JOIN LATERAL (VALUES
  (CASE WHEN t.rn % 2 = 0 THEN 1 ELSE 2 END),               -- seg ou ter
  (CASE WHEN t.rn % 2 = 0 THEN 3 ELSE 4 END)                -- qua ou qui
) AS d(dia);

-- ----------------------------------------------------------------------------
-- Alunos: 120 via generate_series (mínimo exigido: 100).
-- Curso: ~60% CC, ~30% SI, ~10% ADS · Ingresso: 2024/2025/2026 (fev).
-- O currículo é escolhido COERENTEMENTE com o curso — a FK composta [C6] exige.
-- ----------------------------------------------------------------------------
WITH base AS (
  SELECT i,
         CASE WHEN i % 10 < 6 THEN 'CC'
              WHEN i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END                       AS curso_cod,
         2024 + (i % 3)                            AS ano_ing
  FROM generate_series(1, 120) AS g(i)
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
  lpad(((b.i::bigint * 137137137 + 91) % 100000000000)::text, 11, '0'),
  lower(n.pn[1 + (b.i * 7) % 20] || '.' || n.sn[1 + (b.i * 13) % 15]) || b.i || '@aluno.iesb.br',
  DATE '1999-01-01' + (b.i * 211) % 3000,
  c.id,
  cu.id,
  make_date(b.ano_ing, 2, 1),
  (b.i % 17) <> 0                                  -- ~7 alunos inativos
FROM base b
CROSS JOIN nomes n
JOIN curso c ON c.codigo = b.curso_cod
JOIN curriculo cu
  ON cu.curso_id = c.id
 AND cu.ano_vigencia = CASE
       WHEN b.curso_cod = 'CC' AND b.ano_ing >= 2026 THEN 2026
       WHEN b.curso_cod = 'CC'                       THEN 2024
       ELSE 2025 END;

-- ----------------------------------------------------------------------------
-- Matrículas (~700; mínimo exigido: 300).
-- Elegibilidade realista: o aluno só se matricula em turma cuja disciplina
-- pertence ao SEU currículo e cujo período começa depois do seu ingresso.
-- Seleção determinística por hash; no máximo 1 turma por disciplina/período
-- por aluno; lotação alvo ~75% das vagas (máx. 28 por turma).
-- ----------------------------------------------------------------------------
WITH pool AS (
  SELECT tu.id AS turma_id, tu.codigo, tu.vagas, tu.periodo_letivo_id,
         tu.disciplina_id, a.id AS aluno_id, pl.data_inicio,
         (a.id * 31 + tu.id * 17) % 997 AS h
  FROM turma tu
  JOIN periodo_letivo pl       ON pl.id = tu.periodo_letivo_id
  JOIN curriculo_disciplina cd ON cd.disciplina_id = tu.disciplina_id
  JOIN aluno a                 ON a.curriculo_id = cd.curriculo_id
                              AND a.ativo
                              AND a.ingresso <= pl.data_inicio
  WHERE tu.codigo <> 'COMP1-N1'          -- deixada vazia de propósito (consulta 3)
),
sem_duplicata AS (                       -- 1 turma por (aluno, período, disciplina)
  SELECT *,
         row_number() OVER (PARTITION BY aluno_id, periodo_letivo_id, disciplina_id
                            ORDER BY h, turma_id) AS r1
  FROM pool
),
ranqueado AS (
  SELECT *,
         row_number() OVER (PARTITION BY turma_id ORDER BY h, aluno_id) AS rk
  FROM sem_duplicata
  WHERE r1 = 1
)
INSERT INTO matricula (aluno_id, turma_id, data_matricula, status)
SELECT r.aluno_id,
       r.turma_id,
       (r.data_inicio - 10)::timestamptz + make_interval(hours => (r.rk * 3)::int),
       CASE
         WHEN r.codigo = 'TABD-N1' THEN 'confirmada'    -- cenário da última vaga
         WHEN r.rk % 17 = 0        THEN 'cancelada'
         WHEN r.rk % 13 = 0        THEN 'trancada'
         ELSE 'confirmada'
       END::status_mat_t
FROM ranqueado r
WHERE r.rk <= CASE WHEN r.codigo = 'TABD-N1'
                   THEN 7                               -- 7 de 8 vagas: sobra 1
                   ELSE LEAST((r.vagas * 3) / 4, 28) END;

-- ----------------------------------------------------------------------------
-- Histórico: 1 registro por matrícula não cancelada.
-- Períodos encerrados (< 2026/2): notas e frequência determinísticas;
-- período corrente: em curso, sem notas. P3 para parte dos alunos com MF < 5.
-- ----------------------------------------------------------------------------
INSERT INTO historico (matricula_id, nota_a1, nota_a2, nota_p3, frequencia, situacao)
SELECT m.id,
       CASE WHEN x.encerrado AND m.status = 'confirmada' THEN x.a1 END,
       CASE WHEN x.encerrado AND m.status = 'confirmada' THEN x.a2 END,
       CASE WHEN x.encerrado AND m.status = 'confirmada'
             AND (0.4 * x.a1 + 0.6 * x.a2) < 5
             AND m.aluno_id % 3 <> 0 THEN x.p3 END,
       CASE WHEN x.encerrado AND m.status = 'confirmada' THEN x.freq END,
       'cursando'                        -- situação real definida no UPDATE abaixo
FROM matricula m
JOIN turma tu          ON tu.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = tu.periodo_letivo_id
CROSS JOIN LATERAL (
  SELECT (pl.ano, pl.semestre) < (2026, 2)                                   AS encerrado,
         round((3   + ((m.aluno_id * 37 + m.turma_id * 11) % 71) / 10.0)::numeric, 1) AS a1,   -- 3,0–10,0
         round((3.5 + ((m.aluno_id * 29 + m.turma_id * 13) % 66) / 10.0)::numeric, 1) AS a2,   -- 3,5–10,0
         round((4   + ((m.aluno_id * 41 + m.turma_id * 7)  % 56) / 10.0)::numeric, 1) AS p3,   -- 4,0–9,5
         (60 + (m.aluno_id * 7 + m.turma_id * 3) % 41)::numeric              AS freq  -- 60–100
) AS x
WHERE m.status <> 'cancelada';

-- Situação final derivada da media_final (coluna GERADA [C13]) e da frequência
UPDATE historico h
SET situacao = CASE
                 WHEN m.status = 'trancada'          THEN 'trancado'
                 WHEN (pl.ano, pl.semestre) >= (2026, 2) THEN 'cursando'
                 WHEN h.frequencia < 75              THEN 'reprovado_frequencia'
                 WHEN h.media_final >= 5             THEN 'aprovado'
                 ELSE 'reprovado_nota'
               END::situacao_t
FROM matricula m
JOIN turma tu          ON tu.id = m.turma_id
JOIN periodo_letivo pl ON pl.id = tu.periodo_letivo_id
WHERE m.id = h.matricula_id;

-- ----------------------------------------------------------------------------
-- Feriados — nacionais (campus NULL) e locais [C9]
-- ----------------------------------------------------------------------------
INSERT INTO feriado (data, descricao, campus_id)
SELECT v.data::date, v.descricao, c.id
FROM (VALUES
  ('2026-09-07', 'Independência do Brasil',            NULL),
  ('2026-10-12', 'Nossa Senhora Aparecida',            NULL),
  ('2026-11-02', 'Finados',                            NULL),
  ('2026-11-15', 'Proclamação da República',           NULL),
  ('2026-11-20', 'Dia da Consciência Negra',           NULL),
  ('2026-11-30', 'Dia do Evangélico (DF)',             'Asa Sul'),
  ('2026-11-30', 'Dia do Evangélico (DF)',             'Asa Norte'),
  ('2026-08-22', 'Dia do Folclore — evento interno',   'Asa Norte')
) AS v(data, descricao, campus)
LEFT JOIN campus c ON c.nome = v.campus;

-- ----------------------------------------------------------------------------
-- Log de auditoria: criação de cada matrícula + mudanças de status [C11]
-- ----------------------------------------------------------------------------
INSERT INTO log_matricula (matricula_id, acao, ocorrido_em, usuario, detalhe)
SELECT m.id, 'matricula_criada', m.data_matricula, 'carga_inicial',
       jsonb_build_object('turma', tu.codigo, 'status_inicial', 'confirmada')
FROM matricula m
JOIN turma tu ON tu.id = m.turma_id;

INSERT INTO log_matricula (matricula_id, acao, ocorrido_em, usuario, detalhe)
SELECT m.id, 'status_alterado', m.data_matricula + interval '5 days', 'carga_inicial',
       jsonb_build_object('de', 'confirmada', 'para', m.status)
FROM matricula m
WHERE m.status IN ('trancada', 'cancelada');

COMMIT;

-- ----------------------------------------------------------------------------
-- Verificação: falha ruidosamente se os mínimos do enunciado não forem atingidos
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  n_alunos     int; n_turmas int; n_matriculas int; n_vagas_tabd int;
BEGIN
  SELECT count(*) INTO n_alunos     FROM aluno;
  SELECT count(*) INTO n_turmas     FROM turma;
  SELECT count(*) INTO n_matriculas FROM matricula;
  SELECT t.vagas - count(m.id) FILTER (WHERE m.status = 'confirmada')
    INTO n_vagas_tabd
  FROM turma t LEFT JOIN matricula m ON m.turma_id = t.id
  WHERE t.codigo = 'TABD-N1' GROUP BY t.vagas;

  IF n_alunos     < 100 THEN RAISE EXCEPTION 'Carga insuficiente: % alunos (mínimo 100)', n_alunos; END IF;
  IF n_turmas     < 6   THEN RAISE EXCEPTION 'Carga insuficiente: % turmas (mínimo 6)', n_turmas; END IF;
  IF n_matriculas < 300 THEN RAISE EXCEPTION 'Carga insuficiente: % matrículas (mínimo 300)', n_matriculas; END IF;
  IF n_vagas_tabd <> 1  THEN RAISE EXCEPTION 'Cenário da última vaga quebrado: TABD-N1 com % vagas livres (esperado 1)', n_vagas_tabd; END IF;

  RAISE NOTICE 'Carga OK: % alunos, % turmas, % matrículas; TABD-N1 com exatamente 1 vaga livre.',
    n_alunos, n_turmas, n_matriculas;
END $$;

\echo '=== Resumo da carga ==='
SELECT 'campus'              AS tabela, count(*) FROM campus              UNION ALL
SELECT 'curso',                         count(*) FROM curso               UNION ALL
SELECT 'curriculo',                     count(*) FROM curriculo           UNION ALL
SELECT 'disciplina',                    count(*) FROM disciplina          UNION ALL
SELECT 'pre_requisito',                 count(*) FROM pre_requisito       UNION ALL
SELECT 'curriculo_disciplina',          count(*) FROM curriculo_disciplina UNION ALL
SELECT 'professor',                     count(*) FROM professor           UNION ALL
SELECT 'periodo_letivo',                count(*) FROM periodo_letivo      UNION ALL
SELECT 'sala',                          count(*) FROM sala                UNION ALL
SELECT 'turma',                         count(*) FROM turma               UNION ALL
SELECT 'turma_horario',                 count(*) FROM turma_horario       UNION ALL
SELECT 'aluno',                         count(*) FROM aluno               UNION ALL
SELECT 'matricula',                     count(*) FROM matricula           UNION ALL
SELECT 'historico',                     count(*) FROM historico           UNION ALL
SELECT 'feriado',                       count(*) FROM feriado             UNION ALL
SELECT 'log_matricula',                 count(*) FROM log_matricula
ORDER BY tabela;
