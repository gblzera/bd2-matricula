-- ============================================================================
-- 90_testes_restricoes.sql — Prova de que o modelo REJEITA o que deve rejeitar
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Cada teste tenta gravar um dado INVÁLIDO que o modelo lógico original
-- ACEITARIA, e espera que o banco REJEITE. Padrão: bloco aninhado com
-- EXCEPTION — se o comando passar, o teste FALHA com exceção; se o banco
-- rejeitar com o erro esperado, imprime OK. Nada fica gravado: cada tentativa
-- é revertida pelo próprio bloco.
--
-- Cobertura: as correções [C2]–[C13] sobre o modelo do professor E as
-- decisões [E2]–[E14] da ampliação. O ponto da bateria é que NENHUMA delas
-- depende de trigger: são restrições declarativas — o banco é quem sabe a
-- regra, não a aplicação.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/90_testes_restricoes.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


\echo '=== Testes de restrições (todos devem imprimir OK) ==='
\echo '--- Parte 1: correções sobre o modelo do professor [C2]–[C13]'

-- [C7] pré-requisito reflexivo (disciplina exige a si mesma)
DO $$
BEGIN
  BEGIN
    INSERT INTO pre_requisito (id_disciplina, id_requisito)
    SELECT id_disciplina, id_disciplina FROM disciplina WHERE codigo_disciplina = 'BD2';
    RAISE EXCEPTION 'TESTE FALHOU: aceitou pré-requisito reflexivo (C7)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [C7] pré-requisito reflexivo rejeitado (check_violation)';
  END;
END $$;

-- [C2] matrícula duplicada (mesmo aluno, mesma turma)
DO $$
BEGIN
  BEGIN
    INSERT INTO matricula (id_aluno, id_turma)
    SELECT id_aluno, id_turma FROM matricula LIMIT 1;
    RAISE EXCEPTION 'TESTE FALHOU: aceitou matrícula duplicada (C2)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C2] matrícula duplicada rejeitada (unique_violation)';
  END;
END $$;

-- [C3] período letivo duplicado (segundo "2026/2")
DO $$
BEGIN
  BEGIN
    INSERT INTO periodo_letivo (ano_periodo_letivo, semestre_periodo_letivo, data_inicio_periodo_letivo, data_fim_periodo_letivo)
    VALUES (2026, 2, DATE '2026-08-01', DATE '2026-12-15');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou período letivo duplicado (C3)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C3] período 2026/2 duplicado rejeitado (unique_violation)';
  END;
END $$;

-- [C4→E5] mesmo código de sala no MESMO prédio
DO $$
DECLARE s sala%ROWTYPE;
BEGIN
  SELECT * INTO s FROM sala ORDER BY id_sala LIMIT 1;
  BEGIN
    INSERT INTO sala (id_predio, codigo_sala, capacidade_sala)
    VALUES (s.id_predio, s.codigo_sala, 30);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou código de sala repetido no mesmo prédio (C4/E5)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C4→E5] sala repetida no mesmo prédio rejeitada (o mesmo código em OUTRO prédio continua legal)';
  END;
END $$;

-- [C10] choque de sala: outra turma na MESMA sala, dia e faixa sobreposta,
-- no MESMO período letivo
DO $$
DECLARE
  h turma_horario%ROWTYPE;
  outra integer;
BEGIN
  SELECT * INTO h FROM turma_horario
  WHERE id_sala IS NOT NULL ORDER BY id_turma_horario LIMIT 1;   -- [E12] EAD não entra
  SELECT t.id_turma INTO outra
  FROM turma t
  WHERE t.id_periodo_letivo = h.id_periodo_letivo AND t.id_turma <> h.id_turma
    AND NOT EXISTS (SELECT 1 FROM turma_horario x       -- evita cair no ex_turma_sem_choque
                    WHERE x.id_turma = t.id_turma AND x.dia_semana_turma_horario = h.dia_semana_turma_horario
                      AND x.faixa_turma_horario && h.faixa_turma_horario)
  LIMIT 1;
  BEGIN
    INSERT INTO turma_horario (id_turma, id_periodo_letivo, id_sala, dia_semana_turma_horario, faixa_turma_horario)
    VALUES (outra, h.id_periodo_letivo, h.id_sala, h.dia_semana_turma_horario, h.faixa_turma_horario);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou duas turmas na mesma sala/horário (C10)';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK  [C10] choque de sala rejeitado (exclusion_violation via GiST)';
  END;
