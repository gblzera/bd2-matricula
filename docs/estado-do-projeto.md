# Estado do projeto — resumo, decisões e pendências

> Documento de handoff. Escrito em 17/08/2026 ao fim de uma sessão de trabalho;
> serve para retomar o projeto em qualquer contexto (outro chat, outro colega,
> outra máquina) sem depender de histórico de conversa. **Atualizar sempre que
> uma decisão mudar.**

---

## 1. O projeto em uma tela

| Item | Valor |
|---|---|
| Disciplina | Banco de Dados II (CCO072) · IESB · 2026/2 · Prof. Rodrigo Gonçalves |
| Tema | Sistema de Matrícula Acadêmica — modelo lógico fornecido pelo professor, com erros propositais |
| SGBD | PostgreSQL 17 (Docker oficial da disciplina, cópia em `ambiente/`) |
| Repositório | https://github.com/gblzera/bd2-matricula — **público** desde 13/09/2026 (véspera do Marco 1) |
| Pasta local | `~/Desktop/stopreadingmyfiles/vscode/DataBase/bd2-matricula` |
| Grupo | previsto de 3; hoje **Gabriel sozinho** (frentes 2 e 3 do `AUTORES.md` em aberto) |
| Marco 1 | **14/09/2026** — DDL + carga + 10 consultas (2,0 pts na A1) |
| Marco 2 | **06/11/2026** — views, índices, transações, segurança, backup (4,0 pts na A2) |
| Apresentação | **09/11 ou 16/11** (escala sai 26/10) — 18 min, banco ao vivo, **arguição cruzada** individual e sem IA |
| Nota | MF = 0,4·A1 + 0,6·A2. Commit único / trabalho concentrado numa pessoa é **penalizado** |

Acessos do banco: `localhost:5432`, base `matricula`, usuário/senha `bd2`/`bd2` (superusuário — só para rodar scripts).
pgAdmin: `http://localhost:8080` (`admin@iesb.br` / `admin`; host interno `postgres`).

Conexões já configuradas no DBeaver: `matricula_sadmin` (bd2), `matricula_coord` (`coordenacao`/`coordenacao123`, só leitura), `matricula_aluno` (`al_20250094` ou `al_20240030` / `aluno123` — mostra o RLS).

---

## 2. Como reconstruir tudo do zero

```bash
cd ambiente && docker compose up -d && cd ..     # sobe PostgreSQL 17 + pgAdmin
./scripts/run_all.sh                             # 01 → 08 + 90 (DDL, carga, consultas, views, volume, índices, transações, segurança, testes)
```

Tudo é idempotente e determinístico: reexecutar dá exatamente o mesmo banco. Se alguém apagar
uma tabela por engano (já aconteceu com `matricula`), é só rodar de novo.

---

## 3. O que está pronto

### Marco 1 — completo e validado
| Arquivo | Conteúdo |
|---|---|
| `sql/01_ddl.sql` | **41 tabelas** (modelo ampliado, no ar desde 27/08/2026), 16 ENUMs, 3 domínios, `timerange`, todas as restrições. Correções marcadas `[C#]` e decisões da ampliação `[E#]`. Traz também `v_desempenho_matricula` — a view que sucede a coluna GERADA que [E14] removeu de `historico` |
| `sql/02_carga.sql` | 120 alunos, 34 turmas, 796 matrículas (mínimos: 100/6/300) + 132 pessoas, 1.189 aulas, 17.214 presenças, 995 notas, 22 planos de ensino. 100 % determinística, com cenários plantados: TABD-N1 com 1 vaga livre, COMP1-N1 vazia, LBD2-N1 EAD sem sala, e uma coorte de baixa frequência que produz `reprovado_frequencia` |
| `sql/03_consultas.sql` | 10 consultas comentadas: junção externa+agregação (3), recursiva árvore de pré-req (5), recursiva "pode cursar" (6), ranking+percentil (7), LAG (8), ranges (9), painel (10) |
| `sql/90_testes_restricoes.sql` | **21 testes**: 19 tentam gravar dado inválido ([C2]–[C13] e [E2]–[E14]) e confirmam a rejeição; 2 provam o que o modelo deve ACEITAR (dois horários EAD no mesmo dia/faixa; mesmo código de sala em prédios diferentes) |
| `docs/correcoes-modelo-logico.md` | análise crítica **reescrita em 17/08/2026**: medida contra o SQL de partida do professor (não contra o diagrama), com metodologia executável, 7 erros reais e 6 restrições conferidas e corretas |

