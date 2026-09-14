# Sistema de Matrícula Acadêmica — Esboço do Schema Ampliado

PostgreSQL 17 · schema `academico` · 16 tabelas originais + 25 novas = **41 tabelas**

## Convenções

**Ordem das colunas em toda tabela:** `pk` → `fk` → `varchar` → `text` → `char` → inteiros (`smallint`/`integer`/`bigint`) → decimais (`numeric`) → demais (`date`, `timestamptz`, `boolean`, ENUM, DOMAIN, range). Os tipos fora da regra ficam sempre por último.

**Nomenclatura:** PK = `id_<tabela>`; FK recebe o mesmo nome da PK referenciada (permite `JOIN USING`); papel diferente ganha prefixo (`id_requisito`, `id_professor_orientador`). Demais colunas com sufixo `_<tabela>`.

**Cardinalidade:** notação `(min,max)` em cada lado. `sala (1,1) — predio (0,N)` lê-se: toda sala pertence a exatamente 1 prédio; um prédio tem de 0 a N salas.

**Normalização:** todas as tabelas em 3FN. Atributos derivados (`ch_total_disciplina`, `media_final`) só existem como coluna GENERATED ou como view/MV — nunca como coluna gravada à mão. Multivalorados (telefone, documento, recurso da sala) viraram tabela própria (1FN). Atributos que dependiam de parte da chave (ex.: `id_professor` em turma quando há vários docentes) saíram para tabela associativa (2FN). Atributos que dependiam de outro não-chave (`cidade_campus` → estado → país; `usuario_log` → pessoa) viraram entidade (3FN).

---

## 1. Geografia

```
pais
  pk  id_pais            smallint IDENTITY
  varchar nome_pais      varchar(60)  NOT NULL UNIQUE
  char    sigla_pais     char(2)      NOT NULL UNIQUE   -- ISO 3166-1

estado
  pk  id_estado          smallint IDENTITY
  fk  id_pais            → pais  NOT NULL
  varchar nome_estado    varchar(60)  NOT NULL
  char    uf_estado      char(2)      NOT NULL
  UNIQUE (id_pais, uf_estado)

cidade
  pk  id_cidade          integer IDENTITY
  fk  id_estado          → estado  NOT NULL
  varchar nome_cidade    varchar(80)  NOT NULL
  char    codigo_ibge_cidade char(7)  UNIQUE
  UNIQUE (id_estado, nome_cidade)

endereco
  pk  id_endereco        integer IDENTITY
  fk  id_cidade          → cidade  NOT NULL
  varchar logradouro_endereco   varchar(120) NOT NULL
  varchar numero_endereco       varchar(10)
  varchar complemento_endereco  varchar(60)
  varchar bairro_endereco       varchar(60)
  char    cep_endereco          char(8)   CHECK ~ '^[0-9]{8}$'
```

**Cardinalidades**
- `estado (1,1) — pais (1,N)`
- `cidade (1,1) — estado (1,N)`
- `endereco (1,1) — cidade (0,N)`

---

## 2. Pessoas

`pessoa` é o supertipo; `aluno` e `professor` são especializações 1:1 (exclusividade não é obrigatória — um professor pode ser aluno de outro curso).