END $$;

-- [C6] aluno apontando currículo de OUTRO curso (a FK composta barra)
DO $$
DECLARE
  al aluno%ROWTYPE;
  curriculo_errado integer;
BEGIN
  SELECT * INTO al FROM aluno ORDER BY id_aluno LIMIT 1;
  SELECT id_curriculo INTO curriculo_errado FROM curriculo WHERE id_curso <> al.id_curso LIMIT 1;
  BEGIN
    UPDATE aluno SET id_curriculo = curriculo_errado WHERE id_aluno = al.id_aluno;
    RAISE EXCEPTION 'TESTE FALHOU: aceitou currículo de outro curso (C6)';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK  [C6] currículo de outro curso rejeitado (foreign_key_violation composta)';
  END;
END $$;

-- [C12] nota fora da escala 0–10 (domínio nota_t) — a nota mudou de tabela
-- com [E14], mas o DOMÍNIO viajou junto com ela: é essa a vantagem de domínio
-- sobre CHECK solto na coluna.
DO $$
DECLARE n nota%ROWTYPE;
BEGIN
  SELECT * INTO n FROM nota ORDER BY id_avaliacao, id_matricula LIMIT 1;
  BEGIN
    UPDATE nota SET valor_nota = 11
    WHERE id_avaliacao = n.id_avaliacao AND id_matricula = n.id_matricula;
    RAISE EXCEPTION 'TESTE FALHOU: aceitou nota 11 (C12)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [C12] nota 11 rejeitada pelo domínio nota_t (check_violation)';
  END;
END $$;

-- [C9] feriado NACIONAL duplicado — a técnica mudou com [E10] (índice único
-- PARCIAL por nível do arco, em vez de UNIQUE NULLS NOT DISTINCT), mas a
-- garantia é a mesma: não existe o mesmo feriado duas vezes no mesmo alcance.
DO $$
DECLARE f feriado%ROWTYPE;
BEGIN
  SELECT * INTO f FROM feriado WHERE id_pais IS NOT NULL ORDER BY id_feriado LIMIT 1;
  BEGIN
    INSERT INTO feriado (id_pais, descricao_feriado, data_feriado)
    VALUES (f.id_pais, 'Feriado nacional duplicado', f.data_feriado);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou feriado nacional duplicado (C9)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C9] feriado nacional duplicado rejeitado (índice único parcial)';
  END;
END $$;

-- [C13] coluna gerada não aceita escrita direta. A média saiu de historico com
-- [E14], mas a técnica continua viva em disciplina.ch_total_disciplina.
DO $$
BEGIN
  BEGIN
    UPDATE disciplina SET ch_total_disciplina = 999
    WHERE id_disciplina = (SELECT id_disciplina FROM disciplina ORDER BY id_disciplina LIMIT 1);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou escrita direta em coluna gerada (C13)';
  EXCEPTION WHEN generated_always THEN
    RAISE NOTICE 'OK  [C13] escrita direta em ch_total_disciplina rejeitada (generated_always)';
  END;
END $$;

\echo ''
\echo '--- Parte 2: decisões da ampliação [E2]–[E14]'

-- [E2] CPF é 1:1 com a pessoa: duas pessoas com o mesmo CPF não existem
DO $$
DECLARE c cpf_t;
BEGIN
  SELECT cpf_pessoa INTO c FROM pessoa ORDER BY id_pessoa LIMIT 1;
  BEGIN
    INSERT INTO pessoa (nome_pessoa, email_pessoa, cpf_pessoa, nascimento_pessoa)
    VALUES ('Clone do CPF', 'clone.cpf@teste.iesb.br', c, DATE '2000-01-01');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou CPF duplicado (E2)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [E2] CPF duplicado rejeitado (unique_violation em pessoa)';
  END;
END $$;