### Marco 2 — completo e validado
| Arquivo | Conteúdo |
|---|---|
| `sql/04_views.sql` | `v_oferta_periodo`, `v_vagas_disponiveis`, `v_historico_aluno` (security_invoker) + `mv_indicadores` e `mv_historico_consolidado`, ambas com política de refresh justificada |
| `sql/05_volume_legado.sql` | semestres 2020–2024: 3.000 egressos, 400 turmas, ~33 mil matrículas, ~60 mil notas. **Não** reconstitui horário/aula/presença — decisão registrada no cabeçalho do script |
| `sql/06_indices.sql` | 4 índices com EXPLAIN antes/depois: **parcial** (39×), BRIN (2,7×), B-tree em `mv_historico_consolidado.media_final` (**56 ms na derivação → 0,13 ms na MV indexada**), **GIN jsonb** (18×, = bônus JSONB) |
| `sql/07_transacoes.sql` + `scripts/demo_concorrencia.sh` | anomalia da última vaga (9/8) reproduzida em 2 sessões reais; correção A `FOR UPDATE`; correção B `SERIALIZABLE` (40001) |
| `sql/08_seguranca.sql` | roles `papel_aluno`/`secretaria`/`coordenacao`/`al_<RA>`, GRANT/REVOKE, RLS em **6 tabelas** — `aluno`, `matricula`, `historico` e, por causa da ampliação, `pessoa` [E2], `nota` e `presenca` [E14]. Normalizar moveu o dado pessoal de lugar e as três políticas antigas teriam deixado CPF e notas em aberto |
| `scripts/backup.sh` / `restore.sh` + `docs/backup-restore.md` | `pg_dump -Fc`, restauração ensaiada em base nova, roteiro de desastre |
| `docs/evidencias/` | saídas reais: `explain-indices.md`, `transacoes-demo.md`, `rls-demo.md` |

### Extras
- `docs/modelo-tabelas.drawio` — **a modelagem oficial**: p.1 com as 41 tabelas, os 60 relacionamentos e o painel de normalização; p.2 com as decisões [E1]–[E16]. Exportar PNG só da página 1.
- `docs/modelo-fisico.html` — página visual da **BASE** (16 tabelas): diagrama ER (pé-de-galinha), catálogo com PK/FK/U/GEN, as 13 correções em **antes | depois**. Documenta o ponto de partida, não o modelo em produção. Abrir com `open docs/modelo-fisico.html` (diagrama usa Mermaid via CDN).
- `docs/plano-marco2.md` — plano original (marcado como implementado; registro do processo).
- `README.md` — sobe do zero, estrutura, roteiro das demos ao vivo.

---

## 4. As correções ao modelo de partida (síntese)

> **Revisado em 17/08/2026.** A tabela abaixo é a versão original, escrita contra
> o **diagrama**. O modelo de partida do professor
> (`docs/banco_de_dados_matricula_com_erros.sql`) foi então carregado num banco
> descartável e inspecionado: **o DDL dele roda limpo e já traz C2, C3, C4, C7,
> C8, C1 e as duas colunas geradas com fórmula.** A análise vigente é
> `docs/correcoes-modelo-logico.md`, que separa erros reais de restrições
> conferidas. Os erros reais são: o trigger `fn_valida_vaga()` sem proteção sob
> concorrência (E1), o `EXCLUDE` sem período letivo — **forte demais**, não fraco
> (C10), o feriado nacional duplicável por NULL (C9), as duas FKs soltas em
> `aluno` (C6), a fórmula da média que pune quem faz P3 (C13), o índice
> redundante (E6) e a unicidade fraca de `turma` (C5).