```
pessoa
  pk  id_pessoa          integer IDENTITY
  fk  id_endereco        → endereco   NULL
  varchar nome_pessoa    varchar(120) NOT NULL
  varchar email_pessoa   varchar(120) NOT NULL UNIQUE CHECK (formato)
  date    nascimento_pessoa date      NOT NULL

telefone
  pk  id_telefone        integer IDENTITY
  fk  id_pessoa          → pessoa  NOT NULL
  varchar numero_telefone varchar(20) NOT NULL
  boolean principal_telefone  NOT NULL DEFAULT false
  tipo_telefone_t        ENUM (celular, residencial, comercial) NOT NULL
  UNIQUE (id_pessoa, numero_telefone)
  -- índice parcial único: só um principal por pessoa

documento_pessoa
  pk  id_documento_pessoa integer IDENTITY
  fk  id_pessoa          → pessoa  NOT NULL
  varchar numero_documento_pessoa varchar(20) NOT NULL
  varchar orgao_documento_pessoa  varchar(20)
  date    emissao_documento_pessoa date
  tipo_documento_t       ENUM (cpf, rg, passaporte, cnh) NOT NULL
  UNIQUE (tipo_documento_t, numero_documento_pessoa)
  -- CHECK: se tipo = cpf então numero ~ '^[0-9]{11}$'   (substitui cpf_t)

usuario
  pk  id_usuario         integer IDENTITY
  fk  id_pessoa          → pessoa  NOT NULL UNIQUE
  varchar login_usuario  varchar(60)  NOT NULL UNIQUE   -- = nome do ROLE no Postgres
  boolean ativo_usuario  NOT NULL DEFAULT true
  papel_usuario_t        ENUM (aluno, secretaria, coordenacao, admin) NOT NULL

professor
  pk  id_professor       integer IDENTITY
  fk  id_pessoa          → pessoa        NOT NULL UNIQUE
  fk  id_departamento    → departamento  NOT NULL
  varchar matricula_professor varchar(12) NOT NULL UNIQUE
  regime_professor_t     ENUM (horista, parcial, integral) NOT NULL
  titulacao_t            ENUM (graduacao, especializacao, mestrado, doutorado, pos_doutorado) NOT NULL

formacao_professor
  pk  id_formacao_professor integer IDENTITY
  fk  id_professor       → professor  NOT NULL
  varchar curso_formacao_professor      varchar(120) NOT NULL
  varchar instituicao_formacao_professor varchar(120) NOT NULL
  smallint ano_conclusao_formacao_professor NOT NULL CHECK 1950–2100
  titulacao_t            NOT NULL

aluno
  pk  id_aluno           integer IDENTITY
  fk  id_pessoa          → pessoa     NOT NULL UNIQUE
  fk  id_curso           → curso      NOT NULL
  fk  id_curriculo       → curriculo  NOT NULL
  varchar matricula_aluno varchar(12) NOT NULL UNIQUE
  date    ingresso_aluno  NOT NULL
  forma_ingresso_t       ENUM (vestibular, enem, transferencia, portador_diploma) NOT NULL
  status_aluno_t         ENUM (ativo, trancado, formado, evadido, jubilado) NOT NULL DEFAULT 'ativo'
  FK composta (id_curriculo, id_curso) → curriculo (id_curriculo, id_curso)   -- [C6] mantido
```

**Cardinalidades**
- `pessoa (0,1) — endereco (0,N)`
- `telefone (1,1) — pessoa (0,N)`
- `documento_pessoa (1,1) — pessoa (1,N)` — toda pessoa precisa de ao menos um documento (garantido por trigger/deferrable)
- `usuario (1,1) — pessoa (0,1)`
- `professor (1,1) — pessoa (0,1)` · `aluno (1,1) — pessoa (0,1)`
- `professor (1,1) — departamento (0,N)`
- `formacao_professor (1,1) — professor (0,N)`
- `aluno (1,1) — curso (0,N)` · `aluno (1,1) — curriculo (0,N)`

---

## 3. Estrutura física e organizacional

```
campus
  pk  id_campus          smallint IDENTITY
  fk  id_endereco        → endereco  NOT NULL
  varchar nome_campus    varchar(60) NOT NULL UNIQUE
  -- cidade_campus REMOVIDA (vem de endereco → cidade)

departamento
  pk  id_departamento    smallint IDENTITY
  fk  id_campus          → campus     NOT NULL
  fk  id_professor_chefe → professor  NULL      -- FK circular com professor: criar depois
  varchar nome_departamento  varchar(80) NOT NULL
  varchar sigla_departamento varchar(10) NOT NULL UNIQUE

predio
  pk  id_predio          smallint IDENTITY
  fk  id_campus          → campus  NOT NULL
  varchar nome_predio    varchar(60) NOT NULL
  smallint andares_predio  CHECK > 0
  UNIQUE (id_campus, nome_predio)

sala
  pk  id_sala            integer IDENTITY
  fk  id_predio          → predio  NOT NULL     -- substitui id_campus
  varchar codigo_sala    varchar(10) NOT NULL
  smallint andar_sala
  smallint capacidade_sala NOT NULL CHECK > 0
  tipo_sala_t            NOT NULL DEFAULT 'teorica'
  UNIQUE (id_predio, codigo_sala)

recurso
  pk  id_recurso         smallint IDENTITY
  varchar nome_recurso   varchar(60) NOT NULL UNIQUE

sala_recurso
  pk/fk id_sala          → sala
  pk/fk id_recurso       → recurso
  smallint quantidade_sala_recurso NOT NULL DEFAULT 1 CHECK > 0
```

