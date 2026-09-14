# Roteiro da apresentação — seminário técnico (09/11 ou 16/11)

> **Formato (Seção 6 do enunciado):** ~18 minutos por grupo = **demonstração ao
> vivo (~9 min)** + **arguição individual (~9 min)**. Vídeo gravado ou captura de
> tela **não valem** — o banco tem que executar na hora. A demonstração deve
> contemplar, no mínimo: restrições de integridade funcionando; a anomalia de
> concorrência reproduzida e corrigida; ao menos um plano de execução com
> `EXPLAIN ANALYZE`; a política de row-level security; e uma **restauração de
> backup ao vivo**. Este roteiro cobre os cinco, com folga de ~1 min.
>
> Todos os comandos abaixo foram **executados e validados em 13/09/2026** contra
> o modelo atual (41 tabelas, schema `academico`, chaves `id_<tabela>`).

---

## 0. Preparação

### Na véspera
- [ ] Na máquina que vai pro seminário: clonar o repo, `cd ambiente && docker compose up -d`, `./scripts/run_all.sh` → tem que terminar com `OK — banco 'matricula' reconstruído e verificado com sucesso.`
- [ ] Rodar `./scripts/demo_concorrencia.sh sem_protecao` e `lock` uma vez (aquece a demo e confirma que o cenário rearma sozinho).
- [ ] Gerar um dump fresco: `./scripts/backup.sh` → anotar o nome do arquivo em `backups/`.
- [ ] Ensaiar o roteiro inteiro **cronometrado** ao menos uma vez.

### 30 minutos antes
- [ ] Docker Desktop aberto; `docker compose up -d` na pasta `ambiente/`.
- [ ] `./scripts/run_all.sh` (recria tudo limpo — TABD-N1 volta a 7/8).
- [ ] `./scripts/backup.sh` (dump do dia, para a restauração ao vivo).
- [ ] Terminal com **fonte grande** (o professor precisa ler do fundo da sala), 3 abas prontas na pasta do projeto:
  - aba 1: shell (scripts)
  - aba 2: `docker exec -it bd2_aluno_postgres psql -U bd2 -d matricula` (DBA)
  - aba 3: `docker exec -it bd2_aluno_postgres psql -U al_20250094 -d matricula` (aluno — RLS)
- [ ] `docs/modelo-tabelas.png` aberto (diagrama para apontar durante a fala).

---

## 1. Demonstração ao vivo — minuto a minuto (~9 min)

### 0:00–0:45 · Abertura (sem comando)

Fala: *"Sistema de matrícula sobre PostgreSQL 17. Partimos do modelo com erros do
professor, corrigimos o que era erro real — documentado item a item — e ampliamos
para 41 tabelas normalizadas: pessoa/endereço, aulas, presenças e notas por
avaliação. A base tem ~33 mil matrículas e 60 mil notas incluindo o legado
2020–2024. Tudo que vocês vão ver reconstrói do zero com um script só."*
Apontar o diagrama (`modelo-tabelas.png`) por 10 segundos, não mais.

### 0:45–2:15 · Restrições de integridade funcionando  ✅ exigido

Na aba 2 (psql DBA), dois ataques manuais — ambos devem **falhar**:

```sql
-- disciplina pré-requisito de si mesma [C7]
INSERT INTO pre_requisito (id_disciplina, id_requisito)
SELECT id_disciplina, id_disciplina FROM disciplina LIMIT 1;
-- ERROR: violates check constraint "ck_prereq_nao_reflexivo"

-- matrícula duplicada [C2]
INSERT INTO matricula (id_aluno, id_turma)
SELECT id_aluno, id_turma FROM matricula LIMIT 1;
-- ERROR: duplicate key "uq_matricula_aluno_turma"
```

Depois, na aba 1, a bateria completa:

```bash
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/90_testes_restricoes.sql
```

