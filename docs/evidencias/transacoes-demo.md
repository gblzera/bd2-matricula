# Evidências — a disputa pela última vaga (anomalia + duas correções)

> Execuções reais de `./scripts/demo_concorrencia.sh` sobre a turma **TABD-N1**
> (8 vagas, 7 confirmadas pela carga — exatamente 1 vaga livre, cenário plantado
> pelo `02_carga.sql`). Duas sessões psql concorrentes de verdade: a sessão A
> entra primeiro e segura a janela crítica por 4 s (`pg_sleep` documentado na
> função — a janela existe na vida real, só é mais estreita); a B entra 1 s
> depois, sem pausa.

## 1. A anomalia (READ COMMITTED, fluxo ingênuo)  `sem_protecao`

```
Estado inicial: 7/8 confirmadas
Sessão A: CONFIRMADA: aluno 2 ficou com a vaga 8/8 da turma 24   (4015 ms)
Sessão B: CONFIRMADA: aluno 5 ficou com a vaga 8/8 da turma 24   (3 ms)
Estado final: 9/8 — ANOMALIA! turma estourada (overbooking)
```

**O que aconteceu:** o fluxo "conta → confere → insere" é uma corrida
read-check-act. Em READ COMMITTED cada sessão enxerga o instantâneo de antes da
outra commitar: ambas contaram 7, ambas concluíram que havia vaga, ambas
inseriram. Nenhuma constraint pega isso — o limite de vagas atravessa uma
agregação sobre outra tabela (`count(matricula)` × `turma.vagas`), fora do
alcance de UNIQUE/CHECK/EXCLUDE.

## 2. Correção A — bloqueio explícito (`SELECT ... FOR UPDATE`)  `lock`

```
Estado inicial: 7/8 confirmadas
Sessão A: CONFIRMADA: aluno 11 ficou com a vaga 8/8 da turma 24  (4016 ms)
Sessão B: RECUSADA: turma 24 cheia (8/8)                         (2976 ms) ← bloqueada esperando o lock
Estado final: 8/8 — limite de vagas respeitado
```

**O que aconteceu:** a linha da turma vira um mutex natural. A sessão A pegou o
lock em t=0; a B, ao chegar em t=1 s, **ficou 2,98 s parada** no `FOR UPDATE`
(o tempo dela é a prova do bloqueio) até a A commitar em t=4 s. Ao acordar, a B
recontou **já vendo a matrícula da A** e recusou. Só muda 1 linha em relação ao
código ingênuo.

## 3. Correção B — isolamento `SERIALIZABLE`  `serializable`

```
Estado inicial: 7/8 confirmadas
Sessão A: ERROR: could not serialize access due to read/write dependencies
          DETAIL: Reason code: Canceled on identification as a pivot, during write.
          HINT:   The transaction might succeed if retried.        → ROLLBACK (40001)
Sessão B: CONFIRMADA: aluno 5 ficou com a vaga 8/8 da turma 24   (3 ms)
Estado final: 8/8 — limite de vagas respeitado
```

**O que aconteceu:** o código é **o mesmo da anomalia** — quem corrige é o nível
de isolamento. O SSI do PostgreSQL detectou a dependência leitura→escrita
cruzada (as duas leram o conjunto que as duas escreveram) e abortou a A com
SQLSTATE **40001**. A aplicação captura o erro e **retenta**; na retentativa, a
contagem já mostra 8/8 e a matrícula é recusada pelo caminho normal.

## Comparação fundamentada (exigida no enunciado)

| Critério | A — `FOR UPDATE` (pessimista) | B — `SERIALIZABLE` (otimista) |
|---|---|---|
| Mecanismo | lock de linha serializa o trecho crítico | SSI detecta conflito e aborta no commit/escrita |
| Custo sem contenção | um lock a mais por matrícula (barato) | rastreamento de dependências (predicate locks) em TODA transação |
| Custo sob contenção | sessões **enfileiram** (B esperou 2,98 s); vaga decidida por ordem de chegada; latência previsível | transações **abortam e refazem**; sob disputa alta, retrabalho (retry storm) |
| Retentativa na aplicação | **não precisa** — quem espera o lock reconta e decide | **obrigatória** — 40001 é esperado por design; sem retry, o usuário vê erro |
| Risco de deadlock | existe se múltiplos locks forem tomados fora de ordem (aqui: 1 lock, risco nulo) | não há deadlock de locks; há aborts |
| Alcance | protege só o que o programador lembrou de lockar | protege **qualquer** anomalia de serialização, inclusive as não previstas |
| Indicação | ponto quente conhecido e disputado (ex.: vaga de turma) | regras complexas/espalhadas, ou quando não se controla todo o código que acessa o banco |

**Recomendação para o domínio:** a matrícula tem UM ponto quente óbvio (a vaga da
turma). `FOR UPDATE` na linha da turma é mais simples, previsível e dispensa
lógica de retry — é a nossa escolha para a função de produção. `SERIALIZABLE`
fica documentado como alternativa correta, preferível se as regras crescerem
(pré-requisitos, choque de horário e limite de créditos checados na mesma
transação).

## Reproduzir

```bash
./scripts/demo_concorrencia.sh sem_protecao   # anomalia (9/8)
./scripts/demo_concorrencia.sh lock           # correção A (8/8, B esperou)
./scripts/demo_concorrencia.sh serializable   # correção B (8/8, um 40001)
```

O cenário se rearma sozinho (`fn_demo_reset` roda no início de cada execução).
