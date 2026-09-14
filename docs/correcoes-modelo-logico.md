# Análise crítica do modelo de partida — o que verificamos, o que corrigimos

> Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
>
> Cada item tem um código `C#` que aparece como comentário no ponto exato do
> [sql/01_ddl.sql](../sql/01_ddl.sql).

## Metodologia

Esta análise é medida contra **`docs/banco_de_dados_matricula_com_erros.sql`** —
o arquivo de partida do professor, 397 linhas —, não contra o diagrama do modelo
lógico. A diferença importa: o diagrama não expressa `CHECK`, `EXCLUDE` nem
colunas geradas, e uma leitura só do diagrama sugere ausências que o SQL não tem.

O procedimento foi executável, não interpretativo:

1. o arquivo do professor foi carregado num banco descartável em PostgreSQL 17;
2. o catálogo (`pg_constraint`, `information_schema`) foi inspecionado para
   listar o que **de fato** existe;
3. cada suposto defeito foi testado por inserção — se o banco aceitou o dado
   inválido, o defeito é real; se rejeitou, não é.

**Resultado de partida, que convém dizer sem rodeios: o DDL do professor roda
limpo, sem um único erro, e já traz a maior parte das restrições de integridade
básicas.** Os defeitos reais são mais sutis do que ausência de `UNIQUE` — e são
os que interessam.

---

## Parte 1 — O que conferimos e está correto no modelo

Análise crítica também é dizer o que não precisa mudar. Verificado por execução:

| Elemento no modelo do professor | Onde | Situação |
|---|---|---|
| `CREATE TYPE timerange AS RANGE (subtype = time)` | linha 21 | ✅ presente — o DDL roda |
| `matricula UNIQUE (aluno_id, turma_id)` | linha 162 | ✅ impede matrícula duplicada |
| `periodo_letivo UNIQUE (ano, semestre)` | linha 105 | ✅ |
| `periodo_letivo CHECK (semestre IN (1,2))` | linha 102 | ✅ |
| `periodo_letivo CHECK (data_fim > data_inicio)` | linha 106 | ✅ |
| `sala UNIQUE (campus_id, codigo)` | linha 95 | ✅ código único por campus |
| `curriculo UNIQUE (curso_id, ano_vigencia)` | linha 45 | ✅ |
| `curriculo` índice único parcial `WHERE ativo` | linhas 48-49 | ✅ um currículo ativo por curso |
| `pre_requisito CHECK (disciplina_id <> requisito_id)` | linha 76 | ✅ barra o autociclo |
| `disciplina.ch_total GENERATED ... STORED` | linha 57 | ✅ com fórmula |
| `historico.media_final GENERATED ... STORED` | linhas 174-181 | ✅ com fórmula (mas ver E5) |
| `nota_t`, `pct_t` como `DOMAIN` com `CHECK` | linhas 17-18 | ✅ |
| 6 `ENUM` (`turno_t`, `tipo_disc_t`, `vinculo_t`, `status_mat_t`, `situacao_t`, `tipo_sala_t`) | linhas 10-15 | ✅ definidos |
| `NOT NULL` e `CHECK` de sanidade | espalhados | ✅ abundantes |

Essas restrições foram **mantidas** no nosso DDL. Onde reimplementamos, foi por
igual ou por endurecimento explícito (Parte 3), nunca porque faltavam.

---

## Parte 2 — Os erros reais

### E1 · A anomalia da última vaga está no trigger `fn_valida_vaga()`

**Onde:** linhas 194-218.

```sql
SELECT count(*) INTO v_ocupadas FROM matricula WHERE turma_id = NEW.turma_id ...;
IF v_ocupadas >= v_vagas THEN RAISE EXCEPTION ...
```

**Problema:** *check-then-act* clássico. Entre o `count(*)` e a gravação da linha
não há nada que impeça outra sessão de fazer exatamente o mesmo. Em Read
Committed — o isolamento padrão — duas sessões leem a mesma contagem, ambas
passam no `IF`, e a turma fecha com mais matrículas do que vagas.