-- [E7] um SEGUNDO plano base para a mesma disciplina (id_turma NULL nos dois):
-- é o UNIQUE NULLS NOT DISTINCT que barra — em PG 14 isto passaria
DO $$
DECLARE d integer;
BEGIN
  SELECT id_disciplina INTO d FROM plano_ensino WHERE id_turma IS NULL LIMIT 1;
  BEGIN
    INSERT INTO plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino)
    VALUES (d, NULL, 'Segundo plano base — não deveria entrar');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou dois planos base para a mesma disciplina (E7)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [E7] segundo plano base rejeitado (UNIQUE NULLS NOT DISTINCT)';
  END;
END $$;

-- [E7] versão de plano apontando para turma de OUTRA disciplina (FK composta)
DO $$
DECLARE d integer; t integer;
BEGIN
  SELECT id_disciplina INTO d FROM disciplina WHERE codigo_disciplina = 'BD2';
  SELECT tu.id_turma INTO t FROM turma tu WHERE tu.id_disciplina <> d LIMIT 1;
  BEGIN
    INSERT INTO plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino)
    VALUES (d, t, 'Plano de BD2 numa turma que não é de BD2');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou plano em turma de outra disciplina (E7)';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK  [E7] plano em turma de outra disciplina rejeitado (FK composta)';
  END;
END $$;

-- [E8] duas coordenações do MESMO curso com vigências que se sobrepõem
DO $$
DECLARE c coordenacao_curso%ROWTYPE; outro integer;
BEGIN
  SELECT * INTO c FROM coordenacao_curso ORDER BY id_coordenacao_curso LIMIT 1;
  SELECT id_professor INTO outro FROM professor WHERE id_professor <> c.id_professor LIMIT 1;
  BEGIN
    INSERT INTO coordenacao_curso (id_curso, id_professor, vigencia_coordenacao_curso)
    VALUES (c.id_curso, outro, c.vigencia_coordenacao_curso);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou dois coordenadores simultâneos (E8)';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK  [E8] coordenação sobreposta rejeitada (EXCLUDE gist sobre daterange)';
  END;
END $$;

-- [E9] duas janelas do MESMO tipo se sobrepondo no mesmo período letivo
DO $$
DECLARE pm periodo_matricula%ROWTYPE;
BEGIN
  SELECT * INTO pm FROM periodo_matricula ORDER BY id_periodo_matricula LIMIT 1;
  BEGIN
    INSERT INTO periodo_matricula (id_periodo_letivo, descricao_periodo_matricula, janela_periodo_matricula, tipo_periodo_matricula)
    VALUES (pm.id_periodo_letivo, 'Janela sobreposta', pm.janela_periodo_matricula, pm.tipo_periodo_matricula);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou duas janelas do mesmo tipo sobrepostas (E9)';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK  [E9] janela de matrícula sobreposta rejeitada (EXCLUDE gist com ENUM + tstzrange)';
  END;
END $$;

-- [E10] feriado com DOIS níveis de alcance preenchidos (o arco exige exatamente um)
DO $$
DECLARE p smallint; e smallint;
BEGIN
  SELECT id_pais INTO p FROM pais LIMIT 1;
  SELECT id_estado INTO e FROM estado LIMIT 1;
  BEGIN
    INSERT INTO feriado (id_pais, id_estado, descricao_feriado, data_feriado)
    VALUES (p, e, 'Feriado nacional E estadual ao mesmo tempo', DATE '2026-12-31');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou feriado com dois alcances (E10)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [E10] feriado com dois alcances rejeitado (CHECK de arco exclusivo)';
  END;
END $$;

-- [E11] um SEGUNDO titular na mesma turma (índice parcial único)
DO $$
DECLARE tp turma_professor%ROWTYPE; outro integer;
BEGIN
  SELECT * INTO tp FROM turma_professor WHERE papel_turma_professor = 'titular' LIMIT 1;
  SELECT id_professor INTO outro FROM professor WHERE id_professor <> tp.id_professor LIMIT 1;
  BEGIN
    INSERT INTO turma_professor (id_turma, id_professor, papel_turma_professor)
    VALUES (tp.id_turma, outro, 'titular');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou dois titulares na mesma turma (E11)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [E11] segundo titular rejeitado (índice parcial único) — auxiliar continua permitido';
  END;
