# Evidências — papéis e Row-Level Security

> Execução real de [sql/08_seguranca.sql](../../sql/08_seguranca.sql). A exigência do
> enunciado — **um aluno não pode ver o histórico de outro** — demonstrada com
> `SET ROLE` entre os papéis.

```
=== DEMO RLS — visão do banco como cada papel ===
-- Como DBA (bd2): total de linhas de histórico visíveis:
 historico_total = 31168

-- Como al_20250094 (aluno): linhas de histórico visíveis (só as dele):
 historico_visivel = 18

-- Como al_20250094: o histórico detalhado via view (RLS atravessa a view):
 2025/1  ALG1  7.82  aprovado
 2025/1  MAT1  6.60  aprovado
 2025/2  BD1   7.12  aprovado
 2025/2  ED1   6.72  reprovado_frequencia
 2025/2  EMP   6.20  aprovado

-- Como al_20250094: tentando enxergar OUTROS alunos na tabela aluno:
 alunos_visiveis = 1        <- só ele mesmo

-- Como coordenacao: leitura ampla (todos os históricos):
 historico_visivel = 31168
```

## Pontos de defesa

1. **GRANT abre a tabela; RLS filtra as linhas.** `papel_aluno` tem `SELECT` em
   `historico`, mas `ENABLE ROW LEVEL SECURITY` instala o "nega tudo" e só a
   política `pol_historico_so_do_aluno` abre as linhas cuja matrícula pertence ao
   próprio aluno.
2. **RLS atravessa a view** porque `v_historico_aluno` foi criada com
   `security_invoker = on` (04_views.sql). Sem isso, a view executaria como o dono
   (superusuário bd2) e vazaria tudo — pegadinha clássica de RLS + views.
3. **Identidade sem recursão.** A role do aluno chama-se `al_<RA>`; a função
   `aluno_id_de(current_user)` é `SECURITY DEFINER` (lê `aluno` sem RLS, evitando
   recursão de política). O `current_user` é avaliado **na política** (contexto do
   usuário) e passado por parâmetro — dentro de uma função SECURITY DEFINER,
   `current_user` viraria o dono (bd2) e negaria tudo; encontramos e documentamos
   essa pegadinha durante o desenvolvimento.
4. **Superusuário ignora RLS por design** (papel de DBA). Numa instalação real, a
   aplicação jamais conectaria como bd2.

## Papéis e credenciais (didáticas, só para o ambiente de aula)

| Papel | Login | Acesso |
|---|---|---|
| `secretaria` | senha `secretaria123` | CRUD operacional (aluno, matrícula, histórico, log) |
| `coordenacao` | senha `coordenacao123` | leitura ampla + `mv_indicadores` |
| `al_<RA>` (2 exemplos) | senha `aluno123` | catálogo + apenas os próprios dados |

Reproduzir: `docker exec -it bd2_aluno_postgres psql -U al_20250094 -d matricula`
(ou o segundo RA criado — o script escolhe os 2 alunos com mais matrículas).