Um trigger `BEFORE INSERT` **não** é mecanismo de exclusão mútua. Ele dá a
aparência de proteção, que é pior do que não ter proteção nenhuma: quem lê o DDL
conclui que a regra está garantida.

**Correção:** é o cerne do Marco 2 e tem duas implementações comparadas em
[sql/07_transacoes.sql](../sql/07_transacoes.sql) — bloqueio explícito
(`SELECT ... FOR UPDATE`, correção A, adotada) e nível de isolamento
(`SERIALIZABLE` + retentativa em 40001, correção B, documentada). Evidência
capturada em [docs/evidencias/transacoes-demo.md](evidencias/transacoes-demo.md).

**Este é o erro mais importante do modelo** e é deliberado: o enunciado pede
exatamente que a anomalia seja reproduzida e corrigida.

### E2 · A restrição de exclusão é forte demais, não fraca

**Onde:** linhas 138-140.

```sql
EXCLUDE USING gist (sala_id WITH =, dia_semana WITH =, faixa WITH &&)
```

**Problema:** falta o **período letivo**. A restrição não distingue semestres,
então uma sala ocupada na segunda das 08:15 às 11:00 em 2026/2 fica bloqueada
naquele horário **para sempre**, em todos os semestres seguintes. O modelo não
falha em impedir o choque — impede coisa demais, e impede reuso legítimo.

Verificado: inserir horário idêntico numa turma de outro período letivo é
rejeitado com `conflicting key value violates exclusion constraint
"ex_sala_ocupada"`.

**Correção [C10]:** acrescentar o período ao escopo da restrição.

```sql
EXCLUDE USING gist (periodo_letivo_id WITH =, sala_id WITH =,
                    dia_semana WITH =, faixa WITH &&)
```

**Decisão de projeto embutida:** `turma_horario` não tem o período letivo — ele
vive em `turma`. Para que a restrição possa vê-lo, **denormalizamos**
`periodo_letivo_id` para dentro de `turma_horario`, amarrado por FK composta
`(turma_id, periodo_letivo_id) → turma (id, periodo_letivo_id)`. A
denormalização é **controlada**: por construção não pode divergir da turma.

É uma violação deliberada da 3FN que compra uma garantia de integridade que a
forma normal não conseguiria expressar — e o risco que a 3FN existe para
prevenir (a cópia divergir) é fechado pela FK composta.

Acrescentamos ainda `EXCLUDE (turma_id WITH =, dia_semana WITH =, faixa WITH &&)`
— a própria turma não pode ter dois horários sobrepostos — e
`CHECK (NOT isempty(faixa))`.

### E3 · Feriado nacional é infinitamente duplicável

**Onde:** linha 114, `UNIQUE (data, campus_id)`.

**Problema:** a unicidade existe, mas `campus_id` é anulável e **dois NULLs nunca
conflitam entre si** num `UNIQUE` comum. Com a convenção "NULL = feriado
nacional", o mesmo feriado nacional pode ser cadastrado quantas vezes se quiser.

Verificado: um segundo "07/09 com `campus_id` NULL" foi aceito; a tabela ficou
com duas linhas para a mesma data.

**Correção [C9]:** `UNIQUE NULLS NOT DISTINCT (campus_id, data)`, recurso do
PostgreSQL 15+, que faz NULLs conflitarem entre si. E a semântica do NULL passa a
ser documentada no `COMMENT`: NULL = feriado nacional, vale para todos os campi.

### E4 · `aluno` pode apontar para o currículo de outro curso

**Onde:** linhas 150-151.

```sql
curso_id      smallint NOT NULL REFERENCES curso,
curriculo_id  integer  NOT NULL REFERENCES curriculo
```

**Problema:** duas chaves estrangeiras **independentes**. Cada uma é válida
isoladamente, e nada impede um aluno de Ciência da Computação apontar para um
currículo de Direito. `curriculo` já pertence a um curso (`curriculo.curso_id`),
então há uma dependência transitiva desprotegida.

