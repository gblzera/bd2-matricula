-- ============================================================================
-- 01_schema.sql — schema (41 tables)
-- College · English mirror of the Brazilian academic model
--
-- GENERATED FILE — do not edit by hand.
--   source: sql/01_ddl.sql   (Portuguese, the single source of truth)
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
-- 01_ddl.sql — DDL completo do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- O modelo do professor é a BASE (16 tabelas, correções [C1]–[C15]); a ampliação
-- [E1]–[E15] foi modelada em docs/esboco-schema-ampliado.md, revisada e validada
-- em banco descartável. Cada decisão é marcada no ponto em que vira DDL.
--
-- Ordem de colunas (padrão exigido): PK, FK, varchar, text, char, inteiros,
-- decimais — e depois date/hora e ranges, boolean, ENUM, jsonb.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d <banco> < sql/01_ddl.sql
-- Idempotente: recria o schema academic do zero a cada execução.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- [C15] Schema próprio; reset barato e de escopo restrito.
DROP SCHEMA IF EXISTS academic CASCADE;
CREATE SCHEMA academic;
SET search_path TO academic, public;

-- [C10] igualdade escalar + && numa mesma restrição de exclusão GiST.
-- [C15] A extensão fica em public: sobrevive ao DROP SCHEMA academic.
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

-- ============================================================================
-- 1. TIPOS E DOMÍNIOS  [C12]
--    ENUM para conjunto fechado de rótulos; DOMAIN para faixa ou formato.
-- ============================================================================

-- [C1] range de TIME não existe nativamente; semester isto turma_horario não compila.
CREATE TYPE timerange AS RANGE (subtype = time);

-- [E16] DIVERGÊNCIA DELIBERADA do modelo do professor, que traz três turnos
-- ('MATUTINO','VESPERTINO','NOTURNO'). Esta instituição opera em DOIS: manhã e
-- noite. Rótulo que o domínio não usa é rótulo que um day entra por engano —
-- o ENUM existe justamente para fechar o conjunto no valor certo, e um valor a
-- mais enfraquece a garantia. A base do professor segue com os três em
-- docs/modelo-fisico.html, que documenta o ponto de partida.
CREATE TYPE shift                AS ENUM ('morning', 'evening');
CREATE TYPE room_type            AS ENUM ('lecture', 'lab', 'auditorium');
-- [E17] prerequisite_link removido: semester co-requisito, o kind ficaria semester uso.
CREATE TYPE requirement_type            AS ENUM ('required', 'elective', 'free_elective');
CREATE TYPE enrollment_status           AS ENUM ('pending', 'confirmed', 'suspended', 'cancelled');
CREATE TYPE academic_outcome             AS ENUM ('in_progress', 'passed', 'failed_grade',
                                            'failed_attendance', 'suspended');
-- [E2..E15] tipos novos da ampliação
CREATE TYPE phone_type        AS ENUM ('mobile', 'home', 'work');
CREATE TYPE document_type       AS ENUM ('id_card', 'passport', 'drivers_license', 'foreign_id');  -- CPF fica em pessoa [E2]
CREATE TYPE user_role        AS ENUM ('aluno', 'registrar', 'coordinator', 'admin');
CREATE TYPE work_regime     AS ENUM ('hourly', 'part_time', 'full_time');
CREATE TYPE degree_level            AS ENUM ('bachelor', 'specialization', 'master',
                                            'doctorate', 'postdoc');
CREATE TYPE admission_type       AS ENUM ('entrance_exam', 'national_exam', 'transfer', 'second_degree');
CREATE TYPE student_status         AS ENUM ('active', 'suspended', 'graduated', 'dropped_out', 'dismissed');
CREATE TYPE degree_type           AS ENUM ('bachelor', 'teaching_degree', 'associate');
CREATE TYPE delivery_mode           AS ENUM ('on_campus', 'online', 'hybrid');
CREATE TYPE teaching_role        AS ENUM ('lead', 'assistant', 'substitute');
CREATE TYPE enrollment_window_type AS ENUM ('matricula', 'adjustment', 'withdrawal', 're_enrollment');
CREATE TYPE meeting_type            AS ENUM ('lecture', 'lab_session');
CREATE TYPE reference_type    AS ENUM ('core', 'supplementary');
CREATE TYPE credit_transfer_status AS ENUM ('pending', 'approved', 'denied');
CREATE TYPE log_action             AS ENUM ('insert', 'update', 'delete');