### Versão original (contra o diagrama — mantida por histórico)

| # | Tabela | Problema no modelo | Correção |
|---|---|---|---|
| C1 | turma_horario | `timerange` **não existe** no PG — DDL nem roda | `CREATE TYPE timerange AS RANGE (subtype = time)` |
| C2 | matricula | sem `UNIQUE (aluno, turma)` — matrícula duplicada | `UNIQUE (aluno_id, turma_id)` |
| C3 | periodo_letivo | sem `UNIQUE (ano, semestre)`; sem checks | `UNIQUE` + `CHECK semestre IN (1,2)` + `CHECK inicio < fim` |
| C4 | sala | código não único por campus | `UNIQUE (campus_id, codigo)` |
| C5 | turma | código não único por período | `UNIQUE (periodo_letivo_id, codigo)` |
| C6 | aluno | `curso_id` e `curriculo_id` soltos → currículo de outro curso | **FK composta** `(curriculo_id, curso_id) → curriculo (id, curso_id)` |
| C7 | pre_requisito | disciplina pré-req de si mesma | `CHECK disciplina_id <> requisito_id` |
| C8 | curriculo | sem `UNIQUE (curso, ano)` | `UNIQUE (curso_id, ano_vigencia)` |
| C9 | feriado | duplicável; NULL sem semântica | `UNIQUE NULLS NOT DISTINCT (campus_id, data)`; NULL = nacional |
| C10 | turma_horario | choque de sala não impedido | `EXCLUDE USING gist (periodo, sala, dia, faixa &&)` + `periodo_letivo_id` denormalizado com FK composta |
| C11 | log_matricula | sem FK (modelo já não marcava) | **mantido sem FK, de propósito** (auditoria sobrevive à origem) |
| C15 | (schema) | tudo em `public`; o professor usa `academico` | **`CREATE SCHEMA academico`** + `search_path` + extensão fixada em `public` — aplicado em 17/08/2026 |
| C12 | todas | tipos citados e não definidos; sem NOT NULL/CHECK | domínios `nota_t`/`pct_t`/`cpf_t`, enums, NOT NULL padrão, checks |
| C13 | disciplina, historico | colunas "geradas" sem fórmula | `GENERATED ALWAYS AS (...) STORED` (`ch_total`, `media_final`) |

---

## 5. Decisões de projeto (e por quê)

Registro das escolhas que não estão óbvias no código. Ordem: decisões **fechadas**, depois a **revertida** nesta sessão.

### 5.1 Fechadas
| Decisão | Justificativa |
|---|---|
| `GENERATED ALWAYS AS IDENTITY` em vez de `SERIAL` | padrão SQL; impede id manual acidental; sequência pertence à coluna |
| `RESTRICT` (padrão) no núcleo, `CASCADE` só em detalhe (`historico`, `turma_horario`, `pre_requisito`, `curriculo_disciplina`, `feriado`) | dado acadêmico não some por arrasto |
| ENUM para rótulos fechados, DOMAIN para faixa/formato | critério explícito; defensável na arguição |
| `periodo_letivo_id` copiado em `turma_horario` (denormalização) | exigido pelo `EXCLUDE` de C10; **controlada** pela FK composta — nunca diverge |
| `log_matricula` sem FK | trilha de auditoria deve sobreviver ao expurgo da matrícula (testado na prática: DELETE acidental em `matricula` levou `historico` por CASCADE e deixou 32 mil logs intactos) |
| Volume legado (`05`) separado da carga curada (`02`) | mantém os cenários do Marco 1 intocados; dá massa para EXPLAIN |
| Índices escolhidos: parcial, BRIN, B-tree, GIN | cobrem padrões distintos; `matricula(aluno_id)` não foi criado porque a UNIQUE de C2 já o cobre |
| Correção A (`FOR UPDATE`) como caminho de produção; B (`SERIALIZABLE`) documentada | um ponto quente conhecido → lock previsível, sem retry na aplicação |
| Bônus escolhido: JSONB + GIN (não particionamento) | coluna já existe; particionar `historico` exigiria denormalizar o ano |
| RLS: identidade pela role `al_<RA>`, função `SECURITY DEFINER` recebendo `current_user` por parâmetro | dentro de SECURITY DEFINER `current_user` vira o dono — pegadinha encontrada e documentada |
| Repositório privado até a entrega | evita cópia por outros grupos; enunciado aceita "público **ou** com acesso ao professor" |
| Backup lógico `pg_dump -Fc` (não PITR) | adequado ao escopo; PITR registrado como próximo passo |