**Correção [C6]:** manter as duas colunas — como no modelo — e amarrá-las com
**FK composta**:

```sql
FOREIGN KEY (curriculo_id, curso_id) REFERENCES curriculo (id, curso_id)
```

Exige `UNIQUE (id, curso_id)` em `curriculo` — uma superchave da PK, barata e
legítima. Agora o currículo do aluno é, por construção, um currículo do curso do
aluno.

### E5 · A fórmula da média pode punir quem faz a P3

**Onde:** linhas 174-181.

```sql
ELSE round(greatest(0.4*nota_p3 + 0.6*nota_a2,
                    0.4*nota_a1 + 0.6*nota_p3), 2)
```

**Problema:** o `GREATEST` tem dois termos e **falta o terceiro**,
`0.4*nota_a1 + 0.6*nota_a2` — a média sem P3. Um aluno que já passaria com A1 e
A2, fizer a P3 e for mal, termina com média **menor** do que teria se não tivesse
feito a prova. A P3 é substitutiva; ela nunca deveria piorar o resultado.

**Correção [C13]:** incluir os três termos.

```sql
GREATEST(0.4*a1 + 0.6*a2, 0.4*p3 + 0.6*a2, 0.4*a1 + 0.6*p3)
```

NULL enquanto A1 e A2 não estiverem lançadas. Por ser `GENERATED ALWAYS ...
STORED`, é **impossível** existir média inconsistente com as notas — a regra é do
banco, não da aplicação. `STORED` é a única modalidade disponível no PG 17, e é o
que torna a coluna indexável (ver o índice B-tree de `06_indices.sql`).

### E6 · Índice redundante

**Onde:** linha 225, `CREATE INDEX ix_matricula_aluno ON matricula (aluno_id)`.

**Problema:** a restrição `UNIQUE (aluno_id, turma_id)` da linha 162 já cria um
índice cuja **coluna líder** é `aluno_id`. Um índice B-tree multicoluna atende
consultas sobre qualquer prefixo à esquerda, então `ix_matricula_aluno` não
acrescenta capacidade de busca — só custo de manutenção em cada `INSERT`,
`UPDATE` e `DELETE`, e espaço em disco.

**Correção:** não replicamos esse índice. Os 4 índices de
[sql/06_indices.sql](../sql/06_indices.sql) cobrem padrões de acesso que as
restrições **não** já atendem. Saber justificar o índice ausente vale tanto
quanto justificar os presentes.

### E7 · A unicidade de `turma` é mais fraca do que parece

**Onde:** linha 125, `UNIQUE (codigo, periodo_letivo_id, disciplina_id)`.

**Problema:** ao incluir `disciplina_id` na chave, o mesmo código de turma pode
se repetir no mesmo período letivo, desde que em disciplinas diferentes. Duas
turmas "CCODM2B" em 2026/2 seriam aceitas. O código de turma é o identificador
que aparece no sistema acadêmico e em documento de matrícula — repetido no mesmo
semestre, ele deixa de identificar.

**Correção [C5]:** `UNIQUE (periodo_letivo_id, codigo)`. O código se repete
**entre** semestres (a cada nova oferta), mas não **dentro** do mesmo.

### E8 · Ciclos em `pre_requisito` (limite conhecido, não corrigível em constraint)

`CHECK (disciplina_id <> requisito_id)` barra `A→A`. Verificado: `A→B` seguido de
`B→A` é aceito — um par de disciplinas mutuamente pré-requisito, que nenhum aluno
jamais poderia cursar.

Ciclos maiores não são expressáveis em restrição declarativa: exigem travessia
recursiva do grafo. A **consulta 5** ([03_consultas.sql](../sql/03_consultas.sql))
percorre a árvore de pré-requisitos com proteção de ciclo e serve de ferramenta
de auditoria. Tratamento definitivo por trigger é candidato registrado, não
implementado.

### E9 · Rótulos de ENUM divergentes entre o modelo e o nosso DDL