**Cardinalidades**
- `campus (1,1) — endereco (0,1)`
- `departamento (1,1) — campus (0,N)` · `departamento (0,1) — professor_chefe (0,1)`
- `predio (1,1) — campus (0,N)`
- `sala (1,1) — predio (0,N)`
- `sala (0,N) — recurso (0,N)` via `sala_recurso`

---

## 4. Estrutura acadêmica

```
curso
  pk  id_curso           smallint IDENTITY
  fk  id_campus          → campus        NOT NULL
  fk  id_departamento    → departamento  NOT NULL
  varchar codigo_curso   varchar(10)  NOT NULL UNIQUE
  varchar nome_curso     varchar(120) NOT NULL
  integer ch_total_curso NOT NULL CHECK > 0
  grau_curso_t           ENUM (bacharelado, licenciatura, tecnologo) NOT NULL   -- substitui varchar(20)
  modalidade_t           ENUM (presencial, ead, hibrido) NOT NULL DEFAULT 'presencial'

coordenacao_curso
  pk  id_coordenacao_curso integer IDENTITY
  fk  id_curso           → curso      NOT NULL
  fk  id_professor       → professor  NOT NULL
  varchar portaria_coordenacao_curso varchar(30)
  daterange vigencia_coordenacao_curso NOT NULL
  EXCLUDE USING gist (id_curso WITH =, vigencia WITH &&)   -- um coordenador por vez

curriculo
  pk  id_curriculo       integer IDENTITY
  fk  id_curso           → curso  NOT NULL
  varchar portaria_curriculo varchar(30)
  smallint ano_vigencia_curriculo NOT NULL CHECK 1990–2100
  boolean ativo_curriculo NOT NULL DEFAULT true
  UNIQUE (id_curso, ano_vigencia_curriculo)
  UNIQUE (id_curriculo, id_curso)   -- alvo da FK composta [C6]

disciplina
  pk  id_disciplina      integer IDENTITY
  fk  id_departamento    → departamento  NOT NULL
  varchar codigo_disciplina varchar(10)  NOT NULL UNIQUE
  varchar nome_disciplina   varchar(120) NOT NULL
  text    ementa_disciplina
  smallint ch_teorica_disciplina NOT NULL DEFAULT 0
  smallint ch_pratica_disciplina NOT NULL DEFAULT 0
  smallint ch_total_disciplina   GENERATED ALWAYS AS (teorica + pratica) STORED
  CHECK (ch_teorica + ch_pratica > 0)

curriculo_disciplina
  pk/fk id_curriculo     → curriculo
  pk/fk id_disciplina    → disciplina
  smallint periodo_curriculo_disciplina NOT NULL CHECK 1–12
  tipo_disc_t            NOT NULL DEFAULT 'obrigatoria'

pre_requisito
  pk/fk id_disciplina    → disciplina     -- a que depende (ex.: BD2)
  pk/fk id_requisito     → disciplina     -- a exigida   (ex.: BD1)
  numeric(4,2) media_minima_pre_requisito NOT NULL DEFAULT 5.00 CHECK 0–10
  smallint     ch_minima_pre_requisito    NULL CHECK > 0   -- alternativa por CH acumulada
  vinculo_t              NOT NULL DEFAULT 'pre_requisito'  -- pre_requisito | co_requisito
  CHECK (id_disciplina <> id_requisito)   -- ciclo de nível > 1 barrado por trigger com CTE recursiva

aproveitamento_materia
  pk  id_aproveitamento_materia integer IDENTITY
  fk  id_aluno           → aluno       NOT NULL
  fk  id_disciplina      → disciplina  NOT NULL      -- disciplina do IESB dispensada
  fk  id_usuario_avaliador → usuario   NULL          -- quem deferiu/indeferiu
  varchar disciplina_origem_aproveitamento_materia  varchar(120) NOT NULL
  varchar instituicao_origem_aproveitamento_materia varchar(120) NOT NULL
  text    parecer_aproveitamento_materia
  smallint ch_origem_aproveitamento_materia NOT NULL CHECK > 0
  numeric(4,2) nota_origem_aproveitamento_materia NOT NULL CHECK 0–10
  date    solicitacao_aproveitamento_materia NOT NULL DEFAULT current_date
  date    decisao_aproveitamento_materia
  status_aproveitamento_t ENUM (pendente, deferido, indeferido) NOT NULL DEFAULT 'pendente'
  UNIQUE (id_aluno, id_disciplina)
  -- Regras (trigger, pois cruzam tabela):
  --   deferido exige ch_origem >= disciplina.ch_total_disciplina
  --   deferido exige nota_origem >= 5.00
  --   deferido exige aluno.forma_ingresso = 'transferencia' ou 'portador_diploma'
```

