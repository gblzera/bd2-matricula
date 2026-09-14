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

-- [C1] range de TIME não existe nativamente; semester isto section_schedule não compila.
CREATE TYPE timerange AS RANGE (subtype = time);

-- [E16] DIVERGÊNCIA DELIBERADA do modelo do professor, que traz três turnos
-- ('MATUTINO','VESPERTINO','NOTURNO'). Esta instituição opera em DOIS: manhã e
-- noite. Rótulo que o domínio não usa é rótulo que um day entra por engano —
-- o ENUM existe justamente para fechar o conjunto no valor certo, e um valor a
-- mais enfraquece a garantia. A base do professor segue com os três em
-- docs/modelo-fisico.html, que documenta o ponto de partida.
CREATE TYPE shift                AS ENUM ('morning', 'evening');
CREATE TYPE room_type            AS ENUM ('lecture', 'lab', 'auditorium');
CREATE TYPE prerequisite_link              AS ENUM ('prerequisite', 'corequisite');
CREATE TYPE requirement_type            AS ENUM ('required', 'elective', 'free_elective');
CREATE TYPE enrollment_status           AS ENUM ('pending', 'confirmed', 'suspended', 'cancelled');
CREATE TYPE academic_outcome             AS ENUM ('in_progress', 'passed', 'failed_grade',
                                            'failed_attendance', 'suspended');
-- [E2..E15] tipos novos da ampliação
CREATE TYPE phone_type        AS ENUM ('mobile', 'home', 'work');
CREATE TYPE document_type       AS ENUM ('id_card', 'passport', 'drivers_license', 'foreign_id');  -- CPF fica em person [E2]
CREATE TYPE user_role        AS ENUM ('student', 'registrar', 'coordinator', 'admin');
CREATE TYPE work_regime     AS ENUM ('hourly', 'part_time', 'full_time');
CREATE TYPE degree_level            AS ENUM ('bachelor', 'specialization', 'master',
                                            'doctorate', 'postdoc');
CREATE TYPE admission_type       AS ENUM ('entrance_exam', 'national_exam', 'transfer', 'second_degree');
CREATE TYPE student_status         AS ENUM ('active', 'suspended', 'graduated', 'dropped_out', 'dismissed');
CREATE TYPE degree_type           AS ENUM ('bachelor', 'teaching_degree', 'associate');
CREATE TYPE delivery_mode           AS ENUM ('on_campus', 'online', 'hybrid');
CREATE TYPE teaching_role        AS ENUM ('lead', 'assistant', 'substitute');
CREATE TYPE enrollment_window_type AS ENUM ('enrollment', 'adjustment', 'withdrawal', 're_enrollment');
CREATE TYPE meeting_type            AS ENUM ('lecture', 'lab_session');
CREATE TYPE reference_type    AS ENUM ('core', 'supplementary');
CREATE TYPE credit_transfer_status AS ENUM ('pending', 'approved', 'denied');
CREATE TYPE log_action             AS ENUM ('insert', 'update', 'delete');