O professor usa `'MATRICULADO','TRANCADO','CANCELADO'` em `status_mat_t`; nosso
DDL usa `'pendente','confirmada','trancada','cancelada'` — caixa e conjunto
diferentes. Consequência prática: dados e exemplos do material de aula não rodam
no nosso banco sem tradução.

**Decisão:** mantemos os nossos rótulos, por dois motivos — o conjunto é mais
completo (`pendente` distingue a matrícula em processamento da confirmada, o que
a transação da última vaga usa) e minúsculas seguem a convenção do restante do
esquema. Divergência **deliberada e registrada**, não descuido.

---

## Parte 3 — Endurecimentos e decisões de projeto

Itens em que o modelo não está errado, mas fomos além.

### C12 · `cpf_t` e checks adicionais

O modelo define `nota_t` e `pct_t`, mas valida CPF com `CHECK` inline
(`cpf char(11) ... CHECK (cpf ~ '^[0-9]{11}$')`). Promovemos a `DOMAIN cpf_t`:
a regra passa a ser reutilizável e declarada num lugar só.

Critério **enum vs. domain** que adotamos, e que vale ter na ponta da língua:
`ENUM` para conjuntos fechados de rótulos controlados pelo DBA; `DOMAIN` para
restrição de faixa ou formato sobre um tipo base.

Acrescentamos ainda checks de sanidade que o modelo não traz — `nascimento <
ingresso`, entre outros — e `NOT NULL` por padrão, com as exceções documentadas
coluna a coluna no DDL.

### C2 · Nota sobre re-matrícula

Mantivemos `UNIQUE (aluno_id, turma_id)` total, como no modelo. Uma alternativa
mais permissiva seria índice único parcial (`WHERE status <> 'cancelada'`),
permitindo rematrícula após cancelamento. Optamos pela restrição total: mais
simples de defender, e o cancelamento preserva a linha para fins de histórico.

### C11 · `log_matricula` sem FK — decisão documentada

**Onde:** linha 186, `matricula_id integer NOT NULL` sem `REFERENCES`.

Isso **não é um erro a corrigir**. Mantivemos sem FK, de propósito: é trilha de
auditoria, e o registro de log deve sobreviver à remoção da matrícula que o
originou. Com FK + `CASCADE`, o log sumiria junto; com `RESTRICT`, impediria o
expurgo.

Comprovado na prática durante o desenvolvimento: um `DELETE` acidental em
`matricula` levou `historico` junto por `CASCADE` e **deixou os logs intactos** —
que é exatamente o comportamento desejado de uma trilha de auditoria.

Alternativa rejeitada: FK com `ON DELETE SET NULL` — perderíamos a referência
histórica no expurgo, que é justamente o que o log quer preservar.

### C1 · `timerange`

O modelo já cria o tipo (linha 21). Reproduzimos a criação no nosso DDL porque
ele constrói o schema do zero. Tipos range criados assim ganham `&&` e suporte
GiST automaticamente, o que viabiliza [C10].

### C15 · Schema `academico` em vez de `public`

**Onde:** o modelo do professor abre com `DROP SCHEMA IF EXISTS academico
CASCADE; CREATE SCHEMA academico; SET search_path TO academico, public;`
(linhas 3-5) — e o material da Aula 2 faz o mesmo.

Nossa versão anterior usava `DROP SCHEMA public CASCADE; CREATE SCHEMA public`.
Corrigido, por duas razões independentes:

1. **Alinhamento.** Todo exemplo do material de aula pressupõe `academico`.
2. **Escopo do reset.** `DROP SCHEMA public CASCADE` derruba junto extensões e
   quaisquer objetos de terceiros instalados no schema padrão do banco. Um schema
   próprio dá o mesmo reset determinístico com escopo restrito ao que é nosso.

Detalhes da implementação que valem menção na arguição:

- a extensão `btree_gist` é instalada **explicitamente em `public`**
  (`CREATE EXTENSION ... SCHEMA public`), porque `academico` é derrubado a cada
  execução e uma extensão instalada lá morreria junto. Schema estável para
  infraestrutura, schema próprio para os dados;
