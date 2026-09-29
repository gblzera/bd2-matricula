-- ============================================================================
-- 02_seed.sql — deterministic seed data
-- College · English mirror of the Brazilian academic model
--
-- GENERATED FILE — do not edit by hand.
--   source: sql/02_carga.sql   (Portuguese, the single source of truth)
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
-- 02_carga.sql — Marco 1 · Carga de dados do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Requisitos do enunciado: >= 100 alunos, >= 6 turmas, >= 300 matrículas
-- (generate_series permitido). Esta carga produz 120 alunos, 34 turmas em
-- 4 períodos letivos (2025/1 a 2026/2) e ~700 matrículas — agora com o
-- registro FINO que a ampliação criou: aulas, presenças, avaliações e notas.
--
-- A carga é 100% DETERMINÍSTICA (aritmética modular, semester random()):
-- reexecutar produz exatamente os mesmos dados — importante para
-- reproduzibilidade das consultas e das evidências de EXPLAIN do Marco 2.
--
-- O QUE MUDOU COM A AMPLIAÇÃO (ver docs/modelo-tabelas.drawio, página 2):
--   [E1] geografia: pais -> estado -> cidade -> endereco antes de qualquer campus
--   [E2] pessoa é o supertipo: name/e-mail/CPF/nascimento saíram de aluno e
--        professor; a carga cria a pessoa e DEPOIS a especialização
--   [E4] usuario espelha a ROLE do PostgreSQL (login = name da role)
--   [E11] o professor da turma virou turma_professor (titular + auxiliar)
--   [E14] nota_a1/a2/p3 sumiram de historico: agora são avaliacao + nota, e
--        a frequência sai de presenca. historico guarda só o CONSOLIDADO.
--
-- Cenários plantados de propósito (usados pelas consultas e pelo Marco 2):
--   · TABD-N1 (2026/2) com 8 seats e 7 confirmadas  -> 1 vaga p/ disputa (Marco 2)
--   · COMP1-N1 (2026/2) semester nenhuma matrícula       -> junção externa (consulta 3)
--   · LBD2-N1 (2026/2) EAD, semester sala                -> EXCLUDE parcial [E12]
--   · alunos com 3-4 semestres de notas             -> LAG/evolução (consulta 8)
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/02_carga.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academic`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academic, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academic, public;


BEGIN;

-- Idempotência: limpa dados preservando o esquema. A ordem não importa por
-- causa do CASCADE, mas a lista é explícita para que uma tabela nova nunca
-- fique de fora silenciosamente.
TRUNCATE tb_country, tb_state, tb_city, tb_address, tb_person, tb_phone, tb_person_document,
         tb_app_user, tb_campus, tb_department, tb_building, tb_room, tb_resource, tb_room_resource,
         tb_professor, tb_professor_degree, tb_program, tb_program_coordination, tb_curriculum,
         tb_course, tb_curriculum_course, tb_prerequisite, tb_student,
         tb_credit_transfer, tb_academic_term, tb_enrollment_window, tb_holiday,
         tb_section, tb_section_professor, tb_section_schedule, tb_syllabus,
         tb_syllabus_unit, tb_bibliography, tb_syllabus_bibliography,
         tb_enrollment, tb_academic_record, tb_audit_log, tb_class_meeting, tb_attendance, tb_assessment, tb_grade
RESTART IDENTITY CASCADE;

-- ============================================================================
-- 1. GEOGRAFIA  [E1]
--    A cadeia inteira nasce aqui: nenhum endereço existe semester cidade, nenhuma
--    cidade semester estado, nenhum estado semester país. É o ends do "Brasília" digitado
--    à mão em cada campus.
-- ============================================================================
INSERT INTO tb_country (name, iso_code) VALUES ('Brasil', 'BR');

INSERT INTO tb_state (country_id, name, abbreviation)
SELECT p.country_id, v.name, v.abbrev
FROM (VALUES
  ('Distrito Federal', 'DF'), ('Goiás', 'GO'), ('Minas Gerais', 'MG'),
  ('São Paulo', 'SP'),        ('Bahia', 'BA')
) AS v(name, abbrev), tb_country p;

INSERT INTO tb_city (state_id, name, ibge_code)
SELECT e.state_id, v.name, v.ibge
FROM (VALUES
  ('DF', 'Brasília',        '5300108'),
  ('GO', 'Goiânia',         '5208707'),
  ('GO', 'Anápolis',        '5201108'),
  ('GO', 'Luziânia',        '5212501'),
  ('MG', 'Belo Horizonte',  '3106200'),
  ('MG', 'Uberlândia',      '3170206'),
  ('SP', 'São Paulo',       '3550308'),
  ('SP', 'Campinas',        '3509502'),
  ('BA', 'Salvador',        '2927408')
) AS v(abbrev, name, ibge)
JOIN tb_state e ON e.abbreviation = v.abbrev;

-- Endereços institucionais (os dois campi)
INSERT INTO tb_address (city_id, street, number, complement, district, postal_code)
SELECT c.city_id, v.street, v.number, v.complement, v.district, v.postal
FROM (VALUES
  ('Brasília', 'SEPN 707/907', '1',   'Campus A',   'Asa Norte', '70790075'),
  ('Brasília', 'SGAS 613/614', '255', 'Campus B',   'Asa Sul',   '70200730')
) AS v(tb_city, street, number, complement, district, postal)
JOIN tb_city c ON c.name = v.tb_city;

INSERT INTO tb_campus (address_id, name)
SELECT e.address_id, v.name
FROM (VALUES
  ('Campus B', 'Asa Sul'),
  ('Campus A', 'Asa Norte')
) AS v(complement, name)
JOIN tb_address e ON e.complement = v.complement;

-- ============================================================================
-- 2. PESSOAS  [E2]
--    130 pessoas: 10 docentes, 118 discentes... na verdade 120 discentes e 2
--    servidores técnicos (secretaria e DBA). Toda especialização abaixo
--    (professor, aluno, usuario) aponta para uma linha daqui.
--    Faixas de CPF disjuntas por grupo — reexecução nunca colide, e o
--    05_volume_legado.sql usa a faixa 2e10, também disjunta.
-- ============================================================================
WITH nomes AS (
  SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
               'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
               'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
         ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
               'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
               'Gomes','Martins']                                AS sn
),
-- endereços residenciais: 1 por pessoa, distribuídos pelas cidades cadastradas
-- (a maioria em Brasília, como manda a realidade de um campus do DF)
ends AS (
  INSERT INTO tb_address (city_id, street, number, district, postal_code)
  SELECT c.city_id,
         'Quadra ' || (100 + g.i % 400) || ' Conjunto ' || chr(65 + g.i % 20),
         ((g.i * 7) % 900 + 1)::text,
         (ARRAY['Asa Norte','Asa Sul','Taguatinga','Águas Claras','Sudoeste',
                'Guará','Ceilândia','Samambaia'])[1 + g.i % 8],
         lpad((70000000 + (g.i * 137) % 900000)::text, 8, '0')
  FROM generate_series(1, 132) AS g(i)
  JOIN LATERAL (
    SELECT city_id FROM tb_city
    ORDER BY CASE WHEN g.i % 10 < 7 THEN 0 ELSE 1 END,   -- 70% Brasília
             CASE WHEN g.i % 10 < 7 THEN 0 ELSE (city_id + g.i) % 9 END,
             city_id
    LIMIT 1
  ) c ON true
  RETURNING address_id
)
INSERT INTO tb_person (address_id, name, email, cpf, birth_date)
SELECT e.address_id, x.name, x.email, x.cpf, x.nasc
FROM (
  -- (a) 10 docentes — nomes fixos, os mesmos da carga anterior
  SELECT 1 AS grupo, v.position, v.name,
         v.email,
         lpad((90000000000 + v.position * 7654321)::text, 11, '0')::char(11) AS cpf,
         DATE '1970-01-01' + (v.position * 613) AS nasc
  FROM (VALUES
    (1,'Marcos Tanaka','marcos.tanaka@iesb.br'),   (2,'Luciana Prado','luciana.prado@iesb.br'),
    (3,'André Vieira','andre.vieira@iesb.br'),     (4,'Camila Duarte','camila.duarte@iesb.br'),
    (5,'Ricardo Nóbrega','ricardo.nobrega@iesb.br'),(6,'Sofia Rezende','sofia.rezende@iesb.br'),
    (7,'Tiago Sales','tiago.sales@iesb.br'),       (8,'Vera Lúcia Pinto','vera.pinto@iesb.br'),
    (9,'Paulo César Lima','paulo.lima@iesb.br'),   (10,'Helena Barros','helena.barros@iesb.br')
  ) AS v(position, name, email)
  UNION ALL
  -- (b) 2 servidores técnicos: a secretaria acadêmica e o DBA
  SELECT 2, v.position, v.name, v.email,
         lpad((95000000000 + v.position * 1234567)::text, 11, '0')::char(11),
         DATE '1985-05-10' + (v.position * 97)
  FROM (VALUES
    (1, 'Juliana Freitas', 'juliana.freitas@iesb.br'),
    (2, 'Gabriel Kuhn Paz', 'gabriel.paz@iesb.br')
  ) AS v(position, name, email)
  UNION ALL
  -- (c) 120 discentes
  SELECT 3, g.i,
         n.pn[1 + (g.i * 7) % 20] || ' ' || n.sn[1 + (g.i * 13) % 15],
         lower(n.pn[1 + (g.i * 7) % 20] || '.' || n.sn[1 + (g.i * 13) % 15]) || g.i || '@aluno.iesb.br',
         lpad(((g.i::bigint * 137137137 + 91) % 100000000000)::text, 11, '0')::char(11),
         DATE '1999-01-01' + (g.i * 211) % 3000
  FROM generate_series(1, 120) AS g(i), nomes n
) AS x
JOIN LATERAL (
  SELECT address_id,
         row_number() OVER (ORDER BY address_id) AS rn
  FROM ends
) e ON e.rn = CASE x.grupo WHEN 1 THEN x.position
                          WHEN 2 THEN 10 + x.position
                          ELSE 12 + x.position END;

-- Telefones [E3]: um celular principal para todos; fixo adicional a cada 3.
INSERT INTO tb_phone (person_id, number, is_primary, phone_type)
SELECT p.person_id,
       '(61) 9' || lpad(((p.person_id * 81721) % 100000000)::text, 8, '0'),
       true, 'mobile'
FROM tb_person p;

INSERT INTO tb_phone (person_id, number, is_primary, phone_type)
SELECT p.person_id,
       '(61) 3' || lpad(((p.person_id * 5417) % 10000000)::text, 7, '0'),
       false, 'home'
FROM tb_person p
WHERE p.person_id % 3 = 0;

-- Documentos [E3]: RG para todos (o CPF NÃO entra aqui — é 1:1 com a pessoa
-- e por isso vive em pessoa.cpf [E2]); CNH para uma parte.
INSERT INTO tb_person_document (person_id, number, issuer, issued_on, document_type)
SELECT p.person_id,
       lpad(((p.person_id * 314159) % 10000000)::text, 7, '0'),
       (ARRAY['SSP/DF','SSP/GO','SSP/MG','SSP/SP','SSP/BA'])[1 + p.person_id % 5],
       p.birth_date + interval '18 years',
       'id_card'
FROM tb_person p;

INSERT INTO tb_person_document (person_id, number, issuer, issued_on, document_type)
SELECT p.person_id,
       lpad(((p.person_id * 2718281) % 100000000000)::text, 11, '0'),
       'DETRAN/DF',
       p.birth_date + interval '20 years',
       'drivers_license'
FROM tb_person p
WHERE p.person_id % 5 = 0;

-- ============================================================================
-- 3. INFRAESTRUTURA  [E5] [E6]
-- ============================================================================
INSERT INTO tb_department (campus_id, name, abbreviation)
SELECT c.campus_id, v.name, v.abbrev
FROM (VALUES
  ('Asa Sul',   'Departamento de Ciência da Computação', 'DCC'),
  ('Asa Sul',   'Departamento de Matemática',            'DMAT'),
  ('Asa Norte', 'Departamento de Gestão',                'DGES')
) AS v(tb_campus, name, abbrev)
JOIN tb_campus c ON c.name = v.tb_campus;

-- [E5] sala não pertence mais ao campus direto: pertence ao PRÉDIO.
INSERT INTO tb_building (campus_id, name, floor_count)
SELECT c.campus_id, v.name, v.floors
FROM (VALUES
  ('Asa Sul',   'Bloco A', 4),
  ('Asa Sul',   'Bloco B', 3),
  ('Asa Norte', 'Bloco Único', 5),
  ('Asa Norte', 'Anexo Laboratórios', 2)
) AS v(tb_campus, name, floors)
JOIN tb_campus c ON c.name = v.tb_campus;

-- "T101" existe nos DOIS campi: continua legal, agora por UNIQUE(predio, code) [C4→E5]
INSERT INTO tb_room (building_id, code, floor, capacity, room_type)
SELECT pr.building_id, v.code, v.floor, v.capacity, v.kind::room_type
FROM (VALUES
  ('Asa Sul',   'Bloco A',            'T101', 1, 60,  'lecture'),
  ('Asa Sul',   'Bloco A',            'T102', 1, 60,  'lecture'),
  ('Asa Sul',   'Bloco A',            'T103', 2, 45,  'lecture'),
  ('Asa Sul',   'Bloco B',            'L201', 2, 25,  'lab'),
  ('Asa Sul',   'Bloco B',            'L202', 2, 25,  'lab'),
  ('Asa Sul',   'Bloco B',            'AUD1', 1, 120, 'auditorium'),
  ('Asa Norte', 'Bloco Único',        'T101', 1, 50,  'lecture'),
  ('Asa Norte', 'Bloco Único',        'T102', 1, 40,  'lecture'),
  ('Asa Norte', 'Anexo Laboratórios', 'L101', 1, 25,  'lab')
) AS v(tb_campus, tb_building, code, floor, capacity, kind)
JOIN tb_campus c  ON c.name = v.tb_campus
JOIN tb_building pr ON pr.campus_id = c.campus_id AND pr.name = v.tb_building;

INSERT INTO tb_resource (name) VALUES
  ('Projetor multimídia'), ('Quadro branco'), ('Ar-condicionado'),
  ('Computadores'), ('Lousa digital');

-- Recursos por sala: quadro em todas; projetor e ar na maioria; computadores
-- só em laboratório (a regra que justifica a tabela existir).
INSERT INTO tb_room_resource (room_id, resource_id, quantity)
SELECT s.room_id, r.resource_id,
       CASE r.name WHEN 'Computadores' THEN s.capacity ELSE 1 END
FROM tb_room s
CROSS JOIN tb_resource r
WHERE (r.name = 'Quadro branco')
   OR (r.name = 'Projetor multimídia' AND s.room_id % 4 <> 0)
   OR (r.name = 'Ar-condicionado'     AND s.room_id % 3 <> 0)
   OR (r.name = 'Computadores'        AND s.room_type = 'lab')
   OR (r.name = 'Lousa digital'       AND s.room_type = 'auditorium');

-- ============================================================================
-- 4. DOCENTES  [E2] [E6]
-- ============================================================================
INSERT INTO tb_professor (person_id, department_id, employee_number, work_regime, degree_level)
SELECT p.person_id, d.department_id, v.employee_no, v.regime::work_regime, v.degree_level::degree_level
FROM (VALUES
  ('marcos.tanaka@iesb.br',   'P0001', 'DCC',  'full_time', 'doctorate'),
  ('luciana.prado@iesb.br',   'P0002', 'DMAT', 'full_time', 'doctorate'),
  ('andre.vieira@iesb.br',    'P0003', 'DCC',  'part_time',  'master'),
  ('camila.duarte@iesb.br',   'P0004', 'DCC',  'full_time', 'doctorate'),
  ('ricardo.nobrega@iesb.br', 'P0005', 'DCC',  'part_time',  'master'),
  ('sofia.rezende@iesb.br',   'P0006', 'DGES', 'hourly',  'specialization'),
  ('tiago.sales@iesb.br',     'P0007', 'DCC',  'part_time',  'master'),
  ('vera.pinto@iesb.br',      'P0008', 'DMAT', 'full_time', 'doctorate'),
  ('paulo.lima@iesb.br',      'P0009', 'DCC',  'part_time',  'master'),
  ('helena.barros@iesb.br',   'P0010', 'DGES', 'hourly',  'specialization')
) AS v(email, employee_no, abbrev, regime, degree_level)
JOIN tb_person p       ON p.email = v.email
JOIN tb_department d ON d.abbreviation = v.abbrev;

-- Formações [E3]: a graduação de todos, e a pós de quem tem título maior.
INSERT INTO tb_professor_degree (professor_id, program_name, institution, completion_year, degree_level)
SELECT pr.professor_id, 'Ciência da Computação',
       (ARRAY['UnB','UFG','USP','UFMG','PUC'])[1 + pr.professor_id % 5],
       1995 + (pr.professor_id * 3) % 15, 'bachelor'
FROM tb_professor pr
UNION ALL
SELECT pr.professor_id,
       CASE pr.degree_level WHEN 'doctorate' THEN 'Doutorado em Informática'
                                   WHEN 'master'  THEN 'Mestrado em Informática'
                                   ELSE 'Especialização em Banco de Dados' END,
       (ARRAY['UnB','USP','UFRJ','UFPE','UNICAMP'])[1 + (pr.professor_id * 2) % 5],
       2008 + (pr.professor_id * 2) % 14, pr.degree_level
FROM tb_professor pr
WHERE pr.degree_level <> 'bachelor';

-- [E6] chefia: a FK circular criada por ALTER, com UNIQUE (um chefe por professor).
UPDATE tb_department d
SET head_professor_id = pr.professor_id
FROM tb_professor pr, tb_person p
WHERE pr.person_id = p.person_id
  AND (d.abbreviation, p.email) IN (
        ('DCC',  'marcos.tanaka@iesb.br'),
        ('DMAT', 'vera.pinto@iesb.br'),
        ('DGES', 'helena.barros@iesb.br'));

-- ============================================================================
-- 5. USUÁRIOS  [E4]
--    login É o name da ROLE do PostgreSQL. O 08_seguranca.sql cria as
--    roles com exatamente estes nomes — e f_session_user() liga uma coisa
--    à outra em tempo de execução, semester tabela de-para separada.
-- ============================================================================
INSERT INTO tb_app_user (person_id, login, role)
SELECT p.person_id, v.login, v.role::user_role
FROM (VALUES
  ('juliana.freitas@iesb.br', 'registrar',  'registrar'),
  ('gabriel.paz@iesb.br',     'bd2',         'admin'),        -- o DBA da disciplina
  ('marcos.tanaka@iesb.br',   'coordinator', 'coordinator')
) AS v(email, login, role)
JOIN tb_person p ON p.email = v.email;

-- ============================================================================
-- 6. CURSOS, CURRÍCULOS E DISCIPLINAS
-- ============================================================================
INSERT INTO tb_program (campus_id, department_id, code, name, total_hours, degree_type, delivery_mode)
SELECT c.campus_id, d.department_id, v.code, v.name, v.hours,
       v.degree::degree_type, v.delivery_mode::delivery_mode
FROM (VALUES
  ('CC',  'Ciência da Computação',                 3200, 'bachelor', 'Asa Sul',   'DCC',  'on_campus'),
  ('SI',  'Sistemas de Informação',                3000, 'bachelor', 'Asa Sul',   'DCC',  'on_campus'),
  ('ADS', 'Análise e Desenvolvimento de Sistemas', 2400, 'associate',   'Asa Norte', 'DGES', 'hybrid')
) AS v(code, name, hours, degree, tb_campus, abbrev, delivery_mode)
JOIN tb_campus c       ON c.name = v.tb_campus
JOIN tb_department d ON d.abbreviation = v.abbrev;

-- [E8] coordenação COM VIGÊNCIA: o EXCLUDE gist garante um coordenador por
-- curso a cada instante. O mandato is_closed de CC prova que o histórico cabe
-- na mesma tabela — o que uma coluna id_coordenador em curso não permitiria.
INSERT INTO tb_program_coordination (program_id, professor_id, appointment_ref, validity)
SELECT c.program_id, pr.professor_id, v.ref, v.validity
FROM (VALUES
  ('CC',  'P0004', 'PORT-2021-014', daterange(DATE '2021-01-01', DATE '2024-01-01', '[)')),
  ('CC',  'P0001', 'PORT-2024-003', daterange(DATE '2024-01-01', NULL, '[)')),
  ('SI',  'P0005', 'PORT-2023-021', daterange(DATE '2023-03-01', NULL, '[)')),
  ('ADS', 'P0010', 'PORT-2022-008', daterange(DATE '2022-08-01', NULL, '[)'))
) AS v(tb_program, professor_code, ref, validity)
JOIN tb_program c     ON c.code = v.tb_program
JOIN tb_professor pr ON pr.employee_number = v.professor_code;

INSERT INTO tb_curriculum (program_id, approval_ref, effective_year, is_active)
SELECT c.program_id, v.ref, v.year, v.is_active
FROM (VALUES
  ('CC',  'RES-2023-091', 2024, false),   -- matriz antiga (ingressantes 2024/2025)
  ('CC',  'RES-2025-112', 2026, true),    -- matriz vigente
  ('SI',  'RES-2024-077', 2025, true),
  ('ADS', 'RES-2024-078', 2025, true)
) AS v(tb_program, ref, year, is_active)
JOIN tb_program c ON c.code = v.tb_program;

-- Catálogo de disciplinas — ch_total é coluna GERADA [C13], não se insere.
-- Cada disciplina agora tem DONO (departamento) [E6] e ementa.
INSERT INTO tb_course (department_id, code, name, description, theory_hours, lab_hours)
SELECT d.department_id, v.code, v.name,
       'Ementa de ' || v.name || '. Conteúdo programático detalhado no plano de ensino vigente.',
       v.theory, v.lab
FROM (VALUES
  ('DCC',  'ALG1',  'Algoritmos e Programação',             60, 30),
  ('DMAT', 'MAT1',  'Matemática Discreta',                  60,  0),
  ('DCC',  'ED1',   'Estruturas de Dados',                  60, 30),
  ('DCC',  'POO1',  'Programação Orientada a Objetos',      60, 30),
  ('DCC',  'LFA',   'Linguagens Formais e Autômatos',       60,  0),
  ('DCC',  'BD1',   'Banco de Dados I',                     60, 30),
  ('DCC',  'SO1',   'Sistemas Operacionais',                60, 30),
  ('DCC',  'IA1',   'Inteligência Artificial',              60, 30),
  ('DCC',  'BD2',   'Banco de Dados II',                    60, 30),
  ('DCC',  'ENG1',  'Engenharia de Software',               60,  0),
  ('DCC',  'COMP1', 'Compiladores',                         60, 30),
  ('DCC',  'TABD',  'Tópicos Avançados em Banco de Dados',  30, 30),
  ('DCC',  'LBD2',  'Laboratório de Banco de Dados',         0, 60),
  ('DCC',  'RED1',  'Redes de Computadores',                60, 30),
  ('DGES', 'ETI',   'Ética e Cidadania',                    30,  0),
  ('DGES', 'EMP',   'Empreendedorismo',                     30,  0),
  ('DGES', 'GPI',   'Gestão de Projetos de TI',             60,  0),
  ('DGES', 'SIG',   'Sistemas de Informação Gerenciais',    60,  0),
  ('DCC',  'WEB1',  'Desenvolvimento Web',                  30, 60),
  ('DMAT', 'EST1',  'Probabilidade e Estatística',          60,  0)
) AS v(abbrev, code, name, theory, lab)
JOIN tb_department d ON d.abbreviation = v.abbrev;

-- [E17] Cadeia de pré-requisitos, agora POR CURRÍCULO.
-- Profundidade 4 na matriz de CC: TABD -> BD2 -> BD1 -> ED1 -> ALG1.
-- O INSERT roda depois da grade (curriculo_disciplina) porque as duas FKs
-- compostas exigem que disciplina e requisito já estejam naquela matriz — e
-- é justamente isso que o modelo passou a garantir.
-- O co-requisito LBD2/BD2 saiu junto com a coluna `link`.
-- Fica logo abaixo do bloco da grade.
INSERT INTO tb_curriculum_course (curriculum_id, course_id, term_number, requirement_type)
SELECT cu.curriculum_id, d.course_id, v.term, v.kind::requirement_type
FROM (VALUES
  -- CC 2026 (vigente)
  ('CC', 2026, 'ALG1', 1, 'required'), ('CC', 2026, 'MAT1', 1, 'required'),
  ('CC', 2026, 'ETI',  1, 'required'), ('CC', 2026, 'ED1',  2, 'required'),
  ('CC', 2026, 'POO1', 2, 'required'), ('CC', 2026, 'EST1', 2, 'required'),
  ('CC', 2026, 'BD1',  3, 'required'), ('CC', 2026, 'LFA',  3, 'required'),
  ('CC', 2026, 'WEB1', 3, 'required'), ('CC', 2026, 'BD2',  4, 'required'),
  ('CC', 2026, 'SO1',  4, 'required'), ('CC', 2026, 'ENG1', 4, 'required'),
  ('CC', 2026, 'IA1',  5, 'required'), ('CC', 2026, 'TABD', 5, 'elective'),
  ('CC', 2026, 'LBD2', 5, 'elective'),    ('CC', 2026, 'COMP1',6, 'required'),
  ('CC', 2026, 'RED1', 6, 'required'), ('CC', 2026, 'GPI',  6, 'free_elective'),
  -- CC 2024 (matriz antiga — semester TABD/LBD2)
  ('CC', 2024, 'ALG1', 1, 'required'), ('CC', 2024, 'MAT1', 1, 'required'),
  ('CC', 2024, 'ETI',  1, 'required'), ('CC', 2024, 'ED1',  2, 'required'),
  ('CC', 2024, 'POO1', 2, 'required'), ('CC', 2024, 'EST1', 2, 'required'),
  ('CC', 2024, 'BD1',  3, 'required'), ('CC', 2024, 'LFA',  3, 'required'),
  ('CC', 2024, 'EMP',  3, 'free_elective'),     ('CC', 2024, 'BD2',  4, 'required'),
  ('CC', 2024, 'SO1',  4, 'required'), ('CC', 2024, 'ENG1', 4, 'required'),
  ('CC', 2024, 'IA1',  5, 'required'), ('CC', 2024, 'COMP1',5, 'required'),
  ('CC', 2024, 'RED1', 5, 'required'), ('CC', 2024, 'WEB1', 6, 'required'),
  ('CC', 2024, 'GPI',  6, 'required'),
  -- SI 2025
  ('SI', 2025, 'ALG1', 1, 'required'), ('SI', 2025, 'MAT1', 1, 'required'),
  ('SI', 2025, 'SIG',  1, 'required'), ('SI', 2025, 'POO1', 2, 'required'),
  ('SI', 2025, 'EST1', 2, 'required'), ('SI', 2025, 'EMP',  2, 'free_elective'),
  ('SI', 2025, 'BD1',  3, 'required'), ('SI', 2025, 'WEB1', 3, 'required'),
  ('SI', 2025, 'ENG1', 4, 'required'), ('SI', 2025, 'GPI',  4, 'required'),
  ('SI', 2025, 'BD2',  5, 'elective'),    ('SI', 2025, 'ETI',  5, 'required'),
  -- ADS 2025
  ('ADS', 2025, 'ALG1', 1, 'required'), ('ADS', 2025, 'ETI',  1, 'required'),
  ('ADS', 2025, 'POO1', 2, 'required'), ('ADS', 2025, 'WEB1', 2, 'required'),
  ('ADS', 2025, 'BD1',  3, 'required'), ('ADS', 2025, 'RED1', 3, 'required'),
  ('ADS', 2025, 'GPI',  4, 'required'), ('ADS', 2025, 'EMP',  4, 'free_elective')
) AS v(tb_program, year, course_code, term, kind)
JOIN tb_program c      ON c.code = v.tb_program
JOIN tb_curriculum cu ON cu.program_id = c.program_id AND cu.effective_year = v.year
JOIN tb_course d ON d.code = v.course_code;

-- A mesma aresta vale em toda matriz onde as DUAS matérias existem. O último
-- JOIN é o que garante isso: se o requisito não está naquele currículo, a
-- linha simplesmente não é gerada — espelhando a restrição que o modelo impõe.
INSERT INTO tb_prerequisite (curriculum_id, course_id, required_course_id)
SELECT cd.curriculum_id, d.course_id, r.course_id
FROM (VALUES
  ('ED1',   'ALG1'),
  ('POO1',  'ALG1'),
  ('LFA',   'MAT1'),
  ('BD1',   'ED1'),
  ('SO1',   'ED1'),
  ('IA1',   'ED1'),
  ('IA1',   'MAT1'),
  ('BD2',   'BD1'),
  ('ENG1',  'POO1'),
  ('COMP1', 'LFA'),
  ('COMP1', 'ED1'),
  ('TABD',  'BD2')
) AS v(course_code, requires)
JOIN tb_course d ON d.code = v.course_code
JOIN tb_course r ON r.code = v.requires
JOIN tb_curriculum_course cd ON cd.course_id = d.course_id
JOIN tb_curriculum_course cr ON cr.curriculum_id = cd.curriculum_id
                               AND cr.course_id = r.course_id;

-- ============================================================================
-- 7. CALENDÁRIO  [E9] [E10]
-- ============================================================================
INSERT INTO tb_academic_term (year, semester, start_date, end_date) VALUES
  (2025, 1, DATE '2025-02-03', DATE '2025-07-05'),
  (2025, 2, DATE '2025-08-04', DATE '2025-12-20'),
  (2026, 1, DATE '2026-02-02', DATE '2026-07-04'),
  (2026, 2, DATE '2026-08-03', DATE '2026-12-19');   -- período corrente

-- [E9] janelas de matrícula: o EXCLUDE gist impede duas janelas do MESMO kind
-- se sobreporem no mesmo período. Tipos diferentes PODEM conviver — e convivem:
-- o ajuste começa antes de a matrícula terminar, de propósito.
INSERT INTO tb_enrollment_window (academic_term_id, description, window_range, window_type)
SELECT pl.academic_term_id, v.description,
       tstzrange(
         (pl.start_date + v.starts)::timestamptz,
         (pl.start_date + v.ends)::timestamptz, '[)'),
       v.kind::enrollment_window_type
FROM tb_academic_term pl
CROSS JOIN (VALUES
  ('Matrícula regular',   -30, -10, 'matricula'),
  ('Rematrícula',         -45, -30, 're_enrollment'),
  ('Ajuste de matrícula', -12,   7, 'adjustment'),
  ('Trancamento',          15,  60, 'withdrawal')
) AS v(description, starts, ends, kind);

-- [E10] feriado por ARCO EXCLUSIVO: exatamente uma das 4 FKs preenchida.
-- O "kind" (nacional/estadual/…) NÃO é coluna: seria derivável do arco (3FN).
INSERT INTO tb_holiday (country_id, description, holiday_date, is_optional)
SELECT p.country_id, v.description, v.date::date, v.is_optional
FROM (VALUES
  ('2026-09-07', 'Independência do Brasil',    false),
  ('2026-10-12', 'Nossa Senhora Aparecida',    false),
  ('2026-11-02', 'Finados',                    false),
  ('2026-11-15', 'Proclamação da República',   false),
  ('2026-11-20', 'Dia da Consciência Negra',   false),
  ('2025-09-07', 'Independência do Brasil',    false),
  ('2025-10-12', 'Nossa Senhora Aparecida',    false),
  ('2025-11-15', 'Proclamação da República',   false),
  ('2026-02-16', 'Carnaval',                   true),
  ('2026-04-03', 'Sexta-feira Santa',          false)
) AS v(date, description, is_optional), tb_country p;

INSERT INTO tb_holiday (state_id, description, holiday_date, is_optional)
SELECT e.state_id, 'Dia do Evangélico (DF)', DATE '2026-11-30', false
FROM tb_state e WHERE e.abbreviation = 'DF';

INSERT INTO tb_holiday (city_id, description, holiday_date, is_optional)
SELECT c.city_id, 'Aniversário de Brasília', DATE '2026-04-21', false
FROM tb_city c WHERE c.name = 'Brasília';

INSERT INTO tb_holiday (campus_id, description, holiday_date, is_optional)
SELECT c.campus_id, 'Dia do Folclore — evento interno', DATE '2026-08-22', true
FROM tb_campus c WHERE c.name = 'Asa Norte';

-- ============================================================================
-- 8. TURMAS, DOCÊNCIA E HORÁRIOS  [E11] [E12]
-- ============================================================================
INSERT INTO tb_section (course_id, academic_term_id, code, seats, shift, delivery_mode)
SELECT d.course_id, pl.academic_term_id, v.code, v.seats,
       v.shift::shift, v.delivery_mode::delivery_mode
FROM (VALUES
  -- 2025/1
  (2025, 1, 'ALG1',  'ALG1-N1',  'evening',  50, 'on_campus'),
  (2025, 1, 'MAT1',  'MAT1-N1',  'evening',  50, 'on_campus'),
  (2025, 1, 'ED1',   'ED1-N1',   'evening',  40, 'on_campus'),
  (2025, 1, 'POO1',  'POO1-N1',  'evening',  40, 'on_campus'),
  (2025, 1, 'BD1',   'BD1-N1',   'evening',  40, 'on_campus'),
  (2025, 1, 'ETI',   'ETI-M1',   'morning', 60, 'on_campus'),
  -- 2025/2
  (2025, 2, 'ED1',   'ED1-N1',   'evening',  40, 'on_campus'),
  (2025, 2, 'POO1',  'POO1-N1',  'evening',  40, 'on_campus'),
  (2025, 2, 'BD1',   'BD1-N1',   'evening',  40, 'on_campus'),
  (2025, 2, 'SO1',   'SO1-N1',   'evening',  35, 'on_campus'),
  (2025, 2, 'LFA',   'LFA-N1',   'evening',  35, 'on_campus'),
  (2025, 2, 'EST1',  'EST1-M1',  'morning', 45, 'on_campus'),
  (2025, 2, 'EMP',   'EMP-M1',   'morning', 60, 'on_campus'),
  -- 2026/1
  (2026, 1, 'BD1',   'BD1-N1',   'evening',  40, 'on_campus'),
  (2026, 1, 'BD2',   'BD2-N1',   'evening',  35, 'on_campus'),
  (2026, 1, 'ENG1',  'ENG1-N1',  'evening',  40, 'on_campus'),
  (2026, 1, 'SO1',   'SO1-N1',   'evening',  35, 'on_campus'),
  (2026, 1, 'IA1',   'IA1-N1',   'evening',  30, 'on_campus'),
  (2026, 1, 'RED1',  'RED1-N1',  'evening',  35, 'on_campus'),
  (2026, 1, 'WEB1',  'WEB1-M1',  'morning', 30, 'on_campus'),
  -- 2026/2 (período corrente — a "grade viva")
  (2026, 2, 'ALG1',  'ALG1-M1',  'morning', 45, 'on_campus'),
  (2026, 2, 'ALG1',  'ALG1-N1',  'evening',  50, 'on_campus'),
  (2026, 2, 'ED1',   'ED1-M1',   'morning', 40, 'on_campus'),
  (2026, 2, 'POO1',  'POO1-N1',  'evening',  40, 'on_campus'),
  (2026, 2, 'BD1',   'BD1-M1',   'morning', 35, 'on_campus'),
  (2026, 2, 'BD1',   'BD1-N1',   'evening',  35, 'on_campus'),
  (2026, 2, 'BD2',   'BD2-N1',   'evening',  30, 'on_campus'),
  (2026, 2, 'ENG1',  'ENG1-N1',  'evening',  40, 'on_campus'),
  (2026, 2, 'IA1',   'IA1-N1',   'evening',  30, 'on_campus'),
  (2026, 2, 'LFA',   'LFA-M1',   'morning', 35, 'on_campus'),
  (2026, 2, 'TABD',  'TABD-N1',  'evening',   8, 'on_campus'),  -- disputa da última vaga (Marco 2)
  (2026, 2, 'COMP1', 'COMP1-N1', 'evening',  25, 'on_campus'),  -- ficará SEM matrículas (consulta 3)
  (2026, 2, 'LBD2',  'LBD2-N1',  'evening',  20, 'online'),         -- EAD: semester sala [E12]
  (2026, 2, 'WEB1',  'WEB1-M1',  'morning', 30, 'on_campus')
) AS v(year, semester, course_code, code, shift, seats, delivery_mode)
JOIN tb_academic_term pl ON pl.year = v.year AND pl.semester = v.semester
JOIN tb_course d      ON d.code = v.course_code;

-- [E11] co-docência: o titular (um só por turma, garantido por índice parcial
-- único) e, nas turmas com prática, um auxiliar. Era uma coluna professor_id
-- em turma; virou tabela porque a realidade tem mais de um docente.
INSERT INTO tb_section_professor (section_id, professor_id, hours, teaching_role)
SELECT t.section_id, pr.professor_id, d.total_hours, 'lead'
FROM tb_section t
JOIN tb_course d ON d.course_id = t.course_id
JOIN tb_professor pr ON pr.employee_number = (CASE d.code
        WHEN 'ALG1'  THEN 'P0001' WHEN 'MAT1'  THEN 'P0002' WHEN 'ED1'   THEN 'P0003'
        WHEN 'POO1'  THEN 'P0004' WHEN 'BD1'   THEN 'P0005' WHEN 'ETI'   THEN 'P0006'
        WHEN 'SO1'   THEN 'P0007' WHEN 'LFA'   THEN 'P0008' WHEN 'EST1'  THEN 'P0002'
        WHEN 'EMP'   THEN 'P0006' WHEN 'BD2'   THEN 'P0001' WHEN 'ENG1'  THEN 'P0004'
        WHEN 'IA1'   THEN 'P0009' WHEN 'RED1'  THEN 'P0010' WHEN 'WEB1'  THEN 'P0003'
        WHEN 'TABD'  THEN 'P0001' WHEN 'COMP1' THEN 'P0010' WHEN 'LBD2'  THEN 'P0005'
        WHEN 'GPI'   THEN 'P0010' ELSE 'P0009' END);

-- auxiliar nas turmas com carga prática (o laboratório precisa de dois)
INSERT INTO tb_section_professor (section_id, professor_id, hours, teaching_role)
SELECT t.section_id, pr.professor_id, d.lab_hours, 'assistant'
FROM tb_section t
JOIN tb_course d ON d.course_id = t.course_id AND d.lab_hours >= 30
JOIN LATERAL (
  SELECT p2.professor_id FROM tb_professor p2
  WHERE p2.professor_id <> (SELECT tp.professor_id FROM tb_section_professor tp
                            WHERE tp.section_id = t.section_id AND tp.teaching_role = 'lead')
  ORDER BY (p2.professor_id + t.section_id) % 10, p2.professor_id
  LIMIT 1
) pr ON true
WHERE t.section_id % 2 = 0;

-- ----------------------------------------------------------------------------
-- Horários: 2 encontros semanais por turma, gerados deterministicamente.
-- Combinações (par de dias × faixa) e sala rotacionada por rn garantem que a
-- restrição de exclusão [C10] passe. Faixas: matutino 08:00/10:00, noturno
-- 19:00/20:50 — duração 1h40.
-- [E12] turma EAD entra com room_id NULL: o EXCLUDE de sala é PARCIAL
-- (WHERE room_id IS NOT NULL), então dois horários EAD convivem semester choque.
-- ----------------------------------------------------------------------------
WITH t AS (
  SELECT tu.section_id, tu.academic_term_id, tu.shift, tu.delivery_mode,
         row_number() OVER (PARTITION BY tu.academic_term_id, tu.shift
                            ORDER BY tu.code) - 1 AS rn
  FROM tb_section tu
), s AS (
  SELECT room_id, row_number() OVER (ORDER BY room_id) - 1 AS sn FROM tb_room
)
INSERT INTO tb_section_schedule (section_id, academic_term_id, room_id, weekday, time_range, meeting_type)
SELECT t.section_id, t.academic_term_id,
       CASE WHEN t.delivery_mode = 'online' THEN NULL ELSE s.room_id END,
       d.day,
       CASE
         WHEN t.shift = 'morning' AND (t.rn / 2) % 2 = 0 THEN timerange(TIME '08:00', TIME '09:40')
         WHEN t.shift = 'morning'                        THEN timerange(TIME '10:00', TIME '11:40')
         WHEN (t.rn / 2) % 2 = 0                                THEN timerange(TIME '19:00', TIME '20:40')
         ELSE                                                        timerange(TIME '20:50', TIME '22:30')
       END AS faixa,
       CASE WHEN d.position = 2 AND dd.lab_hours > 0 THEN 'lab_session' ELSE 'lecture' END::meeting_type
FROM t
JOIN tb_section tu     ON tu.section_id = t.section_id
JOIN tb_course dd ON dd.course_id = tu.course_id
JOIN s ON s.sn = t.rn % 9                                   -- 9 salas cadastradas
CROSS JOIN LATERAL (VALUES
  (1, CASE WHEN t.rn % 2 = 0 THEN 1 ELSE 2 END),            -- seg ou ter
  (2, CASE WHEN t.rn % 2 = 0 THEN 3 ELSE 4 END)             -- qua ou qui
) AS d(position, day);

-- ============================================================================
-- 9. PLANOS DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA (section_id NULL = plano base). Uma turma
--    pode ter a SUA versão — e a FK composta garante que a versão só existe
--    para uma turma DAQUELA disciplina. UNIQUE NULLS NOT DISTINCT impede um
--    segundo plano base [técnica de C9].
-- ============================================================================
INSERT INTO tb_syllabus (course_id, section_id, objective, methodology, grading_criteria, approved_on)
SELECT d.course_id, NULL,
       'Capacitar o estudante em ' || d.name || ', articulando teoria e prática.',
       CASE WHEN d.lab_hours > 0
            THEN 'Aulas expositivas dialogadas, laboratório e projeto integrador.'
            ELSE 'Aulas expositivas dialogadas, estudos dirigidos e seminários.' END,
       'Duas avaliações (A1 peso 4, A2 peso 6) e prova substitutiva conforme regimento.',
       DATE '2025-01-15'
FROM tb_course d;

-- Versão de turma para as ofertas de 2026/2 de BD2 e TABD: é o caso que
-- justifica section_id na tabela — o mesmo plano base, adaptado à oferta.
INSERT INTO tb_syllabus (course_id, section_id, objective, methodology, grading_criteria, approved_on)
SELECT t.course_id, t.section_id,
       'Versão 2026/2 do plano de ' || d.name || ': ênfase em PostgreSQL 17.',
       'Aulas expositivas, laboratório com contêiner Docker e projeto em dupla.',
       'A1 (peso 4) sobre modelagem; A2 (peso 6) sobre implementação; substitutiva conforme regimento.',
       DATE '2026-07-20'
FROM tb_section t
JOIN tb_course d      ON d.course_id = t.course_id
JOIN tb_academic_term pl ON pl.academic_term_id = t.academic_term_id
WHERE pl.year = 2026 AND pl.semester = 2
  AND d.code IN ('BD2', 'TABD');

-- Unidades do plano base: 4 por disciplina, somando a CH total da disciplina.
INSERT INTO tb_syllabus_unit (syllabus_id, title, content, position, hours)
SELECT pe.syllabus_id,
       'Unidade ' || u.position || ' — ' || d.code,
       'Conteúdo da unidade ' || u.position || ' de ' || d.name || '.',
       u.position,
       (d.total_hours / 4) + CASE WHEN u.position <= d.total_hours % 4 THEN 1 ELSE 0 END
FROM tb_syllabus pe
JOIN tb_course d ON d.course_id = pe.course_id
CROSS JOIN generate_series(1, 4) AS u(position)
WHERE pe.section_id IS NULL;

INSERT INTO tb_bibliography (title, author, publisher, isbn, year, edition) VALUES
  ('Sistemas de Banco de Dados',            'Elmasri, R.; Navathe, S.', 'Pearson',       '9788579361852', 2011, 6),
  ('Sistema de Banco de Dados',             'Silberschatz, A.',         'Elsevier',      '9788535245356', 2012, 6),
  ('Projeto de Banco de Dados',             'Heuser, C. A.',            'Bookman',       '9788577803828', 2009, 6),
  ('Introdução a Sistemas de Bancos de Dados','Date, C. J.',            'Campus',        '9788535212730', 2004, 8),
  ('PostgreSQL: Guia do Programador',       'Milani, A.',               'Novatec',       '9788575221365', 2008, 1),
  ('Algoritmos: Teoria e Prática',          'Cormen, T. H.',            'GEN LTC',       '9788535236996', 2012, 3),
  ('Estruturas de Dados e Algoritmos em Java','Goodrich, M. T.',        'Bookman',       '9788577805006', 2013, 5),
  ('Engenharia de Software',                'Sommerville, I.',          'Pearson',       '9788543024974', 2018, 10),
  ('Redes de Computadores',                 'Tanenbaum, A. S.',         'Pearson',       '9788543020563', 2021, 6),
  ('Inteligência Artificial',               'Russell, S.; Norvig, P.',  'GEN LTC',       '9788535251418', 2013, 3),
  ('Fundamentos de Matemática Discreta',    'Gersting, J. L.',          'GEN LTC',       '9788521633334', 2016, 7),
  ('Estatística Básica',                    'Bussab, W. O.; Morettin, P.','Saraiva',     '9788502207998', 2013, 8);

-- Bibliografia por plano: uma básica e uma complementar, escolhidas de forma
-- determinística — a chave (plano, bibliografia) impede repetir o mesmo título.
INSERT INTO tb_syllabus_bibliography (syllabus_id, bibliography_id, reference_type)
SELECT pe.syllabus_id, b.bibliography_id, v.kind::reference_type
FROM tb_syllabus pe
CROSS JOIN (VALUES ('core', 0), ('supplementary', 5)) AS v(kind, deslo)
JOIN LATERAL (
  SELECT bibliography_id FROM tb_bibliography
  ORDER BY ((bibliography_id + pe.syllabus_id + v.deslo) % 12), bibliography_id
  LIMIT 1
) b ON true
WHERE pe.section_id IS NULL
ON CONFLICT (syllabus_id, bibliography_id) DO NOTHING;

-- ============================================================================
-- 10. DISCENTES  [E2]
--     120 alunos, cada um apontando para a pessoa já criada. O currículo é
--     coerente com o curso — a FK composta [C6] exige.
-- ============================================================================
INSERT INTO tb_student (person_id, program_id, curriculum_id, enrollment_number, admission_type, status)
SELECT p.person_id, c.program_id, cu.curriculum_id,
       -- o RA carrega o year de ingresso: 2024 * 10000 + i  ->  "20240036" [E18]
       (b.ano_ing * 10000 + b.i)::text,
       (ARRAY['entrance_exam','national_exam','transfer','second_degree'])[1 + b.i % 4]::admission_type,
       CASE WHEN b.i % 17 = 0 THEN 'suspended' ELSE 'active' END::student_status
FROM (
  SELECT g.i,
         CASE WHEN g.i % 10 < 6 THEN 'CC'
              WHEN g.i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2024 + (g.i % 3)     AS ano_ing,
         -- o e-mail é a chave natural que liga o aluno i à pessoa criada no
         -- passo 2: a MESMA expressão, para não depender de ordem de id
         lower(n.pn[1 + (g.i * 7) % 20] || '.' || n.sn[1 + (g.i * 13) % 15]) || g.i || '@aluno.iesb.br' AS email
  FROM generate_series(1, 120) AS g(i),
       (SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
                     'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
                     'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
               ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
                     'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
                     'Gomes','Martins']                                AS sn) n
) b
JOIN tb_person p ON p.email = b.email
JOIN tb_program c  ON c.code = b.curso_cod
JOIN tb_curriculum cu
  ON cu.program_id = c.program_id
 AND cu.effective_year = CASE
       WHEN b.curso_cod = 'CC' AND b.ano_ing >= 2026 THEN 2026
       WHEN b.curso_cod = 'CC'                       THEN 2024
       ELSE 2025 END;

-- Um usuário por aluno [E4]: login = 'al_' || RA, o mesmo name que o
-- 08_seguranca.sql dá à ROLE. É essa igualdade que a RLS usa.
INSERT INTO tb_app_user (person_id, login, is_active, role)
SELECT a.person_id, 'al_' || a.enrollment_number, (a.status = 'active'), 'aluno'
FROM tb_student a;

-- ============================================================================
-- 11. MATRÍCULAS
--     Elegibilidade realista: o aluno só se matricula em turma cuja disciplina
--     pertence ao SEU currículo e cujo período começa depois do seu ingresso.
--     Seleção determinística por hash; no máximo 1 turma por disciplina/período
--     por aluno; lotação alvo ~75% das seats (máx. 28 por turma).
-- ============================================================================
WITH pool AS (
  SELECT tu.section_id AS section_id, tu.code, tu.seats, tu.academic_term_id,
         tu.course_id, a.student_id AS student_id, pl.start_date,
         (a.student_id * 31 + tu.section_id * 17) % 997 AS h
  FROM tb_section tu
  JOIN tb_academic_term pl       ON pl.academic_term_id = tu.academic_term_id
  JOIN tb_curriculum_course cd ON cd.course_id = tu.course_id
  JOIN tb_student a                 ON a.curriculum_id = cd.curriculum_id
                              AND a.status = 'active'
                              -- year de ingresso vem do RA [E18]
                              AND left(a.enrollment_number, 4)::int <= pl.year
  WHERE tu.code <> 'COMP1-N1'          -- deixada vazia de propósito (consulta 3)
),
sem_duplicata AS (                       -- 1 turma por (aluno, período, disciplina)
  SELECT *,
         row_number() OVER (PARTITION BY student_id, academic_term_id, course_id
                            ORDER BY h, section_id) AS r1
  FROM pool
),
ranqueado AS (
  SELECT *,
         row_number() OVER (PARTITION BY section_id ORDER BY h, student_id) AS rk
  FROM sem_duplicata
  WHERE r1 = 1
)
INSERT INTO tb_enrollment (student_id, section_id, enrolled_at, status)
SELECT r.student_id,
       r.section_id,
       (r.start_date - 10)::timestamptz + make_interval(hours => (r.rk * 3)::int),
       CASE
         WHEN r.code = 'TABD-N1' THEN 'confirmed'    -- cenário da última vaga
         WHEN r.rk % 17 = 0        THEN 'cancelled'
         WHEN r.rk % 13 = 0        THEN 'suspended'
         ELSE 'confirmed'
       END::enrollment_status
FROM ranqueado r
WHERE r.rk <= CASE WHEN r.code = 'TABD-N1'
                   THEN 7                               -- 7 de 8 seats: sobra 1
                   ELSE LEAST((r.seats * 3) / 4, 28) END;

-- ============================================================================
-- 12. AVALIAÇÕES E NOTAS  [E14]
--     Onde antes havia nota_a1/nota_a2/nota_p3 em historico (colunas fixas,
--     violação de 1FN disfarçada), agora há avaliacao × nota. Pesos das
--     avaliações REGULARES somam 10; a substitutiva não entra na soma —
--     ela SUBSTITUI a de menor nota, que é a regra da P3 do modelo original.
-- ============================================================================
INSERT INTO tb_assessment (section_id, name, weight, assessment_date, is_makeup)
SELECT t.section_id, v.name, v.weight,
       pl.start_date + v.day, v.is_makeup
FROM tb_section t
JOIN tb_academic_term pl ON pl.academic_term_id = t.academic_term_id
CROSS JOIN (VALUES
  ('A1', 4.00,  60, false),
  ('A2', 6.00, 120, false),
  ('P3', 6.00, 135, true)
) AS v(name, weight, day, is_makeup);

-- Notas: só para períodos ENCERRADOS (< 2026/2) e matrículas confirmadas.
-- As fórmulas são as mesmas da carga anterior — a média continua reproduzível.
INSERT INTO tb_grade (assessment_id, enrollment_id, section_id, value)
SELECT av.assessment_id, m.enrollment_id, m.section_id,
       CASE av.name
         WHEN 'A1' THEN round((3   + ((m.student_id * 37 + m.section_id * 11) % 71) / 10.0)::numeric, 1)
         WHEN 'A2' THEN round((3.5 + ((m.student_id * 29 + m.section_id * 13) % 66) / 10.0)::numeric, 1)
         ELSE           round((4   + ((m.student_id * 41 + m.section_id * 7)  % 56) / 10.0)::numeric, 1)
       END
FROM tb_enrollment m
JOIN tb_section tu          ON tu.section_id = m.section_id
JOIN tb_academic_term pl ON pl.academic_term_id = tu.academic_term_id
                      AND (pl.year, pl.semester) < (2026, 2)
JOIN tb_assessment av      ON av.section_id = m.section_id
WHERE m.status = 'confirmed'
  AND (
    NOT av.is_makeup                       -- A1 e A2 para todos
    OR (                                                -- P3 só para quem precisa
      (0.4 * round((3   + ((m.student_id * 37 + m.section_id * 11) % 71) / 10.0)::numeric, 1)
     + 0.6 * round((3.5 + ((m.student_id * 29 + m.section_id * 13) % 66) / 10.0)::numeric, 1)) < 5
      AND m.student_id % 3 <> 0
    )
  );

-- ============================================================================
-- 13. AULAS E PRESENÇAS  [E13]
--     A frequência deixou de ser um número digitado: ela EMERGE das presenças.
--     Aula pula feriado — a regra que o modelo do professor não conseguia
--     expressar porque não tinha aula nenhuma.
-- ============================================================================
INSERT INTO tb_class_meeting (section_schedule_id, syllabus_unit_id, section_id, topic, meeting_date, was_held)
SELECT th.section_schedule_id, u.syllabus_unit_id, th.section_id,
       'Encontro ' || dt.n || ' — ' || d.code,
       dt.date, true
FROM tb_section_schedule th
JOIN tb_section t           ON t.section_id = th.section_id
JOIN tb_course d      ON d.course_id = t.course_id
JOIN tb_academic_term pl ON pl.academic_term_id = th.academic_term_id
CROSS JOIN LATERAL (
  -- 18 semanas a partir do primeiro day da semana pedido pelo horário
  SELECT row_number() OVER (ORDER BY g.d) AS n, g.d AS date
  FROM generate_series(
         pl.start_date
           + ((th.weekday - EXTRACT(ISODOW FROM pl.start_date)::int + 7) % 7),
         pl.end_date, interval '7 days') AS g(d)
  LIMIT 18
) dt
LEFT JOIN LATERAL (                                  -- distribui as 4 unidades
  SELECT ue.syllabus_unit_id
  FROM tb_syllabus pe
  JOIN tb_syllabus_unit ue ON ue.syllabus_id = pe.syllabus_id
  WHERE pe.course_id = t.course_id AND pe.section_id IS NULL
    AND ue.position = LEAST(4, 1 + ((dt.n - 1) / 5))
  LIMIT 1
) u ON true
WHERE NOT EXISTS (                                   -- não há aula em feriado
  SELECT 1 FROM tb_holiday f
  WHERE f.holiday_date = dt.date AND NOT f.is_optional
);

-- Presenças: toda matrícula confirmada em toda aula da sua turma.
-- A falta é determinística e é ela que produz a frequência. Dois regimes de
-- propósito: a maioria falta ~5% (aprova por frequência) e um em cada 11
-- alunos falta ~33% — abaixo dos 75% exigidos. É esse grupo que faz existir
-- a situação 'failed_attendance', usada pelas consultas 4 e 10.
INSERT INTO tb_attendance (class_meeting_id, enrollment_id, section_id, was_present, is_excused)
SELECT a.class_meeting_id, m.enrollment_id, m.section_id,
       CASE WHEN m.student_id % 11 = 0
            THEN ((m.student_id * 7 + a.class_meeting_id * 3) % 3)  <> 0
            ELSE ((m.student_id * 7 + a.class_meeting_id * 3) % 20) <> 0 END,
       CASE WHEN m.student_id % 11 = 0
            THEN ((m.student_id * 7 + a.class_meeting_id * 3) % 3)  = 0 AND (m.student_id % 4 = 0)
            ELSE ((m.student_id * 7 + a.class_meeting_id * 3) % 20) = 0 AND (m.student_id % 4 = 0) END
FROM tb_class_meeting a
JOIN tb_enrollment m       ON m.section_id = a.section_id AND m.status = 'confirmed'
JOIN tb_section t           ON t.section_id = a.section_id
JOIN tb_academic_term pl ON pl.academic_term_id = t.academic_term_id
                      AND (pl.year, pl.semester) < (2026, 2);

-- ============================================================================
-- 14. HISTÓRICO CONSOLIDADO  [E14]
--     historico não guarda mais nota nem frequência: guarda a SITUAÇÃO e a
--     date de fechamento. Média e frequência são derivadas de nota/presenca —
--     é esse o custo assumido da ampliação, e a MV do 04_views.sql é a
--     resposta a ele.
-- ============================================================================
INSERT INTO tb_academic_record (enrollment_id, closed_on, outcome)
SELECT m.enrollment_id,
       CASE WHEN x.is_closed THEN pl.end_date END,
       CASE
         WHEN m.status = 'suspended' THEN 'suspended'
         WHEN NOT x.is_closed                 THEN 'in_progress'
         WHEN x.attendance < 75                     THEN 'failed_attendance'
         WHEN x.avg_grade >= 5                    THEN 'passed'
         ELSE 'failed_grade'
       END::academic_outcome
FROM tb_enrollment m
JOIN tb_section tu          ON tu.section_id = m.section_id
JOIN tb_academic_term pl ON pl.academic_term_id = tu.academic_term_id
-- média e frequência vêm da MESMA view que as consultas usam
-- (desempenho_matricula, criada no 01_ddl.sql [E14]): a regra da
-- substitutiva não pode divergir entre a carga e o relatório.
LEFT JOIN vw_enrollment_performance dm ON dm.enrollment_id = m.enrollment_id
CROSS JOIN LATERAL (
  SELECT (pl.year, pl.semester) < (2026, 2) AS is_closed,
         dm.final_grade AS avg_grade,
         dm.attendance_rate  AS attendance
) AS x
WHERE m.status <> 'cancelled';

-- ============================================================================
-- 15. APROVEITAMENTO DE MATÉRIA  [E15]
--     Dispensa por estudo anterior: entra como 2ª via de "pode cursar".
--     Um caso de cada status, para as consultas terem o que mostrar.
-- ============================================================================
INSERT INTO tb_credit_transfer (student_id, course_id, reviewer_id,
       source_course, source_institution,
       review_note, source_hours,
       source_grade, requested_on,
       decided_on, status)
SELECT a.student_id, d.course_id, u.app_user_id,
       'Introdução à ' || d.name,
       (ARRAY['UnB','UFG','IFB','UCB','Unip'])[1 + a.student_id % 5],
       CASE v.status
         WHEN 'approved'   THEN 'Ementa e carga horária compatíveis (>= 75%). Deferido.'
         WHEN 'denied' THEN 'Carga horária insuficiente frente à disciplina de destino.'
         ELSE NULL END,
       CASE v.status WHEN 'denied' THEN 30 ELSE d.total_hours END,
       CASE v.status WHEN 'denied' THEN 6.0 ELSE 8.5 END,
       DATE '2026-01-20',
       CASE WHEN v.status = 'pending' THEN NULL ELSE DATE '2026-02-10' END,
       v.status::credit_transfer_status
FROM (VALUES
  ('ETI',  'approved',   1), ('EMP',  'approved',   2), ('MAT1', 'approved',   3),
  ('SIG',  'denied', 4), ('EST1', 'denied', 5),
  ('WEB1', 'pending',   6), ('GPI',  'pending',   7), ('ALG1', 'pending',   8)
) AS v(course_code, status, position)
JOIN tb_course d ON d.code = v.course_code
JOIN LATERAL (
  SELECT student_id FROM tb_student WHERE status = 'active'
  ORDER BY (student_id * 13 + v.position) % 97, student_id LIMIT 1
) a ON true
LEFT JOIN tb_app_user u ON u.login = 'registrar'
ON CONFLICT (student_id, course_id) DO NOTHING;

-- ============================================================================
-- 16. AUDITORIA  [C11] [E4]
--     [E19] A carga NÃO insere no street: os triggers de auditoria já gravaram
--     uma linha por INSERT em pessoa, aluno, matricula, nota e
--     historico enquanto os blocos acima rodavam. Inserir à mão aqui
--     duplicaria a trilha — e a diferença entre "a aplicação lembrou de logar"
--     e "o banco logou" é justamente o ponto da mudança.
-- ============================================================================

COMMIT;

-- ============================================================================
-- Verificação: falha ruidosamente se os mínimos do enunciado não forem atingidos
-- ou se um dos cenários plantados tiver sido corrompido.
-- ============================================================================
DO $$
DECLARE
  n_alunos int; n_turmas int; n_matriculas int; n_vagas_tabd int;
  n_notas int; n_presencas int; n_aulas int; n_comp1 int; n_ead int;
BEGIN
  SELECT count(*) INTO n_alunos     FROM tb_student;
  SELECT count(*) INTO n_turmas     FROM tb_section;
  SELECT count(*) INTO n_matriculas FROM tb_enrollment;
  SELECT count(*) INTO n_notas      FROM tb_grade;
  SELECT count(*) INTO n_presencas  FROM tb_attendance;
  SELECT count(*) INTO n_aulas      FROM tb_class_meeting;
  SELECT t.seats - count(m.enrollment_id) FILTER (WHERE m.status = 'confirmed')
    INTO n_vagas_tabd
  FROM tb_section t LEFT JOIN tb_enrollment m ON m.section_id = t.section_id
  WHERE t.code = 'TABD-N1' GROUP BY t.seats;
  SELECT count(*) INTO n_comp1 FROM tb_enrollment m JOIN tb_section t ON t.section_id = m.section_id
   WHERE t.code = 'COMP1-N1';
  SELECT count(*) INTO n_ead FROM tb_section_schedule th JOIN tb_section t ON t.section_id = th.section_id
   WHERE t.code = 'LBD2-N1' AND th.room_id IS NULL;

  IF n_alunos     < 100 THEN RAISE EXCEPTION 'Carga insuficiente: % alunos (mínimo 100)', n_alunos; END IF;
  IF n_turmas     < 6   THEN RAISE EXCEPTION 'Carga insuficiente: % turmas (mínimo 6)', n_turmas; END IF;
  IF n_matriculas < 300 THEN RAISE EXCEPTION 'Carga insuficiente: % matrículas (mínimo 300)', n_matriculas; END IF;
  IF n_vagas_tabd <> 1  THEN RAISE EXCEPTION 'Cenário da última vaga quebrado: TABD-N1 com % vagas livres (esperado 1)', n_vagas_tabd; END IF;
  IF n_comp1 <> 0       THEN RAISE EXCEPTION 'Cenário da junção externa quebrado: COMP1-N1 tem % matrículas (esperado 0)', n_comp1; END IF;
  IF n_ead   <  1       THEN RAISE EXCEPTION 'Cenário EAD quebrado: LBD2-N1 sem horário de sala NULL'; END IF;
  IF n_notas      < 500 THEN RAISE EXCEPTION 'Poucas notas: %', n_notas; END IF;
  IF NOT EXISTS (SELECT 1 FROM tb_academic_record WHERE outcome = 'failed_attendance')
    THEN RAISE EXCEPTION 'Cenário de frequência quebrado: ninguém reprovou por falta'; END IF;
  IF n_presencas  < 5000 THEN RAISE EXCEPTION 'Poucas presenças: %', n_presencas; END IF;

  RAISE NOTICE 'Carga OK: % alunos, % turmas, % matrículas, % aulas, % presenças, % notas.',
    n_alunos, n_turmas, n_matriculas, n_aulas, n_presencas, n_notas;
  RAISE NOTICE 'Cenários intactos: TABD-N1 com 1 vaga livre, COMP1-N1 vazia, LBD2-N1 EAD sem sala.';
END $$;

\echo '=== Resumo da carga (41 tabelas) ==='
SELECT 'tb_country' AS tabela, count(*) FROM tb_country                          UNION ALL
SELECT 'tb_state',            count(*) FROM tb_state                     UNION ALL
SELECT 'tb_city',            count(*) FROM tb_city                     UNION ALL
SELECT 'tb_address',          count(*) FROM tb_address                   UNION ALL
SELECT 'tb_person',            count(*) FROM tb_person                     UNION ALL
SELECT 'tb_phone',          count(*) FROM tb_phone                   UNION ALL
SELECT 'tb_person_document',  count(*) FROM tb_person_document           UNION ALL
SELECT 'tb_app_user',           count(*) FROM tb_app_user                    UNION ALL
SELECT 'tb_campus',            count(*) FROM tb_campus                     UNION ALL
SELECT 'tb_department',      count(*) FROM tb_department               UNION ALL
SELECT 'tb_building',            count(*) FROM tb_building                     UNION ALL
SELECT 'tb_room',              count(*) FROM tb_room                       UNION ALL
SELECT 'tb_resource',           count(*) FROM tb_resource                    UNION ALL
SELECT 'tb_room_resource',      count(*) FROM tb_room_resource               UNION ALL
SELECT 'tb_professor',         count(*) FROM tb_professor                  UNION ALL
SELECT 'tb_professor_degree',count(*) FROM tb_professor_degree         UNION ALL
SELECT 'tb_program',             count(*) FROM tb_program                      UNION ALL
SELECT 'tb_program_coordination', count(*) FROM tb_program_coordination          UNION ALL
SELECT 'tb_curriculum',         count(*) FROM tb_curriculum                  UNION ALL
SELECT 'tb_course',        count(*) FROM tb_course                 UNION ALL
SELECT 'tb_curriculum_course', count(*) FROM tb_curriculum_course    UNION ALL
SELECT 'tb_prerequisite',     count(*) FROM tb_prerequisite              UNION ALL
SELECT 'tb_student',             count(*) FROM tb_student                      UNION ALL
SELECT 'tb_credit_transfer', count(*) FROM tb_credit_transfer UNION ALL
SELECT 'tb_academic_term',    count(*) FROM tb_academic_term             UNION ALL
SELECT 'tb_enrollment_window', count(*) FROM tb_enrollment_window          UNION ALL
SELECT 'tb_holiday',           count(*) FROM tb_holiday                    UNION ALL
SELECT 'tb_section',             count(*) FROM tb_section                      UNION ALL
SELECT 'tb_section_professor',   count(*) FROM tb_section_professor            UNION ALL
SELECT 'tb_section_schedule',     count(*) FROM tb_section_schedule              UNION ALL
SELECT 'tb_syllabus',      count(*) FROM tb_syllabus               UNION ALL
SELECT 'tb_syllabus_unit', count(*) FROM tb_syllabus_unit    UNION ALL
SELECT 'tb_bibliography',      count(*) FROM tb_bibliography               UNION ALL
SELECT 'tb_syllabus_bibliography', count(*) FROM tb_syllabus_bibliography UNION ALL
SELECT 'tb_enrollment',         count(*) FROM tb_enrollment                  UNION ALL
SELECT 'tb_academic_record',         count(*) FROM tb_academic_record                  UNION ALL
SELECT 'log_matricula',     count(*) FROM tb_audit_log              UNION ALL
SELECT 'tb_class_meeting',              count(*) FROM tb_class_meeting                       UNION ALL
SELECT 'tb_attendance',          count(*) FROM tb_attendance                   UNION ALL
SELECT 'tb_assessment',         count(*) FROM tb_assessment                  UNION ALL
SELECT 'tb_grade',              count(*) FROM tb_grade
ORDER BY tabela;