### 5.2 Revertida nesta sessão — nomenclatura das chaves

**Situação anterior:** o modelo do professor nomeia toda PK como `id` e as FKs como `<tabela>_id`
(`curso.campus_id → campus.id`). O DDL seguiu isso, e a recomendação inicial do assistente foi **não
renomear** (convenção válida; diverge do modelo sem ganho de integridade; risco de questionamento).

**Decisão do Gabriel (17/08/2026, reafirmada): RENOMEAR. É para fazer.** Fundamento: o objetivo do
trabalho é *corrigir* o modelo e implementá-lo do nosso jeito, aplicando boas práticas de mercado
— e não copiar o que veio. Se diverge do modelo do professor, a divergência é justificada e
documentada como qualquer outra correção. Vira, portanto, uma **correção adicional (C14)**.

**Convenção adotada:**
- PK: `id_<tabela>` (`id_campus`, `id_curso`, `id_curriculo`, `id_disciplina`, `id_professor`,
  `id_periodo_letivo`, `id_sala`, `id_turma`, `id_turma_horario`, `id_aluno`, `id_matricula`,
  `id_historico`, `id_feriado`, `id_log_matricula`).
- FK: **mesmo nome da PK referenciada** (`curso.id_campus → campus.id_campus`). Ganho prático:
  o nome é autoexplicativo em qualquer JOIN e permite `JOIN ... USING (id_campus)`.
- Quando a mesma tabela é referenciada por **papel** (auto-relacionamento ou dupla referência), o
  nome carrega o papel: `pre_requisito.id_disciplina` + `pre_requisito.id_requisito`.
- Tabelas associativas com PK composta mantêm as duas FKs como PK
  (`curriculo_disciplina (id_curriculo, id_disciplina)`).
- Nomes de constraints (`uq_`, `ck_`, `fk_`, `ex_`) e de índices continuam como estão.

**Plano de execução (checklist — a mudança atravessa TUDO):**
- [ ] `sql/01_ddl.sql` — renomear PKs/FKs; ajustar FKs compostas (`(id_curriculo, id_curso)`), EXCLUDE, CHECKs; adicionar **C14** nos comentários
- [ ] `sql/02_carga.sql` — todos os JOINs/INSERTs
- [ ] `sql/03_consultas.sql` — as 10 consultas
- [ ] `sql/04_views.sql` — views e MV (`aluno_id` → `id_aluno` etc.)
- [ ] `sql/05_volume_legado.sql`
- [ ] `sql/06_indices.sql` — colunas dos índices e consultas de EXPLAIN
- [ ] `sql/07_transacoes.sql` — corpo das funções (assinaturas `p_aluno`, `p_turma` podem ficar)
- [ ] `sql/08_seguranca.sql` — políticas RLS (`aluno_id = ...` → `id_aluno = ...`), GRANTs
- [ ] `sql/90_testes_restricoes.sql`
- [ ] `scripts/demo_concorrencia.sh` — SQL embutido no shell
- [ ] `docs/correcoes-modelo-logico.md` — adicionar **C14** com a justificativa acima
- [ ] `docs/modelo-fisico.html` — cards, tabela de relacionamentos, diagrama Mermaid, seção "o que não mudamos" (remover o item sobre `id` e mover para as correções)
- [ ] `docs/evidencias/*.md` — trechos de plano/saída que citam colunas
- [ ] `README.md` — se citar colunas
- [ ] rodar `./scripts/run_all.sh` até ficar verde (os 8 testes + asserções de carga são a rede de segurança); reexecutar `06` para regenerar evidências e `demo_concorrencia.sh` nos 3 modos
- [ ] commit(s) separados: `refactor(C14): PKs/FKs nomeadas por tabela` (+ docs)