- `ALTER DATABASE matricula SET search_path TO academico, public` faz sessões
  novas (psql, pgAdmin, DBeaver, roteiros de demo) nascerem com o caminho certo;
- cada script fixa o próprio `search_path`, para ser executável isoladamente;
- a função `aluno_id_de()`, que é `SECURITY DEFINER`, tem
  `SET search_path = academico` — obrigatório em `SECURITY DEFINER` e agora
  apontando para o schema certo. Se tivesse ficado em `public`, o RLS quebraria
  em silêncio.

### C14 · Nomenclatura de chaves — APLICADA

PK `id_<tabela>` e FK com o mesmo nome da PK referenciada
(`curso.id_campus → campus.id_campus`), habilitando `JOIN ... USING (id_campus)`.

O modelo do professor usa `id` + `<tabela>_id`, que é uma convenção **coerente**
— não um erro. Nossa mudança é **padronização deliberada**, justificada por nome
autoexplicativo em consultas com muitas junções e pela possibilidade do `USING`.
**Executada na ampliação do modelo**: todas as 41 tabelas do `sql/01_ddl.sql`
seguem a convenção, e carga, consultas, views, índices, transações, segurança e
testes foram escritos sobre ela.

---

## Parte 4 — Regras que restrição declarativa não alcança

| Regra | Por que não é constraint | Tratamento |
|---|---|---|
| Nº de confirmadas ≤ `turma.vagas` | agregação sobre outra tabela | transação da última vaga (E1) — implementado |
| `turma.vagas` ≤ capacidade da sala | atravessa `turma_horario → sala` | validação em transação; não implementado |
| Choque de horário do **aluno** | atravessa `matricula × turma_horario` | consulta 9 detecta; regra de negócio pendente |
| Ciclos em `pre_requisito` | recursivo por natureza (E8) | consulta 5 audita; trigger candidata |
| Matrícula exige pré-requisitos aprovados | consulta recursiva sobre histórico | consulta 6 verifica |

---

## Resumo

| Código | Assunto | Situação no modelo | Nossa ação |
|---|---|---|---|
| C1 | `timerange` | ✅ já existe | reproduzido |
| C2 | `matricula` unicidade | ✅ já existe | mantido |
| C3 | `periodo_letivo` unicidade e checks | ✅ já existem | mantidos |
| C4 | `sala` unicidade por campus | ✅ já existe | mantido |
| C5 | `turma` unicidade | ⚠️ fraca (E7) | **endurecida** |
| C6 | `aluno` → currículo de outro curso | ❌ erro (E4) | **FK composta** |
| C7 | autociclo de pré-requisito | ✅ já existe | mantido; ciclos maiores em aberto (E8) |
| C8 | `curriculo` unicidade | ✅ já existe | mantido |
| C9 | feriado nacional duplicável | ❌ erro (E3) | **`NULLS NOT DISTINCT`** |
| C10 | `EXCLUDE` sem período letivo | ❌ erro (E2) | **escopo corrigido + denormalização controlada** |
| C11 | `log_matricula` sem FK | ✅ decisão correta | mantida de propósito |
| C12 | domínios e checks | ⚠️ quase completo | `cpf_t` + checks adicionais |
| C13 | `media_final` pune quem faz P3 | ❌ erro (E5) | **terceiro termo no `GREATEST`** |
| C14 | nomenclatura de chaves | — convenção do professor | padronização deliberada — **pendente** |
| C15 | schema `academico` | ❌ nossa divergência | **corrigida** |
| — | índice redundante | ❌ erro (E6) | não replicado |
| — | rótulos de ENUM | — divergência nossa (E9) | mantida e justificada |

**4 erros de integridade reais** (E2, E3, E4, E5), **1 erro de concorrência**
(E1, o cerne do Marco 2), **1 de desempenho** (E6), **1 de unicidade fraca**
(E7), **1 limite estrutural** (E8), **8 restrições conferidas e corretas**, e
**2 divergências deliberadas nossas** (C14, E9).