Fala: *"21 testes: 19 tentam gravar dado que o modelo original aceitaria e provam
a rejeição — cada um mapeado a uma correção; 2 provam o que o modelo deve
ACEITAR (EAD sem sala; mesmo código de sala em prédios distintos)."*

### 2:15–4:45 · Concorrência: a disputa pela última vaga  ✅ exigido

Contexto (aba 2): `SELECT turma, confirmadas || '/' || vagas_turma AS ocupacao, vagas_livres FROM v_vagas_disponiveis WHERE turma = 'TABD-N1';` → **7/8, 1 vaga**.

Aba 1 — a anomalia:

```bash
./scripts/demo_concorrencia.sh sem_protecao
```

Fala enquanto roda (leva ~5 s): *"Duas sessões reais. As duas contam 7, as duas
concluem que há vaga, as duas gravam."* → resultado: **9/8 — ANOMALIA**.
*"Nenhuma constraint pega: o limite cruza uma agregação de outra tabela."*

A correção:

```bash
./scripts/demo_concorrencia.sh lock
```

→ **8/8**; apontar o tempo da sessão B (~3 s): *"esse tempo é ela parada no
`FOR UPDATE`; ao acordar reconta e recusa."* Fechar com uma frase: *"Também
corrigimos com `SERIALIZABLE` sem mudar o código — o SSI aborta uma transação
com erro 40001 e a aplicação retenta; comparação completa está no repositório."*
(Se sobrar tempo no fim, rodar `serializable` como bônus.)

### 4:45–6:15 · Plano de execução com EXPLAIN ANALYZE  ✅ exigido

```bash
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/06_indices.sql
```

O script derruba e recria os 4 índices, mostrando **antes/depois** de cada um.
Rolar até o par do índice **parcial** e narrar: *"contagem de vagas — o caminho
mais quente: Seq Scan de ~390 buffers vira Index Only Scan; o predicado
`WHERE status='confirmada'` grava a regra de negócio no índice."* Mencionar em
uma frase cada um dos outros: BRIN (24 kB, correlação física), B-tree na média
consolidada, GIN em jsonb (bônus).

### 6:15–7:30 · Row-Level Security  ✅ exigido

Aba 2 (DBA): `SELECT count(*) FROM nota;` → dezenas de milhares.
Aba 3 (logado como **al_20250094**):

```sql
SELECT count(*) FROM v_historico_aluno;   -- 18: só as linhas DELE
SELECT count(*) FROM aluno;               -- 1: só ele mesmo
```

Fala: *"Mesmo banco, papéis diferentes. O GRANT abre a tabela; o RLS filtra as
linhas. A ampliação obrigou políticas em 6 tabelas — normalizar moveu o dado
pessoal de lugar. E a view respeita o RLS porque é `security_invoker`."*

### 7:30–8:45 · Restauração de backup ao vivo  ✅ exigido

```bash
./scripts/restore.sh backups/matricula_<carimbo-do-dia>.dump
```

(usar o dump gerado 30 min antes; o script recria `matricula_restore` e imprime a
conferência de volumes). Fala: *"`pg_dump -Fc` + `pg_restore` numa base nova —
backup que nunca foi restaurado é esperança, não backup. O roteiro de desastre
completo, incluindo `down -v`, está em `docs/backup-restore.md`."*

### 8:45–9:00 · Fecho

*"Repositório público, um script reconstrói tudo, cada correção tem um teste que
a prova. Perguntas."*

---

## 2. Se algo der errado (fallbacks)

| Sintoma | Ação |
|---|---|
| Banco em estado estranho / demo anterior sujou | `./scripts/run_all.sh` (~1 min) recria tudo; falar do design idempotente enquanto roda — vira ponto a favor |
| `demo_concorrencia.sh` não mostra anomalia | rodar de novo — ele rearma o cenário sozinho (`fn_demo_reset`) |
| Docker caiu | reabrir Docker Desktop, `docker compose up -d` na pasta `ambiente/`, `run_all.sh`. Enquanto sobe: falar sobre o diagrama e as correções (não precisa de banco) |
| Projetor/máquina falhou | plano B: máquina de um colega com o repo já clonado e testado (por isso o checklist da véspera roda em TODAS as máquinas do grupo) |
| Pergunta durante a demo que quebra o fluxo | "ótima pergunta — respondo na arguição para não estourar o tempo" |