**Como o pré-requisito é validado na matrícula** (função `pode_cursar(id_aluno, id_disciplina)`):

Para cada linha de `pre_requisito` da disciplina alvo, o aluno satisfaz o requisito se **uma** das condições vale:
1. **Histórico** — existe `historico` com `situacao = aprovado` e `media_final >= media_minima_pre_requisito` na disciplina `id_requisito`;
2. **Aproveitamento** — existe `aproveitamento_materia` com `status = deferido` para `id_requisito`;
3. **CH acumulada** — se `ch_minima_pre_requisito` não for nula, soma de `ch_total` das disciplinas aprovadas/aproveitadas ≥ esse valor.

A árvore inteira (BD2 → BD1 → Lógica → …) é percorrida por CTE recursiva; é a consulta obrigatória do Marco 1.

**Cardinalidades**
- `curso (1,1) — campus (0,N)` · `curso (1,1) — departamento (0,N)`
- `coordenacao_curso (1,1) — curso (0,N)` · `coordenacao_curso (1,1) — professor (0,N)`
- `curriculo (1,1) — curso (1,N)`
- `disciplina (1,1) — departamento (0,N)`
- `curriculo (0,N) — disciplina (0,N)` via `curriculo_disciplina`
- `disciplina (0,N) — disciplina (0,N)` via `pre_requisito` (auto-relacionamento)
- `aproveitamento_materia (1,1) — aluno (0,N)` · `— disciplina (0,N)` · `(0,1) — usuario (0,N)`

---

## 5. Plano de ensino

Plano é **por turma** (cada professor monta o seu para a oferta).

```
plano_ensino
  pk  id_plano_ensino    integer IDENTITY
  fk  id_turma           → turma  NOT NULL UNIQUE
  text objetivo_plano_ensino
  text metodologia_plano_ensino
  text criterio_avaliacao_plano_ensino
  date aprovacao_plano_ensino

unidade_plano_ensino
  pk  id_unidade_plano_ensino integer IDENTITY
  fk  id_plano_ensino    → plano_ensino  NOT NULL
  varchar titulo_unidade_plano_ensino varchar(120) NOT NULL
  text    conteudo_unidade_plano_ensino
  smallint ordem_unidade_plano_ensino NOT NULL CHECK > 0
  smallint ch_unidade_plano_ensino    NOT NULL CHECK > 0
  UNIQUE (id_plano_ensino, ordem_unidade_plano_ensino)
  -- trigger: soma de ch_unidade <= disciplina.ch_total

bibliografia
  pk  id_bibliografia    integer IDENTITY
  varchar titulo_bibliografia  varchar(200) NOT NULL
  varchar autor_bibliografia   varchar(120) NOT NULL
  varchar editora_bibliografia varchar(80)
  char    isbn_bibliografia    char(13) UNIQUE
  smallint ano_bibliografia    CHECK 1800–2100
  smallint edicao_bibliografia CHECK > 0

plano_ensino_bibliografia
  pk/fk id_plano_ensino  → plano_ensino
  pk/fk id_bibliografia  → bibliografia
  tipo_bibliografia_t    ENUM (basica, complementar) NOT NULL
```

**Cardinalidades**
- `plano_ensino (1,1) — turma (0,1)`
- `unidade_plano_ensino (1,1) — plano_ensino (1,N)`
- `plano_ensino (0,N) — bibliografia (0,N)` via `plano_ensino_bibliografia`

---

## 6. Tempo e calendário

