# Plano de ataque — Marco 2 (entrega 06/11/2026)

> **STATUS: IMPLEMENTADO.** Este documento foi o plano; a implementação vive em
> `sql/04..08`, `scripts/` e `docs/evidencias/`. Diferenças em relação ao plano
> original: (a) entrou o `05_volume_legado.sql` — sem volume, EXPLAIN não mostra
> ganho mensurável; (b) os índices escolhidos mudaram para parcial + BRIN +
> B-tree + GIN (o `matricula(aluno_id)` planejado já era coberto pela UNIQUE da
> correção C2 — análise em `docs/evidencias/explain-indices.md`); (c) o bônus
> confirmado foi JSONB+GIN. Mantido como registro do processo.

## 1. Views — `sql/04_views.sql`

| View | Conteúdo | Por quê |
|---|---|---|
| `v_oferta_periodo` | oferta do período corrente: turma, disciplina, professor, horários, sala | consulta 2/3 viram view de catálogo |
| `v_vagas_disponiveis` | vagas − confirmadas por turma (base da transação da última vaga) | usada pela matrícula e pela demo de concorrência |
| `v_historico_aluno` | histórico completo por aluno (notas, situação, período) | alvo natural do RLS |
| `mv_indicadores` (materialized) | taxa de aprovação/ocupação por disciplina/período | **política de atualização justificada**: dados históricos mudam só no fechamento do período ⇒ `REFRESH ... CONCURRENTLY` agendado/manual pós-fechamento, com índice único para o CONCURRENTLY |

## 2. Índices — `sql/05_indices.sql` + `docs/evidencias/`

O PostgreSQL **não** indexa FKs automaticamente — e nossas consultas fazem join
pesado por elas. Candidatos (validar com EXPLAIN na base carregada):

1. `matricula (turma_id)` — joins de ocupação/vagas (consultas 3, C4).
2. `historico (matricula_id)` — já tem UNIQUE; avaliar covering p/ `media_final`.
3. `turma (disciplina_id, periodo_letivo_id)` — oferta por disciplina.
4. **Parcial** (exigido): `matricula (turma_id) WHERE status = 'confirmada'` —
   é exatamente a contagem que a disputa de vaga faz; alternativa: unique parcial
   `(aluno_id, turma_id) WHERE status <> 'cancelada'` (evolução da C2).
5. Bônus GIN: `log_matricula USING gin (detalhe)` — casa com o bônus JSONB.

Método (exigência da frente 1): `EXPLAIN (ANALYZE, BUFFERS)` **antes**, criar
índice, **depois** — ganho medido e registrado em `docs/evidencias/`.

## 3. Transações e concorrência — `sql/06_transacoes.sql`

A anomalia: **duas sessões disputam a última vaga de TABD-N1** (a carga já
deixa exatamente 1 vaga livre).

1. **Reprodução da anomalia** (READ COMMITTED): duas sessões fazem
   `SELECT count(confirmadas) < vagas` → ambas veem 1 vaga → ambas inserem →
   turma com 9/8. Roteiro em dois terminais psql lado a lado.
2. **Correção A — bloqueio explícito**: `SELECT ... FROM turma WHERE id = $1
   FOR UPDATE` serializa a checagem+inserção (lock na linha da turma).
3. **Correção B — nível de isolamento**: `SERIALIZABLE`; a segunda transação
   falha com `serialization_failure` (40001) e a aplicação faz retry.
4. **Comparação fundamentada** (exigida): custo (lock pessimista bloqueia e
   enfileira × otimista aborta e refaz), contenção sob carga, necessidade de
   retentativa na aplicação, e onde cada uma é preferível.

## 4. Segurança — `sql/07_seguranca.sql`

- Papéis: `aluno`, `secretaria`, `coordenacao` com GRANT/REVOKE mínimos.
- **RLS**: `historico`/`matricula` com política
  `aluno_id = current_setting('app.aluno_id')::int` (ou mapeando `current_user`
  a alunos criados como roles) — **um aluno não vê o histórico de outro**
  (demonstração exigida na apresentação).
- Cuidado herdado do Marco 1: o `01_ddl.sql` recria o schema `public`, então os
  GRANTs entram DEPOIS do DDL na ordem dos scripts.

## 5. Backup e recuperação — `sql/08_backup_restore.md` + scripts

- `pg_dump -Fc` (formato custom) dentro do contêiner + `pg_restore` numa base
  nova → documentado passo a passo, reproduzível do zero, com restauração AO
  VIVO na apresentação (exigido).
- Simular desastre: `docker compose down -v` + restore.

## 6. Bônus (até 0,5)

Opções aceitas: particionamento do histórico por ano OU JSONB + GIN.
**Escolha atual: JSONB + GIN** em `log_matricula.detalhe` — a coluna já existe
e casa com o índice 5. Particionar `historico` exigiria carregar o ano
(derivável só via matricula→turma→período), o que forçaria denormalização —
justificativa a registrar se mudarmos de ideia.

## Pendências operacionais

- [ ] Fechar grupo de 3 e atualizar `AUTORES.md` (frentes 2 e 3).
- [ ] Publicar no GitHub (público ou com acesso ao professor) — o histórico de
      commits é avaliado; commits pequenos e frequentes, nada de entrega única.
- [ ] Testar o ambiente Docker completo antes da apresentação (exigência do enunciado).
- [ ] Banco público de perguntas: revisar as frentes dos colegas (arguição é cruzada).
