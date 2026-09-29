-- ============================================================================
-- entrega_marco1.sql — Marco 1 completo, para executar DE UMA VEZ SÓ.
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- ARQUIVO GERADO por scripts/gerar_entrega.sh — não editar à mão.
-- É a concatenação, na ordem de execução, de:
--   sql/01_ddl.sql
--   sql/02_carga.sql
--   sql/02b_geografia_ibge.sql
--   sql/03_consultas.sql
--
-- Como rodar (cria o banco do zero; o script recria o schema sozinho):
--   createdb matricula
--   psql -v ON_ERROR_STOP=1 -d matricula -f entrega_marco1.sql
--
-- O que ele faz, nesta ordem: cria as 41 tabelas com as restrições; carrega
-- 120 alunos, 34 turmas e 796 matrículas (mínimos do enunciado: 100/6/300),
-- mais a geografia do IBGE; e roda as 10 consultas comentadas, entre elas as
-- 5 obrigatórias — junção externa com agregação (C3), as duas recursivas
-- (C5 e C6), ranking com percentil (C7) e LAG (C8).
--
-- Gerado em 2026-09-28 a partir do commit 5ef51c5.
-- ============================================================================


-- ############################################################################
-- ### sql/01_ddl.sql
-- ############################################################################

-- ============================================================================
-- 01_ddl.sql — DDL completo do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- O modelo do professor é a BASE (16 tabelas, correções [C1]–[C15]); a ampliação
-- [E1]–[E15] foi modelada em docs/esboco-schema-ampliado.md, revisada e validada
-- em banco descartável. Cada decisão é marcada no ponto em que vira DDL.
--
-- Ordem de colunas (padrão exigido): PK, FK, varchar, text, char, inteiros,
-- decimais — e depois data/hora e ranges, boolean, ENUM, jsonb.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d <banco> < sql/01_ddl.sql
-- Idempotente: recria o schema academico do zero a cada execução.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- [C15] Schema próprio; reset barato e de escopo restrito.
DROP SCHEMA IF EXISTS academico CASCADE;
CREATE SCHEMA academico;
SET search_path TO academico, public;

-- [C10] igualdade escalar + && numa mesma restrição de exclusão GiST.
-- [C15] A extensão fica em public: sobrevive ao DROP SCHEMA academico.
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

-- ============================================================================
-- 1. TIPOS E DOMÍNIOS  [C12]
--    ENUM para conjunto fechado de rótulos; DOMAIN para faixa ou formato.
-- ============================================================================

-- [C1] range de TIME não existe nativamente; sem isto turma_horario não compila.
CREATE TYPE timerange AS RANGE (subtype = time);

-- [E16] DIVERGÊNCIA DELIBERADA do modelo do professor, que traz três turnos
-- ('MATUTINO','VESPERTINO','NOTURNO'). Esta instituição opera em DOIS: manhã e
-- noite. Rótulo que o domínio não usa é rótulo que um dia entra por engano —
-- o ENUM existe justamente para fechar o conjunto no valor certo, e um valor a
-- mais enfraquece a garantia. A base do professor segue com os três em
-- docs/modelo-fisico.html, que documenta o ponto de partida.
CREATE TYPE turno_t                AS ENUM ('matutino', 'noturno');
CREATE TYPE tipo_sala_t            AS ENUM ('teorica', 'laboratorio', 'auditorio');
-- [E17] vinculo_t removido: sem co-requisito, o tipo ficaria sem uso.
CREATE TYPE tipo_disc_t            AS ENUM ('obrigatoria', 'optativa', 'eletiva');
CREATE TYPE status_mat_t           AS ENUM ('pendente', 'confirmada', 'trancada', 'cancelada');
CREATE TYPE situacao_t             AS ENUM ('cursando', 'aprovado', 'reprovado_nota',
                                            'reprovado_frequencia', 'trancado');
-- [E2..E15] tipos novos da ampliação
CREATE TYPE tipo_telefone_t        AS ENUM ('celular', 'residencial', 'comercial');
CREATE TYPE tipo_documento_t       AS ENUM ('rg', 'passaporte', 'cnh', 'rne');  -- CPF fica em pessoa [E2]
CREATE TYPE papel_usuario_t        AS ENUM ('aluno', 'secretaria', 'coordenacao', 'admin');
CREATE TYPE regime_professor_t     AS ENUM ('horista', 'parcial', 'integral');
CREATE TYPE titulacao_t            AS ENUM ('graduacao', 'especializacao', 'mestrado',
                                            'doutorado', 'pos_doutorado');
CREATE TYPE forma_ingresso_t       AS ENUM ('vestibular', 'enem', 'transferencia', 'portador_diploma');
CREATE TYPE status_aluno_t         AS ENUM ('ativo', 'trancado', 'formado', 'evadido', 'jubilado');
CREATE TYPE grau_curso_t           AS ENUM ('bacharelado', 'licenciatura', 'tecnologo');
CREATE TYPE modalidade_t           AS ENUM ('presencial', 'ead', 'hibrido');
CREATE TYPE papel_docente_t        AS ENUM ('titular', 'auxiliar', 'substituto');
CREATE TYPE tipo_periodo_matricula_t AS ENUM ('matricula', 'ajuste', 'trancamento', 'rematricula');
CREATE TYPE tipo_aula_t            AS ENUM ('teorica', 'pratica');
CREATE TYPE tipo_bibliografia_t    AS ENUM ('basica', 'complementar');
CREATE TYPE status_aproveitamento_t AS ENUM ('pendente', 'deferido', 'indeferido');
CREATE TYPE acao_log_t             AS ENUM ('insert', 'update', 'delete');

CREATE DOMAIN nota_t AS numeric(4,2) CHECK (VALUE >= 0 AND VALUE <= 10);
CREATE DOMAIN pct_t  AS numeric(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN cpf_t  AS char(11)     CHECK (VALUE ~ '^[0-9]{11}$');

-- ============================================================================
-- 2. GEOGRAFIA  [E1]
--    Tira "Brasília" de string repetida: cidade→estado→país com dedup por nível.
-- ============================================================================

CREATE TABLE tb_pais (
  id_pais    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_pais  varchar(60) NOT NULL UNIQUE,
  sigla_pais char(2)     NOT NULL UNIQUE                          -- ISO 3166-1
);
COMMENT ON TABLE tb_pais IS 'Países [E1].';

CREATE TABLE tb_estado (
  id_estado   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pais     smallint    NOT NULL REFERENCES tb_pais (id_pais),
  nome_estado varchar(60) NOT NULL,
  uf_estado   char(2)     NOT NULL,
  CONSTRAINT uq_estado_pais_uf UNIQUE (id_pais, uf_estado)
);
COMMENT ON TABLE tb_estado IS 'Unidades federativas [E1].';

CREATE TABLE tb_cidade (
  id_cidade          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_estado          smallint    NOT NULL REFERENCES tb_estado (id_estado),
  nome_cidade        varchar(80) NOT NULL,
  codigo_ibge_cidade char(7)     UNIQUE,
  CONSTRAINT uq_cidade_estado_nome UNIQUE (id_estado, nome_cidade)
);
COMMENT ON TABLE tb_cidade IS 'Municípios; "Brasilia" ≠ "BRASÍLIA" morre aqui [E1].';

CREATE TABLE tb_endereco (
  id_endereco          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cidade            integer      NOT NULL REFERENCES tb_cidade (id_cidade),
  logradouro_endereco  varchar(120) NOT NULL,
  numero_endereco      varchar(10),                               -- varchar: "s/n"
  complemento_endereco varchar(60),
  bairro_endereco      varchar(60),
  cep_endereco         char(8) CHECK (cep_endereco ~ '^[0-9]{8}$')
);
COMMENT ON TABLE tb_endereco IS 'Endereços de pessoas e campi [E1].';

-- ============================================================================
-- 3. PESSOAS  [E2] [E3]
--    pessoa é o supertipo; aluno e professor são especializações 1:1 e não
--    exclusivas (um professor pode ser aluno de outro curso).
-- ============================================================================

CREATE TABLE tb_pessoa (
  id_pessoa         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_endereco       integer REFERENCES tb_endereco (id_endereco),
  nome_pessoa       varchar(120) NOT NULL,
  email_pessoa      varchar(120) NOT NULL UNIQUE CHECK (position('@' in email_pessoa) > 1),
  -- [E2] CPF é 1:1 com a pessoa no Brasil: fica AQUI, obrigatório, preservando
  -- [C12]. documento_pessoa guarda os demais documentos (multivalorados).
  cpf_pessoa        cpf_t NOT NULL UNIQUE,
  nascimento_pessoa date  NOT NULL
);
COMMENT ON TABLE tb_pessoa IS 'Supertipo de aluno e professor [E2]; nome/e-mail/CPF vivem só aqui.';

CREATE TABLE tb_telefone (
  id_telefone        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa          integer     NOT NULL REFERENCES tb_pessoa (id_pessoa) ON DELETE CASCADE,
  numero_telefone    varchar(20) NOT NULL,
  principal_telefone boolean     NOT NULL DEFAULT false,
  tipo_telefone      tipo_telefone_t NOT NULL,
  CONSTRAINT uq_telefone_pessoa_numero UNIQUE (id_pessoa, numero_telefone)
);
COMMENT ON TABLE tb_telefone IS 'Multivalorado → tabela (1FN) [E3]. Um principal por pessoa: índice parcial.';
-- só um telefone principal por pessoa (validado em banco descartável)
CREATE UNIQUE INDEX uq_telefone_principal ON tb_telefone (id_pessoa) WHERE principal_telefone;

CREATE TABLE tb_documento_pessoa (
  id_documento_pessoa      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa                integer     NOT NULL REFERENCES tb_pessoa (id_pessoa) ON DELETE CASCADE,
  numero_documento_pessoa  varchar(20) NOT NULL,
  orgao_documento_pessoa   varchar(20),
  emissao_documento_pessoa date,
  tipo_documento_pessoa    tipo_documento_t NOT NULL,
  -- o mesmo documento não pode pertencer a duas pessoas…
  CONSTRAINT uq_documento_tipo_numero UNIQUE (tipo_documento_pessoa, numero_documento_pessoa),
  -- …e uma pessoa tem no máximo um documento de cada tipo
  CONSTRAINT uq_documento_pessoa_tipo UNIQUE (id_pessoa, tipo_documento_pessoa)
);
COMMENT ON TABLE tb_documento_pessoa IS 'Documentos além do CPF [E3]; CPF mora em pessoa [E2].';

CREATE TABLE tb_usuario (
  id_usuario    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa     integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  login_usuario varchar(60) NOT NULL UNIQUE,     -- = nome da ROLE no PostgreSQL [E4]
  ativo_usuario boolean     NOT NULL DEFAULT true,
  papel_usuario papel_usuario_t NOT NULL
);
COMMENT ON TABLE tb_usuario IS 'Conta de acesso; login = ROLE do Postgres, casa com a RLS al_<RA> [E4].';

-- ============================================================================
-- 4. ESTRUTURA FÍSICA E ORGANIZACIONAL  [E5] [E6]
-- ============================================================================

CREATE TABLE tb_campus (
  id_campus   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE honra a cardinalidade (0,1) do lado do endereço (achado F1 da revisão)
  id_endereco integer     NOT NULL UNIQUE REFERENCES tb_endereco (id_endereco),
  nome_campus varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_campus IS 'Campi; cidade_campus saiu — vem de endereco→cidade [E1].';

CREATE TABLE tb_departamento (
  id_departamento    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus          smallint    NOT NULL REFERENCES tb_campus (id_campus),
  id_professor_chefe integer,       -- FK circular com professor: constraint via ALTER, adiante [E6]
  nome_departamento  varchar(80) NOT NULL,
  sigla_departamento varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_departamento IS 'Departamentos; chefe é FK circular resolvida por ALTER [E6].';

CREATE TABLE tb_predio (
  id_predio      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus      smallint    NOT NULL REFERENCES tb_campus (id_campus),
  nome_predio    varchar(60) NOT NULL,
  andares_predio smallint CHECK (andares_predio > 0),
  CONSTRAINT uq_predio_campus_nome UNIQUE (id_campus, nome_predio)
);
COMMENT ON TABLE tb_predio IS 'Prédios do campus [E5].';

CREATE TABLE tb_sala (
  id_sala         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E5] sala muda de dono: o campus vem via prédio. [C4] evolui junto:
  -- código único DENTRO do prédio (prédios do mesmo campus podem repetir).
  id_predio       smallint    NOT NULL REFERENCES tb_predio (id_predio),
  codigo_sala     varchar(10) NOT NULL,
  andar_sala      smallint,
  capacidade_sala smallint    NOT NULL CHECK (capacidade_sala > 0),
  tipo_sala       tipo_sala_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT uq_sala_predio_codigo UNIQUE (id_predio, codigo_sala)   -- [C4→E5]
);
COMMENT ON TABLE tb_sala IS 'Salas físicas, por prédio [E5]; [C4] agora por prédio.';

CREATE TABLE tb_recurso (
  id_recurso   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_recurso varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_recurso IS 'Recursos alocáveis (projetor, bancada…) [E3].';

CREATE TABLE tb_sala_recurso (
  id_sala                 integer  NOT NULL REFERENCES tb_sala (id_sala) ON DELETE CASCADE,
  id_recurso              smallint NOT NULL REFERENCES tb_recurso (id_recurso),
  quantidade_sala_recurso smallint NOT NULL DEFAULT 1 CHECK (quantidade_sala_recurso > 0),
  PRIMARY KEY (id_sala, id_recurso)
);
COMMENT ON TABLE tb_sala_recurso IS 'N:N sala×recurso — o critério para alocar laboratório [E3].';

CREATE TABLE tb_professor (
  id_professor        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa           integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  id_departamento     smallint    NOT NULL REFERENCES tb_departamento (id_departamento),
  matricula_professor varchar(12) NOT NULL UNIQUE,
  regime_professor    regime_professor_t NOT NULL,
  titulacao_professor titulacao_t NOT NULL
);
COMMENT ON TABLE tb_professor IS 'Especialização 1:1 de pessoa [E2]; só o que é vínculo de trabalho.';

-- [E6] a FK circular departamento↔professor entra agora, com UNIQUE (F4: um
-- professor chefia no máximo um departamento; UNIQUE aceita vários NULLs).
ALTER TABLE tb_departamento
  ADD CONSTRAINT fk_departamento_chefe
      FOREIGN KEY (id_professor_chefe) REFERENCES tb_professor (id_professor),
  ADD CONSTRAINT uq_departamento_chefe UNIQUE (id_professor_chefe);

CREATE TABLE tb_formacao_professor (
  id_formacao_professor            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_professor                     integer      NOT NULL REFERENCES tb_professor (id_professor) ON DELETE CASCADE,
  curso_formacao_professor         varchar(120) NOT NULL,
  instituicao_formacao_professor   varchar(120) NOT NULL,
  ano_conclusao_formacao_professor smallint     NOT NULL CHECK (ano_conclusao_formacao_professor BETWEEN 1950 AND 2100),
  titulacao_formacao_professor     titulacao_t  NOT NULL,
  CONSTRAINT uq_formacao_prof UNIQUE (id_professor, curso_formacao_professor, instituicao_formacao_professor)
);
COMMENT ON TABLE tb_formacao_professor IS 'Formações (multivalorado, 1FN) [E3]; a titulação declarada fica em professor.';

-- ============================================================================
-- 5. ESTRUTURA ACADÊMICA  [E7] [E8] [E15]
-- ============================================================================

CREATE TABLE tb_curso (
  id_curso        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus       smallint     NOT NULL REFERENCES tb_campus (id_campus),
  id_departamento smallint     NOT NULL REFERENCES tb_departamento (id_departamento),
  codigo_curso    varchar(10)  NOT NULL UNIQUE,
  nome_curso      varchar(120) NOT NULL,
  ch_total_curso  integer      NOT NULL CHECK (ch_total_curso > 0),
  grau_curso      grau_curso_t NOT NULL,          -- era varchar+CHECK: rótulo fechado ⇒ ENUM [C12]
  modalidade_curso modalidade_t NOT NULL DEFAULT 'presencial'
);
COMMENT ON TABLE tb_curso IS 'Cursos; ganham departamento [E6] e modalidade.';

CREATE TABLE tb_coordenacao_curso (
  id_coordenacao_curso       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso                   smallint    NOT NULL REFERENCES tb_curso (id_curso),
  id_professor               integer     NOT NULL REFERENCES tb_professor (id_professor),
  portaria_coordenacao_curso varchar(30),
  vigencia_coordenacao_curso daterange   NOT NULL CHECK (NOT isempty(vigencia_coordenacao_curso)),
  -- [E8] um coordenador por curso a cada instante — técnica de [C10], sem trigger.
  -- Vigência aberta: daterange(inicio, NULL). Validado em banco descartável.
  CONSTRAINT ex_coordenacao_vigencia EXCLUDE USING gist
    (id_curso WITH =, vigencia_coordenacao_curso WITH &&)
);
COMMENT ON TABLE tb_coordenacao_curso IS 'Mandatos de coordenação; EXCLUDE de vigência [E8].';

CREATE TABLE tb_curriculo (
  id_curriculo           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso               smallint    NOT NULL REFERENCES tb_curso (id_curso),
  portaria_curriculo     varchar(30),
  ano_vigencia_curriculo smallint    NOT NULL CHECK (ano_vigencia_curriculo BETWEEN 1990 AND 2100),
  ativo_curriculo        boolean     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculo_curso_ano UNIQUE (id_curso, ano_vigencia_curriculo),   -- [C8]
  CONSTRAINT uq_curriculo_id_curso  UNIQUE (id_curriculo, id_curso)              -- alvo da FK composta [C6]
);
COMMENT ON TABLE tb_curriculo IS 'Matrizes curriculares por ano [C8]; alvo de [C6].';

CREATE TABLE tb_disciplina (
  id_disciplina         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_departamento       smallint     NOT NULL REFERENCES tb_departamento (id_departamento),
  codigo_disciplina     varchar(10)  NOT NULL UNIQUE,
  nome_disciplina       varchar(120) NOT NULL,
  ementa_disciplina     text,
  ch_teorica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_teorica_disciplina >= 0),
  ch_pratica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_pratica_disciplina >= 0),
  ch_total_disciplina   smallint GENERATED ALWAYS AS (ch_teorica_disciplina + ch_pratica_disciplina) STORED,  -- [C13]
  CONSTRAINT ck_disciplina_ch_positiva CHECK (ch_teorica_disciplina + ch_pratica_disciplina > 0)
);
COMMENT ON TABLE tb_disciplina IS 'Catálogo; ch_total é gerada [C13]; ementa é a descrição perene — o plano de ensino é a execução [E7].';

CREATE TABLE tb_curriculo_disciplina (
  id_curriculo                 integer     NOT NULL REFERENCES tb_curriculo (id_curriculo) ON DELETE CASCADE,
  id_disciplina                integer     NOT NULL REFERENCES tb_disciplina (id_disciplina),
  periodo_curriculo_disciplina smallint    NOT NULL CHECK (periodo_curriculo_disciplina BETWEEN 1 AND 12),
  tipo_curriculo_disciplina    tipo_disc_t NOT NULL DEFAULT 'obrigatoria',
  PRIMARY KEY (id_curriculo, id_disciplina)
);
COMMENT ON TABLE tb_curriculo_disciplina IS 'Grade: período sugerido de cada disciplina no currículo.';

-- [E17] O pré-requisito passa a pertencer ao CURRÍCULO, não ao catálogo.
-- Antes, "BD2 exige BD1" valia para toda matriz de uma vez; mas a cadeia é
-- decisão de cada matriz, e matrizes diferentes encadeiam diferente.
-- As DUAS chaves compostas são o ponto: exigem que a disciplina E o requisito
-- estejam ambos NAQUELE currículo. Apontar para matéria fora da matriz é
-- impossível por restrição, sem trigger — a técnica de [C6] outra vez.
-- `vinculo` saiu a pedido: o modelo expressa só pré-requisito. Consequência
-- assumida: o co-requisito (LBD2 junto de BD2) deixa de ser representável.
-- `ch_minima_pre_requisito` saiu junto — nunca foi usado por consulta nenhuma.
CREATE TABLE tb_pre_requisito (
  id_curriculo               integer NOT NULL,
  id_disciplina              integer NOT NULL,
  id_requisito               integer NOT NULL,
  media_minima_pre_requisito nota_t  NOT NULL DEFAULT 5.00,
  PRIMARY KEY (id_curriculo, id_disciplina, id_requisito),
  CONSTRAINT fk_prereq_disciplina_do_curriculo
    FOREIGN KEY (id_curriculo, id_disciplina)
    REFERENCES tb_curriculo_disciplina (id_curriculo, id_disciplina) ON DELETE CASCADE,
  CONSTRAINT fk_prereq_requisito_do_curriculo
    FOREIGN KEY (id_curriculo, id_requisito)
    REFERENCES tb_curriculo_disciplina (id_curriculo, id_disciplina),
  CONSTRAINT ck_prereq_nao_reflexivo CHECK (id_disciplina <> id_requisito)   -- [C7]
);
COMMENT ON TABLE tb_pre_requisito IS 'id_disciplina EXIGE id_requisito, com média/CH mínimas por aresta; ciclos maiores: consulta recursiva [C7].';

CREATE TABLE tb_aluno (
  id_aluno             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa            integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  id_curso             smallint    NOT NULL REFERENCES tb_curso (id_curso),
  id_curriculo         integer     NOT NULL,
  -- [E18] `ingresso_aluno` saiu: o RA já carrega o ano nos quatro primeiros
  -- dígitos (20240036 = 2024), então a data era determinada por ele —
  -- transitiva. Quem precisa do ano lê `left(matricula_aluno, 4)`.
  matricula_aluno      varchar(12) NOT NULL UNIQUE,
  forma_ingresso_aluno forma_ingresso_t NOT NULL,
  status_aluno         status_aluno_t   NOT NULL DEFAULT 'ativo',
  -- [C6] o currículo do aluno tem que ser um currículo do curso do aluno.
  CONSTRAINT fk_aluno_curriculo_do_curso
    FOREIGN KEY (id_curriculo, id_curso) REFERENCES tb_curriculo (id_curriculo, id_curso)
);
COMMENT ON TABLE tb_aluno IS 'Especialização 1:1 de pessoa [E2]; fica só o vínculo acadêmico. [C6] mantido.';
-- Ambiguidade HERDADA do modelo do professor, registrada para quem vier depois:
-- `matricula_aluno` é o RA (identificação do aluno na instituição, uma por aluno),
-- enquanto a TABELA `tb_matricula` é a inscrição do aluno numa turma (muitas por aluno).
-- São conceitos distintos com a mesma palavra. Renomear divergiria da convenção do
-- professor, então o nome fica e a distinção é documentada aqui.
COMMENT ON COLUMN tb_aluno.matricula_aluno IS
  'RA: identificação do aluno na instituição. NÃO confundir com a tabela matricula (inscrição em turma).';

CREATE TABLE tb_aproveitamento_materia (
  id_aproveitamento_materia               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno                                integer      NOT NULL REFERENCES tb_aluno (id_aluno),
  id_disciplina                           integer      NOT NULL REFERENCES tb_disciplina (id_disciplina),
  id_usuario_avaliador                    integer      REFERENCES tb_usuario (id_usuario),
  disciplina_origem_aproveitamento_materia  varchar(120) NOT NULL,
  instituicao_origem_aproveitamento_materia varchar(120) NOT NULL,
  parecer_aproveitamento_materia          text,
  ch_origem_aproveitamento_materia        smallint NOT NULL CHECK (ch_origem_aproveitamento_materia > 0),
  nota_origem_aproveitamento_materia      nota_t   NOT NULL,
  solicitacao_aproveitamento_materia      date     NOT NULL DEFAULT current_date,
  decisao_aproveitamento_materia          date,
  status_aproveitamento_materia           status_aproveitamento_t NOT NULL DEFAULT 'pendente',
  CONSTRAINT uq_aproveitamento_aluno_disc UNIQUE (id_aluno, id_disciplina)
  -- Regras de deferimento cruzam tabela (CH da disciplina, forma de ingresso):
  -- ficam na função de deferimento, não em CHECK [E15].
);
COMMENT ON TABLE tb_aproveitamento_materia IS 'Dispensa por estudo anterior [E15]; conta em pode_cursar().';

-- ============================================================================
-- 6. TEMPO E CALENDÁRIO  [E9] [E10]
-- ============================================================================

CREATE TABLE tb_periodo_letivo (
  id_periodo_letivo          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ano_periodo_letivo         smallint NOT NULL,
  semestre_periodo_letivo    smallint NOT NULL CHECK (semestre_periodo_letivo IN (1, 2)),
  data_inicio_periodo_letivo date     NOT NULL,
  data_fim_periodo_letivo    date     NOT NULL,
  CONSTRAINT uq_periodo_ano_semestre UNIQUE (ano_periodo_letivo, semestre_periodo_letivo),  -- [C3]
  CONSTRAINT ck_periodo_datas        CHECK (data_inicio_periodo_letivo < data_fim_periodo_letivo)
);
COMMENT ON TABLE tb_periodo_letivo IS 'Semestres letivos [C3].';

CREATE TABLE tb_periodo_matricula (
  id_periodo_matricula        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_periodo_letivo           smallint    NOT NULL REFERENCES tb_periodo_letivo (id_periodo_letivo),
  descricao_periodo_matricula varchar(60) NOT NULL,
  janela_periodo_matricula    tstzrange   NOT NULL CHECK (NOT isempty(janela_periodo_matricula)),
  tipo_periodo_matricula      tipo_periodo_matricula_t NOT NULL,
  -- [E9] janelas do mesmo tipo não se sobrepõem no período; tipos diferentes
  -- podem (ajuste cobre o fim da matrícula). ENUM em GiST: btree_gist, validado.
  CONSTRAINT ex_periodo_matricula_janela EXCLUDE USING gist
    (id_periodo_letivo WITH =, tipo_periodo_matricula WITH =, janela_periodo_matricula WITH &&)
);
COMMENT ON TABLE tb_periodo_matricula IS 'QUANDO se pode matricular [E9]; a função de matrícula consulta now() <@ janela.';

CREATE TABLE tb_feriado (
  id_feriado          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E10] arco exclusivo: o ALCANCE do feriado é exatamente uma das 4 FKs.
  -- O ENUM de tipo foi REMOVIDO de propósito: seria derivável do arco
  -- (dependência funcional tipo↔FK — violaria 3FN); facultativo é ortogonal.
  id_pais             smallint REFERENCES tb_pais (id_pais),
  id_estado           smallint REFERENCES tb_estado (id_estado),
  id_cidade           integer  REFERENCES tb_cidade (id_cidade),
  id_campus           smallint REFERENCES tb_campus (id_campus),
  descricao_feriado   varchar(120) NOT NULL,
  data_feriado        date         NOT NULL,
  facultativo_feriado boolean      NOT NULL DEFAULT false,
  CONSTRAINT ck_feriado_arco CHECK (
    (id_pais   IS NOT NULL)::int + (id_estado IS NOT NULL)::int +
    (id_cidade IS NOT NULL)::int + (id_campus IS NOT NULL)::int = 1)
);
COMMENT ON TABLE tb_feriado IS 'Alcance pelo arco de FKs [E10]; dedup por nível preserva [C9].';
-- [C9→E10] dedup por nível: sem isto, dois feriados nacionais na mesma data
-- voltariam a passar — que era o erro original do modelo do professor.
CREATE UNIQUE INDEX uq_feriado_pais_data   ON tb_feriado (id_pais,   data_feriado) WHERE id_pais   IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_estado_data ON tb_feriado (id_estado, data_feriado) WHERE id_estado IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_cidade_data ON tb_feriado (id_cidade, data_feriado) WHERE id_cidade IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_campus_data ON tb_feriado (id_campus, data_feriado) WHERE id_campus IS NOT NULL;

-- ============================================================================
-- 7. OFERTA E DOCÊNCIA  [E11] [E12]
-- ============================================================================

CREATE TABLE tb_turma (
  id_turma          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina     integer     NOT NULL REFERENCES tb_disciplina (id_disciplina),
  id_periodo_letivo smallint    NOT NULL REFERENCES tb_periodo_letivo (id_periodo_letivo),
  codigo_turma      varchar(15) NOT NULL,
  vagas_turma       smallint    NOT NULL CHECK (vagas_turma >= 0),
  turno_turma       turno_t     NOT NULL,
  modalidade_turma  modalidade_t NOT NULL DEFAULT 'presencial',
  CONSTRAINT uq_turma_periodo_codigo UNIQUE (id_periodo_letivo, codigo_turma),  -- [C5]
  CONSTRAINT uq_turma_id_periodo     UNIQUE (id_turma, id_periodo_letivo),      -- alvo de [C10]
  CONSTRAINT uq_turma_id_disciplina  UNIQUE (id_turma, id_disciplina)           -- alvo de [E7]
  -- id_professor SAIU → turma_professor [E11] (co-docência)
);
COMMENT ON TABLE tb_turma IS 'Oferta; professor foi para turma_professor [E11].';

CREATE TABLE tb_turma_professor (
  id_turma              integer  NOT NULL REFERENCES tb_turma (id_turma),
  id_professor          integer  NOT NULL REFERENCES tb_professor (id_professor),
  ch_turma_professor    smallint CHECK (ch_turma_professor > 0),
  papel_turma_professor papel_docente_t NOT NULL DEFAULT 'titular',
  PRIMARY KEY (id_turma, id_professor)
);
COMMENT ON TABLE tb_turma_professor IS 'Co-docência [E11]; um titular por turma via índice parcial.';
CREATE UNIQUE INDEX uq_turma_prof_titular ON tb_turma_professor (id_turma)
  WHERE papel_turma_professor = 'titular';

CREATE TABLE tb_turma_horario (
  id_turma_horario         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma                 integer  NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da turma via FK composta.
  id_periodo_letivo        smallint NOT NULL,
  -- [E12] sala ANULÁVEL: turma EAD tem horário sem sala física.
  id_sala                  integer  REFERENCES tb_sala (id_sala),
  dia_semana_turma_horario smallint  NOT NULL CHECK (dia_semana_turma_horario BETWEEN 1 AND 7),
  faixa_turma_horario      timerange NOT NULL CHECK (NOT isempty(faixa_turma_horario)),   -- [C1]
  tipo_aula_turma_horario  tipo_aula_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT fk_horario_turma_periodo
    FOREIGN KEY (id_turma, id_periodo_letivo)
    REFERENCES tb_turma (id_turma, id_periodo_letivo) ON DELETE CASCADE,
  CONSTRAINT uq_horario_id_turma UNIQUE (id_turma_horario, id_turma),   -- alvo de [E13]
  -- [C10] choque de sala só para quem TEM sala (EXCLUDE parcial, validado) [E12]
  CONSTRAINT ex_sala_sem_choque EXCLUDE USING gist (
    id_periodo_letivo WITH =, id_sala WITH =, dia_semana_turma_horario WITH =,
    faixa_turma_horario WITH &&) WHERE (id_sala IS NOT NULL),
  -- [C10] a própria turma não se sobrepõe, com ou sem sala
  CONSTRAINT ex_turma_sem_choque EXCLUDE USING gist (
    id_turma WITH =, dia_semana_turma_horario WITH =, faixa_turma_horario WITH &&)
);
COMMENT ON TABLE tb_turma_horario IS 'Encontros semanais; sala NULL = EAD [E12]; alvo de [E13].';

-- ============================================================================
-- 8. PLANO DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA; a turma pode ter a sua versão.
--    id_turma NULL  = plano base da disciplina;
--    id_turma preenchido = versão daquela oferta.
-- ============================================================================

CREATE TABLE tb_plano_ensino (
  id_plano_ensino                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina                   integer NOT NULL,
  id_turma                        integer,
  objetivo_plano_ensino           text NOT NULL,
  metodologia_plano_ensino        text,
  criterio_avaliacao_plano_ensino text,
  aprovacao_plano_ensino          date,
  CONSTRAINT fk_plano_disciplina FOREIGN KEY (id_disciplina) REFERENCES tb_disciplina (id_disciplina),
  -- [E7] técnica de [C9]: um único plano base (turma NULL) e no máximo uma
  -- versão por turma.
  CONSTRAINT uq_plano_disciplina_turma UNIQUE NULLS NOT DISTINCT (id_disciplina, id_turma),
  -- [E7] técnica de [C6]: a versão só pode pendurar numa turma DESSA disciplina.
  -- (com id_turma NULL a FK composta não é avaliada — MATCH SIMPLE — e o plano
  -- base passa; preenchida, o par é validado contra turma.)
  CONSTRAINT fk_plano_turma_da_disciplina
    FOREIGN KEY (id_turma, id_disciplina) REFERENCES tb_turma (id_turma, id_disciplina)
);
COMMENT ON TABLE tb_plano_ensino IS 'Da disciplina, com versão opcional por turma [E7]: técnicas de [C9] e [C6].';

CREATE TABLE tb_unidade_plano_ensino (
  id_unidade_plano_ensino        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_plano_ensino                integer      NOT NULL REFERENCES tb_plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  titulo_unidade_plano_ensino    varchar(120) NOT NULL,
  conteudo_unidade_plano_ensino  text,
  ordem_unidade_plano_ensino     smallint NOT NULL CHECK (ordem_unidade_plano_ensino > 0),
  ch_unidade_plano_ensino        smallint NOT NULL CHECK (ch_unidade_plano_ensino > 0),
  CONSTRAINT uq_unidade_plano_ordem UNIQUE (id_plano_ensino, ordem_unidade_plano_ensino)
);
COMMENT ON TABLE tb_unidade_plano_ensino IS 'Unidades do plano; soma de CH ≤ CH da disciplina fica em função [E7].';

CREATE TABLE tb_bibliografia (
  id_bibliografia      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  titulo_bibliografia  varchar(200) NOT NULL,
  autor_bibliografia   varchar(120) NOT NULL,
  editora_bibliografia varchar(80),
  isbn_bibliografia    char(13) UNIQUE,
  ano_bibliografia     smallint CHECK (ano_bibliografia BETWEEN 1800 AND 2100),
  edicao_bibliografia  smallint CHECK (edicao_bibliografia > 0)
);
COMMENT ON TABLE tb_bibliografia IS 'Obras; N:N com plano via plano_ensino_bibliografia.';

CREATE TABLE tb_plano_ensino_bibliografia (
  id_plano_ensino               integer NOT NULL REFERENCES tb_plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  id_bibliografia               integer NOT NULL REFERENCES tb_bibliografia (id_bibliografia),
  tipo_plano_ensino_bibliografia tipo_bibliografia_t NOT NULL,
  PRIMARY KEY (id_plano_ensino, id_bibliografia)
);
COMMENT ON TABLE tb_plano_ensino_bibliografia IS 'Básica × complementar por plano.';

-- ============================================================================
-- 9. MATRÍCULA E HISTÓRICO  [C2] [C11] [E14]
-- ============================================================================

CREATE TABLE tb_matricula (
  id_matricula     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno         integer      NOT NULL REFERENCES tb_aluno (id_aluno),
  id_turma         integer      NOT NULL REFERENCES tb_turma (id_turma),
  data_matricula   timestamptz  NOT NULL DEFAULT now(),
  -- DEFAULT 'confirmada' MANTIDO (achado F9): vagas conta confirmadas e a
  -- demo da última vaga depende disso; o fluxo pendente→confirmada, quando
  -- existir, muda o default junto com a função de matrícula.
  status_matricula status_mat_t NOT NULL DEFAULT 'confirmada',
  CONSTRAINT uq_matricula_aluno_turma UNIQUE (id_aluno, id_turma),   -- [C2]
  CONSTRAINT uq_matricula_id_turma    UNIQUE (id_matricula, id_turma)  -- alvo de [E13]
);
COMMENT ON TABLE tb_matricula IS 'Inscrição do aluno numa turma [C2] — uma linha por turma cursada, não confundir com aluno.matricula_aluno (o RA). Vaga consumida por confirmada; a disputa é o Marco 2.';

CREATE TABLE tb_historico (
  id_historico              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_matricula              integer NOT NULL UNIQUE REFERENCES tb_matricula (id_matricula) ON DELETE CASCADE,
  data_fechamento_historico date,
  situacao_historico        situacao_t NOT NULL DEFAULT 'cursando'
  -- [E14] nota_a1/a2/p3, frequência e media_final SAÍRAM: agora derivam de
  -- nota/presenca na MV historico_consolidado (refresh ao fechar o período).
  -- Custo assumido e registrado: o GENERATED de [C13] e o índice B-tree de 46×
  -- migram para a MV — que aceita índice e REFRESH CONCURRENTLY (validado).
);
COMMENT ON TABLE tb_historico IS 'Consolidado 1:1 da matrícula [E14]; o registro fino vive em nota/presenca.';

-- [E19] O log deixa de ser só da matrícula e passa a ser GENÉRICO: uma linha
-- por alteração, em qualquer tabela auditada, gravada por trigger. Antes ele
-- dependia da aplicação lembrar de inserir; agora quem grava é o banco, e
-- "esquecer de logar" deixa de ser possível.
--
-- Nota para a arguição: isto NÃO contradiz o "zero triggers" do modelo. Aquilo
-- vale para trigger de VALIDAÇÃO — regra de integridade que o banco já sabe
-- declarar, e que em trigger vira código com desvio. Auditoria é o caso oposto:
-- não há forma declarativa de dizer "registre quem mudou o quê", e o trigger é
-- a ferramenta certa justamente por interceptar TODO caminho de escrita.
CREATE TABLE tb_log_auditoria (
  id_log_auditoria    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK para a linha auditada, de propósito: a trilha sobrevive ao
  -- expurgo do dado. Auditoria que some junto com o auditado não é auditoria.
  id_usuario          integer REFERENCES tb_usuario (id_usuario),
  nome_tabela         name        NOT NULL,
  acao_log            acao_log_t  NOT NULL,
  ocorrido_em         timestamptz NOT NULL DEFAULT now(),
  dados_antes         jsonb,
  dados_depois        jsonb
);
COMMENT ON TABLE tb_log_auditoria IS 'Trilha de auditoria gravada por trigger [E19]; sem FK para o auditado [C11].';

-- [E4] resolve a ROLE da sessão para usuario.id_usuario (NULL se não mapeada —
-- o log nunca deixa de ser gravado por causa disso).
CREATE FUNCTION f_usuario_sessao() RETURNS integer
  LANGUAGE sql STABLE
  AS $$ SELECT id_usuario FROM academico.tb_usuario WHERE login_usuario = current_user $$;
ALTER TABLE tb_log_auditoria ALTER COLUMN id_usuario SET DEFAULT f_usuario_sessao();

-- ============================================================================
-- 10. AULA E AVALIAÇÃO  [E13] [E14]
--     Coerência SEM trigger: id_turma viaja nas junções e é amarrada por FK
--     composta — a técnica de [C6]/[C10] pela terceira vez.
-- ============================================================================

CREATE TABLE tb_aula (
  id_aula                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma_horario        integer NOT NULL,
  id_unidade_plano_ensino integer REFERENCES tb_unidade_plano_ensino (id_unidade_plano_ensino),
  -- [E13] denormalização controlada: a turma vem junto do horário via FK composta.
  id_turma                integer NOT NULL,
  conteudo_aula           text,
  data_aula               date    NOT NULL,
  realizada_aula          boolean NOT NULL DEFAULT true,
  CONSTRAINT fk_aula_horario_da_turma
    FOREIGN KEY (id_turma_horario, id_turma)
    REFERENCES tb_turma_horario (id_turma_horario, id_turma),
  CONSTRAINT uq_aula_horario_data UNIQUE (id_turma_horario, data_aula),
  CONSTRAINT uq_aula_id_turma     UNIQUE (id_aula, id_turma)          -- alvo p/ presenca [E13]
);
COMMENT ON TABLE tb_aula IS 'Encontros realizados; feriado × data fica em função [E13].';

CREATE TABLE tb_presenca (
  id_aula              integer NOT NULL,
  id_matricula         integer NOT NULL,
  -- [E13] a MESMA turma amarra a aula e a matrícula: coerência por constraint.
  id_turma             integer NOT NULL,
  presente_presenca    boolean NOT NULL DEFAULT true,
  justificada_presenca boolean NOT NULL DEFAULT false,
  PRIMARY KEY (id_aula, id_matricula),
  CONSTRAINT fk_presenca_aula_da_turma
    FOREIGN KEY (id_aula, id_turma) REFERENCES tb_aula (id_aula, id_turma),
  CONSTRAINT fk_presenca_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES tb_matricula (id_matricula, id_turma)
);
COMMENT ON TABLE tb_presenca IS 'Presença por aula; aluno de outra turma é IMPOSSÍVEL por FK composta [E13].';

CREATE TABLE tb_avaliacao (
  id_avaliacao           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma               integer      NOT NULL REFERENCES tb_turma (id_turma),
  nome_avaliacao         varchar(60)  NOT NULL,
  -- [E14] escala DECIDIDA: pesos somam 10.00 (coerente com nota_t 0–10);
  -- o teto fecha o achado F7. A soma exata por turma é conferida no fechamento.
  peso_avaliacao         numeric(4,2) NOT NULL CHECK (peso_avaliacao > 0 AND peso_avaliacao <= 10),
  data_avaliacao         date,
  substitutiva_avaliacao boolean      NOT NULL DEFAULT false,
  CONSTRAINT uq_avaliacao_turma_nome UNIQUE (id_turma, nome_avaliacao),
  CONSTRAINT uq_avaliacao_id_turma   UNIQUE (id_avaliacao, id_turma)   -- alvo de [E13]
);
COMMENT ON TABLE tb_avaliacao IS 'Avaliações por turma [E14]; substitutiva preserva a regra da P3 [C13].';

CREATE TABLE tb_nota (
  id_avaliacao integer NOT NULL,
  id_matricula integer NOT NULL,
  id_turma     integer NOT NULL,          -- [E13] mesma técnica da presenca
  valor_nota   nota_t  NOT NULL,
  PRIMARY KEY (id_avaliacao, id_matricula),
  CONSTRAINT fk_nota_avaliacao_da_turma
    FOREIGN KEY (id_avaliacao, id_turma) REFERENCES tb_avaliacao (id_avaliacao, id_turma),
  CONSTRAINT fk_nota_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES tb_matricula (id_matricula, id_turma)
);
COMMENT ON TABLE tb_nota IS 'Nota por avaliação; nota em avaliação de outra turma é IMPOSSÍVEL por FK composta [E13].';

-- ============================================================================
-- 11. DERIVAÇÃO DO DESEMPENHO  [E14]
--     Sucessora direta da coluna GERADA que a ampliação removeu de historico.
--     Antes, media_final_historico era `GENERATED ALWAYS AS (...) STORED` sobre
--     nota_a1/a2/p3 — três colunas fixas, 1FN disfarçada. Agora a nota vive em
--     `tb_nota` (n linhas por matrícula) e a média é DERIVADA aqui, uma vez, para
--     que consultas, views e a MV do 04 usem a MESMA regra.
--
--     A regra da P3 do modelo original é preservada: a avaliação SUBSTITUTIVA
--     troca a MENOR nota regular, e só quando é maior que ela.
--
--     Direitos do DONO (sem security_invoker), de propósito: quem consulta
--     precisa enxergar `tb_nota`/`tb_presenca` inteiras para a agregação fechar. O
--     isolamento por aluno é feito uma camada acima, em historico_aluno
--     (security_invoker = on), que filtra por `tb_matricula` — protegida por RLS.
--     Por isso esta view NÃO é concedida a papel_aluno (ver 08_seguranca.sql).
-- ============================================================================
CREATE VIEW vw_desempenho_matricula AS
WITH regulares AS (
  SELECT n.id_matricula, n.valor_nota, av.peso_avaliacao,
         row_number() OVER (PARTITION BY n.id_matricula ORDER BY n.valor_nota, av.id_avaliacao) AS posicao
  FROM tb_nota n
  JOIN tb_avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE NOT av.substitutiva_avaliacao
),
substitutiva AS (
  SELECT n.id_matricula, max(n.valor_nota) AS valor_nota
  FROM tb_nota n
  JOIN tb_avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE av.substitutiva_avaliacao
  GROUP BY n.id_matricula
),
media AS (
  SELECT r.id_matricula,
         round(sum(CASE WHEN r.posicao = 1 AND s.valor_nota > r.valor_nota
                        THEN s.valor_nota ELSE r.valor_nota END * r.peso_avaliacao)
               / sum(r.peso_avaliacao), 2)                       AS media_final,
         count(*)                                                AS avaliacoes_lancadas,
         bool_or(s.valor_nota IS NOT NULL)                       AS usou_substitutiva
  FROM regulares r
  LEFT JOIN substitutiva s ON s.id_matricula = r.id_matricula
  GROUP BY r.id_matricula
),
frequencia AS (
  SELECT p.id_matricula,
         count(*)                                                AS aulas_previstas,
         count(*) FILTER (WHERE p.presente_presenca)             AS presencas,
         round(100.0 * count(*) FILTER (WHERE p.presente_presenca) / count(*), 2)::pct_t AS frequencia
  FROM tb_presenca p
  GROUP BY p.id_matricula
)
SELECT m.id_matricula,
       m.id_aluno,
       m.id_turma,
       md.media_final,
       md.avaliacoes_lancadas,
       md.usou_substitutiva,
       fq.aulas_previstas,
       fq.presencas,
       fq.frequencia
FROM tb_matricula m
LEFT JOIN media md      ON md.id_matricula = m.id_matricula
LEFT JOIN frequencia fq ON fq.id_matricula = m.id_matricula;
COMMENT ON VIEW vw_desempenho_matricula IS
  'Média final (com a regra da substitutiva) e frequência, derivadas de nota/presenca [E14]. Sucessora da coluna gerada [C13].';


-- ============================================================================
-- 12. AUDITORIA TRANSVERSAL  [E19]
--     Três colunas em TODA tabela e dois triggers. É a única parte do modelo
--     que se aplica por igual a todas as 41 — e por isso entra num laço, não
--     copiada 41 vezes.
-- ============================================================================

-- criado_em / atualizado_em / excluido_em em todas as tabelas de dados.
-- log_auditoria fica de fora: ela é append-only e já tem `ocorrido_em`;
-- auditar a própria auditoria seria recursão sem ganho.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academico' AND tablename <> 'tb_log_auditoria'
           ORDER BY tablename
  LOOP
    EXECUTE format(
      'ALTER TABLE %I
         ADD COLUMN criado_em     timestamptz NOT NULL DEFAULT now(),
         ADD COLUMN atualizado_em timestamptz,
         ADD COLUMN excluido_em   timestamptz', t);
  END LOOP;
END $$;

COMMENT ON COLUMN tb_matricula.excluido_em IS
  'Exclusão lógica: preenchida em vez de apagar a linha. NULL = ativa.';

-- Marca a hora da última alteração. BEFORE UPDATE porque precisa alterar NEW
-- antes da gravação — um AFTER não conseguiria.
CREATE FUNCTION f_marca_atualizacao() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $$;

-- Grava a trilha. AFTER e RETURN NULL: o trigger não interfere na operação,
-- só registra o que já aconteceu. `to_jsonb(OLD/NEW)` guarda a linha inteira,
-- então a trilha continua legível mesmo se a tabela ganhar colunas depois.
CREATE FUNCTION f_auditoria() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO academico.tb_log_auditoria (nome_tabela, acao_log, dados_antes, dados_depois)
  VALUES (TG_TABLE_NAME,
          lower(TG_OP)::acao_log_t,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

-- f_marca_atualizacao vale para todas; f_auditoria só para as tabelas onde
-- "quem mudou o quê" é pergunta real. Auditar as 5.570 cidades do IBGE — dado
-- de referência que ninguém edita — seria encher a trilha de ruído e esconder
-- o que importa. As cinco escolhidas são as que guardam pessoa, vínculo e nota.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academico' AND tablename <> 'tb_log_auditoria'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_atualizacao BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_marca_atualizacao()', t, t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['tb_pessoa','tb_aluno','tb_matricula','tb_nota','tb_historico']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_auditoria AFTER INSERT OR UPDATE OR DELETE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_auditoria()', t, t);
  END LOOP;
END $$;

COMMIT;

-- [C15] sessões novas nascem com o search_path certo, em qualquer banco:
SELECT format('ALTER DATABASE %I SET search_path TO academico, public', current_database())
\gexec

\echo '=== Esquema ampliado criado. Tabelas: ==='
SELECT count(*) AS tabelas FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE';
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE' ORDER BY table_name;

-- ############################################################################
-- ### sql/02_carga.sql
-- ############################################################################

-- ============================================================================
-- 02_carga.sql — Marco 1 · Carga de dados do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Requisitos do enunciado: >= 100 alunos, >= 6 turmas, >= 300 matrículas
-- (generate_series permitido). Esta carga produz 120 alunos, 34 turmas em
-- 4 períodos letivos (2025/1 a 2026/2) e ~700 matrículas — agora com o
-- registro FINO que a ampliação criou: aulas, presenças, avaliações e notas.
--
-- A carga é 100% DETERMINÍSTICA (aritmética modular, sem random()):
-- reexecutar produz exatamente os mesmos dados — importante para
-- reproduzibilidade das consultas e das evidências de EXPLAIN do Marco 2.
--
-- O QUE MUDOU COM A AMPLIAÇÃO (ver docs/modelo-tabelas.drawio, página 2):
--   [E1] geografia: pais -> estado -> cidade -> endereco antes de qualquer campus
--   [E2] pessoa é o supertipo: nome/e-mail/CPF/nascimento saíram de aluno e
--        professor; a carga cria a pessoa e DEPOIS a especialização
--   [E4] usuario espelha a ROLE do PostgreSQL (login_usuario = nome da role)
--   [E11] o professor da turma virou turma_professor (titular + auxiliar)
--   [E14] nota_a1/a2/p3 sumiram de historico: agora são avaliacao + nota, e
--        a frequência sai de presenca. historico guarda só o CONSOLIDADO.
--
-- Cenários plantados de propósito (usados pelas consultas e pelo Marco 2):
--   · TABD-N1 (2026/2) com 8 vagas e 7 confirmadas  -> 1 vaga p/ disputa (Marco 2)
--   · COMP1-N1 (2026/2) sem nenhuma matrícula       -> junção externa (consulta 3)
--   · LBD2-N1 (2026/2) EAD, sem sala                -> EXCLUDE parcial [E12]
--   · alunos com 3-4 semestres de notas             -> LAG/evolução (consulta 8)
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/02_carga.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


BEGIN;

-- Idempotência: limpa dados preservando o esquema. A ordem não importa por
-- causa do CASCADE, mas a lista é explícita para que uma tabela nova nunca
-- fique de fora silenciosamente.
TRUNCATE tb_pais, tb_estado, tb_cidade, tb_endereco, tb_pessoa, tb_telefone, tb_documento_pessoa,
         tb_usuario, tb_campus, tb_departamento, tb_predio, tb_sala, tb_recurso, tb_sala_recurso,
         tb_professor, tb_formacao_professor, tb_curso, tb_coordenacao_curso, tb_curriculo,
         tb_disciplina, tb_curriculo_disciplina, tb_pre_requisito, tb_aluno,
         tb_aproveitamento_materia, tb_periodo_letivo, tb_periodo_matricula, tb_feriado,
         tb_turma, tb_turma_professor, tb_turma_horario, tb_plano_ensino,
         tb_unidade_plano_ensino, tb_bibliografia, tb_plano_ensino_bibliografia,
         tb_matricula, tb_historico, tb_log_auditoria, tb_aula, tb_presenca, tb_avaliacao, tb_nota
RESTART IDENTITY CASCADE;

-- ============================================================================
-- 1. GEOGRAFIA  [E1]
--    A cadeia inteira nasce aqui: nenhum endereço existe sem cidade, nenhuma
--    cidade sem estado, nenhum estado sem país. É o fim do "Brasília" digitado
--    à mão em cada campus.
-- ============================================================================
INSERT INTO tb_pais (nome_pais, sigla_pais) VALUES ('Brasil', 'BR');

INSERT INTO tb_estado (id_pais, nome_estado, uf_estado)
SELECT p.id_pais, v.nome, v.uf
FROM (VALUES
  ('Distrito Federal', 'DF'), ('Goiás', 'GO'), ('Minas Gerais', 'MG'),
  ('São Paulo', 'SP'),        ('Bahia', 'BA')
) AS v(nome, uf), tb_pais p;

INSERT INTO tb_cidade (id_estado, nome_cidade, codigo_ibge_cidade)
SELECT e.id_estado, v.nome, v.ibge
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
) AS v(uf, nome, ibge)
JOIN tb_estado e ON e.uf_estado = v.uf;

-- Endereços institucionais (os dois campi)
INSERT INTO tb_endereco (id_cidade, logradouro_endereco, numero_endereco, complemento_endereco, bairro_endereco, cep_endereco)
SELECT c.id_cidade, v.log, v.num, v.compl, v.bairro, v.cep
FROM (VALUES
  ('Brasília', 'SEPN 707/907', '1',   'Campus A',   'Asa Norte', '70790075'),
  ('Brasília', 'SGAS 613/614', '255', 'Campus B',   'Asa Sul',   '70200730')
) AS v(tb_cidade, log, num, compl, bairro, cep)
JOIN tb_cidade c ON c.nome_cidade = v.tb_cidade;

INSERT INTO tb_campus (id_endereco, nome_campus)
SELECT e.id_endereco, v.nome
FROM (VALUES
  ('Campus B', 'Asa Sul'),
  ('Campus A', 'Asa Norte')
) AS v(compl, nome)
JOIN tb_endereco e ON e.complemento_endereco = v.compl;

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
  INSERT INTO tb_endereco (id_cidade, logradouro_endereco, numero_endereco, bairro_endereco, cep_endereco)
  SELECT c.id_cidade,
         'Quadra ' || (100 + g.i % 400) || ' Conjunto ' || chr(65 + g.i % 20),
         ((g.i * 7) % 900 + 1)::text,
         (ARRAY['Asa Norte','Asa Sul','Taguatinga','Águas Claras','Sudoeste',
                'Guará','Ceilândia','Samambaia'])[1 + g.i % 8],
         lpad((70000000 + (g.i * 137) % 900000)::text, 8, '0')
  FROM generate_series(1, 132) AS g(i)
  JOIN LATERAL (
    SELECT id_cidade FROM tb_cidade
    ORDER BY CASE WHEN g.i % 10 < 7 THEN 0 ELSE 1 END,   -- 70% Brasília
             CASE WHEN g.i % 10 < 7 THEN 0 ELSE (id_cidade + g.i) % 9 END,
             id_cidade
    LIMIT 1
  ) c ON true
  RETURNING id_endereco
)
INSERT INTO tb_pessoa (id_endereco, nome_pessoa, email_pessoa, cpf_pessoa, nascimento_pessoa)
SELECT e.id_endereco, x.nome, x.email, x.cpf, x.nasc
FROM (
  -- (a) 10 docentes — nomes fixos, os mesmos da carga anterior
  SELECT 1 AS grupo, v.ord, v.nome,
         v.email,
         lpad((90000000000 + v.ord * 7654321)::text, 11, '0')::char(11) AS cpf,
         DATE '1970-01-01' + (v.ord * 613) AS nasc
  FROM (VALUES
    (1,'Marcos Tanaka','marcos.tanaka@iesb.br'),   (2,'Luciana Prado','luciana.prado@iesb.br'),
    (3,'André Vieira','andre.vieira@iesb.br'),     (4,'Camila Duarte','camila.duarte@iesb.br'),
    (5,'Ricardo Nóbrega','ricardo.nobrega@iesb.br'),(6,'Sofia Rezende','sofia.rezende@iesb.br'),
    (7,'Tiago Sales','tiago.sales@iesb.br'),       (8,'Vera Lúcia Pinto','vera.pinto@iesb.br'),
    (9,'Paulo César Lima','paulo.lima@iesb.br'),   (10,'Helena Barros','helena.barros@iesb.br')
  ) AS v(ord, nome, email)
  UNION ALL
  -- (b) 2 servidores técnicos: a secretaria acadêmica e o DBA
  SELECT 2, v.ord, v.nome, v.email,
         lpad((95000000000 + v.ord * 1234567)::text, 11, '0')::char(11),
         DATE '1985-05-10' + (v.ord * 97)
  FROM (VALUES
    (1, 'Juliana Freitas', 'juliana.freitas@iesb.br'),
    (2, 'Gabriel Kuhn Paz', 'gabriel.paz@iesb.br')
  ) AS v(ord, nome, email)
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
  SELECT id_endereco,
         row_number() OVER (ORDER BY id_endereco) AS rn
  FROM ends
) e ON e.rn = CASE x.grupo WHEN 1 THEN x.ord
                          WHEN 2 THEN 10 + x.ord
                          ELSE 12 + x.ord END;

-- Telefones [E3]: um celular principal para todos; fixo adicional a cada 3.
INSERT INTO tb_telefone (id_pessoa, numero_telefone, principal_telefone, tipo_telefone)
SELECT p.id_pessoa,
       '(61) 9' || lpad(((p.id_pessoa * 81721) % 100000000)::text, 8, '0'),
       true, 'celular'
FROM tb_pessoa p;

INSERT INTO tb_telefone (id_pessoa, numero_telefone, principal_telefone, tipo_telefone)
SELECT p.id_pessoa,
       '(61) 3' || lpad(((p.id_pessoa * 5417) % 10000000)::text, 7, '0'),
       false, 'residencial'
FROM tb_pessoa p
WHERE p.id_pessoa % 3 = 0;

-- Documentos [E3]: RG para todos (o CPF NÃO entra aqui — é 1:1 com a pessoa
-- e por isso vive em pessoa.cpf_pessoa [E2]); CNH para uma parte.
INSERT INTO tb_documento_pessoa (id_pessoa, numero_documento_pessoa, orgao_documento_pessoa, emissao_documento_pessoa, tipo_documento_pessoa)
SELECT p.id_pessoa,
       lpad(((p.id_pessoa * 314159) % 10000000)::text, 7, '0'),
       (ARRAY['SSP/DF','SSP/GO','SSP/MG','SSP/SP','SSP/BA'])[1 + p.id_pessoa % 5],
       p.nascimento_pessoa + interval '18 years',
       'rg'
FROM tb_pessoa p;

INSERT INTO tb_documento_pessoa (id_pessoa, numero_documento_pessoa, orgao_documento_pessoa, emissao_documento_pessoa, tipo_documento_pessoa)
SELECT p.id_pessoa,
       lpad(((p.id_pessoa * 2718281) % 100000000000)::text, 11, '0'),
       'DETRAN/DF',
       p.nascimento_pessoa + interval '20 years',
       'cnh'
FROM tb_pessoa p
WHERE p.id_pessoa % 5 = 0;

-- ============================================================================
-- 3. INFRAESTRUTURA  [E5] [E6]
-- ============================================================================
INSERT INTO tb_departamento (id_campus, nome_departamento, sigla_departamento)
SELECT c.id_campus, v.nome, v.sigla
FROM (VALUES
  ('Asa Sul',   'Departamento de Ciência da Computação', 'DCC'),
  ('Asa Sul',   'Departamento de Matemática',            'DMAT'),
  ('Asa Norte', 'Departamento de Gestão',                'DGES')
) AS v(tb_campus, nome, sigla)
JOIN tb_campus c ON c.nome_campus = v.tb_campus;

-- [E5] sala não pertence mais ao campus direto: pertence ao PRÉDIO.
INSERT INTO tb_predio (id_campus, nome_predio, andares_predio)
SELECT c.id_campus, v.nome, v.andares
FROM (VALUES
  ('Asa Sul',   'Bloco A', 4),
  ('Asa Sul',   'Bloco B', 3),
  ('Asa Norte', 'Bloco Único', 5),
  ('Asa Norte', 'Anexo Laboratórios', 2)
) AS v(tb_campus, nome, andares)
JOIN tb_campus c ON c.nome_campus = v.tb_campus;

-- "T101" existe nos DOIS campi: continua legal, agora por UNIQUE(predio, codigo) [C4→E5]
INSERT INTO tb_sala (id_predio, codigo_sala, andar_sala, capacidade_sala, tipo_sala)
SELECT pr.id_predio, v.codigo, v.andar, v.cap, v.tipo::tipo_sala_t
FROM (VALUES
  ('Asa Sul',   'Bloco A',            'T101', 1, 60,  'teorica'),
  ('Asa Sul',   'Bloco A',            'T102', 1, 60,  'teorica'),
  ('Asa Sul',   'Bloco A',            'T103', 2, 45,  'teorica'),
  ('Asa Sul',   'Bloco B',            'L201', 2, 25,  'laboratorio'),
  ('Asa Sul',   'Bloco B',            'L202', 2, 25,  'laboratorio'),
  ('Asa Sul',   'Bloco B',            'AUD1', 1, 120, 'auditorio'),
  ('Asa Norte', 'Bloco Único',        'T101', 1, 50,  'teorica'),
  ('Asa Norte', 'Bloco Único',        'T102', 1, 40,  'teorica'),
  ('Asa Norte', 'Anexo Laboratórios', 'L101', 1, 25,  'laboratorio')
) AS v(tb_campus, tb_predio, codigo, andar, cap, tipo)
JOIN tb_campus c  ON c.nome_campus = v.tb_campus
JOIN tb_predio pr ON pr.id_campus = c.id_campus AND pr.nome_predio = v.tb_predio;

INSERT INTO tb_recurso (nome_recurso) VALUES
  ('Projetor multimídia'), ('Quadro branco'), ('Ar-condicionado'),
  ('Computadores'), ('Lousa digital');

-- Recursos por sala: quadro em todas; projetor e ar na maioria; computadores
-- só em laboratório (a regra que justifica a tabela existir).
INSERT INTO tb_sala_recurso (id_sala, id_recurso, quantidade_sala_recurso)
SELECT s.id_sala, r.id_recurso,
       CASE r.nome_recurso WHEN 'Computadores' THEN s.capacidade_sala ELSE 1 END
FROM tb_sala s
CROSS JOIN tb_recurso r
WHERE (r.nome_recurso = 'Quadro branco')
   OR (r.nome_recurso = 'Projetor multimídia' AND s.id_sala % 4 <> 0)
   OR (r.nome_recurso = 'Ar-condicionado'     AND s.id_sala % 3 <> 0)
   OR (r.nome_recurso = 'Computadores'        AND s.tipo_sala = 'laboratorio')
   OR (r.nome_recurso = 'Lousa digital'       AND s.tipo_sala = 'auditorio');

-- ============================================================================
-- 4. DOCENTES  [E2] [E6]
-- ============================================================================
INSERT INTO tb_professor (id_pessoa, id_departamento, matricula_professor, regime_professor, titulacao_professor)
SELECT p.id_pessoa, d.id_departamento, v.mat, v.regime::regime_professor_t, v.titulacao::titulacao_t
FROM (VALUES
  ('marcos.tanaka@iesb.br',   'P0001', 'DCC',  'integral', 'doutorado'),
  ('luciana.prado@iesb.br',   'P0002', 'DMAT', 'integral', 'doutorado'),
  ('andre.vieira@iesb.br',    'P0003', 'DCC',  'parcial',  'mestrado'),
  ('camila.duarte@iesb.br',   'P0004', 'DCC',  'integral', 'doutorado'),
  ('ricardo.nobrega@iesb.br', 'P0005', 'DCC',  'parcial',  'mestrado'),
  ('sofia.rezende@iesb.br',   'P0006', 'DGES', 'horista',  'especializacao'),
  ('tiago.sales@iesb.br',     'P0007', 'DCC',  'parcial',  'mestrado'),
  ('vera.pinto@iesb.br',      'P0008', 'DMAT', 'integral', 'doutorado'),
  ('paulo.lima@iesb.br',      'P0009', 'DCC',  'parcial',  'mestrado'),
  ('helena.barros@iesb.br',   'P0010', 'DGES', 'horista',  'especializacao')
) AS v(email, mat, sigla, regime, titulacao)
JOIN tb_pessoa p       ON p.email_pessoa = v.email
JOIN tb_departamento d ON d.sigla_departamento = v.sigla;

-- Formações [E3]: a graduação de todos, e a pós de quem tem título maior.
INSERT INTO tb_formacao_professor (id_professor, curso_formacao_professor, instituicao_formacao_professor, ano_conclusao_formacao_professor, titulacao_formacao_professor)
SELECT pr.id_professor, 'Ciência da Computação',
       (ARRAY['UnB','UFG','USP','UFMG','PUC'])[1 + pr.id_professor % 5],
       1995 + (pr.id_professor * 3) % 15, 'graduacao'
FROM tb_professor pr
UNION ALL
SELECT pr.id_professor,
       CASE pr.titulacao_professor WHEN 'doutorado' THEN 'Doutorado em Informática'
                                   WHEN 'mestrado'  THEN 'Mestrado em Informática'
                                   ELSE 'Especialização em Banco de Dados' END,
       (ARRAY['UnB','USP','UFRJ','UFPE','UNICAMP'])[1 + (pr.id_professor * 2) % 5],
       2008 + (pr.id_professor * 2) % 14, pr.titulacao_professor
FROM tb_professor pr
WHERE pr.titulacao_professor <> 'graduacao';

-- [E6] chefia: a FK circular criada por ALTER, com UNIQUE (um chefe por professor).
UPDATE tb_departamento d
SET id_professor_chefe = pr.id_professor
FROM tb_professor pr, tb_pessoa p
WHERE pr.id_pessoa = p.id_pessoa
  AND (d.sigla_departamento, p.email_pessoa) IN (
        ('DCC',  'marcos.tanaka@iesb.br'),
        ('DMAT', 'vera.pinto@iesb.br'),
        ('DGES', 'helena.barros@iesb.br'));

-- ============================================================================
-- 5. USUÁRIOS  [E4]
--    login_usuario É o nome da ROLE do PostgreSQL. O 08_seguranca.sql cria as
--    roles com exatamente estes nomes — e f_usuario_sessao() liga uma coisa
--    à outra em tempo de execução, sem tabela de-para separada.
-- ============================================================================
INSERT INTO tb_usuario (id_pessoa, login_usuario, papel_usuario)
SELECT p.id_pessoa, v.login, v.papel::papel_usuario_t
FROM (VALUES
  ('juliana.freitas@iesb.br', 'secretaria',  'secretaria'),
  ('gabriel.paz@iesb.br',     'bd2',         'admin'),        -- o DBA da disciplina
  ('marcos.tanaka@iesb.br',   'coordenacao', 'coordenacao')
) AS v(email, login, papel)
JOIN tb_pessoa p ON p.email_pessoa = v.email;

-- ============================================================================
-- 6. CURSOS, CURRÍCULOS E DISCIPLINAS
-- ============================================================================
INSERT INTO tb_curso (id_campus, id_departamento, codigo_curso, nome_curso, ch_total_curso, grau_curso, modalidade_curso)
SELECT c.id_campus, d.id_departamento, v.codigo, v.nome, v.ch,
       v.grau::grau_curso_t, v.modalidade::modalidade_t
FROM (VALUES
  ('CC',  'Ciência da Computação',                 3200, 'bacharelado', 'Asa Sul',   'DCC',  'presencial'),
  ('SI',  'Sistemas de Informação',                3000, 'bacharelado', 'Asa Sul',   'DCC',  'presencial'),
  ('ADS', 'Análise e Desenvolvimento de Sistemas', 2400, 'tecnologo',   'Asa Norte', 'DGES', 'hibrido')
) AS v(codigo, nome, ch, grau, tb_campus, sigla, modalidade)
JOIN tb_campus c       ON c.nome_campus = v.tb_campus
JOIN tb_departamento d ON d.sigla_departamento = v.sigla;

-- [E8] coordenação COM VIGÊNCIA: o EXCLUDE gist garante um coordenador por
-- curso a cada instante. O mandato encerrado de CC prova que o histórico cabe
-- na mesma tabela — o que uma coluna id_coordenador em curso não permitiria.
INSERT INTO tb_coordenacao_curso (id_curso, id_professor, portaria_coordenacao_curso, vigencia_coordenacao_curso)
SELECT c.id_curso, pr.id_professor, v.portaria, v.vig
FROM (VALUES
  ('CC',  'P0004', 'PORT-2021-014', daterange(DATE '2021-01-01', DATE '2024-01-01', '[)')),
  ('CC',  'P0001', 'PORT-2024-003', daterange(DATE '2024-01-01', NULL, '[)')),
  ('SI',  'P0005', 'PORT-2023-021', daterange(DATE '2023-03-01', NULL, '[)')),
  ('ADS', 'P0010', 'PORT-2022-008', daterange(DATE '2022-08-01', NULL, '[)'))
) AS v(tb_curso, prof, portaria, vig)
JOIN tb_curso c     ON c.codigo_curso = v.tb_curso
JOIN tb_professor pr ON pr.matricula_professor = v.prof;

INSERT INTO tb_curriculo (id_curso, portaria_curriculo, ano_vigencia_curriculo, ativo_curriculo)
SELECT c.id_curso, v.portaria, v.ano, v.ativo
FROM (VALUES
  ('CC',  'RES-2023-091', 2024, false),   -- matriz antiga (ingressantes 2024/2025)
  ('CC',  'RES-2025-112', 2026, true),    -- matriz vigente
  ('SI',  'RES-2024-077', 2025, true),
  ('ADS', 'RES-2024-078', 2025, true)
) AS v(tb_curso, portaria, ano, ativo)
JOIN tb_curso c ON c.codigo_curso = v.tb_curso;

-- Catálogo de disciplinas — ch_total é coluna GERADA [C13], não se insere.
-- Cada disciplina agora tem DONO (departamento) [E6] e ementa.
INSERT INTO tb_disciplina (id_departamento, codigo_disciplina, nome_disciplina, ementa_disciplina, ch_teorica_disciplina, ch_pratica_disciplina)
SELECT d.id_departamento, v.codigo, v.nome,
       'Ementa de ' || v.nome || '. Conteúdo programático detalhado no plano de ensino vigente.',
       v.teo, v.pra
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
) AS v(sigla, codigo, nome, teo, pra)
JOIN tb_departamento d ON d.sigla_departamento = v.sigla;

-- [E17] Cadeia de pré-requisitos, agora POR CURRÍCULO.
-- Profundidade 4 na matriz de CC: TABD -> BD2 -> BD1 -> ED1 -> ALG1.
-- O INSERT roda depois da grade (curriculo_disciplina) porque as duas FKs
-- compostas exigem que disciplina e requisito já estejam naquela matriz — e
-- é justamente isso que o modelo passou a garantir.
-- O co-requisito LBD2/BD2 saiu junto com a coluna `vinculo`.
-- Fica logo abaixo do bloco da grade.
INSERT INTO tb_curriculo_disciplina (id_curriculo, id_disciplina, periodo_curriculo_disciplina, tipo_curriculo_disciplina)
SELECT cu.id_curriculo, d.id_disciplina, v.periodo, v.tipo::tipo_disc_t
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
) AS v(tb_curso, ano, disc, periodo, tipo)
JOIN tb_curso c      ON c.codigo_curso = v.tb_curso
JOIN tb_curriculo cu ON cu.id_curso = c.id_curso AND cu.ano_vigencia_curriculo = v.ano
JOIN tb_disciplina d ON d.codigo_disciplina = v.disc;

-- A mesma aresta vale em toda matriz onde as DUAS matérias existem. O último
-- JOIN é o que garante isso: se o requisito não está naquele currículo, a
-- linha simplesmente não é gerada — espelhando a restrição que o modelo impõe.
INSERT INTO tb_pre_requisito (id_curriculo, id_disciplina, id_requisito)
SELECT cd.id_curriculo, d.id_disciplina, r.id_disciplina
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
) AS v(disc, req)
JOIN tb_disciplina d ON d.codigo_disciplina = v.disc
JOIN tb_disciplina r ON r.codigo_disciplina = v.req
JOIN tb_curriculo_disciplina cd ON cd.id_disciplina = d.id_disciplina
JOIN tb_curriculo_disciplina cr ON cr.id_curriculo = cd.id_curriculo
                               AND cr.id_disciplina = r.id_disciplina;

-- ============================================================================
-- 7. CALENDÁRIO  [E9] [E10]
-- ============================================================================
INSERT INTO tb_periodo_letivo (ano_periodo_letivo, semestre_periodo_letivo, data_inicio_periodo_letivo, data_fim_periodo_letivo) VALUES
  (2025, 1, DATE '2025-02-03', DATE '2025-07-05'),
  (2025, 2, DATE '2025-08-04', DATE '2025-12-20'),
  (2026, 1, DATE '2026-02-02', DATE '2026-07-04'),
  (2026, 2, DATE '2026-08-03', DATE '2026-12-19');   -- período corrente

-- [E9] janelas de matrícula: o EXCLUDE gist impede duas janelas do MESMO tipo
-- se sobreporem no mesmo período. Tipos diferentes PODEM conviver — e convivem:
-- o ajuste começa antes de a matrícula terminar, de propósito.
INSERT INTO tb_periodo_matricula (id_periodo_letivo, descricao_periodo_matricula, janela_periodo_matricula, tipo_periodo_matricula)
SELECT pl.id_periodo_letivo, v.descricao,
       tstzrange(
         (pl.data_inicio_periodo_letivo + v.ini)::timestamptz,
         (pl.data_inicio_periodo_letivo + v.fim)::timestamptz, '[)'),
       v.tipo::tipo_periodo_matricula_t
FROM tb_periodo_letivo pl
CROSS JOIN (VALUES
  ('Matrícula regular',   -30, -10, 'matricula'),
  ('Rematrícula',         -45, -30, 'rematricula'),
  ('Ajuste de matrícula', -12,   7, 'ajuste'),
  ('Trancamento',          15,  60, 'trancamento')
) AS v(descricao, ini, fim, tipo);

-- [E10] feriado por ARCO EXCLUSIVO: exatamente uma das 4 FKs preenchida.
-- O "tipo" (nacional/estadual/…) NÃO é coluna: seria derivável do arco (3FN).
INSERT INTO tb_feriado (id_pais, descricao_feriado, data_feriado, facultativo_feriado)
SELECT p.id_pais, v.descricao, v.data::date, v.facultativo
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
) AS v(data, descricao, facultativo), tb_pais p;

INSERT INTO tb_feriado (id_estado, descricao_feriado, data_feriado, facultativo_feriado)
SELECT e.id_estado, 'Dia do Evangélico (DF)', DATE '2026-11-30', false
FROM tb_estado e WHERE e.uf_estado = 'DF';

INSERT INTO tb_feriado (id_cidade, descricao_feriado, data_feriado, facultativo_feriado)
SELECT c.id_cidade, 'Aniversário de Brasília', DATE '2026-04-21', false
FROM tb_cidade c WHERE c.nome_cidade = 'Brasília';

INSERT INTO tb_feriado (id_campus, descricao_feriado, data_feriado, facultativo_feriado)
SELECT c.id_campus, 'Dia do Folclore — evento interno', DATE '2026-08-22', true
FROM tb_campus c WHERE c.nome_campus = 'Asa Norte';

-- ============================================================================
-- 8. TURMAS, DOCÊNCIA E HORÁRIOS  [E11] [E12]
-- ============================================================================
INSERT INTO tb_turma (id_disciplina, id_periodo_letivo, codigo_turma, vagas_turma, turno_turma, modalidade_turma)
SELECT d.id_disciplina, pl.id_periodo_letivo, v.codigo, v.vagas,
       v.turno::turno_t, v.modalidade::modalidade_t
FROM (VALUES
  -- 2025/1
  (2025, 1, 'ALG1',  'ALG1-N1',  'noturno',  50, 'presencial'),
  (2025, 1, 'MAT1',  'MAT1-N1',  'noturno',  50, 'presencial'),
  (2025, 1, 'ED1',   'ED1-N1',   'noturno',  40, 'presencial'),
  (2025, 1, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2025, 1, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2025, 1, 'ETI',   'ETI-M1',   'matutino', 60, 'presencial'),
  -- 2025/2
  (2025, 2, 'ED1',   'ED1-N1',   'noturno',  40, 'presencial'),
  (2025, 2, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2025, 2, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2025, 2, 'SO1',   'SO1-N1',   'noturno',  35, 'presencial'),
  (2025, 2, 'LFA',   'LFA-N1',   'noturno',  35, 'presencial'),
  (2025, 2, 'EST1',  'EST1-M1',  'matutino', 45, 'presencial'),
  (2025, 2, 'EMP',   'EMP-M1',   'matutino', 60, 'presencial'),
  -- 2026/1
  (2026, 1, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2026, 1, 'BD2',   'BD2-N1',   'noturno',  35, 'presencial'),
  (2026, 1, 'ENG1',  'ENG1-N1',  'noturno',  40, 'presencial'),
  (2026, 1, 'SO1',   'SO1-N1',   'noturno',  35, 'presencial'),
  (2026, 1, 'IA1',   'IA1-N1',   'noturno',  30, 'presencial'),
  (2026, 1, 'RED1',  'RED1-N1',  'noturno',  35, 'presencial'),
  (2026, 1, 'WEB1',  'WEB1-M1',  'matutino', 30, 'presencial'),
  -- 2026/2 (período corrente — a "grade viva")
  (2026, 2, 'ALG1',  'ALG1-M1',  'matutino', 45, 'presencial'),
  (2026, 2, 'ALG1',  'ALG1-N1',  'noturno',  50, 'presencial'),
  (2026, 2, 'ED1',   'ED1-M1',   'matutino', 40, 'presencial'),
  (2026, 2, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2026, 2, 'BD1',   'BD1-M1',   'matutino', 35, 'presencial'),
  (2026, 2, 'BD1',   'BD1-N1',   'noturno',  35, 'presencial'),
  (2026, 2, 'BD2',   'BD2-N1',   'noturno',  30, 'presencial'),
  (2026, 2, 'ENG1',  'ENG1-N1',  'noturno',  40, 'presencial'),
  (2026, 2, 'IA1',   'IA1-N1',   'noturno',  30, 'presencial'),
  (2026, 2, 'LFA',   'LFA-M1',   'matutino', 35, 'presencial'),
  (2026, 2, 'TABD',  'TABD-N1',  'noturno',   8, 'presencial'),  -- disputa da última vaga (Marco 2)
  (2026, 2, 'COMP1', 'COMP1-N1', 'noturno',  25, 'presencial'),  -- ficará SEM matrículas (consulta 3)
  (2026, 2, 'LBD2',  'LBD2-N1',  'noturno',  20, 'ead'),         -- EAD: sem sala [E12]
  (2026, 2, 'WEB1',  'WEB1-M1',  'matutino', 30, 'presencial')
) AS v(ano, sem, disc, codigo, turno, vagas, modalidade)
JOIN tb_periodo_letivo pl ON pl.ano_periodo_letivo = v.ano AND pl.semestre_periodo_letivo = v.sem
JOIN tb_disciplina d      ON d.codigo_disciplina = v.disc;

-- [E11] co-docência: o titular (um só por turma, garantido por índice parcial
-- único) e, nas turmas com prática, um auxiliar. Era uma coluna id_professor
-- em turma; virou tabela porque a realidade tem mais de um docente.
INSERT INTO tb_turma_professor (id_turma, id_professor, ch_turma_professor, papel_turma_professor)
SELECT t.id_turma, pr.id_professor, d.ch_total_disciplina, 'titular'
FROM tb_turma t
JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
JOIN tb_professor pr ON pr.matricula_professor = (CASE d.codigo_disciplina
        WHEN 'ALG1'  THEN 'P0001' WHEN 'MAT1'  THEN 'P0002' WHEN 'ED1'   THEN 'P0003'
        WHEN 'POO1'  THEN 'P0004' WHEN 'BD1'   THEN 'P0005' WHEN 'ETI'   THEN 'P0006'
        WHEN 'SO1'   THEN 'P0007' WHEN 'LFA'   THEN 'P0008' WHEN 'EST1'  THEN 'P0002'
        WHEN 'EMP'   THEN 'P0006' WHEN 'BD2'   THEN 'P0001' WHEN 'ENG1'  THEN 'P0004'
        WHEN 'IA1'   THEN 'P0009' WHEN 'RED1'  THEN 'P0010' WHEN 'WEB1'  THEN 'P0003'
        WHEN 'TABD'  THEN 'P0001' WHEN 'COMP1' THEN 'P0010' WHEN 'LBD2'  THEN 'P0005'
        WHEN 'GPI'   THEN 'P0010' ELSE 'P0009' END);

-- auxiliar nas turmas com carga prática (o laboratório precisa de dois)
INSERT INTO tb_turma_professor (id_turma, id_professor, ch_turma_professor, papel_turma_professor)
SELECT t.id_turma, pr.id_professor, d.ch_pratica_disciplina, 'auxiliar'
FROM tb_turma t
JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina AND d.ch_pratica_disciplina >= 30
JOIN LATERAL (
  SELECT p2.id_professor FROM tb_professor p2
  WHERE p2.id_professor <> (SELECT tp.id_professor FROM tb_turma_professor tp
                            WHERE tp.id_turma = t.id_turma AND tp.papel_turma_professor = 'titular')
  ORDER BY (p2.id_professor + t.id_turma) % 10, p2.id_professor
  LIMIT 1
) pr ON true
WHERE t.id_turma % 2 = 0;

-- ----------------------------------------------------------------------------
-- Horários: 2 encontros semanais por turma, gerados deterministicamente.
-- Combinações (par de dias × faixa) e sala rotacionada por rn garantem que a
-- restrição de exclusão [C10] passe. Faixas: matutino 08:00/10:00, noturno
-- 19:00/20:50 — duração 1h40.
-- [E12] turma EAD entra com id_sala NULL: o EXCLUDE de sala é PARCIAL
-- (WHERE id_sala IS NOT NULL), então dois horários EAD convivem sem choque.
-- ----------------------------------------------------------------------------
WITH t AS (
  SELECT tu.id_turma, tu.id_periodo_letivo, tu.turno_turma, tu.modalidade_turma,
         row_number() OVER (PARTITION BY tu.id_periodo_letivo, tu.turno_turma
                            ORDER BY tu.codigo_turma) - 1 AS rn
  FROM tb_turma tu
), s AS (
  SELECT id_sala, row_number() OVER (ORDER BY id_sala) - 1 AS sn FROM tb_sala
)
INSERT INTO tb_turma_horario (id_turma, id_periodo_letivo, id_sala, dia_semana_turma_horario, faixa_turma_horario, tipo_aula_turma_horario)
SELECT t.id_turma, t.id_periodo_letivo,
       CASE WHEN t.modalidade_turma = 'ead' THEN NULL ELSE s.id_sala END,
       d.dia,
       CASE
         WHEN t.turno_turma = 'matutino' AND (t.rn / 2) % 2 = 0 THEN timerange(TIME '08:00', TIME '09:40')
         WHEN t.turno_turma = 'matutino'                        THEN timerange(TIME '10:00', TIME '11:40')
         WHEN (t.rn / 2) % 2 = 0                                THEN timerange(TIME '19:00', TIME '20:40')
         ELSE                                                        timerange(TIME '20:50', TIME '22:30')
       END AS faixa,
       CASE WHEN d.ord = 2 AND dd.ch_pratica_disciplina > 0 THEN 'pratica' ELSE 'teorica' END::tipo_aula_t
FROM t
JOIN tb_turma tu     ON tu.id_turma = t.id_turma
JOIN tb_disciplina dd ON dd.id_disciplina = tu.id_disciplina
JOIN s ON s.sn = t.rn % 9                                   -- 9 salas cadastradas
CROSS JOIN LATERAL (VALUES
  (1, CASE WHEN t.rn % 2 = 0 THEN 1 ELSE 2 END),            -- seg ou ter
  (2, CASE WHEN t.rn % 2 = 0 THEN 3 ELSE 4 END)             -- qua ou qui
) AS d(ord, dia);

-- ============================================================================
-- 9. PLANOS DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA (id_turma NULL = plano base). Uma turma
--    pode ter a SUA versão — e a FK composta garante que a versão só existe
--    para uma turma DAQUELA disciplina. UNIQUE NULLS NOT DISTINCT impede um
--    segundo plano base [técnica de C9].
-- ============================================================================
INSERT INTO tb_plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino, metodologia_plano_ensino, criterio_avaliacao_plano_ensino, aprovacao_plano_ensino)
SELECT d.id_disciplina, NULL,
       'Capacitar o estudante em ' || d.nome_disciplina || ', articulando teoria e prática.',
       CASE WHEN d.ch_pratica_disciplina > 0
            THEN 'Aulas expositivas dialogadas, laboratório e projeto integrador.'
            ELSE 'Aulas expositivas dialogadas, estudos dirigidos e seminários.' END,
       'Duas avaliações (A1 peso 4, A2 peso 6) e prova substitutiva conforme regimento.',
       DATE '2025-01-15'
FROM tb_disciplina d;

-- Versão de turma para as ofertas de 2026/2 de BD2 e TABD: é o caso que
-- justifica id_turma na tabela — o mesmo plano base, adaptado à oferta.
INSERT INTO tb_plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino, metodologia_plano_ensino, criterio_avaliacao_plano_ensino, aprovacao_plano_ensino)
SELECT t.id_disciplina, t.id_turma,
       'Versão 2026/2 do plano de ' || d.nome_disciplina || ': ênfase em PostgreSQL 17.',
       'Aulas expositivas, laboratório com contêiner Docker e projeto em dupla.',
       'A1 (peso 4) sobre modelagem; A2 (peso 6) sobre implementação; substitutiva conforme regimento.',
       DATE '2026-07-20'
FROM tb_turma t
JOIN tb_disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
WHERE pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
  AND d.codigo_disciplina IN ('BD2', 'TABD');

-- Unidades do plano base: 4 por disciplina, somando a CH total da disciplina.
INSERT INTO tb_unidade_plano_ensino (id_plano_ensino, titulo_unidade_plano_ensino, conteudo_unidade_plano_ensino, ordem_unidade_plano_ensino, ch_unidade_plano_ensino)
SELECT pe.id_plano_ensino,
       'Unidade ' || u.ord || ' — ' || d.codigo_disciplina,
       'Conteúdo da unidade ' || u.ord || ' de ' || d.nome_disciplina || '.',
       u.ord,
       (d.ch_total_disciplina / 4) + CASE WHEN u.ord <= d.ch_total_disciplina % 4 THEN 1 ELSE 0 END
FROM tb_plano_ensino pe
JOIN tb_disciplina d ON d.id_disciplina = pe.id_disciplina
CROSS JOIN generate_series(1, 4) AS u(ord)
WHERE pe.id_turma IS NULL;

INSERT INTO tb_bibliografia (titulo_bibliografia, autor_bibliografia, editora_bibliografia, isbn_bibliografia, ano_bibliografia, edicao_bibliografia) VALUES
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
INSERT INTO tb_plano_ensino_bibliografia (id_plano_ensino, id_bibliografia, tipo_plano_ensino_bibliografia)
SELECT pe.id_plano_ensino, b.id_bibliografia, v.tipo::tipo_bibliografia_t
FROM tb_plano_ensino pe
CROSS JOIN (VALUES ('basica', 0), ('complementar', 5)) AS v(tipo, deslo)
JOIN LATERAL (
  SELECT id_bibliografia FROM tb_bibliografia
  ORDER BY ((id_bibliografia + pe.id_plano_ensino + v.deslo) % 12), id_bibliografia
  LIMIT 1
) b ON true
WHERE pe.id_turma IS NULL
ON CONFLICT (id_plano_ensino, id_bibliografia) DO NOTHING;

-- ============================================================================
-- 10. DISCENTES  [E2]
--     120 alunos, cada um apontando para a pessoa já criada. O currículo é
--     coerente com o curso — a FK composta [C6] exige.
-- ============================================================================
INSERT INTO tb_aluno (id_pessoa, id_curso, id_curriculo, matricula_aluno, forma_ingresso_aluno, status_aluno)
SELECT p.id_pessoa, c.id_curso, cu.id_curriculo,
       -- o RA carrega o ano de ingresso: 2024 * 10000 + i  ->  "20240036" [E18]
       (b.ano_ing * 10000 + b.i)::text,
       (ARRAY['vestibular','enem','transferencia','portador_diploma'])[1 + b.i % 4]::forma_ingresso_t,
       CASE WHEN b.i % 17 = 0 THEN 'trancado' ELSE 'ativo' END::status_aluno_t
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
JOIN tb_pessoa p ON p.email_pessoa = b.email
JOIN tb_curso c  ON c.codigo_curso = b.curso_cod
JOIN tb_curriculo cu
  ON cu.id_curso = c.id_curso
 AND cu.ano_vigencia_curriculo = CASE
       WHEN b.curso_cod = 'CC' AND b.ano_ing >= 2026 THEN 2026
       WHEN b.curso_cod = 'CC'                       THEN 2024
       ELSE 2025 END;

-- Um usuário por aluno [E4]: login = 'al_' || RA, o mesmo nome que o
-- 08_seguranca.sql dá à ROLE. É essa igualdade que a RLS usa.
INSERT INTO tb_usuario (id_pessoa, login_usuario, ativo_usuario, papel_usuario)
SELECT a.id_pessoa, 'al_' || a.matricula_aluno, (a.status_aluno = 'ativo'), 'aluno'
FROM tb_aluno a;

-- ============================================================================
-- 11. MATRÍCULAS
--     Elegibilidade realista: o aluno só se matricula em turma cuja disciplina
--     pertence ao SEU currículo e cujo período começa depois do seu ingresso.
--     Seleção determinística por hash; no máximo 1 turma por disciplina/período
--     por aluno; lotação alvo ~75% das vagas (máx. 28 por turma).
-- ============================================================================
WITH pool AS (
  SELECT tu.id_turma AS id_turma, tu.codigo_turma, tu.vagas_turma, tu.id_periodo_letivo,
         tu.id_disciplina, a.id_aluno AS id_aluno, pl.data_inicio_periodo_letivo,
         (a.id_aluno * 31 + tu.id_turma * 17) % 997 AS h
  FROM tb_turma tu
  JOIN tb_periodo_letivo pl       ON pl.id_periodo_letivo = tu.id_periodo_letivo
  JOIN tb_curriculo_disciplina cd ON cd.id_disciplina = tu.id_disciplina
  JOIN tb_aluno a                 ON a.id_curriculo = cd.id_curriculo
                              AND a.status_aluno = 'ativo'
                              -- ano de ingresso vem do RA [E18]
                              AND left(a.matricula_aluno, 4)::int <= pl.ano_periodo_letivo
  WHERE tu.codigo_turma <> 'COMP1-N1'          -- deixada vazia de propósito (consulta 3)
),
sem_duplicata AS (                       -- 1 turma por (aluno, período, disciplina)
  SELECT *,
         row_number() OVER (PARTITION BY id_aluno, id_periodo_letivo, id_disciplina
                            ORDER BY h, id_turma) AS r1
  FROM pool
),
ranqueado AS (
  SELECT *,
         row_number() OVER (PARTITION BY id_turma ORDER BY h, id_aluno) AS rk
  FROM sem_duplicata
  WHERE r1 = 1
)
INSERT INTO tb_matricula (id_aluno, id_turma, data_matricula, status_matricula)
SELECT r.id_aluno,
       r.id_turma,
       (r.data_inicio_periodo_letivo - 10)::timestamptz + make_interval(hours => (r.rk * 3)::int),
       CASE
         WHEN r.codigo_turma = 'TABD-N1' THEN 'confirmada'    -- cenário da última vaga
         WHEN r.rk % 17 = 0        THEN 'cancelada'
         WHEN r.rk % 13 = 0        THEN 'trancada'
         ELSE 'confirmada'
       END::status_mat_t
FROM ranqueado r
WHERE r.rk <= CASE WHEN r.codigo_turma = 'TABD-N1'
                   THEN 7                               -- 7 de 8 vagas: sobra 1
                   ELSE LEAST((r.vagas_turma * 3) / 4, 28) END;

-- ============================================================================
-- 12. AVALIAÇÕES E NOTAS  [E14]
--     Onde antes havia nota_a1/nota_a2/nota_p3 em historico (colunas fixas,
--     violação de 1FN disfarçada), agora há avaliacao × nota. Pesos das
--     avaliações REGULARES somam 10; a substitutiva não entra na soma —
--     ela SUBSTITUI a de menor nota, que é a regra da P3 do modelo original.
-- ============================================================================
INSERT INTO tb_avaliacao (id_turma, nome_avaliacao, peso_avaliacao, data_avaliacao, substitutiva_avaliacao)
SELECT t.id_turma, v.nome, v.peso,
       pl.data_inicio_periodo_letivo + v.dia, v.subst
FROM tb_turma t
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
CROSS JOIN (VALUES
  ('A1', 4.00,  60, false),
  ('A2', 6.00, 120, false),
  ('P3', 6.00, 135, true)
) AS v(nome, peso, dia, subst);

-- Notas: só para períodos ENCERRADOS (< 2026/2) e matrículas confirmadas.
-- As fórmulas são as mesmas da carga anterior — a média continua reproduzível.
INSERT INTO tb_nota (id_avaliacao, id_matricula, id_turma, valor_nota)
SELECT av.id_avaliacao, m.id_matricula, m.id_turma,
       CASE av.nome_avaliacao
         WHEN 'A1' THEN round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
         WHEN 'A2' THEN round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)
         ELSE           round((4   + ((m.id_aluno * 41 + m.id_turma * 7)  % 56) / 10.0)::numeric, 1)
       END
FROM tb_matricula m
JOIN tb_turma tu          ON tu.id_turma = m.id_turma
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
JOIN tb_avaliacao av      ON av.id_turma = m.id_turma
WHERE m.status_matricula = 'confirmada'
  AND (
    NOT av.substitutiva_avaliacao                       -- A1 e A2 para todos
    OR (                                                -- P3 só para quem precisa
      (0.4 * round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
     + 0.6 * round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)) < 5
      AND m.id_aluno % 3 <> 0
    )
  );

-- ============================================================================
-- 13. AULAS E PRESENÇAS  [E13]
--     A frequência deixou de ser um número digitado: ela EMERGE das presenças.
--     Aula pula feriado — a regra que o modelo do professor não conseguia
--     expressar porque não tinha aula nenhuma.
-- ============================================================================
INSERT INTO tb_aula (id_turma_horario, id_unidade_plano_ensino, id_turma, conteudo_aula, data_aula, realizada_aula)
SELECT th.id_turma_horario, u.id_unidade_plano_ensino, th.id_turma,
       'Encontro ' || dt.n || ' — ' || d.codigo_disciplina,
       dt.data, true
FROM tb_turma_horario th
JOIN tb_turma t           ON t.id_turma = th.id_turma
JOIN tb_disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = th.id_periodo_letivo
CROSS JOIN LATERAL (
  -- 18 semanas a partir do primeiro dia da semana pedido pelo horário
  SELECT row_number() OVER (ORDER BY g.d) AS n, g.d AS data
  FROM generate_series(
         pl.data_inicio_periodo_letivo
           + ((th.dia_semana_turma_horario - EXTRACT(ISODOW FROM pl.data_inicio_periodo_letivo)::int + 7) % 7),
         pl.data_fim_periodo_letivo, interval '7 days') AS g(d)
  LIMIT 18
) dt
LEFT JOIN LATERAL (                                  -- distribui as 4 unidades
  SELECT ue.id_unidade_plano_ensino
  FROM tb_plano_ensino pe
  JOIN tb_unidade_plano_ensino ue ON ue.id_plano_ensino = pe.id_plano_ensino
  WHERE pe.id_disciplina = t.id_disciplina AND pe.id_turma IS NULL
    AND ue.ordem_unidade_plano_ensino = LEAST(4, 1 + ((dt.n - 1) / 5))
  LIMIT 1
) u ON true
WHERE NOT EXISTS (                                   -- não há aula em feriado
  SELECT 1 FROM tb_feriado f
  WHERE f.data_feriado = dt.data AND NOT f.facultativo_feriado
);

-- Presenças: toda matrícula confirmada em toda aula da sua turma.
-- A falta é determinística e é ela que produz a frequência. Dois regimes de
-- propósito: a maioria falta ~5% (aprova por frequência) e um em cada 11
-- alunos falta ~33% — abaixo dos 75% exigidos. É esse grupo que faz existir
-- a situação 'reprovado_frequencia', usada pelas consultas 4 e 10.
INSERT INTO tb_presenca (id_aula, id_matricula, id_turma, presente_presenca, justificada_presenca)
SELECT a.id_aula, m.id_matricula, m.id_turma,
       CASE WHEN m.id_aluno % 11 = 0
            THEN ((m.id_aluno * 7 + a.id_aula * 3) % 3)  <> 0
            ELSE ((m.id_aluno * 7 + a.id_aula * 3) % 20) <> 0 END,
       CASE WHEN m.id_aluno % 11 = 0
            THEN ((m.id_aluno * 7 + a.id_aula * 3) % 3)  = 0 AND (m.id_aluno % 4 = 0)
            ELSE ((m.id_aluno * 7 + a.id_aula * 3) % 20) = 0 AND (m.id_aluno % 4 = 0) END
FROM tb_aula a
JOIN tb_matricula m       ON m.id_turma = a.id_turma AND m.status_matricula = 'confirmada'
JOIN tb_turma t           ON t.id_turma = a.id_turma
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2);

-- ============================================================================
-- 14. HISTÓRICO CONSOLIDADO  [E14]
--     historico não guarda mais nota nem frequência: guarda a SITUAÇÃO e a
--     data de fechamento. Média e frequência são derivadas de nota/presenca —
--     é esse o custo assumido da ampliação, e a MV do 04_views.sql é a
--     resposta a ele.
-- ============================================================================
INSERT INTO tb_historico (id_matricula, data_fechamento_historico, situacao_historico)
SELECT m.id_matricula,
       CASE WHEN x.encerrado THEN pl.data_fim_periodo_letivo END,
       CASE
         WHEN m.status_matricula = 'trancada' THEN 'trancado'
         WHEN NOT x.encerrado                 THEN 'cursando'
         WHEN x.freq < 75                     THEN 'reprovado_frequencia'
         WHEN x.media >= 5                    THEN 'aprovado'
         ELSE 'reprovado_nota'
       END::situacao_t
FROM tb_matricula m
JOIN tb_turma tu          ON tu.id_turma = m.id_turma
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo
-- média e frequência vêm da MESMA view que as consultas usam
-- (desempenho_matricula, criada no 01_ddl.sql [E14]): a regra da
-- substitutiva não pode divergir entre a carga e o relatório.
LEFT JOIN vw_desempenho_matricula dm ON dm.id_matricula = m.id_matricula
CROSS JOIN LATERAL (
  SELECT (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2) AS encerrado,
         dm.media_final AS media,
         dm.frequencia  AS freq
) AS x
WHERE m.status_matricula <> 'cancelada';

-- ============================================================================
-- 15. APROVEITAMENTO DE MATÉRIA  [E15]
--     Dispensa por estudo anterior: entra como 2ª via de "pode cursar".
--     Um caso de cada status, para as consultas terem o que mostrar.
-- ============================================================================
INSERT INTO tb_aproveitamento_materia (id_aluno, id_disciplina, id_usuario_avaliador,
       disciplina_origem_aproveitamento_materia, instituicao_origem_aproveitamento_materia,
       parecer_aproveitamento_materia, ch_origem_aproveitamento_materia,
       nota_origem_aproveitamento_materia, solicitacao_aproveitamento_materia,
       decisao_aproveitamento_materia, status_aproveitamento_materia)
SELECT a.id_aluno, d.id_disciplina, u.id_usuario,
       'Introdução à ' || d.nome_disciplina,
       (ARRAY['UnB','UFG','IFB','UCB','Unip'])[1 + a.id_aluno % 5],
       CASE v.status
         WHEN 'deferido'   THEN 'Ementa e carga horária compatíveis (>= 75%). Deferido.'
         WHEN 'indeferido' THEN 'Carga horária insuficiente frente à disciplina de destino.'
         ELSE NULL END,
       CASE v.status WHEN 'indeferido' THEN 30 ELSE d.ch_total_disciplina END,
       CASE v.status WHEN 'indeferido' THEN 6.0 ELSE 8.5 END,
       DATE '2026-01-20',
       CASE WHEN v.status = 'pendente' THEN NULL ELSE DATE '2026-02-10' END,
       v.status::status_aproveitamento_t
FROM (VALUES
  ('ETI',  'deferido',   1), ('EMP',  'deferido',   2), ('MAT1', 'deferido',   3),
  ('SIG',  'indeferido', 4), ('EST1', 'indeferido', 5),
  ('WEB1', 'pendente',   6), ('GPI',  'pendente',   7), ('ALG1', 'pendente',   8)
) AS v(disc, status, ord)
JOIN tb_disciplina d ON d.codigo_disciplina = v.disc
JOIN LATERAL (
  SELECT id_aluno FROM tb_aluno WHERE status_aluno = 'ativo'
  ORDER BY (id_aluno * 13 + v.ord) % 97, id_aluno LIMIT 1
) a ON true
LEFT JOIN tb_usuario u ON u.login_usuario = 'secretaria'
ON CONFLICT (id_aluno, id_disciplina) DO NOTHING;

-- ============================================================================
-- 16. AUDITORIA  [C11] [E4]
--     [E19] A carga NÃO insere no log: os triggers de auditoria já gravaram
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
  SELECT count(*) INTO n_alunos     FROM tb_aluno;
  SELECT count(*) INTO n_turmas     FROM tb_turma;
  SELECT count(*) INTO n_matriculas FROM tb_matricula;
  SELECT count(*) INTO n_notas      FROM tb_nota;
  SELECT count(*) INTO n_presencas  FROM tb_presenca;
  SELECT count(*) INTO n_aulas      FROM tb_aula;
  SELECT t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')
    INTO n_vagas_tabd
  FROM tb_turma t LEFT JOIN tb_matricula m ON m.id_turma = t.id_turma
  WHERE t.codigo_turma = 'TABD-N1' GROUP BY t.vagas_turma;
  SELECT count(*) INTO n_comp1 FROM tb_matricula m JOIN tb_turma t ON t.id_turma = m.id_turma
   WHERE t.codigo_turma = 'COMP1-N1';
  SELECT count(*) INTO n_ead FROM tb_turma_horario th JOIN tb_turma t ON t.id_turma = th.id_turma
   WHERE t.codigo_turma = 'LBD2-N1' AND th.id_sala IS NULL;

  IF n_alunos     < 100 THEN RAISE EXCEPTION 'Carga insuficiente: % alunos (mínimo 100)', n_alunos; END IF;
  IF n_turmas     < 6   THEN RAISE EXCEPTION 'Carga insuficiente: % turmas (mínimo 6)', n_turmas; END IF;
  IF n_matriculas < 300 THEN RAISE EXCEPTION 'Carga insuficiente: % matrículas (mínimo 300)', n_matriculas; END IF;
  IF n_vagas_tabd <> 1  THEN RAISE EXCEPTION 'Cenário da última vaga quebrado: TABD-N1 com % vagas livres (esperado 1)', n_vagas_tabd; END IF;
  IF n_comp1 <> 0       THEN RAISE EXCEPTION 'Cenário da junção externa quebrado: COMP1-N1 tem % matrículas (esperado 0)', n_comp1; END IF;
  IF n_ead   <  1       THEN RAISE EXCEPTION 'Cenário EAD quebrado: LBD2-N1 sem horário de sala NULL'; END IF;
  IF n_notas      < 500 THEN RAISE EXCEPTION 'Poucas notas: %', n_notas; END IF;
  IF NOT EXISTS (SELECT 1 FROM tb_historico WHERE situacao_historico = 'reprovado_frequencia')
    THEN RAISE EXCEPTION 'Cenário de frequência quebrado: ninguém reprovou por falta'; END IF;
  IF n_presencas  < 5000 THEN RAISE EXCEPTION 'Poucas presenças: %', n_presencas; END IF;

  RAISE NOTICE 'Carga OK: % alunos, % turmas, % matrículas, % aulas, % presenças, % notas.',
    n_alunos, n_turmas, n_matriculas, n_aulas, n_presencas, n_notas;
  RAISE NOTICE 'Cenários intactos: TABD-N1 com 1 vaga livre, COMP1-N1 vazia, LBD2-N1 EAD sem sala.';
END $$;

\echo '=== Resumo da carga (41 tabelas) ==='
SELECT 'tb_pais' AS tabela, count(*) FROM tb_pais                          UNION ALL
SELECT 'tb_estado',            count(*) FROM tb_estado                     UNION ALL
SELECT 'tb_cidade',            count(*) FROM tb_cidade                     UNION ALL
SELECT 'tb_endereco',          count(*) FROM tb_endereco                   UNION ALL
SELECT 'tb_pessoa',            count(*) FROM tb_pessoa                     UNION ALL
SELECT 'tb_telefone',          count(*) FROM tb_telefone                   UNION ALL
SELECT 'tb_documento_pessoa',  count(*) FROM tb_documento_pessoa           UNION ALL
SELECT 'tb_usuario',           count(*) FROM tb_usuario                    UNION ALL
SELECT 'tb_campus',            count(*) FROM tb_campus                     UNION ALL
SELECT 'tb_departamento',      count(*) FROM tb_departamento               UNION ALL
SELECT 'tb_predio',            count(*) FROM tb_predio                     UNION ALL
SELECT 'tb_sala',              count(*) FROM tb_sala                       UNION ALL
SELECT 'tb_recurso',           count(*) FROM tb_recurso                    UNION ALL
SELECT 'tb_sala_recurso',      count(*) FROM tb_sala_recurso               UNION ALL
SELECT 'tb_professor',         count(*) FROM tb_professor                  UNION ALL
SELECT 'tb_formacao_professor',count(*) FROM tb_formacao_professor         UNION ALL
SELECT 'tb_curso',             count(*) FROM tb_curso                      UNION ALL
SELECT 'tb_coordenacao_curso', count(*) FROM tb_coordenacao_curso          UNION ALL
SELECT 'tb_curriculo',         count(*) FROM tb_curriculo                  UNION ALL
SELECT 'tb_disciplina',        count(*) FROM tb_disciplina                 UNION ALL
SELECT 'tb_curriculo_disciplina', count(*) FROM tb_curriculo_disciplina    UNION ALL
SELECT 'tb_pre_requisito',     count(*) FROM tb_pre_requisito              UNION ALL
SELECT 'tb_aluno',             count(*) FROM tb_aluno                      UNION ALL
SELECT 'tb_aproveitamento_materia', count(*) FROM tb_aproveitamento_materia UNION ALL
SELECT 'tb_periodo_letivo',    count(*) FROM tb_periodo_letivo             UNION ALL
SELECT 'tb_periodo_matricula', count(*) FROM tb_periodo_matricula          UNION ALL
SELECT 'tb_feriado',           count(*) FROM tb_feriado                    UNION ALL
SELECT 'tb_turma',             count(*) FROM tb_turma                      UNION ALL
SELECT 'tb_turma_professor',   count(*) FROM tb_turma_professor            UNION ALL
SELECT 'tb_turma_horario',     count(*) FROM tb_turma_horario              UNION ALL
SELECT 'tb_plano_ensino',      count(*) FROM tb_plano_ensino               UNION ALL
SELECT 'tb_unidade_plano_ensino', count(*) FROM tb_unidade_plano_ensino    UNION ALL
SELECT 'tb_bibliografia',      count(*) FROM tb_bibliografia               UNION ALL
SELECT 'tb_plano_ensino_bibliografia', count(*) FROM tb_plano_ensino_bibliografia UNION ALL
SELECT 'tb_matricula',         count(*) FROM tb_matricula                  UNION ALL
SELECT 'tb_historico',         count(*) FROM tb_historico                  UNION ALL
SELECT 'log_matricula',     count(*) FROM tb_log_auditoria              UNION ALL
SELECT 'tb_aula',              count(*) FROM tb_aula                       UNION ALL
SELECT 'tb_presenca',          count(*) FROM tb_presenca                   UNION ALL
SELECT 'tb_avaliacao',         count(*) FROM tb_avaliacao                  UNION ALL
SELECT 'tb_nota',              count(*) FROM tb_nota
ORDER BY tabela;

-- ############################################################################
-- ### sql/02b_geografia_ibge.sql
-- ############################################################################

-- =========================================================================
-- 02b_geografia_ibge.sql — GERADO por scripts/gerar_geografia_ibge.py. NÃO EDITAR À MÃO.
-- Geografia completa do Brasil: 27 estados + 5.570 municípios com código
-- IBGE (fonte: github.com/leogermani/estados-e-municipios-ibge).
-- Roda DEPOIS da carga base e é idempotente: ON CONFLICT DO NOTHING sobre
-- as unicidades de UF e de código IBGE preserva as linhas já semeadas.
-- =========================================================================
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO tb_estado (id_pais, nome_estado, uf_estado)
SELECT p.id_pais, v.nome, v.uf
FROM (VALUES
  ('Rondônia', 'RO'),
  ('Acre', 'AC'),
  ('Amazonas', 'AM'),
  ('Roraima', 'RR'),
  ('Pará', 'PA'),
  ('Amapá', 'AP'),
  ('Tocantins', 'TO'),
  ('Maranhão', 'MA'),
  ('Piauí', 'PI'),
  ('Ceará', 'CE'),
  ('Rio Grande do Norte', 'RN'),
  ('Paraíba', 'PB'),
  ('Pernambuco', 'PE'),
  ('Alagoas', 'AL'),
  ('Sergipe', 'SE'),
  ('Bahia', 'BA'),
  ('Minas Gerais', 'MG'),
  ('Espírito Santo', 'ES'),
  ('Rio de Janeiro', 'RJ'),
  ('São Paulo', 'SP'),
  ('Paraná', 'PR'),
  ('Santa Catarina', 'SC'),
  ('Rio Grande do Sul', 'RS'),
  ('Mato Grosso do Sul', 'MS'),
  ('Mato Grosso', 'MT'),
  ('Goiás', 'GO'),
  ('Distrito Federal', 'DF')
) AS v(nome, uf)
JOIN tb_pais p ON p.sigla_pais = 'BR'
ON CONFLICT (id_pais, uf_estado) DO NOTHING;

INSERT INTO tb_cidade (id_estado, nome_cidade, codigo_ibge_cidade)
SELECT e.id_estado, v.nome, v.ibge
FROM (VALUES
  ('RO', 'Alta Floresta D''oeste', '1100015'),
  ('RO', 'Ariquemes', '1100023'),
  ('RO', 'Cabixi', '1100031'),
  ('RO', 'Cacoal', '1100049'),
  ('RO', 'Cerejeiras', '1100056'),
  ('RO', 'Colorado do Oeste', '1100064'),
  ('RO', 'Corumbiara', '1100072'),
  ('RO', 'Costa Marques', '1100080'),
  ('RO', 'Espigão D''oeste', '1100098'),
  ('RO', 'Guajará-Mirim', '1100106'),
  ('RO', 'Jaru', '1100114'),
  ('RO', 'Ji-Paraná', '1100122'),
  ('RO', 'Machadinho D''oeste', '1100130'),
  ('RO', 'Nova Brasilândia D''oeste', '1100148'),
  ('RO', 'Ouro Preto do Oeste', '1100155'),
  ('RO', 'Pimenta Bueno', '1100189'),
  ('RO', 'Porto Velho', '1100205'),
  ('RO', 'Presidente Médici', '1100254'),
  ('RO', 'Rio Crespo', '1100262'),
  ('RO', 'Rolim de Moura', '1100288'),
  ('RO', 'Santa Luzia D''oeste', '1100296'),
  ('RO', 'Vilhena', '1100304'),
  ('RO', 'São Miguel do Guaporé', '1100320'),
  ('RO', 'Nova Mamoré', '1100338'),
  ('RO', 'Alvorada D''oeste', '1100346'),
  ('RO', 'Alto Alegre dos Parecis', '1100379'),
  ('RO', 'Alto Paraíso', '1100403'),
  ('RO', 'Buritis', '1100452'),
  ('RO', 'Novo Horizonte do Oeste', '1100502'),
  ('RO', 'Cacaulândia', '1100601'),
  ('RO', 'Campo Novo de Rondônia', '1100700'),
  ('RO', 'Candeias do Jamari', '1100809'),
  ('RO', 'Castanheiras', '1100908'),
  ('RO', 'Chupinguaia', '1100924'),
  ('RO', 'Cujubim', '1100940'),
  ('RO', 'Governador Jorge Teixeira', '1101005'),
  ('RO', 'Itapuã do Oeste', '1101104'),
  ('RO', 'Ministro Andreazza', '1101203'),
  ('RO', 'Mirante da Serra', '1101302'),
  ('RO', 'Monte Negro', '1101401'),
  ('RO', 'Nova União', '1101435'),
  ('RO', 'Parecis', '1101450'),
  ('RO', 'Pimenteiras do Oeste', '1101468'),
  ('RO', 'Primavera de Rondônia', '1101476'),
  ('RO', 'São Felipe D''oeste', '1101484'),
  ('RO', 'São Francisco do Guaporé', '1101492'),
  ('RO', 'Seringueiras', '1101500'),
  ('RO', 'Teixeirópolis', '1101559'),
  ('RO', 'Theobroma', '1101609'),
  ('RO', 'Urupá', '1101708'),
  ('RO', 'Vale do Anari', '1101757'),
  ('RO', 'Vale do Paraíso', '1101807'),
  ('AC', 'Acrelândia', '1200013'),
  ('AC', 'Assis Brasil', '1200054'),
  ('AC', 'Brasiléia', '1200104'),
  ('AC', 'Bujari', '1200138'),
  ('AC', 'Capixaba', '1200179'),
  ('AC', 'Cruzeiro do Sul', '1200203'),
  ('AC', 'Epitaciolândia', '1200252'),
  ('AC', 'Feijó', '1200302'),
  ('AC', 'Jordão', '1200328'),
  ('AC', 'Mâncio Lima', '1200336'),
  ('AC', 'Manoel Urbano', '1200344'),
  ('AC', 'Marechal Thaumaturgo', '1200351'),
  ('AC', 'Plácido de Castro', '1200385'),
  ('AC', 'Porto Walter', '1200393'),
  ('AC', 'Rio Branco', '1200401'),
  ('AC', 'Rodrigues Alves', '1200427'),
  ('AC', 'Santa Rosa do Purus', '1200435'),
  ('AC', 'Senador Guiomard', '1200450'),
  ('AC', 'Sena Madureira', '1200500'),
  ('AC', 'Tarauacá', '1200609'),
  ('AC', 'Xapuri', '1200708'),
  ('AC', 'Porto Acre', '1200807'),
  ('AM', 'Alvarães', '1300029'),
  ('AM', 'Amaturá', '1300060'),
  ('AM', 'Anamã', '1300086'),
  ('AM', 'Anori', '1300102'),
  ('AM', 'Apuí', '1300144'),
  ('AM', 'Atalaia do Norte', '1300201'),
  ('AM', 'Autazes', '1300300'),
  ('AM', 'Barcelos', '1300409'),
  ('AM', 'Barreirinha', '1300508'),
  ('AM', 'Benjamin Constant', '1300607'),
  ('AM', 'Beruri', '1300631'),
  ('AM', 'Boa Vista do Ramos', '1300680'),
  ('AM', 'Boca do Acre', '1300706'),
  ('AM', 'Borba', '1300805'),
  ('AM', 'Caapiranga', '1300839'),
  ('AM', 'Canutama', '1300904'),
  ('AM', 'Carauari', '1301001'),
  ('AM', 'Careiro', '1301100'),
  ('AM', 'Careiro da Várzea', '1301159'),
  ('AM', 'Coari', '1301209'),
  ('AM', 'Codajás', '1301308'),
  ('AM', 'Eirunepé', '1301407'),
  ('AM', 'Envira', '1301506'),
  ('AM', 'Fonte Boa', '1301605'),
  ('AM', 'Guajará', '1301654'),
  ('AM', 'Humaitá', '1301704'),
  ('AM', 'Ipixuna', '1301803'),
  ('AM', 'Iranduba', '1301852'),
  ('AM', 'Itacoatiara', '1301902'),
  ('AM', 'Itamarati', '1301951'),
  ('AM', 'Itapiranga', '1302009'),
  ('AM', 'Japurá', '1302108'),
  ('AM', 'Juruá', '1302207'),
  ('AM', 'Jutaí', '1302306'),
  ('AM', 'Lábrea', '1302405'),
  ('AM', 'Manacapuru', '1302504'),
  ('AM', 'Manaquiri', '1302553'),
  ('AM', 'Manaus', '1302603'),
  ('AM', 'Manicoré', '1302702'),
  ('AM', 'Maraã', '1302801'),
  ('AM', 'Maués', '1302900'),
  ('AM', 'Nhamundá', '1303007'),
  ('AM', 'Nova Olinda do Norte', '1303106'),
  ('AM', 'Novo Airão', '1303205'),
  ('AM', 'Novo Aripuanã', '1303304'),
  ('AM', 'Parintins', '1303403'),
  ('AM', 'Pauini', '1303502'),
  ('AM', 'Presidente Figueiredo', '1303536'),
  ('AM', 'Rio Preto da Eva', '1303569'),
  ('AM', 'Santa Isabel do Rio Negro', '1303601'),
  ('AM', 'Santo Antônio do Içá', '1303700'),
  ('AM', 'São Gabriel da Cachoeira', '1303809'),
  ('AM', 'São Paulo de Olivença', '1303908'),
  ('AM', 'São Sebastião do Uatumã', '1303957'),
  ('AM', 'Silves', '1304005'),
  ('AM', 'Tabatinga', '1304062'),
  ('AM', 'Tapauá', '1304104'),
  ('AM', 'Tefé', '1304203'),
  ('AM', 'Tonantins', '1304237'),
  ('AM', 'Uarini', '1304260'),
  ('AM', 'Urucará', '1304302'),
  ('AM', 'Urucurituba', '1304401'),
  ('RR', 'Amajari', '1400027'),
  ('RR', 'Alto Alegre', '1400050'),
  ('RR', 'Boa Vista', '1400100'),
  ('RR', 'Bonfim', '1400159'),
  ('RR', 'Cantá', '1400175'),
  ('RR', 'Caracaraí', '1400209'),
  ('RR', 'Caroebe', '1400233'),
  ('RR', 'Iracema', '1400282'),
  ('RR', 'Mucajaí', '1400308'),
  ('RR', 'Normandia', '1400407'),
  ('RR', 'Pacaraima', '1400456'),
  ('RR', 'Rorainópolis', '1400472'),
  ('RR', 'São João da Baliza', '1400506'),
  ('RR', 'São Luiz', '1400605'),
  ('RR', 'Uiramutã', '1400704'),
  ('PA', 'Abaetetuba', '1500107'),
  ('PA', 'Abel Figueiredo', '1500131'),
  ('PA', 'Acará', '1500206'),
  ('PA', 'Afuá', '1500305'),
  ('PA', 'Água Azul do Norte', '1500347'),
  ('PA', 'Alenquer', '1500404'),
  ('PA', 'Almeirim', '1500503'),
  ('PA', 'Altamira', '1500602'),
  ('PA', 'Anajás', '1500701'),
  ('PA', 'Ananindeua', '1500800'),
  ('PA', 'Anapu', '1500859'),
  ('PA', 'Augusto Corrêa', '1500909'),
  ('PA', 'Aurora do Pará', '1500958'),
  ('PA', 'Aveiro', '1501006'),
  ('PA', 'Bagre', '1501105'),
  ('PA', 'Baião', '1501204'),
  ('PA', 'Bannach', '1501253'),
  ('PA', 'Barcarena', '1501303'),
  ('PA', 'Belém', '1501402'),
  ('PA', 'Belterra', '1501451'),
  ('PA', 'Benevides', '1501501'),
  ('PA', 'Bom Jesus do Tocantins', '1501576'),
  ('PA', 'Bonito', '1501600'),
  ('PA', 'Bragança', '1501709'),
  ('PA', 'Brasil Novo', '1501725'),
  ('PA', 'Brejo Grande do Araguaia', '1501758'),
  ('PA', 'Breu Branco', '1501782'),
  ('PA', 'Breves', '1501808'),
  ('PA', 'Bujaru', '1501907'),
  ('PA', 'Cachoeira do Piriá', '1501956'),
  ('PA', 'Cachoeira do Arari', '1502004'),
  ('PA', 'Cametá', '1502103'),
  ('PA', 'Canaã dos Carajás', '1502152'),
  ('PA', 'Capanema', '1502202'),
  ('PA', 'Capitão Poço', '1502301'),
  ('PA', 'Castanhal', '1502400'),
  ('PA', 'Chaves', '1502509'),
  ('PA', 'Colares', '1502608'),
  ('PA', 'Conceição do Araguaia', '1502707'),
  ('PA', 'Concórdia do Pará', '1502756'),
  ('PA', 'Cumaru do Norte', '1502764'),
  ('PA', 'Curionópolis', '1502772'),
  ('PA', 'Curralinho', '1502806'),
  ('PA', 'Curuá', '1502855'),
  ('PA', 'Curuçá', '1502905'),
  ('PA', 'dom Eliseu', '1502939'),
  ('PA', 'Eldorado do Carajás', '1502954'),
  ('PA', 'Faro', '1503002'),
  ('PA', 'Floresta do Araguaia', '1503044'),
  ('PA', 'Garrafão do Norte', '1503077'),
  ('PA', 'Goianésia do Pará', '1503093'),
  ('PA', 'Gurupá', '1503101'),
  ('PA', 'Igarapé-Açu', '1503200'),
  ('PA', 'Igarapé-Miri', '1503309'),
  ('PA', 'Inhangapi', '1503408'),
  ('PA', 'Ipixuna do Pará', '1503457'),
  ('PA', 'Irituia', '1503507'),
  ('PA', 'Itaituba', '1503606'),
  ('PA', 'Itupiranga', '1503705'),
  ('PA', 'Jacareacanga', '1503754'),
  ('PA', 'Jacundá', '1503804'),
  ('PA', 'Juruti', '1503903'),
  ('PA', 'Limoeiro do Ajuru', '1504000'),
  ('PA', 'Mãe do Rio', '1504059'),
  ('PA', 'Magalhães Barata', '1504109'),
  ('PA', 'Marabá', '1504208'),
  ('PA', 'Maracanã', '1504307'),
  ('PA', 'Marapanim', '1504406'),
  ('PA', 'Marituba', '1504422'),
  ('PA', 'Medicilândia', '1504455'),
  ('PA', 'Melgaço', '1504505'),
  ('PA', 'Mocajuba', '1504604'),
  ('PA', 'Moju', '1504703'),
  ('PA', 'Mojuí dos Campos', '1504752'),
  ('PA', 'Monte Alegre', '1504802'),
  ('PA', 'Muaná', '1504901'),
  ('PA', 'Nova Esperança do Piriá', '1504950'),
  ('PA', 'Nova Ipixuna', '1504976'),
  ('PA', 'Nova Timboteua', '1505007'),
  ('PA', 'Novo Progresso', '1505031'),
  ('PA', 'Novo Repartimento', '1505064'),
  ('PA', 'Óbidos', '1505106'),
  ('PA', 'Oeiras do Pará', '1505205'),
  ('PA', 'Oriximiná', '1505304'),
  ('PA', 'Ourém', '1505403'),
  ('PA', 'Ourilândia do Norte', '1505437'),
  ('PA', 'Pacajá', '1505486'),
  ('PA', 'Palestina do Pará', '1505494'),
  ('PA', 'Paragominas', '1505502'),
  ('PA', 'Parauapebas', '1505536'),
  ('PA', 'Pau D''arco', '1505551'),
  ('PA', 'Peixe-Boi', '1505601'),
  ('PA', 'Piçarra', '1505635'),
  ('PA', 'Placas', '1505650'),
  ('PA', 'Ponta de Pedras', '1505700'),
  ('PA', 'Portel', '1505809'),
  ('PA', 'Porto de Moz', '1505908'),
  ('PA', 'Prainha', '1506005'),
  ('PA', 'Primavera', '1506104'),
  ('PA', 'Quatipuru', '1506112'),
  ('PA', 'Redenção', '1506138'),
  ('PA', 'Rio Maria', '1506161'),
  ('PA', 'Rondon do Pará', '1506187'),
  ('PA', 'Rurópolis', '1506195'),
  ('PA', 'Salinópolis', '1506203'),
  ('PA', 'Salvaterra', '1506302'),
  ('PA', 'Santa Bárbara do Pará', '1506351'),
  ('PA', 'Santa Cruz do Arari', '1506401'),
  ('PA', 'Santa Izabel do Pará', '1506500'),
  ('PA', 'Santa Luzia do Pará', '1506559'),
  ('PA', 'Santa Maria das Barreiras', '1506583'),
  ('PA', 'Santa Maria do Pará', '1506609'),
  ('PA', 'Santana do Araguaia', '1506708'),
  ('PA', 'Santarém', '1506807'),
  ('PA', 'Santarém Novo', '1506906'),
  ('PA', 'Santo Antônio do Tauá', '1507003'),
  ('PA', 'São Caetano de Odivelas', '1507102'),
  ('PA', 'São domingos do Araguaia', '1507151'),
  ('PA', 'São domingos do Capim', '1507201'),
  ('PA', 'São Félix do Xingu', '1507300'),
  ('PA', 'São Francisco do Pará', '1507409'),
  ('PA', 'São Geraldo do Araguaia', '1507458'),
  ('PA', 'São João da Ponta', '1507466'),
  ('PA', 'São João de Pirabas', '1507474'),
  ('PA', 'São João do Araguaia', '1507508'),
  ('PA', 'São Miguel do Guamá', '1507607'),
  ('PA', 'São Sebastião da Boa Vista', '1507706'),
  ('PA', 'Sapucaia', '1507755'),
  ('PA', 'Senador José Porfírio', '1507805'),
  ('PA', 'Soure', '1507904'),
  ('PA', 'Tailândia', '1507953'),
  ('PA', 'Terra Alta', '1507961'),
  ('PA', 'Terra Santa', '1507979'),
  ('PA', 'Tomé-Açu', '1508001'),
  ('PA', 'Tracuateua', '1508035'),
  ('PA', 'Trairão', '1508050'),
  ('PA', 'Tucumã', '1508084'),
  ('PA', 'Tucuruí', '1508100'),
  ('PA', 'Ulianópolis', '1508126'),
  ('PA', 'Uruará', '1508159'),
  ('PA', 'Vigia', '1508209'),
  ('PA', 'Viseu', '1508308'),
  ('PA', 'Vitória do Xingu', '1508357'),
  ('PA', 'Xinguara', '1508407'),
  ('AP', 'Serra do Navio', '1600055'),
  ('AP', 'Amapá', '1600105'),
  ('AP', 'Pedra Branca do Amapari', '1600154'),
  ('AP', 'Calçoene', '1600204'),
  ('AP', 'Cutias', '1600212'),
  ('AP', 'Ferreira Gomes', '1600238'),
  ('AP', 'Itaubal', '1600253'),
  ('AP', 'Laranjal do Jari', '1600279'),
  ('AP', 'Macapá', '1600303'),
  ('AP', 'Mazagão', '1600402'),
  ('AP', 'Oiapoque', '1600501'),
  ('AP', 'Porto Grande', '1600535'),
  ('AP', 'Pracuúba', '1600550'),
  ('AP', 'Santana', '1600600'),
  ('AP', 'Tartarugalzinho', '1600709'),
  ('AP', 'Vitória do Jari', '1600808'),
  ('TO', 'Abreulândia', '1700251'),
  ('TO', 'Aguiarnópolis', '1700301'),
  ('TO', 'Aliança do Tocantins', '1700350'),
  ('TO', 'Almas', '1700400'),
  ('TO', 'Alvorada', '1700707'),
  ('TO', 'Ananás', '1701002'),
  ('TO', 'Angico', '1701051'),
  ('TO', 'Aparecida do Rio Negro', '1701101'),
  ('TO', 'Aragominas', '1701309'),
  ('TO', 'Araguacema', '1701903'),
  ('TO', 'Araguaçu', '1702000'),
  ('TO', 'Araguaína', '1702109'),
  ('TO', 'Araguanã', '1702158'),
  ('TO', 'Araguatins', '1702208'),
  ('TO', 'Arapoema', '1702307'),
  ('TO', 'Arraias', '1702406'),
  ('TO', 'Augustinópolis', '1702554'),
  ('TO', 'Aurora do Tocantins', '1702703'),
  ('TO', 'Axixá do Tocantins', '1702901'),
  ('TO', 'Babaçulândia', '1703008'),
  ('TO', 'Bandeirantes do Tocantins', '1703057'),
  ('TO', 'Barra do Ouro', '1703073'),
  ('TO', 'Barrolândia', '1703107'),
  ('TO', 'Bernardo Sayão', '1703206'),
  ('TO', 'Bom Jesus do Tocantins', '1703305'),
  ('TO', 'Brasilândia do Tocantins', '1703602'),
  ('TO', 'Brejinho de Nazaré', '1703701'),
  ('TO', 'Buriti do Tocantins', '1703800'),
  ('TO', 'Cachoeirinha', '1703826'),
  ('TO', 'Campos Lindos', '1703842'),
  ('TO', 'Cariri do Tocantins', '1703867'),
  ('TO', 'Carmolândia', '1703883'),
  ('TO', 'Carrasco Bonito', '1703891'),
  ('TO', 'Caseara', '1703909'),
  ('TO', 'Centenário', '1704105'),
  ('TO', 'Chapada de Areia', '1704600'),
  ('TO', 'Chapada da Natividade', '1705102'),
  ('TO', 'Colinas do Tocantins', '1705508'),
  ('TO', 'Combinado', '1705557'),
  ('TO', 'Conceição do Tocantins', '1705607'),
  ('TO', 'Couto Magalhães', '1706001'),
  ('TO', 'Cristalândia', '1706100'),
  ('TO', 'Crixás do Tocantins', '1706258'),
  ('TO', 'darcinópolis', '1706506'),
  ('TO', 'Dianópolis', '1707009'),
  ('TO', 'Divinópolis do Tocantins', '1707108'),
  ('TO', 'dois Irmãos do Tocantins', '1707207'),
  ('TO', 'Dueré', '1707306'),
  ('TO', 'Esperantina', '1707405'),
  ('TO', 'Fátima', '1707553'),
  ('TO', 'Figueirópolis', '1707652'),
  ('TO', 'Filadélfia', '1707702'),
  ('TO', 'Formoso do Araguaia', '1708205'),
  ('TO', 'Fortaleza do Tabocão', '1708254'),
  ('TO', 'Goianorte', '1708304'),
  ('TO', 'Goiatins', '1709005'),
  ('TO', 'Guaraí', '1709302'),
  ('TO', 'Gurupi', '1709500'),
  ('TO', 'Ipueiras', '1709807'),
  ('TO', 'Itacajá', '1710508'),
  ('TO', 'Itaguatins', '1710706'),
  ('TO', 'Itapiratins', '1710904'),
  ('TO', 'Itaporã do Tocantins', '1711100'),
  ('TO', 'Jaú do Tocantins', '1711506'),
  ('TO', 'Juarina', '1711803'),
  ('TO', 'Lagoa da Confusão', '1711902'),
  ('TO', 'Lagoa do Tocantins', '1711951'),
  ('TO', 'Lajeado', '1712009'),
  ('TO', 'Lavandeira', '1712157'),
  ('TO', 'Lizarda', '1712405'),
  ('TO', 'Luzinópolis', '1712454'),
  ('TO', 'Marianópolis do Tocantins', '1712504'),
  ('TO', 'Mateiros', '1712702'),
  ('TO', 'Maurilândia do Tocantins', '1712801'),
  ('TO', 'Miracema do Tocantins', '1713205'),
  ('TO', 'Miranorte', '1713304'),
  ('TO', 'Monte do Carmo', '1713601'),
  ('TO', 'Monte Santo do Tocantins', '1713700'),
  ('TO', 'Palmeiras do Tocantins', '1713809'),
  ('TO', 'Muricilândia', '1713957'),
  ('TO', 'Natividade', '1714203'),
  ('TO', 'Nazaré', '1714302'),
  ('TO', 'Nova Olinda', '1714880'),
  ('TO', 'Nova Rosalândia', '1715002'),
  ('TO', 'Novo Acordo', '1715101'),
  ('TO', 'Novo Alegre', '1715150'),
  ('TO', 'Novo Jardim', '1715259'),
  ('TO', 'Oliveira de Fátima', '1715507'),
  ('TO', 'Palmeirante', '1715705'),
  ('TO', 'Palmeirópolis', '1715754'),
  ('TO', 'Paraíso do Tocantins', '1716109'),
  ('TO', 'Paranã', '1716208'),
  ('TO', 'Pau D''arco', '1716307'),
  ('TO', 'Pedro Afonso', '1716505'),
  ('TO', 'Peixe', '1716604'),
  ('TO', 'Pequizeiro', '1716653'),
  ('TO', 'Colméia', '1716703'),
  ('TO', 'Pindorama do Tocantins', '1717008'),
  ('TO', 'Piraquê', '1717206'),
  ('TO', 'Pium', '1717503'),
  ('TO', 'Ponte Alta do Bom Jesus', '1717800'),
  ('TO', 'Ponte Alta do Tocantins', '1717909'),
  ('TO', 'Porto Alegre do Tocantins', '1718006'),
  ('TO', 'Porto Nacional', '1718204'),
  ('TO', 'Praia Norte', '1718303'),
  ('TO', 'Presidente Kennedy', '1718402'),
  ('TO', 'Pugmil', '1718451'),
  ('TO', 'Recursolândia', '1718501'),
  ('TO', 'Riachinho', '1718550'),
  ('TO', 'Rio da Conceição', '1718659'),
  ('TO', 'Rio dos Bois', '1718709'),
  ('TO', 'Rio Sono', '1718758'),
  ('TO', 'Sampaio', '1718808'),
  ('TO', 'Sandolândia', '1718840'),
  ('TO', 'Santa Fé do Araguaia', '1718865'),
  ('TO', 'Santa Maria do Tocantins', '1718881'),
  ('TO', 'Santa Rita do Tocantins', '1718899'),
  ('TO', 'Santa Rosa do Tocantins', '1718907'),
  ('TO', 'Santa Tereza do Tocantins', '1719004'),
  ('TO', 'Santa Terezinha do Tocantins', '1720002'),
  ('TO', 'São Bento do Tocantins', '1720101'),
  ('TO', 'São Félix do Tocantins', '1720150'),
  ('TO', 'São Miguel do Tocantins', '1720200'),
  ('TO', 'São Salvador do Tocantins', '1720259'),
  ('TO', 'São Sebastião do Tocantins', '1720309'),
  ('TO', 'São Valério', '1720499'),
  ('TO', 'Silvanópolis', '1720655'),
  ('TO', 'Sítio Novo do Tocantins', '1720804'),
  ('TO', 'Sucupira', '1720853'),
  ('TO', 'Taguatinga', '1720903'),
  ('TO', 'Taipas do Tocantins', '1720937'),
  ('TO', 'Talismã', '1720978'),
  ('TO', 'Palmas', '1721000'),
  ('TO', 'Tocantínia', '1721109'),
  ('TO', 'Tocantinópolis', '1721208'),
  ('TO', 'Tupirama', '1721257'),
  ('TO', 'Tupiratins', '1721307'),
  ('TO', 'Wanderlândia', '1722081'),
  ('TO', 'Xambioá', '1722107'),
  ('MA', 'Açailândia', '2100055'),
  ('MA', 'Afonso Cunha', '2100105'),
  ('MA', 'Água doce do Maranhão', '2100154'),
  ('MA', 'Alcântara', '2100204'),
  ('MA', 'Aldeias Altas', '2100303'),
  ('MA', 'Altamira do Maranhão', '2100402'),
  ('MA', 'Alto Alegre do Maranhão', '2100436'),
  ('MA', 'Alto Alegre do Pindaré', '2100477'),
  ('MA', 'Alto Parnaíba', '2100501'),
  ('MA', 'Amapá do Maranhão', '2100550'),
  ('MA', 'Amarante do Maranhão', '2100600'),
  ('MA', 'Anajatuba', '2100709'),
  ('MA', 'Anapurus', '2100808'),
  ('MA', 'Apicum-Açu', '2100832'),
  ('MA', 'Araguanã', '2100873'),
  ('MA', 'Araioses', '2100907'),
  ('MA', 'Arame', '2100956'),
  ('MA', 'Arari', '2101004'),
  ('MA', 'Axixá', '2101103'),
  ('MA', 'Bacabal', '2101202'),
  ('MA', 'Bacabeira', '2101251'),
  ('MA', 'Bacuri', '2101301'),
  ('MA', 'Bacurituba', '2101350'),
  ('MA', 'Balsas', '2101400'),
  ('MA', 'Barão de Grajaú', '2101509'),
  ('MA', 'Barra do Corda', '2101608'),
  ('MA', 'Barreirinhas', '2101707'),
  ('MA', 'Belágua', '2101731'),
  ('MA', 'Bela Vista do Maranhão', '2101772'),
  ('MA', 'Benedito Leite', '2101806'),
  ('MA', 'Bequimão', '2101905'),
  ('MA', 'Bernardo do Mearim', '2101939'),
  ('MA', 'Boa Vista do Gurupi', '2101970'),
  ('MA', 'Bom Jardim', '2102002'),
  ('MA', 'Bom Jesus das Selvas', '2102036'),
  ('MA', 'Bom Lugar', '2102077'),
  ('MA', 'Brejo', '2102101'),
  ('MA', 'Brejo de Areia', '2102150'),
  ('MA', 'Buriti', '2102200'),
  ('MA', 'Buriti Bravo', '2102309'),
  ('MA', 'Buriticupu', '2102325'),
  ('MA', 'Buritirana', '2102358'),
  ('MA', 'Cachoeira Grande', '2102374'),
  ('MA', 'Cajapió', '2102408'),
  ('MA', 'Cajari', '2102507'),
  ('MA', 'Campestre do Maranhão', '2102556'),
  ('MA', 'Cândido Mendes', '2102606'),
  ('MA', 'Cantanhede', '2102705'),
  ('MA', 'Capinzal do Norte', '2102754'),
  ('MA', 'Carolina', '2102804'),
  ('MA', 'Carutapera', '2102903'),
  ('MA', 'Caxias', '2103000'),
  ('MA', 'Cedral', '2103109'),
  ('MA', 'Central do Maranhão', '2103125'),
  ('MA', 'Centro do Guilherme', '2103158'),
  ('MA', 'Centro Novo do Maranhão', '2103174'),
  ('MA', 'Chapadinha', '2103208'),
  ('MA', 'Cidelândia', '2103257'),
  ('MA', 'Codó', '2103307'),
  ('MA', 'Coelho Neto', '2103406'),
  ('MA', 'Colinas', '2103505'),
  ('MA', 'Conceição do Lago-Açu', '2103554'),
  ('MA', 'Coroatá', '2103604'),
  ('MA', 'Cururupu', '2103703'),
  ('MA', 'davinópolis', '2103752'),
  ('MA', 'dom Pedro', '2103802'),
  ('MA', 'Duque Bacelar', '2103901'),
  ('MA', 'Esperantinópolis', '2104008'),
  ('MA', 'Estreito', '2104057'),
  ('MA', 'Feira Nova do Maranhão', '2104073'),
  ('MA', 'Fernando Falcão', '2104081'),
  ('MA', 'Formosa da Serra Negra', '2104099'),
  ('MA', 'Fortaleza dos Nogueiras', '2104107'),
  ('MA', 'Fortuna', '2104206'),
  ('MA', 'Godofredo Viana', '2104305'),
  ('MA', 'Gonçalves Dias', '2104404'),
  ('MA', 'Governador Archer', '2104503'),
  ('MA', 'Governador Edison Lobão', '2104552'),
  ('MA', 'Governador Eugênio Barros', '2104602'),
  ('MA', 'Governador Luiz Rocha', '2104628'),
  ('MA', 'Governador Newton Bello', '2104651'),
  ('MA', 'Governador Nunes Freire', '2104677'),
  ('MA', 'Graça Aranha', '2104701'),
  ('MA', 'Grajaú', '2104800'),
  ('MA', 'Guimarães', '2104909'),
  ('MA', 'Humberto de Campos', '2105005'),
  ('MA', 'Icatu', '2105104'),
  ('MA', 'Igarapé do Meio', '2105153'),
  ('MA', 'Igarapé Grande', '2105203'),
  ('MA', 'Imperatriz', '2105302'),
  ('MA', 'Itaipava do Grajaú', '2105351'),
  ('MA', 'Itapecuru Mirim', '2105401'),
  ('MA', 'Itinga do Maranhão', '2105427'),
  ('MA', 'Jatobá', '2105450'),
  ('MA', 'Jenipapo dos Vieiras', '2105476'),
  ('MA', 'João Lisboa', '2105500'),
  ('MA', 'Joselândia', '2105609'),
  ('MA', 'Junco do Maranhão', '2105658'),
  ('MA', 'Lago da Pedra', '2105708'),
  ('MA', 'Lago do Junco', '2105807'),
  ('MA', 'Lago Verde', '2105906'),
  ('MA', 'Lagoa do Mato', '2105922'),
  ('MA', 'Lago dos Rodrigues', '2105948'),
  ('MA', 'Lagoa Grande do Maranhão', '2105963'),
  ('MA', 'Lajeado Novo', '2105989'),
  ('MA', 'Lima Campos', '2106003'),
  ('MA', 'Loreto', '2106102'),
  ('MA', 'Luís domingues', '2106201'),
  ('MA', 'Magalhães de Almeida', '2106300'),
  ('MA', 'Maracaçumé', '2106326'),
  ('MA', 'Marajá do Sena', '2106359'),
  ('MA', 'Maranhãozinho', '2106375'),
  ('MA', 'Mata Roma', '2106409'),
  ('MA', 'Matinha', '2106508'),
  ('MA', 'Matões', '2106607'),
  ('MA', 'Matões do Norte', '2106631'),
  ('MA', 'Milagres do Maranhão', '2106672'),
  ('MA', 'Mirador', '2106706'),
  ('MA', 'Miranda do Norte', '2106755'),
  ('MA', 'Mirinzal', '2106805'),
  ('MA', 'Monção', '2106904'),
  ('MA', 'Montes Altos', '2107001'),
  ('MA', 'Morros', '2107100'),
  ('MA', 'Nina Rodrigues', '2107209'),
  ('MA', 'Nova Colinas', '2107258'),
  ('MA', 'Nova Iorque', '2107308'),
  ('MA', 'Nova Olinda do Maranhão', '2107357'),
  ('MA', 'Olho D''água das Cunhãs', '2107407'),
  ('MA', 'Olinda Nova do Maranhão', '2107456'),
  ('MA', 'Paço do Lumiar', '2107506'),
  ('MA', 'Palmeirândia', '2107605'),
  ('MA', 'Paraibano', '2107704'),
  ('MA', 'Parnarama', '2107803'),
  ('MA', 'Passagem Franca', '2107902'),
  ('MA', 'Pastos Bons', '2108009'),
  ('MA', 'Paulino Neves', '2108058'),
  ('MA', 'Paulo Ramos', '2108108'),
  ('MA', 'Pedreiras', '2108207'),
  ('MA', 'Pedro do Rosário', '2108256'),
  ('MA', 'Penalva', '2108306'),
  ('MA', 'Peri Mirim', '2108405'),
  ('MA', 'Peritoró', '2108454'),
  ('MA', 'Pindaré-Mirim', '2108504'),
  ('MA', 'Pinheiro', '2108603'),
  ('MA', 'Pio Xii', '2108702'),
  ('MA', 'Pirapemas', '2108801'),
  ('MA', 'Poção de Pedras', '2108900'),
  ('MA', 'Porto Franco', '2109007'),
  ('MA', 'Porto Rico do Maranhão', '2109056'),
  ('MA', 'Presidente Dutra', '2109106'),
  ('MA', 'Presidente Juscelino', '2109205'),
  ('MA', 'Presidente Médici', '2109239'),
  ('MA', 'Presidente Sarney', '2109270'),
  ('MA', 'Presidente Vargas', '2109304'),
  ('MA', 'Primeira Cruz', '2109403'),
  ('MA', 'Raposa', '2109452'),
  ('MA', 'Riachão', '2109502'),
  ('MA', 'Ribamar Fiquene', '2109551'),
  ('MA', 'Rosário', '2109601'),
  ('MA', 'Sambaíba', '2109700'),
  ('MA', 'Santa Filomena do Maranhão', '2109759'),
  ('MA', 'Santa Helena', '2109809'),
  ('MA', 'Santa Inês', '2109908'),
  ('MA', 'Santa Luzia', '2110005'),
  ('MA', 'Santa Luzia do Paruá', '2110039'),
  ('MA', 'Santa Quitéria do Maranhão', '2110104'),
  ('MA', 'Santa Rita', '2110203'),
  ('MA', 'Santana do Maranhão', '2110237'),
  ('MA', 'Santo Amaro do Maranhão', '2110278'),
  ('MA', 'Santo Antônio dos Lopes', '2110302'),
  ('MA', 'São Benedito do Rio Preto', '2110401'),
  ('MA', 'São Bento', '2110500'),
  ('MA', 'São Bernardo', '2110609'),
  ('MA', 'São domingos do Azeitão', '2110658'),
  ('MA', 'São domingos do Maranhão', '2110708'),
  ('MA', 'São Félix de Balsas', '2110807'),
  ('MA', 'São Francisco do Brejão', '2110856'),
  ('MA', 'São Francisco do Maranhão', '2110906'),
  ('MA', 'São João Batista', '2111003'),
  ('MA', 'São João do Carú', '2111029'),
  ('MA', 'São João do Paraíso', '2111052'),
  ('MA', 'São João do Soter', '2111078'),
  ('MA', 'São João dos Patos', '2111102'),
  ('MA', 'São José de Ribamar', '2111201'),
  ('MA', 'São José dos Basílios', '2111250'),
  ('MA', 'São Luís', '2111300'),
  ('MA', 'São Luís Gonzaga do Maranhão', '2111409'),
  ('MA', 'São Mateus do Maranhão', '2111508'),
  ('MA', 'São Pedro da Água Branca', '2111532'),
  ('MA', 'São Pedro dos Crentes', '2111573'),
  ('MA', 'São Raimundo das Mangabeiras', '2111607'),
  ('MA', 'São Raimundo do doca Bezerra', '2111631'),
  ('MA', 'São Roberto', '2111672'),
  ('MA', 'São Vicente Ferrer', '2111706'),
  ('MA', 'Satubinha', '2111722'),
  ('MA', 'Senador Alexandre Costa', '2111748'),
  ('MA', 'Senador La Rocque', '2111763'),
  ('MA', 'Serrano do Maranhão', '2111789'),
  ('MA', 'Sítio Novo', '2111805'),
  ('MA', 'Sucupira do Norte', '2111904'),
  ('MA', 'Sucupira do Riachão', '2111953'),
  ('MA', 'Tasso Fragoso', '2112001'),
  ('MA', 'Timbiras', '2112100'),
  ('MA', 'Timon', '2112209'),
  ('MA', 'Trizidela do Vale', '2112233'),
  ('MA', 'Tufilândia', '2112274'),
  ('MA', 'Tuntum', '2112308'),
  ('MA', 'Turiaçu', '2112407'),
  ('MA', 'Turilândia', '2112456'),
  ('MA', 'Tutóia', '2112506'),
  ('MA', 'Urbano Santos', '2112605'),
  ('MA', 'Vargem Grande', '2112704'),
  ('MA', 'Viana', '2112803'),
  ('MA', 'Vila Nova dos Martírios', '2112852'),
  ('MA', 'Vitória do Mearim', '2112902'),
  ('MA', 'Vitorino Freire', '2113009'),
  ('MA', 'Zé doca', '2114007'),
  ('PI', 'Acauã', '2200053'),
  ('PI', 'Agricolândia', '2200103'),
  ('PI', 'Água Branca', '2200202'),
  ('PI', 'Alagoinha do Piauí', '2200251'),
  ('PI', 'Alegrete do Piauí', '2200277'),
  ('PI', 'Alto Longá', '2200301'),
  ('PI', 'Altos', '2200400'),
  ('PI', 'Alvorada do Gurguéia', '2200459'),
  ('PI', 'Amarante', '2200509'),
  ('PI', 'Angical do Piauí', '2200608'),
  ('PI', 'Anísio de Abreu', '2200707'),
  ('PI', 'Antônio Almeida', '2200806'),
  ('PI', 'Aroazes', '2200905'),
  ('PI', 'Aroeiras do Itaim', '2200954'),
  ('PI', 'Arraial', '2201002'),
  ('PI', 'Assunção do Piauí', '2201051'),
  ('PI', 'Avelino Lopes', '2201101'),
  ('PI', 'Baixa Grande do Ribeiro', '2201150'),
  ('PI', 'Barra D''alcântara', '2201176'),
  ('PI', 'Barras', '2201200'),
  ('PI', 'Barreiras do Piauí', '2201309'),
  ('PI', 'Barro Duro', '2201408'),
  ('PI', 'Batalha', '2201507'),
  ('PI', 'Bela Vista do Piauí', '2201556'),
  ('PI', 'Belém do Piauí', '2201572'),
  ('PI', 'Beneditinos', '2201606'),
  ('PI', 'Bertolínia', '2201705'),
  ('PI', 'Betânia do Piauí', '2201739'),
  ('PI', 'Boa Hora', '2201770'),
  ('PI', 'Bocaina', '2201804'),
  ('PI', 'Bom Jesus', '2201903'),
  ('PI', 'Bom Princípio do Piauí', '2201919'),
  ('PI', 'Bonfim do Piauí', '2201929'),
  ('PI', 'Boqueirão do Piauí', '2201945'),
  ('PI', 'Brasileira', '2201960'),
  ('PI', 'Brejo do Piauí', '2201988'),
  ('PI', 'Buriti dos Lopes', '2202000'),
  ('PI', 'Buriti dos Montes', '2202026'),
  ('PI', 'Cabeceiras do Piauí', '2202059'),
  ('PI', 'Cajazeiras do Piauí', '2202075'),
  ('PI', 'Cajueiro da Praia', '2202083'),
  ('PI', 'Caldeirão Grande do Piauí', '2202091'),
  ('PI', 'Campinas do Piauí', '2202109'),
  ('PI', 'Campo Alegre do Fidalgo', '2202117'),
  ('PI', 'Campo Grande do Piauí', '2202133'),
  ('PI', 'Campo Largo do Piauí', '2202174'),
  ('PI', 'Campo Maior', '2202208'),
  ('PI', 'Canavieira', '2202251'),
  ('PI', 'Canto do Buriti', '2202307'),
  ('PI', 'Capitão de Campos', '2202406'),
  ('PI', 'Capitão Gervásio Oliveira', '2202455'),
  ('PI', 'Caracol', '2202505'),
  ('PI', 'Caraúbas do Piauí', '2202539'),
  ('PI', 'Caridade do Piauí', '2202554'),
  ('PI', 'Castelo do Piauí', '2202604'),
  ('PI', 'Caxingó', '2202653'),
  ('PI', 'Cocal', '2202703'),
  ('PI', 'Cocal de Telha', '2202711'),
  ('PI', 'Cocal dos Alves', '2202729'),
  ('PI', 'Coivaras', '2202737'),
  ('PI', 'Colônia do Gurguéia', '2202752'),
  ('PI', 'Colônia do Piauí', '2202778'),
  ('PI', 'Conceição do Canindé', '2202802'),
  ('PI', 'Coronel José Dias', '2202851'),
  ('PI', 'Corrente', '2202901'),
  ('PI', 'Cristalândia do Piauí', '2203008'),
  ('PI', 'Cristino Castro', '2203107'),
  ('PI', 'Curimatá', '2203206'),
  ('PI', 'Currais', '2203230'),
  ('PI', 'Curralinhos', '2203255'),
  ('PI', 'Curral Novo do Piauí', '2203271'),
  ('PI', 'demerval Lobão', '2203305'),
  ('PI', 'Dirceu Arcoverde', '2203354'),
  ('PI', 'dom Expedito Lopes', '2203404'),
  ('PI', 'domingos Mourão', '2203420'),
  ('PI', 'dom Inocêncio', '2203453'),
  ('PI', 'Elesbão Veloso', '2203503'),
  ('PI', 'Eliseu Martins', '2203602'),
  ('PI', 'Esperantina', '2203701'),
  ('PI', 'Fartura do Piauí', '2203750'),
  ('PI', 'Flores do Piauí', '2203800'),
  ('PI', 'Floresta do Piauí', '2203859'),
  ('PI', 'Floriano', '2203909'),
  ('PI', 'Francinópolis', '2204006'),
  ('PI', 'Francisco Ayres', '2204105'),
  ('PI', 'Francisco Macedo', '2204154'),
  ('PI', 'Francisco Santos', '2204204'),
  ('PI', 'Fronteiras', '2204303'),
  ('PI', 'Geminiano', '2204352'),
  ('PI', 'Gilbués', '2204402'),
  ('PI', 'Guadalupe', '2204501'),
  ('PI', 'Guaribas', '2204550'),
  ('PI', 'Hugo Napoleão', '2204600'),
  ('PI', 'Ilha Grande', '2204659'),
  ('PI', 'Inhuma', '2204709'),
  ('PI', 'Ipiranga do Piauí', '2204808'),
  ('PI', 'Isaías Coelho', '2204907'),
  ('PI', 'Itainópolis', '2205003'),
  ('PI', 'Itaueira', '2205102'),
  ('PI', 'Jacobina do Piauí', '2205151'),
  ('PI', 'Jaicós', '2205201'),
  ('PI', 'Jardim do Mulato', '2205250'),
  ('PI', 'Jatobá do Piauí', '2205276'),
  ('PI', 'Jerumenha', '2205300'),
  ('PI', 'João Costa', '2205359'),
  ('PI', 'Joaquim Pires', '2205409'),
  ('PI', 'Joca Marques', '2205458'),
  ('PI', 'José de Freitas', '2205508'),
  ('PI', 'Juazeiro do Piauí', '2205516'),
  ('PI', 'Júlio Borges', '2205524'),
  ('PI', 'Jurema', '2205532'),
  ('PI', 'Lagoinha do Piauí', '2205540'),
  ('PI', 'Lagoa Alegre', '2205557'),
  ('PI', 'Lagoa do Barro do Piauí', '2205565'),
  ('PI', 'Lagoa de São Francisco', '2205573'),
  ('PI', 'Lagoa do Piauí', '2205581'),
  ('PI', 'Lagoa do Sítio', '2205599'),
  ('PI', 'Landri Sales', '2205607'),
  ('PI', 'Luís Correia', '2205706'),
  ('PI', 'Luzilândia', '2205805'),
  ('PI', 'Madeiro', '2205854'),
  ('PI', 'Manoel Emídio', '2205904'),
  ('PI', 'Marcolândia', '2205953'),
  ('PI', 'Marcos Parente', '2206001'),
  ('PI', 'Massapê do Piauí', '2206050'),
  ('PI', 'Matias Olímpio', '2206100'),
  ('PI', 'Miguel Alves', '2206209'),
  ('PI', 'Miguel Leão', '2206308'),
  ('PI', 'Milton Brandão', '2206357'),
  ('PI', 'Monsenhor Gil', '2206407'),
  ('PI', 'Monsenhor Hipólito', '2206506'),
  ('PI', 'Monte Alegre do Piauí', '2206605'),
  ('PI', 'Morro Cabeça No Tempo', '2206654'),
  ('PI', 'Morro do Chapéu do Piauí', '2206670'),
  ('PI', 'Murici dos Portelas', '2206696'),
  ('PI', 'Nazaré do Piauí', '2206704'),
  ('PI', 'Nazária', '2206720'),
  ('PI', 'Nossa Senhora de Nazaré', '2206753'),
  ('PI', 'Nossa Senhora dos Remédios', '2206803'),
  ('PI', 'Novo Oriente do Piauí', '2206902'),
  ('PI', 'Novo Santo Antônio', '2206951'),
  ('PI', 'Oeiras', '2207009'),
  ('PI', 'Olho D''água do Piauí', '2207108'),
  ('PI', 'Padre Marcos', '2207207'),
  ('PI', 'Paes Landim', '2207306'),
  ('PI', 'Pajeú do Piauí', '2207355'),
  ('PI', 'Palmeira do Piauí', '2207405'),
  ('PI', 'Palmeirais', '2207504'),
  ('PI', 'Paquetá', '2207553'),
  ('PI', 'Parnaguá', '2207603'),
  ('PI', 'Parnaíba', '2207702'),
  ('PI', 'Passagem Franca do Piauí', '2207751'),
  ('PI', 'Patos do Piauí', '2207777'),
  ('PI', 'Pau D''arco do Piauí', '2207793'),
  ('PI', 'Paulistana', '2207801'),
  ('PI', 'Pavussu', '2207850'),
  ('PI', 'Pedro Ii', '2207900'),
  ('PI', 'Pedro Laurentino', '2207934'),
  ('PI', 'Nova Santa Rita', '2207959'),
  ('PI', 'Picos', '2208007'),
  ('PI', 'Pimenteiras', '2208106'),
  ('PI', 'Pio Ix', '2208205'),
  ('PI', 'Piracuruca', '2208304'),
  ('PI', 'Piripiri', '2208403'),
  ('PI', 'Porto', '2208502'),
  ('PI', 'Porto Alegre do Piauí', '2208551'),
  ('PI', 'Prata do Piauí', '2208601'),
  ('PI', 'Queimada Nova', '2208650'),
  ('PI', 'Redenção do Gurguéia', '2208700'),
  ('PI', 'Regeneração', '2208809'),
  ('PI', 'Riacho Frio', '2208858'),
  ('PI', 'Ribeira do Piauí', '2208874'),
  ('PI', 'Ribeiro Gonçalves', '2208908'),
  ('PI', 'Rio Grande do Piauí', '2209005'),
  ('PI', 'Santa Cruz do Piauí', '2209104'),
  ('PI', 'Santa Cruz dos Milagres', '2209153'),
  ('PI', 'Santa Filomena', '2209203'),
  ('PI', 'Santa Luz', '2209302'),
  ('PI', 'Santana do Piauí', '2209351'),
  ('PI', 'Santa Rosa do Piauí', '2209377'),
  ('PI', 'Santo Antônio de Lisboa', '2209401'),
  ('PI', 'Santo Antônio dos Milagres', '2209450'),
  ('PI', 'Santo Inácio do Piauí', '2209500'),
  ('PI', 'São Braz do Piauí', '2209559'),
  ('PI', 'São Félix do Piauí', '2209609'),
  ('PI', 'São Francisco de Assis do Piauí', '2209658'),
  ('PI', 'São Francisco do Piauí', '2209708'),
  ('PI', 'São Gonçalo do Gurguéia', '2209757'),
  ('PI', 'São Gonçalo do Piauí', '2209807'),
  ('PI', 'São João da Canabrava', '2209856'),
  ('PI', 'São João da Fronteira', '2209872'),
  ('PI', 'São João da Serra', '2209906'),
  ('PI', 'São João da Varjota', '2209955'),
  ('PI', 'São João do Arraial', '2209971'),
  ('PI', 'São João do Piauí', '2210003'),
  ('PI', 'São José do Divino', '2210052'),
  ('PI', 'São José do Peixe', '2210102'),
  ('PI', 'São José do Piauí', '2210201'),
  ('PI', 'São Julião', '2210300'),
  ('PI', 'São Lourenço do Piauí', '2210359'),
  ('PI', 'São Luis do Piauí', '2210375'),
  ('PI', 'São Miguel da Baixa Grande', '2210383'),
  ('PI', 'São Miguel do Fidalgo', '2210391'),
  ('PI', 'São Miguel do Tapuio', '2210409'),
  ('PI', 'São Pedro do Piauí', '2210508'),
  ('PI', 'São Raimundo Nonato', '2210607'),
  ('PI', 'Sebastião Barros', '2210623'),
  ('PI', 'Sebastião Leal', '2210631'),
  ('PI', 'Sigefredo Pacheco', '2210656'),
  ('PI', 'Simões', '2210706'),
  ('PI', 'Simplício Mendes', '2210805'),
  ('PI', 'Socorro do Piauí', '2210904'),
  ('PI', 'Sussuapara', '2210938'),
  ('PI', 'Tamboril do Piauí', '2210953'),
  ('PI', 'Tanque do Piauí', '2210979'),
  ('PI', 'Teresina', '2211001'),
  ('PI', 'União', '2211100'),
  ('PI', 'Uruçuí', '2211209'),
  ('PI', 'Valença do Piauí', '2211308'),
  ('PI', 'Várzea Branca', '2211357'),
  ('PI', 'Várzea Grande', '2211407'),
  ('PI', 'Vera Mendes', '2211506'),
  ('PI', 'Vila Nova do Piauí', '2211605'),
  ('PI', 'Wall Ferraz', '2211704'),
  ('CE', 'Abaiara', '2300101'),
  ('CE', 'Acarape', '2300150'),
  ('CE', 'Acaraú', '2300200'),
  ('CE', 'Acopiara', '2300309'),
  ('CE', 'Aiuaba', '2300408'),
  ('CE', 'Alcântaras', '2300507'),
  ('CE', 'Altaneira', '2300606'),
  ('CE', 'Alto Santo', '2300705'),
  ('CE', 'Amontada', '2300754'),
  ('CE', 'Antonina do Norte', '2300804'),
  ('CE', 'Apuiarés', '2300903'),
  ('CE', 'Aquiraz', '2301000'),
  ('CE', 'Aracati', '2301109'),
  ('CE', 'Aracoiaba', '2301208'),
  ('CE', 'Ararendá', '2301257'),
  ('CE', 'Araripe', '2301307'),
  ('CE', 'Aratuba', '2301406'),
  ('CE', 'Arneiroz', '2301505'),
  ('CE', 'Assaré', '2301604'),
  ('CE', 'Aurora', '2301703'),
  ('CE', 'Baixio', '2301802'),
  ('CE', 'Banabuiú', '2301851'),
  ('CE', 'Barbalha', '2301901'),
  ('CE', 'Barreira', '2301950'),
  ('CE', 'Barro', '2302008'),
  ('CE', 'Barroquinha', '2302057'),
  ('CE', 'Baturité', '2302107'),
  ('CE', 'Beberibe', '2302206'),
  ('CE', 'Bela Cruz', '2302305'),
  ('CE', 'Boa Viagem', '2302404'),
  ('CE', 'Brejo Santo', '2302503'),
  ('CE', 'Camocim', '2302602'),
  ('CE', 'Campos Sales', '2302701'),
  ('CE', 'Canindé', '2302800'),
  ('CE', 'Capistrano', '2302909'),
  ('CE', 'Caridade', '2303006'),
  ('CE', 'Cariré', '2303105'),
  ('CE', 'Caririaçu', '2303204'),
  ('CE', 'Cariús', '2303303'),
  ('CE', 'Carnaubal', '2303402'),
  ('CE', 'Cascavel', '2303501'),
  ('CE', 'Catarina', '2303600'),
  ('CE', 'Catunda', '2303659'),
  ('CE', 'Caucaia', '2303709'),
  ('CE', 'Cedro', '2303808'),
  ('CE', 'Chaval', '2303907'),
  ('CE', 'Choró', '2303931'),
  ('CE', 'Chorozinho', '2303956'),
  ('CE', 'Coreaú', '2304004'),
  ('CE', 'Crateús', '2304103'),
  ('CE', 'Crato', '2304202'),
  ('CE', 'Croatá', '2304236'),
  ('CE', 'Cruz', '2304251'),
  ('CE', 'deputado Irapuan Pinheiro', '2304269'),
  ('CE', 'Ererê', '2304277'),
  ('CE', 'Eusébio', '2304285'),
  ('CE', 'Farias Brito', '2304301'),
  ('CE', 'Forquilha', '2304350'),
  ('CE', 'Fortaleza', '2304400'),
  ('CE', 'Fortim', '2304459'),
  ('CE', 'Frecheirinha', '2304509'),
  ('CE', 'General Sampaio', '2304608'),
  ('CE', 'Graça', '2304657'),
  ('CE', 'Granja', '2304707'),
  ('CE', 'Granjeiro', '2304806'),
  ('CE', 'Groaíras', '2304905'),
  ('CE', 'Guaiúba', '2304954'),
  ('CE', 'Guaraciaba do Norte', '2305001'),
  ('CE', 'Guaramiranga', '2305100'),
  ('CE', 'Hidrolândia', '2305209'),
  ('CE', 'Horizonte', '2305233'),
  ('CE', 'Ibaretama', '2305266'),
  ('CE', 'Ibiapina', '2305308'),
  ('CE', 'Ibicuitinga', '2305332'),
  ('CE', 'Icapuí', '2305357'),
  ('CE', 'Icó', '2305407'),
  ('CE', 'Iguatu', '2305506'),
  ('CE', 'Independência', '2305605'),
  ('CE', 'Ipaporanga', '2305654'),
  ('CE', 'Ipaumirim', '2305704'),
  ('CE', 'Ipu', '2305803'),
  ('CE', 'Ipueiras', '2305902'),
  ('CE', 'Iracema', '2306009'),
  ('CE', 'Irauçuba', '2306108'),
  ('CE', 'Itaiçaba', '2306207'),
  ('CE', 'Itaitinga', '2306256'),
  ('CE', 'Itapajé', '2306306'),
  ('CE', 'Itapipoca', '2306405'),
  ('CE', 'Itapiúna', '2306504'),
  ('CE', 'Itarema', '2306553'),
  ('CE', 'Itatira', '2306603'),
  ('CE', 'Jaguaretama', '2306702'),
  ('CE', 'Jaguaribara', '2306801'),
  ('CE', 'Jaguaribe', '2306900'),
  ('CE', 'Jaguaruana', '2307007'),
  ('CE', 'Jardim', '2307106'),
  ('CE', 'Jati', '2307205'),
  ('CE', 'Jijoca de Jericoacoara', '2307254'),
  ('CE', 'Juazeiro do Norte', '2307304'),
  ('CE', 'Jucás', '2307403'),
  ('CE', 'Lavras da Mangabeira', '2307502'),
  ('CE', 'Limoeiro do Norte', '2307601'),
  ('CE', 'Madalena', '2307635'),
  ('CE', 'Maracanaú', '2307650'),
  ('CE', 'Maranguape', '2307700'),
  ('CE', 'Marco', '2307809'),
  ('CE', 'Martinópole', '2307908'),
  ('CE', 'Massapê', '2308005'),
  ('CE', 'Mauriti', '2308104'),
  ('CE', 'Meruoca', '2308203'),
  ('CE', 'Milagres', '2308302'),
  ('CE', 'Milhã', '2308351'),
  ('CE', 'Miraíma', '2308377'),
  ('CE', 'Missão Velha', '2308401'),
  ('CE', 'Mombaça', '2308500'),
  ('CE', 'Monsenhor Tabosa', '2308609'),
  ('CE', 'Morada Nova', '2308708'),
  ('CE', 'Moraújo', '2308807'),
  ('CE', 'Morrinhos', '2308906'),
  ('CE', 'Mucambo', '2309003'),
  ('CE', 'Mulungu', '2309102'),
  ('CE', 'Nova Olinda', '2309201'),
  ('CE', 'Nova Russas', '2309300'),
  ('CE', 'Novo Oriente', '2309409'),
  ('CE', 'Ocara', '2309458'),
  ('CE', 'Orós', '2309508'),
  ('CE', 'Pacajus', '2309607'),
  ('CE', 'Pacatuba', '2309706'),
  ('CE', 'Pacoti', '2309805'),
  ('CE', 'Pacujá', '2309904'),
  ('CE', 'Palhano', '2310001'),
  ('CE', 'Palmácia', '2310100'),
  ('CE', 'Paracuru', '2310209'),
  ('CE', 'Paraipaba', '2310258'),
  ('CE', 'Parambu', '2310308'),
  ('CE', 'Paramoti', '2310407'),
  ('CE', 'Pedra Branca', '2310506'),
  ('CE', 'Penaforte', '2310605'),
  ('CE', 'Pentecoste', '2310704'),
  ('CE', 'Pereiro', '2310803'),
  ('CE', 'Pindoretama', '2310852'),
  ('CE', 'Piquet Carneiro', '2310902'),
  ('CE', 'Pires Ferreira', '2310951'),
  ('CE', 'Poranga', '2311009'),
  ('CE', 'Porteiras', '2311108'),
  ('CE', 'Potengi', '2311207'),
  ('CE', 'Potiretama', '2311231'),
  ('CE', 'Quiterianópolis', '2311264'),
  ('CE', 'Quixadá', '2311306'),
  ('CE', 'Quixelô', '2311355'),
  ('CE', 'Quixeramobim', '2311405'),
  ('CE', 'Quixeré', '2311504'),
  ('CE', 'Redenção', '2311603'),
  ('CE', 'Reriutaba', '2311702'),
  ('CE', 'Russas', '2311801'),
  ('CE', 'Saboeiro', '2311900'),
  ('CE', 'Salitre', '2311959'),
  ('CE', 'Santana do Acaraú', '2312007'),
  ('CE', 'Santana do Cariri', '2312106'),
  ('CE', 'Santa Quitéria', '2312205'),
  ('CE', 'São Benedito', '2312304'),
  ('CE', 'São Gonçalo do Amarante', '2312403'),
  ('CE', 'São João do Jaguaribe', '2312502'),
  ('CE', 'São Luís do Curu', '2312601'),
  ('CE', 'Senador Pompeu', '2312700'),
  ('CE', 'Senador Sá', '2312809'),
  ('CE', 'Sobral', '2312908'),
  ('CE', 'Solonópole', '2313005'),
  ('CE', 'Tabuleiro do Norte', '2313104'),
  ('CE', 'Tamboril', '2313203'),
  ('CE', 'Tarrafas', '2313252'),
  ('CE', 'Tauá', '2313302'),
  ('CE', 'Tejuçuoca', '2313351'),
  ('CE', 'Tianguá', '2313401'),
  ('CE', 'Trairi', '2313500'),
  ('CE', 'Tururu', '2313559'),
  ('CE', 'Ubajara', '2313609'),
  ('CE', 'Umari', '2313708'),
  ('CE', 'Umirim', '2313757'),
  ('CE', 'Uruburetama', '2313807'),
  ('CE', 'Uruoca', '2313906'),
  ('CE', 'Varjota', '2313955'),
  ('CE', 'Várzea Alegre', '2314003'),
  ('CE', 'Viçosa do Ceará', '2314102'),
  ('RN', 'Acari', '2400109'),
  ('RN', 'Açu', '2400208'),
  ('RN', 'Afonso Bezerra', '2400307'),
  ('RN', 'Água Nova', '2400406'),
  ('RN', 'Alexandria', '2400505'),
  ('RN', 'Almino Afonso', '2400604'),
  ('RN', 'Alto do Rodrigues', '2400703'),
  ('RN', 'Angicos', '2400802'),
  ('RN', 'Antônio Martins', '2400901'),
  ('RN', 'Apodi', '2401008'),
  ('RN', 'Areia Branca', '2401107'),
  ('RN', 'Arês', '2401206'),
  ('RN', 'Augusto Severo', '2401305'),
  ('RN', 'Baía Formosa', '2401404'),
  ('RN', 'Baraúna', '2401453'),
  ('RN', 'Barcelona', '2401503'),
  ('RN', 'Bento Fernandes', '2401602'),
  ('RN', 'Bodó', '2401651'),
  ('RN', 'Bom Jesus', '2401701'),
  ('RN', 'Brejinho', '2401800'),
  ('RN', 'Caiçara do Norte', '2401859'),
  ('RN', 'Caiçara do Rio do Vento', '2401909'),
  ('RN', 'Caicó', '2402006'),
  ('RN', 'Campo Redondo', '2402105'),
  ('RN', 'Canguaretama', '2402204'),
  ('RN', 'Caraúbas', '2402303'),
  ('RN', 'Carnaúba dos dantas', '2402402'),
  ('RN', 'Carnaubais', '2402501'),
  ('RN', 'Ceará-Mirim', '2402600'),
  ('RN', 'Cerro Corá', '2402709'),
  ('RN', 'Coronel Ezequiel', '2402808'),
  ('RN', 'Coronel João Pessoa', '2402907'),
  ('RN', 'Cruzeta', '2403004'),
  ('RN', 'Currais Novos', '2403103'),
  ('RN', 'doutor Severiano', '2403202'),
  ('RN', 'Parnamirim', '2403251'),
  ('RN', 'Encanto', '2403301'),
  ('RN', 'Equador', '2403400'),
  ('RN', 'Espírito Santo', '2403509'),
  ('RN', 'Extremoz', '2403608'),
  ('RN', 'Felipe Guerra', '2403707'),
  ('RN', 'Fernando Pedroza', '2403756'),
  ('RN', 'Florânia', '2403806'),
  ('RN', 'Francisco dantas', '2403905'),
  ('RN', 'Frutuoso Gomes', '2404002'),
  ('RN', 'Galinhos', '2404101'),
  ('RN', 'Goianinha', '2404200'),
  ('RN', 'Governador Dix-Sept Rosado', '2404309'),
  ('RN', 'Grossos', '2404408'),
  ('RN', 'Guamaré', '2404507'),
  ('RN', 'Ielmo Marinho', '2404606'),
  ('RN', 'Ipanguaçu', '2404705'),
  ('RN', 'Ipueira', '2404804'),
  ('RN', 'Itajá', '2404853'),
  ('RN', 'Itaú', '2404903'),
  ('RN', 'Jaçanã', '2405009'),
  ('RN', 'Jandaíra', '2405108'),
  ('RN', 'Janduís', '2405207'),
  ('RN', 'Januário Cicco', '2405306'),
  ('RN', 'Japi', '2405405'),
  ('RN', 'Jardim de Angicos', '2405504'),
  ('RN', 'Jardim de Piranhas', '2405603'),
  ('RN', 'Jardim do Seridó', '2405702'),
  ('RN', 'João Câmara', '2405801'),
  ('RN', 'João Dias', '2405900'),
  ('RN', 'José da Penha', '2406007'),
  ('RN', 'Jucurutu', '2406106'),
  ('RN', 'Jundiá', '2406155'),
  ('RN', 'Lagoa D''anta', '2406205'),
  ('RN', 'Lagoa de Pedras', '2406304'),
  ('RN', 'Lagoa de Velhos', '2406403'),
  ('RN', 'Lagoa Nova', '2406502'),
  ('RN', 'Lagoa Salgada', '2406601'),
  ('RN', 'Lajes', '2406700'),
  ('RN', 'Lajes Pintadas', '2406809'),
  ('RN', 'Lucrécia', '2406908'),
  ('RN', 'Luís Gomes', '2407005'),
  ('RN', 'Macaíba', '2407104'),
  ('RN', 'Macau', '2407203'),
  ('RN', 'Major Sales', '2407252'),
  ('RN', 'Marcelino Vieira', '2407302'),
  ('RN', 'Martins', '2407401'),
  ('RN', 'Maxaranguape', '2407500'),
  ('RN', 'Messias Targino', '2407609'),
  ('RN', 'Montanhas', '2407708'),
  ('RN', 'Monte Alegre', '2407807'),
  ('RN', 'Monte das Gameleiras', '2407906'),
  ('RN', 'Mossoró', '2408003'),
  ('RN', 'Natal', '2408102'),
  ('RN', 'Nísia Floresta', '2408201'),
  ('RN', 'Nova Cruz', '2408300'),
  ('RN', 'Olho-D''água do Borges', '2408409'),
  ('RN', 'Ouro Branco', '2408508'),
  ('RN', 'Paraná', '2408607'),
  ('RN', 'Paraú', '2408706'),
  ('RN', 'Parazinho', '2408805'),
  ('RN', 'Parelhas', '2408904'),
  ('RN', 'Rio do Fogo', '2408953'),
  ('RN', 'Passa E Fica', '2409100'),
  ('RN', 'Passagem', '2409209'),
  ('RN', 'Patu', '2409308'),
  ('RN', 'Santa Maria', '2409332'),
  ('RN', 'Pau dos Ferros', '2409407'),
  ('RN', 'Pedra Grande', '2409506'),
  ('RN', 'Pedra Preta', '2409605'),
  ('RN', 'Pedro Avelino', '2409704'),
  ('RN', 'Pedro Velho', '2409803'),
  ('RN', 'Pendências', '2409902'),
  ('RN', 'Pilões', '2410009'),
  ('RN', 'Poço Branco', '2410108'),
  ('RN', 'Portalegre', '2410207'),
  ('RN', 'Porto do Mangue', '2410256'),
  ('RN', 'Serra Caiada', '2410306'),
  ('RN', 'Pureza', '2410405'),
  ('RN', 'Rafael Fernandes', '2410504'),
  ('RN', 'Rafael Godeiro', '2410603'),
  ('RN', 'Riacho da Cruz', '2410702'),
  ('RN', 'Riacho de Santana', '2410801'),
  ('RN', 'Riachuelo', '2410900'),
  ('RN', 'Rodolfo Fernandes', '2411007'),
  ('RN', 'Tibau', '2411056'),
  ('RN', 'Ruy Barbosa', '2411106'),
  ('RN', 'Santa Cruz', '2411205'),
  ('RN', 'Santana do Matos', '2411403'),
  ('RN', 'Santana do Seridó', '2411429'),
  ('RN', 'Santo Antônio', '2411502'),
  ('RN', 'São Bento do Norte', '2411601'),
  ('RN', 'São Bento do Trairí', '2411700'),
  ('RN', 'São Fernando', '2411809'),
  ('RN', 'São Francisco do Oeste', '2411908'),
  ('RN', 'São Gonçalo do Amarante', '2412005'),
  ('RN', 'São João do Sabugi', '2412104'),
  ('RN', 'São José de Mipibu', '2412203'),
  ('RN', 'São José do Campestre', '2412302'),
  ('RN', 'São José do Seridó', '2412401'),
  ('RN', 'São Miguel', '2412500'),
  ('RN', 'São Miguel do Gostoso', '2412559'),
  ('RN', 'São Paulo do Potengi', '2412609'),
  ('RN', 'São Pedro', '2412708'),
  ('RN', 'São Rafael', '2412807'),
  ('RN', 'São Tomé', '2412906'),
  ('RN', 'São Vicente', '2413003'),
  ('RN', 'Senador Elói de Souza', '2413102'),
  ('RN', 'Senador Georgino Avelino', '2413201'),
  ('RN', 'Serra de São Bento', '2413300'),
  ('RN', 'Serra do Mel', '2413359'),
  ('RN', 'Serra Negra do Norte', '2413409'),
  ('RN', 'Serrinha', '2413508'),
  ('RN', 'Serrinha dos Pintos', '2413557'),
  ('RN', 'Severiano Melo', '2413607'),
  ('RN', 'Sítio Novo', '2413706'),
  ('RN', 'Taboleiro Grande', '2413805'),
  ('RN', 'Taipu', '2413904'),
  ('RN', 'Tangará', '2414001'),
  ('RN', 'Tenente Ananias', '2414100'),
  ('RN', 'Tenente Laurentino Cruz', '2414159'),
  ('RN', 'Tibau do Sul', '2414209'),
  ('RN', 'Timbaúba dos Batistas', '2414308'),
  ('RN', 'Touros', '2414407'),
  ('RN', 'Triunfo Potiguar', '2414456'),
  ('RN', 'Umarizal', '2414506'),
  ('RN', 'Upanema', '2414605'),
  ('RN', 'Várzea', '2414704'),
  ('RN', 'Venha-Ver', '2414753'),
  ('RN', 'Vera Cruz', '2414803'),
  ('RN', 'Viçosa', '2414902'),
  ('RN', 'Vila Flor', '2415008'),
  ('PB', 'Água Branca', '2500106'),
  ('PB', 'Aguiar', '2500205'),
  ('PB', 'Alagoa Grande', '2500304'),
  ('PB', 'Alagoa Nova', '2500403'),
  ('PB', 'Alagoinha', '2500502'),
  ('PB', 'Alcantil', '2500536'),
  ('PB', 'Algodão de Jandaíra', '2500577'),
  ('PB', 'Alhandra', '2500601'),
  ('PB', 'São João do Rio do Peixe', '2500700'),
  ('PB', 'Amparo', '2500734'),
  ('PB', 'Aparecida', '2500775'),
  ('PB', 'Araçagi', '2500809'),
  ('PB', 'Arara', '2500908'),
  ('PB', 'Araruna', '2501005'),
  ('PB', 'Areia', '2501104'),
  ('PB', 'Areia de Baraúnas', '2501153'),
  ('PB', 'Areial', '2501203'),
  ('PB', 'Aroeiras', '2501302'),
  ('PB', 'Assunção', '2501351'),
  ('PB', 'Baía da Traição', '2501401'),
  ('PB', 'Bananeiras', '2501500'),
  ('PB', 'Baraúna', '2501534'),
  ('PB', 'Barra de Santana', '2501575'),
  ('PB', 'Barra de Santa Rosa', '2501609'),
  ('PB', 'Barra de São Miguel', '2501708'),
  ('PB', 'Bayeux', '2501807'),
  ('PB', 'Belém', '2501906'),
  ('PB', 'Belém do Brejo do Cruz', '2502003'),
  ('PB', 'Bernardino Batista', '2502052'),
  ('PB', 'Boa Ventura', '2502102'),
  ('PB', 'Boa Vista', '2502151'),
  ('PB', 'Bom Jesus', '2502201'),
  ('PB', 'Bom Sucesso', '2502300'),
  ('PB', 'Bonito de Santa Fé', '2502409'),
  ('PB', 'Boqueirão', '2502508'),
  ('PB', 'Igaracy', '2502607'),
  ('PB', 'Borborema', '2502706'),
  ('PB', 'Brejo do Cruz', '2502805'),
  ('PB', 'Brejo dos Santos', '2502904'),
  ('PB', 'Caaporã', '2503001'),
  ('PB', 'Cabaceiras', '2503100'),
  ('PB', 'Cabedelo', '2503209'),
  ('PB', 'Cachoeira dos Índios', '2503308'),
  ('PB', 'Cacimba de Areia', '2503407'),
  ('PB', 'Cacimba de dentro', '2503506'),
  ('PB', 'Cacimbas', '2503555'),
  ('PB', 'Caiçara', '2503605'),
  ('PB', 'Cajazeiras', '2503704'),
  ('PB', 'Cajazeirinhas', '2503753'),
  ('PB', 'Caldas Brandão', '2503803'),
  ('PB', 'Camalaú', '2503902'),
  ('PB', 'Campina Grande', '2504009'),
  ('PB', 'Capim', '2504033'),
  ('PB', 'Caraúbas', '2504074'),
  ('PB', 'Carrapateira', '2504108'),
  ('PB', 'Casserengue', '2504157'),
  ('PB', 'Catingueira', '2504207'),
  ('PB', 'Catolé do Rocha', '2504306'),
  ('PB', 'Caturité', '2504355'),
  ('PB', 'Conceição', '2504405'),
  ('PB', 'Condado', '2504504'),
  ('PB', 'Conde', '2504603'),
  ('PB', 'Congo', '2504702'),
  ('PB', 'Coremas', '2504801'),
  ('PB', 'Coxixola', '2504850'),
  ('PB', 'Cruz do Espírito Santo', '2504900'),
  ('PB', 'Cubati', '2505006'),
  ('PB', 'Cuité', '2505105'),
  ('PB', 'Cuitegi', '2505204'),
  ('PB', 'Cuité de Mamanguape', '2505238'),
  ('PB', 'Curral de Cima', '2505279'),
  ('PB', 'Curral Velho', '2505303'),
  ('PB', 'damião', '2505352'),
  ('PB', 'desterro', '2505402'),
  ('PB', 'Vista Serrana', '2505501'),
  ('PB', 'Diamante', '2505600'),
  ('PB', 'dona Inês', '2505709'),
  ('PB', 'Duas Estradas', '2505808'),
  ('PB', 'Emas', '2505907'),
  ('PB', 'Esperança', '2506004'),
  ('PB', 'Fagundes', '2506103'),
  ('PB', 'Frei Martinho', '2506202'),
  ('PB', 'Gado Bravo', '2506251'),
  ('PB', 'Guarabira', '2506301'),
  ('PB', 'Gurinhém', '2506400'),
  ('PB', 'Gurjão', '2506509'),
  ('PB', 'Ibiara', '2506608'),
  ('PB', 'Imaculada', '2506707'),
  ('PB', 'Ingá', '2506806'),
  ('PB', 'Itabaiana', '2506905'),
  ('PB', 'Itaporanga', '2507002'),
  ('PB', 'Itapororoca', '2507101'),
  ('PB', 'Itatuba', '2507200'),
  ('PB', 'Jacaraú', '2507309'),
  ('PB', 'Jericó', '2507408'),
  ('PB', 'João Pessoa', '2507507'),
  ('PB', 'Juarez Távora', '2507606'),
  ('PB', 'Juazeirinho', '2507705'),
  ('PB', 'Junco do Seridó', '2507804'),
  ('PB', 'Juripiranga', '2507903'),
  ('PB', 'Juru', '2508000'),
  ('PB', 'Lagoa', '2508109'),
  ('PB', 'Lagoa de dentro', '2508208'),
  ('PB', 'Lagoa Seca', '2508307'),
  ('PB', 'Lastro', '2508406'),
  ('PB', 'Livramento', '2508505'),
  ('PB', 'Logradouro', '2508554'),
  ('PB', 'Lucena', '2508604'),
  ('PB', 'Mãe D''água', '2508703'),
  ('PB', 'Malta', '2508802'),
  ('PB', 'Mamanguape', '2508901'),
  ('PB', 'Manaíra', '2509008'),
  ('PB', 'Marcação', '2509057'),
  ('PB', 'Mari', '2509107'),
  ('PB', 'Marizópolis', '2509156'),
  ('PB', 'Massaranduba', '2509206'),
  ('PB', 'Mataraca', '2509305'),
  ('PB', 'Matinhas', '2509339'),
  ('PB', 'Mato Grosso', '2509370'),
  ('PB', 'Maturéia', '2509396'),
  ('PB', 'Mogeiro', '2509404'),
  ('PB', 'Montadas', '2509503'),
  ('PB', 'Monte Horebe', '2509602'),
  ('PB', 'Monteiro', '2509701'),
  ('PB', 'Mulungu', '2509800'),
  ('PB', 'Natuba', '2509909'),
  ('PB', 'Nazarezinho', '2510006'),
  ('PB', 'Nova Floresta', '2510105'),
  ('PB', 'Nova Olinda', '2510204'),
  ('PB', 'Nova Palmeira', '2510303'),
  ('PB', 'Olho D''água', '2510402'),
  ('PB', 'Olivedos', '2510501'),
  ('PB', 'Ouro Velho', '2510600'),
  ('PB', 'Parari', '2510659'),
  ('PB', 'Passagem', '2510709'),
  ('PB', 'Patos', '2510808'),
  ('PB', 'Paulista', '2510907'),
  ('PB', 'Pedra Branca', '2511004'),
  ('PB', 'Pedra Lavrada', '2511103'),
  ('PB', 'Pedras de Fogo', '2511202'),
  ('PB', 'Piancó', '2511301'),
  ('PB', 'Picuí', '2511400'),
  ('PB', 'Pilar', '2511509'),
  ('PB', 'Pilões', '2511608'),
  ('PB', 'Pilõezinhos', '2511707'),
  ('PB', 'Pirpirituba', '2511806'),
  ('PB', 'Pitimbu', '2511905'),
  ('PB', 'Pocinhos', '2512002'),
  ('PB', 'Poço dantas', '2512036'),
  ('PB', 'Poço de José de Moura', '2512077'),
  ('PB', 'Pombal', '2512101'),
  ('PB', 'Prata', '2512200'),
  ('PB', 'Princesa Isabel', '2512309'),
  ('PB', 'Puxinanã', '2512408'),
  ('PB', 'Queimadas', '2512507'),
  ('PB', 'Quixaba', '2512606'),
  ('PB', 'Remígio', '2512705'),
  ('PB', 'Pedro Régis', '2512721'),
  ('PB', 'Riachão', '2512747'),
  ('PB', 'Riachão do Bacamarte', '2512754'),
  ('PB', 'Riachão do Poço', '2512762'),
  ('PB', 'Riacho de Santo Antônio', '2512788'),
  ('PB', 'Riacho dos Cavalos', '2512804'),
  ('PB', 'Rio Tinto', '2512903'),
  ('PB', 'Salgadinho', '2513000'),
  ('PB', 'Salgado de São Félix', '2513109'),
  ('PB', 'Santa Cecília', '2513158'),
  ('PB', 'Santa Cruz', '2513208'),
  ('PB', 'Santa Helena', '2513307'),
  ('PB', 'Santa Inês', '2513356'),
  ('PB', 'Santa Luzia', '2513406'),
  ('PB', 'Santana de Mangueira', '2513505'),
  ('PB', 'Santana dos Garrotes', '2513604'),
  ('PB', 'Joca Claudino', '2513653'),
  ('PB', 'Santa Rita', '2513703'),
  ('PB', 'Santa Teresinha', '2513802'),
  ('PB', 'Santo André', '2513851'),
  ('PB', 'São Bento', '2513901'),
  ('PB', 'São Bentinho', '2513927'),
  ('PB', 'São domingos do Cariri', '2513943'),
  ('PB', 'São domingos', '2513968'),
  ('PB', 'São Francisco', '2513984'),
  ('PB', 'São João do Cariri', '2514008'),
  ('PB', 'São João do Tigre', '2514107'),
  ('PB', 'São José da Lagoa Tapada', '2514206'),
  ('PB', 'São José de Caiana', '2514305'),
  ('PB', 'São José de Espinharas', '2514404'),
  ('PB', 'São José dos Ramos', '2514453'),
  ('PB', 'São José de Piranhas', '2514503'),
  ('PB', 'São José de Princesa', '2514552'),
  ('PB', 'São José do Bonfim', '2514602'),
  ('PB', 'São José do Brejo do Cruz', '2514651'),
  ('PB', 'São José do Sabugi', '2514701'),
  ('PB', 'São José dos Cordeiros', '2514800'),
  ('PB', 'São Mamede', '2514909'),
  ('PB', 'São Miguel de Taipu', '2515005'),
  ('PB', 'São Sebastião de Lagoa de Roça', '2515104'),
  ('PB', 'São Sebastião do Umbuzeiro', '2515203'),
  ('PB', 'Sapé', '2515302'),
  ('PB', 'São Vicente do Seridó', '2515401'),
  ('PB', 'Serra Branca', '2515500'),
  ('PB', 'Serra da Raiz', '2515609'),
  ('PB', 'Serra Grande', '2515708'),
  ('PB', 'Serra Redonda', '2515807'),
  ('PB', 'Serraria', '2515906'),
  ('PB', 'Sertãozinho', '2515930'),
  ('PB', 'Sobrado', '2515971'),
  ('PB', 'Solânea', '2516003'),
  ('PB', 'Soledade', '2516102'),
  ('PB', 'Sossêgo', '2516151'),
  ('PB', 'Sousa', '2516201'),
  ('PB', 'Sumé', '2516300'),
  ('PB', 'Tacima', '2516409'),
  ('PB', 'Taperoá', '2516508'),
  ('PB', 'Tavares', '2516607'),
  ('PB', 'Teixeira', '2516706'),
  ('PB', 'Tenório', '2516755'),
  ('PB', 'Triunfo', '2516805'),
  ('PB', 'Uiraúna', '2516904'),
  ('PB', 'Umbuzeiro', '2517001'),
  ('PB', 'Várzea', '2517100'),
  ('PB', 'Vieirópolis', '2517209'),
  ('PB', 'Zabelê', '2517407'),
  ('PE', 'Abreu E Lima', '2600054'),
  ('PE', 'Afogados da Ingazeira', '2600104'),
  ('PE', 'Afrânio', '2600203'),
  ('PE', 'Agrestina', '2600302'),
  ('PE', 'Água Preta', '2600401'),
  ('PE', 'Águas Belas', '2600500'),
  ('PE', 'Alagoinha', '2600609'),
  ('PE', 'Aliança', '2600708'),
  ('PE', 'Altinho', '2600807'),
  ('PE', 'Amaraji', '2600906'),
  ('PE', 'Angelim', '2601003'),
  ('PE', 'Araçoiaba', '2601052'),
  ('PE', 'Araripina', '2601102'),
  ('PE', 'Arcoverde', '2601201'),
  ('PE', 'Barra de Guabiraba', '2601300'),
  ('PE', 'Barreiros', '2601409'),
  ('PE', 'Belém de Maria', '2601508'),
  ('PE', 'Belém do São Francisco', '2601607'),
  ('PE', 'Belo Jardim', '2601706'),
  ('PE', 'Betânia', '2601805'),
  ('PE', 'Bezerros', '2601904'),
  ('PE', 'Bodocó', '2602001'),
  ('PE', 'Bom Conselho', '2602100'),
  ('PE', 'Bom Jardim', '2602209'),
  ('PE', 'Bonito', '2602308'),
  ('PE', 'Brejão', '2602407'),
  ('PE', 'Brejinho', '2602506'),
  ('PE', 'Brejo da Madre de deus', '2602605'),
  ('PE', 'Buenos Aires', '2602704'),
  ('PE', 'Buíque', '2602803'),
  ('PE', 'Cabo de Santo Agostinho', '2602902'),
  ('PE', 'Cabrobó', '2603009'),
  ('PE', 'Cachoeirinha', '2603108'),
  ('PE', 'Caetés', '2603207'),
  ('PE', 'Calçado', '2603306'),
  ('PE', 'Calumbi', '2603405'),
  ('PE', 'Camaragibe', '2603454'),
  ('PE', 'Camocim de São Félix', '2603504'),
  ('PE', 'Camutanga', '2603603'),
  ('PE', 'Canhotinho', '2603702'),
  ('PE', 'Capoeiras', '2603801'),
  ('PE', 'Carnaíba', '2603900'),
  ('PE', 'Carnaubeira da Penha', '2603926'),
  ('PE', 'Carpina', '2604007'),
  ('PE', 'Caruaru', '2604106'),
  ('PE', 'Casinhas', '2604155'),
  ('PE', 'Catende', '2604205'),
  ('PE', 'Cedro', '2604304'),
  ('PE', 'Chã de Alegria', '2604403'),
  ('PE', 'Chã Grande', '2604502'),
  ('PE', 'Condado', '2604601'),
  ('PE', 'Correntes', '2604700'),
  ('PE', 'Cortês', '2604809'),
  ('PE', 'Cumaru', '2604908'),
  ('PE', 'Cupira', '2605004'),
  ('PE', 'Custódia', '2605103'),
  ('PE', 'dormentes', '2605152'),
  ('PE', 'Escada', '2605202'),
  ('PE', 'Exu', '2605301'),
  ('PE', 'Feira Nova', '2605400'),
  ('PE', 'Fernando de Noronha', '2605459'),
  ('PE', 'Ferreiros', '2605509'),
  ('PE', 'Flores', '2605608'),
  ('PE', 'Floresta', '2605707'),
  ('PE', 'Frei Miguelinho', '2605806'),
  ('PE', 'Gameleira', '2605905'),
  ('PE', 'Garanhuns', '2606002'),
  ('PE', 'Glória do Goitá', '2606101'),
  ('PE', 'Goiana', '2606200'),
  ('PE', 'Granito', '2606309'),
  ('PE', 'Gravatá', '2606408'),
  ('PE', 'Iati', '2606507'),
  ('PE', 'Ibimirim', '2606606'),
  ('PE', 'Ibirajuba', '2606705'),
  ('PE', 'Igarassu', '2606804'),
  ('PE', 'Iguaracy', '2606903'),
  ('PE', 'Inajá', '2607000'),
  ('PE', 'Ingazeira', '2607109'),
  ('PE', 'Ipojuca', '2607208'),
  ('PE', 'Ipubi', '2607307'),
  ('PE', 'Itacuruba', '2607406'),
  ('PE', 'Itaíba', '2607505'),
  ('PE', 'Ilha de Itamaracá', '2607604'),
  ('PE', 'Itambé', '2607653'),
  ('PE', 'Itapetim', '2607703'),
  ('PE', 'Itapissuma', '2607752'),
  ('PE', 'Itaquitinga', '2607802'),
  ('PE', 'Jaboatão dos Guararapes', '2607901'),
  ('PE', 'Jaqueira', '2607950'),
  ('PE', 'Jataúba', '2608008'),
  ('PE', 'Jatobá', '2608057'),
  ('PE', 'João Alfredo', '2608107'),
  ('PE', 'Joaquim Nabuco', '2608206'),
  ('PE', 'Jucati', '2608255'),
  ('PE', 'Jupi', '2608305'),
  ('PE', 'Jurema', '2608404'),
  ('PE', 'Lagoa do Carro', '2608453'),
  ('PE', 'Lagoa de Itaenga', '2608503'),
  ('PE', 'Lagoa do Ouro', '2608602'),
  ('PE', 'Lagoa dos Gatos', '2608701'),
  ('PE', 'Lagoa Grande', '2608750'),
  ('PE', 'Lajedo', '2608800'),
  ('PE', 'Limoeiro', '2608909'),
  ('PE', 'Macaparana', '2609006'),
  ('PE', 'Machados', '2609105'),
  ('PE', 'Manari', '2609154'),
  ('PE', 'Maraial', '2609204'),
  ('PE', 'Mirandiba', '2609303'),
  ('PE', 'Moreno', '2609402'),
  ('PE', 'Nazaré da Mata', '2609501'),
  ('PE', 'Olinda', '2609600'),
  ('PE', 'Orobó', '2609709'),
  ('PE', 'Orocó', '2609808'),
  ('PE', 'Ouricuri', '2609907'),
  ('PE', 'Palmares', '2610004'),
  ('PE', 'Palmeirina', '2610103'),
  ('PE', 'Panelas', '2610202'),
  ('PE', 'Paranatama', '2610301'),
  ('PE', 'Parnamirim', '2610400'),
  ('PE', 'Passira', '2610509'),
  ('PE', 'Paudalho', '2610608'),
  ('PE', 'Paulista', '2610707'),
  ('PE', 'Pedra', '2610806'),
  ('PE', 'Pesqueira', '2610905'),
  ('PE', 'Petrolândia', '2611002'),
  ('PE', 'Petrolina', '2611101'),
  ('PE', 'Poção', '2611200'),
  ('PE', 'Pombos', '2611309'),
  ('PE', 'Primavera', '2611408'),
  ('PE', 'Quipapá', '2611507'),
  ('PE', 'Quixaba', '2611533'),
  ('PE', 'Recife', '2611606'),
  ('PE', 'Riacho das Almas', '2611705'),
  ('PE', 'Ribeirão', '2611804'),
  ('PE', 'Rio Formoso', '2611903'),
  ('PE', 'Sairé', '2612000'),
  ('PE', 'Salgadinho', '2612109'),
  ('PE', 'Salgueiro', '2612208'),
  ('PE', 'Saloá', '2612307'),
  ('PE', 'Sanharó', '2612406'),
  ('PE', 'Santa Cruz', '2612455'),
  ('PE', 'Santa Cruz da Baixa Verde', '2612471'),
  ('PE', 'Santa Cruz do Capibaribe', '2612505'),
  ('PE', 'Santa Filomena', '2612554'),
  ('PE', 'Santa Maria da Boa Vista', '2612604'),
  ('PE', 'Santa Maria do Cambucá', '2612703'),
  ('PE', 'Santa Terezinha', '2612802'),
  ('PE', 'São Benedito do Sul', '2612901'),
  ('PE', 'São Bento do Una', '2613008'),
  ('PE', 'São Caitano', '2613107'),
  ('PE', 'São João', '2613206'),
  ('PE', 'São Joaquim do Monte', '2613305'),
  ('PE', 'São José da Coroa Grande', '2613404'),
  ('PE', 'São José do Belmonte', '2613503'),
  ('PE', 'São José do Egito', '2613602'),
  ('PE', 'São Lourenço da Mata', '2613701'),
  ('PE', 'São Vicente Ferrer', '2613800'),
  ('PE', 'Serra Talhada', '2613909'),
  ('PE', 'Serrita', '2614006'),
  ('PE', 'Sertânia', '2614105'),
  ('PE', 'Sirinhaém', '2614204'),
  ('PE', 'Moreilândia', '2614303'),
  ('PE', 'Solidão', '2614402'),
  ('PE', 'Surubim', '2614501'),
  ('PE', 'Tabira', '2614600'),
  ('PE', 'Tacaimbó', '2614709'),
  ('PE', 'Tacaratu', '2614808'),
  ('PE', 'Tamandaré', '2614857'),
  ('PE', 'Taquaritinga do Norte', '2615003'),
  ('PE', 'Terezinha', '2615102'),
  ('PE', 'Terra Nova', '2615201'),
  ('PE', 'Timbaúba', '2615300'),
  ('PE', 'Toritama', '2615409'),
  ('PE', 'Tracunhaém', '2615508'),
  ('PE', 'Trindade', '2615607'),
  ('PE', 'Triunfo', '2615706'),
  ('PE', 'Tupanatinga', '2615805'),
  ('PE', 'Tuparetama', '2615904'),
  ('PE', 'Venturosa', '2616001'),
  ('PE', 'Verdejante', '2616100'),
  ('PE', 'Vertente do Lério', '2616183'),
  ('PE', 'Vertentes', '2616209'),
  ('PE', 'Vicência', '2616308'),
  ('PE', 'Vitória de Santo Antão', '2616407'),
  ('PE', 'Xexéu', '2616506'),
  ('AL', 'Água Branca', '2700102'),
  ('AL', 'Anadia', '2700201'),
  ('AL', 'Arapiraca', '2700300'),
  ('AL', 'Atalaia', '2700409'),
  ('AL', 'Barra de Santo Antônio', '2700508'),
  ('AL', 'Barra de São Miguel', '2700607'),
  ('AL', 'Batalha', '2700706'),
  ('AL', 'Belém', '2700805'),
  ('AL', 'Belo Monte', '2700904'),
  ('AL', 'Boca da Mata', '2701001'),
  ('AL', 'Branquinha', '2701100'),
  ('AL', 'Cacimbinhas', '2701209'),
  ('AL', 'Cajueiro', '2701308'),
  ('AL', 'Campestre', '2701357'),
  ('AL', 'Campo Alegre', '2701407'),
  ('AL', 'Campo Grande', '2701506'),
  ('AL', 'Canapi', '2701605'),
  ('AL', 'Capela', '2701704'),
  ('AL', 'Carneiros', '2701803'),
  ('AL', 'Chã Preta', '2701902'),
  ('AL', 'Coité do Nóia', '2702009'),
  ('AL', 'Colônia Leopoldina', '2702108'),
  ('AL', 'Coqueiro Seco', '2702207'),
  ('AL', 'Coruripe', '2702306'),
  ('AL', 'Craíbas', '2702355'),
  ('AL', 'delmiro Gouveia', '2702405'),
  ('AL', 'dois Riachos', '2702504'),
  ('AL', 'Estrela de Alagoas', '2702553'),
  ('AL', 'Feira Grande', '2702603'),
  ('AL', 'Feliz deserto', '2702702'),
  ('AL', 'Flexeiras', '2702801'),
  ('AL', 'Girau do Ponciano', '2702900'),
  ('AL', 'Ibateguara', '2703007'),
  ('AL', 'Igaci', '2703106'),
  ('AL', 'Igreja Nova', '2703205'),
  ('AL', 'Inhapi', '2703304'),
  ('AL', 'Jacaré dos Homens', '2703403'),
  ('AL', 'Jacuípe', '2703502'),
  ('AL', 'Japaratinga', '2703601'),
  ('AL', 'Jaramataia', '2703700'),
  ('AL', 'Jequiá da Praia', '2703759'),
  ('AL', 'Joaquim Gomes', '2703809'),
  ('AL', 'Jundiá', '2703908'),
  ('AL', 'Junqueiro', '2704005'),
  ('AL', 'Lagoa da Canoa', '2704104'),
  ('AL', 'Limoeiro de Anadia', '2704203'),
  ('AL', 'Maceió', '2704302'),
  ('AL', 'Major Isidoro', '2704401'),
  ('AL', 'Maragogi', '2704500'),
  ('AL', 'Maravilha', '2704609'),
  ('AL', 'Marechal deodoro', '2704708'),
  ('AL', 'Maribondo', '2704807'),
  ('AL', 'Mar Vermelho', '2704906'),
  ('AL', 'Mata Grande', '2705002'),
  ('AL', 'Matriz de Camaragibe', '2705101'),
  ('AL', 'Messias', '2705200'),
  ('AL', 'Minador do Negrão', '2705309'),
  ('AL', 'Monteirópolis', '2705408'),
  ('AL', 'Murici', '2705507'),
  ('AL', 'Novo Lino', '2705606'),
  ('AL', 'Olho D''água das Flores', '2705705'),
  ('AL', 'Olho D''água do Casado', '2705804'),
  ('AL', 'Olho D''água Grande', '2705903'),
  ('AL', 'Olivença', '2706000'),
  ('AL', 'Ouro Branco', '2706109'),
  ('AL', 'Palestina', '2706208'),
  ('AL', 'Palmeira dos Índios', '2706307'),
  ('AL', 'Pão de Açúcar', '2706406'),
  ('AL', 'Pariconha', '2706422'),
  ('AL', 'Paripueira', '2706448'),
  ('AL', 'Passo de Camaragibe', '2706505'),
  ('AL', 'Paulo Jacinto', '2706604'),
  ('AL', 'Penedo', '2706703'),
  ('AL', 'Piaçabuçu', '2706802'),
  ('AL', 'Pilar', '2706901'),
  ('AL', 'Pindoba', '2707008'),
  ('AL', 'Piranhas', '2707107'),
  ('AL', 'Poço das Trincheiras', '2707206'),
  ('AL', 'Porto Calvo', '2707305'),
  ('AL', 'Porto de Pedras', '2707404'),
  ('AL', 'Porto Real do Colégio', '2707503'),
  ('AL', 'Quebrangulo', '2707602'),
  ('AL', 'Rio Largo', '2707701'),
  ('AL', 'Roteiro', '2707800'),
  ('AL', 'Santa Luzia do Norte', '2707909'),
  ('AL', 'Santana do Ipanema', '2708006'),
  ('AL', 'Santana do Mundaú', '2708105'),
  ('AL', 'São Brás', '2708204'),
  ('AL', 'São José da Laje', '2708303'),
  ('AL', 'São José da Tapera', '2708402'),
  ('AL', 'São Luís do Quitunde', '2708501'),
  ('AL', 'São Miguel dos Campos', '2708600'),
  ('AL', 'São Miguel dos Milagres', '2708709'),
  ('AL', 'São Sebastião', '2708808'),
  ('AL', 'Satuba', '2708907'),
  ('AL', 'Senador Rui Palmeira', '2708956'),
  ('AL', 'Tanque D''arca', '2709004'),
  ('AL', 'Taquarana', '2709103'),
  ('AL', 'Teotônio Vilela', '2709152'),
  ('AL', 'Traipu', '2709202'),
  ('AL', 'União dos Palmares', '2709301'),
  ('AL', 'Viçosa', '2709400'),
  ('SE', 'Amparo de São Francisco', '2800100'),
  ('SE', 'Aquidabã', '2800209'),
  ('SE', 'Aracaju', '2800308'),
  ('SE', 'Arauá', '2800407'),
  ('SE', 'Areia Branca', '2800506'),
  ('SE', 'Barra dos Coqueiros', '2800605'),
  ('SE', 'Boquim', '2800670'),
  ('SE', 'Brejo Grande', '2800704'),
  ('SE', 'Campo do Brito', '2801009'),
  ('SE', 'Canhoba', '2801108'),
  ('SE', 'Canindé de São Francisco', '2801207'),
  ('SE', 'Capela', '2801306'),
  ('SE', 'Carira', '2801405'),
  ('SE', 'Carmópolis', '2801504'),
  ('SE', 'Cedro de São João', '2801603'),
  ('SE', 'Cristinápolis', '2801702'),
  ('SE', 'Cumbe', '2801900'),
  ('SE', 'Divina Pastora', '2802007'),
  ('SE', 'Estância', '2802106'),
  ('SE', 'Feira Nova', '2802205'),
  ('SE', 'Frei Paulo', '2802304'),
  ('SE', 'Gararu', '2802403'),
  ('SE', 'General Maynard', '2802502'),
  ('SE', 'Gracho Cardoso', '2802601'),
  ('SE', 'Ilha das Flores', '2802700'),
  ('SE', 'Indiaroba', '2802809'),
  ('SE', 'Itabaiana', '2802908'),
  ('SE', 'Itabaianinha', '2803005'),
  ('SE', 'Itabi', '2803104'),
  ('SE', 'Itaporanga D''ajuda', '2803203'),
  ('SE', 'Japaratuba', '2803302'),
  ('SE', 'Japoatã', '2803401'),
  ('SE', 'Lagarto', '2803500'),
  ('SE', 'Laranjeiras', '2803609'),
  ('SE', 'Macambira', '2803708'),
  ('SE', 'Malhada dos Bois', '2803807'),
  ('SE', 'Malhador', '2803906'),
  ('SE', 'Maruim', '2804003'),
  ('SE', 'Moita Bonita', '2804102'),
  ('SE', 'Monte Alegre de Sergipe', '2804201'),
  ('SE', 'Muribeca', '2804300'),
  ('SE', 'Neópolis', '2804409'),
  ('SE', 'Nossa Senhora Aparecida', '2804458'),
  ('SE', 'Nossa Senhora da Glória', '2804508'),
  ('SE', 'Nossa Senhora das dores', '2804607'),
  ('SE', 'Nossa Senhora de Lourdes', '2804706'),
  ('SE', 'Nossa Senhora do Socorro', '2804805'),
  ('SE', 'Pacatuba', '2804904'),
  ('SE', 'Pedra Mole', '2805000'),
  ('SE', 'Pedrinhas', '2805109'),
  ('SE', 'Pinhão', '2805208'),
  ('SE', 'Pirambu', '2805307'),
  ('SE', 'Poço Redondo', '2805406'),
  ('SE', 'Poço Verde', '2805505'),
  ('SE', 'Porto da Folha', '2805604'),
  ('SE', 'Propriá', '2805703'),
  ('SE', 'Riachão do dantas', '2805802'),
  ('SE', 'Riachuelo', '2805901'),
  ('SE', 'Ribeirópolis', '2806008'),
  ('SE', 'Rosário do Catete', '2806107'),
  ('SE', 'Salgado', '2806206'),
  ('SE', 'Santa Luzia do Itanhy', '2806305'),
  ('SE', 'Santana do São Francisco', '2806404'),
  ('SE', 'Santa Rosa de Lima', '2806503'),
  ('SE', 'Santo Amaro das Brotas', '2806602'),
  ('SE', 'São Cristóvão', '2806701'),
  ('SE', 'São domingos', '2806800'),
  ('SE', 'São Francisco', '2806909'),
  ('SE', 'São Miguel do Aleixo', '2807006'),
  ('SE', 'Simão Dias', '2807105'),
  ('SE', 'Siriri', '2807204'),
  ('SE', 'Telha', '2807303'),
  ('SE', 'Tobias Barreto', '2807402'),
  ('SE', 'Tomar do Geru', '2807501'),
  ('SE', 'Umbaúba', '2807600'),
  ('BA', 'Abaíra', '2900108'),
  ('BA', 'Abaré', '2900207'),
  ('BA', 'Acajutiba', '2900306'),
  ('BA', 'Adustina', '2900355'),
  ('BA', 'Água Fria', '2900405'),
  ('BA', 'Érico Cardoso', '2900504'),
  ('BA', 'Aiquara', '2900603'),
  ('BA', 'Alagoinhas', '2900702'),
  ('BA', 'Alcobaça', '2900801'),
  ('BA', 'Almadina', '2900900'),
  ('BA', 'Amargosa', '2901007'),
  ('BA', 'Amélia Rodrigues', '2901106'),
  ('BA', 'América dourada', '2901155'),
  ('BA', 'Anagé', '2901205'),
  ('BA', 'Andaraí', '2901304'),
  ('BA', 'Andorinha', '2901353'),
  ('BA', 'Angical', '2901403'),
  ('BA', 'Anguera', '2901502'),
  ('BA', 'Antas', '2901601'),
  ('BA', 'Antônio Cardoso', '2901700'),
  ('BA', 'Antônio Gonçalves', '2901809'),
  ('BA', 'Aporá', '2901908'),
  ('BA', 'Apuarema', '2901957'),
  ('BA', 'Aracatu', '2902005'),
  ('BA', 'Araças', '2902054'),
  ('BA', 'Araci', '2902104'),
  ('BA', 'Aramari', '2902203'),
  ('BA', 'Arataca', '2902252'),
  ('BA', 'Aratuípe', '2902302'),
  ('BA', 'Aurelino Leal', '2902401'),
  ('BA', 'Baianópolis', '2902500'),
  ('BA', 'Baixa Grande', '2902609'),
  ('BA', 'Banzaê', '2902658'),
  ('BA', 'Barra', '2902708'),
  ('BA', 'Barra da Estiva', '2902807'),
  ('BA', 'Barra do Choça', '2902906'),
  ('BA', 'Barra do Mendes', '2903003'),
  ('BA', 'Barra do Rocha', '2903102'),
  ('BA', 'Barreiras', '2903201'),
  ('BA', 'Barro Alto', '2903235'),
  ('BA', 'Barrocas', '2903276'),
  ('BA', 'Barro Preto', '2903300'),
  ('BA', 'Belmonte', '2903409'),
  ('BA', 'Belo Campo', '2903508'),
  ('BA', 'Biritinga', '2903607'),
  ('BA', 'Boa Nova', '2903706'),
  ('BA', 'Boa Vista do Tupim', '2903805'),
  ('BA', 'Bom Jesus da Lapa', '2903904'),
  ('BA', 'Bom Jesus da Serra', '2903953'),
  ('BA', 'Boninal', '2904001'),
  ('BA', 'Bonito', '2904050'),
  ('BA', 'Boquira', '2904100'),
  ('BA', 'Botuporã', '2904209'),
  ('BA', 'Brejões', '2904308'),
  ('BA', 'Brejolândia', '2904407'),
  ('BA', 'Brotas de Macaúbas', '2904506'),
  ('BA', 'Brumado', '2904605'),
  ('BA', 'Buerarema', '2904704'),
  ('BA', 'Buritirama', '2904753'),
  ('BA', 'Caatiba', '2904803'),
  ('BA', 'Cabaceiras do Paraguaçu', '2904852'),
  ('BA', 'Cachoeira', '2904902'),
  ('BA', 'Caculé', '2905008'),
  ('BA', 'Caém', '2905107'),
  ('BA', 'Caetanos', '2905156'),
  ('BA', 'Caetité', '2905206'),
  ('BA', 'Cafarnaum', '2905305'),
  ('BA', 'Cairu', '2905404'),
  ('BA', 'Caldeirão Grande', '2905503'),
  ('BA', 'Camacan', '2905602'),
  ('BA', 'Camaçari', '2905701'),
  ('BA', 'Camamu', '2905800'),
  ('BA', 'Campo Alegre de Lourdes', '2905909'),
  ('BA', 'Campo Formoso', '2906006'),
  ('BA', 'Canápolis', '2906105'),
  ('BA', 'Canarana', '2906204'),
  ('BA', 'Canavieiras', '2906303'),
  ('BA', 'Candeal', '2906402'),
  ('BA', 'Candeias', '2906501'),
  ('BA', 'Candiba', '2906600'),
  ('BA', 'Cândido Sales', '2906709'),
  ('BA', 'Cansanção', '2906808'),
  ('BA', 'Canudos', '2906824'),
  ('BA', 'Capela do Alto Alegre', '2906857'),
  ('BA', 'Capim Grosso', '2906873'),
  ('BA', 'Caraíbas', '2906899'),
  ('BA', 'Caravelas', '2906907'),
  ('BA', 'Cardeal da Silva', '2907004'),
  ('BA', 'Carinhanha', '2907103'),
  ('BA', 'Casa Nova', '2907202'),
  ('BA', 'Castro Alves', '2907301'),
  ('BA', 'Catolândia', '2907400'),
  ('BA', 'Catu', '2907509'),
  ('BA', 'Caturama', '2907558'),
  ('BA', 'Central', '2907608'),
  ('BA', 'Chorrochó', '2907707'),
  ('BA', 'Cícero dantas', '2907806'),
  ('BA', 'Cipó', '2907905'),
  ('BA', 'Coaraci', '2908002'),
  ('BA', 'Cocos', '2908101'),
  ('BA', 'Conceição da Feira', '2908200'),
  ('BA', 'Conceição do Almeida', '2908309'),
  ('BA', 'Conceição do Coité', '2908408'),
  ('BA', 'Conceição do Jacuípe', '2908507'),
  ('BA', 'Conde', '2908606'),
  ('BA', 'Condeúba', '2908705'),
  ('BA', 'Contendas do Sincorá', '2908804'),
  ('BA', 'Coração de Maria', '2908903'),
  ('BA', 'Cordeiros', '2909000'),
  ('BA', 'Coribe', '2909109'),
  ('BA', 'Coronel João Sá', '2909208'),
  ('BA', 'Correntina', '2909307'),
  ('BA', 'Cotegipe', '2909406'),
  ('BA', 'Cravolândia', '2909505'),
  ('BA', 'Crisópolis', '2909604'),
  ('BA', 'Cristópolis', '2909703'),
  ('BA', 'Cruz das Almas', '2909802'),
  ('BA', 'Curaçá', '2909901'),
  ('BA', 'Dário Meira', '2910008'),
  ('BA', 'Dias D''ávila', '2910057'),
  ('BA', 'dom Basílio', '2910107'),
  ('BA', 'dom Macedo Costa', '2910206'),
  ('BA', 'Elísio Medrado', '2910305'),
  ('BA', 'Encruzilhada', '2910404'),
  ('BA', 'Entre Rios', '2910503'),
  ('BA', 'Esplanada', '2910602'),
  ('BA', 'Euclides da Cunha', '2910701'),
  ('BA', 'Eunápolis', '2910727'),
  ('BA', 'Fátima', '2910750'),
  ('BA', 'Feira da Mata', '2910776'),
  ('BA', 'Feira de Santana', '2910800'),
  ('BA', 'Filadélfia', '2910859'),
  ('BA', 'Firmino Alves', '2910909'),
  ('BA', 'Floresta Azul', '2911006'),
  ('BA', 'Formosa do Rio Preto', '2911105'),
  ('BA', 'Gandu', '2911204'),
  ('BA', 'Gavião', '2911253'),
  ('BA', 'Gentio do Ouro', '2911303'),
  ('BA', 'Glória', '2911402'),
  ('BA', 'Gongogi', '2911501'),
  ('BA', 'Governador Mangabeira', '2911600'),
  ('BA', 'Guajeru', '2911659'),
  ('BA', 'Guanambi', '2911709'),
  ('BA', 'Guaratinga', '2911808'),
  ('BA', 'Heliópolis', '2911857'),
  ('BA', 'Iaçu', '2911907'),
  ('BA', 'Ibiassucê', '2912004'),
  ('BA', 'Ibicaraí', '2912103'),
  ('BA', 'Ibicoara', '2912202'),
  ('BA', 'Ibicuí', '2912301'),
  ('BA', 'Ibipeba', '2912400'),
  ('BA', 'Ibipitanga', '2912509'),
  ('BA', 'Ibiquera', '2912608'),
  ('BA', 'Ibirapitanga', '2912707'),
  ('BA', 'Ibirapuã', '2912806'),
  ('BA', 'Ibirataia', '2912905'),
  ('BA', 'Ibitiara', '2913002'),
  ('BA', 'Ibititá', '2913101'),
  ('BA', 'Ibotirama', '2913200'),
  ('BA', 'Ichu', '2913309'),
  ('BA', 'Igaporã', '2913408'),
  ('BA', 'Igrapiúna', '2913457'),
  ('BA', 'Iguaí', '2913507'),
  ('BA', 'Ilhéus', '2913606'),
  ('BA', 'Inhambupe', '2913705'),
  ('BA', 'Ipecaetá', '2913804'),
  ('BA', 'Ipiaú', '2913903'),
  ('BA', 'Ipirá', '2914000'),
  ('BA', 'Ipupiara', '2914109'),
  ('BA', 'Irajuba', '2914208'),
  ('BA', 'Iramaia', '2914307'),
  ('BA', 'Iraquara', '2914406'),
  ('BA', 'Irará', '2914505'),
  ('BA', 'Irecê', '2914604'),
  ('BA', 'Itabela', '2914653'),
  ('BA', 'Itaberaba', '2914703'),
  ('BA', 'Itabuna', '2914802'),
  ('BA', 'Itacaré', '2914901'),
  ('BA', 'Itaeté', '2915007'),
  ('BA', 'Itagi', '2915106'),
  ('BA', 'Itagibá', '2915205'),
  ('BA', 'Itagimirim', '2915304'),
  ('BA', 'Itaguaçu da Bahia', '2915353'),
  ('BA', 'Itaju do Colônia', '2915403'),
  ('BA', 'Itajuípe', '2915502'),
  ('BA', 'Itamaraju', '2915601'),
  ('BA', 'Itamari', '2915700'),
  ('BA', 'Itambé', '2915809'),
  ('BA', 'Itanagra', '2915908'),
  ('BA', 'Itanhém', '2916005'),
  ('BA', 'Itaparica', '2916104'),
  ('BA', 'Itapé', '2916203'),
  ('BA', 'Itapebi', '2916302'),
  ('BA', 'Itapetinga', '2916401'),
  ('BA', 'Itapicuru', '2916500'),
  ('BA', 'Itapitanga', '2916609'),
  ('BA', 'Itaquara', '2916708'),
  ('BA', 'Itarantim', '2916807'),
  ('BA', 'Itatim', '2916856'),
  ('BA', 'Itiruçu', '2916906'),
  ('BA', 'Itiúba', '2917003'),
  ('BA', 'Itororó', '2917102'),
  ('BA', 'Ituaçu', '2917201'),
  ('BA', 'Ituberá', '2917300'),
  ('BA', 'Iuiú', '2917334'),
  ('BA', 'Jaborandi', '2917359'),
  ('BA', 'Jacaraci', '2917409'),
  ('BA', 'Jacobina', '2917508'),
  ('BA', 'Jaguaquara', '2917607'),
  ('BA', 'Jaguarari', '2917706'),
  ('BA', 'Jaguaripe', '2917805'),
  ('BA', 'Jandaíra', '2917904'),
  ('BA', 'Jequié', '2918001'),
  ('BA', 'Jeremoabo', '2918100'),
  ('BA', 'Jiquiriçá', '2918209'),
  ('BA', 'Jitaúna', '2918308'),
  ('BA', 'João dourado', '2918357'),
  ('BA', 'Juazeiro', '2918407'),
  ('BA', 'Jucuruçu', '2918456'),
  ('BA', 'Jussara', '2918506'),
  ('BA', 'Jussari', '2918555'),
  ('BA', 'Jussiape', '2918605'),
  ('BA', 'Lafaiete Coutinho', '2918704'),
  ('BA', 'Lagoa Real', '2918753'),
  ('BA', 'Laje', '2918803'),
  ('BA', 'Lajedão', '2918902'),
  ('BA', 'Lajedinho', '2919009'),
  ('BA', 'Lajedo do Tabocal', '2919058'),
  ('BA', 'Lamarão', '2919108'),
  ('BA', 'Lapão', '2919157'),
  ('BA', 'Lauro de Freitas', '2919207'),
  ('BA', 'Lençóis', '2919306'),
  ('BA', 'Licínio de Almeida', '2919405'),
  ('BA', 'Livramento de Nossa Senhora', '2919504'),
  ('BA', 'Luís Eduardo Magalhães', '2919553'),
  ('BA', 'Macajuba', '2919603'),
  ('BA', 'Macarani', '2919702'),
  ('BA', 'Macaúbas', '2919801'),
  ('BA', 'Macururé', '2919900'),
  ('BA', 'Madre de deus', '2919926'),
  ('BA', 'Maetinga', '2919959'),
  ('BA', 'Maiquinique', '2920007'),
  ('BA', 'Mairi', '2920106'),
  ('BA', 'Malhada', '2920205'),
  ('BA', 'Malhada de Pedras', '2920304'),
  ('BA', 'Manoel Vitorino', '2920403'),
  ('BA', 'Mansidão', '2920452'),
  ('BA', 'Maracás', '2920502'),
  ('BA', 'Maragogipe', '2920601'),
  ('BA', 'Maraú', '2920700'),
  ('BA', 'Marcionílio Souza', '2920809'),
  ('BA', 'Mascote', '2920908'),
  ('BA', 'Mata de São João', '2921005'),
  ('BA', 'Matina', '2921054'),
  ('BA', 'Medeiros Neto', '2921104'),
  ('BA', 'Miguel Calmon', '2921203'),
  ('BA', 'Milagres', '2921302'),
  ('BA', 'Mirangaba', '2921401'),
  ('BA', 'Mirante', '2921450'),
  ('BA', 'Monte Santo', '2921500'),
  ('BA', 'Morpará', '2921609'),
  ('BA', 'Morro do Chapéu', '2921708'),
  ('BA', 'Mortugaba', '2921807'),
  ('BA', 'Mucugê', '2921906'),
  ('BA', 'Mucuri', '2922003'),
  ('BA', 'Mulungu do Morro', '2922052'),
  ('BA', 'Mundo Novo', '2922102'),
  ('BA', 'Muniz Ferreira', '2922201'),
  ('BA', 'Muquém de São Francisco', '2922250'),
  ('BA', 'Muritiba', '2922300'),
  ('BA', 'Mutuípe', '2922409'),
  ('BA', 'Nazaré', '2922508'),
  ('BA', 'Nilo Peçanha', '2922607'),
  ('BA', 'Nordestina', '2922656'),
  ('BA', 'Nova Canaã', '2922706'),
  ('BA', 'Nova Fátima', '2922730'),
  ('BA', 'Nova Ibiá', '2922755'),
  ('BA', 'Nova Itarana', '2922805'),
  ('BA', 'Nova Redenção', '2922854'),
  ('BA', 'Nova Soure', '2922904'),
  ('BA', 'Nova Viçosa', '2923001'),
  ('BA', 'Novo Horizonte', '2923035'),
  ('BA', 'Novo Triunfo', '2923050'),
  ('BA', 'Olindina', '2923100'),
  ('BA', 'Oliveira dos Brejinhos', '2923209'),
  ('BA', 'Ouriçangas', '2923308'),
  ('BA', 'Ourolândia', '2923357'),
  ('BA', 'Palmas de Monte Alto', '2923407'),
  ('BA', 'Palmeiras', '2923506'),
  ('BA', 'Paramirim', '2923605'),
  ('BA', 'Paratinga', '2923704'),
  ('BA', 'Paripiranga', '2923803'),
  ('BA', 'Pau Brasil', '2923902'),
  ('BA', 'Paulo Afonso', '2924009'),
  ('BA', 'Pé de Serra', '2924058'),
  ('BA', 'Pedrão', '2924108'),
  ('BA', 'Pedro Alexandre', '2924207'),
  ('BA', 'Piatã', '2924306'),
  ('BA', 'Pilão Arcado', '2924405'),
  ('BA', 'Pindaí', '2924504'),
  ('BA', 'Pindobaçu', '2924603'),
  ('BA', 'Pintadas', '2924652'),
  ('BA', 'Piraí do Norte', '2924678'),
  ('BA', 'Piripá', '2924702'),
  ('BA', 'Piritiba', '2924801'),
  ('BA', 'Planaltino', '2924900'),
  ('BA', 'Planalto', '2925006'),
  ('BA', 'Poções', '2925105'),
  ('BA', 'Pojuca', '2925204'),
  ('BA', 'Ponto Novo', '2925253'),
  ('BA', 'Porto Seguro', '2925303'),
  ('BA', 'Potiraguá', '2925402'),
  ('BA', 'Prado', '2925501'),
  ('BA', 'Presidente Dutra', '2925600'),
  ('BA', 'Presidente Jânio Quadros', '2925709'),
  ('BA', 'Presidente Tancredo Neves', '2925758'),
  ('BA', 'Queimadas', '2925808'),
  ('BA', 'Quijingue', '2925907'),
  ('BA', 'Quixabeira', '2925931'),
  ('BA', 'Rafael Jambeiro', '2925956'),
  ('BA', 'Remanso', '2926004'),
  ('BA', 'Retirolândia', '2926103'),
  ('BA', 'Riachão das Neves', '2926202'),
  ('BA', 'Riachão do Jacuípe', '2926301'),
  ('BA', 'Riacho de Santana', '2926400'),
  ('BA', 'Ribeira do Amparo', '2926509'),
  ('BA', 'Ribeira do Pombal', '2926608'),
  ('BA', 'Ribeirão do Largo', '2926657'),
  ('BA', 'Rio de Contas', '2926707'),
  ('BA', 'Rio do Antônio', '2926806'),
  ('BA', 'Rio do Pires', '2926905'),
  ('BA', 'Rio Real', '2927002'),
  ('BA', 'Rodelas', '2927101'),
  ('BA', 'Ruy Barbosa', '2927200'),
  ('BA', 'Salinas da Margarida', '2927309'),
  ('BA', 'Salvador', '2927408'),
  ('BA', 'Santa Bárbara', '2927507'),
  ('BA', 'Santa Brígida', '2927606'),
  ('BA', 'Santa Cruz Cabrália', '2927705'),
  ('BA', 'Santa Cruz da Vitória', '2927804'),
  ('BA', 'Santa Inês', '2927903'),
  ('BA', 'Santaluz', '2928000'),
  ('BA', 'Santa Luzia', '2928059'),
  ('BA', 'Santa Maria da Vitória', '2928109'),
  ('BA', 'Santana', '2928208'),
  ('BA', 'Santanópolis', '2928307'),
  ('BA', 'Santa Rita de Cássia', '2928406'),
  ('BA', 'Santa Teresinha', '2928505'),
  ('BA', 'Santo Amaro', '2928604'),
  ('BA', 'Santo Antônio de Jesus', '2928703'),
  ('BA', 'Santo Estêvão', '2928802'),
  ('BA', 'São desidério', '2928901'),
  ('BA', 'São domingos', '2928950'),
  ('BA', 'São Félix', '2929008'),
  ('BA', 'São Félix do Coribe', '2929057'),
  ('BA', 'São Felipe', '2929107'),
  ('BA', 'São Francisco do Conde', '2929206'),
  ('BA', 'São Gabriel', '2929255'),
  ('BA', 'São Gonçalo dos Campos', '2929305'),
  ('BA', 'São José da Vitória', '2929354'),
  ('BA', 'São José do Jacuípe', '2929370'),
  ('BA', 'São Miguel das Matas', '2929404'),
  ('BA', 'São Sebastião do Passé', '2929503'),
  ('BA', 'Sapeaçu', '2929602'),
  ('BA', 'Sátiro Dias', '2929701'),
  ('BA', 'Saubara', '2929750'),
  ('BA', 'Saúde', '2929800'),
  ('BA', 'Seabra', '2929909'),
  ('BA', 'Sebastião Laranjeiras', '2930006'),
  ('BA', 'Senhor do Bonfim', '2930105'),
  ('BA', 'Serra do Ramalho', '2930154'),
  ('BA', 'Sento Sé', '2930204'),
  ('BA', 'Serra dourada', '2930303'),
  ('BA', 'Serra Preta', '2930402'),
  ('BA', 'Serrinha', '2930501'),
  ('BA', 'Serrolândia', '2930600'),
  ('BA', 'Simões Filho', '2930709'),
  ('BA', 'Sítio do Mato', '2930758'),
  ('BA', 'Sítio do Quinto', '2930766'),
  ('BA', 'Sobradinho', '2930774'),
  ('BA', 'Souto Soares', '2930808'),
  ('BA', 'Tabocas do Brejo Velho', '2930907'),
  ('BA', 'Tanhaçu', '2931004'),
  ('BA', 'Tanque Novo', '2931053'),
  ('BA', 'Tanquinho', '2931103'),
  ('BA', 'Taperoá', '2931202'),
  ('BA', 'Tapiramutá', '2931301'),
  ('BA', 'Teixeira de Freitas', '2931350'),
  ('BA', 'Teodoro Sampaio', '2931400'),
  ('BA', 'Teofilândia', '2931509'),
  ('BA', 'Teolândia', '2931608'),
  ('BA', 'Terra Nova', '2931707'),
  ('BA', 'Tremedal', '2931806'),
  ('BA', 'Tucano', '2931905'),
  ('BA', 'Uauá', '2932002'),
  ('BA', 'Ubaíra', '2932101'),
  ('BA', 'Ubaitaba', '2932200'),
  ('BA', 'Ubatã', '2932309'),
  ('BA', 'Uibaí', '2932408'),
  ('BA', 'Umburanas', '2932457'),
  ('BA', 'Una', '2932507'),
  ('BA', 'Urandi', '2932606'),
  ('BA', 'Uruçuca', '2932705'),
  ('BA', 'Utinga', '2932804'),
  ('BA', 'Valença', '2932903'),
  ('BA', 'Valente', '2933000'),
  ('BA', 'Várzea da Roça', '2933059'),
  ('BA', 'Várzea do Poço', '2933109'),
  ('BA', 'Várzea Nova', '2933158'),
  ('BA', 'Varzedo', '2933174'),
  ('BA', 'Vera Cruz', '2933208'),
  ('BA', 'Vereda', '2933257'),
  ('BA', 'Vitória da Conquista', '2933307'),
  ('BA', 'Wagner', '2933406'),
  ('BA', 'Wanderley', '2933455'),
  ('BA', 'Wenceslau Guimarães', '2933505'),
  ('BA', 'Xique-Xique', '2933604'),
  ('MG', 'Abadia dos dourados', '3100104'),
  ('MG', 'Abaeté', '3100203'),
  ('MG', 'Abre Campo', '3100302'),
  ('MG', 'Acaiaca', '3100401'),
  ('MG', 'Açucena', '3100500'),
  ('MG', 'Água Boa', '3100609'),
  ('MG', 'Água Comprida', '3100708'),
  ('MG', 'Aguanil', '3100807'),
  ('MG', 'Águas Formosas', '3100906'),
  ('MG', 'Águas Vermelhas', '3101003'),
  ('MG', 'Aimorés', '3101102'),
  ('MG', 'Aiuruoca', '3101201'),
  ('MG', 'Alagoa', '3101300'),
  ('MG', 'Albertina', '3101409'),
  ('MG', 'Além Paraíba', '3101508'),
  ('MG', 'Alfenas', '3101607'),
  ('MG', 'Alfredo Vasconcelos', '3101631'),
  ('MG', 'Almenara', '3101706'),
  ('MG', 'Alpercata', '3101805'),
  ('MG', 'Alpinópolis', '3101904'),
  ('MG', 'Alterosa', '3102001'),
  ('MG', 'Alto Caparaó', '3102050'),
  ('MG', 'Alto Rio doce', '3102100'),
  ('MG', 'Alvarenga', '3102209'),
  ('MG', 'Alvinópolis', '3102308'),
  ('MG', 'Alvorada de Minas', '3102407'),
  ('MG', 'Amparo do Serra', '3102506'),
  ('MG', 'Andradas', '3102605'),
  ('MG', 'Cachoeira de Pajeú', '3102704'),
  ('MG', 'Andrelândia', '3102803'),
  ('MG', 'Angelândia', '3102852'),
  ('MG', 'Antônio Carlos', '3102902'),
  ('MG', 'Antônio Dias', '3103009'),
  ('MG', 'Antônio Prado de Minas', '3103108'),
  ('MG', 'Araçaí', '3103207'),
  ('MG', 'Aracitaba', '3103306'),
  ('MG', 'Araçuaí', '3103405'),
  ('MG', 'Araguari', '3103504'),
  ('MG', 'Arantina', '3103603'),
  ('MG', 'Araponga', '3103702'),
  ('MG', 'Araporã', '3103751'),
  ('MG', 'Arapuá', '3103801'),
  ('MG', 'Araújos', '3103900'),
  ('MG', 'Araxá', '3104007'),
  ('MG', 'Arceburgo', '3104106'),
  ('MG', 'Arcos', '3104205'),
  ('MG', 'Areado', '3104304'),
  ('MG', 'Argirita', '3104403'),
  ('MG', 'Aricanduva', '3104452'),
  ('MG', 'Arinos', '3104502'),
  ('MG', 'Astolfo Dutra', '3104601'),
  ('MG', 'Ataléia', '3104700'),
  ('MG', 'Augusto de Lima', '3104809'),
  ('MG', 'Baependi', '3104908'),
  ('MG', 'Baldim', '3105004'),
  ('MG', 'Bambuí', '3105103'),
  ('MG', 'Bandeira', '3105202'),
  ('MG', 'Bandeira do Sul', '3105301'),
  ('MG', 'Barão de Cocais', '3105400'),
  ('MG', 'Barão de Monte Alto', '3105509'),
  ('MG', 'Barbacena', '3105608'),
  ('MG', 'Barra Longa', '3105707'),
  ('MG', 'Barroso', '3105905'),
  ('MG', 'Bela Vista de Minas', '3106002'),
  ('MG', 'Belmiro Braga', '3106101'),
  ('MG', 'Belo Horizonte', '3106200'),
  ('MG', 'Belo Oriente', '3106309'),
  ('MG', 'Belo Vale', '3106408'),
  ('MG', 'Berilo', '3106507'),
  ('MG', 'Bertópolis', '3106606'),
  ('MG', 'Berizal', '3106655'),
  ('MG', 'Betim', '3106705'),
  ('MG', 'Bias Fortes', '3106804'),
  ('MG', 'Bicas', '3106903'),
  ('MG', 'Biquinhas', '3107000'),
  ('MG', 'Boa Esperança', '3107109'),
  ('MG', 'Bocaina de Minas', '3107208'),
  ('MG', 'Bocaiúva', '3107307'),
  ('MG', 'Bom despacho', '3107406'),
  ('MG', 'Bom Jardim de Minas', '3107505'),
  ('MG', 'Bom Jesus da Penha', '3107604'),
  ('MG', 'Bom Jesus do Amparo', '3107703'),
  ('MG', 'Bom Jesus do Galho', '3107802'),
  ('MG', 'Bom Repouso', '3107901'),
  ('MG', 'Bom Sucesso', '3108008'),
  ('MG', 'Bonfim', '3108107'),
  ('MG', 'Bonfinópolis de Minas', '3108206'),
  ('MG', 'Bonito de Minas', '3108255'),
  ('MG', 'Borda da Mata', '3108305'),
  ('MG', 'Botelhos', '3108404'),
  ('MG', 'Botumirim', '3108503'),
  ('MG', 'Brasilândia de Minas', '3108552'),
  ('MG', 'Brasília de Minas', '3108602'),
  ('MG', 'Brás Pires', '3108701'),
  ('MG', 'Braúnas', '3108800'),
  ('MG', 'Brazópolis', '3108909'),
  ('MG', 'Brumadinho', '3109006'),
  ('MG', 'Bueno Brandão', '3109105'),
  ('MG', 'Buenópolis', '3109204'),
  ('MG', 'Bugre', '3109253'),
  ('MG', 'Buritis', '3109303'),
  ('MG', 'Buritizeiro', '3109402'),
  ('MG', 'Cabeceira Grande', '3109451'),
  ('MG', 'Cabo Verde', '3109501'),
  ('MG', 'Cachoeira da Prata', '3109600'),
  ('MG', 'Cachoeira de Minas', '3109709'),
  ('MG', 'Cachoeira dourada', '3109808'),
  ('MG', 'Caetanópolis', '3109907'),
  ('MG', 'Caeté', '3110004'),
  ('MG', 'Caiana', '3110103'),
  ('MG', 'Cajuri', '3110202'),
  ('MG', 'Caldas', '3110301'),
  ('MG', 'Camacho', '3110400'),
  ('MG', 'Camanducaia', '3110509'),
  ('MG', 'Cambuí', '3110608'),
  ('MG', 'Cambuquira', '3110707'),
  ('MG', 'Campanário', '3110806'),
  ('MG', 'Campanha', '3110905'),
  ('MG', 'Campestre', '3111002'),
  ('MG', 'Campina Verde', '3111101'),
  ('MG', 'Campo Azul', '3111150'),
  ('MG', 'Campo Belo', '3111200'),
  ('MG', 'Campo do Meio', '3111309'),
  ('MG', 'Campo Florido', '3111408'),
  ('MG', 'Campos Altos', '3111507'),
  ('MG', 'Campos Gerais', '3111606'),
  ('MG', 'Canaã', '3111705'),
  ('MG', 'Canápolis', '3111804'),
  ('MG', 'Cana Verde', '3111903'),
  ('MG', 'Candeias', '3112000'),
  ('MG', 'Cantagalo', '3112059'),
  ('MG', 'Caparaó', '3112109'),
  ('MG', 'Capela Nova', '3112208'),
  ('MG', 'Capelinha', '3112307'),
  ('MG', 'Capetinga', '3112406'),
  ('MG', 'Capim Branco', '3112505'),
  ('MG', 'Capinópolis', '3112604'),
  ('MG', 'Capitão Andrade', '3112653'),
  ('MG', 'Capitão Enéas', '3112703'),
  ('MG', 'Capitólio', '3112802'),
  ('MG', 'Caputira', '3112901'),
  ('MG', 'Caraí', '3113008'),
  ('MG', 'Caranaíba', '3113107'),
  ('MG', 'Carandaí', '3113206'),
  ('MG', 'Carangola', '3113305'),
  ('MG', 'Caratinga', '3113404'),
  ('MG', 'Carbonita', '3113503'),
  ('MG', 'Careaçu', '3113602'),
  ('MG', 'Carlos Chagas', '3113701'),
  ('MG', 'Carmésia', '3113800'),
  ('MG', 'Carmo da Cachoeira', '3113909'),
  ('MG', 'Carmo da Mata', '3114006'),
  ('MG', 'Carmo de Minas', '3114105'),
  ('MG', 'Carmo do Cajuru', '3114204'),
  ('MG', 'Carmo do Paranaíba', '3114303'),
  ('MG', 'Carmo do Rio Claro', '3114402'),
  ('MG', 'Carmópolis de Minas', '3114501'),
  ('MG', 'Carneirinho', '3114550'),
  ('MG', 'Carrancas', '3114600'),
  ('MG', 'Carvalhópolis', '3114709'),
  ('MG', 'Carvalhos', '3114808'),
  ('MG', 'Casa Grande', '3114907'),
  ('MG', 'Cascalho Rico', '3115003'),
  ('MG', 'Cássia', '3115102'),
  ('MG', 'Conceição da Barra de Minas', '3115201'),
  ('MG', 'Cataguases', '3115300'),
  ('MG', 'Catas Altas', '3115359'),
  ('MG', 'Catas Altas da Noruega', '3115409'),
  ('MG', 'Catuji', '3115458'),
  ('MG', 'Catuti', '3115474'),
  ('MG', 'Caxambu', '3115508'),
  ('MG', 'Cedro do Abaeté', '3115607'),
  ('MG', 'Central de Minas', '3115706'),
  ('MG', 'Centralina', '3115805'),
  ('MG', 'Chácara', '3115904'),
  ('MG', 'Chalé', '3116001'),
  ('MG', 'Chapada do Norte', '3116100'),
  ('MG', 'Chapada Gaúcha', '3116159'),
  ('MG', 'Chiador', '3116209'),
  ('MG', 'Cipotânea', '3116308'),
  ('MG', 'Claraval', '3116407'),
  ('MG', 'Claro dos Poções', '3116506'),
  ('MG', 'Cláudio', '3116605'),
  ('MG', 'Coimbra', '3116704'),
  ('MG', 'Coluna', '3116803'),
  ('MG', 'Comendador Gomes', '3116902'),
  ('MG', 'Comercinho', '3117009'),
  ('MG', 'Conceição da Aparecida', '3117108'),
  ('MG', 'Conceição das Pedras', '3117207'),
  ('MG', 'Conceição das Alagoas', '3117306'),
  ('MG', 'Conceição de Ipanema', '3117405'),
  ('MG', 'Conceição do Mato dentro', '3117504'),
  ('MG', 'Conceição do Pará', '3117603'),
  ('MG', 'Conceição do Rio Verde', '3117702'),
  ('MG', 'Conceição dos Ouros', '3117801'),
  ('MG', 'Cônego Marinho', '3117836'),
  ('MG', 'Confins', '3117876'),
  ('MG', 'Congonhal', '3117900'),
  ('MG', 'Congonhas', '3118007'),
  ('MG', 'Congonhas do Norte', '3118106'),
  ('MG', 'Conquista', '3118205'),
  ('MG', 'Conselheiro Lafaiete', '3118304'),
  ('MG', 'Conselheiro Pena', '3118403'),
  ('MG', 'Consolação', '3118502'),
  ('MG', 'Contagem', '3118601'),
  ('MG', 'Coqueiral', '3118700'),
  ('MG', 'Coração de Jesus', '3118809'),
  ('MG', 'Cordisburgo', '3118908'),
  ('MG', 'Cordislândia', '3119005'),
  ('MG', 'Corinto', '3119104'),
  ('MG', 'Coroaci', '3119203'),
  ('MG', 'Coromandel', '3119302'),
  ('MG', 'Coronel Fabriciano', '3119401'),
  ('MG', 'Coronel Murta', '3119500'),
  ('MG', 'Coronel Pacheco', '3119609'),
  ('MG', 'Coronel Xavier Chaves', '3119708'),
  ('MG', 'Córrego danta', '3119807'),
  ('MG', 'Córrego do Bom Jesus', '3119906'),
  ('MG', 'Córrego Fundo', '3119955'),
  ('MG', 'Córrego Novo', '3120003'),
  ('MG', 'Couto de Magalhães de Minas', '3120102'),
  ('MG', 'Crisólita', '3120151'),
  ('MG', 'Cristais', '3120201'),
  ('MG', 'Cristália', '3120300'),
  ('MG', 'Cristiano Otoni', '3120409'),
  ('MG', 'Cristina', '3120508'),
  ('MG', 'Crucilândia', '3120607'),
  ('MG', 'Cruzeiro da Fortaleza', '3120706'),
  ('MG', 'Cruzília', '3120805'),
  ('MG', 'Cuparaque', '3120839'),
  ('MG', 'Curral de dentro', '3120870'),
  ('MG', 'Curvelo', '3120904'),
  ('MG', 'datas', '3121001'),
  ('MG', 'delfim Moreira', '3121100'),
  ('MG', 'delfinópolis', '3121209'),
  ('MG', 'delta', '3121258'),
  ('MG', 'descoberto', '3121308'),
  ('MG', 'desterro de Entre Rios', '3121407'),
  ('MG', 'desterro do Melo', '3121506'),
  ('MG', 'Diamantina', '3121605'),
  ('MG', 'Diogo de Vasconcelos', '3121704'),
  ('MG', 'Dionísio', '3121803'),
  ('MG', 'Divinésia', '3121902'),
  ('MG', 'Divino', '3122009'),
  ('MG', 'Divino das Laranjeiras', '3122108'),
  ('MG', 'Divinolândia de Minas', '3122207'),
  ('MG', 'Divinópolis', '3122306'),
  ('MG', 'Divisa Alegre', '3122355'),
  ('MG', 'Divisa Nova', '3122405'),
  ('MG', 'Divisópolis', '3122454'),
  ('MG', 'dom Bosco', '3122470'),
  ('MG', 'dom Cavati', '3122504'),
  ('MG', 'dom Joaquim', '3122603'),
  ('MG', 'dom Silvério', '3122702'),
  ('MG', 'dom Viçoso', '3122801'),
  ('MG', 'dona Eusébia', '3122900'),
  ('MG', 'dores de Campos', '3123007'),
  ('MG', 'dores de Guanhães', '3123106'),
  ('MG', 'dores do Indaiá', '3123205'),
  ('MG', 'dores do Turvo', '3123304'),
  ('MG', 'doresópolis', '3123403'),
  ('MG', 'douradoquara', '3123502'),
  ('MG', 'Durandé', '3123528'),
  ('MG', 'Elói Mendes', '3123601'),
  ('MG', 'Engenheiro Caldas', '3123700'),
  ('MG', 'Engenheiro Navarro', '3123809'),
  ('MG', 'Entre Folhas', '3123858'),
  ('MG', 'Entre Rios de Minas', '3123908'),
  ('MG', 'Ervália', '3124005'),
  ('MG', 'Esmeraldas', '3124104'),
  ('MG', 'Espera Feliz', '3124203'),
  ('MG', 'Espinosa', '3124302'),
  ('MG', 'Espírito Santo do dourado', '3124401'),
  ('MG', 'Estiva', '3124500'),
  ('MG', 'Estrela dalva', '3124609'),
  ('MG', 'Estrela do Indaiá', '3124708'),
  ('MG', 'Estrela do Sul', '3124807'),
  ('MG', 'Eugenópolis', '3124906'),
  ('MG', 'Ewbank da Câmara', '3125002'),
  ('MG', 'Extrema', '3125101'),
  ('MG', 'Fama', '3125200'),
  ('MG', 'Faria Lemos', '3125309'),
  ('MG', 'Felício dos Santos', '3125408'),
  ('MG', 'São Gonçalo do Rio Preto', '3125507'),
  ('MG', 'Felisburgo', '3125606'),
  ('MG', 'Felixlândia', '3125705'),
  ('MG', 'Fernandes Tourinho', '3125804'),
  ('MG', 'Ferros', '3125903'),
  ('MG', 'Fervedouro', '3125952'),
  ('MG', 'Florestal', '3126000'),
  ('MG', 'Formiga', '3126109'),
  ('MG', 'Formoso', '3126208'),
  ('MG', 'Fortaleza de Minas', '3126307'),
  ('MG', 'Fortuna de Minas', '3126406'),
  ('MG', 'Francisco Badaró', '3126505'),
  ('MG', 'Francisco Dumont', '3126604'),
  ('MG', 'Francisco Sá', '3126703'),
  ('MG', 'Franciscópolis', '3126752'),
  ('MG', 'Frei Gaspar', '3126802'),
  ('MG', 'Frei Inocêncio', '3126901'),
  ('MG', 'Frei Lagonegro', '3126950'),
  ('MG', 'Fronteira', '3127008'),
  ('MG', 'Fronteira dos Vales', '3127057'),
  ('MG', 'Fruta de Leite', '3127073'),
  ('MG', 'Frutal', '3127107'),
  ('MG', 'Funilândia', '3127206'),
  ('MG', 'Galiléia', '3127305'),
  ('MG', 'Gameleiras', '3127339'),
  ('MG', 'Glaucilândia', '3127354'),
  ('MG', 'Goiabeira', '3127370'),
  ('MG', 'Goianá', '3127388'),
  ('MG', 'Gonçalves', '3127404'),
  ('MG', 'Gonzaga', '3127503'),
  ('MG', 'Gouveia', '3127602'),
  ('MG', 'Governador Valadares', '3127701'),
  ('MG', 'Grão Mogol', '3127800'),
  ('MG', 'Grupiara', '3127909'),
  ('MG', 'Guanhães', '3128006'),
  ('MG', 'Guapé', '3128105'),
  ('MG', 'Guaraciaba', '3128204'),
  ('MG', 'Guaraciama', '3128253'),
  ('MG', 'Guaranésia', '3128303'),
  ('MG', 'Guarani', '3128402'),
  ('MG', 'Guarará', '3128501'),
  ('MG', 'Guarda-Mor', '3128600'),
  ('MG', 'Guaxupé', '3128709'),
  ('MG', 'Guidoval', '3128808'),
  ('MG', 'Guimarânia', '3128907'),
  ('MG', 'Guiricema', '3129004'),
  ('MG', 'Gurinhatã', '3129103'),
  ('MG', 'Heliodora', '3129202'),
  ('MG', 'Iapu', '3129301'),
  ('MG', 'Ibertioga', '3129400'),
  ('MG', 'Ibiá', '3129509'),
  ('MG', 'Ibiaí', '3129608'),
  ('MG', 'Ibiracatu', '3129657'),
  ('MG', 'Ibiraci', '3129707'),
  ('MG', 'Ibirité', '3129806'),
  ('MG', 'Ibitiúra de Minas', '3129905'),
  ('MG', 'Ibituruna', '3130002'),
  ('MG', 'Icaraí de Minas', '3130051'),
  ('MG', 'Igarapé', '3130101'),
  ('MG', 'Igaratinga', '3130200'),
  ('MG', 'Iguatama', '3130309'),
  ('MG', 'Ijaci', '3130408'),
  ('MG', 'Ilicínea', '3130507'),
  ('MG', 'Imbé de Minas', '3130556'),
  ('MG', 'Inconfidentes', '3130606'),
  ('MG', 'Indaiabira', '3130655'),
  ('MG', 'Indianópolis', '3130705'),
  ('MG', 'Ingaí', '3130804'),
  ('MG', 'Inhapim', '3130903'),
  ('MG', 'Inhaúma', '3131000'),
  ('MG', 'Inimutaba', '3131109'),
  ('MG', 'Ipaba', '3131158'),
  ('MG', 'Ipanema', '3131208'),
  ('MG', 'Ipatinga', '3131307'),
  ('MG', 'Ipiaçu', '3131406'),
  ('MG', 'Ipuiúna', '3131505'),
  ('MG', 'Iraí de Minas', '3131604'),
  ('MG', 'Itabira', '3131703'),
  ('MG', 'Itabirinha', '3131802'),
  ('MG', 'Itabirito', '3131901'),
  ('MG', 'Itacambira', '3132008'),
  ('MG', 'Itacarambi', '3132107'),
  ('MG', 'Itaguara', '3132206'),
  ('MG', 'Itaipé', '3132305'),
  ('MG', 'Itajubá', '3132404'),
  ('MG', 'Itamarandiba', '3132503'),
  ('MG', 'Itamarati de Minas', '3132602'),
  ('MG', 'Itambacuri', '3132701'),
  ('MG', 'Itambé do Mato dentro', '3132800'),
  ('MG', 'Itamogi', '3132909'),
  ('MG', 'Itamonte', '3133006'),
  ('MG', 'Itanhandu', '3133105'),
  ('MG', 'Itanhomi', '3133204'),
  ('MG', 'Itaobim', '3133303'),
  ('MG', 'Itapagipe', '3133402'),
  ('MG', 'Itapecerica', '3133501'),
  ('MG', 'Itapeva', '3133600'),
  ('MG', 'Itatiaiuçu', '3133709'),
  ('MG', 'Itaú de Minas', '3133758'),
  ('MG', 'Itaúna', '3133808'),
  ('MG', 'Itaverava', '3133907'),
  ('MG', 'Itinga', '3134004'),
  ('MG', 'Itueta', '3134103'),
  ('MG', 'Ituiutaba', '3134202'),
  ('MG', 'Itumirim', '3134301'),
  ('MG', 'Iturama', '3134400'),
  ('MG', 'Itutinga', '3134509'),
  ('MG', 'Jaboticatubas', '3134608'),
  ('MG', 'Jacinto', '3134707'),
  ('MG', 'Jacuí', '3134806'),
  ('MG', 'Jacutinga', '3134905'),
  ('MG', 'Jaguaraçu', '3135001'),
  ('MG', 'Jaíba', '3135050'),
  ('MG', 'Jampruca', '3135076'),
  ('MG', 'Janaúba', '3135100'),
  ('MG', 'Januária', '3135209'),
  ('MG', 'Japaraíba', '3135308'),
  ('MG', 'Japonvar', '3135357'),
  ('MG', 'Jeceaba', '3135407'),
  ('MG', 'Jenipapo de Minas', '3135456'),
  ('MG', 'Jequeri', '3135506'),
  ('MG', 'Jequitaí', '3135605'),
  ('MG', 'Jequitibá', '3135704'),
  ('MG', 'Jequitinhonha', '3135803'),
  ('MG', 'Jesuânia', '3135902'),
  ('MG', 'Joaíma', '3136009'),
  ('MG', 'Joanésia', '3136108'),
  ('MG', 'João Monlevade', '3136207'),
  ('MG', 'João Pinheiro', '3136306'),
  ('MG', 'Joaquim Felício', '3136405'),
  ('MG', 'Jordânia', '3136504'),
  ('MG', 'José Gonçalves de Minas', '3136520'),
  ('MG', 'José Raydan', '3136553'),
  ('MG', 'Josenópolis', '3136579'),
  ('MG', 'Nova União', '3136603'),
  ('MG', 'Juatuba', '3136652'),
  ('MG', 'Juiz de Fora', '3136702'),
  ('MG', 'Juramento', '3136801'),
  ('MG', 'Juruaia', '3136900'),
  ('MG', 'Juvenília', '3136959'),
  ('MG', 'Ladainha', '3137007'),
  ('MG', 'Lagamar', '3137106'),
  ('MG', 'Lagoa da Prata', '3137205'),
  ('MG', 'Lagoa dos Patos', '3137304'),
  ('MG', 'Lagoa dourada', '3137403'),
  ('MG', 'Lagoa Formosa', '3137502'),
  ('MG', 'Lagoa Grande', '3137536'),
  ('MG', 'Lagoa Santa', '3137601'),
  ('MG', 'Lajinha', '3137700'),
  ('MG', 'Lambari', '3137809'),
  ('MG', 'Lamim', '3137908'),
  ('MG', 'Laranjal', '3138005'),
  ('MG', 'Lassance', '3138104'),
  ('MG', 'Lavras', '3138203'),
  ('MG', 'Leandro Ferreira', '3138302'),
  ('MG', 'Leme do Prado', '3138351'),
  ('MG', 'Leopoldina', '3138401'),
  ('MG', 'Liberdade', '3138500'),
  ('MG', 'Lima Duarte', '3138609'),
  ('MG', 'Limeira do Oeste', '3138625'),
  ('MG', 'Lontra', '3138658'),
  ('MG', 'Luisburgo', '3138674'),
  ('MG', 'Luislândia', '3138682'),
  ('MG', 'Luminárias', '3138708'),
  ('MG', 'Luz', '3138807'),
  ('MG', 'Machacalis', '3138906'),
  ('MG', 'Machado', '3139003'),
  ('MG', 'Madre de deus de Minas', '3139102'),
  ('MG', 'Malacacheta', '3139201'),
  ('MG', 'Mamonas', '3139250'),
  ('MG', 'Manga', '3139300'),
  ('MG', 'Manhuaçu', '3139409'),
  ('MG', 'Manhumirim', '3139508'),
  ('MG', 'Mantena', '3139607'),
  ('MG', 'Maravilhas', '3139706'),
  ('MG', 'Mar de Espanha', '3139805'),
  ('MG', 'Maria da Fé', '3139904'),
  ('MG', 'Mariana', '3140001'),
  ('MG', 'Marilac', '3140100'),
  ('MG', 'Mário Campos', '3140159'),
  ('MG', 'Maripá de Minas', '3140209'),
  ('MG', 'Marliéria', '3140308'),
  ('MG', 'Marmelópolis', '3140407'),
  ('MG', 'Martinho Campos', '3140506'),
  ('MG', 'Martins Soares', '3140530'),
  ('MG', 'Mata Verde', '3140555'),
  ('MG', 'Materlândia', '3140605'),
  ('MG', 'Mateus Leme', '3140704'),
  ('MG', 'Matias Barbosa', '3140803'),
  ('MG', 'Matias Cardoso', '3140852'),
  ('MG', 'Matipó', '3140902'),
  ('MG', 'Mato Verde', '3141009'),
  ('MG', 'Matozinhos', '3141108'),
  ('MG', 'Matutina', '3141207'),
  ('MG', 'Medeiros', '3141306'),
  ('MG', 'Medina', '3141405'),
  ('MG', 'Mendes Pimentel', '3141504'),
  ('MG', 'Mercês', '3141603'),
  ('MG', 'Mesquita', '3141702'),
  ('MG', 'Minas Novas', '3141801'),
  ('MG', 'Minduri', '3141900'),
  ('MG', 'Mirabela', '3142007'),
  ('MG', 'Miradouro', '3142106'),
  ('MG', 'Miraí', '3142205'),
  ('MG', 'Miravânia', '3142254'),
  ('MG', 'Moeda', '3142304'),
  ('MG', 'Moema', '3142403'),
  ('MG', 'Monjolos', '3142502'),
  ('MG', 'Monsenhor Paulo', '3142601'),
  ('MG', 'Montalvânia', '3142700'),
  ('MG', 'Monte Alegre de Minas', '3142809'),
  ('MG', 'Monte Azul', '3142908'),
  ('MG', 'Monte Belo', '3143005'),
  ('MG', 'Monte Carmelo', '3143104'),
  ('MG', 'Monte Formoso', '3143153'),
  ('MG', 'Monte Santo de Minas', '3143203'),
  ('MG', 'Montes Claros', '3143302'),
  ('MG', 'Monte Sião', '3143401'),
  ('MG', 'Montezuma', '3143450'),
  ('MG', 'Morada Nova de Minas', '3143500'),
  ('MG', 'Morro da Garça', '3143609'),
  ('MG', 'Morro do Pilar', '3143708'),
  ('MG', 'Munhoz', '3143807'),
  ('MG', 'Muriaé', '3143906'),
  ('MG', 'Mutum', '3144003'),
  ('MG', 'Muzambinho', '3144102'),
  ('MG', 'Nacip Raydan', '3144201'),
  ('MG', 'Nanuque', '3144300'),
  ('MG', 'Naque', '3144359'),
  ('MG', 'Natalândia', '3144375'),
  ('MG', 'Natércia', '3144409'),
  ('MG', 'Nazareno', '3144508'),
  ('MG', 'Nepomuceno', '3144607'),
  ('MG', 'Ninheira', '3144656'),
  ('MG', 'Nova Belém', '3144672'),
  ('MG', 'Nova Era', '3144706'),
  ('MG', 'Nova Lima', '3144805'),
  ('MG', 'Nova Módica', '3144904'),
  ('MG', 'Nova Ponte', '3145000'),
  ('MG', 'Nova Porteirinha', '3145059'),
  ('MG', 'Nova Resende', '3145109'),
  ('MG', 'Nova Serrana', '3145208'),
  ('MG', 'Novo Cruzeiro', '3145307'),
  ('MG', 'Novo Oriente de Minas', '3145356'),
  ('MG', 'Novorizonte', '3145372'),
  ('MG', 'Olaria', '3145406'),
  ('MG', 'Olhos-D''água', '3145455'),
  ('MG', 'Olímpio Noronha', '3145505'),
  ('MG', 'Oliveira', '3145604'),
  ('MG', 'Oliveira Fortes', '3145703'),
  ('MG', 'Onça de Pitangui', '3145802'),
  ('MG', 'Oratórios', '3145851'),
  ('MG', 'Orizânia', '3145877'),
  ('MG', 'Ouro Branco', '3145901'),
  ('MG', 'Ouro Fino', '3146008'),
  ('MG', 'Ouro Preto', '3146107'),
  ('MG', 'Ouro Verde de Minas', '3146206'),
  ('MG', 'Padre Carvalho', '3146255'),
  ('MG', 'Padre Paraíso', '3146305'),
  ('MG', 'Paineiras', '3146404'),
  ('MG', 'Pains', '3146503'),
  ('MG', 'Pai Pedro', '3146552'),
  ('MG', 'Paiva', '3146602'),
  ('MG', 'Palma', '3146701'),
  ('MG', 'Palmópolis', '3146750'),
  ('MG', 'Papagaios', '3146909'),
  ('MG', 'Paracatu', '3147006'),
  ('MG', 'Pará de Minas', '3147105'),
  ('MG', 'Paraguaçu', '3147204'),
  ('MG', 'Paraisópolis', '3147303'),
  ('MG', 'Paraopeba', '3147402'),
  ('MG', 'Passabém', '3147501'),
  ('MG', 'Passa Quatro', '3147600'),
  ('MG', 'Passa Tempo', '3147709'),
  ('MG', 'Passa-Vinte', '3147808'),
  ('MG', 'Passos', '3147907'),
  ('MG', 'Patis', '3147956'),
  ('MG', 'Patos de Minas', '3148004'),
  ('MG', 'Patrocínio', '3148103'),
  ('MG', 'Patrocínio do Muriaé', '3148202'),
  ('MG', 'Paula Cândido', '3148301'),
  ('MG', 'Paulistas', '3148400'),
  ('MG', 'Pavão', '3148509'),
  ('MG', 'Peçanha', '3148608'),
  ('MG', 'Pedra Azul', '3148707'),
  ('MG', 'Pedra Bonita', '3148756'),
  ('MG', 'Pedra do Anta', '3148806'),
  ('MG', 'Pedra do Indaiá', '3148905'),
  ('MG', 'Pedra dourada', '3149002'),
  ('MG', 'Pedralva', '3149101'),
  ('MG', 'Pedras de Maria da Cruz', '3149150'),
  ('MG', 'Pedrinópolis', '3149200'),
  ('MG', 'Pedro Leopoldo', '3149309'),
  ('MG', 'Pedro Teixeira', '3149408'),
  ('MG', 'Pequeri', '3149507'),
  ('MG', 'Pequi', '3149606'),
  ('MG', 'Perdigão', '3149705'),
  ('MG', 'Perdizes', '3149804'),
  ('MG', 'Perdões', '3149903'),
  ('MG', 'Periquito', '3149952'),
  ('MG', 'Pescador', '3150000'),
  ('MG', 'Piau', '3150109'),
  ('MG', 'Piedade de Caratinga', '3150158'),
  ('MG', 'Piedade de Ponte Nova', '3150208'),
  ('MG', 'Piedade do Rio Grande', '3150307'),
  ('MG', 'Piedade dos Gerais', '3150406'),
  ('MG', 'Pimenta', '3150505'),
  ('MG', 'Pingo-D''água', '3150539'),
  ('MG', 'Pintópolis', '3150570'),
  ('MG', 'Piracema', '3150604'),
  ('MG', 'Pirajuba', '3150703'),
  ('MG', 'Piranga', '3150802'),
  ('MG', 'Piranguçu', '3150901'),
  ('MG', 'Piranguinho', '3151008'),
  ('MG', 'Pirapetinga', '3151107'),
  ('MG', 'Pirapora', '3151206'),
  ('MG', 'Piraúba', '3151305'),
  ('MG', 'Pitangui', '3151404'),
  ('MG', 'Piumhi', '3151503'),
  ('MG', 'Planura', '3151602'),
  ('MG', 'Poço Fundo', '3151701'),
  ('MG', 'Poços de Caldas', '3151800'),
  ('MG', 'Pocrane', '3151909'),
  ('MG', 'Pompéu', '3152006'),
  ('MG', 'Ponte Nova', '3152105'),
  ('MG', 'Ponto Chique', '3152131'),
  ('MG', 'Ponto dos Volantes', '3152170'),
  ('MG', 'Porteirinha', '3152204'),
  ('MG', 'Porto Firme', '3152303'),
  ('MG', 'Poté', '3152402'),
  ('MG', 'Pouso Alegre', '3152501'),
  ('MG', 'Pouso Alto', '3152600'),
  ('MG', 'Prados', '3152709'),
  ('MG', 'Prata', '3152808'),
  ('MG', 'Pratápolis', '3152907'),
  ('MG', 'Pratinha', '3153004'),
  ('MG', 'Presidente Bernardes', '3153103'),
  ('MG', 'Presidente Juscelino', '3153202'),
  ('MG', 'Presidente Kubitschek', '3153301'),
  ('MG', 'Presidente Olegário', '3153400'),
  ('MG', 'Alto Jequitibá', '3153509'),
  ('MG', 'Prudente de Morais', '3153608'),
  ('MG', 'Quartel Geral', '3153707'),
  ('MG', 'Queluzito', '3153806'),
  ('MG', 'Raposos', '3153905'),
  ('MG', 'Raul Soares', '3154002'),
  ('MG', 'Recreio', '3154101'),
  ('MG', 'Reduto', '3154150'),
  ('MG', 'Resende Costa', '3154200'),
  ('MG', 'Resplendor', '3154309'),
  ('MG', 'Ressaquinha', '3154408'),
  ('MG', 'Riachinho', '3154457'),
  ('MG', 'Riacho dos Machados', '3154507'),
  ('MG', 'Ribeirão das Neves', '3154606'),
  ('MG', 'Ribeirão Vermelho', '3154705'),
  ('MG', 'Rio Acima', '3154804'),
  ('MG', 'Rio Casca', '3154903'),
  ('MG', 'Rio doce', '3155009'),
  ('MG', 'Rio do Prado', '3155108'),
  ('MG', 'Rio Espera', '3155207'),
  ('MG', 'Rio Manso', '3155306'),
  ('MG', 'Rio Novo', '3155405'),
  ('MG', 'Rio Paranaíba', '3155504'),
  ('MG', 'Rio Pardo de Minas', '3155603'),
  ('MG', 'Rio Piracicaba', '3155702'),
  ('MG', 'Rio Pomba', '3155801'),
  ('MG', 'Rio Preto', '3155900'),
  ('MG', 'Rio Vermelho', '3156007'),
  ('MG', 'Ritápolis', '3156106'),
  ('MG', 'Rochedo de Minas', '3156205'),
  ('MG', 'Rodeiro', '3156304'),
  ('MG', 'Romaria', '3156403'),
  ('MG', 'Rosário da Limeira', '3156452'),
  ('MG', 'Rubelita', '3156502'),
  ('MG', 'Rubim', '3156601'),
  ('MG', 'Sabará', '3156700'),
  ('MG', 'Sabinópolis', '3156809'),
  ('MG', 'Sacramento', '3156908'),
  ('MG', 'Salinas', '3157005'),
  ('MG', 'Salto da Divisa', '3157104'),
  ('MG', 'Santa Bárbara', '3157203'),
  ('MG', 'Santa Bárbara do Leste', '3157252'),
  ('MG', 'Santa Bárbara do Monte Verde', '3157278'),
  ('MG', 'Santa Bárbara do Tugúrio', '3157302'),
  ('MG', 'Santa Cruz de Minas', '3157336'),
  ('MG', 'Santa Cruz de Salinas', '3157377'),
  ('MG', 'Santa Cruz do Escalvado', '3157401'),
  ('MG', 'Santa Efigênia de Minas', '3157500'),
  ('MG', 'Santa Fé de Minas', '3157609'),
  ('MG', 'Santa Helena de Minas', '3157658'),
  ('MG', 'Santa Juliana', '3157708'),
  ('MG', 'Santa Luzia', '3157807'),
  ('MG', 'Santa Margarida', '3157906'),
  ('MG', 'Santa Maria de Itabira', '3158003'),
  ('MG', 'Santa Maria do Salto', '3158102'),
  ('MG', 'Santa Maria do Suaçuí', '3158201'),
  ('MG', 'Santana da Vargem', '3158300'),
  ('MG', 'Santana de Cataguases', '3158409'),
  ('MG', 'Santana de Pirapama', '3158508'),
  ('MG', 'Santana do deserto', '3158607'),
  ('MG', 'Santana do Garambéu', '3158706'),
  ('MG', 'Santana do Jacaré', '3158805'),
  ('MG', 'Santana do Manhuaçu', '3158904'),
  ('MG', 'Santana do Paraíso', '3158953'),
  ('MG', 'Santana do Riacho', '3159001'),
  ('MG', 'Santana dos Montes', '3159100'),
  ('MG', 'Santa Rita de Caldas', '3159209'),
  ('MG', 'Santa Rita de Jacutinga', '3159308'),
  ('MG', 'Santa Rita de Minas', '3159357'),
  ('MG', 'Santa Rita de Ibitipoca', '3159407'),
  ('MG', 'Santa Rita do Itueto', '3159506'),
  ('MG', 'Santa Rita do Sapucaí', '3159605'),
  ('MG', 'Santa Rosa da Serra', '3159704'),
  ('MG', 'Santa Vitória', '3159803'),
  ('MG', 'Santo Antônio do Amparo', '3159902'),
  ('MG', 'Santo Antônio do Aventureiro', '3160009'),
  ('MG', 'Santo Antônio do Grama', '3160108'),
  ('MG', 'Santo Antônio do Itambé', '3160207'),
  ('MG', 'Santo Antônio do Jacinto', '3160306'),
  ('MG', 'Santo Antônio do Monte', '3160405'),
  ('MG', 'Santo Antônio do Retiro', '3160454'),
  ('MG', 'Santo Antônio do Rio Abaixo', '3160504'),
  ('MG', 'Santo Hipólito', '3160603'),
  ('MG', 'Santos Dumont', '3160702'),
  ('MG', 'São Bento Abade', '3160801'),
  ('MG', 'São Brás do Suaçuí', '3160900'),
  ('MG', 'São domingos das dores', '3160959'),
  ('MG', 'São domingos do Prata', '3161007'),
  ('MG', 'São Félix de Minas', '3161056'),
  ('MG', 'São Francisco', '3161106'),
  ('MG', 'São Francisco de Paula', '3161205'),
  ('MG', 'São Francisco de Sales', '3161304'),
  ('MG', 'São Francisco do Glória', '3161403'),
  ('MG', 'São Geraldo', '3161502'),
  ('MG', 'São Geraldo da Piedade', '3161601'),
  ('MG', 'São Geraldo do Baixio', '3161650'),
  ('MG', 'São Gonçalo do Abaeté', '3161700'),
  ('MG', 'São Gonçalo do Pará', '3161809'),
  ('MG', 'São Gonçalo do Rio Abaixo', '3161908'),
  ('MG', 'São Gonçalo do Sapucaí', '3162005'),
  ('MG', 'São Gotardo', '3162104'),
  ('MG', 'São João Batista do Glória', '3162203'),
  ('MG', 'São João da Lagoa', '3162252'),
  ('MG', 'São João da Mata', '3162302'),
  ('MG', 'São João da Ponte', '3162401'),
  ('MG', 'São João das Missões', '3162450'),
  ('MG', 'São João del Rei', '3162500'),
  ('MG', 'São João do Manhuaçu', '3162559'),
  ('MG', 'São João do Manteninha', '3162575'),
  ('MG', 'São João do Oriente', '3162609'),
  ('MG', 'São João do Pacuí', '3162658'),
  ('MG', 'São João do Paraíso', '3162708'),
  ('MG', 'São João Evangelista', '3162807'),
  ('MG', 'São João Nepomuceno', '3162906'),
  ('MG', 'São Joaquim de Bicas', '3162922'),
  ('MG', 'São José da Barra', '3162948'),
  ('MG', 'São José da Lapa', '3162955'),
  ('MG', 'São José da Safira', '3163003'),
  ('MG', 'São José da Varginha', '3163102'),
  ('MG', 'São José do Alegre', '3163201'),
  ('MG', 'São José do Divino', '3163300'),
  ('MG', 'São José do Goiabal', '3163409'),
  ('MG', 'São José do Jacuri', '3163508'),
  ('MG', 'São José do Mantimento', '3163607'),
  ('MG', 'São Lourenço', '3163706'),
  ('MG', 'São Miguel do Anta', '3163805'),
  ('MG', 'São Pedro da União', '3163904'),
  ('MG', 'São Pedro dos Ferros', '3164001'),
  ('MG', 'São Pedro do Suaçuí', '3164100'),
  ('MG', 'São Romão', '3164209'),
  ('MG', 'São Roque de Minas', '3164308'),
  ('MG', 'São Sebastião da Bela Vista', '3164407'),
  ('MG', 'São Sebastião da Vargem Alegre', '3164431'),
  ('MG', 'São Sebastião do Anta', '3164472'),
  ('MG', 'São Sebastião do Maranhão', '3164506'),
  ('MG', 'São Sebastião do Oeste', '3164605'),
  ('MG', 'São Sebastião do Paraíso', '3164704'),
  ('MG', 'São Sebastião do Rio Preto', '3164803'),
  ('MG', 'São Sebastião do Rio Verde', '3164902'),
  ('MG', 'São Tiago', '3165008'),
  ('MG', 'São Tomás de Aquino', '3165107'),
  ('MG', 'São Thomé das Letras', '3165206'),
  ('MG', 'São Vicente de Minas', '3165305'),
  ('MG', 'Sapucaí-Mirim', '3165404'),
  ('MG', 'Sardoá', '3165503'),
  ('MG', 'Sarzedo', '3165537'),
  ('MG', 'Setubinha', '3165552'),
  ('MG', 'Sem-Peixe', '3165560'),
  ('MG', 'Senador Amaral', '3165578'),
  ('MG', 'Senador Cortes', '3165602'),
  ('MG', 'Senador Firmino', '3165701'),
  ('MG', 'Senador José Bento', '3165800'),
  ('MG', 'Senador Modestino Gonçalves', '3165909'),
  ('MG', 'Senhora de Oliveira', '3166006'),
  ('MG', 'Senhora do Porto', '3166105'),
  ('MG', 'Senhora dos Remédios', '3166204'),
  ('MG', 'Sericita', '3166303'),
  ('MG', 'Seritinga', '3166402'),
  ('MG', 'Serra Azul de Minas', '3166501'),
  ('MG', 'Serra da Saudade', '3166600'),
  ('MG', 'Serra dos Aimorés', '3166709'),
  ('MG', 'Serra do Salitre', '3166808'),
  ('MG', 'Serrania', '3166907'),
  ('MG', 'Serranópolis de Minas', '3166956'),
  ('MG', 'Serranos', '3167004'),
  ('MG', 'Serro', '3167103'),
  ('MG', 'Sete Lagoas', '3167202'),
  ('MG', 'Silveirânia', '3167301'),
  ('MG', 'Silvianópolis', '3167400'),
  ('MG', 'Simão Pereira', '3167509'),
  ('MG', 'Simonésia', '3167608'),
  ('MG', 'Sobrália', '3167707'),
  ('MG', 'Soledade de Minas', '3167806'),
  ('MG', 'Tabuleiro', '3167905'),
  ('MG', 'Taiobeiras', '3168002'),
  ('MG', 'Taparuba', '3168051'),
  ('MG', 'Tapira', '3168101'),
  ('MG', 'Tapiraí', '3168200'),
  ('MG', 'Taquaraçu de Minas', '3168309'),
  ('MG', 'Tarumirim', '3168408'),
  ('MG', 'Teixeiras', '3168507'),
  ('MG', 'Teófilo Otoni', '3168606'),
  ('MG', 'Timóteo', '3168705'),
  ('MG', 'Tiradentes', '3168804'),
  ('MG', 'Tiros', '3168903'),
  ('MG', 'Tocantins', '3169000'),
  ('MG', 'Tocos do Moji', '3169059'),
  ('MG', 'Toledo', '3169109'),
  ('MG', 'Tombos', '3169208'),
  ('MG', 'Três Corações', '3169307'),
  ('MG', 'Três Marias', '3169356'),
  ('MG', 'Três Pontas', '3169406'),
  ('MG', 'Tumiritinga', '3169505'),
  ('MG', 'Tupaciguara', '3169604'),
  ('MG', 'Turmalina', '3169703'),
  ('MG', 'Turvolândia', '3169802'),
  ('MG', 'Ubá', '3169901'),
  ('MG', 'Ubaí', '3170008'),
  ('MG', 'Ubaporanga', '3170057'),
  ('MG', 'Uberaba', '3170107'),
  ('MG', 'Uberlândia', '3170206'),
  ('MG', 'Umburatiba', '3170305'),
  ('MG', 'Unaí', '3170404'),
  ('MG', 'União de Minas', '3170438'),
  ('MG', 'Uruana de Minas', '3170479'),
  ('MG', 'Urucânia', '3170503'),
  ('MG', 'Urucuia', '3170529'),
  ('MG', 'Vargem Alegre', '3170578'),
  ('MG', 'Vargem Bonita', '3170602'),
  ('MG', 'Vargem Grande do Rio Pardo', '3170651'),
  ('MG', 'Varginha', '3170701'),
  ('MG', 'Varjão de Minas', '3170750'),
  ('MG', 'Várzea da Palma', '3170800'),
  ('MG', 'Varzelândia', '3170909'),
  ('MG', 'Vazante', '3171006'),
  ('MG', 'Verdelândia', '3171030'),
  ('MG', 'Veredinha', '3171071'),
  ('MG', 'Veríssimo', '3171105'),
  ('MG', 'Vermelho Novo', '3171154'),
  ('MG', 'Vespasiano', '3171204'),
  ('MG', 'Viçosa', '3171303'),
  ('MG', 'Vieiras', '3171402'),
  ('MG', 'Mathias Lobato', '3171501'),
  ('MG', 'Virgem da Lapa', '3171600'),
  ('MG', 'Virgínia', '3171709'),
  ('MG', 'Virginópolis', '3171808'),
  ('MG', 'Virgolândia', '3171907'),
  ('MG', 'Visconde do Rio Branco', '3172004'),
  ('MG', 'Volta Grande', '3172103'),
  ('MG', 'Wenceslau Braz', '3172202'),
  ('ES', 'Afonso Cláudio', '3200102'),
  ('ES', 'Águia Branca', '3200136'),
  ('ES', 'Água doce do Norte', '3200169'),
  ('ES', 'Alegre', '3200201'),
  ('ES', 'Alfredo Chaves', '3200300'),
  ('ES', 'Alto Rio Novo', '3200359'),
  ('ES', 'Anchieta', '3200409'),
  ('ES', 'Apiacá', '3200508'),
  ('ES', 'Aracruz', '3200607'),
  ('ES', 'Atilio Vivacqua', '3200706'),
  ('ES', 'Baixo Guandu', '3200805'),
  ('ES', 'Barra de São Francisco', '3200904'),
  ('ES', 'Boa Esperança', '3201001'),
  ('ES', 'Bom Jesus do Norte', '3201100'),
  ('ES', 'Brejetuba', '3201159'),
  ('ES', 'Cachoeiro de Itapemirim', '3201209'),
  ('ES', 'Cariacica', '3201308'),
  ('ES', 'Castelo', '3201407'),
  ('ES', 'Colatina', '3201506'),
  ('ES', 'Conceição da Barra', '3201605'),
  ('ES', 'Conceição do Castelo', '3201704'),
  ('ES', 'Divino de São Lourenço', '3201803'),
  ('ES', 'domingos Martins', '3201902'),
  ('ES', 'dores do Rio Preto', '3202009'),
  ('ES', 'Ecoporanga', '3202108'),
  ('ES', 'Fundão', '3202207'),
  ('ES', 'Governador Lindenberg', '3202256'),
  ('ES', 'Guaçuí', '3202306'),
  ('ES', 'Guarapari', '3202405'),
  ('ES', 'Ibatiba', '3202454'),
  ('ES', 'Ibiraçu', '3202504'),
  ('ES', 'Ibitirama', '3202553'),
  ('ES', 'Iconha', '3202603'),
  ('ES', 'Irupi', '3202652'),
  ('ES', 'Itaguaçu', '3202702'),
  ('ES', 'Itapemirim', '3202801'),
  ('ES', 'Itarana', '3202900'),
  ('ES', 'Iúna', '3203007'),
  ('ES', 'Jaguaré', '3203056'),
  ('ES', 'Jerônimo Monteiro', '3203106'),
  ('ES', 'João Neiva', '3203130'),
  ('ES', 'Laranja da Terra', '3203163'),
  ('ES', 'Linhares', '3203205'),
  ('ES', 'Mantenópolis', '3203304'),
  ('ES', 'Marataízes', '3203320'),
  ('ES', 'Marechal Floriano', '3203346'),
  ('ES', 'Marilândia', '3203353'),
  ('ES', 'Mimoso do Sul', '3203403'),
  ('ES', 'Montanha', '3203502'),
  ('ES', 'Mucurici', '3203601'),
  ('ES', 'Muniz Freire', '3203700'),
  ('ES', 'Muqui', '3203809'),
  ('ES', 'Nova Venécia', '3203908'),
  ('ES', 'Pancas', '3204005'),
  ('ES', 'Pedro Canário', '3204054'),
  ('ES', 'Pinheiros', '3204104'),
  ('ES', 'Piúma', '3204203'),
  ('ES', 'Ponto Belo', '3204252'),
  ('ES', 'Presidente Kennedy', '3204302'),
  ('ES', 'Rio Bananal', '3204351'),
  ('ES', 'Rio Novo do Sul', '3204401'),
  ('ES', 'Santa Leopoldina', '3204500'),
  ('ES', 'Santa Maria de Jetibá', '3204559'),
  ('ES', 'Santa Teresa', '3204609'),
  ('ES', 'São domingos do Norte', '3204658'),
  ('ES', 'São Gabriel da Palha', '3204708'),
  ('ES', 'São José do Calçado', '3204807'),
  ('ES', 'São Mateus', '3204906'),
  ('ES', 'São Roque do Canaã', '3204955'),
  ('ES', 'Serra', '3205002'),
  ('ES', 'Sooretama', '3205010'),
  ('ES', 'Vargem Alta', '3205036'),
  ('ES', 'Venda Nova do Imigrante', '3205069'),
  ('ES', 'Viana', '3205101'),
  ('ES', 'Vila Pavão', '3205150'),
  ('ES', 'Vila Valério', '3205176'),
  ('ES', 'Vila Velha', '3205200'),
  ('ES', 'Vitória', '3205309'),
  ('RJ', 'Angra dos Reis', '3300100'),
  ('RJ', 'Aperibé', '3300159'),
  ('RJ', 'Araruama', '3300209'),
  ('RJ', 'Areal', '3300225'),
  ('RJ', 'Armação dos Búzios', '3300233'),
  ('RJ', 'Arraial do Cabo', '3300258'),
  ('RJ', 'Barra do Piraí', '3300308'),
  ('RJ', 'Barra Mansa', '3300407'),
  ('RJ', 'Belford Roxo', '3300456'),
  ('RJ', 'Bom Jardim', '3300506'),
  ('RJ', 'Bom Jesus do Itabapoana', '3300605'),
  ('RJ', 'Cabo Frio', '3300704'),
  ('RJ', 'Cachoeiras de Macacu', '3300803'),
  ('RJ', 'Cambuci', '3300902'),
  ('RJ', 'Carapebus', '3300936'),
  ('RJ', 'Comendador Levy Gasparian', '3300951'),
  ('RJ', 'Campos dos Goytacazes', '3301009'),
  ('RJ', 'Cantagalo', '3301108'),
  ('RJ', 'Cardoso Moreira', '3301157'),
  ('RJ', 'Carmo', '3301207'),
  ('RJ', 'Casimiro de Abreu', '3301306'),
  ('RJ', 'Conceição de Macabu', '3301405'),
  ('RJ', 'Cordeiro', '3301504'),
  ('RJ', 'Duas Barras', '3301603'),
  ('RJ', 'Duque de Caxias', '3301702'),
  ('RJ', 'Engenheiro Paulo de Frontin', '3301801'),
  ('RJ', 'Guapimirim', '3301850'),
  ('RJ', 'Iguaba Grande', '3301876'),
  ('RJ', 'Itaboraí', '3301900'),
  ('RJ', 'Itaguaí', '3302007'),
  ('RJ', 'Italva', '3302056'),
  ('RJ', 'Itaocara', '3302106'),
  ('RJ', 'Itaperuna', '3302205'),
  ('RJ', 'Itatiaia', '3302254'),
  ('RJ', 'Japeri', '3302270'),
  ('RJ', 'Laje do Muriaé', '3302304'),
  ('RJ', 'Macaé', '3302403'),
  ('RJ', 'Macuco', '3302452'),
  ('RJ', 'Magé', '3302502'),
  ('RJ', 'Mangaratiba', '3302601'),
  ('RJ', 'Maricá', '3302700'),
  ('RJ', 'Mendes', '3302809'),
  ('RJ', 'Mesquita', '3302858'),
  ('RJ', 'Miguel Pereira', '3302908'),
  ('RJ', 'Miracema', '3303005'),
  ('RJ', 'Natividade', '3303104'),
  ('RJ', 'Nilópolis', '3303203'),
  ('RJ', 'Niterói', '3303302'),
  ('RJ', 'Nova Friburgo', '3303401'),
  ('RJ', 'Nova Iguaçu', '3303500'),
  ('RJ', 'Paracambi', '3303609'),
  ('RJ', 'Paraíba do Sul', '3303708'),
  ('RJ', 'Paraty', '3303807'),
  ('RJ', 'Paty do Alferes', '3303856'),
  ('RJ', 'Petrópolis', '3303906'),
  ('RJ', 'Pinheiral', '3303955'),
  ('RJ', 'Piraí', '3304003'),
  ('RJ', 'Porciúncula', '3304102'),
  ('RJ', 'Porto Real', '3304110'),
  ('RJ', 'Quatis', '3304128'),
  ('RJ', 'Queimados', '3304144'),
  ('RJ', 'Quissamã', '3304151'),
  ('RJ', 'Resende', '3304201'),
  ('RJ', 'Rio Bonito', '3304300'),
  ('RJ', 'Rio Claro', '3304409'),
  ('RJ', 'Rio das Flores', '3304508'),
  ('RJ', 'Rio das Ostras', '3304524'),
  ('RJ', 'Rio de Janeiro', '3304557'),
  ('RJ', 'Santa Maria Madalena', '3304607'),
  ('RJ', 'Santo Antônio de Pádua', '3304706'),
  ('RJ', 'São Francisco de Itabapoana', '3304755'),
  ('RJ', 'São Fidélis', '3304805'),
  ('RJ', 'São Gonçalo', '3304904'),
  ('RJ', 'São João da Barra', '3305000'),
  ('RJ', 'São João de Meriti', '3305109'),
  ('RJ', 'São José de Ubá', '3305133'),
  ('RJ', 'São José do Vale do Rio Preto', '3305158'),
  ('RJ', 'São Pedro da Aldeia', '3305208'),
  ('RJ', 'São Sebastião do Alto', '3305307'),
  ('RJ', 'Sapucaia', '3305406'),
  ('RJ', 'Saquarema', '3305505'),
  ('RJ', 'Seropédica', '3305554'),
  ('RJ', 'Silva Jardim', '3305604'),
  ('RJ', 'Sumidouro', '3305703'),
  ('RJ', 'Tanguá', '3305752'),
  ('RJ', 'Teresópolis', '3305802'),
  ('RJ', 'Trajano de Moraes', '3305901'),
  ('RJ', 'Três Rios', '3306008'),
  ('RJ', 'Valença', '3306107'),
  ('RJ', 'Varre-Sai', '3306156'),
  ('RJ', 'Vassouras', '3306206'),
  ('RJ', 'Volta Redonda', '3306305'),
  ('SP', 'Adamantina', '3500105'),
  ('SP', 'Adolfo', '3500204'),
  ('SP', 'Aguaí', '3500303'),
  ('SP', 'Águas da Prata', '3500402'),
  ('SP', 'Águas de Lindóia', '3500501'),
  ('SP', 'Águas de Santa Bárbara', '3500550'),
  ('SP', 'Águas de São Pedro', '3500600'),
  ('SP', 'Agudos', '3500709'),
  ('SP', 'Alambari', '3500758'),
  ('SP', 'Alfredo Marcondes', '3500808'),
  ('SP', 'Altair', '3500907'),
  ('SP', 'Altinópolis', '3501004'),
  ('SP', 'Alto Alegre', '3501103'),
  ('SP', 'Alumínio', '3501152'),
  ('SP', 'Álvares Florence', '3501202'),
  ('SP', 'Álvares Machado', '3501301'),
  ('SP', 'Álvaro de Carvalho', '3501400'),
  ('SP', 'Alvinlândia', '3501509'),
  ('SP', 'Americana', '3501608'),
  ('SP', 'Américo Brasiliense', '3501707'),
  ('SP', 'Américo de Campos', '3501806'),
  ('SP', 'Amparo', '3501905'),
  ('SP', 'Analândia', '3502002'),
  ('SP', 'Andradina', '3502101'),
  ('SP', 'Angatuba', '3502200'),
  ('SP', 'Anhembi', '3502309'),
  ('SP', 'Anhumas', '3502408'),
  ('SP', 'Aparecida', '3502507'),
  ('SP', 'Aparecida D''oeste', '3502606'),
  ('SP', 'Apiaí', '3502705'),
  ('SP', 'Araçariguama', '3502754'),
  ('SP', 'Araçatuba', '3502804'),
  ('SP', 'Araçoiaba da Serra', '3502903'),
  ('SP', 'Aramina', '3503000'),
  ('SP', 'Arandu', '3503109'),
  ('SP', 'Arapeí', '3503158'),
  ('SP', 'Araraquara', '3503208'),
  ('SP', 'Araras', '3503307'),
  ('SP', 'Arco-Íris', '3503356'),
  ('SP', 'Arealva', '3503406'),
  ('SP', 'Areias', '3503505'),
  ('SP', 'Areiópolis', '3503604'),
  ('SP', 'Ariranha', '3503703'),
  ('SP', 'Artur Nogueira', '3503802'),
  ('SP', 'Arujá', '3503901'),
  ('SP', 'Aspásia', '3503950'),
  ('SP', 'Assis', '3504008'),
  ('SP', 'Atibaia', '3504107'),
  ('SP', 'Auriflama', '3504206'),
  ('SP', 'Avaí', '3504305'),
  ('SP', 'Avanhandava', '3504404'),
  ('SP', 'Avaré', '3504503'),
  ('SP', 'Bady Bassitt', '3504602'),
  ('SP', 'Balbinos', '3504701'),
  ('SP', 'Bálsamo', '3504800'),
  ('SP', 'Bananal', '3504909'),
  ('SP', 'Barão de Antonina', '3505005'),
  ('SP', 'Barbosa', '3505104'),
  ('SP', 'Bariri', '3505203'),
  ('SP', 'Barra Bonita', '3505302'),
  ('SP', 'Barra do Chapéu', '3505351'),
  ('SP', 'Barra do Turvo', '3505401'),
  ('SP', 'Barretos', '3505500'),
  ('SP', 'Barrinha', '3505609'),
  ('SP', 'Barueri', '3505708'),
  ('SP', 'Bastos', '3505807'),
  ('SP', 'Batatais', '3505906'),
  ('SP', 'Bauru', '3506003'),
  ('SP', 'Bebedouro', '3506102'),
  ('SP', 'Bento de Abreu', '3506201'),
  ('SP', 'Bernardino de Campos', '3506300'),
  ('SP', 'Bertioga', '3506359'),
  ('SP', 'Bilac', '3506409'),
  ('SP', 'Birigui', '3506508'),
  ('SP', 'Biritiba-Mirim', '3506607'),
  ('SP', 'Boa Esperança do Sul', '3506706'),
  ('SP', 'Bocaina', '3506805'),
  ('SP', 'Bofete', '3506904'),
  ('SP', 'Boituva', '3507001'),
  ('SP', 'Bom Jesus dos Perdões', '3507100'),
  ('SP', 'Bom Sucesso de Itararé', '3507159'),
  ('SP', 'Borá', '3507209'),
  ('SP', 'Boracéia', '3507308'),
  ('SP', 'Borborema', '3507407'),
  ('SP', 'Borebi', '3507456'),
  ('SP', 'Botucatu', '3507506'),
  ('SP', 'Bragança Paulista', '3507605'),
  ('SP', 'Braúna', '3507704'),
  ('SP', 'Brejo Alegre', '3507753'),
  ('SP', 'Brodowski', '3507803'),
  ('SP', 'Brotas', '3507902'),
  ('SP', 'Buri', '3508009'),
  ('SP', 'Buritama', '3508108'),
  ('SP', 'Buritizal', '3508207'),
  ('SP', 'Cabrália Paulista', '3508306'),
  ('SP', 'Cabreúva', '3508405'),
  ('SP', 'Caçapava', '3508504'),
  ('SP', 'Cachoeira Paulista', '3508603'),
  ('SP', 'Caconde', '3508702'),
  ('SP', 'Cafelândia', '3508801'),
  ('SP', 'Caiabu', '3508900'),
  ('SP', 'Caieiras', '3509007'),
  ('SP', 'Caiuá', '3509106'),
  ('SP', 'Cajamar', '3509205'),
  ('SP', 'Cajati', '3509254'),
  ('SP', 'Cajobi', '3509304'),
  ('SP', 'Cajuru', '3509403'),
  ('SP', 'Campina do Monte Alegre', '3509452'),
  ('SP', 'Campinas', '3509502'),
  ('SP', 'Campo Limpo Paulista', '3509601'),
  ('SP', 'Campos do Jordão', '3509700'),
  ('SP', 'Campos Novos Paulista', '3509809'),
  ('SP', 'Cananéia', '3509908'),
  ('SP', 'Canas', '3509957'),
  ('SP', 'Cândido Mota', '3510005'),
  ('SP', 'Cândido Rodrigues', '3510104'),
  ('SP', 'Canitar', '3510153'),
  ('SP', 'Capão Bonito', '3510203'),
  ('SP', 'Capela do Alto', '3510302'),
  ('SP', 'Capivari', '3510401'),
  ('SP', 'Caraguatatuba', '3510500'),
  ('SP', 'Carapicuíba', '3510609'),
  ('SP', 'Cardoso', '3510708'),
  ('SP', 'Casa Branca', '3510807'),
  ('SP', 'Cássia dos Coqueiros', '3510906'),
  ('SP', 'Castilho', '3511003'),
  ('SP', 'Catanduva', '3511102'),
  ('SP', 'Catiguá', '3511201'),
  ('SP', 'Cedral', '3511300'),
  ('SP', 'Cerqueira César', '3511409'),
  ('SP', 'Cerquilho', '3511508'),
  ('SP', 'Cesário Lange', '3511607'),
  ('SP', 'Charqueada', '3511706'),
  ('SP', 'Clementina', '3511904'),
  ('SP', 'Colina', '3512001'),
  ('SP', 'Colômbia', '3512100'),
  ('SP', 'Conchal', '3512209'),
  ('SP', 'Conchas', '3512308'),
  ('SP', 'Cordeirópolis', '3512407'),
  ('SP', 'Coroados', '3512506'),
  ('SP', 'Coronel Macedo', '3512605'),
  ('SP', 'Corumbataí', '3512704'),
  ('SP', 'Cosmópolis', '3512803'),
  ('SP', 'Cosmorama', '3512902'),
  ('SP', 'Cotia', '3513009'),
  ('SP', 'Cravinhos', '3513108'),
  ('SP', 'Cristais Paulista', '3513207'),
  ('SP', 'Cruzália', '3513306'),
  ('SP', 'Cruzeiro', '3513405'),
  ('SP', 'Cubatão', '3513504'),
  ('SP', 'Cunha', '3513603'),
  ('SP', 'descalvado', '3513702'),
  ('SP', 'Diadema', '3513801'),
  ('SP', 'Dirce Reis', '3513850'),
  ('SP', 'Divinolândia', '3513900'),
  ('SP', 'dobrada', '3514007'),
  ('SP', 'dois Córregos', '3514106'),
  ('SP', 'dolcinópolis', '3514205'),
  ('SP', 'dourado', '3514304'),
  ('SP', 'Dracena', '3514403'),
  ('SP', 'Duartina', '3514502'),
  ('SP', 'Dumont', '3514601'),
  ('SP', 'Echaporã', '3514700'),
  ('SP', 'Eldorado', '3514809'),
  ('SP', 'Elias Fausto', '3514908'),
  ('SP', 'Elisiário', '3514924'),
  ('SP', 'Embaúba', '3514957'),
  ('SP', 'Embu das Artes', '3515004'),
  ('SP', 'Embu-Guaçu', '3515103'),
  ('SP', 'Emilianópolis', '3515129'),
  ('SP', 'Engenheiro Coelho', '3515152'),
  ('SP', 'Espírito Santo do Pinhal', '3515186'),
  ('SP', 'Espírito Santo do Turvo', '3515194'),
  ('SP', 'Estrela D''oeste', '3515202'),
  ('SP', 'Estrela do Norte', '3515301'),
  ('SP', 'Euclides da Cunha Paulista', '3515350'),
  ('SP', 'Fartura', '3515400'),
  ('SP', 'Fernandópolis', '3515509'),
  ('SP', 'Fernando Prestes', '3515608'),
  ('SP', 'Fernão', '3515657'),
  ('SP', 'Ferraz de Vasconcelos', '3515707'),
  ('SP', 'Flora Rica', '3515806'),
  ('SP', 'Floreal', '3515905'),
  ('SP', 'Flórida Paulista', '3516002'),
  ('SP', 'Florínia', '3516101'),
  ('SP', 'Franca', '3516200'),
  ('SP', 'Francisco Morato', '3516309'),
  ('SP', 'Franco da Rocha', '3516408'),
  ('SP', 'Gabriel Monteiro', '3516507'),
  ('SP', 'Gália', '3516606'),
  ('SP', 'Garça', '3516705'),
  ('SP', 'Gastão Vidigal', '3516804'),
  ('SP', 'Gavião Peixoto', '3516853'),
  ('SP', 'General Salgado', '3516903'),
  ('SP', 'Getulina', '3517000'),
  ('SP', 'Glicério', '3517109'),
  ('SP', 'Guaiçara', '3517208'),
  ('SP', 'Guaimbê', '3517307'),
  ('SP', 'Guaíra', '3517406'),
  ('SP', 'Guapiaçu', '3517505'),
  ('SP', 'Guapiara', '3517604'),
  ('SP', 'Guará', '3517703'),
  ('SP', 'Guaraçaí', '3517802'),
  ('SP', 'Guaraci', '3517901'),
  ('SP', 'Guarani D''oeste', '3518008'),
  ('SP', 'Guarantã', '3518107'),
  ('SP', 'Guararapes', '3518206'),
  ('SP', 'Guararema', '3518305'),
  ('SP', 'Guaratinguetá', '3518404'),
  ('SP', 'Guareí', '3518503'),
  ('SP', 'Guariba', '3518602'),
  ('SP', 'Guarujá', '3518701'),
  ('SP', 'Guarulhos', '3518800'),
  ('SP', 'Guatapará', '3518859'),
  ('SP', 'Guzolândia', '3518909'),
  ('SP', 'Herculândia', '3519006'),
  ('SP', 'Holambra', '3519055'),
  ('SP', 'Hortolândia', '3519071'),
  ('SP', 'Iacanga', '3519105'),
  ('SP', 'Iacri', '3519204'),
  ('SP', 'Iaras', '3519253'),
  ('SP', 'Ibaté', '3519303'),
  ('SP', 'Ibirá', '3519402'),
  ('SP', 'Ibirarema', '3519501'),
  ('SP', 'Ibitinga', '3519600'),
  ('SP', 'Ibiúna', '3519709'),
  ('SP', 'Icém', '3519808'),
  ('SP', 'Iepê', '3519907'),
  ('SP', 'Igaraçu do Tietê', '3520004'),
  ('SP', 'Igarapava', '3520103'),
  ('SP', 'Igaratá', '3520202'),
  ('SP', 'Iguape', '3520301'),
  ('SP', 'Ilhabela', '3520400'),
  ('SP', 'Ilha Comprida', '3520426'),
  ('SP', 'Ilha Solteira', '3520442'),
  ('SP', 'Indaiatuba', '3520509'),
  ('SP', 'Indiana', '3520608'),
  ('SP', 'Indiaporã', '3520707'),
  ('SP', 'Inúbia Paulista', '3520806'),
  ('SP', 'Ipaussu', '3520905'),
  ('SP', 'Iperó', '3521002'),
  ('SP', 'Ipeúna', '3521101'),
  ('SP', 'Ipiguá', '3521150'),
  ('SP', 'Iporanga', '3521200'),
  ('SP', 'Ipuã', '3521309'),
  ('SP', 'Iracemápolis', '3521408'),
  ('SP', 'Irapuã', '3521507'),
  ('SP', 'Irapuru', '3521606'),
  ('SP', 'Itaberá', '3521705'),
  ('SP', 'Itaí', '3521804'),
  ('SP', 'Itajobi', '3521903'),
  ('SP', 'Itaju', '3522000'),
  ('SP', 'Itanhaém', '3522109'),
  ('SP', 'Itaóca', '3522158'),
  ('SP', 'Itapecerica da Serra', '3522208'),
  ('SP', 'Itapetininga', '3522307'),
  ('SP', 'Itapeva', '3522406'),
  ('SP', 'Itapevi', '3522505'),
  ('SP', 'Itapira', '3522604'),
  ('SP', 'Itapirapuã Paulista', '3522653'),
  ('SP', 'Itápolis', '3522703'),
  ('SP', 'Itaporanga', '3522802'),
  ('SP', 'Itapuí', '3522901'),
  ('SP', 'Itapura', '3523008'),
  ('SP', 'Itaquaquecetuba', '3523107'),
  ('SP', 'Itararé', '3523206'),
  ('SP', 'Itariri', '3523305'),
  ('SP', 'Itatiba', '3523404'),
  ('SP', 'Itatinga', '3523503'),
  ('SP', 'Itirapina', '3523602'),
  ('SP', 'Itirapuã', '3523701'),
  ('SP', 'Itobi', '3523800'),
  ('SP', 'Itu', '3523909'),
  ('SP', 'Itupeva', '3524006'),
  ('SP', 'Ituverava', '3524105'),
  ('SP', 'Jaborandi', '3524204'),
  ('SP', 'Jaboticabal', '3524303'),
  ('SP', 'Jacareí', '3524402'),
  ('SP', 'Jaci', '3524501'),
  ('SP', 'Jacupiranga', '3524600'),
  ('SP', 'Jaguariúna', '3524709'),
  ('SP', 'Jales', '3524808'),
  ('SP', 'Jambeiro', '3524907'),
  ('SP', 'Jandira', '3525003'),
  ('SP', 'Jardinópolis', '3525102'),
  ('SP', 'Jarinu', '3525201'),
  ('SP', 'Jaú', '3525300'),
  ('SP', 'Jeriquara', '3525409'),
  ('SP', 'Joanópolis', '3525508'),
  ('SP', 'João Ramalho', '3525607'),
  ('SP', 'José Bonifácio', '3525706'),
  ('SP', 'Júlio Mesquita', '3525805'),
  ('SP', 'Jumirim', '3525854'),
  ('SP', 'Jundiaí', '3525904'),
  ('SP', 'Junqueirópolis', '3526001'),
  ('SP', 'Juquiá', '3526100'),
  ('SP', 'Juquitiba', '3526209'),
  ('SP', 'Lagoinha', '3526308'),
  ('SP', 'Laranjal Paulista', '3526407'),
  ('SP', 'Lavínia', '3526506'),
  ('SP', 'Lavrinhas', '3526605'),
  ('SP', 'Leme', '3526704'),
  ('SP', 'Lençóis Paulista', '3526803'),
  ('SP', 'Limeira', '3526902'),
  ('SP', 'Lindóia', '3527009'),
  ('SP', 'Lins', '3527108'),
  ('SP', 'Lorena', '3527207'),
  ('SP', 'Lourdes', '3527256'),
  ('SP', 'Louveira', '3527306'),
  ('SP', 'Lucélia', '3527405'),
  ('SP', 'Lucianópolis', '3527504'),
  ('SP', 'Luís Antônio', '3527603'),
  ('SP', 'Luiziânia', '3527702'),
  ('SP', 'Lupércio', '3527801'),
  ('SP', 'Lutécia', '3527900'),
  ('SP', 'Macatuba', '3528007'),
  ('SP', 'Macaubal', '3528106'),
  ('SP', 'Macedônia', '3528205'),
  ('SP', 'Magda', '3528304'),
  ('SP', 'Mairinque', '3528403'),
  ('SP', 'Mairiporã', '3528502'),
  ('SP', 'Manduri', '3528601'),
  ('SP', 'Marabá Paulista', '3528700'),
  ('SP', 'Maracaí', '3528809'),
  ('SP', 'Marapoama', '3528858'),
  ('SP', 'Mariápolis', '3528908'),
  ('SP', 'Marília', '3529005'),
  ('SP', 'Marinópolis', '3529104'),
  ('SP', 'Martinópolis', '3529203'),
  ('SP', 'Matão', '3529302'),
  ('SP', 'Mauá', '3529401'),
  ('SP', 'Mendonça', '3529500'),
  ('SP', 'Meridiano', '3529609'),
  ('SP', 'Mesópolis', '3529658'),
  ('SP', 'Miguelópolis', '3529708'),
  ('SP', 'Mineiros do Tietê', '3529807'),
  ('SP', 'Miracatu', '3529906'),
  ('SP', 'Mira Estrela', '3530003'),
  ('SP', 'Mirandópolis', '3530102'),
  ('SP', 'Mirante do Paranapanema', '3530201'),
  ('SP', 'Mirassol', '3530300'),
  ('SP', 'Mirassolândia', '3530409'),
  ('SP', 'Mococa', '3530508'),
  ('SP', 'Mogi das Cruzes', '3530607'),
  ('SP', 'Mogi Guaçu', '3530706'),
  ('SP', 'Mogi Mirim', '3530805'),
  ('SP', 'Mombuca', '3530904'),
  ('SP', 'Monções', '3531001'),
  ('SP', 'Mongaguá', '3531100'),
  ('SP', 'Monte Alegre do Sul', '3531209'),
  ('SP', 'Monte Alto', '3531308'),
  ('SP', 'Monte Aprazível', '3531407'),
  ('SP', 'Monte Azul Paulista', '3531506'),
  ('SP', 'Monte Castelo', '3531605'),
  ('SP', 'Monteiro Lobato', '3531704'),
  ('SP', 'Monte Mor', '3531803'),
  ('SP', 'Morro Agudo', '3531902'),
  ('SP', 'Morungaba', '3532009'),
  ('SP', 'Motuca', '3532058'),
  ('SP', 'Murutinga do Sul', '3532108'),
  ('SP', 'Nantes', '3532157'),
  ('SP', 'Narandiba', '3532207'),
  ('SP', 'Natividade da Serra', '3532306'),
  ('SP', 'Nazaré Paulista', '3532405'),
  ('SP', 'Neves Paulista', '3532504'),
  ('SP', 'Nhandeara', '3532603'),
  ('SP', 'Nipoã', '3532702'),
  ('SP', 'Nova Aliança', '3532801'),
  ('SP', 'Nova Campina', '3532827'),
  ('SP', 'Nova Canaã Paulista', '3532843'),
  ('SP', 'Nova Castilho', '3532868'),
  ('SP', 'Nova Europa', '3532900'),
  ('SP', 'Nova Granada', '3533007'),
  ('SP', 'Nova Guataporanga', '3533106'),
  ('SP', 'Nova Independência', '3533205'),
  ('SP', 'Novais', '3533254'),
  ('SP', 'Nova Luzitânia', '3533304'),
  ('SP', 'Nova Odessa', '3533403'),
  ('SP', 'Novo Horizonte', '3533502'),
  ('SP', 'Nuporanga', '3533601'),
  ('SP', 'Ocauçu', '3533700'),
  ('SP', 'Óleo', '3533809'),
  ('SP', 'Olímpia', '3533908'),
  ('SP', 'Onda Verde', '3534005'),
  ('SP', 'Oriente', '3534104'),
  ('SP', 'Orindiúva', '3534203'),
  ('SP', 'Orlândia', '3534302'),
  ('SP', 'Osasco', '3534401'),
  ('SP', 'Oscar Bressane', '3534500'),
  ('SP', 'Osvaldo Cruz', '3534609'),
  ('SP', 'Ourinhos', '3534708'),
  ('SP', 'Ouroeste', '3534757'),
  ('SP', 'Ouro Verde', '3534807'),
  ('SP', 'Pacaembu', '3534906'),
  ('SP', 'Palestina', '3535002'),
  ('SP', 'Palmares Paulista', '3535101'),
  ('SP', 'Palmeira D''oeste', '3535200'),
  ('SP', 'Palmital', '3535309'),
  ('SP', 'Panorama', '3535408'),
  ('SP', 'Paraguaçu Paulista', '3535507'),
  ('SP', 'Paraibuna', '3535606'),
  ('SP', 'Paraíso', '3535705'),
  ('SP', 'Paranapanema', '3535804'),
  ('SP', 'Paranapuã', '3535903'),
  ('SP', 'Parapuã', '3536000'),
  ('SP', 'Pardinho', '3536109'),
  ('SP', 'Pariquera-Açu', '3536208'),
  ('SP', 'Parisi', '3536257'),
  ('SP', 'Patrocínio Paulista', '3536307'),
  ('SP', 'Paulicéia', '3536406'),
  ('SP', 'Paulínia', '3536505'),
  ('SP', 'Paulistânia', '3536570'),
  ('SP', 'Paulo de Faria', '3536604'),
  ('SP', 'Pederneiras', '3536703'),
  ('SP', 'Pedra Bela', '3536802'),
  ('SP', 'Pedranópolis', '3536901'),
  ('SP', 'Pedregulho', '3537008'),
  ('SP', 'Pedreira', '3537107'),
  ('SP', 'Pedrinhas Paulista', '3537156'),
  ('SP', 'Pedro de Toledo', '3537206'),
  ('SP', 'Penápolis', '3537305'),
  ('SP', 'Pereira Barreto', '3537404'),
  ('SP', 'Pereiras', '3537503'),
  ('SP', 'Peruíbe', '3537602'),
  ('SP', 'Piacatu', '3537701'),
  ('SP', 'Piedade', '3537800'),
  ('SP', 'Pilar do Sul', '3537909'),
  ('SP', 'Pindamonhangaba', '3538006'),
  ('SP', 'Pindorama', '3538105'),
  ('SP', 'Pinhalzinho', '3538204'),
  ('SP', 'Piquerobi', '3538303'),
  ('SP', 'Piquete', '3538501'),
  ('SP', 'Piracaia', '3538600'),
  ('SP', 'Piracicaba', '3538709'),
  ('SP', 'Piraju', '3538808'),
  ('SP', 'Pirajuí', '3538907'),
  ('SP', 'Pirangi', '3539004'),
  ('SP', 'Pirapora do Bom Jesus', '3539103'),
  ('SP', 'Pirapozinho', '3539202'),
  ('SP', 'Pirassununga', '3539301'),
  ('SP', 'Piratininga', '3539400'),
  ('SP', 'Pitangueiras', '3539509'),
  ('SP', 'Planalto', '3539608'),
  ('SP', 'Platina', '3539707'),
  ('SP', 'Poá', '3539806'),
  ('SP', 'Poloni', '3539905'),
  ('SP', 'Pompéia', '3540002'),
  ('SP', 'Pongaí', '3540101'),
  ('SP', 'Pontal', '3540200'),
  ('SP', 'Pontalinda', '3540259'),
  ('SP', 'Pontes Gestal', '3540309'),
  ('SP', 'Populina', '3540408'),
  ('SP', 'Porangaba', '3540507'),
  ('SP', 'Porto Feliz', '3540606'),
  ('SP', 'Porto Ferreira', '3540705'),
  ('SP', 'Potim', '3540754'),
  ('SP', 'Potirendaba', '3540804'),
  ('SP', 'Pracinha', '3540853'),
  ('SP', 'Pradópolis', '3540903'),
  ('SP', 'Praia Grande', '3541000'),
  ('SP', 'Pratânia', '3541059'),
  ('SP', 'Presidente Alves', '3541109'),
  ('SP', 'Presidente Bernardes', '3541208'),
  ('SP', 'Presidente Epitácio', '3541307'),
  ('SP', 'Presidente Prudente', '3541406'),
  ('SP', 'Presidente Venceslau', '3541505'),
  ('SP', 'Promissão', '3541604'),
  ('SP', 'Quadra', '3541653'),
  ('SP', 'Quatá', '3541703'),
  ('SP', 'Queiroz', '3541802'),
  ('SP', 'Queluz', '3541901'),
  ('SP', 'Quintana', '3542008'),
  ('SP', 'Rafard', '3542107'),
  ('SP', 'Rancharia', '3542206'),
  ('SP', 'Redenção da Serra', '3542305'),
  ('SP', 'Regente Feijó', '3542404'),
  ('SP', 'Reginópolis', '3542503'),
  ('SP', 'Registro', '3542602'),
  ('SP', 'Restinga', '3542701'),
  ('SP', 'Ribeira', '3542800'),
  ('SP', 'Ribeirão Bonito', '3542909'),
  ('SP', 'Ribeirão Branco', '3543006'),
  ('SP', 'Ribeirão Corrente', '3543105'),
  ('SP', 'Ribeirão do Sul', '3543204'),
  ('SP', 'Ribeirão dos Índios', '3543238'),
  ('SP', 'Ribeirão Grande', '3543253'),
  ('SP', 'Ribeirão Pires', '3543303'),
  ('SP', 'Ribeirão Preto', '3543402'),
  ('SP', 'Riversul', '3543501'),
  ('SP', 'Rifaina', '3543600'),
  ('SP', 'Rincão', '3543709'),
  ('SP', 'Rinópolis', '3543808'),
  ('SP', 'Rio Claro', '3543907'),
  ('SP', 'Rio das Pedras', '3544004'),
  ('SP', 'Rio Grande da Serra', '3544103'),
  ('SP', 'Riolândia', '3544202'),
  ('SP', 'Rosana', '3544251'),
  ('SP', 'Roseira', '3544301'),
  ('SP', 'Rubiácea', '3544400'),
  ('SP', 'Rubinéia', '3544509'),
  ('SP', 'Sabino', '3544608'),
  ('SP', 'Sagres', '3544707'),
  ('SP', 'Sales', '3544806'),
  ('SP', 'Sales Oliveira', '3544905'),
  ('SP', 'Salesópolis', '3545001'),
  ('SP', 'Salmourão', '3545100'),
  ('SP', 'Saltinho', '3545159'),
  ('SP', 'Salto', '3545209'),
  ('SP', 'Salto de Pirapora', '3545308'),
  ('SP', 'Salto Grande', '3545407'),
  ('SP', 'Sandovalina', '3545506'),
  ('SP', 'Santa Adélia', '3545605'),
  ('SP', 'Santa Albertina', '3545704'),
  ('SP', 'Santa Bárbara D''oeste', '3545803'),
  ('SP', 'Santa Branca', '3546009'),
  ('SP', 'Santa Clara D''oeste', '3546108'),
  ('SP', 'Santa Cruz da Conceição', '3546207'),
  ('SP', 'Santa Cruz da Esperança', '3546256'),
  ('SP', 'Santa Cruz das Palmeiras', '3546306'),
  ('SP', 'Santa Cruz do Rio Pardo', '3546405'),
  ('SP', 'Santa Ernestina', '3546504'),
  ('SP', 'Santa Fé do Sul', '3546603'),
  ('SP', 'Santa Gertrudes', '3546702'),
  ('SP', 'Santa Isabel', '3546801'),
  ('SP', 'Santa Lúcia', '3546900'),
  ('SP', 'Santa Maria da Serra', '3547007'),
  ('SP', 'Santa Mercedes', '3547106'),
  ('SP', 'Santana da Ponte Pensa', '3547205'),
  ('SP', 'Santana de Parnaíba', '3547304'),
  ('SP', 'Santa Rita D''oeste', '3547403'),
  ('SP', 'Santa Rita do Passa Quatro', '3547502'),
  ('SP', 'Santa Rosa de Viterbo', '3547601'),
  ('SP', 'Santa Salete', '3547650'),
  ('SP', 'Santo Anastácio', '3547700'),
  ('SP', 'Santo André', '3547809'),
  ('SP', 'Santo Antônio da Alegria', '3547908'),
  ('SP', 'Santo Antônio de Posse', '3548005'),
  ('SP', 'Santo Antônio do Aracanguá', '3548054'),
  ('SP', 'Santo Antônio do Jardim', '3548104'),
  ('SP', 'Santo Antônio do Pinhal', '3548203'),
  ('SP', 'Santo Expedito', '3548302'),
  ('SP', 'Santópolis do Aguapeí', '3548401'),
  ('SP', 'Santos', '3548500'),
  ('SP', 'São Bento do Sapucaí', '3548609'),
  ('SP', 'São Bernardo do Campo', '3548708'),
  ('SP', 'São Caetano do Sul', '3548807'),
  ('SP', 'São Carlos', '3548906'),
  ('SP', 'São Francisco', '3549003'),
  ('SP', 'São João da Boa Vista', '3549102'),
  ('SP', 'São João das Duas Pontes', '3549201'),
  ('SP', 'São João de Iracema', '3549250'),
  ('SP', 'São João do Pau D''alho', '3549300'),
  ('SP', 'São Joaquim da Barra', '3549409'),
  ('SP', 'São José da Bela Vista', '3549508'),
  ('SP', 'São José do Barreiro', '3549607'),
  ('SP', 'São José do Rio Pardo', '3549706'),
  ('SP', 'São José do Rio Preto', '3549805'),
  ('SP', 'São José dos Campos', '3549904'),
  ('SP', 'São Lourenço da Serra', '3549953'),
  ('SP', 'São Luís do Paraitinga', '3550001'),
  ('SP', 'São Manuel', '3550100'),
  ('SP', 'São Miguel Arcanjo', '3550209'),
  ('SP', 'São Paulo', '3550308'),
  ('SP', 'São Pedro', '3550407'),
  ('SP', 'São Pedro do Turvo', '3550506'),
  ('SP', 'São Roque', '3550605'),
  ('SP', 'São Sebastião', '3550704'),
  ('SP', 'São Sebastião da Grama', '3550803'),
  ('SP', 'São Simão', '3550902'),
  ('SP', 'São Vicente', '3551009'),
  ('SP', 'Sarapuí', '3551108'),
  ('SP', 'Sarutaiá', '3551207'),
  ('SP', 'Sebastianópolis do Sul', '3551306'),
  ('SP', 'Serra Azul', '3551405'),
  ('SP', 'Serrana', '3551504'),
  ('SP', 'Serra Negra', '3551603'),
  ('SP', 'Sertãozinho', '3551702'),
  ('SP', 'Sete Barras', '3551801'),
  ('SP', 'Severínia', '3551900'),
  ('SP', 'Silveiras', '3552007'),
  ('SP', 'Socorro', '3552106'),
  ('SP', 'Sorocaba', '3552205'),
  ('SP', 'Sud Mennucci', '3552304'),
  ('SP', 'Sumaré', '3552403'),
  ('SP', 'Suzano', '3552502'),
  ('SP', 'Suzanápolis', '3552551'),
  ('SP', 'Tabapuã', '3552601'),
  ('SP', 'Tabatinga', '3552700'),
  ('SP', 'Taboão da Serra', '3552809'),
  ('SP', 'Taciba', '3552908'),
  ('SP', 'Taguaí', '3553005'),
  ('SP', 'Taiaçu', '3553104'),
  ('SP', 'Taiúva', '3553203'),
  ('SP', 'Tambaú', '3553302'),
  ('SP', 'Tanabi', '3553401'),
  ('SP', 'Tapiraí', '3553500'),
  ('SP', 'Tapiratiba', '3553609'),
  ('SP', 'Taquaral', '3553658'),
  ('SP', 'Taquaritinga', '3553708'),
  ('SP', 'Taquarituba', '3553807'),
  ('SP', 'Taquarivaí', '3553856'),
  ('SP', 'Tarabai', '3553906'),
  ('SP', 'Tarumã', '3553955'),
  ('SP', 'Tatuí', '3554003'),
  ('SP', 'Taubaté', '3554102'),
  ('SP', 'Tejupá', '3554201'),
  ('SP', 'Teodoro Sampaio', '3554300'),
  ('SP', 'Terra Roxa', '3554409'),
  ('SP', 'Tietê', '3554508'),
  ('SP', 'Timburi', '3554607'),
  ('SP', 'Torre de Pedra', '3554656'),
  ('SP', 'Torrinha', '3554706'),
  ('SP', 'Trabiju', '3554755'),
  ('SP', 'Tremembé', '3554805'),
  ('SP', 'Três Fronteiras', '3554904'),
  ('SP', 'Tuiuti', '3554953'),
  ('SP', 'Tupã', '3555000'),
  ('SP', 'Tupi Paulista', '3555109'),
  ('SP', 'Turiúba', '3555208'),
  ('SP', 'Turmalina', '3555307'),
  ('SP', 'Ubarana', '3555356'),
  ('SP', 'Ubatuba', '3555406'),
  ('SP', 'Ubirajara', '3555505'),
  ('SP', 'Uchoa', '3555604'),
  ('SP', 'União Paulista', '3555703'),
  ('SP', 'Urânia', '3555802'),
  ('SP', 'Uru', '3555901'),
  ('SP', 'Urupês', '3556008'),
  ('SP', 'Valentim Gentil', '3556107'),
  ('SP', 'Valinhos', '3556206'),
  ('SP', 'Valparaíso', '3556305'),
  ('SP', 'Vargem', '3556354'),
  ('SP', 'Vargem Grande do Sul', '3556404'),
  ('SP', 'Vargem Grande Paulista', '3556453'),
  ('SP', 'Várzea Paulista', '3556503'),
  ('SP', 'Vera Cruz', '3556602'),
  ('SP', 'Vinhedo', '3556701'),
  ('SP', 'Viradouro', '3556800'),
  ('SP', 'Vista Alegre do Alto', '3556909'),
  ('SP', 'Vitória Brasil', '3556958'),
  ('SP', 'Votorantim', '3557006'),
  ('SP', 'Votuporanga', '3557105'),
  ('SP', 'Zacarias', '3557154'),
  ('SP', 'Chavantes', '3557204'),
  ('SP', 'Estiva Gerbi', '3557303'),
  ('PR', 'Abatiá', '4100103'),
  ('PR', 'Adrianópolis', '4100202'),
  ('PR', 'Agudos do Sul', '4100301'),
  ('PR', 'Almirante Tamandaré', '4100400'),
  ('PR', 'Altamira do Paraná', '4100459'),
  ('PR', 'Altônia', '4100509'),
  ('PR', 'Alto Paraná', '4100608'),
  ('PR', 'Alto Piquiri', '4100707'),
  ('PR', 'Alvorada do Sul', '4100806'),
  ('PR', 'Amaporã', '4100905'),
  ('PR', 'Ampére', '4101002'),
  ('PR', 'Anahy', '4101051'),
  ('PR', 'Andirá', '4101101'),
  ('PR', 'Ângulo', '4101150'),
  ('PR', 'Antonina', '4101200'),
  ('PR', 'Antônio Olinto', '4101309'),
  ('PR', 'Apucarana', '4101408'),
  ('PR', 'Arapongas', '4101507'),
  ('PR', 'Arapoti', '4101606'),
  ('PR', 'Arapuã', '4101655'),
  ('PR', 'Araruna', '4101705'),
  ('PR', 'Araucária', '4101804'),
  ('PR', 'Ariranha do Ivaí', '4101853'),
  ('PR', 'Assaí', '4101903'),
  ('PR', 'Assis Chateaubriand', '4102000'),
  ('PR', 'Astorga', '4102109'),
  ('PR', 'Atalaia', '4102208'),
  ('PR', 'Balsa Nova', '4102307'),
  ('PR', 'Bandeirantes', '4102406'),
  ('PR', 'Barbosa Ferraz', '4102505'),
  ('PR', 'Barracão', '4102604'),
  ('PR', 'Barra do Jacaré', '4102703'),
  ('PR', 'Bela Vista da Caroba', '4102752'),
  ('PR', 'Bela Vista do Paraíso', '4102802'),
  ('PR', 'Bituruna', '4102901'),
  ('PR', 'Boa Esperança', '4103008'),
  ('PR', 'Boa Esperança do Iguaçu', '4103024'),
  ('PR', 'Boa Ventura de São Roque', '4103040'),
  ('PR', 'Boa Vista da Aparecida', '4103057'),
  ('PR', 'Bocaiúva do Sul', '4103107'),
  ('PR', 'Bom Jesus do Sul', '4103156'),
  ('PR', 'Bom Sucesso', '4103206'),
  ('PR', 'Bom Sucesso do Sul', '4103222'),
  ('PR', 'Borrazópolis', '4103305'),
  ('PR', 'Braganey', '4103354'),
  ('PR', 'Brasilândia do Sul', '4103370'),
  ('PR', 'Cafeara', '4103404'),
  ('PR', 'Cafelândia', '4103453'),
  ('PR', 'Cafezal do Sul', '4103479'),
  ('PR', 'Califórnia', '4103503'),
  ('PR', 'Cambará', '4103602'),
  ('PR', 'Cambé', '4103701'),
  ('PR', 'Cambira', '4103800'),
  ('PR', 'Campina da Lagoa', '4103909'),
  ('PR', 'Campina do Simão', '4103958'),
  ('PR', 'Campina Grande do Sul', '4104006'),
  ('PR', 'Campo Bonito', '4104055'),
  ('PR', 'Campo do Tenente', '4104105'),
  ('PR', 'Campo Largo', '4104204'),
  ('PR', 'Campo Magro', '4104253'),
  ('PR', 'Campo Mourão', '4104303'),
  ('PR', 'Cândido de Abreu', '4104402'),
  ('PR', 'Candói', '4104428'),
  ('PR', 'Cantagalo', '4104451'),
  ('PR', 'Capanema', '4104501'),
  ('PR', 'Capitão Leônidas Marques', '4104600'),
  ('PR', 'Carambeí', '4104659'),
  ('PR', 'Carlópolis', '4104709'),
  ('PR', 'Cascavel', '4104808'),
  ('PR', 'Castro', '4104907'),
  ('PR', 'Catanduvas', '4105003'),
  ('PR', 'Centenário do Sul', '4105102'),
  ('PR', 'Cerro Azul', '4105201'),
  ('PR', 'Céu Azul', '4105300'),
  ('PR', 'Chopinzinho', '4105409'),
  ('PR', 'Cianorte', '4105508'),
  ('PR', 'Cidade Gaúcha', '4105607'),
  ('PR', 'Clevelândia', '4105706'),
  ('PR', 'Colombo', '4105805'),
  ('PR', 'Colorado', '4105904'),
  ('PR', 'Congonhinhas', '4106001'),
  ('PR', 'Conselheiro Mairinck', '4106100'),
  ('PR', 'Contenda', '4106209'),
  ('PR', 'Corbélia', '4106308'),
  ('PR', 'Cornélio Procópio', '4106407'),
  ('PR', 'Coronel domingos Soares', '4106456'),
  ('PR', 'Coronel Vivida', '4106506'),
  ('PR', 'Corumbataí do Sul', '4106555'),
  ('PR', 'Cruzeiro do Iguaçu', '4106571'),
  ('PR', 'Cruzeiro do Oeste', '4106605'),
  ('PR', 'Cruzeiro do Sul', '4106704'),
  ('PR', 'Cruz Machado', '4106803'),
  ('PR', 'Cruzmaltina', '4106852'),
  ('PR', 'Curitiba', '4106902'),
  ('PR', 'Curiúva', '4107009'),
  ('PR', 'Diamante do Norte', '4107108'),
  ('PR', 'Diamante do Sul', '4107124'),
  ('PR', 'Diamante D''oeste', '4107157'),
  ('PR', 'dois Vizinhos', '4107207'),
  ('PR', 'douradina', '4107256'),
  ('PR', 'doutor Camargo', '4107306'),
  ('PR', 'Enéas Marques', '4107405'),
  ('PR', 'Engenheiro Beltrão', '4107504'),
  ('PR', 'Esperança Nova', '4107520'),
  ('PR', 'Entre Rios do Oeste', '4107538'),
  ('PR', 'Espigão Alto do Iguaçu', '4107546'),
  ('PR', 'Farol', '4107553'),
  ('PR', 'Faxinal', '4107603'),
  ('PR', 'Fazenda Rio Grande', '4107652'),
  ('PR', 'Fênix', '4107702'),
  ('PR', 'Fernandes Pinheiro', '4107736'),
  ('PR', 'Figueira', '4107751'),
  ('PR', 'Floraí', '4107801'),
  ('PR', 'Flor da Serra do Sul', '4107850'),
  ('PR', 'Floresta', '4107900'),
  ('PR', 'Florestópolis', '4108007'),
  ('PR', 'Flórida', '4108106'),
  ('PR', 'Formosa do Oeste', '4108205'),
  ('PR', 'Foz do Iguaçu', '4108304'),
  ('PR', 'Francisco Alves', '4108320'),
  ('PR', 'Francisco Beltrão', '4108403'),
  ('PR', 'Foz do Jordão', '4108452'),
  ('PR', 'General Carneiro', '4108502'),
  ('PR', 'Godoy Moreira', '4108551'),
  ('PR', 'Goioerê', '4108601'),
  ('PR', 'Goioxim', '4108650'),
  ('PR', 'Grandes Rios', '4108700'),
  ('PR', 'Guaíra', '4108809'),
  ('PR', 'Guairaçá', '4108908'),
  ('PR', 'Guamiranga', '4108957'),
  ('PR', 'Guapirama', '4109005'),
  ('PR', 'Guaporema', '4109104'),
  ('PR', 'Guaraci', '4109203'),
  ('PR', 'Guaraniaçu', '4109302'),
  ('PR', 'Guarapuava', '4109401'),
  ('PR', 'Guaraqueçaba', '4109500'),
  ('PR', 'Guaratuba', '4109609'),
  ('PR', 'Honório Serpa', '4109658'),
  ('PR', 'Ibaiti', '4109708'),
  ('PR', 'Ibema', '4109757'),
  ('PR', 'Ibiporã', '4109807'),
  ('PR', 'Icaraíma', '4109906'),
  ('PR', 'Iguaraçu', '4110003'),
  ('PR', 'Iguatu', '4110052'),
  ('PR', 'Imbaú', '4110078'),
  ('PR', 'Imbituva', '4110102'),
  ('PR', 'Inácio Martins', '4110201'),
  ('PR', 'Inajá', '4110300'),
  ('PR', 'Indianópolis', '4110409'),
  ('PR', 'Ipiranga', '4110508'),
  ('PR', 'Iporã', '4110607'),
  ('PR', 'Iracema do Oeste', '4110656'),
  ('PR', 'Irati', '4110706'),
  ('PR', 'Iretama', '4110805'),
  ('PR', 'Itaguajé', '4110904'),
  ('PR', 'Itaipulândia', '4110953'),
  ('PR', 'Itambaracá', '4111001'),
  ('PR', 'Itambé', '4111100'),
  ('PR', 'Itapejara D''oeste', '4111209'),
  ('PR', 'Itaperuçu', '4111258'),
  ('PR', 'Itaúna do Sul', '4111308'),
  ('PR', 'Ivaí', '4111407'),
  ('PR', 'Ivaiporã', '4111506'),
  ('PR', 'Ivaté', '4111555'),
  ('PR', 'Ivatuba', '4111605'),
  ('PR', 'Jaboti', '4111704'),
  ('PR', 'Jacarezinho', '4111803'),
  ('PR', 'Jaguapitã', '4111902'),
  ('PR', 'Jaguariaíva', '4112009'),
  ('PR', 'Jandaia do Sul', '4112108'),
  ('PR', 'Janiópolis', '4112207'),
  ('PR', 'Japira', '4112306'),
  ('PR', 'Japurá', '4112405'),
  ('PR', 'Jardim Alegre', '4112504'),
  ('PR', 'Jardim Olinda', '4112603'),
  ('PR', 'Jataizinho', '4112702'),
  ('PR', 'Jesuítas', '4112751'),
  ('PR', 'Joaquim Távora', '4112801'),
  ('PR', 'Jundiaí do Sul', '4112900'),
  ('PR', 'Juranda', '4112959'),
  ('PR', 'Jussara', '4113007'),
  ('PR', 'Kaloré', '4113106'),
  ('PR', 'Lapa', '4113205'),
  ('PR', 'Laranjal', '4113254'),
  ('PR', 'Laranjeiras do Sul', '4113304'),
  ('PR', 'Leópolis', '4113403'),
  ('PR', 'Lidianópolis', '4113429'),
  ('PR', 'Lindoeste', '4113452'),
  ('PR', 'Loanda', '4113502'),
  ('PR', 'Lobato', '4113601'),
  ('PR', 'Londrina', '4113700'),
  ('PR', 'Luiziana', '4113734'),
  ('PR', 'Lunardelli', '4113759'),
  ('PR', 'Lupionópolis', '4113809'),
  ('PR', 'Mallet', '4113908'),
  ('PR', 'Mamborê', '4114005'),
  ('PR', 'Mandaguaçu', '4114104'),
  ('PR', 'Mandaguari', '4114203'),
  ('PR', 'Mandirituba', '4114302'),
  ('PR', 'Manfrinópolis', '4114351'),
  ('PR', 'Mangueirinha', '4114401'),
  ('PR', 'Manoel Ribas', '4114500'),
  ('PR', 'Marechal Cândido Rondon', '4114609'),
  ('PR', 'Maria Helena', '4114708'),
  ('PR', 'Marialva', '4114807'),
  ('PR', 'Marilândia do Sul', '4114906'),
  ('PR', 'Marilena', '4115002'),
  ('PR', 'Mariluz', '4115101'),
  ('PR', 'Maringá', '4115200'),
  ('PR', 'Mariópolis', '4115309'),
  ('PR', 'Maripá', '4115358'),
  ('PR', 'Marmeleiro', '4115408'),
  ('PR', 'Marquinho', '4115457'),
  ('PR', 'Marumbi', '4115507'),
  ('PR', 'Matelândia', '4115606'),
  ('PR', 'Matinhos', '4115705'),
  ('PR', 'Mato Rico', '4115739'),
  ('PR', 'Mauá da Serra', '4115754'),
  ('PR', 'Medianeira', '4115804'),
  ('PR', 'Mercedes', '4115853'),
  ('PR', 'Mirador', '4115903'),
  ('PR', 'Miraselva', '4116000'),
  ('PR', 'Missal', '4116059'),
  ('PR', 'Moreira Sales', '4116109'),
  ('PR', 'Morretes', '4116208'),
  ('PR', 'Munhoz de Melo', '4116307'),
  ('PR', 'Nossa Senhora das Graças', '4116406'),
  ('PR', 'Nova Aliança do Ivaí', '4116505'),
  ('PR', 'Nova América da Colina', '4116604'),
  ('PR', 'Nova Aurora', '4116703'),
  ('PR', 'Nova Cantu', '4116802'),
  ('PR', 'Nova Esperança', '4116901'),
  ('PR', 'Nova Esperança do Sudoeste', '4116950'),
  ('PR', 'Nova Fátima', '4117008'),
  ('PR', 'Nova Laranjeiras', '4117057'),
  ('PR', 'Nova Londrina', '4117107'),
  ('PR', 'Nova Olímpia', '4117206'),
  ('PR', 'Nova Santa Bárbara', '4117214'),
  ('PR', 'Nova Santa Rosa', '4117222'),
  ('PR', 'Nova Prata do Iguaçu', '4117255'),
  ('PR', 'Nova Tebas', '4117271'),
  ('PR', 'Novo Itacolomi', '4117297'),
  ('PR', 'Ortigueira', '4117305'),
  ('PR', 'Ourizona', '4117404'),
  ('PR', 'Ouro Verde do Oeste', '4117453'),
  ('PR', 'Paiçandu', '4117503'),
  ('PR', 'Palmas', '4117602'),
  ('PR', 'Palmeira', '4117701'),
  ('PR', 'Palmital', '4117800'),
  ('PR', 'Palotina', '4117909'),
  ('PR', 'Paraíso do Norte', '4118006'),
  ('PR', 'Paranacity', '4118105'),
  ('PR', 'Paranaguá', '4118204'),
  ('PR', 'Paranapoema', '4118303'),
  ('PR', 'Paranavaí', '4118402'),
  ('PR', 'Pato Bragado', '4118451'),
  ('PR', 'Pato Branco', '4118501'),
  ('PR', 'Paula Freitas', '4118600'),
  ('PR', 'Paulo Frontin', '4118709'),
  ('PR', 'Peabiru', '4118808'),
  ('PR', 'Perobal', '4118857'),
  ('PR', 'Pérola', '4118907'),
  ('PR', 'Pérola D''oeste', '4119004'),
  ('PR', 'Piên', '4119103'),
  ('PR', 'Pinhais', '4119152'),
  ('PR', 'Pinhalão', '4119202'),
  ('PR', 'Pinhal de São Bento', '4119251'),
  ('PR', 'Pinhão', '4119301'),
  ('PR', 'Piraí do Sul', '4119400'),
  ('PR', 'Piraquara', '4119509'),
  ('PR', 'Pitanga', '4119608'),
  ('PR', 'Pitangueiras', '4119657'),
  ('PR', 'Planaltina do Paraná', '4119707'),
  ('PR', 'Planalto', '4119806'),
  ('PR', 'Ponta Grossa', '4119905'),
  ('PR', 'Pontal do Paraná', '4119954'),
  ('PR', 'Porecatu', '4120002'),
  ('PR', 'Porto Amazonas', '4120101'),
  ('PR', 'Porto Barreiro', '4120150'),
  ('PR', 'Porto Rico', '4120200'),
  ('PR', 'Porto Vitória', '4120309'),
  ('PR', 'Prado Ferreira', '4120333'),
  ('PR', 'Pranchita', '4120358'),
  ('PR', 'Presidente Castelo Branco', '4120408'),
  ('PR', 'Primeiro de Maio', '4120507'),
  ('PR', 'Prudentópolis', '4120606'),
  ('PR', 'Quarto Centenário', '4120655'),
  ('PR', 'Quatiguá', '4120705'),
  ('PR', 'Quatro Barras', '4120804'),
  ('PR', 'Quatro Pontes', '4120853'),
  ('PR', 'Quedas do Iguaçu', '4120903'),
  ('PR', 'Querência do Norte', '4121000'),
  ('PR', 'Quinta do Sol', '4121109'),
  ('PR', 'Quitandinha', '4121208'),
  ('PR', 'Ramilândia', '4121257'),
  ('PR', 'Rancho Alegre', '4121307'),
  ('PR', 'Rancho Alegre D''oeste', '4121356'),
  ('PR', 'Realeza', '4121406'),
  ('PR', 'Rebouças', '4121505'),
  ('PR', 'Renascença', '4121604'),
  ('PR', 'Reserva', '4121703'),
  ('PR', 'Reserva do Iguaçu', '4121752'),
  ('PR', 'Ribeirão Claro', '4121802'),
  ('PR', 'Ribeirão do Pinhal', '4121901'),
  ('PR', 'Rio Azul', '4122008'),
  ('PR', 'Rio Bom', '4122107'),
  ('PR', 'Rio Bonito do Iguaçu', '4122156'),
  ('PR', 'Rio Branco do Ivaí', '4122172'),
  ('PR', 'Rio Branco do Sul', '4122206'),
  ('PR', 'Rio Negro', '4122305'),
  ('PR', 'Rolândia', '4122404'),
  ('PR', 'Roncador', '4122503'),
  ('PR', 'Rondon', '4122602'),
  ('PR', 'Rosário do Ivaí', '4122651'),
  ('PR', 'Sabáudia', '4122701'),
  ('PR', 'Salgado Filho', '4122800'),
  ('PR', 'Salto do Itararé', '4122909'),
  ('PR', 'Salto do Lontra', '4123006'),
  ('PR', 'Santa Amélia', '4123105'),
  ('PR', 'Santa Cecília do Pavão', '4123204'),
  ('PR', 'Santa Cruz de Monte Castelo', '4123303'),
  ('PR', 'Santa Fé', '4123402'),
  ('PR', 'Santa Helena', '4123501'),
  ('PR', 'Santa Inês', '4123600'),
  ('PR', 'Santa Isabel do Ivaí', '4123709'),
  ('PR', 'Santa Izabel do Oeste', '4123808'),
  ('PR', 'Santa Lúcia', '4123824'),
  ('PR', 'Santa Maria do Oeste', '4123857'),
  ('PR', 'Santa Mariana', '4123907'),
  ('PR', 'Santa Mônica', '4123956'),
  ('PR', 'Santana do Itararé', '4124004'),
  ('PR', 'Santa Tereza do Oeste', '4124020'),
  ('PR', 'Santa Terezinha de Itaipu', '4124053'),
  ('PR', 'Santo Antônio da Platina', '4124103'),
  ('PR', 'Santo Antônio do Caiuá', '4124202'),
  ('PR', 'Santo Antônio do Paraíso', '4124301'),
  ('PR', 'Santo Antônio do Sudoeste', '4124400'),
  ('PR', 'Santo Inácio', '4124509'),
  ('PR', 'São Carlos do Ivaí', '4124608'),
  ('PR', 'São Jerônimo da Serra', '4124707'),
  ('PR', 'São João', '4124806'),
  ('PR', 'São João do Caiuá', '4124905'),
  ('PR', 'São João do Ivaí', '4125001'),
  ('PR', 'São João do Triunfo', '4125100'),
  ('PR', 'São Jorge D''oeste', '4125209'),
  ('PR', 'São Jorge do Ivaí', '4125308'),
  ('PR', 'São Jorge do Patrocínio', '4125357'),
  ('PR', 'São José da Boa Vista', '4125407'),
  ('PR', 'São José das Palmeiras', '4125456'),
  ('PR', 'São José dos Pinhais', '4125506'),
  ('PR', 'São Manoel do Paraná', '4125555'),
  ('PR', 'São Mateus do Sul', '4125605'),
  ('PR', 'São Miguel do Iguaçu', '4125704'),
  ('PR', 'São Pedro do Iguaçu', '4125753'),
  ('PR', 'São Pedro do Ivaí', '4125803'),
  ('PR', 'São Pedro do Paraná', '4125902'),
  ('PR', 'São Sebastião da Amoreira', '4126009'),
  ('PR', 'São Tomé', '4126108'),
  ('PR', 'Sapopema', '4126207'),
  ('PR', 'Sarandi', '4126256'),
  ('PR', 'Saudade do Iguaçu', '4126272'),
  ('PR', 'Sengés', '4126306'),
  ('PR', 'Serranópolis do Iguaçu', '4126355'),
  ('PR', 'Sertaneja', '4126405'),
  ('PR', 'Sertanópolis', '4126504'),
  ('PR', 'Siqueira Campos', '4126603'),
  ('PR', 'Sulina', '4126652'),
  ('PR', 'Tamarana', '4126678'),
  ('PR', 'Tamboara', '4126702'),
  ('PR', 'Tapejara', '4126801'),
  ('PR', 'Tapira', '4126900'),
  ('PR', 'Teixeira Soares', '4127007'),
  ('PR', 'Telêmaco Borba', '4127106'),
  ('PR', 'Terra Boa', '4127205'),
  ('PR', 'Terra Rica', '4127304'),
  ('PR', 'Terra Roxa', '4127403'),
  ('PR', 'Tibagi', '4127502'),
  ('PR', 'Tijucas do Sul', '4127601'),
  ('PR', 'Toledo', '4127700'),
  ('PR', 'Tomazina', '4127809'),
  ('PR', 'Três Barras do Paraná', '4127858'),
  ('PR', 'Tunas do Paraná', '4127882'),
  ('PR', 'Tuneiras do Oeste', '4127908'),
  ('PR', 'Tupãssi', '4127957'),
  ('PR', 'Turvo', '4127965'),
  ('PR', 'Ubiratã', '4128005'),
  ('PR', 'Umuarama', '4128104'),
  ('PR', 'União da Vitória', '4128203'),
  ('PR', 'Uniflor', '4128302'),
  ('PR', 'Uraí', '4128401'),
  ('PR', 'Wenceslau Braz', '4128500'),
  ('PR', 'Ventania', '4128534'),
  ('PR', 'Vera Cruz do Oeste', '4128559'),
  ('PR', 'Verê', '4128609'),
  ('PR', 'Alto Paraíso', '4128625'),
  ('PR', 'doutor Ulysses', '4128633'),
  ('PR', 'Virmond', '4128658'),
  ('PR', 'Vitorino', '4128708'),
  ('PR', 'Xambrê', '4128807'),
  ('SC', 'Abdon Batista', '4200051'),
  ('SC', 'Abelardo Luz', '4200101'),
  ('SC', 'Agrolândia', '4200200'),
  ('SC', 'Agronômica', '4200309'),
  ('SC', 'Água doce', '4200408'),
  ('SC', 'Águas de Chapecó', '4200507'),
  ('SC', 'Águas Frias', '4200556'),
  ('SC', 'Águas Mornas', '4200606'),
  ('SC', 'Alfredo Wagner', '4200705'),
  ('SC', 'Alto Bela Vista', '4200754'),
  ('SC', 'Anchieta', '4200804'),
  ('SC', 'Angelina', '4200903'),
  ('SC', 'Anita Garibaldi', '4201000'),
  ('SC', 'Anitápolis', '4201109'),
  ('SC', 'Antônio Carlos', '4201208'),
  ('SC', 'Apiúna', '4201257'),
  ('SC', 'Arabutã', '4201273'),
  ('SC', 'Araquari', '4201307'),
  ('SC', 'Araranguá', '4201406'),
  ('SC', 'Armazém', '4201505'),
  ('SC', 'Arroio Trinta', '4201604'),
  ('SC', 'Arvoredo', '4201653'),
  ('SC', 'Ascurra', '4201703'),
  ('SC', 'Atalanta', '4201802'),
  ('SC', 'Aurora', '4201901'),
  ('SC', 'Balneário Arroio do Silva', '4201950'),
  ('SC', 'Balneário Camboriú', '4202008'),
  ('SC', 'Balneário Barra do Sul', '4202057'),
  ('SC', 'Balneário Gaivota', '4202073'),
  ('SC', 'Bandeirante', '4202081'),
  ('SC', 'Barra Bonita', '4202099'),
  ('SC', 'Barra Velha', '4202107'),
  ('SC', 'Bela Vista do Toldo', '4202131'),
  ('SC', 'Belmonte', '4202156'),
  ('SC', 'Benedito Novo', '4202206'),
  ('SC', 'Biguaçu', '4202305'),
  ('SC', 'Blumenau', '4202404'),
  ('SC', 'Bocaina do Sul', '4202438'),
  ('SC', 'Bombinhas', '4202453'),
  ('SC', 'Bom Jardim da Serra', '4202503'),
  ('SC', 'Bom Jesus', '4202537'),
  ('SC', 'Bom Jesus do Oeste', '4202578'),
  ('SC', 'Bom Retiro', '4202602'),
  ('SC', 'Botuverá', '4202701'),
  ('SC', 'Braço do Norte', '4202800'),
  ('SC', 'Braço do Trombudo', '4202859'),
  ('SC', 'Brunópolis', '4202875'),
  ('SC', 'Brusque', '4202909'),
  ('SC', 'Caçador', '4203006'),
  ('SC', 'Caibi', '4203105'),
  ('SC', 'Calmon', '4203154'),
  ('SC', 'Camboriú', '4203204'),
  ('SC', 'Capão Alto', '4203253'),
  ('SC', 'Campo Alegre', '4203303'),
  ('SC', 'Campo Belo do Sul', '4203402'),
  ('SC', 'Campo Erê', '4203501'),
  ('SC', 'Campos Novos', '4203600'),
  ('SC', 'Canelinha', '4203709'),
  ('SC', 'Canoinhas', '4203808'),
  ('SC', 'Capinzal', '4203907'),
  ('SC', 'Capivari de Baixo', '4203956'),
  ('SC', 'Catanduvas', '4204004'),
  ('SC', 'Caxambu do Sul', '4204103'),
  ('SC', 'Celso Ramos', '4204152'),
  ('SC', 'Cerro Negro', '4204178'),
  ('SC', 'Chapadão do Lageado', '4204194'),
  ('SC', 'Chapecó', '4204202'),
  ('SC', 'Cocal do Sul', '4204251'),
  ('SC', 'Concórdia', '4204301'),
  ('SC', 'Cordilheira Alta', '4204350'),
  ('SC', 'Coronel Freitas', '4204400'),
  ('SC', 'Coronel Martins', '4204459'),
  ('SC', 'Corupá', '4204509'),
  ('SC', 'Correia Pinto', '4204558'),
  ('SC', 'Criciúma', '4204608'),
  ('SC', 'Cunha Porã', '4204707'),
  ('SC', 'Cunhataí', '4204756'),
  ('SC', 'Curitibanos', '4204806'),
  ('SC', 'descanso', '4204905'),
  ('SC', 'Dionísio Cerqueira', '4205001'),
  ('SC', 'dona Emma', '4205100'),
  ('SC', 'doutor Pedrinho', '4205159'),
  ('SC', 'Entre Rios', '4205175'),
  ('SC', 'Ermo', '4205191'),
  ('SC', 'Erval Velho', '4205209'),
  ('SC', 'Faxinal dos Guedes', '4205308'),
  ('SC', 'Flor do Sertão', '4205357'),
  ('SC', 'Florianópolis', '4205407'),
  ('SC', 'Formosa do Sul', '4205431'),
  ('SC', 'Forquilhinha', '4205456'),
  ('SC', 'Fraiburgo', '4205506'),
  ('SC', 'Frei Rogério', '4205555'),
  ('SC', 'Galvão', '4205605'),
  ('SC', 'Garopaba', '4205704'),
  ('SC', 'Garuva', '4205803'),
  ('SC', 'Gaspar', '4205902'),
  ('SC', 'Governador Celso Ramos', '4206009'),
  ('SC', 'Grão Pará', '4206108'),
  ('SC', 'Gravatal', '4206207'),
  ('SC', 'Guabiruba', '4206306'),
  ('SC', 'Guaraciaba', '4206405'),
  ('SC', 'Guaramirim', '4206504'),
  ('SC', 'Guarujá do Sul', '4206603'),
  ('SC', 'Guatambú', '4206652'),
  ('SC', 'Herval D''oeste', '4206702'),
  ('SC', 'Ibiam', '4206751'),
  ('SC', 'Ibicaré', '4206801'),
  ('SC', 'Ibirama', '4206900'),
  ('SC', 'Içara', '4207007'),
  ('SC', 'Ilhota', '4207106'),
  ('SC', 'Imaruí', '4207205'),
  ('SC', 'Imbituba', '4207304'),
  ('SC', 'Imbuia', '4207403'),
  ('SC', 'Indaial', '4207502'),
  ('SC', 'Iomerê', '4207577'),
  ('SC', 'Ipira', '4207601'),
  ('SC', 'Iporã do Oeste', '4207650'),
  ('SC', 'Ipuaçu', '4207684'),
  ('SC', 'Ipumirim', '4207700'),
  ('SC', 'Iraceminha', '4207759'),
  ('SC', 'Irani', '4207809'),
  ('SC', 'Irati', '4207858'),
  ('SC', 'Irineópolis', '4207908'),
  ('SC', 'Itá', '4208005'),
  ('SC', 'Itaiópolis', '4208104'),
  ('SC', 'Itajaí', '4208203'),
  ('SC', 'Itapema', '4208302'),
  ('SC', 'Itapiranga', '4208401'),
  ('SC', 'Itapoá', '4208450'),
  ('SC', 'Ituporanga', '4208500'),
  ('SC', 'Jaborá', '4208609'),
  ('SC', 'Jacinto Machado', '4208708'),
  ('SC', 'Jaguaruna', '4208807'),
  ('SC', 'Jaraguá do Sul', '4208906'),
  ('SC', 'Jardinópolis', '4208955'),
  ('SC', 'Joaçaba', '4209003'),
  ('SC', 'Joinville', '4209102'),
  ('SC', 'José Boiteux', '4209151'),
  ('SC', 'Jupiá', '4209177'),
  ('SC', 'Lacerdópolis', '4209201'),
  ('SC', 'Lages', '4209300'),
  ('SC', 'Laguna', '4209409'),
  ('SC', 'Lajeado Grande', '4209458'),
  ('SC', 'Laurentino', '4209508'),
  ('SC', 'Lauro Muller', '4209607'),
  ('SC', 'Lebon Régis', '4209706'),
  ('SC', 'Leoberto Leal', '4209805'),
  ('SC', 'Lindóia do Sul', '4209854'),
  ('SC', 'Lontras', '4209904'),
  ('SC', 'Luiz Alves', '4210001'),
  ('SC', 'Luzerna', '4210035'),
  ('SC', 'Macieira', '4210050'),
  ('SC', 'Mafra', '4210100'),
  ('SC', 'Major Gercino', '4210209'),
  ('SC', 'Major Vieira', '4210308'),
  ('SC', 'Maracajá', '4210407'),
  ('SC', 'Maravilha', '4210506'),
  ('SC', 'Marema', '4210555'),
  ('SC', 'Massaranduba', '4210605'),
  ('SC', 'Matos Costa', '4210704'),
  ('SC', 'Meleiro', '4210803'),
  ('SC', 'Mirim doce', '4210852'),
  ('SC', 'Modelo', '4210902'),
  ('SC', 'Mondaí', '4211009'),
  ('SC', 'Monte Carlo', '4211058'),
  ('SC', 'Monte Castelo', '4211108'),
  ('SC', 'Morro da Fumaça', '4211207'),
  ('SC', 'Morro Grande', '4211256'),
  ('SC', 'Navegantes', '4211306'),
  ('SC', 'Nova Erechim', '4211405'),
  ('SC', 'Nova Itaberaba', '4211454'),
  ('SC', 'Nova Trento', '4211504'),
  ('SC', 'Nova Veneza', '4211603'),
  ('SC', 'Novo Horizonte', '4211652'),
  ('SC', 'Orleans', '4211702'),
  ('SC', 'Otacílio Costa', '4211751'),
  ('SC', 'Ouro', '4211801'),
  ('SC', 'Ouro Verde', '4211850'),
  ('SC', 'Paial', '4211876'),
  ('SC', 'Painel', '4211892'),
  ('SC', 'Palhoça', '4211900'),
  ('SC', 'Palma Sola', '4212007'),
  ('SC', 'Palmeira', '4212056'),
  ('SC', 'Palmitos', '4212106'),
  ('SC', 'Papanduva', '4212205'),
  ('SC', 'Paraíso', '4212239'),
  ('SC', 'Passo de Torres', '4212254'),
  ('SC', 'Passos Maia', '4212270'),
  ('SC', 'Paulo Lopes', '4212304'),
  ('SC', 'Pedras Grandes', '4212403'),
  ('SC', 'Penha', '4212502'),
  ('SC', 'Peritiba', '4212601'),
  ('SC', 'Pescaria Brava', '4212650'),
  ('SC', 'Petrolândia', '4212700'),
  ('SC', 'Balneário Piçarras', '4212809'),
  ('SC', 'Pinhalzinho', '4212908'),
  ('SC', 'Pinheiro Preto', '4213005'),
  ('SC', 'Piratuba', '4213104'),
  ('SC', 'Planalto Alegre', '4213153'),
  ('SC', 'Pomerode', '4213203'),
  ('SC', 'Ponte Alta', '4213302'),
  ('SC', 'Ponte Alta do Norte', '4213351'),
  ('SC', 'Ponte Serrada', '4213401'),
  ('SC', 'Porto Belo', '4213500'),
  ('SC', 'Porto União', '4213609'),
  ('SC', 'Pouso Redondo', '4213708'),
  ('SC', 'Praia Grande', '4213807'),
  ('SC', 'Presidente Castello Branco', '4213906'),
  ('SC', 'Presidente Getúlio', '4214003'),
  ('SC', 'Presidente Nereu', '4214102'),
  ('SC', 'Princesa', '4214151'),
  ('SC', 'Quilombo', '4214201'),
  ('SC', 'Rancho Queimado', '4214300'),
  ('SC', 'Rio das Antas', '4214409'),
  ('SC', 'Rio do Campo', '4214508'),
  ('SC', 'Rio do Oeste', '4214607'),
  ('SC', 'Rio dos Cedros', '4214706'),
  ('SC', 'Rio do Sul', '4214805'),
  ('SC', 'Rio Fortuna', '4214904'),
  ('SC', 'Rio Negrinho', '4215000'),
  ('SC', 'Rio Rufino', '4215059'),
  ('SC', 'Riqueza', '4215075'),
  ('SC', 'Rodeio', '4215109'),
  ('SC', 'Romelândia', '4215208'),
  ('SC', 'Salete', '4215307'),
  ('SC', 'Saltinho', '4215356'),
  ('SC', 'Salto Veloso', '4215406'),
  ('SC', 'Sangão', '4215455'),
  ('SC', 'Santa Cecília', '4215505'),
  ('SC', 'Santa Helena', '4215554'),
  ('SC', 'Santa Rosa de Lima', '4215604'),
  ('SC', 'Santa Rosa do Sul', '4215653'),
  ('SC', 'Santa Terezinha', '4215679'),
  ('SC', 'Santa Terezinha do Progresso', '4215687'),
  ('SC', 'Santiago do Sul', '4215695'),
  ('SC', 'Santo Amaro da Imperatriz', '4215703'),
  ('SC', 'São Bernardino', '4215752'),
  ('SC', 'São Bento do Sul', '4215802'),
  ('SC', 'São Bonifácio', '4215901'),
  ('SC', 'São Carlos', '4216008'),
  ('SC', 'São Cristovão do Sul', '4216057'),
  ('SC', 'São domingos', '4216107'),
  ('SC', 'São Francisco do Sul', '4216206'),
  ('SC', 'São João do Oeste', '4216255'),
  ('SC', 'São João Batista', '4216305'),
  ('SC', 'São João do Itaperiú', '4216354'),
  ('SC', 'São João do Sul', '4216404'),
  ('SC', 'São Joaquim', '4216503'),
  ('SC', 'São José', '4216602'),
  ('SC', 'São José do Cedro', '4216701'),
  ('SC', 'São José do Cerrito', '4216800'),
  ('SC', 'São Lourenço do Oeste', '4216909'),
  ('SC', 'São Ludgero', '4217006'),
  ('SC', 'São Martinho', '4217105'),
  ('SC', 'São Miguel da Boa Vista', '4217154'),
  ('SC', 'São Miguel do Oeste', '4217204'),
  ('SC', 'São Pedro de Alcântara', '4217253'),
  ('SC', 'Saudades', '4217303'),
  ('SC', 'Schroeder', '4217402'),
  ('SC', 'Seara', '4217501'),
  ('SC', 'Serra Alta', '4217550'),
  ('SC', 'Siderópolis', '4217600'),
  ('SC', 'Sombrio', '4217709'),
  ('SC', 'Sul Brasil', '4217758'),
  ('SC', 'Taió', '4217808'),
  ('SC', 'Tangará', '4217907'),
  ('SC', 'Tigrinhos', '4217956'),
  ('SC', 'Tijucas', '4218004'),
  ('SC', 'Timbé do Sul', '4218103'),
  ('SC', 'Timbó', '4218202'),
  ('SC', 'Timbó Grande', '4218251'),
  ('SC', 'Três Barras', '4218301'),
  ('SC', 'Treviso', '4218350'),
  ('SC', 'Treze de Maio', '4218400'),
  ('SC', 'Treze Tílias', '4218509'),
  ('SC', 'Trombudo Central', '4218608'),
  ('SC', 'Tubarão', '4218707'),
  ('SC', 'Tunápolis', '4218756'),
  ('SC', 'Turvo', '4218806'),
  ('SC', 'União do Oeste', '4218855'),
  ('SC', 'Urubici', '4218905'),
  ('SC', 'Urupema', '4218954'),
  ('SC', 'Urussanga', '4219002'),
  ('SC', 'Vargeão', '4219101'),
  ('SC', 'Vargem', '4219150'),
  ('SC', 'Vargem Bonita', '4219176'),
  ('SC', 'Vidal Ramos', '4219200'),
  ('SC', 'Videira', '4219309'),
  ('SC', 'Vitor Meireles', '4219358'),
  ('SC', 'Witmarsum', '4219408'),
  ('SC', 'Xanxerê', '4219507'),
  ('SC', 'Xavantina', '4219606'),
  ('SC', 'Xaxim', '4219705'),
  ('SC', 'Zortéa', '4219853'),
  ('SC', 'Balneário Rincão', '4220000'),
  ('RS', 'Aceguá', '4300034'),
  ('RS', 'Água Santa', '4300059'),
  ('RS', 'Agudo', '4300109'),
  ('RS', 'Ajuricaba', '4300208'),
  ('RS', 'Alecrim', '4300307'),
  ('RS', 'Alegrete', '4300406'),
  ('RS', 'Alegria', '4300455'),
  ('RS', 'Almirante Tamandaré do Sul', '4300471'),
  ('RS', 'Alpestre', '4300505'),
  ('RS', 'Alto Alegre', '4300554'),
  ('RS', 'Alto Feliz', '4300570'),
  ('RS', 'Alvorada', '4300604'),
  ('RS', 'Amaral Ferrador', '4300638'),
  ('RS', 'Ametista do Sul', '4300646'),
  ('RS', 'André da Rocha', '4300661'),
  ('RS', 'Anta Gorda', '4300703'),
  ('RS', 'Antônio Prado', '4300802'),
  ('RS', 'Arambaré', '4300851'),
  ('RS', 'Araricá', '4300877'),
  ('RS', 'Aratiba', '4300901'),
  ('RS', 'Arroio do Meio', '4301008'),
  ('RS', 'Arroio do Sal', '4301057'),
  ('RS', 'Arroio do Padre', '4301073'),
  ('RS', 'Arroio dos Ratos', '4301107'),
  ('RS', 'Arroio do Tigre', '4301206'),
  ('RS', 'Arroio Grande', '4301305'),
  ('RS', 'Arvorezinha', '4301404'),
  ('RS', 'Augusto Pestana', '4301503'),
  ('RS', 'Áurea', '4301552'),
  ('RS', 'Bagé', '4301602'),
  ('RS', 'Balneário Pinhal', '4301636'),
  ('RS', 'Barão', '4301651'),
  ('RS', 'Barão de Cotegipe', '4301701'),
  ('RS', 'Barão do Triunfo', '4301750'),
  ('RS', 'Barracão', '4301800'),
  ('RS', 'Barra do Guarita', '4301859'),
  ('RS', 'Barra do Quaraí', '4301875'),
  ('RS', 'Barra do Ribeiro', '4301909'),
  ('RS', 'Barra do Rio Azul', '4301925'),
  ('RS', 'Barra Funda', '4301958'),
  ('RS', 'Barros Cassal', '4302006'),
  ('RS', 'Benjamin Constant do Sul', '4302055'),
  ('RS', 'Bento Gonçalves', '4302105'),
  ('RS', 'Boa Vista das Missões', '4302154'),
  ('RS', 'Boa Vista do Buricá', '4302204'),
  ('RS', 'Boa Vista do Cadeado', '4302220'),
  ('RS', 'Boa Vista do Incra', '4302238'),
  ('RS', 'Boa Vista do Sul', '4302253'),
  ('RS', 'Bom Jesus', '4302303'),
  ('RS', 'Bom Princípio', '4302352'),
  ('RS', 'Bom Progresso', '4302378'),
  ('RS', 'Bom Retiro do Sul', '4302402'),
  ('RS', 'Boqueirão do Leão', '4302451'),
  ('RS', 'Bossoroca', '4302501'),
  ('RS', 'Bozano', '4302584'),
  ('RS', 'Braga', '4302600'),
  ('RS', 'Brochier', '4302659'),
  ('RS', 'Butiá', '4302709'),
  ('RS', 'Caçapava do Sul', '4302808'),
  ('RS', 'Cacequi', '4302907'),
  ('RS', 'Cachoeira do Sul', '4303004'),
  ('RS', 'Cachoeirinha', '4303103'),
  ('RS', 'Cacique doble', '4303202'),
  ('RS', 'Caibaté', '4303301'),
  ('RS', 'Caiçara', '4303400'),
  ('RS', 'Camaquã', '4303509'),
  ('RS', 'Camargo', '4303558'),
  ('RS', 'Cambará do Sul', '4303608'),
  ('RS', 'Campestre da Serra', '4303673'),
  ('RS', 'Campina das Missões', '4303707'),
  ('RS', 'Campinas do Sul', '4303806'),
  ('RS', 'Campo Bom', '4303905'),
  ('RS', 'Campo Novo', '4304002'),
  ('RS', 'Campos Borges', '4304101'),
  ('RS', 'Candelária', '4304200'),
  ('RS', 'Cândido Godói', '4304309'),
  ('RS', 'Candiota', '4304358'),
  ('RS', 'Canela', '4304408'),
  ('RS', 'Canguçu', '4304507'),
  ('RS', 'Canoas', '4304606'),
  ('RS', 'Canudos do Vale', '4304614'),
  ('RS', 'Capão Bonito do Sul', '4304622'),
  ('RS', 'Capão da Canoa', '4304630'),
  ('RS', 'Capão do Cipó', '4304655'),
  ('RS', 'Capão do Leão', '4304663'),
  ('RS', 'Capivari do Sul', '4304671'),
  ('RS', 'Capela de Santana', '4304689'),
  ('RS', 'Capitão', '4304697'),
  ('RS', 'Carazinho', '4304705'),
  ('RS', 'Caraá', '4304713'),
  ('RS', 'Carlos Barbosa', '4304804'),
  ('RS', 'Carlos Gomes', '4304853'),
  ('RS', 'Casca', '4304903'),
  ('RS', 'Caseiros', '4304952'),
  ('RS', 'Catuípe', '4305009'),
  ('RS', 'Caxias do Sul', '4305108'),
  ('RS', 'Centenário', '4305116'),
  ('RS', 'Cerrito', '4305124'),
  ('RS', 'Cerro Branco', '4305132'),
  ('RS', 'Cerro Grande', '4305157'),
  ('RS', 'Cerro Grande do Sul', '4305173'),
  ('RS', 'Cerro Largo', '4305207'),
  ('RS', 'Chapada', '4305306'),
  ('RS', 'Charqueadas', '4305355'),
  ('RS', 'Charrua', '4305371'),
  ('RS', 'Chiapetta', '4305405'),
  ('RS', 'Chuí', '4305439'),
  ('RS', 'Chuvisca', '4305447'),
  ('RS', 'Cidreira', '4305454'),
  ('RS', 'Ciríaco', '4305504'),
  ('RS', 'Colinas', '4305587'),
  ('RS', 'Colorado', '4305603'),
  ('RS', 'Condor', '4305702'),
  ('RS', 'Constantina', '4305801'),
  ('RS', 'Coqueiro Baixo', '4305835'),
  ('RS', 'Coqueiros do Sul', '4305850'),
  ('RS', 'Coronel Barros', '4305871'),
  ('RS', 'Coronel Bicaco', '4305900'),
  ('RS', 'Coronel Pilar', '4305934'),
  ('RS', 'Cotiporã', '4305959'),
  ('RS', 'Coxilha', '4305975'),
  ('RS', 'Crissiumal', '4306007'),
  ('RS', 'Cristal', '4306056'),
  ('RS', 'Cristal do Sul', '4306072'),
  ('RS', 'Cruz Alta', '4306106'),
  ('RS', 'Cruzaltense', '4306130'),
  ('RS', 'Cruzeiro do Sul', '4306205'),
  ('RS', 'david Canabarro', '4306304'),
  ('RS', 'derrubadas', '4306320'),
  ('RS', 'dezesseis de Novembro', '4306353'),
  ('RS', 'Dilermando de Aguiar', '4306379'),
  ('RS', 'dois Irmãos', '4306403'),
  ('RS', 'dois Irmãos das Missões', '4306429'),
  ('RS', 'dois Lajeados', '4306452'),
  ('RS', 'dom Feliciano', '4306502'),
  ('RS', 'dom Pedro de Alcântara', '4306551'),
  ('RS', 'dom Pedrito', '4306601'),
  ('RS', 'dona Francisca', '4306700'),
  ('RS', 'doutor Maurício Cardoso', '4306734'),
  ('RS', 'doutor Ricardo', '4306759'),
  ('RS', 'Eldorado do Sul', '4306767'),
  ('RS', 'Encantado', '4306809'),
  ('RS', 'Encruzilhada do Sul', '4306908'),
  ('RS', 'Engenho Velho', '4306924'),
  ('RS', 'Entre-Ijuís', '4306932'),
  ('RS', 'Entre Rios do Sul', '4306957'),
  ('RS', 'Erebango', '4306973'),
  ('RS', 'Erechim', '4307005'),
  ('RS', 'Ernestina', '4307054'),
  ('RS', 'Herval', '4307104'),
  ('RS', 'Erval Grande', '4307203'),
  ('RS', 'Erval Seco', '4307302'),
  ('RS', 'Esmeralda', '4307401'),
  ('RS', 'Esperança do Sul', '4307450'),
  ('RS', 'Espumoso', '4307500'),
  ('RS', 'Estação', '4307559'),
  ('RS', 'Estância Velha', '4307609'),
  ('RS', 'Esteio', '4307708'),
  ('RS', 'Estrela', '4307807'),
  ('RS', 'Estrela Velha', '4307815'),
  ('RS', 'Eugênio de Castro', '4307831'),
  ('RS', 'Fagundes Varela', '4307864'),
  ('RS', 'Farroupilha', '4307906'),
  ('RS', 'Faxinal do Soturno', '4308003'),
  ('RS', 'Faxinalzinho', '4308052'),
  ('RS', 'Fazenda Vilanova', '4308078'),
  ('RS', 'Feliz', '4308102'),
  ('RS', 'Flores da Cunha', '4308201'),
  ('RS', 'Floriano Peixoto', '4308250'),
  ('RS', 'Fontoura Xavier', '4308300'),
  ('RS', 'Formigueiro', '4308409'),
  ('RS', 'Forquetinha', '4308433'),
  ('RS', 'Fortaleza dos Valos', '4308458'),
  ('RS', 'Frederico Westphalen', '4308508'),
  ('RS', 'Garibaldi', '4308607'),
  ('RS', 'Garruchos', '4308656'),
  ('RS', 'Gaurama', '4308706'),
  ('RS', 'General Câmara', '4308805'),
  ('RS', 'Gentil', '4308854'),
  ('RS', 'Getúlio Vargas', '4308904'),
  ('RS', 'Giruá', '4309001'),
  ('RS', 'Glorinha', '4309050'),
  ('RS', 'Gramado', '4309100'),
  ('RS', 'Gramado dos Loureiros', '4309126'),
  ('RS', 'Gramado Xavier', '4309159'),
  ('RS', 'Gravataí', '4309209'),
  ('RS', 'Guabiju', '4309258'),
  ('RS', 'Guaíba', '4309308'),
  ('RS', 'Guaporé', '4309407'),
  ('RS', 'Guarani das Missões', '4309506'),
  ('RS', 'Harmonia', '4309555'),
  ('RS', 'Herveiras', '4309571'),
  ('RS', 'Horizontina', '4309605'),
  ('RS', 'Hulha Negra', '4309654'),
  ('RS', 'Humaitá', '4309704'),
  ('RS', 'Ibarama', '4309753'),
  ('RS', 'Ibiaçá', '4309803'),
  ('RS', 'Ibiraiaras', '4309902'),
  ('RS', 'Ibirapuitã', '4309951'),
  ('RS', 'Ibirubá', '4310009'),
  ('RS', 'Igrejinha', '4310108'),
  ('RS', 'Ijuí', '4310207'),
  ('RS', 'Ilópolis', '4310306'),
  ('RS', 'Imbé', '4310330'),
  ('RS', 'Imigrante', '4310363'),
  ('RS', 'Independência', '4310405'),
  ('RS', 'Inhacorá', '4310413'),
  ('RS', 'Ipê', '4310439'),
  ('RS', 'Ipiranga do Sul', '4310462'),
  ('RS', 'Iraí', '4310504'),
  ('RS', 'Itaara', '4310538'),
  ('RS', 'Itacurubi', '4310553'),
  ('RS', 'Itapuca', '4310579'),
  ('RS', 'Itaqui', '4310603'),
  ('RS', 'Itati', '4310652'),
  ('RS', 'Itatiba do Sul', '4310702'),
  ('RS', 'Ivorá', '4310751'),
  ('RS', 'Ivoti', '4310801'),
  ('RS', 'Jaboticaba', '4310850'),
  ('RS', 'Jacuizinho', '4310876'),
  ('RS', 'Jacutinga', '4310900'),
  ('RS', 'Jaguarão', '4311007'),
  ('RS', 'Jaguari', '4311106'),
  ('RS', 'Jaquirana', '4311122'),
  ('RS', 'Jari', '4311130'),
  ('RS', 'Jóia', '4311155'),
  ('RS', 'Júlio de Castilhos', '4311205'),
  ('RS', 'Lagoa Bonita do Sul', '4311239'),
  ('RS', 'Lagoão', '4311254'),
  ('RS', 'Lagoa dos Três Cantos', '4311270'),
  ('RS', 'Lagoa Vermelha', '4311304'),
  ('RS', 'Lajeado', '4311403'),
  ('RS', 'Lajeado do Bugre', '4311429'),
  ('RS', 'Lavras do Sul', '4311502'),
  ('RS', 'Liberato Salzano', '4311601'),
  ('RS', 'Lindolfo Collor', '4311627'),
  ('RS', 'Linha Nova', '4311643'),
  ('RS', 'Machadinho', '4311700'),
  ('RS', 'Maçambará', '4311718'),
  ('RS', 'Mampituba', '4311734'),
  ('RS', 'Manoel Viana', '4311759'),
  ('RS', 'Maquiné', '4311775'),
  ('RS', 'Maratá', '4311791'),
  ('RS', 'Marau', '4311809'),
  ('RS', 'Marcelino Ramos', '4311908'),
  ('RS', 'Mariana Pimentel', '4311981'),
  ('RS', 'Mariano Moro', '4312005'),
  ('RS', 'Marques de Souza', '4312054'),
  ('RS', 'Mata', '4312104'),
  ('RS', 'Mato Castelhano', '4312138'),
  ('RS', 'Mato Leitão', '4312153'),
  ('RS', 'Mato Queimado', '4312179'),
  ('RS', 'Maximiliano de Almeida', '4312203'),
  ('RS', 'Minas do Leão', '4312252'),
  ('RS', 'Miraguaí', '4312302'),
  ('RS', 'Montauri', '4312351'),
  ('RS', 'Monte Alegre dos Campos', '4312377'),
  ('RS', 'Monte Belo do Sul', '4312385'),
  ('RS', 'Montenegro', '4312401'),
  ('RS', 'Mormaço', '4312427'),
  ('RS', 'Morrinhos do Sul', '4312443'),
  ('RS', 'Morro Redondo', '4312450'),
  ('RS', 'Morro Reuter', '4312476'),
  ('RS', 'Mostardas', '4312500'),
  ('RS', 'Muçum', '4312609'),
  ('RS', 'Muitos Capões', '4312617'),
  ('RS', 'Muliterno', '4312625'),
  ('RS', 'Não-Me-Toque', '4312658'),
  ('RS', 'Nicolau Vergueiro', '4312674'),
  ('RS', 'Nonoai', '4312708'),
  ('RS', 'Nova Alvorada', '4312757'),
  ('RS', 'Nova Araçá', '4312807'),
  ('RS', 'Nova Bassano', '4312906'),
  ('RS', 'Nova Boa Vista', '4312955'),
  ('RS', 'Nova Bréscia', '4313003'),
  ('RS', 'Nova Candelária', '4313011'),
  ('RS', 'Nova Esperança do Sul', '4313037'),
  ('RS', 'Nova Hartz', '4313060'),
  ('RS', 'Nova Pádua', '4313086'),
  ('RS', 'Nova Palma', '4313102'),
  ('RS', 'Nova Petrópolis', '4313201'),
  ('RS', 'Nova Prata', '4313300'),
  ('RS', 'Nova Ramada', '4313334'),
  ('RS', 'Nova Roma do Sul', '4313359'),
  ('RS', 'Nova Santa Rita', '4313375'),
  ('RS', 'Novo Cabrais', '4313391'),
  ('RS', 'Novo Hamburgo', '4313409'),
  ('RS', 'Novo Machado', '4313425'),
  ('RS', 'Novo Tiradentes', '4313441'),
  ('RS', 'Novo Xingu', '4313466'),
  ('RS', 'Novo Barreiro', '4313490'),
  ('RS', 'Osório', '4313508'),
  ('RS', 'Paim Filho', '4313607'),
  ('RS', 'Palmares do Sul', '4313656'),
  ('RS', 'Palmeira das Missões', '4313706'),
  ('RS', 'Palmitinho', '4313805'),
  ('RS', 'Panambi', '4313904'),
  ('RS', 'Pantano Grande', '4313953'),
  ('RS', 'Paraí', '4314001'),
  ('RS', 'Paraíso do Sul', '4314027'),
  ('RS', 'Pareci Novo', '4314035'),
  ('RS', 'Parobé', '4314050'),
  ('RS', 'Passa Sete', '4314068'),
  ('RS', 'Passo do Sobrado', '4314076'),
  ('RS', 'Passo Fundo', '4314100'),
  ('RS', 'Paulo Bento', '4314134'),
  ('RS', 'Paverama', '4314159'),
  ('RS', 'Pedras Altas', '4314175'),
  ('RS', 'Pedro Osório', '4314209'),
  ('RS', 'Pejuçara', '4314308'),
  ('RS', 'Pelotas', '4314407'),
  ('RS', 'Picada Café', '4314423'),
  ('RS', 'Pinhal', '4314456'),
  ('RS', 'Pinhal da Serra', '4314464'),
  ('RS', 'Pinhal Grande', '4314472'),
  ('RS', 'Pinheirinho do Vale', '4314498'),
  ('RS', 'Pinheiro Machado', '4314506'),
  ('RS', 'Pinto Bandeira', '4314548'),
  ('RS', 'Pirapó', '4314555'),
  ('RS', 'Piratini', '4314605'),
  ('RS', 'Planalto', '4314704'),
  ('RS', 'Poço das Antas', '4314753'),
  ('RS', 'Pontão', '4314779'),
  ('RS', 'Ponte Preta', '4314787'),
  ('RS', 'Portão', '4314803'),
  ('RS', 'Porto Alegre', '4314902'),
  ('RS', 'Porto Lucena', '4315008'),
  ('RS', 'Porto Mauá', '4315057'),
  ('RS', 'Porto Vera Cruz', '4315073'),
  ('RS', 'Porto Xavier', '4315107'),
  ('RS', 'Pouso Novo', '4315131'),
  ('RS', 'Presidente Lucena', '4315149'),
  ('RS', 'Progresso', '4315156'),
  ('RS', 'Protásio Alves', '4315172'),
  ('RS', 'Putinga', '4315206'),
  ('RS', 'Quaraí', '4315305'),
  ('RS', 'Quatro Irmãos', '4315313'),
  ('RS', 'Quevedos', '4315321'),
  ('RS', 'Quinze de Novembro', '4315354'),
  ('RS', 'Redentora', '4315404'),
  ('RS', 'Relvado', '4315453'),
  ('RS', 'Restinga Seca', '4315503'),
  ('RS', 'Rio dos Índios', '4315552'),
  ('RS', 'Rio Grande', '4315602'),
  ('RS', 'Rio Pardo', '4315701'),
  ('RS', 'Riozinho', '4315750'),
  ('RS', 'Roca Sales', '4315800'),
  ('RS', 'Rodeio Bonito', '4315909'),
  ('RS', 'Rolador', '4315958'),
  ('RS', 'Rolante', '4316006'),
  ('RS', 'Ronda Alta', '4316105'),
  ('RS', 'Rondinha', '4316204'),
  ('RS', 'Roque Gonzales', '4316303'),
  ('RS', 'Rosário do Sul', '4316402'),
  ('RS', 'Sagrada Família', '4316428'),
  ('RS', 'Saldanha Marinho', '4316436'),
  ('RS', 'Salto do Jacuí', '4316451'),
  ('RS', 'Salvador das Missões', '4316477'),
  ('RS', 'Salvador do Sul', '4316501'),
  ('RS', 'Sananduva', '4316600'),
  ('RS', 'Santa Bárbara do Sul', '4316709'),
  ('RS', 'Santa Cecília do Sul', '4316733'),
  ('RS', 'Santa Clara do Sul', '4316758'),
  ('RS', 'Santa Cruz do Sul', '4316808'),
  ('RS', 'Santa Maria', '4316907'),
  ('RS', 'Santa Maria do Herval', '4316956'),
  ('RS', 'Santa Margarida do Sul', '4316972'),
  ('RS', 'Santana da Boa Vista', '4317004'),
  ('RS', 'Sant''ana do Livramento', '4317103'),
  ('RS', 'Santa Rosa', '4317202'),
  ('RS', 'Santa Tereza', '4317251'),
  ('RS', 'Santa Vitória do Palmar', '4317301'),
  ('RS', 'Santiago', '4317400'),
  ('RS', 'Santo Ângelo', '4317509'),
  ('RS', 'Santo Antônio do Palma', '4317558'),
  ('RS', 'Santo Antônio da Patrulha', '4317608'),
  ('RS', 'Santo Antônio das Missões', '4317707'),
  ('RS', 'Santo Antônio do Planalto', '4317756'),
  ('RS', 'Santo Augusto', '4317806'),
  ('RS', 'Santo Cristo', '4317905'),
  ('RS', 'Santo Expedito do Sul', '4317954'),
  ('RS', 'São Borja', '4318002'),
  ('RS', 'São domingos do Sul', '4318051'),
  ('RS', 'São Francisco de Assis', '4318101'),
  ('RS', 'São Francisco de Paula', '4318200'),
  ('RS', 'São Gabriel', '4318309'),
  ('RS', 'São Jerônimo', '4318408'),
  ('RS', 'São João da Urtiga', '4318424'),
  ('RS', 'São João do Polêsine', '4318432'),
  ('RS', 'São Jorge', '4318440'),
  ('RS', 'São José das Missões', '4318457'),
  ('RS', 'São José do Herval', '4318465'),
  ('RS', 'São José do Hortêncio', '4318481'),
  ('RS', 'São José do Inhacorá', '4318499'),
  ('RS', 'São José do Norte', '4318507'),
  ('RS', 'São José do Ouro', '4318606'),
  ('RS', 'São José do Sul', '4318614'),
  ('RS', 'São José dos Ausentes', '4318622'),
  ('RS', 'São Leopoldo', '4318705'),
  ('RS', 'São Lourenço do Sul', '4318804'),
  ('RS', 'São Luiz Gonzaga', '4318903'),
  ('RS', 'São Marcos', '4319000'),
  ('RS', 'São Martinho', '4319109'),
  ('RS', 'São Martinho da Serra', '4319125'),
  ('RS', 'São Miguel das Missões', '4319158'),
  ('RS', 'São Nicolau', '4319208'),
  ('RS', 'São Paulo das Missões', '4319307'),
  ('RS', 'São Pedro da Serra', '4319356'),
  ('RS', 'São Pedro das Missões', '4319364'),
  ('RS', 'São Pedro do Butiá', '4319372'),
  ('RS', 'São Pedro do Sul', '4319406'),
  ('RS', 'São Sebastião do Caí', '4319505'),
  ('RS', 'São Sepé', '4319604'),
  ('RS', 'São Valentim', '4319703'),
  ('RS', 'São Valentim do Sul', '4319711'),
  ('RS', 'São Valério do Sul', '4319737'),
  ('RS', 'São Vendelino', '4319752'),
  ('RS', 'São Vicente do Sul', '4319802'),
  ('RS', 'Sapiranga', '4319901'),
  ('RS', 'Sapucaia do Sul', '4320008'),
  ('RS', 'Sarandi', '4320107'),
  ('RS', 'Seberi', '4320206'),
  ('RS', 'Sede Nova', '4320230'),
  ('RS', 'Segredo', '4320263'),
  ('RS', 'Selbach', '4320305'),
  ('RS', 'Senador Salgado Filho', '4320321'),
  ('RS', 'Sentinela do Sul', '4320354'),
  ('RS', 'Serafina Corrêa', '4320404'),
  ('RS', 'Sério', '4320453'),
  ('RS', 'Sertão', '4320503'),
  ('RS', 'Sertão Santana', '4320552'),
  ('RS', 'Sete de Setembro', '4320578'),
  ('RS', 'Severiano de Almeida', '4320602'),
  ('RS', 'Silveira Martins', '4320651'),
  ('RS', 'Sinimbu', '4320677'),
  ('RS', 'Sobradinho', '4320701'),
  ('RS', 'Soledade', '4320800'),
  ('RS', 'Tabaí', '4320859'),
  ('RS', 'Tapejara', '4320909'),
  ('RS', 'Tapera', '4321006'),
  ('RS', 'Tapes', '4321105'),
  ('RS', 'Taquara', '4321204'),
  ('RS', 'Taquari', '4321303'),
  ('RS', 'Taquaruçu do Sul', '4321329'),
  ('RS', 'Tavares', '4321352'),
  ('RS', 'Tenente Portela', '4321402'),
  ('RS', 'Terra de Areia', '4321436'),
  ('RS', 'Teutônia', '4321451'),
  ('RS', 'Tio Hugo', '4321469'),
  ('RS', 'Tiradentes do Sul', '4321477'),
  ('RS', 'Toropi', '4321493'),
  ('RS', 'Torres', '4321501'),
  ('RS', 'Tramandaí', '4321600'),
  ('RS', 'Travesseiro', '4321626'),
  ('RS', 'Três Arroios', '4321634'),
  ('RS', 'Três Cachoeiras', '4321667'),
  ('RS', 'Três Coroas', '4321709'),
  ('RS', 'Três de Maio', '4321808'),
  ('RS', 'Três Forquilhas', '4321832'),
  ('RS', 'Três Palmeiras', '4321857'),
  ('RS', 'Três Passos', '4321907'),
  ('RS', 'Trindade do Sul', '4321956'),
  ('RS', 'Triunfo', '4322004'),
  ('RS', 'Tucunduva', '4322103'),
  ('RS', 'Tunas', '4322152'),
  ('RS', 'Tupanci do Sul', '4322186'),
  ('RS', 'Tupanciretã', '4322202'),
  ('RS', 'Tupandi', '4322251'),
  ('RS', 'Tuparendi', '4322301'),
  ('RS', 'Turuçu', '4322327'),
  ('RS', 'Ubiretama', '4322343'),
  ('RS', 'União da Serra', '4322350'),
  ('RS', 'Unistalda', '4322376'),
  ('RS', 'Uruguaiana', '4322400'),
  ('RS', 'Vacaria', '4322509'),
  ('RS', 'Vale Verde', '4322525'),
  ('RS', 'Vale do Sol', '4322533'),
  ('RS', 'Vale Real', '4322541'),
  ('RS', 'Vanini', '4322558'),
  ('RS', 'Venâncio Aires', '4322608'),
  ('RS', 'Vera Cruz', '4322707'),
  ('RS', 'Veranópolis', '4322806'),
  ('RS', 'Vespasiano Correa', '4322855'),
  ('RS', 'Viadutos', '4322905'),
  ('RS', 'Viamão', '4323002'),
  ('RS', 'Vicente Dutra', '4323101'),
  ('RS', 'Victor Graeff', '4323200'),
  ('RS', 'Vila Flores', '4323309'),
  ('RS', 'Vila Lângaro', '4323358'),
  ('RS', 'Vila Maria', '4323408'),
  ('RS', 'Vila Nova do Sul', '4323457'),
  ('RS', 'Vista Alegre', '4323507'),
  ('RS', 'Vista Alegre do Prata', '4323606'),
  ('RS', 'Vista Gaúcha', '4323705'),
  ('RS', 'Vitória das Missões', '4323754'),
  ('RS', 'Westfalia', '4323770'),
  ('RS', 'Xangri-Lá', '4323804'),
  ('MS', 'Água Clara', '5000203'),
  ('MS', 'Alcinópolis', '5000252'),
  ('MS', 'Amambai', '5000609'),
  ('MS', 'Anastácio', '5000708'),
  ('MS', 'Anaurilândia', '5000807'),
  ('MS', 'Angélica', '5000856'),
  ('MS', 'Antônio João', '5000906'),
  ('MS', 'Aparecida do Taboado', '5001003'),
  ('MS', 'Aquidauana', '5001102'),
  ('MS', 'Aral Moreira', '5001243'),
  ('MS', 'Bandeirantes', '5001508'),
  ('MS', 'Bataguassu', '5001904'),
  ('MS', 'Batayporã', '5002001'),
  ('MS', 'Bela Vista', '5002100'),
  ('MS', 'Bodoquena', '5002159'),
  ('MS', 'Bonito', '5002209'),
  ('MS', 'Brasilândia', '5002308'),
  ('MS', 'Caarapó', '5002407'),
  ('MS', 'Camapuã', '5002605'),
  ('MS', 'Campo Grande', '5002704'),
  ('MS', 'Caracol', '5002803'),
  ('MS', 'Cassilândia', '5002902'),
  ('MS', 'Chapadão do Sul', '5002951'),
  ('MS', 'Corguinho', '5003108'),
  ('MS', 'Coronel Sapucaia', '5003157'),
  ('MS', 'Corumbá', '5003207'),
  ('MS', 'Costa Rica', '5003256'),
  ('MS', 'Coxim', '5003306'),
  ('MS', 'deodápolis', '5003454'),
  ('MS', 'dois Irmãos do Buriti', '5003488'),
  ('MS', 'douradina', '5003504'),
  ('MS', 'dourados', '5003702'),
  ('MS', 'Eldorado', '5003751'),
  ('MS', 'Fátima do Sul', '5003801'),
  ('MS', 'Figueirão', '5003900'),
  ('MS', 'Glória de dourados', '5004007'),
  ('MS', 'Guia Lopes da Laguna', '5004106'),
  ('MS', 'Iguatemi', '5004304'),
  ('MS', 'Inocência', '5004403'),
  ('MS', 'Itaporã', '5004502'),
  ('MS', 'Itaquiraí', '5004601'),
  ('MS', 'Ivinhema', '5004700'),
  ('MS', 'Japorã', '5004809'),
  ('MS', 'Jaraguari', '5004908'),
  ('MS', 'Jardim', '5005004'),
  ('MS', 'Jateí', '5005103'),
  ('MS', 'Juti', '5005152'),
  ('MS', 'Ladário', '5005202'),
  ('MS', 'Laguna Carapã', '5005251'),
  ('MS', 'Maracaju', '5005400'),
  ('MS', 'Miranda', '5005608'),
  ('MS', 'Mundo Novo', '5005681'),
  ('MS', 'Naviraí', '5005707'),
  ('MS', 'Nioaque', '5005806'),
  ('MS', 'Nova Alvorada do Sul', '5006002'),
  ('MS', 'Nova Andradina', '5006200'),
  ('MS', 'Novo Horizonte do Sul', '5006259'),
  ('MS', 'Paraíso das Águas', '5006275'),
  ('MS', 'Paranaíba', '5006309'),
  ('MS', 'Paranhos', '5006358'),
  ('MS', 'Pedro Gomes', '5006408'),
  ('MS', 'Ponta Porã', '5006606'),
  ('MS', 'Porto Murtinho', '5006903'),
  ('MS', 'Ribas do Rio Pardo', '5007109'),
  ('MS', 'Rio Brilhante', '5007208'),
  ('MS', 'Rio Negro', '5007307'),
  ('MS', 'Rio Verde de Mato Grosso', '5007406'),
  ('MS', 'Rochedo', '5007505'),
  ('MS', 'Santa Rita do Pardo', '5007554'),
  ('MS', 'São Gabriel do Oeste', '5007695'),
  ('MS', 'Sete Quedas', '5007703'),
  ('MS', 'Selvíria', '5007802'),
  ('MS', 'Sidrolândia', '5007901'),
  ('MS', 'Sonora', '5007935'),
  ('MS', 'Tacuru', '5007950'),
  ('MS', 'Taquarussu', '5007976'),
  ('MS', 'Terenos', '5008008'),
  ('MS', 'Três Lagoas', '5008305'),
  ('MS', 'Vicentina', '5008404'),
  ('MT', 'Acorizal', '5100102'),
  ('MT', 'Água Boa', '5100201'),
  ('MT', 'Alta Floresta', '5100250'),
  ('MT', 'Alto Araguaia', '5100300'),
  ('MT', 'Alto Boa Vista', '5100359'),
  ('MT', 'Alto Garças', '5100409'),
  ('MT', 'Alto Paraguai', '5100508'),
  ('MT', 'Alto Taquari', '5100607'),
  ('MT', 'Apiacás', '5100805'),
  ('MT', 'Araguaiana', '5101001'),
  ('MT', 'Araguainha', '5101209'),
  ('MT', 'Araputanga', '5101258'),
  ('MT', 'Arenápolis', '5101308'),
  ('MT', 'Aripuanã', '5101407'),
  ('MT', 'Barão de Melgaço', '5101605'),
  ('MT', 'Barra do Bugres', '5101704'),
  ('MT', 'Barra do Garças', '5101803'),
  ('MT', 'Bom Jesus do Araguaia', '5101852'),
  ('MT', 'Brasnorte', '5101902'),
  ('MT', 'Cáceres', '5102504'),
  ('MT', 'Campinápolis', '5102603'),
  ('MT', 'Campo Novo do Parecis', '5102637'),
  ('MT', 'Campo Verde', '5102678'),
  ('MT', 'Campos de Júlio', '5102686'),
  ('MT', 'Canabrava do Norte', '5102694'),
  ('MT', 'Canarana', '5102702'),
  ('MT', 'Carlinda', '5102793'),
  ('MT', 'Castanheira', '5102850'),
  ('MT', 'Chapada dos Guimarães', '5103007'),
  ('MT', 'Cláudia', '5103056'),
  ('MT', 'Cocalinho', '5103106'),
  ('MT', 'Colíder', '5103205'),
  ('MT', 'Colniza', '5103254'),
  ('MT', 'Comodoro', '5103304'),
  ('MT', 'Confresa', '5103353'),
  ('MT', 'Conquista D''oeste', '5103361'),
  ('MT', 'Cotriguaçu', '5103379'),
  ('MT', 'Cuiabá', '5103403'),
  ('MT', 'Curvelândia', '5103437'),
  ('MT', 'denise', '5103452'),
  ('MT', 'Diamantino', '5103502'),
  ('MT', 'dom Aquino', '5103601'),
  ('MT', 'Feliz Natal', '5103700'),
  ('MT', 'Figueirópolis D''oeste', '5103809'),
  ('MT', 'Gaúcha do Norte', '5103858'),
  ('MT', 'General Carneiro', '5103908'),
  ('MT', 'Glória D''oeste', '5103957'),
  ('MT', 'Guarantã do Norte', '5104104'),
  ('MT', 'Guiratinga', '5104203'),
  ('MT', 'Indiavaí', '5104500'),
  ('MT', 'Ipiranga do Norte', '5104526'),
  ('MT', 'Itanhangá', '5104542'),
  ('MT', 'Itaúba', '5104559'),
  ('MT', 'Itiquira', '5104609'),
  ('MT', 'Jaciara', '5104807'),
  ('MT', 'Jangada', '5104906'),
  ('MT', 'Jauru', '5105002'),
  ('MT', 'Juara', '5105101'),
  ('MT', 'Juína', '5105150'),
  ('MT', 'Juruena', '5105176'),
  ('MT', 'Juscimeira', '5105200'),
  ('MT', 'Lambari D''oeste', '5105234'),
  ('MT', 'Lucas do Rio Verde', '5105259'),
  ('MT', 'Luciara', '5105309'),
  ('MT', 'Vila Bela da Santíssima Trindade', '5105507'),
  ('MT', 'Marcelândia', '5105580'),
  ('MT', 'Matupá', '5105606'),
  ('MT', 'Mirassol D''oeste', '5105622'),
  ('MT', 'Nobres', '5105903'),
  ('MT', 'Nortelândia', '5106000'),
  ('MT', 'Nossa Senhora do Livramento', '5106109'),
  ('MT', 'Nova Bandeirantes', '5106158'),
  ('MT', 'Nova Nazaré', '5106174'),
  ('MT', 'Nova Lacerda', '5106182'),
  ('MT', 'Nova Santa Helena', '5106190'),
  ('MT', 'Nova Brasilândia', '5106208'),
  ('MT', 'Nova Canaã do Norte', '5106216'),
  ('MT', 'Nova Mutum', '5106224'),
  ('MT', 'Nova Olímpia', '5106232'),
  ('MT', 'Nova Ubiratã', '5106240'),
  ('MT', 'Nova Xavantina', '5106257'),
  ('MT', 'Novo Mundo', '5106265'),
  ('MT', 'Novo Horizonte do Norte', '5106273'),
  ('MT', 'Novo São Joaquim', '5106281'),
  ('MT', 'Paranaíta', '5106299'),
  ('MT', 'Paranatinga', '5106307'),
  ('MT', 'Novo Santo Antônio', '5106315'),
  ('MT', 'Pedra Preta', '5106372'),
  ('MT', 'Peixoto de Azevedo', '5106422'),
  ('MT', 'Planalto da Serra', '5106455'),
  ('MT', 'Poconé', '5106505'),
  ('MT', 'Pontal do Araguaia', '5106653'),
  ('MT', 'Ponte Branca', '5106703'),
  ('MT', 'Pontes E Lacerda', '5106752'),
  ('MT', 'Porto Alegre do Norte', '5106778'),
  ('MT', 'Porto dos Gaúchos', '5106802'),
  ('MT', 'Porto Esperidião', '5106828'),
  ('MT', 'Porto Estrela', '5106851'),
  ('MT', 'Poxoréu', '5107008'),
  ('MT', 'Primavera do Leste', '5107040'),
  ('MT', 'Querência', '5107065'),
  ('MT', 'São José dos Quatro Marcos', '5107107'),
  ('MT', 'Reserva do Cabaçal', '5107156'),
  ('MT', 'Ribeirão Cascalheira', '5107180'),
  ('MT', 'Ribeirãozinho', '5107198'),
  ('MT', 'Rio Branco', '5107206'),
  ('MT', 'Santa Carmem', '5107248'),
  ('MT', 'Santo Afonso', '5107263'),
  ('MT', 'São José do Povo', '5107297'),
  ('MT', 'São José do Rio Claro', '5107305'),
  ('MT', 'São José do Xingu', '5107354'),
  ('MT', 'São Pedro da Cipa', '5107404'),
  ('MT', 'Rondolândia', '5107578'),
  ('MT', 'Rondonópolis', '5107602'),
  ('MT', 'Rosário Oeste', '5107701'),
  ('MT', 'Santa Cruz do Xingu', '5107743'),
  ('MT', 'Salto do Céu', '5107750'),
  ('MT', 'Santa Rita do Trivelato', '5107768'),
  ('MT', 'Santa Terezinha', '5107776'),
  ('MT', 'Santo Antônio do Leste', '5107792'),
  ('MT', 'Santo Antônio do Leverger', '5107800'),
  ('MT', 'São Félix do Araguaia', '5107859'),
  ('MT', 'Sapezal', '5107875'),
  ('MT', 'Serra Nova dourada', '5107883'),
  ('MT', 'Sinop', '5107909'),
  ('MT', 'Sorriso', '5107925'),
  ('MT', 'Tabaporã', '5107941'),
  ('MT', 'Tangará da Serra', '5107958'),
  ('MT', 'Tapurah', '5108006'),
  ('MT', 'Terra Nova do Norte', '5108055'),
  ('MT', 'Tesouro', '5108105'),
  ('MT', 'Torixoréu', '5108204'),
  ('MT', 'União do Sul', '5108303'),
  ('MT', 'Vale de São domingos', '5108352'),
  ('MT', 'Várzea Grande', '5108402'),
  ('MT', 'Vera', '5108501'),
  ('MT', 'Vila Rica', '5108600'),
  ('MT', 'Nova Guarita', '5108808'),
  ('MT', 'Nova Marilândia', '5108857'),
  ('MT', 'Nova Maringá', '5108907'),
  ('MT', 'Nova Monte Verde', '5108956'),
  ('GO', 'Abadia de Goiás', '5200050'),
  ('GO', 'Abadiânia', '5200100'),
  ('GO', 'Acreúna', '5200134'),
  ('GO', 'Adelândia', '5200159'),
  ('GO', 'Água Fria de Goiás', '5200175'),
  ('GO', 'Água Limpa', '5200209'),
  ('GO', 'Águas Lindas de Goiás', '5200258'),
  ('GO', 'Alexânia', '5200308'),
  ('GO', 'Aloândia', '5200506'),
  ('GO', 'Alto Horizonte', '5200555'),
  ('GO', 'Alto Paraíso de Goiás', '5200605'),
  ('GO', 'Alvorada do Norte', '5200803'),
  ('GO', 'Amaralina', '5200829'),
  ('GO', 'Americano do Brasil', '5200852'),
  ('GO', 'Amorinópolis', '5200902'),
  ('GO', 'Anápolis', '5201108'),
  ('GO', 'Anhanguera', '5201207'),
  ('GO', 'Anicuns', '5201306'),
  ('GO', 'Aparecida de Goiânia', '5201405'),
  ('GO', 'Aparecida do Rio doce', '5201454'),
  ('GO', 'Aporé', '5201504'),
  ('GO', 'Araçu', '5201603'),
  ('GO', 'Aragarças', '5201702'),
  ('GO', 'Aragoiânia', '5201801'),
  ('GO', 'Araguapaz', '5202155'),
  ('GO', 'Arenópolis', '5202353'),
  ('GO', 'Aruanã', '5202502'),
  ('GO', 'Aurilândia', '5202601'),
  ('GO', 'Avelinópolis', '5202809'),
  ('GO', 'Baliza', '5203104'),
  ('GO', 'Barro Alto', '5203203'),
  ('GO', 'Bela Vista de Goiás', '5203302'),
  ('GO', 'Bom Jardim de Goiás', '5203401'),
  ('GO', 'Bom Jesus de Goiás', '5203500'),
  ('GO', 'Bonfinópolis', '5203559'),
  ('GO', 'Bonópolis', '5203575'),
  ('GO', 'Brazabrantes', '5203609'),
  ('GO', 'Britânia', '5203807'),
  ('GO', 'Buriti Alegre', '5203906'),
  ('GO', 'Buriti de Goiás', '5203939'),
  ('GO', 'Buritinópolis', '5203962'),
  ('GO', 'Cabeceiras', '5204003'),
  ('GO', 'Cachoeira Alta', '5204102'),
  ('GO', 'Cachoeira de Goiás', '5204201'),
  ('GO', 'Cachoeira dourada', '5204250'),
  ('GO', 'Caçu', '5204300'),
  ('GO', 'Caiapônia', '5204409'),
  ('GO', 'Caldas Novas', '5204508'),
  ('GO', 'Caldazinha', '5204557'),
  ('GO', 'Campestre de Goiás', '5204607'),
  ('GO', 'Campinaçu', '5204656'),
  ('GO', 'Campinorte', '5204706'),
  ('GO', 'Campo Alegre de Goiás', '5204805'),
  ('GO', 'Campo Limpo de Goiás', '5204854'),
  ('GO', 'Campos Belos', '5204904'),
  ('GO', 'Campos Verdes', '5204953'),
  ('GO', 'Carmo do Rio Verde', '5205000'),
  ('GO', 'Castelândia', '5205059'),
  ('GO', 'Catalão', '5205109'),
  ('GO', 'Caturaí', '5205208'),
  ('GO', 'Cavalcante', '5205307'),
  ('GO', 'Ceres', '5205406'),
  ('GO', 'Cezarina', '5205455'),
  ('GO', 'Chapadão do Céu', '5205471'),
  ('GO', 'Cidade Ocidental', '5205497'),
  ('GO', 'Cocalzinho de Goiás', '5205513'),
  ('GO', 'Colinas do Sul', '5205521'),
  ('GO', 'Córrego do Ouro', '5205703'),
  ('GO', 'Corumbá de Goiás', '5205802'),
  ('GO', 'Corumbaíba', '5205901'),
  ('GO', 'Cristalina', '5206206'),
  ('GO', 'Cristianópolis', '5206305'),
  ('GO', 'Crixás', '5206404'),
  ('GO', 'Cromínia', '5206503'),
  ('GO', 'Cumari', '5206602'),
  ('GO', 'damianópolis', '5206701'),
  ('GO', 'damolândia', '5206800'),
  ('GO', 'davinópolis', '5206909'),
  ('GO', 'Diorama', '5207105'),
  ('GO', 'doverlândia', '5207253'),
  ('GO', 'Edealina', '5207352'),
  ('GO', 'Edéia', '5207402'),
  ('GO', 'Estrela do Norte', '5207501'),
  ('GO', 'Faina', '5207535'),
  ('GO', 'Fazenda Nova', '5207600'),
  ('GO', 'Firminópolis', '5207808'),
  ('GO', 'Flores de Goiás', '5207907'),
  ('GO', 'Formosa', '5208004'),
  ('GO', 'Formoso', '5208103'),
  ('GO', 'Gameleira de Goiás', '5208152'),
  ('GO', 'Divinópolis de Goiás', '5208301'),
  ('GO', 'Goianápolis', '5208400'),
  ('GO', 'Goiandira', '5208509'),
  ('GO', 'Goianésia', '5208608'),
  ('GO', 'Goiânia', '5208707'),
  ('GO', 'Goianira', '5208806'),
  ('GO', 'Goiás', '5208905'),
  ('GO', 'Goiatuba', '5209101'),
  ('GO', 'Gouvelândia', '5209150'),
  ('GO', 'Guapó', '5209200'),
  ('GO', 'Guaraíta', '5209291'),
  ('GO', 'Guarani de Goiás', '5209408'),
  ('GO', 'Guarinos', '5209457'),
  ('GO', 'Heitoraí', '5209606'),
  ('GO', 'Hidrolândia', '5209705'),
  ('GO', 'Hidrolina', '5209804'),
  ('GO', 'Iaciara', '5209903'),
  ('GO', 'Inaciolândia', '5209937'),
  ('GO', 'Indiara', '5209952'),
  ('GO', 'Inhumas', '5210000'),
  ('GO', 'Ipameri', '5210109'),
  ('GO', 'Ipiranga de Goiás', '5210158'),
  ('GO', 'Iporá', '5210208'),
  ('GO', 'Israelândia', '5210307'),
  ('GO', 'Itaberaí', '5210406'),
  ('GO', 'Itaguari', '5210562'),
  ('GO', 'Itaguaru', '5210604'),
  ('GO', 'Itajá', '5210802'),
  ('GO', 'Itapaci', '5210901'),
  ('GO', 'Itapirapuã', '5211008'),
  ('GO', 'Itapuranga', '5211206'),
  ('GO', 'Itarumã', '5211305'),
  ('GO', 'Itauçu', '5211404'),
  ('GO', 'Itumbiara', '5211503'),
  ('GO', 'Ivolândia', '5211602'),
  ('GO', 'Jandaia', '5211701'),
  ('GO', 'Jaraguá', '5211800'),
  ('GO', 'Jataí', '5211909'),
  ('GO', 'Jaupaci', '5212006'),
  ('GO', 'Jesúpolis', '5212055'),
  ('GO', 'Joviânia', '5212105'),
  ('GO', 'Jussara', '5212204'),
  ('GO', 'Lagoa Santa', '5212253'),
  ('GO', 'Leopoldo de Bulhões', '5212303'),
  ('GO', 'Luziânia', '5212501'),
  ('GO', 'Mairipotaba', '5212600'),
  ('GO', 'Mambaí', '5212709'),
  ('GO', 'Mara Rosa', '5212808'),
  ('GO', 'Marzagão', '5212907'),
  ('GO', 'Matrinchã', '5212956'),
  ('GO', 'Maurilândia', '5213004'),
  ('GO', 'Mimoso de Goiás', '5213053'),
  ('GO', 'Minaçu', '5213087'),
  ('GO', 'Mineiros', '5213103'),
  ('GO', 'Moiporá', '5213400'),
  ('GO', 'Monte Alegre de Goiás', '5213509'),
  ('GO', 'Montes Claros de Goiás', '5213707'),
  ('GO', 'Montividiu', '5213756'),
  ('GO', 'Montividiu do Norte', '5213772'),
  ('GO', 'Morrinhos', '5213806'),
  ('GO', 'Morro Agudo de Goiás', '5213855'),
  ('GO', 'Mossâmedes', '5213905'),
  ('GO', 'Mozarlândia', '5214002'),
  ('GO', 'Mundo Novo', '5214051'),
  ('GO', 'Mutunópolis', '5214101'),
  ('GO', 'Nazário', '5214408'),
  ('GO', 'Nerópolis', '5214507'),
  ('GO', 'Niquelândia', '5214606'),
  ('GO', 'Nova América', '5214705'),
  ('GO', 'Nova Aurora', '5214804'),
  ('GO', 'Nova Crixás', '5214838'),
  ('GO', 'Nova Glória', '5214861'),
  ('GO', 'Nova Iguaçu de Goiás', '5214879'),
  ('GO', 'Nova Roma', '5214903'),
  ('GO', 'Nova Veneza', '5215009'),
  ('GO', 'Novo Brasil', '5215207'),
  ('GO', 'Novo Gama', '5215231'),
  ('GO', 'Novo Planalto', '5215256'),
  ('GO', 'Orizona', '5215306'),
  ('GO', 'Ouro Verde de Goiás', '5215405'),
  ('GO', 'Ouvidor', '5215504'),
  ('GO', 'Padre Bernardo', '5215603'),
  ('GO', 'Palestina de Goiás', '5215652'),
  ('GO', 'Palmeiras de Goiás', '5215702'),
  ('GO', 'Palmelo', '5215801'),
  ('GO', 'Palminópolis', '5215900'),
  ('GO', 'Panamá', '5216007'),
  ('GO', 'Paranaiguara', '5216304'),
  ('GO', 'Paraúna', '5216403'),
  ('GO', 'Perolândia', '5216452'),
  ('GO', 'Petrolina de Goiás', '5216809'),
  ('GO', 'Pilar de Goiás', '5216908'),
  ('GO', 'Piracanjuba', '5217104'),
  ('GO', 'Piranhas', '5217203'),
  ('GO', 'Pirenópolis', '5217302'),
  ('GO', 'Pires do Rio', '5217401'),
  ('GO', 'Planaltina', '5217609'),
  ('GO', 'Pontalina', '5217708'),
  ('GO', 'Porangatu', '5218003'),
  ('GO', 'Porteirão', '5218052'),
  ('GO', 'Portelândia', '5218102'),
  ('GO', 'Posse', '5218300'),
  ('GO', 'Professor Jamil', '5218391'),
  ('GO', 'Quirinópolis', '5218508'),
  ('GO', 'Rialma', '5218607'),
  ('GO', 'Rianápolis', '5218706'),
  ('GO', 'Rio Quente', '5218789'),
  ('GO', 'Rio Verde', '5218805'),
  ('GO', 'Rubiataba', '5218904'),
  ('GO', 'Sanclerlândia', '5219001'),
  ('GO', 'Santa Bárbara de Goiás', '5219100'),
  ('GO', 'Santa Cruz de Goiás', '5219209'),
  ('GO', 'Santa Fé de Goiás', '5219258'),
  ('GO', 'Santa Helena de Goiás', '5219308'),
  ('GO', 'Santa Isabel', '5219357'),
  ('GO', 'Santa Rita do Araguaia', '5219407'),
  ('GO', 'Santa Rita do Novo destino', '5219456'),
  ('GO', 'Santa Rosa de Goiás', '5219506'),
  ('GO', 'Santa Tereza de Goiás', '5219605'),
  ('GO', 'Santa Terezinha de Goiás', '5219704'),
  ('GO', 'Santo Antônio da Barra', '5219712'),
  ('GO', 'Santo Antônio de Goiás', '5219738'),
  ('GO', 'Santo Antônio do descoberto', '5219753'),
  ('GO', 'São domingos', '5219803'),
  ('GO', 'São Francisco de Goiás', '5219902'),
  ('GO', 'São João D''aliança', '5220009'),
  ('GO', 'São João da Paraúna', '5220058'),
  ('GO', 'São Luís de Montes Belos', '5220108'),
  ('GO', 'São Luíz do Norte', '5220157'),
  ('GO', 'São Miguel do Araguaia', '5220207'),
  ('GO', 'São Miguel do Passa Quatro', '5220264'),
  ('GO', 'São Patrício', '5220280'),
  ('GO', 'São Simão', '5220405'),
  ('GO', 'Senador Canedo', '5220454'),
  ('GO', 'Serranópolis', '5220504'),
  ('GO', 'Silvânia', '5220603'),
  ('GO', 'Simolândia', '5220686'),
  ('GO', 'Sítio D''abadia', '5220702'),
  ('GO', 'Taquaral de Goiás', '5221007'),
  ('GO', 'Teresina de Goiás', '5221080'),
  ('GO', 'Terezópolis de Goiás', '5221197'),
  ('GO', 'Três Ranchos', '5221304'),
  ('GO', 'Trindade', '5221403'),
  ('GO', 'Trombas', '5221452'),
  ('GO', 'Turvânia', '5221502'),
  ('GO', 'Turvelândia', '5221551'),
  ('GO', 'Uirapuru', '5221577'),
  ('GO', 'Uruaçu', '5221601'),
  ('GO', 'Uruana', '5221700'),
  ('GO', 'Urutaí', '5221809'),
  ('GO', 'Valparaíso de Goiás', '5221858'),
  ('GO', 'Varjão', '5221908'),
  ('GO', 'Vianópolis', '5222005'),
  ('GO', 'Vicentinópolis', '5222054'),
  ('GO', 'Vila Boa', '5222203'),
  ('GO', 'Vila Propício', '5222302'),
  ('DF', 'Brasília', '5300108')
) AS v(uf, nome, ibge)
JOIN tb_estado e ON e.uf_estado = v.uf
ON CONFLICT (codigo_ibge_cidade) DO NOTHING;

COMMIT;

DO $$
DECLARE n_est int; n_cid int;
BEGIN
  SELECT count(*) INTO n_est FROM tb_estado;
  SELECT count(*) INTO n_cid FROM tb_cidade;
  IF n_est <> 27   THEN RAISE EXCEPTION 'Geografia: % estados (esperado 27)', n_est; END IF;
  IF n_cid <> 5570 THEN RAISE EXCEPTION 'Geografia: % cidades (esperado 5570)', n_cid; END IF;
  RAISE NOTICE 'Geografia IBGE OK: % estados, % municípios.', n_est, n_cid;
END $$;

-- ############################################################################
-- ### sql/03_consultas.sql
-- ############################################################################

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
--   · o nome do aluno e do professor vêm de `tb_pessoa` [E2] — toda consulta que
--     exibe gente passa a ter mais uma junção, e isso é o preço explícito de
--     não repetir nome/CPF em duas tabelas;
--   · o professor da turma vem de `tb_turma_professor` filtrando o TITULAR [E11];
--   · a sala vem de `tb_predio` [E5] e pode ser NULL (turma EAD) [E12] — por isso
--     LEFT JOIN, não INNER: com INNER a turma EAD sumiria do relatório;
--   · média e frequência não existem mais como coluna: vêm de
--     `vw_desempenho_matricula`, derivadas de nota/presenca [E14].
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
SELECT cp.nome_campus                                   AS tb_campus,
       c.codigo_curso                                  AS tb_curso,
       c.nome_curso                                    AS nome_curso,
       count(a.id_aluno) FILTER (WHERE a.status_aluno = 'ativo')     AS ativos,
       count(a.id_aluno) FILTER (WHERE a.status_aluno <> 'ativo')    AS inativos,
       count(a.id_aluno)                               AS total
FROM tb_curso c
JOIN tb_campus cp     ON cp.id_campus = c.id_campus
LEFT JOIN tb_aluno a  ON a.id_curso = c.id_curso
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
  FROM tb_matricula m
  JOIN tb_turma t           ON t.id_turma = m.id_turma
  JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
  WHERE pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2 AND m.status_matricula = 'confirmada'
  GROUP BY m.id_aluno
  ORDER BY count(*) DESC, m.id_aluno
  LIMIT 1
)
SELECT pa.nome_pessoa                                                          AS tb_aluno,
       (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.dia_semana_turma_horario] AS dia,
       left(lower(th.faixa_turma_horario)::text, 5) || '–' ||
       left(upper(th.faixa_turma_horario)::text, 5)                            AS horario,
       d.codigo_disciplina                                                     AS tb_disciplina,
       t.codigo_turma                                                          AS tb_turma,
       coalesce(s.codigo_sala, '(EAD)')                                        AS tb_sala,
       coalesce(pr.nome_predio, '—')                                           AS tb_predio,
       coalesce(cp.nome_campus, t.modalidade_turma::text)                      AS tb_campus,
       pp.nome_pessoa                                                          AS tb_professor
FROM alvo
JOIN tb_aluno a           ON a.id_aluno = alvo.id_aluno
JOIN tb_pessoa pa         ON pa.id_pessoa = a.id_pessoa                     -- [E2]
JOIN tb_matricula m       ON m.id_aluno = a.id_aluno AND m.status_matricula = 'confirmada'
JOIN tb_turma t           ON t.id_turma = m.id_turma
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN tb_disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN tb_turma_professor tp ON tp.id_turma = t.id_turma
                      AND tp.papel_turma_professor = 'titular'           -- [E11]
JOIN tb_professor p       ON p.id_professor = tp.id_professor
JOIN tb_pessoa pp         ON pp.id_pessoa = p.id_pessoa                     -- [E2]
JOIN tb_turma_horario th  ON th.id_turma = t.id_turma
LEFT JOIN tb_sala s       ON s.id_sala = th.id_sala                         -- NULL = EAD [E12]
LEFT JOIN tb_predio pr    ON pr.id_predio = s.id_predio                     -- [E5]
LEFT JOIN tb_campus cp    ON cp.id_campus = pr.id_campus
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
SELECT t.codigo_turma                                                   AS tb_turma,
       d.nome_disciplina                                                     AS tb_disciplina,
       t.turno_turma,
       t.vagas_turma,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')         AS confirmadas,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'trancada')           AS trancadas,
       t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada') AS vagas_livres,
       round(100.0 * count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')
             / NULLIF(t.vagas_turma, 0), 1)                             AS ocupacao_pct
FROM tb_turma t
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN tb_disciplina d      ON d.id_disciplina = t.id_disciplina
LEFT JOIN tb_matricula m  ON m.id_turma = t.id_turma
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
FROM tb_disciplina d
JOIN tb_turma t           ON t.id_disciplina = d.id_disciplina
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
JOIN tb_matricula m       ON m.id_turma = t.id_turma
JOIN tb_historico h       ON h.id_matricula = m.id_matricula
                      AND h.situacao_historico IN ('aprovado', 'reprovado_nota', 'reprovado_frequencia')
LEFT JOIN vw_desempenho_matricula dm ON dm.id_matricula = m.id_matricula     -- [E14]
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
-- [E17] a árvore agora é de UMA MATRIZ: a cadeia é decisão do currículo, e
-- currículos diferentes encadeiam diferente. O alvo é a matriz vigente de CC.
WITH RECURSIVE
matriz AS (
  SELECT cu.id_curriculo
  FROM tb_curriculo cu
  JOIN tb_curso c ON c.id_curso = cu.id_curso
  WHERE c.codigo_curso = 'CC' AND cu.ativo_curriculo
  ORDER BY cu.ano_vigencia_curriculo DESC
  LIMIT 1
),
arvore (node_id, nivel, caminho) AS (
  -- âncora: a própria disciplina-alvo
  SELECT d.id_disciplina, 0, ARRAY[d.id_disciplina]
  FROM tb_disciplina d
  WHERE d.codigo_disciplina = 'TABD'
  UNION ALL
  -- passo: os requisitos diretos DAQUELA matriz
  SELECT p.id_requisito, a.nivel + 1, a.caminho || p.id_requisito
  FROM arvore a
  JOIN tb_pre_requisito p ON p.id_disciplina = a.node_id
                         AND p.id_curriculo = (SELECT id_curriculo FROM matriz)
  WHERE NOT p.id_requisito = ANY (a.caminho)      -- proteção contra ciclos
)
SELECT repeat('    ', a.nivel) || d.codigo_disciplina AS arvore,
       d.nome_disciplina,
       a.nivel,
       CASE WHEN a.nivel = 0 THEN '(alvo)' ELSE 'pré-requisito' END AS vinculo
FROM arvore a
JOIN tb_disciplina d ON d.id_disciplina = a.node_id
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
--   [E17] os pré-requisitos consultados são os DA MATRIZ do aluno.
-- Leitura: o "plano de matrícula" possível do aluno, semestre a semestre.
-- ============================================================================
\echo '=== C6: disciplinas liberadas para o aluno com mais aprovações (recursiva) ==='
WITH RECURSIVE
alvo AS (                               -- aluno com mais disciplinas aprovadas
  SELECT m.id_aluno AS id_aluno, a.id_curriculo, p.nome_pessoa AS nome_aluno
  FROM tb_matricula m
  JOIN tb_historico h ON h.id_matricula = m.id_matricula AND h.situacao_historico = 'aprovado'
  JOIN tb_aluno a     ON a.id_aluno = m.id_aluno
  JOIN tb_pessoa p    ON p.id_pessoa = a.id_pessoa                            -- [E2]
  GROUP BY m.id_aluno, a.id_curriculo, p.nome_pessoa
  ORDER BY count(*) DESC, m.id_aluno
  LIMIT 1
),
aprovadas AS (                          -- conjunto-base: o que ele já aprovou
  SELECT DISTINCT t.id_disciplina
  FROM tb_matricula m
  JOIN tb_turma t     ON t.id_turma = m.id_turma
  JOIN tb_historico h ON h.id_matricula = m.id_matricula
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
      FROM tb_curriculo_disciplina cd
      WHERE cd.id_curriculo = (SELECT id_curriculo FROM alvo)
        AND cd.id_disciplina <> ALL (e.feitas)          -- ainda não feita
        AND NOT EXISTS (                                -- nenhum pré-req pendente
              SELECT 1
              FROM tb_pre_requisito p
              WHERE p.id_disciplina = cd.id_disciplina
                AND p.id_curriculo   = cd.id_curriculo      -- [E17]
                AND NOT (p.id_requisito = ANY (e.feitas)))
      ORDER BY cd.id_disciplina
    ) AS novas
  ) x
  WHERE cardinality(x.novas) > 0 AND e.nivel < 12       -- término garantido
)
SELECT (SELECT nome_aluno FROM alvo)               AS tb_aluno,
       e.nivel                               AS onda,
       CASE e.nivel WHEN 1 THEN 'PODE CURSAR JÁ'
                    ELSE 'destrava na onda ' || e.nivel END AS quando,
       d.codigo_disciplina,
       d.nome_disciplina,
       cd.periodo_curriculo_disciplina                            AS periodo_sugerido,
       cd.tipo_curriculo_disciplina
FROM expansao e
CROSS JOIN LATERAL unnest(e.novas) AS n(id_disciplina)
JOIN tb_disciplina d            ON d.id_disciplina = n.id_disciplina
JOIN tb_curriculo_disciplina cd ON cd.id_disciplina = d.id_disciplina
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
  SELECT a.id_aluno, a.matricula_aluno, p.nome_pessoa AS nome_aluno, c.codigo_curso AS tb_curso,
         round(sum(dm.media_final * d.ch_total_disciplina) / sum(d.ch_total_disciplina), 2) AS cr,
         count(*) AS disciplinas_avaliadas
  FROM tb_aluno a
  JOIN tb_pessoa p    ON p.id_pessoa = a.id_pessoa                            -- [E2]
  JOIN tb_curso c     ON c.id_curso = a.id_curso
  JOIN tb_matricula m ON m.id_aluno = a.id_aluno
  JOIN tb_turma t     ON t.id_turma = m.id_turma
  JOIN tb_disciplina d ON d.id_disciplina = t.id_disciplina
  JOIN vw_desempenho_matricula dm ON dm.id_matricula = m.id_matricula        -- [E14]
                                AND dm.media_final IS NOT NULL
  GROUP BY a.id_aluno, p.nome_pessoa, c.codigo_curso
  HAVING count(*) >= 3
)
SELECT tb_curso, matricula_aluno, nome_aluno, cr, disciplinas_avaliadas,   -- matrícula desambigua homônimos
       rank()         OVER (PARTITION BY tb_curso ORDER BY cr DESC)      AS posicao,
       round((percent_rank() OVER (PARTITION BY tb_curso ORDER BY cr))::numeric
             * 100, 1)                                                AS percentil,
       ntile(4)       OVER (PARTITION BY tb_curso ORDER BY cr DESC)      AS quartil
FROM rendimento
ORDER BY tb_curso, posicao
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
  FROM tb_matricula m
  JOIN tb_turma t           ON t.id_turma = m.id_turma
  JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
  JOIN vw_desempenho_matricula dm ON dm.id_matricula = m.id_matricula        -- [E14]
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
JOIN tb_aluno a  ON a.id_aluno = md.id_aluno
JOIN tb_pessoa pe ON pe.id_pessoa = a.id_pessoa                                -- [E2]
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
FROM tb_matricula m1
JOIN tb_matricula m2      ON m2.id_aluno = m1.id_aluno
                      AND m2.id_turma > m1.id_turma
                      AND m1.status_matricula = 'confirmada' AND m2.status_matricula = 'confirmada'
JOIN tb_turma t1          ON t1.id_turma = m1.id_turma
JOIN tb_turma t2          ON t2.id_turma = m2.id_turma
                      AND t2.id_periodo_letivo = t1.id_periodo_letivo
JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t1.id_periodo_letivo
                      AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
JOIN tb_turma_horario h1  ON h1.id_turma = t1.id_turma
JOIN tb_turma_horario h2  ON h2.id_turma = t2.id_turma
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
  FROM tb_pre_requisito p
  UNION                                       -- sem ALL: deduplica diamantes
  SELECT dep.base_id, p.id_disciplina
  FROM dependentes dep
  JOIN tb_pre_requisito p ON p.id_requisito = dep.dependente_id
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
  FROM tb_turma t
  JOIN tb_periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                        AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
  JOIN tb_matricula m       ON m.id_turma = t.id_turma
  JOIN tb_historico h       ON h.id_matricula = m.id_matricula
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
JOIN tb_disciplina d    ON d.id_disciplina = r.id_disciplina
LEFT JOIN destravas ds ON ds.base_id = d.id_disciplina
ORDER BY prioridade, d.codigo_disciplina
LIMIT 15;