```
periodo_letivo
  pk  id_periodo_letivo  smallint IDENTITY
  smallint ano_periodo_letivo      NOT NULL
  smallint semestre_periodo_letivo NOT NULL CHECK IN (1,2)
  date data_inicio_periodo_letivo  NOT NULL
  date data_fim_periodo_letivo     NOT NULL
  UNIQUE (ano, semestre) · CHECK (inicio < fim)

periodo_matricula
  pk  id_periodo_matricula integer IDENTITY
  fk  id_periodo_letivo  → periodo_letivo  NOT NULL
  varchar descricao_periodo_matricula varchar(60) NOT NULL
  tstzrange janela_periodo_matricula  NOT NULL
  tipo_periodo_matricula_t ENUM (matricula, ajuste, trancamento, rematricula) NOT NULL
  EXCLUDE USING gist (id_periodo_letivo WITH =, tipo WITH =, janela WITH &&)
  -- função de matrícula só aceita INSERT se now() <@ janela de tipo 'matricula' ou 'ajuste'

feriado
  pk  id_feriado         integer IDENTITY
  fk  id_pais            → pais    NULL
  fk  id_estado          → estado  NULL
  fk  id_cidade          → cidade  NULL
  fk  id_campus          → campus  NULL     -- feriado institucional
  varchar descricao_feriado varchar(120) NOT NULL
  date    data_feriado   NOT NULL
  tipo_feriado_t         ENUM (nacional, estadual, municipal, institucional, ponto_facultativo) NOT NULL
  CHECK: exatamente uma das 4 FKs não nula, coerente com tipo_feriado_t
  -- substitui o "NULL = nacional"; campus herda feriados da sua cidade/estado/país por view
```

**Cardinalidades**
- `periodo_matricula (1,1) — periodo_letivo (1,N)`
- `feriado (1,1) — { pais | estado | cidade | campus } (0,N)` — arco exclusivo

---

## 7. Oferta e docência

```
turma
  pk  id_turma           integer IDENTITY
  fk  id_disciplina      → disciplina      NOT NULL
  fk  id_periodo_letivo  → periodo_letivo  NOT NULL
  varchar codigo_turma   varchar(15) NOT NULL
  smallint vagas_turma   NOT NULL CHECK >= 0
  turno_t                NOT NULL
  modalidade_t           NOT NULL DEFAULT 'presencial'
  UNIQUE (id_periodo_letivo, codigo_turma)
  UNIQUE (id_turma, id_periodo_letivo)    -- alvo da FK composta [C10]
  -- id_professor REMOVIDO → turma_professor

turma_professor
  pk/fk id_turma         → turma
  pk/fk id_professor     → professor
  papel_docente_t        ENUM (titular, auxiliar, substituto) NOT NULL DEFAULT 'titular'
  -- índice parcial único: um titular por turma

turma_horario
  pk  id_turma_horario   integer IDENTITY
  fk  id_turma           → turma            NOT NULL
  fk  id_periodo_letivo  → periodo_letivo   NOT NULL
  fk  id_sala            → sala             NOT NULL
  smallint dia_semana_turma_horario NOT NULL CHECK 1–7
  timerange faixa_turma_horario     NOT NULL CHECK not isempty
  tipo_aula_t            ENUM (teorica, pratica) NOT NULL DEFAULT 'teorica'
  FK composta (id_turma, id_periodo_letivo) → turma   [C10]
  EXCLUDE gist (periodo =, sala =, dia =, faixa &&)
  EXCLUDE gist (turma =, dia =, faixa &&)
  -- EXCLUDE de professor no mesmo horário passa a ser trigger (professor está em turma_professor)
```

**Cardinalidades**
- `turma (1,1) — disciplina (0,N)` · `turma (1,1) — periodo_letivo (0,N)`
- `turma (1,N) — professor (0,N)` via `turma_professor`
- `turma_horario (1,1) — turma (1,N)` · `turma_horario (1,1) — sala (0,N)`

---

## 8. Matrícula e histórico

```
matricula
  pk  id_matricula       integer IDENTITY
  fk  id_aluno           → aluno  NOT NULL
  fk  id_turma           → turma  NOT NULL
  timestamptz data_matricula NOT NULL DEFAULT now()
  status_mat_t           NOT NULL DEFAULT 'pendente'
  UNIQUE (id_aluno, id_turma)
  -- trigger BEFORE INSERT: pode_cursar() + janela de periodo_matricula + vaga (aqui mora a anomalia)

historico
  pk  id_historico       integer IDENTITY
  fk  id_matricula       → matricula  NOT NULL UNIQUE
  date data_fechamento_historico
  situacao_t             NOT NULL DEFAULT 'cursando'
  -- nota_a1/a2/p3, frequencia e media_final SAEM: são derivadas de nota/presenca.
  -- Expostas na MV mv_historico_consolidado (política de refresh: ao fechar o período letivo).

log_matricula
  pk  id_log_matricula   bigint IDENTITY
  fk  id_matricula       → matricula  NULL   -- sem FK física de propósito [C11]
  fk  id_usuario         → usuario    NOT NULL DEFAULT (usuario da sessão)
  timestamptz ocorrido_em_log_matricula NOT NULL DEFAULT now()
  jsonb   detalhe_log_matricula            -- bônus: índice GIN
  acao_log_t             ENUM (insert, update, delete) NOT NULL
```