Sugestão de método: fazer por busca-e-substituição **coluna a coluna** (não global), começando pelo
DDL e rodando `run_all.sh` a cada 2–3 arquivos — a idempotência dos scripts torna isso barato.

**Risco a assumir conscientemente:** na arguição, o professor pode perguntar por que o esquema
não segue o diagrama dele. Resposta pronta: "tratamos como a 14ª correção — nomenclatura
autoexplicativa é prática de mercado, e a mudança está justificada e testada como as outras".

---

## 6. Pendências (além do C14)

0. ~~Migrar `public` → `academico`~~ **feito em 17/08/2026** (C15). Inclui:
   extensão `btree_gist` fixada em `public` (schema estável sobrevive ao reset de
   `academico`), `ALTER DATABASE ... SET search_path`, `search_path` explícito em
   cada script, e o `SET search_path` da função `SECURITY DEFINER` migrado —
   este último era o que quebraria o RLS em silêncio. Validado: `run_all.sh`
   verde, reconstrução do zero em base virgem verde, os 3 modos de
   `demo_concorrencia.sh` verdes.
0b. ~~Reescrever a análise crítica~~ **feito em 17/08/2026**. `modelo-fisico.html`
   atualizado junto: metodologia, novos cards (E1 trigger, C10 invertido, E6
   índice redundante, C15 schema, C14), card consolidado dos 6 conferidos, e as
   âncoras remapeadas.
1. **Cadência de commits** — tudo nasceu em poucos dias; o professor penaliza concentração. Ir refinando e commitando até 14/09 e 06/11 (o C14 é uma boa oportunidade de vários commits pequenos e legítimos).
2. **Fechar o grupo de 3** e preencher `AUTORES.md` (frentes 2 e 3). Colegas precisam **commitar** — autoria é avaliada. Adicionar como colaboradores no repo.
3. **Dar acesso ao professor** antes de 14/09: `gh repo edit gblzera/bd2-matricula --visibility public --accept-visibility-change-consequences` **ou** convite de colaborador. Confirmar em aula **como** ele recebe o link.
4. **Estudar para a arguição cruzada** — material: `docs/evidencias/*.md`, `docs/correcoes-modelo-logico.md`, `docs/modelo-fisico.html`. Roteiro da demo ao vivo: seção "Demonstrações rápidas" do README.
5. **Testar o Docker na máquina do dia** da apresentação (exigência do enunciado).
6. Incorporar o **banco público de perguntas** do professor quando for divulgado.
7. Opcional/futuro: trigger contra ciclos em `pre_requisito` (limite conhecido de C7); regra de choque de horário do **aluno** na transação de matrícula (consulta 9 hoje só detecta).

---

## 7. Comandos úteis

```bash
./scripts/run_all.sh                              # reconstrói tudo
./scripts/demo_concorrencia.sh sem_protecao       # anomalia 9/8
./scripts/demo_concorrencia.sh lock               # correção A
./scripts/demo_concorrencia.sh serializable       # correção B
./scripts/backup.sh && ./scripts/restore.sh backups/<arquivo>.dump
docker exec -it bd2_aluno_postgres psql -U bd2 -d matricula          # psql como DBA
docker exec -it bd2_aluno_postgres psql -U al_20250094 -d matricula  # psql como aluno (RLS)
open docs/modelo-fisico.html                      # página visual do modelo
```