CREATE DOMAIN grade_value AS numeric(4,2) CHECK (VALUE >= 0 AND VALUE <= 10);
CREATE DOMAIN percentage  AS numeric(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN cpf  AS char(11)     CHECK (VALUE ~ '^[0-9]{11}$');

-- ============================================================================
-- 2. GEOGRAFIA  [E1]
--    Tira "Brasília" de string repetida: city→state→país com dedup por nível.
-- ============================================================================

CREATE TABLE country (
  country_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name  varchar(60) NOT NULL UNIQUE,
  iso_code char(2)     NOT NULL UNIQUE                          -- ISO 3166-1
);
COMMENT ON TABLE country IS 'Países [E1].';

CREATE TABLE state (
  state_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_id     smallint    NOT NULL REFERENCES country (country_id),
  name varchar(60) NOT NULL,
  abbreviation   char(2)     NOT NULL,
  CONSTRAINT uq_state_country_uf UNIQUE (country_id, abbreviation)
);
COMMENT ON TABLE state IS 'Unidades federativas [E1].';

CREATE TABLE city (
  city_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  state_id          smallint    NOT NULL REFERENCES state (state_id),
  name        varchar(80) NOT NULL,
  ibge_code char(7)     UNIQUE,
  CONSTRAINT uq_city_state_name UNIQUE (state_id, name)
);
COMMENT ON TABLE city IS 'Municípios; "Brasilia" ≠ "BRASÍLIA" morre aqui [E1].';

CREATE TABLE address (
  address_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  city_id            integer      NOT NULL REFERENCES city (city_id),
  street  varchar(120) NOT NULL,
  number      varchar(10),                               -- varchar: "s/n"
  complement varchar(60),
  district      varchar(60),
  postal_code         char(8) CHECK (postal_code ~ '^[0-9]{8}$')
);
COMMENT ON TABLE address IS 'Endereços de pessoas e campi [E1].';

-- ============================================================================
-- 3. PESSOAS  [E2] [E3]
--    person é o supertipo; student e professor são especializações 1:1 e não
--    exclusivas (um professor pode ser student de outro program).
-- ============================================================================

CREATE TABLE person (
  person_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  address_id       integer REFERENCES address (address_id),
  name       varchar(120) NOT NULL,
  email      varchar(120) NOT NULL UNIQUE CHECK (position('@' in email) > 1),
  -- [E2] CPF é 1:1 com a person no Brasil: fica AQUI, obrigatório, preservando
  -- [C12]. person_document guarda os demais documentos (multivalorados).
  cpf        cpf NOT NULL UNIQUE,
  birth_date date  NOT NULL
);
COMMENT ON TABLE person IS 'Supertipo de aluno e professor [E2]; nome/e-mail/CPF vivem só aqui.';

CREATE TABLE phone (
  phone_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id          integer     NOT NULL REFERENCES person (person_id) ON DELETE CASCADE,
  number    varchar(20) NOT NULL,
  is_primary boolean     NOT NULL DEFAULT false,
  phone_type      phone_type NOT NULL,
  CONSTRAINT uq_phone_person_numero UNIQUE (person_id, number)
);
COMMENT ON TABLE phone IS 'Multivalorado → tabela (1FN) [E3]. Um principal por pessoa: índice parcial.';
-- só um phone principal por person (validado em banco descartável)
CREATE UNIQUE INDEX uq_phone_primary ON phone (person_id) WHERE is_primary;

CREATE TABLE person_document (
  person_document_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id                integer     NOT NULL REFERENCES person (person_id) ON DELETE CASCADE,
  number  varchar(20) NOT NULL,
  issuer   varchar(20),
  issued_on date,
  document_type    document_type NOT NULL,
  -- o mesmo documento não pode pertencer a duas pessoas…
  CONSTRAINT uq_document_type_numero UNIQUE (document_type, number),
  -- …e uma person tem no máximo um documento de cada kind
  CONSTRAINT uq_document_person_type UNIQUE (person_id, document_type)
);
COMMENT ON TABLE person_document IS 'Documentos além do CPF [E3]; CPF mora em pessoa [E2].';

CREATE TABLE app_user (
  app_user_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id     integer     NOT NULL UNIQUE REFERENCES person (person_id),
  login varchar(60) NOT NULL UNIQUE,     -- = name da ROLE no PostgreSQL [E4]
  is_active boolean     NOT NULL DEFAULT true,
  role user_role NOT NULL
);
COMMENT ON TABLE app_user IS 'Conta de acesso; login = ROLE do Postgres, casa com a RLS al_<RA> [E4].';

-- ============================================================================
-- 4. ESTRUTURA FÍSICA E ORGANIZACIONAL  [E5] [E6]
-- ============================================================================

CREATE TABLE campus (
  campus_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE honra a cardinalidade (0,1) do lado do endereço (achado F1 da revisão)
  address_id integer     NOT NULL UNIQUE REFERENCES address (address_id),
  name varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE campus IS 'Campi; cidade_campus saiu — vem de endereco→cidade [E1].';

CREATE TABLE department (
  department_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id          smallint    NOT NULL REFERENCES campus (campus_id),
  head_professor_id integer,       -- FK circular com professor: constraint via ALTER, adiante [E6]
  name  varchar(80) NOT NULL,
  abbreviation varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE department IS 'Departamentos; chefe é FK circular resolvida por ALTER [E6].';

CREATE TABLE building (
  building_id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id      smallint    NOT NULL REFERENCES campus (campus_id),
  name    varchar(60) NOT NULL,
  floor_count smallint CHECK (floor_count > 0),
  CONSTRAINT uq_building_campus_name UNIQUE (campus_id, name)
);
COMMENT ON TABLE building IS 'Prédios do campus [E5].';

CREATE TABLE room (
  room_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E5] room muda de dono: o campus vem via prédio. [C4] evolui junto:
  -- código único DENTRO do prédio (prédios do mesmo campus podem repetir).
  building_id       smallint    NOT NULL REFERENCES building (building_id),
  code     varchar(10) NOT NULL,
  floor      smallint,
  capacity smallint    NOT NULL CHECK (capacity > 0),
  room_type       room_type NOT NULL DEFAULT 'lecture',
  CONSTRAINT uq_room_building_code UNIQUE (building_id, code)   -- [C4→E5]
);
COMMENT ON TABLE room IS 'Salas físicas, por prédio [E5]; [C4] agora por prédio.';

CREATE TABLE resource (
  resource_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE resource IS 'Recursos alocáveis (projetor, bancada…) [E3].';

CREATE TABLE room_resource (
  room_id                 integer  NOT NULL REFERENCES room (room_id) ON DELETE CASCADE,
  resource_id              smallint NOT NULL REFERENCES resource (resource_id),
  quantity smallint NOT NULL DEFAULT 1 CHECK (quantity > 0),
  PRIMARY KEY (room_id, resource_id)
);
COMMENT ON TABLE room_resource IS 'N:N sala×recurso — o critério para alocar laboratório [E3].';

CREATE TABLE professor (
  professor_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id           integer     NOT NULL UNIQUE REFERENCES person (person_id),
  department_id     smallint    NOT NULL REFERENCES department (department_id),
  employee_number varchar(12) NOT NULL UNIQUE,
  work_regime    work_regime NOT NULL,
  degree_level degree_level NOT NULL
);
COMMENT ON TABLE professor IS 'Especialização 1:1 de pessoa [E2]; só o que é vínculo de trabalho.';

-- [E6] a FK circular department↔professor entra agora, com UNIQUE (F4: um
-- professor chefia no máximo um department; UNIQUE aceita vários NULLs).
ALTER TABLE department
  ADD CONSTRAINT fk_department_head
      FOREIGN KEY (head_professor_id) REFERENCES professor (professor_id),
  ADD CONSTRAINT uq_department_head UNIQUE (head_professor_id);

CREATE TABLE professor_degree (
  professor_degree_id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  professor_id                     integer      NOT NULL REFERENCES professor (professor_id) ON DELETE CASCADE,
  program_name         varchar(120) NOT NULL,
  institution   varchar(120) NOT NULL,
  completion_year smallint     NOT NULL CHECK (completion_year BETWEEN 1950 AND 2100),
  degree_level     degree_level  NOT NULL,
  CONSTRAINT uq_degree_prof UNIQUE (professor_id, program_name, institution)
);
COMMENT ON TABLE professor_degree IS 'Formações (multivalorado, 1FN) [E3]; a titulação declarada fica em professor.';

-- ============================================================================
-- 5. ESTRUTURA ACADÊMICA  [E7] [E8] [E15]
-- ============================================================================

CREATE TABLE program (
  program_id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id       smallint     NOT NULL REFERENCES campus (campus_id),
  department_id smallint     NOT NULL REFERENCES department (department_id),
  code    varchar(10)  NOT NULL UNIQUE,
  name      varchar(120) NOT NULL,
  total_hours  integer      NOT NULL CHECK (total_hours > 0),
  degree_type      degree_type NOT NULL,          -- era varchar+CHECK: rótulo fechado ⇒ ENUM [C12]
  delivery_mode delivery_mode NOT NULL DEFAULT 'on_campus'
);
COMMENT ON TABLE program IS 'Cursos; ganham departamento [E6] e modalidade.';

CREATE TABLE program_coordination (
  program_coordination_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id                   smallint    NOT NULL REFERENCES program (program_id),
  professor_id               integer     NOT NULL REFERENCES professor (professor_id),
  appointment_ref varchar(30),
  validity daterange   NOT NULL CHECK (NOT isempty(validity)),
  -- [E8] um coordenador por program a cada instante — técnica de [C10], semester trigger.
  -- Vigência aberta: daterange(inicio, NULL). Validado em banco descartável.
  CONSTRAINT ex_coordination_validity EXCLUDE USING gist
    (program_id WITH =, validity WITH &&)
);
COMMENT ON TABLE program_coordination IS 'Mandatos de coordenação; EXCLUDE de vigência [E8].';

CREATE TABLE curriculum (
  curriculum_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  program_id               smallint    NOT NULL REFERENCES program (program_id),
  approval_ref     varchar(30),
  effective_year smallint    NOT NULL CHECK (effective_year BETWEEN 1990 AND 2100),
  is_active        boolean     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculum_program_year UNIQUE (program_id, effective_year),   -- [C8]
  CONSTRAINT uq_curriculum_id_program  UNIQUE (curriculum_id, program_id)              -- alvo da FK composta [C6]
);
COMMENT ON TABLE curriculum IS 'Matrizes curriculares por ano [C8]; alvo de [C6].';

CREATE TABLE course (
  course_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  department_id       smallint     NOT NULL REFERENCES department (department_id),
  code     varchar(10)  NOT NULL UNIQUE,
  name       varchar(120) NOT NULL,
  description     text,
  theory_hours smallint NOT NULL DEFAULT 0 CHECK (theory_hours >= 0),
  lab_hours smallint NOT NULL DEFAULT 0 CHECK (lab_hours >= 0),
  total_hours   smallint GENERATED ALWAYS AS (theory_hours + lab_hours) STORED,  -- [C13]
  CONSTRAINT ck_course_ch_positive CHECK (theory_hours + lab_hours > 0)
);
COMMENT ON TABLE course IS 'Catálogo; ch_total é gerada [C13]; ementa é a descrição perene — o plano de ensino é a execução [E7].';

CREATE TABLE curriculum_course (
  curriculum_id                 integer     NOT NULL REFERENCES curriculum (curriculum_id) ON DELETE CASCADE,
  course_id                integer     NOT NULL REFERENCES course (course_id),
  term_number smallint    NOT NULL CHECK (term_number BETWEEN 1 AND 12),
  requirement_type    requirement_type NOT NULL DEFAULT 'required',
  PRIMARY KEY (curriculum_id, course_id)
);
COMMENT ON TABLE curriculum_course IS 'Grade: período sugerido de cada disciplina no currículo.';

CREATE TABLE prerequisite (
  course_id             integer   NOT NULL REFERENCES course (course_id) ON DELETE CASCADE,
  required_course_id              integer   NOT NULL REFERENCES course (course_id) ON DELETE CASCADE,
  min_hours   smallint  CHECK (min_hours > 0),  -- alternativa por CH acumulada
  min_grade grade_value   NOT NULL DEFAULT 5.00,
  link_type     prerequisite_link NOT NULL DEFAULT 'prerequisite',
  PRIMARY KEY (course_id, required_course_id),
  CONSTRAINT ck_prereq_not_reflexive CHECK (course_id <> required_course_id)   -- [C7]
);
COMMENT ON TABLE prerequisite IS 'id_disciplina EXIGE id_requisito, com média/CH mínimas por aresta; ciclos maiores: consulta recursiva [C7].';

CREATE TABLE student (
  student_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id            integer     NOT NULL UNIQUE REFERENCES person (person_id),
  program_id             smallint    NOT NULL REFERENCES program (program_id),
  curriculum_id         integer     NOT NULL,
  enrollment_number      varchar(12) NOT NULL UNIQUE,
  admission_date       date        NOT NULL,
  admission_type admission_type NOT NULL,
  status         student_status   NOT NULL DEFAULT 'active',
  -- [C6] o currículo do student tem que ser um currículo do program do student.
  CONSTRAINT fk_student_curriculum_do_program
    FOREIGN KEY (curriculum_id, program_id) REFERENCES curriculum (curriculum_id, program_id)
);
COMMENT ON TABLE student IS 'Especialização 1:1 de pessoa [E2]; fica só o vínculo acadêmico. [C6] mantido.';
-- Ambiguidade HERDADA do modelo do professor, registrada para quem vier depois:
-- `enrollment_number` é o RA (identificação do student na instituição, uma por student),
-- enquanto a TABELA `enrollment` é a inscrição do student numa section (muitas por student).
-- São conceitos distintos com a mesma palavra. Renomear divergiria da convenção do
-- professor, então o name fica e a distinção é documentada aqui.
COMMENT ON COLUMN student.enrollment_number IS
  'RA: identificação do aluno na instituição. NÃO confundir com a tabela matricula (inscrição em turma).';

CREATE TABLE credit_transfer (
  credit_transfer_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id                                integer      NOT NULL REFERENCES student (student_id),
  course_id                           integer      NOT NULL REFERENCES course (course_id),
  reviewer_id                    integer      REFERENCES app_user (app_user_id),
  source_course  varchar(120) NOT NULL,
  source_institution varchar(120) NOT NULL,
  review_note          text,
  source_hours        smallint NOT NULL CHECK (source_hours > 0),
  source_grade      grade_value   NOT NULL,
  requested_on      date     NOT NULL DEFAULT current_date,
  decided_on          date,
  status           credit_transfer_status NOT NULL DEFAULT 'pending',
  CONSTRAINT uq_transfer_student_disc UNIQUE (student_id, course_id)
  -- Regras de deferimento cruzam tabela (CH da course, forma de ingresso):
  -- ficam na função de deferimento, não em CHECK [E15].
);
COMMENT ON TABLE credit_transfer IS 'Dispensa por estudo anterior [E15]; conta em pode_cursar().';

-- ============================================================================
-- 6. TEMPO E CALENDÁRIO  [E9] [E10]
-- ============================================================================

CREATE TABLE academic_term (
  academic_term_id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  year         smallint NOT NULL,
  semester    smallint NOT NULL CHECK (semester IN (1, 2)),
  start_date date     NOT NULL,
  end_date    date     NOT NULL,
  CONSTRAINT uq_term_year_semester UNIQUE (year, semester),  -- [C3]
  CONSTRAINT ck_term_dates        CHECK (start_date < end_date)
);
COMMENT ON TABLE academic_term IS 'Semestres letivos [C3].';

CREATE TABLE enrollment_window (
  enrollment_window_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  academic_term_id           smallint    NOT NULL REFERENCES academic_term (academic_term_id),
  description varchar(60) NOT NULL,
  window_range    tstzrange   NOT NULL CHECK (NOT isempty(window_range)),
  window_type      enrollment_window_type NOT NULL,
  -- [E9] janelas do mesmo kind não se sobrepõem no período; tipos diferentes
  -- podem (ajuste cobre o ends da matrícula). ENUM em GiST: btree_gist, validado.
  CONSTRAINT ex_term_enrollment_window EXCLUDE USING gist
    (academic_term_id WITH =, window_type WITH =, window_range WITH &&)
);
COMMENT ON TABLE enrollment_window IS 'QUANDO se pode matricular [E9]; a função de matrícula consulta now() <@ janela.';

CREATE TABLE holiday (
  holiday_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E10] arco exclusivo: o ALCANCE do holiday é exatamente uma das 4 FKs.
  -- O ENUM de kind foi REMOVIDO de propósito: seria derivável do arco
  -- (dependência funcional kind↔FK — violaria 3FN); is_optional é ortogonal.
  country_id             smallint REFERENCES country (country_id),
  state_id           smallint REFERENCES state (state_id),
  city_id           integer  REFERENCES city (city_id),
  campus_id           smallint REFERENCES campus (campus_id),
  description   varchar(120) NOT NULL,
  holiday_date        date         NOT NULL,
  is_optional boolean      NOT NULL DEFAULT false,
  CONSTRAINT ck_holiday_arc CHECK (
    (country_id   IS NOT NULL)::int + (state_id IS NOT NULL)::int +
    (city_id IS NOT NULL)::int + (campus_id IS NOT NULL)::int = 1)
);
COMMENT ON TABLE holiday IS 'Alcance pelo arco de FKs [E10]; dedup por nível preserva [C9].';
-- [C9→E10] dedup por nível: semester isto, dois feriados nacionais na mesma date
-- voltariam a passar — que era o erro original do modelo do professor.
CREATE UNIQUE INDEX uq_holiday_country_date   ON holiday (country_id,   holiday_date) WHERE country_id   IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_state_date ON holiday (state_id, holiday_date) WHERE state_id IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_city_date ON holiday (city_id, holiday_date) WHERE city_id IS NOT NULL;
CREATE UNIQUE INDEX uq_holiday_campus_date ON holiday (campus_id, holiday_date) WHERE campus_id IS NOT NULL;

-- ============================================================================
-- 7. OFERTA E DOCÊNCIA  [E11] [E12]
-- ============================================================================

CREATE TABLE section (
  section_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  course_id     integer     NOT NULL REFERENCES course (course_id),
  academic_term_id smallint    NOT NULL REFERENCES academic_term (academic_term_id),
  code      varchar(15) NOT NULL,
  seats       smallint    NOT NULL CHECK (seats >= 0),
  shift       shift     NOT NULL,
  delivery_mode  delivery_mode NOT NULL DEFAULT 'on_campus',
  CONSTRAINT uq_section_term_code UNIQUE (academic_term_id, code),  -- [C5]
  CONSTRAINT uq_section_id_term     UNIQUE (section_id, academic_term_id),      -- alvo de [C10]
  CONSTRAINT uq_section_id_course  UNIQUE (section_id, course_id)           -- alvo de [E7]
  -- professor_id SAIU → section_professor [E11] (co-docência)
);
COMMENT ON TABLE section IS 'Oferta; professor foi para turma_professor [E11].';

CREATE TABLE section_professor (
  section_id              integer  NOT NULL REFERENCES section (section_id),
  professor_id          integer  NOT NULL REFERENCES professor (professor_id),
  hours    smallint CHECK (hours > 0),
  teaching_role teaching_role NOT NULL DEFAULT 'lead',
  PRIMARY KEY (section_id, professor_id)
);
COMMENT ON TABLE section_professor IS 'Co-docência [E11]; um titular por turma via índice parcial.';
CREATE UNIQUE INDEX uq_section_prof_lead ON section_professor (section_id)
  WHERE teaching_role = 'lead';

CREATE TABLE section_schedule (
  section_schedule_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_id                 integer  NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da section via FK composta.
  academic_term_id        smallint NOT NULL,
  -- [E12] room ANULÁVEL: section EAD tem horário semester room física.
  room_id                  integer  REFERENCES room (room_id),
  weekday smallint  NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  time_range      timerange NOT NULL CHECK (NOT isempty(time_range)),   -- [C1]
  meeting_type  meeting_type NOT NULL DEFAULT 'lecture',
  CONSTRAINT fk_schedule_section_term
    FOREIGN KEY (section_id, academic_term_id)
    REFERENCES section (section_id, academic_term_id) ON DELETE CASCADE,
  CONSTRAINT uq_schedule_id_section UNIQUE (section_schedule_id, section_id),   -- alvo de [E13]
  -- [C10] choque de room só para quem TEM room (EXCLUDE parcial, validado) [E12]
  CONSTRAINT ex_room_no_conflict EXCLUDE USING gist (
    academic_term_id WITH =, room_id WITH =, weekday WITH =,
    time_range WITH &&) WHERE (room_id IS NOT NULL),
  -- [C10] a própria section não se sobrepõe, com ou semester room
  CONSTRAINT ex_section_no_conflict EXCLUDE USING gist (
    section_id WITH =, weekday WITH =, time_range WITH &&)
);
COMMENT ON TABLE section_schedule IS 'Encontros semanais; sala NULL = EAD [E12]; alvo de [E13].';

-- ============================================================================
-- 8. PLANO DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA; a section pode ter a sua versão.
--    section_id NULL  = plano base da course;
--    section_id preenchido = versão daquela oferta.
-- ============================================================================

CREATE TABLE syllabus (
  syllabus_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  course_id                   integer NOT NULL,
  section_id                        integer,
  objective           text NOT NULL,
  methodology        text,
  grading_criteria text,
  approved_on          date,
  CONSTRAINT fk_syllabus_course FOREIGN KEY (course_id) REFERENCES course (course_id),
  -- [E7] técnica de [C9]: um único plano base (section NULL) e no máximo uma
  -- versão por section.
  CONSTRAINT uq_syllabus_course_section UNIQUE NULLS NOT DISTINCT (course_id, section_id),
  -- [E7] técnica de [C6]: a versão só pode pendurar numa section DESSA course.
  -- (com section_id NULL a FK composta não é avaliada — MATCH SIMPLE — e o plano
  -- base passa; preenchida, o par é validado contra section.)
  CONSTRAINT fk_syllabus_section_da_course
    FOREIGN KEY (section_id, course_id) REFERENCES section (section_id, course_id)
);
COMMENT ON TABLE syllabus IS 'Da disciplina, com versão opcional por turma [E7]: técnicas de [C9] e [C6].';

CREATE TABLE syllabus_unit (
  syllabus_unit_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  syllabus_id                integer      NOT NULL REFERENCES syllabus (syllabus_id) ON DELETE CASCADE,
  title    varchar(120) NOT NULL,
  content  text,
  position     smallint NOT NULL CHECK (position > 0),
  hours        smallint NOT NULL CHECK (hours > 0),
  CONSTRAINT uq_unit_syllabus_position UNIQUE (syllabus_id, position)
);
COMMENT ON TABLE syllabus_unit IS 'Unidades do plano; soma de CH ≤ CH da disciplina fica em função [E7].';

CREATE TABLE bibliography (
  bibliography_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title  varchar(200) NOT NULL,
  author   varchar(120) NOT NULL,
  publisher varchar(80),
  isbn    char(13) UNIQUE,
  year     smallint CHECK (year BETWEEN 1800 AND 2100),
  edition  smallint CHECK (edition > 0)
);
COMMENT ON TABLE bibliography IS 'Obras; N:N com plano via plano_ensino_bibliografia.';

CREATE TABLE syllabus_bibliography (
  syllabus_id               integer NOT NULL REFERENCES syllabus (syllabus_id) ON DELETE CASCADE,
  bibliography_id               integer NOT NULL REFERENCES bibliography (bibliography_id),
  reference_type reference_type NOT NULL,
  PRIMARY KEY (syllabus_id, bibliography_id)
);
COMMENT ON TABLE syllabus_bibliography IS 'Básica × complementar por plano.';

-- ============================================================================
-- 9. MATRÍCULA E HISTÓRICO  [C2] [C11] [E14]
-- ============================================================================

CREATE TABLE enrollment (
  enrollment_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         integer      NOT NULL REFERENCES student (student_id),
  section_id         integer      NOT NULL REFERENCES section (section_id),
  enrolled_at   timestamptz  NOT NULL DEFAULT now(),
  -- DEFAULT 'confirmed' MANTIDO (achado F9): vw_vagas conta confirmadas e a
  -- demo da última vaga depende disso; o fluxo pendente→confirmada, quando
  -- existir, muda o default junto com a função de matrícula.
  status enrollment_status NOT NULL DEFAULT 'confirmed',
  CONSTRAINT uq_enrollment_student_section UNIQUE (student_id, section_id),   -- [C2]
  CONSTRAINT uq_enrollment_id_section    UNIQUE (enrollment_id, section_id)  -- alvo de [E13]
);
COMMENT ON TABLE enrollment IS 'Inscrição do aluno numa turma [C2] — uma linha por turma cursada, não confundir com aluno.matricula_aluno (o RA). Vaga consumida por confirmada; a disputa é o Marco 2.';

CREATE TABLE academic_record (
  academic_record_id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  enrollment_id              integer NOT NULL UNIQUE REFERENCES enrollment (enrollment_id) ON DELETE CASCADE,
  closed_on date,
  outcome        academic_outcome NOT NULL DEFAULT 'in_progress'
  -- [E14] nota_a1/a2/p3, frequência e final_grade SAÍRAM: agora derivam de
  -- grade/attendance na MV mv_academic_record (refresh ao fechar o período).
  -- Custo assumido e registrado: o GENERATED de [C13] e o índice B-tree de 46×
  -- migram para a MV — que aceita índice e REFRESH CONCURRENTLY (validado).
);
COMMENT ON TABLE academic_record IS 'Consolidado 1:1 da matrícula [E14]; o registro fino vive em nota/presenca.';

CREATE TABLE enrollment_log (
  enrollment_log_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK, de propósito: a trilha sobrevive ao expurgo da matrícula.
  enrollment_id              integer,
  app_user_id                integer REFERENCES app_user (app_user_id),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  action        log_action  NOT NULL,
  detail     jsonb
);
COMMENT ON TABLE enrollment_log IS 'Auditoria [C11]; id_usuario resolvido da sessão por f_usuario_sessao [E4].';

-- [E4] resolve a ROLE da sessão para app_user.app_user_id (NULL se não mapeada —
-- o street nunca deixa de ser gravado por causa disso).
CREATE FUNCTION f_session_user() RETURNS integer
  LANGUAGE sql STABLE
  AS $$ SELECT app_user_id FROM academic.app_user WHERE login = current_user $$;
ALTER TABLE enrollment_log ALTER COLUMN app_user_id SET DEFAULT f_session_user();

-- ============================================================================
-- 10. AULA E AVALIAÇÃO  [E13] [E14]
--     Coerência SEM trigger: section_id viaja nas junções e é amarrada por FK
--     composta — a técnica de [C6]/[C10] pela terceira vez.
-- ============================================================================

CREATE TABLE class_meeting (
  class_meeting_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_schedule_id        integer NOT NULL,
  syllabus_unit_id integer REFERENCES syllabus_unit (syllabus_unit_id),
  -- [E13] denormalização controlada: a section vem junto do horário via FK composta.
  section_id                integer NOT NULL,
  topic           text,
  meeting_date               date    NOT NULL,
  was_held          boolean NOT NULL DEFAULT true,
  CONSTRAINT fk_meeting_schedule_da_section
    FOREIGN KEY (section_schedule_id, section_id)
    REFERENCES section_schedule (section_schedule_id, section_id),
  CONSTRAINT uq_meeting_schedule_date UNIQUE (section_schedule_id, meeting_date),
  CONSTRAINT uq_meeting_id_section     UNIQUE (class_meeting_id, section_id)          -- alvo p/ attendance [E13]
);
COMMENT ON TABLE class_meeting IS 'Encontros realizados; feriado × data fica em função [E13].';

CREATE TABLE attendance (
  class_meeting_id              integer NOT NULL,
  enrollment_id         integer NOT NULL,
  -- [E13] a MESMA section amarra a class_meeting e a matrícula: coerência por constraint.
  section_id             integer NOT NULL,
  was_present    boolean NOT NULL DEFAULT true,
  is_excused boolean NOT NULL DEFAULT false,
  PRIMARY KEY (class_meeting_id, enrollment_id),
  CONSTRAINT fk_attendance_meeting_da_section
    FOREIGN KEY (class_meeting_id, section_id) REFERENCES class_meeting (class_meeting_id, section_id),
  CONSTRAINT fk_attendance_enrollment_da_section
    FOREIGN KEY (enrollment_id, section_id) REFERENCES enrollment (enrollment_id, section_id)
);
COMMENT ON TABLE attendance IS 'Presença por aula; aluno de outra turma é IMPOSSÍVEL por FK composta [E13].';

CREATE TABLE assessment (
  assessment_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_id               integer      NOT NULL REFERENCES section (section_id),
  name         varchar(60)  NOT NULL,
  -- [E14] escala DECIDIDA: pesos somam 10.00 (coerente com grade_value 0–10);
  -- o teto fecha o achado F7. A soma exata por section é conferida no fechamento.
  weight         numeric(4,2) NOT NULL CHECK (weight > 0 AND weight <= 10),
  assessment_date         date,
  is_makeup boolean      NOT NULL DEFAULT false,
  CONSTRAINT uq_assessment_section_name UNIQUE (section_id, name),
  CONSTRAINT uq_assessment_id_section   UNIQUE (assessment_id, section_id)   -- alvo de [E13]
);
COMMENT ON TABLE assessment IS 'Avaliações por turma [E14]; substitutiva preserva a regra da P3 [C13].';

CREATE TABLE grade (
  assessment_id integer NOT NULL,
  enrollment_id integer NOT NULL,
  section_id     integer NOT NULL,          -- [E13] mesma técnica da attendance
  value   grade_value  NOT NULL,
  PRIMARY KEY (assessment_id, enrollment_id),
  CONSTRAINT fk_grade_assessment_da_section
    FOREIGN KEY (assessment_id, section_id) REFERENCES assessment (assessment_id, section_id),
  CONSTRAINT fk_grade_enrollment_da_section
    FOREIGN KEY (enrollment_id, section_id) REFERENCES enrollment (enrollment_id, section_id)
);
COMMENT ON TABLE grade IS 'Nota por avaliação; nota em avaliação de outra turma é IMPOSSÍVEL por FK composta [E13].';

-- ============================================================================
-- 11. DERIVAÇÃO DO DESEMPENHO  [E14]
--     Sucessora direta da coluna GERADA que a ampliação removeu de academic_record.
--     Antes, media_final_historico era `GENERATED ALWAYS AS (...) STORED` sobre
--     nota_a1/a2/p3 — três colunas fixas, 1FN disfarçada. Agora a grade vive em
--     `grade` (n linhas por matrícula) e a média é DERIVADA aqui, uma vez, para
--     que consultas, views e a MV do 04 usem a MESMA regra.
--
--     A regra da P3 do modelo original é preservada: a avaliação SUBSTITUTIVA
--     troca a MENOR grade regular, e só quando é maior que ela.
--
--     Direitos do DONO (semester security_invoker), de propósito: quem consulta
--     precisa enxergar `grade`/`attendance` inteiras para a agregação fechar. O
--     isolamento por student é feito uma camada acima, em v_student_record
--     (security_invoker = on), que filtra por `enrollment` — protegida por RLS.
--     Por isso esta view NÃO é concedida a papel_aluno (ver 08_seguranca.sql).
-- ============================================================================
CREATE VIEW v_enrollment_performance AS
WITH regulares AS (
  SELECT n.enrollment_id, n.value, av.weight,
         row_number() OVER (PARTITION BY n.enrollment_id ORDER BY n.value, av.assessment_id) AS posicao
  FROM grade n
  JOIN assessment av ON av.assessment_id = n.assessment_id
  WHERE NOT av.is_makeup
),
substitutiva AS (
  SELECT n.enrollment_id, max(n.value) AS value
  FROM grade n
  JOIN assessment av ON av.assessment_id = n.assessment_id
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
  FROM attendance p
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
FROM enrollment m
LEFT JOIN avg_grade md      ON md.enrollment_id = m.enrollment_id
LEFT JOIN attendance_rate fq ON fq.enrollment_id = m.enrollment_id;
COMMENT ON VIEW v_enrollment_performance IS
  'Média final (com a regra da substitutiva) e frequência, derivadas de nota/presenca [E14]. Sucessora da coluna gerada [C13].';

COMMIT;

-- [C15] sessões novas nascem com o search_path certo, em qualquer banco:
SELECT format('ALTER DATABASE %I SET search_path TO academic, public', current_database())
\gexec

\echo '=== Esquema ampliado criado. Tabelas: ==='
SELECT count(*) AS tabelas FROM information_schema.tables
WHERE table_schema = 'academic' AND table_type = 'BASE TABLE';
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'academic' AND table_type = 'BASE TABLE' ORDER BY table_name;