**Cardinalidades**
- `matricula (1,1) — aluno (0,N)` · `matricula (1,1) — turma (0,N)`
- `historico (1,1) — matricula (0,1)`
- `log_matricula (1,1) — usuario (0,N)` · `log_matricula (0,1) ⋯ matricula (0,N)` lógica

---

## 9. Aula e avaliação

```
aula
  pk  id_aula            integer IDENTITY
  fk  id_turma_horario   → turma_horario  NOT NULL
  fk  id_unidade_plano_ensino → unidade_plano_ensino  NULL
  text conteudo_aula
  date data_aula         NOT NULL
  boolean realizada_aula NOT NULL DEFAULT true
  UNIQUE (id_turma_horario, data_aula)
  -- trigger: data_aula não pode cair em feriado aplicável ao campus da sala

presenca
  pk/fk id_aula          → aula
  pk/fk id_matricula     → matricula
  boolean presente_presenca NOT NULL DEFAULT true
  -- trigger: matricula.turma = aula.turma_horario.turma

avaliacao
  pk  id_avaliacao       integer IDENTITY
  fk  id_turma           → turma  NOT NULL
  varchar nome_avaliacao varchar(60) NOT NULL   -- "A1", "A2", "P3", "Projeto"
  numeric(4,2) peso_avaliacao NOT NULL CHECK > 0
  date data_avaliacao
  UNIQUE (id_turma, nome_avaliacao)
  -- trigger: soma dos pesos por turma = 10 (ou 1) antes de fechar o período

nota
  pk/fk id_avaliacao     → avaliacao
  pk/fk id_matricula     → matricula
  numeric(4,2) valor_nota NOT NULL CHECK 0–10   -- DOMAIN nota_t
  -- trigger: matricula.turma = avaliacao.turma
```

**Cardinalidades**
- `aula (1,1) — turma_horario (0,N)` · `aula (0,1) — unidade_plano_ensino (0,N)`
- `aula (0,N) — matricula (0,N)` via `presenca`
- `avaliacao (1,1) — turma (0,N)`
- `avaliacao (0,N) — matricula (0,N)` via `nota`

---

## 10. Derivados (views / MV) — o que saiu das tabelas

| Derivado | Fonte | Forma |
|---|---|---|
| `cidade_campus` | campus → endereco → cidade | view `vw_campus` |
| `nome_aluno`, `cpf_aluno`, `email_aluno` | pessoa, documento_pessoa | view `vw_aluno` |
| `id_professor` da turma | turma_professor (titular) | view `vw_turma_oferta` |
| `nota_a1/a2/p3`, `media_final` | nota × avaliacao (média ponderada) | MV `mv_historico_consolidado` |
| `frequencia_historico` | presenca / aula realizadas | MV `mv_historico_consolidado` |
| vagas restantes | vagas_turma − count(matricula confirmada) | view `vw_vagas` (a da disputa) |
| feriados do campus | feriado ∪ hierarquia geográfica | view `vw_feriado_campus` |

---

## 11. Ordem de criação (dependências)

1. pais → estado → cidade → endereco
2. pessoa → telefone → documento_pessoa → usuario
3. campus → departamento (sem FK chefe) → predio → sala → recurso → sala_recurso
4. professor → `ALTER departamento ADD FK id_professor_chefe` → formacao_professor
5. curso → coordenacao_curso → curriculo → disciplina → curriculo_disciplina → pre_requisito
6. aluno → aproveitamento_materia
7. periodo_letivo → periodo_matricula → feriado
8. turma → turma_professor → turma_horario
9. plano_ensino → unidade_plano_ensino → bibliografia → plano_ensino_bibliografia
10. matricula → historico → log_matricula
11. aula → presenca → avaliacao → nota
12. views, MVs, funções (`pode_cursar`), triggers, índices, roles/RLS