END $$;

-- [E13] a prova central da ampliação: nota de um aluno numa avaliação de
-- OUTRA turma. Sem trigger nenhum: as duas FKs compostas se fecham em id_turma.
DO $$
DECLARE m matricula%ROWTYPE; av avaliacao%ROWTYPE;
BEGIN
  SELECT * INTO m FROM matricula WHERE status_matricula = 'confirmada' ORDER BY id_matricula LIMIT 1;
  SELECT * INTO av FROM avaliacao WHERE id_turma <> m.id_turma ORDER BY id_avaliacao LIMIT 1;
  BEGIN
    INSERT INTO nota (id_avaliacao, id_matricula, id_turma, valor_nota)
    VALUES (av.id_avaliacao, m.id_matricula, m.id_turma, 8.0);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou nota em avaliação de outra turma (E13)';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK  [E13] nota em avaliação de outra turma rejeitada (FK composta, SEM trigger)';
  END;
END $$;

-- [E14] peso de avaliação fora da escala 0–10
DO $$
DECLARE t integer;
BEGIN
  SELECT id_turma INTO t FROM turma ORDER BY id_turma LIMIT 1;
  BEGIN
    INSERT INTO avaliacao (id_turma, nome_avaliacao, peso_avaliacao)
    VALUES (t, 'Peso absurdo', 42.00);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou peso 42 (E14)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [E14] peso fora da escala 0–10 rejeitado (check_violation)';
  END;
END $$;

\echo ''
\echo '--- Parte 3: o que o modelo deve ACEITAR (o oposto também precisa de prova)'

-- [E12] dois horários EAD no mesmo dia e faixa: o EXCLUDE de sala é PARCIAL,
-- então sala NULL não colide com sala NULL. Se este teste falhar, a ampliação
-- teria proibido EAD sem querer.
DO $$
DECLARE t1 integer; t2 integer; p smallint;
BEGIN
  SELECT tu.id_turma, tu.id_periodo_letivo INTO t1, p
  FROM turma tu JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo
  WHERE pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
  ORDER BY tu.id_turma LIMIT 1;
  SELECT tu.id_turma INTO t2 FROM turma tu
  WHERE tu.id_periodo_letivo = p AND tu.id_turma <> t1 ORDER BY tu.id_turma LIMIT 1;
  INSERT INTO turma_horario (id_turma, id_periodo_letivo, id_sala, dia_semana_turma_horario, faixa_turma_horario)
  VALUES (t1, p, NULL, 6, timerange(TIME '14:00', TIME '15:40')),
         (t2, p, NULL, 6, timerange(TIME '14:00', TIME '15:40'));
  RAISE NOTICE 'OK  [E12] dois horários EAD no mesmo dia/faixa ACEITOS (EXCLUDE parcial)';
  RAISE EXCEPTION 'rollback proposital';
EXCEPTION WHEN raise_exception THEN NULL;
END $$;

-- [C4→E5] o MESMO código de sala em prédios diferentes continua legal
DO $$
DECLARE s sala%ROWTYPE; outro_predio smallint;
BEGIN
  SELECT * INTO s FROM sala ORDER BY id_sala LIMIT 1;
  SELECT id_predio INTO outro_predio FROM predio WHERE id_predio <> s.id_predio LIMIT 1;
  INSERT INTO sala (id_predio, codigo_sala, capacidade_sala)
  VALUES (outro_predio, s.codigo_sala, 30);
  RAISE NOTICE 'OK  [C4→E5] mesmo código de sala em OUTRO prédio ACEITO';
  RAISE EXCEPTION 'rollback proposital';
EXCEPTION WHEN raise_exception THEN NULL;
END $$;

\echo ''
\echo '=== Fim dos testes — banco permanece íntegro (nenhuma linha gravada) ==='
SELECT count(*) AS matriculas, (SELECT count(*) FROM nota) AS notas,
       (SELECT count(*) FROM feriado) AS feriados, (SELECT count(*) FROM sala) AS salas
FROM matricula;