Penalidades a lembrar: estourar tempo (−0,5) e demo que não roda ao vivo (−1,5).
Melhor cortar o bônus do `serializable` do que passar dos 9 minutos.

---

## 3. Arguição cruzada — mapa de estudo (~9 min, individual, sem IA)

**A regra:** cada integrante responde sobre a frente de **outro** colega. Todo
mundo estuda as três frentes. Pode consultar **só o próprio repositório** — então
saiba ONDE cada resposta mora:

| Se a pergunta for sobre… | A resposta mora em… |
|---|---|
| Por que essa constraint / esse tipo / essa FK composta | `docs/correcoes-modelo-logico.md` + comentários `[C#]`/`[E#]` no `sql/01_ddl.sql` |
| Decisões da ampliação (41 tabelas, normalização, schema `academico`) | `docs/estado-do-projeto.md` §5 + `docs/modelo-tabelas.drawio` p.2 |
| Por que esse índice / por que parcial / por que BRIN/GIN | `docs/evidencias/explain-indices.md` (números reais medidos) |
| Anomalia, FOR UPDATE vs SERIALIZABLE, quando usar cada um | `docs/evidencias/transacoes-demo.md` (tabela de comparação) |
| RLS, papéis, por que security_invoker, a pegadinha do SECURITY DEFINER | `docs/evidencias/rls-demo.md` |
| Backup, o que o dump carrega, por que roles ficam de fora | `docs/backup-restore.md` |
| Consultas (recursivas, janelas, ranges) | cabeçalhos comentados do `sql/03_consultas.sql` |

**Perguntas prováveis (treinar resposta de 30–60 s cada):**
1. Por que `EXCLUDE USING gist` e não `UNIQUE` no choque de sala? *(sobreposição ≠ igualdade; `&&` de range exige GiST + btree_gist)*
2. Por que a FK composta em `aluno`? *(duas FKs soltas deixam currículo de outro curso passar; a composta fecha o triângulo)*
3. O que acontece sem o `FOR UPDATE`? *(read-check-act race → overbooking — foi demonstrado)*
4. Por que o índice parcial e não um índice comum em `id_turma`? *(menor, e casa exatamente com o predicado da consulta quente; canceladas nem entram)*
5. Por que a view usa `security_invoker`? *(sem isso ela roda como o dono superusuário e vaza tudo — RLS não atravessaria)*
6. Um `pg_dump` da base restaura os papéis? *(não — roles são de cluster; por isso o passo de reaplicar `08_seguranca.sql` no roteiro de desastre)*
7. Por que `id_<tabela>` se o professor usa `id`? *(padronização deliberada e documentada como C14: nome autoexplicativo em joins grandes + `JOIN USING`; a convenção dele é coerente, não erro — sabemos defender as duas)*
8. Como vocês garantem que a carga é a mesma em qualquer máquina? *(determinística: aritmética modular, sem random; asserções de mínimos no fim do script)*

---

## 4. Divisão por integrante (preencher quando o grupo fechar)

| Trecho da demo | Frente | Quem apresenta |
|---|---|---|
| Abertura + restrições + EXPLAIN | 1 · Modelagem Física e Desempenho | Gabriel Henrique Kuhn Paz |
| Concorrência (anomalia + correções) | 2 · Transações e Concorrência | _(a definir)_ |
| RLS + backup/restore + fecho | 3 · Administração e Operação | _(a definir)_ |

> Enquanto o grupo não fecha, Gabriel apresenta os três blocos na ordem acima —
> o roteiro já está em ordem de frente de propósito. **Lembrete:** cada
> integrante mostra a própria frente na demo, mas é arguido sobre a de outro.