CREATE DOMAIN grade_value AS numeric(4,2) CHECK (VALUE >= 0 AND VALUE <= 10);
CREATE DOMAIN percentage  AS numeric(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN cpf  AS char(11)     CHECK (VALUE ~ '^[0-9]{11}$');

-- ============================================================================
-- 2. GEOGRAFIA  [E1]
--    Tira "Brasília" de string repetida: cidade→estado→país com dedup por nível.
-- ============================================================================

CREATE TABLE tb_country (
  country_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name  varchar(60) NOT NULL UNIQUE,
  iso_code char(2)     NOT NULL UNIQUE                          -- ISO 3166-1
);
COMMENT ON TABLE tb_country IS 'Países [E1].';

CREATE TABLE tb_state (
  state_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_id     smallint    NOT NULL REFERENCES tb_country (country_id),
  name varchar(60) NOT NULL,
  abbreviation   char(2)     NOT NULL,
  CONSTRAINT uq_state_country_uf UNIQUE (country_id, abbreviation)
);
COMMENT ON TABLE tb_state IS 'Unidades federativas [E1].';

CREATE TABLE tb_city (
  city_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  state_id          smallint    NOT NULL REFERENCES tb_state (state_id),
  name        varchar(80) NOT NULL,
  ibge_code char(7)     UNIQUE,
  CONSTRAINT uq_city_state_name UNIQUE (state_id, name)
);
COMMENT ON TABLE tb_city IS 'Municípios; "Brasilia" ≠ "BRASÍLIA" morre aqui [E1].';

CREATE TABLE tb_address (
  address_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  city_id            integer      NOT NULL REFERENCES tb_city (city_id),
  street  varchar(120) NOT NULL,
  number      varchar(10),                               -- varchar: "s/n"
  complement varchar(60),
  district      varchar(60),
  postal_code         char(8) CHECK (postal_code ~ '^[0-9]{8}$')
);
COMMENT ON TABLE tb_address IS 'Endereços de pessoas e campi [E1].';

-- ============================================================================
-- 3. PESSOAS  [E2] [E3]
--    pessoa é o supertipo; aluno e professor são especializações 1:1 e não
--    exclusivas (um professor pode ser aluno de outro curso).
-- ============================================================================

CREATE TABLE tb_person (
  person_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  address_id       integer REFERENCES tb_address (address_id),
  name       varchar(120) NOT NULL,
  email      varchar(120) NOT NULL UNIQUE CHECK (position('@' in email) > 1),
  -- [E2] CPF é 1:1 com a pessoa no Brasil: fica AQUI, obrigatório, preservando
  -- [C12]. documento_pessoa guarda os demais documentos (multivalorados).
  cpf        cpf NOT NULL UNIQUE,
  birth_date date  NOT NULL
);
COMMENT ON TABLE tb_person IS 'Supertipo de aluno e professor [E2]; nome/e-mail/CPF vivem só aqui.';

CREATE TABLE tb_phone (
  phone_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id          integer     NOT NULL REFERENCES tb_person (person_id) ON DELETE CASCADE,
  number    varchar(20) NOT NULL,
  is_primary boolean     NOT NULL DEFAULT false,
  phone_type      phone_type NOT NULL,
  CONSTRAINT uq_phone_person_numero UNIQUE (person_id, number)
);
COMMENT ON TABLE tb_phone IS 'Multivalorado → tabela (1FN) [E3]. Um principal por pessoa: índice parcial.';
-- só um telefone principal por pessoa (validado em banco descartável)
CREATE UNIQUE INDEX uq_phone_primary ON tb_phone (person_id) WHERE is_primary;

CREATE TABLE tb_person_document (
  person_document_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id                integer     NOT NULL REFERENCES tb_person (person_id) ON DELETE CASCADE,
  number  varchar(20) NOT NULL,
  issuer   varchar(20),
  issued_on date,
  document_type    document_type NOT NULL,
  -- o mesmo documento não pode pertencer a duas pessoas…
  CONSTRAINT uq_document_type_numero UNIQUE (document_type, number),
  -- …e uma pessoa tem no máximo um documento de cada kind
  CONSTRAINT uq_document_person_type UNIQUE (person_id, document_type)
);
COMMENT ON TABLE tb_person_document IS 'Documentos além do CPF [E3]; CPF mora em pessoa [E2].';

CREATE TABLE tb_app_user (
  app_user_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id     integer     NOT NULL UNIQUE REFERENCES tb_person (person_id),
  login varchar(60) NOT NULL UNIQUE,     -- = name da ROLE no PostgreSQL [E4]
  is_active boolean     NOT NULL DEFAULT true,
  role user_role NOT NULL
);
COMMENT ON TABLE tb_app_user IS 'Conta de acesso; login = ROLE do Postgres, casa com a RLS al_<RA> [E4].';

-- ============================================================================
-- 4. ESTRUTURA FÍSICA E ORGANIZACIONAL  [E5] [E6]
-- ============================================================================

CREATE TABLE tb_campus (
  campus_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE honra a cardinalidade (0,1) do lado do endereço (achado F1 da revisão)
  address_id integer     NOT NULL UNIQUE REFERENCES tb_address (address_id),
  name varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_campus IS 'Campi; cidade_campus saiu — vem de endereco→cidade [E1].';

CREATE TABLE tb_department (
  department_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id          smallint    NOT NULL REFERENCES tb_campus (campus_id),
  head_professor_id integer,       -- FK circular com professor: constraint via ALTER, adiante [E6]
  name  varchar(80) NOT NULL,
  abbreviation varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_department IS 'Departamentos; chefe é FK circular resolvida por ALTER [E6].';

CREATE TABLE tb_building (
  building_id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id      smallint    NOT NULL REFERENCES tb_campus (campus_id),
  name    varchar(60) NOT NULL,
  floor_count smallint CHECK (floor_count > 0),
  CONSTRAINT uq_building_campus_name UNIQUE (campus_id, name)
);
COMMENT ON TABLE tb_building IS 'Prédios do campus [E5].';

CREATE TABLE tb_room (
  room_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E5] sala muda de dono: o campus vem via prédio. [C4] evolui junto:
  -- código único DENTRO do prédio (prédios do mesmo campus podem repetir).
  building_id       smallint    NOT NULL REFERENCES tb_building (building_id),
  code     varchar(10) NOT NULL,
  floor      smallint,
  capacity smallint    NOT NULL CHECK (capacity > 0),
  room_type       room_type NOT NULL DEFAULT 'lecture',
  CONSTRAINT uq_room_building_code UNIQUE (building_id, code)   -- [C4→E5]
);
COMMENT ON TABLE tb_room IS 'Salas físicas, por prédio [E5]; [C4] agora por prédio.';

CREATE TABLE tb_resource (
  resource_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_resource IS 'Recursos alocáveis (projetor, bancada…) [E3].';

CREATE TABLE tb_room_resource (
  room_id                 integer  NOT NULL REFERENCES tb_room (room_id) ON DELETE CASCADE,
  resource_id              smallint NOT NULL REFERENCES tb_resource (resource_id),
  quantity smallint NOT NULL DEFAULT 1 CHECK (quantity > 0),
  PRIMARY KEY (room_id, resource_id)
);
COMMENT ON TABLE tb_room_resource IS 'N:N sala×recurso — o critério para alocar laboratório [E3].';

CREATE TABLE tb_professor (
  professor_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id           integer     NOT NULL UNIQUE REFERENCES tb_person (person_id),
  department_id     smallint    NOT NULL REFERENCES tb_department (department_id),
  employee_number varchar(12) NOT NULL UNIQUE,
  work_regime    work_regime NOT NULL,
  degree_level degree_level NOT NULL
);
COMMENT ON TABLE tb_professor IS 'Especialização 1:1 de pessoa [E2]; só o que é vínculo de trabalho.';

-- [E6] a FK circular departamento↔professor entra agora, com UNIQUE (F4: um
-- professor chefia no máximo um departamento; UNIQUE aceita vários NULLs).
ALTER TABLE tb_department
  ADD CONSTRAINT fk_department_head
      FOREIGN KEY (head_professor_id) REFERENCES tb_professor (professor_id),
  ADD CONSTRAINT uq_department_head UNIQUE (head_professor_id);

CREATE TABLE tb_professor_degree (
  professor_degree_id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  professor_id                     integer      NOT NULL REFERENCES tb_professor (professor_id) ON DELETE CASCADE,
  program_name         varchar(120) NOT NULL,
  institution   varchar(120) NOT NULL,
  completion_year smallint     NOT NULL CHECK (completion_year BETWEEN 1950 AND 2100),
  degree_level     degree_level  NOT NULL,
  CONSTRAINT uq_degree_prof UNIQUE (professor_id, program_name, institution)
);
COMMENT ON TABLE tb_professor_degree IS 'Formações (multivalorado, 1FN) [E3]; a titulação declarada fica em professor.';

-- ============================================================================
-- 5. ESTRUTURA ACADÊMICA  [E7] [E8] [E15]
-- ============================================================================

CREATE TABLE tb_program (
  program_id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id       smallint     NOT NULL REFERENCES tb_campus (campus_id),
  department_id smallint     NOT NULL REFERENCES tb_department (department_id),
  code    varchar(10)  NOT NULL UNIQUE,
  name      varchar(120) NOT NULL,
  total_hours  integer      NOT NULL CHECK (total_hours > 0),
  degree_type      degree_type NOT NULL,          -- era varchar+CHECK: rótulo fechado ⇒ ENUM [C12]
  delivery_mode delivery_mode NOT NULL DEFAULT 'on_campus'
);
COMMENT ON TABLE tb_program IS 'Cursos; ganham departamento [E6] e modalidade.';

CREATE TABLE tb_program_coordination (
  program_coordination_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id                   smallint    NOT NULL REFERENCES tb_program (program_id),
  professor_id               integer     NOT NULL REFERENCES tb_professor (professor_id),
  appointment_ref varchar(30),
  validity daterange   NOT NULL CHECK (NOT isempty(validity)),
  -- [E8] um coordenador por curso a cada instante — técnica de [C10], semester trigger.
  -- Vigência aberta: daterange(inicio, NULL). Validado em banco descartável.
  CONSTRAINT ex_coordination_validity EXCLUDE USING gist
    (program_id WITH =, validity WITH &&)
);
COMMENT ON TABLE tb_program_coordination IS 'Mandatos de coordenação; EXCLUDE de vigência [E8].';

CREATE TABLE tb_curriculum (
  curriculum_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id               smallint    NOT NULL REFERENCES tb_program (program_id),
  approval_ref     varchar(30),
  effective_year smallint    NOT NULL CHECK (effective_year BETWEEN 1990 AND 2100),
  is_active        boolean     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculum_program_year UNIQUE (program_id, effective_year),   -- [C8]
  CONSTRAINT uq_curriculum_id_program  UNIQUE (curriculum_id, program_id)              -- alvo da FK composta [C6]
);
COMMENT ON TABLE tb_curriculum IS 'Matrizes curriculares por ano [C8]; alvo de [C6].';

CREATE TABLE tb_course (
  course_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  department_id       smallint     NOT NULL REFERENCES tb_department (department_id),
  code     varchar(10)  NOT NULL UNIQUE,
  name       varchar(120) NOT NULL,
  description     text,
  theory_hours smallint NOT NULL DEFAULT 0 CHECK (theory_hours >= 0),
  lab_hours smallint NOT NULL DEFAULT 0 CHECK (lab_hours >= 0),
  total_hours   smallint GENERATED ALWAYS AS (theory_hours + lab_hours) STORED,  -- [C13]
  CONSTRAINT ck_course_ch_positive CHECK (theory_hours + lab_hours > 0)
);
COMMENT ON TABLE tb_course IS 'Catálogo; ch_total é gerada [C13]; ementa é a descrição perene — o plano de ensino é a execução [E7].';

CREATE TABLE tb_curriculum_course (
  curriculum_id                 integer     NOT NULL REFERENCES tb_curriculum (curriculum_id) ON DELETE CASCADE,
  course_id                integer     NOT NULL REFERENCES tb_course (course_id),
  term_number smallint    NOT NULL CHECK (term_number BETWEEN 1 AND 12),
  requirement_type    requirement_type NOT NULL DEFAULT 'required',
  PRIMARY KEY (curriculum_id, course_id)
);
COMMENT ON TABLE tb_curriculum_course IS 'Grade: período sugerido de cada disciplina no currículo.';

-- [E17] O pré-requisito passa a pertencer ao CURRÍCULO, não ao catálogo.
-- Antes, "BD2 exige BD1" valia para toda matriz de uma vez; mas a cadeia é
-- decisão de cada matriz, e matrizes diferentes encadeiam diferente.
-- As DUAS chaves compostas são o ponto: exigem que a disciplina E o requisito
-- estejam ambos NAQUELE currículo. Apontar para matéria fora da matriz é
-- impossível por restrição, semester trigger — a técnica de [C6] outra vez.
-- `link` saiu a pedido: o modelo expressa só pré-requisito. Consequência
-- assumida: o co-requisito (LBD2 junto de BD2) deixa de ser representável.
-- `ch_minima_pre_requisito` saiu junto — nunca foi usado por consulta nenhuma.
CREATE TABLE tb_prerequisite (
  curriculum_id               integer NOT NULL,
  course_id              integer NOT NULL,
  required_course_id               integer NOT NULL,
  min_grade grade_value  NOT NULL DEFAULT 5.00,
  PRIMARY KEY (curriculum_id, course_id, required_course_id),
  CONSTRAINT fk_prereq_course_do_curriculum
    FOREIGN KEY (curriculum_id, course_id)
    REFERENCES tb_curriculum_course (curriculum_id, course_id) ON DELETE CASCADE,
  CONSTRAINT fk_prereq_requisite_do_curriculum
    FOREIGN KEY (curriculum_id, required_course_id)
    REFERENCES tb_curriculum_course (curriculum_id, course_id),
  CONSTRAINT ck_prereq_not_reflexive CHECK (course_id <> required_course_id)   -- [C7]
);
COMMENT ON TABLE tb_prerequisite IS 'id_disciplina EXIGE id_requisito, com média/CH mínimas por aresta; ciclos maiores: consulta recursiva [C7].';

CREATE TABLE tb_student (
  student_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id            integer     NOT NULL UNIQUE REFERENCES tb_person (person_id),
  program_id             smallint    NOT NULL REFERENCES tb_program (program_id),
  curriculum_id         integer     NOT NULL,
  -- [E18] `ingresso_aluno` saiu: o RA já carrega o year nos quatro primeiros
  -- dígitos (20240036 = 2024), então a date era determinada por ele —
  -- transitiva. Quem precisa do year lê `left(enrollment_number, 4)`.
  enrollment_number      varchar(12) NOT NULL UNIQUE,
  admission_type admission_type NOT NULL,
  status         student_status   NOT NULL DEFAULT 'active',
  -- [C6] o currículo do aluno tem que ser um currículo do curso do aluno.
  CONSTRAINT fk_student_curriculum_do_program
    FOREIGN KEY (curriculum_id, program_id) REFERENCES tb_curriculum (curriculum_id, program_id)
);
COMMENT ON TABLE tb_student IS 'Especialização 1:1 de pessoa [E2]; fica só o vínculo acadêmico. [C6] mantido.';
-- Ambiguidade HERDADA do modelo do professor, registrada para quem vier depois:
-- `enrollment_number` é o RA (identificação do aluno na instituição, uma por aluno),
-- enquanto a TABELA `tb_enrollment` é a inscrição do aluno numa turma (muitas por aluno).
-- São conceitos distintos com a mesma palavra. Renomear divergiria da convenção do
-- professor, então o name fica e a distinção é documentada aqui.
COMMENT ON COLUMN tb_student.enrollment_number IS
  'RA: identificação do aluno na instituição. NÃO confundir com a tabela matricula (inscrição em turma).';

CREATE TABLE tb_credit_transfer (
  credit_transfer_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id                                integer      NOT NULL REFERENCES tb_student (student_id),
  course_id                           integer      NOT NULL REFERENCES tb_course (course_id),
  reviewer_id                    integer      REFERENCES tb_app_user (app_user_id),
  source_course  varchar(120) NOT NULL,
  source_institution varchar(120) NOT NULL,
  review_note          text,
  source_hours        smallint NOT NULL CHECK (source_hours > 0),
  source_grade      grade_value   NOT NULL,
  requested_on      date     NOT NULL DEFAULT current_date,
  decided_on          date,
  status           credit_transfer_status NOT NULL DEFAULT 'pending',
  CONSTRAINT uq_transfer_student_disc UNIQUE (student_id, course_id)
  -- Regras de deferimento cruzam tabela (CH da disciplina, forma de ingresso):
  -- ficam na função de deferimento, não em CHECK [E15].
);
COMMENT ON TABLE tb_credit_transfer IS 'Dispensa por estudo anterior [E15]; conta em pode_cursar().';

-- ============================================================================
-- 6. TEMPO E CALENDÁRIO  [E9] [E10]
-- ============================================================================

CREATE TABLE tb_academic_term (
  academic_term_id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  year         smallint NOT NULL,
  semester    smallint NOT NULL CHECK (semester IN (1, 2)),
  start_date date     NOT NULL,
  end_date    date     NOT NULL,
  CONSTRAINT uq_term_year_semester UNIQUE (year, semester),  -- [C3]
  CONSTRAINT ck_term_dates        CHECK (start_date < end_date)
);
COMMENT ON TABLE tb_academic_term IS 'Semestres letivos [C3].';

CREATE TABLE tb_enrollment_window (
  enrollment_window_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  academic_term_id           smallint    NOT NULL REFERENCES tb_academic_term (academic_term_id),
  description varchar(60) NOT NULL,
  window_range    tstzrange   NOT NULL CHECK (NOT isempty(window_range)),
  window_type      enrollment_window_type NOT NULL,
  -- [E9] janelas do mesmo kind não se sobrepõem no período; tipos diferentes
  -- podem (ajuste cobre o ends da matrícula). ENUM em GiST: btree_gist, validado.
  CONSTRAINT ex_term_enrollment_window EXCLUDE USING gist
    (academic_term_id WITH =, window_type WITH =, window_range WITH &&)
);
COMMENT ON TABLE tb_enrollment_window IS 'QUANDO se pode matricular [E9]; a função de matrícula consulta now() <@ janela.';

CREATE TABLE tb_holiday (
  holiday_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E10] arco exclusivo: o ALCANCE do feriado é exatamente uma das 4 FKs.
  -- O ENUM de kind foi REMOVIDO de propósito: seria derivável do arco
  -- (dependência funcional kind↔FK — violaria 3FN); is_optional é ortogonal.
  country_id             smallint REFERENCES tb_country (country_id),
  state_id           smallint REFERENCES tb_state (state_id),
  city_id           integer  REFERENCES tb_city (city_id),
  campus_id           smallint REFERENCES tb_campus (campus_id),
  description   varchar(120) NOT NULL,
  holiday_date        date         NOT NULL,
  is_optional boolean      NOT NULL DEFAULT false,
  CONSTRAINT ck_holiday_arc CHECK (
    (country_id   IS NOT NULL)::int + (state_id IS NOT NULL)::int +
    (city_id IS NOT NULL)::int + (campus_id IS NOT NULL)::int = 1)
);
COMMENT ON TABLE tb_holiday IS 'Alcance pelo arco de FKs [E10]; dedup por nível preserva [C9].';
-- [C9→E10] dedup por nível: semester isto, dois feriados nacionais na mesma date
-- voltariam a passar — que era o erro original do modelo do professor.
CREATE UNIQUE INDEX uq_holiday_country_date   ON tb_holiday (country_id,   holiday_date) WHERE country_id   IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_state_date ON tb_holiday (state_id, holiday_date) WHERE state_id IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_city_date ON tb_holiday (city_id, holiday_date) WHERE city_id IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_campus_date ON tb_holiday (campus_id, holiday_date) WHERE campus_id IS NOT NULL;

-- ============================================================================
-- 7. OFERTA E DOCÊNCIA  [E11] [E12]
-- ============================================================================

CREATE TABLE tb_section (
  section_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  course_id     integer     NOT NULL REFERENCES tb_course (course_id),
  academic_term_id smallint    NOT NULL REFERENCES tb_academic_term (academic_term_id),
  code      varchar(15) NOT NULL,
  seats       smallint    NOT NULL CHECK (seats >= 0),
  shift       shift     NOT NULL,
  delivery_mode  delivery_mode NOT NULL DEFAULT 'on_campus',
  CONSTRAINT uq_section_term_code UNIQUE (academic_term_id, code),  -- [C5]
  CONSTRAINT uq_section_id_term     UNIQUE (section_id, academic_term_id),      -- alvo de [C10]
  CONSTRAINT uq_section_id_course  UNIQUE (section_id, course_id)           -- alvo de [E7]
  -- professor_id SAIU → turma_professor [E11] (co-docência)
);
COMMENT ON TABLE tb_section IS 'Oferta; professor foi para turma_professor [E11].';

CREATE TABLE tb_section_professor (
  section_id              integer  NOT NULL REFERENCES tb_section (section_id),
  professor_id          integer  NOT NULL REFERENCES tb_professor (professor_id),
  hours    smallint CHECK (hours > 0),
  teaching_role teaching_role NOT NULL DEFAULT 'lead',
  PRIMARY KEY (section_id, professor_id)
);
COMMENT ON TABLE tb_section_professor IS 'Co-docência [E11]; um titular por turma via índice parcial.';
CREATE UNIQUE INDEX uq_section_prof_lead ON tb_section_professor (section_id)
  WHERE teaching_role = 'lead';

CREATE TABLE tb_section_schedule (
  section_schedule_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_id                 integer  NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da turma via FK composta.
  academic_term_id        smallint NOT NULL,
  -- [E12] sala ANULÁVEL: turma EAD tem horário semester sala física.
  room_id                  integer  REFERENCES tb_room (room_id),
  weekday smallint  NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  time_range      timerange NOT NULL CHECK (NOT isempty(time_range)),   -- [C1]
  meeting_type  meeting_type NOT NULL DEFAULT 'lecture',
  CONSTRAINT fk_schedule_section_term
    FOREIGN KEY (section_id, academic_term_id)
    REFERENCES tb_section (section_id, academic_term_id) ON DELETE CASCADE,
  CONSTRAINT uq_schedule_id_section UNIQUE (section_schedule_id, section_id),   -- alvo de [E13]
  -- [C10] choque de sala só para quem TEM sala (EXCLUDE parcial, validado) [E12]
  CONSTRAINT ex_room_no_conflict EXCLUDE USING gist (
    academic_term_id WITH =, room_id WITH =, weekday WITH =,
    time_range WITH &&) WHERE (room_id IS NOT NULL),
  -- [C10] a própria turma não se sobrepõe, com ou semester sala
  CONSTRAINT ex_section_no_conflict EXCLUDE USING gist (
    section_id WITH =, weekday WITH =, time_range WITH &&)
);
COMMENT ON TABLE tb_section_schedule IS 'Encontros semanais; sala NULL = EAD [E12]; alvo de [E13].';

-- ============================================================================
-- 8. PLANO DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA; a turma pode ter a sua versão.
--    section_id NULL  = plano base da disciplina;
--    section_id preenchido = versão daquela oferta.
-- ============================================================================

CREATE TABLE tb_syllabus (
  syllabus_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  course_id                   integer NOT NULL,
  section_id                        integer,
  objective           text NOT NULL,
  methodology        text,
  grading_criteria text,
  approved_on          date,
  CONSTRAINT fk_syllabus_course FOREIGN KEY (course_id) REFERENCES tb_course (course_id),
  -- [E7] técnica de [C9]: um único plano base (turma NULL) e no máximo uma
  -- versão por turma.
  CONSTRAINT uq_syllabus_course_section UNIQUE NULLS NOT DISTINCT (course_id, section_id),
  -- [E7] técnica de [C6]: a versão só pode pendurar numa turma DESSA disciplina.
  -- (com section_id NULL a FK composta não é avaliada — MATCH SIMPLE — e o plano
  -- base passa; preenchida, o par é validado contra turma.)
  CONSTRAINT fk_syllabus_section_da_course
    FOREIGN KEY (section_id, course_id) REFERENCES tb_section (section_id, course_id)
);
COMMENT ON TABLE tb_syllabus IS 'Da disciplina, com versão opcional por turma [E7]: técnicas de [C9] e [C6].';

CREATE TABLE tb_syllabus_unit (
  syllabus_unit_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  syllabus_id                integer      NOT NULL REFERENCES tb_syllabus (syllabus_id) ON DELETE CASCADE,
  title    varchar(120) NOT NULL,
  content  text,
  position     smallint NOT NULL CHECK (position > 0),
  hours        smallint NOT NULL CHECK (hours > 0),
  CONSTRAINT uq_unit_syllabus_position UNIQUE (syllabus_id, position)
);
COMMENT ON TABLE tb_syllabus_unit IS 'Unidades do plano; soma de CH ≤ CH da disciplina fica em função [E7].';

CREATE TABLE tb_bibliography (
  bibliography_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title  varchar(200) NOT NULL,
  author   varchar(120) NOT NULL,
  publisher varchar(80),
  isbn    char(13) UNIQUE,
  year     smallint CHECK (year BETWEEN 1800 AND 2100),
  edition  smallint CHECK (edition > 0)
);
COMMENT ON TABLE tb_bibliography IS 'Obras; N:N com plano via plano_ensino_bibliografia.';

CREATE TABLE tb_syllabus_bibliography (
  syllabus_id               integer NOT NULL REFERENCES tb_syllabus (syllabus_id) ON DELETE CASCADE,
  bibliography_id               integer NOT NULL REFERENCES tb_bibliography (bibliography_id),
  reference_type reference_type NOT NULL,
  PRIMARY KEY (syllabus_id, bibliography_id)
);
COMMENT ON TABLE tb_syllabus_bibliography IS 'Básica × complementar por plano.';

-- ============================================================================
-- 9. MATRÍCULA E HISTÓRICO  [C2] [C11] [E14]
-- ============================================================================

CREATE TABLE tb_enrollment (
  enrollment_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         integer      NOT NULL REFERENCES tb_student (student_id),
  section_id         integer      NOT NULL REFERENCES tb_section (section_id),
  enrolled_at   timestamptz  NOT NULL DEFAULT now(),
  -- DEFAULT 'confirmed' MANTIDO (achado F9): seats conta confirmadas e a
  -- demo da última vaga depende disso; o fluxo pendente→confirmada, quando
  -- existir, muda o default junto com a função de matrícula.
  status enrollment_status NOT NULL DEFAULT 'confirmed',
  CONSTRAINT uq_enrollment_student_section UNIQUE (student_id, section_id),   -- [C2]
  CONSTRAINT uq_enrollment_id_section    UNIQUE (enrollment_id, section_id)  -- alvo de [E13]
);
COMMENT ON TABLE tb_enrollment IS 'Inscrição do aluno numa turma [C2] — uma linha por turma cursada, não confundir com aluno.matricula_aluno (o RA). Vaga consumida por confirmada; a disputa é o Marco 2.';

CREATE TABLE tb_academic_record (
  academic_record_id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  enrollment_id              integer NOT NULL UNIQUE REFERENCES tb_enrollment (enrollment_id) ON DELETE CASCADE,
  closed_on date,
  outcome        academic_outcome NOT NULL DEFAULT 'in_progress'
  -- [E14] nota_a1/a2/p3, frequência e final_grade SAÍRAM: agora derivam de
  -- nota/presenca na MV historico_consolidado (refresh ao fechar o período).
  -- Custo assumido e registrado: o GENERATED de [C13] e o índice B-tree de 46×
  -- migram para a MV — que aceita índice e REFRESH CONCURRENTLY (validado).
);
COMMENT ON TABLE tb_academic_record IS 'Consolidado 1:1 da matrícula [E14]; o registro fino vive em nota/presenca.';

-- [E19] O street deixa de ser só da matrícula e passa a ser GENÉRICO: uma linha
-- por alteração, em qualquer tabela auditada, gravada por trigger. Antes ele
-- dependia da aplicação lembrar de inserir; agora quem grava é o banco, e
-- "esquecer de logar" deixa de ser possível.
--
-- Nota para a arguição: isto NÃO contradiz o "zero triggers" do modelo. Aquilo
-- vale para trigger de VALIDAÇÃO — regra de integridade que o banco já sabe
-- declarar, e que em trigger vira código com desvio. Auditoria é o caso oposto:
-- não há forma declarativa de dizer "registre quem mudou o quê", e o trigger é
-- a ferramenta certa justamente por interceptar TODO caminho de escrita.
CREATE TABLE tb_audit_log (
  audit_log_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK para a linha auditada, de propósito: a trilha sobrevive ao
  -- expurgo do dado. Auditoria que some junto com o auditado não é auditoria.
  app_user_id          integer REFERENCES tb_app_user (app_user_id),
  table_name         name        NOT NULL,
  action            log_action  NOT NULL,
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  data_before         jsonb,
  data_after        jsonb
);
COMMENT ON TABLE tb_audit_log IS 'Trilha de auditoria gravada por trigger [E19]; sem FK para o auditado [C11].';

-- [E4] resolve a ROLE da sessão para usuario.app_user_id (NULL se não mapeada —
-- o street nunca deixa de ser gravado por causa disso).
CREATE FUNCTION f_session_user() RETURNS integer
  LANGUAGE sql STABLE
  AS $$ SELECT app_user_id FROM academic.tb_app_user WHERE login = current_user $$;
ALTER TABLE tb_audit_log ALTER COLUMN app_user_id SET DEFAULT f_session_user();

-- ============================================================================
-- 10. AULA E AVALIAÇÃO  [E13] [E14]
--     Coerência SEM trigger: section_id viaja nas junções e é amarrada por FK
--     composta — a técnica de [C6]/[C10] pela terceira vez.
-- ============================================================================

CREATE TABLE tb_class_meeting (
  class_meeting_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_schedule_id        integer NOT NULL,
  syllabus_unit_id integer REFERENCES tb_syllabus_unit (syllabus_unit_id),
  -- [E13] denormalização controlada: a turma vem junto do horário via FK composta.
  section_id                integer NOT NULL,
  topic           text,
  meeting_date               date    NOT NULL,
  was_held          boolean NOT NULL DEFAULT true,
  CONSTRAINT fk_meeting_schedule_da_section
    FOREIGN KEY (section_schedule_id, section_id)
    REFERENCES tb_section_schedule (section_schedule_id, section_id),
  CONSTRAINT uq_meeting_schedule_date UNIQUE (section_schedule_id, meeting_date),
  CONSTRAINT uq_meeting_id_section     UNIQUE (class_meeting_id, section_id)          -- alvo p/ presenca [E13]
);
COMMENT ON TABLE tb_class_meeting IS 'Encontros realizados; feriado × data fica em função [E13].';

CREATE TABLE tb_attendance (
  class_meeting_id              integer NOT NULL,
  enrollment_id         integer NOT NULL,
  -- [E13] a MESMA turma amarra a aula e a matrícula: coerência por constraint.
  section_id             integer NOT NULL,
  was_present    boolean NOT NULL DEFAULT true,
  is_excused boolean NOT NULL DEFAULT false,
  PRIMARY KEY (class_meeting_id, enrollment_id),
  CONSTRAINT fk_attendance_meeting_da_section
    FOREIGN KEY (class_meeting_id, section_id) REFERENCES tb_class_meeting (class_meeting_id, section_id),
  CONSTRAINT fk_attendance_enrollment_da_section
    FOREIGN KEY (enrollment_id, section_id) REFERENCES tb_enrollment (enrollment_id, section_id)
);
COMMENT ON TABLE tb_attendance IS 'Presença por aula; aluno de outra turma é IMPOSSÍVEL por FK composta [E13].';

CREATE TABLE tb_assessment (
  assessment_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_id               integer      NOT NULL REFERENCES tb_section (section_id),
  name         varchar(60)  NOT NULL,
  -- [E14] escala DECIDIDA: pesos somam 10.00 (coerente com grade_value 0–10);
  -- o teto fecha o achado F7. A soma exata por turma é conferida no fechamento.
  weight         numeric(4,2) NOT NULL CHECK (weight > 0 AND weight <= 10),
  assessment_date         date,
  is_makeup boolean      NOT NULL DEFAULT false,
  CONSTRAINT uq_assessment_section_name UNIQUE (section_id, name),
  CONSTRAINT uq_assessment_id_section   UNIQUE (assessment_id, section_id)   -- alvo de [E13]
);
COMMENT ON TABLE tb_assessment IS 'Avaliações por turma [E14]; substitutiva preserva a regra da P3 [C13].';

CREATE TABLE tb_grade (
  assessment_id integer NOT NULL,
  enrollment_id integer NOT NULL,
  section_id     integer NOT NULL,          -- [E13] mesma técnica da presenca
  value   grade_value  NOT NULL,
  PRIMARY KEY (assessment_id, enrollment_id),
  CONSTRAINT fk_grade_assessment_da_section
    FOREIGN KEY (assessment_id, section_id) REFERENCES tb_assessment (assessment_id, section_id),
  CONSTRAINT fk_grade_enrollment_da_section
    FOREIGN KEY (enrollment_id, section_id) REFERENCES tb_enrollment (enrollment_id, section_id)
);
COMMENT ON TABLE tb_grade IS 'Nota por avaliação; nota em avaliação de outra turma é IMPOSSÍVEL por FK composta [E13].';

-- ============================================================================
-- 11. DERIVAÇÃO DO DESEMPENHO  [E14]
--     Sucessora direta da coluna GERADA que a ampliação removeu de historico.
--     Antes, media_final_historico era `GENERATED ALWAYS AS (...) STORED` sobre
--     nota_a1/a2/p3 — três colunas fixas, 1FN disfarçada. Agora a nota vive em
--     `tb_grade` (n linhas por matrícula) e a média é DERIVADA aqui, uma vez, para
--     que consultas, views e a MV do 04 usem a MESMA regra.
--
--     A regra da P3 do modelo original é preservada: a avaliação SUBSTITUTIVA
--     troca a MENOR nota regular, e só quando é maior que ela.
--
--     Direitos do DONO (semester security_invoker), de propósito: quem consulta
--     precisa enxergar `tb_grade`/`tb_attendance` inteiras para a agregação fechar. O
--     isolamento por aluno é feito uma camada acima, em historico_aluno
--     (security_invoker = on), que filtra por `tb_enrollment` — protegida por RLS.
--     Por isso esta view NÃO é concedida a papel_aluno (ver 08_seguranca.sql).
-- ============================================================================
CREATE VIEW vw_enrollment_performance AS
WITH regulares AS (
  SELECT n.enrollment_id, n.value, av.weight,
         row_number() OVER (PARTITION BY n.enrollment_id ORDER BY n.value, av.assessment_id) AS posicao
  FROM tb_grade n
  JOIN tb_assessment av ON av.assessment_id = n.assessment_id
  WHERE NOT av.is_makeup
),
substitutiva AS (
  SELECT n.enrollment_id, max(n.value) AS value
  FROM tb_grade n
  JOIN tb_assessment av ON av.assessment_id = n.assessment_id
  WHERE av.is_makeup
  GROUP BY n.enrollment_id
),
avg_grade AS (
  SELECT r.enrollment_id,
         round(sum(CASE WHEN r.posicao = 1 AND s.value > r.value
                        THEN s.value ELSE r.value END * r.weight)
               / sum(r.weight), 2)                       AS final_grade,
         count(*)                                                AS assessments_recorded,
         bool_or(s.value IS NOT NULL)                       AS used_makeup
  FROM regulares r
  LEFT JOIN substitutiva s ON s.enrollment_id = r.enrollment_id
  GROUP BY r.enrollment_id
),
attendance_rate AS (
  SELECT p.enrollment_id,
         count(*)                                                AS meetings_expected,
         count(*) FILTER (WHERE p.was_present)             AS meetings_attended,
         round(100.0 * count(*) FILTER (WHERE p.was_present) / count(*), 2)::percentage AS attendance_rate
  FROM tb_attendance p
  GROUP BY p.enrollment_id
)
SELECT m.enrollment_id,
       m.student_id,
       m.section_id,
       md.final_grade,
       md.assessments_recorded,
       md.used_makeup,
       fq.meetings_expected,
       fq.meetings_attended,
       fq.attendance_rate
FROM tb_enrollment m
LEFT JOIN avg_grade md      ON md.enrollment_id = m.enrollment_id
LEFT JOIN attendance_rate fq ON fq.enrollment_id = m.enrollment_id;
COMMENT ON VIEW vw_enrollment_performance IS
  'Média final (com a regra da substitutiva) e frequência, derivadas de nota/presenca [E14]. Sucessora da coluna gerada [C13].';


-- ============================================================================
-- 12. AUDITORIA TRANSVERSAL  [E19]
--     Três colunas em TODA tabela e dois triggers. É a única parte do modelo
--     que se aplica por igual a todas as 41 — e por isso entra number laço, não
--     copiada 41 vezes.
-- ============================================================================

-- created_at / updated_at / deleted_at em todas as tabelas de dados.
-- log_auditoria fica de fora: ela é append-only e já tem `occurred_at`;
-- auditar a própria auditoria seria recursão semester ganho.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academic' AND tablename <> 'tb_audit_log'
           ORDER BY tablename
  LOOP
    EXECUTE format(
      'ALTER TABLE %I
         ADD COLUMN created_at     timestamptz NOT NULL DEFAULT now(),
         ADD COLUMN updated_at timestamptz,
         ADD COLUMN deleted_at   timestamptz', t);
  END LOOP;
END $$;

COMMENT ON COLUMN tb_enrollment.deleted_at IS
  'Exclusão lógica: preenchida em vez de apagar a linha. NULL = ativa.';

-- Marca a hora da última alteração. BEFORE UPDATE porque precisa alterar NEW
-- antes da gravação — um AFTER não conseguiria.
CREATE FUNCTION f_touch_updated_at() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Grava a trilha. AFTER e RETURN NULL: o trigger não interfere na operação,
-- só registra o que já aconteceu. `to_jsonb(OLD/NEW)` guarda a linha inteira,
-- então a trilha continua legível mesmo se a tabela ganhar colunas depois.
CREATE FUNCTION f_audit() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO academic.tb_audit_log (table_name, action, data_before, data_after)
  VALUES (TG_TABLE_NAME,
          lower(TG_OP)::log_action,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

-- f_touch_updated_at vale para todas; f_audit só para as tabelas onde
-- "quem mudou o quê" é pergunta real. Auditar as 5.570 cidades do IBGE — dado
-- de referência que ninguém edita — seria encher a trilha de ruído e esconder
-- o que importa. As cinco escolhidas são as que guardam pessoa, vínculo e nota.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academic' AND tablename <> 'tb_audit_log'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_atualizacao BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_touch_updated_at()', t, t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['tb_person','tb_student','tb_enrollment','tb_grade','tb_academic_record']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_auditoria AFTER INSERT OR UPDATE OR DELETE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_audit()', t, t);
  END LOOP;
END $$;

COMMIT;

-- [C15] sessões novas nascem com o search_path certo, em qualquer banco:
SELECT format('ALTER DATABASE %I SET search_path TO academic, public', current_database())
\gexec

\echo '=== Esquema ampliado criado. Tabelas: ==='
SELECT count(*) AS tabelas FROM information_schema.tables
WHERE table_schema = 'academic' AND table_type = 'BASE TABLE';
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'academic' AND table_type = 'BASE TABLE' ORDER BY table_name;
