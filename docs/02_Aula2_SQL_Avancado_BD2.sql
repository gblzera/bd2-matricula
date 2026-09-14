/*-------------------------------------------------------------------------------------------------------------------------
Disciplina: Banco de Dados II
Autor....: Prof. Rodrigo Gonçalves Pinto
Objetivo..: SQL avançado, com exemplos de junções complexas, subconsultas, CTEs, funções de janela e views.
Bimestre.: 121 Bimestre 2026
Objeto....: Aula 02sql avancado.sql

Data Criação...................: 17/08/2026
Data Alteração................. :17/08/2026 nome: rodrigo
Alteração Feita: melhoras na organização do código em relação a instruções
--------------------------------------------------------------------------------------------------------------------------
Versão 1.0
*/
-- Define o schema padrao da sessao. Sem isto, o Postgres procuraria as
-- tabelas no schema "public" (que esta vazio) e acusaria "does not exist".
SET search_path TO academico, public;


-- =====================================================================
-- PARTE A — JUNCOES COMPLEXAS
--
-- OBJETIVO DO BLOCO: revisar juncao como o mecanismo central do modelo
-- relacional. Mostrar (1) uma juncao em cadeia por varias tabelas,
-- (2) como INNER e LEFT JOIN respondem perguntas diferentes,
-- (3) a auto-juncao de uma tabela consigo mesma, e (4) juncao N:N com
-- agregacao de texto. E a base sobre a qual todo o resto se apoia.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A.1  A cadeia completa: 5 tabelas para responder "quem cursa o que".
--      Cada matricula liga um aluno a uma turma; a turma aponta para uma
--      disciplina e um periodo. Precisamos navegar por todas essas
--      tabelas para montar uma linha legivel de relatorio.
-- ---------------------------------------------------------------------
SELECT a.nome        AS aluno,        -- nome do aluno (tabela aluno)
       d.nome        AS disciplina,   -- nome da disciplina (tabela disciplina)
       t.codigo      AS turma,        -- codigo da turma (ex.: CCODM2B)
       pl.ano || '/' || pl.semestre AS periodo,  -- concatena ano e semestre num rotulo
       m.status                       -- situacao da matricula (enum)
FROM matricula m                                  -- tabela central: uma linha por vinculo aluno-turma
JOIN aluno a          ON a.id  = m.aluno_id        -- traz o aluno daquela matricula
JOIN turma t          ON t.id  = m.turma_id        -- traz a turma daquela matricula
JOIN disciplina d     ON d.id  = t.disciplina_id   -- da turma, chega-se a disciplina
JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id  -- e ao periodo letivo
WHERE m.status = 'MATRICULADO'                     -- so vinculos ativos (ignora trancados/cancelados)
ORDER BY a.nome, d.nome                            -- ordena por aluno e, dentro dele, por disciplina
LIMIT 10;                                          -- limita a saida para caber na tela em aula

-- ---------------------------------------------------------------------
-- A.2  INNER x LEFT: a pergunta muda com o tipo de juncao.
--      "Quantas matriculas por turma" — com INNER JOIN, uma turma sem
--      nenhuma matricula sumiria do relatorio. Com LEFT JOIN, ela
--      aparece com zero. Repare no count(m.id), e NAO count(*):
--      count(*) contaria a linha gerada pelo LEFT mesmo quando m e nulo.
-- ---------------------------------------------------------------------
SELECT t.codigo        AS turma,      -- codigo da turma
       d.nome          AS disciplina, -- disciplina da turma (para leitura)
       count(m.id)     AS matriculas  -- conta SO matriculas reais; ignora o NULL do LEFT
FROM turma t                          -- comeca pela turma: queremos TODAS, mesmo as vazias
JOIN disciplina d ON d.id = t.disciplina_id            -- nome da disciplina
LEFT JOIN matricula m ON m.turma_id = t.id             -- LEFT: mantem turmas sem matricula
GROUP BY t.codigo, d.nome             -- agrupa por turma (chave do relatorio)
ORDER BY matriculas DESC, t.codigo;   -- mais cheias primeiro; desempata pelo codigo

-- ---------------------------------------------------------------------
-- A.3  Auto-juncao: relacionar a tabela com ela mesma.
--      A tabela pre_requisito liga uma disciplina a outra disciplina.
--      Para mostrar "disciplina -> requisito" com os dois nomes, a
--      tabela disciplina precisa entrar DUAS vezes, com apelidos
--      diferentes (d e r), como se fossem duas tabelas.
-- ---------------------------------------------------------------------
SELECT d.codigo AS disciplina,     -- codigo da disciplina que TEM o pre-requisito
       d.nome   AS nome_disciplina,-- nome dela
       r.codigo AS requisito,      -- codigo da disciplina exigida como pre-requisito
       r.nome   AS nome_requisito  -- nome dela
FROM pre_requisito pr              -- tabela associativa disciplina<->requisito
JOIN disciplina d ON d.id = pr.disciplina_id   -- 1a aparicao: o lado "disciplina"
JOIN disciplina r ON r.id = pr.requisito_id    -- 2a aparicao: o lado "requisito"
ORDER BY d.codigo;                 -- ordena pela disciplina

-- ---------------------------------------------------------------------
-- A.4  N:N com agregacao de texto: cada turma e seus alunos numa linha.
--      Um aluno esta em varias turmas e uma turma tem varios alunos
--      (N:N, resolvido pela tabela matricula). string_agg junta os
--      nomes dos alunos de cada turma numa unica celula de texto.
-- ---------------------------------------------------------------------
SELECT t.codigo AS turma,          -- codigo da turma
       count(*) AS qtd_alunos,     -- quantos alunos matriculados nela
       string_agg(a.nome, '; ' ORDER BY a.nome) AS alunos  -- concatena os nomes, separados por "; "
FROM turma t                       -- turma...
JOIN matricula m ON m.turma_id = t.id          -- ...suas matriculas...
JOIN aluno a     ON a.id = m.aluno_id           -- ...e os alunos correspondentes
GROUP BY t.id, t.codigo            -- agrupa por turma (id garante unicidade)
ORDER BY qtd_alunos DESC, t.codigo;-- turmas maiores primeiro


-- =====================================================================
-- PARTE B — SUBCONSULTAS
--
-- OBJETIVO DO BLOCO: distinguir os tipos de subconsulta e quando cada
-- um faz sentido. Nao-correlacionada (roda uma vez) x correlacionada
-- (roda por linha); as tres formas equivalentes IN/EXISTS/JOIN; a
-- armadilha classica do NOT IN com NULL; e a subconsulta LATERAL, que
-- enxerga a linha corrente do FROM.
-- =====================================================================

-- ---------------------------------------------------------------------
-- B.1  Nao-correlacionada: a subconsulta NAO depende da linha de fora.
--      Roda UMA vez, produz um numero, e esse numero e reaproveitado em
--      toda a comparacao. Aqui: disciplinas com carga horaria acima da
--      media (a media e um unico numero, calculado uma so vez).
-- ---------------------------------------------------------------------
SELECT codigo, nome, ch_total                -- codigo, nome e carga horaria total
FROM disciplina
WHERE ch_total > (                           -- compara a carga de cada disciplina com...
        SELECT avg(ch_total)                 -- ...a carga media de todas as disciplinas
        FROM disciplina                      -- (subconsulta independente da linha externa)
      )
ORDER BY ch_total DESC;                       -- maiores cargas primeiro

-- ---------------------------------------------------------------------
-- B.2  Correlacionada: a subconsulta DEPENDE da linha externa.
--      Repare na referencia "a.id", que vem de fora. Por isso a
--      subconsulta e reexecutada uma vez POR ALUNO. Aqui, para cada
--      aluno, contamos suas matriculas e achamos a mais recente.
-- ---------------------------------------------------------------------
SELECT a.matricula, a.nome,
       (SELECT count(*)            FROM matricula m WHERE m.aluno_id = a.id) AS total_matriculas,  -- conta as matriculas DESTE aluno
       (SELECT max(m.data_matricula) FROM matricula m WHERE m.aluno_id = a.id)::date AS ultima      -- data da matricula mais recente DESTE aluno
FROM aluno a
WHERE EXISTS (                      -- filtra: so alunos que TEM ao menos uma matricula
        SELECT 1 FROM matricula m WHERE m.aluno_id = a.id
      )
ORDER BY total_matriculas DESC, a.matricula
LIMIT 10;

-- ---------------------------------------------------------------------
-- B.3  EXISTS x IN x JOIN: tres caminhos para a MESMA pergunta.
--      "Quantos alunos ja se matricularam em Banco de Dados II (CCO072)".
--      Os tres devolvem o mesmo numero; a escolha e de legibilidade e de
--      plano de execucao (assunto da aula 5, com EXPLAIN).
-- ---------------------------------------------------------------------
--   (a) via IN: a subconsulta produz uma lista de ids; o WHERE testa pertinencia
SELECT count(*) AS via_in
FROM aluno a
WHERE a.id IN (                                   -- o id do aluno esta na lista?
        SELECT m.aluno_id                         -- ids de alunos...
        FROM matricula m
        JOIN turma t      ON t.id = m.turma_id
        JOIN disciplina d ON d.id = t.disciplina_id
        WHERE d.codigo = 'CCO072'                 -- ...matriculados em CCO072
      );

--   (b) via EXISTS: para cada aluno, existe ao menos uma matricula em CCO072?
SELECT count(*) AS via_exists
FROM aluno a
WHERE EXISTS (
        SELECT 1                                  -- o "1" e irrelevante; EXISTS so olha se HA linha
        FROM matricula m
        JOIN turma t      ON t.id = m.turma_id
        JOIN disciplina d ON d.id = t.disciplina_id
        WHERE m.aluno_id = a.id                   -- correlacao com a linha externa
          AND d.codigo = 'CCO072'
      );

--   (c) via JOIN + DISTINCT: junta tudo e conta alunos distintos
SELECT count(DISTINCT a.id) AS via_join           -- DISTINCT porque o JOIN pode repetir o aluno
FROM aluno a
JOIN matricula m  ON m.aluno_id = a.id
JOIN turma t      ON t.id = m.turma_id
JOIN disciplina d ON d.id = t.disciplina_id
WHERE d.codigo = 'CCO072';

-- ---------------------------------------------------------------------
-- B.4  A armadilha do NOT IN com NULL.
--      Se a subconsulta do NOT IN devolver UM unico NULL junto, o
--      resultado inteiro vira vazio — silenciosamente. E um dos erros
--      mais dificeis de achar em producao. A forma segura e NOT EXISTS.
-- ---------------------------------------------------------------------
-- Versao que ainda funciona (a subconsulta nao tem NULL):
SELECT count(*) AS sem_matricula_not_in
FROM aluno
WHERE id NOT IN (SELECT aluno_id FROM matricula);   -- aluno_id e NOT NULL: seguro aqui

-- A MESMA ideia, mas injetando um NULL na lista: o resultado despenca a zero
SELECT count(*) AS armadilha_not_in
FROM aluno
WHERE id NOT IN (
        SELECT aluno_id FROM matricula
        UNION ALL
        SELECT NULL                                 -- este NULL "envenena" o NOT IN
      );

-- A forma segura, imune a NULL:
SELECT count(*) AS forma_segura
FROM aluno a
WHERE NOT EXISTS (                                  -- NOT EXISTS trata a ausencia corretamente
        SELECT 1 FROM matricula m WHERE m.aluno_id = a.id
      );

-- ---------------------------------------------------------------------
-- B.5  Subconsulta no FROM (tabela derivada) e LATERAL.
--      LATERAL permite que a subconsulta enxergue a linha corrente do
--      FROM — algo que uma subconsulta comum no FROM nao pode. Aqui,
--      para cada aluno, buscamos a sua matricula mais recente.
-- ---------------------------------------------------------------------
SELECT a.matricula, a.nome,
       ult.data_matricula::date AS ultima_matricula,  -- data vinda da subconsulta lateral
       ult.status                                     -- status vindo da subconsulta lateral
FROM aluno a
JOIN LATERAL (                       -- LATERAL: a subconsulta pode referenciar "a"
        SELECT m.data_matricula, m.status
        FROM matricula m
        WHERE m.aluno_id = a.id      -- <- correlacao permitida gracas ao LATERAL
        ORDER BY m.data_matricula DESC
        LIMIT 1                       -- so a mais recente
     ) ult ON true                    -- "ON true": junta sempre que a subconsulta produzir linha
ORDER BY ult.data_matricula DESC
LIMIT 10;


-- =====================================================================
-- PARTE C — CTEs (COMMON TABLE EXPRESSIONS)
--
-- OBJETIVO DO BLOCO: usar o "WITH" para nomear etapas de uma consulta,
-- tornando-a legivel; e dominar a CTE RECURSIVA, que percorre estruturas
-- em arvore. No projeto, isso e exatamente a cadeia de pre-requisitos
-- das disciplinas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- C.1  CTE simples: nomear uma etapa e reaproveita-la.
--      Calculamos matriculas por curso e, numa segunda CTE, a media
--      geral; depois comparamos cada curso com essa media. Escrito com
--      subconsultas aninhadas, ficaria bem menos legivel.
-- ---------------------------------------------------------------------
WITH matriculas_por_curso AS (       -- 1a etapa nomeada: total por curso
    SELECT c.codigo AS curso, count(*) AS qtd
    FROM matricula m
    JOIN aluno a ON a.id = m.aluno_id
    JOIN curso c ON c.id = a.curso_id
    GROUP BY c.codigo
),
media AS (                           -- 2a etapa: a media dos totais acima
    SELECT avg(qtd) AS media_geral FROM matriculas_por_curso
)
SELECT mc.curso, mc.qtd,                                  -- curso e seu total
       round(m.media_geral, 2)        AS media_geral,     -- media geral (repetida em cada linha)
       round(mc.qtd - m.media_geral, 2) AS desvio         -- quanto o curso desvia da media
FROM matriculas_por_curso mc
CROSS JOIN media m                    -- CROSS JOIN: cola a linha unica da media em cada curso
ORDER BY mc.qtd DESC;

-- ---------------------------------------------------------------------
-- C.2  CTE RECURSIVA — descer a arvore de pre-requisitos.
--      Estrutura obrigatoria: termo ANCORA  UNION ALL  termo RECURSIVO.
--      A ancora entrega o ponto de partida; o termo recursivo se alimenta
--      do resultado anterior, ate nao encontrar mais pre-requisitos.
--      Aqui: toda a cadeia de pre-requisitos de CCO072 (Banco de Dados II).
-- ---------------------------------------------------------------------
WITH RECURSIVE cadeia AS (
    -- ANCORA: a disciplina de partida, no nivel 0
    SELECT d.id, d.codigo, d.nome, 0 AS nivel,        -- nivel 0 = a propria disciplina
           d.codigo::text AS caminho                  -- caminho textual, para leitura
    FROM disciplina d
    WHERE d.codigo = 'CCO072'                          -- ponto de partida

    UNION ALL

    -- TERMO RECURSIVO: os pre-requisitos das disciplinas ja encontradas
    SELECT req.id, req.codigo, req.nome, c.nivel + 1,  -- desce um nivel a cada salto
           c.caminho || ' -> ' || req.codigo           -- acumula o caminho percorrido
    FROM cadeia c                                       -- o que ja foi encontrado ate agora
    JOIN pre_requisito pr ON pr.disciplina_id = c.id    -- pre-requisitos daquela disciplina
    JOIN disciplina req   ON req.id = pr.requisito_id   -- traz os dados da disciplina exigida
)
SELECT nivel,
       repeat('    ', nivel) || codigo AS hierarquia,   -- indenta conforme a profundidade
       nome, caminho
FROM cadeia
ORDER BY caminho;

-- ---------------------------------------------------------------------
-- C.3  CTE RECURSIVA — subir a arvore (de uma disciplina ate o topo).
--      Mesmo mecanismo, sentido inverso: partimos de uma disciplina e
--      subimos para as disciplinas que DEPENDEM dela (quem a exige).
--      Aqui: tudo que depende, direta ou indiretamente, de MDC118.
-- ---------------------------------------------------------------------
WITH RECURSIVE dependentes AS (
    SELECT d.id, d.codigo, d.nome, 0 AS nivel           -- ancora: a disciplina-base
    FROM disciplina d
    WHERE d.codigo = 'MDC118'
    UNION ALL
    SELECT dep.id, dep.codigo, dep.nome, dp.nivel + 1   -- sobe um nivel
    FROM dependentes dp
    JOIN pre_requisito pr ON pr.requisito_id = dp.id     -- quem tem ESTA como requisito...
    JOIN disciplina dep   ON dep.id = pr.disciplina_id   -- ...e a disciplina que depende
)
SELECT nivel, codigo, nome
FROM dependentes
ORDER BY nivel, codigo;

-- ---------------------------------------------------------------------
-- C.4  O perigo real: recursao infinita.
--      Se os dados tiverem um ciclo (A exige B, B exige A), a CTE nao
--      para sozinha. Duas protecoes: (1) carregar um array com o caminho
--      ja visitado e cortar quando um no se repetir; (2) limitar a
--      profundidade. Toda CTE recursiva sobre dados de origem externa
--      deveria ter ambas.
-- ---------------------------------------------------------------------
WITH RECURSIVE seguro AS (
    SELECT d.id, d.codigo, 0 AS nivel,                  -- ancora
           ARRAY[d.id] AS visitados                     -- inicia a lista de nos visitados
    FROM disciplina d
    WHERE d.codigo = 'CCO072'
    UNION ALL
    SELECT req.id, req.codigo, s.nivel + 1,
           s.visitados || req.id                        -- acrescenta o novo no ao caminho
    FROM seguro s
    JOIN pre_requisito pr ON pr.disciplina_id = s.id
    JOIN disciplina req   ON req.id = pr.requisito_id
    WHERE NOT req.id = ANY(s.visitados)                 -- PROTECAO 1: corta se o no ja foi visitado (ciclo)
      AND s.nivel < 10                                  -- PROTECAO 2: corta na profundidade 10
)
SELECT codigo, nivel, visitados
FROM seguro
ORDER BY nivel, codigo;


-- =====================================================================
-- PARTE D — FUNCOES DE JANELA (WINDOW FUNCTIONS)
--
-- OBJETIVO DO BLOCO: a diferenca essencial entre GROUP BY (que COLAPSA
-- linhas) e OVER (que PRESERVA todas as linhas, anexando o calculo a
-- cada uma). Rankings, comparacao com a linha anterior (LAG/LEAD) e
-- acumulados/medias moveis. No projeto, o ranking de alunos por media e
-- a evolucao de matriculas saem daqui.
-- =====================================================================

-- ---------------------------------------------------------------------
-- D.1  A diferenca fundamental: GROUP BY colapsa; OVER preserva.
--      A primeira consulta devolve UMA linha por curso. A segunda mantem
--      TODAS as matriculas e, em cada uma, escreve o total do curso e o
--      total geral — sem colapsar as linhas.
-- ---------------------------------------------------------------------
-- (i) com GROUP BY: uma linha por curso
SELECT c.codigo AS curso, count(*) AS matriculas
FROM matricula m
JOIN aluno a ON a.id = m.aluno_id
JOIN curso c ON c.id = a.curso_id
GROUP BY c.codigo;

-- (ii) com OVER: todas as matriculas continuam, cada uma "carrega" os totais
SELECT a.nome AS aluno, c.codigo AS curso,
       count(*) OVER (PARTITION BY c.codigo) AS matriculas_no_curso,  -- total do curso da linha
       count(*) OVER ()                      AS matriculas_no_total   -- total geral (janela sem particao)
FROM matricula m
JOIN aluno a ON a.id = m.aluno_id
JOIN curso c ON c.id = a.curso_id
ORDER BY c.codigo, a.nome
LIMIT 12;

-- ---------------------------------------------------------------------
-- D.2  Ranking: ROW_NUMBER x RANK x DENSE_RANK x NTILE.
--      Diferem no tratamento de EMPATE. Mostre a tabela lado a lado e
--      pergunte a turma qual usar para "top 3 alunos por media".
--      row_number: sempre unico (1,2,3,4...)
--      rank: empate compartilha posicao e PULA a seguinte (1,1,3...)
--      dense_rank: empate compartilha e NAO pula (1,1,2...)
-- ---------------------------------------------------------------------
WITH desempenho AS (                 -- media de cada aluno (media das medias das suas matriculas)
    SELECT a.nome, round(avg(h.media_final), 2) AS media
    FROM aluno a
    JOIN matricula m ON m.aluno_id = a.id
    JOIN historico h ON h.matricula_id = m.id
    WHERE h.media_final IS NOT NULL
    GROUP BY a.id, a.nome
)
SELECT nome, media,
       row_number() OVER (ORDER BY media DESC) AS row_number,   -- posicao sequencial unica
       rank()       OVER (ORDER BY media DESC) AS rank,         -- posicao com "buracos" nos empates
       dense_rank() OVER (ORDER BY media DESC) AS dense_rank,   -- posicao sem buracos
       ntile(4)     OVER (ORDER BY media DESC) AS quartil       -- divide a turma em 4 faixas
FROM desempenho
ORDER BY media DESC
LIMIT 12;

-- ---------------------------------------------------------------------
-- D.3  Ranking DENTRO de cada grupo: PARTITION BY.
--      "O aluno de melhor media em cada curso." A janela reinicia o
--      ranking a cada curso (PARTITION BY), e filtramos a posicao 1.
-- ---------------------------------------------------------------------
SELECT * FROM (                      -- subconsulta: nao da para filtrar window function no WHERE direto
    SELECT c.codigo AS curso, a.nome,
           round(avg(h.media_final), 2) AS media,
           rank() OVER (PARTITION BY c.codigo ORDER BY avg(h.media_final) DESC) AS posicao  -- ranking por curso
    FROM aluno a
    JOIN curso c     ON c.id = a.curso_id
    JOIN matricula m ON m.aluno_id = a.id
    JOIN historico h ON h.matricula_id = m.id
    WHERE h.media_final IS NOT NULL
    GROUP BY c.codigo, a.id, a.nome
) r
WHERE posicao = 1                    -- so o primeiro colocado de cada curso
ORDER BY curso;

-- ---------------------------------------------------------------------
-- D.4  LAG e LEAD: comparar uma linha com a anterior/seguinte.
--      Evolucao mensal de matriculas, com a variacao em relacao ao mes
--      anterior. lag() olha para tras; lead() olha para frente.
-- ---------------------------------------------------------------------
WITH por_mes AS (                    -- total de matriculas por mes
    SELECT date_trunc('month', data_matricula)::date AS mes, count(*) AS qtd
    FROM matricula
    GROUP BY 1
)
SELECT mes, qtd,
       lag(qtd)  OVER (ORDER BY mes) AS mes_anterior,          -- qtd do mes anterior
       qtd - lag(qtd) OVER (ORDER BY mes) AS variacao,         -- diferenca em relacao ao anterior
       lead(qtd) OVER (ORDER BY mes) AS mes_seguinte           -- qtd do proximo mes
FROM por_mes
ORDER BY mes;

-- ---------------------------------------------------------------------
-- D.5  Acumulados e molduras (frames).
--      Uma janela ORDENADA tem, por padrao, a moldura "do inicio ate a
--      linha atual" — ou seja, um acumulado. Explicitar a moldura com
--      ROWS BETWEEN deixa a intencao clara e permite a media movel.
-- ---------------------------------------------------------------------
WITH por_mes AS (
    SELECT date_trunc('month', data_matricula)::date AS mes, count(*) AS qtd
    FROM matricula
    GROUP BY 1
)
SELECT mes, qtd,
       sum(qtd) OVER (ORDER BY mes
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS acumulado,   -- soma do inicio ate aqui
       round(avg(qtd) OVER (ORDER BY mes
                      ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING), 2)     AS media_movel_3 -- media do vizinho anterior, atual e seguinte
FROM por_mes
ORDER BY mes;

-- ---------------------------------------------------------------------
-- D.6  Clausula WINDOW: nomear a janela quando ela se repete.
--      Quando varias funcoes usam a MESMA janela, defini-la uma vez em
--      WINDOW e reutilizar o nome evita repeticao e erros.
-- ---------------------------------------------------------------------
WITH desempenho AS (
    SELECT c.codigo AS curso, a.nome,
           round(avg(h.media_final), 2) AS media
    FROM aluno a
    JOIN curso c     ON c.id = a.curso_id
    JOIN matricula m ON m.aluno_id = a.id
    JOIN historico h ON h.matricula_id = m.id
    WHERE h.media_final IS NOT NULL
    GROUP BY c.codigo, a.id, a.nome
)
SELECT curso, nome, media,
       rank()   OVER w AS posicao,          -- usa a janela nomeada "w"
       round(avg(media) OVER w, 2) AS media_do_curso  -- mesma janela, outra funcao
FROM desempenho
WINDOW w AS (PARTITION BY curso ORDER BY media DESC)  -- define "w" uma unica vez
ORDER BY curso, posicao
LIMIT 15;


-- =====================================================================
-- PARTE E — VIEWS E MATERIALIZED VIEWS
--
-- OBJETIVO DO BLOCO: encapsular consultas. Uma VIEW e uma consulta
-- batizada que NAO guarda dados (reexecuta sempre); uma MATERIALIZED
-- VIEW guarda o resultado em disco (rapida, porem "congelada" ate um
-- REFRESH). A decisao entre as duas e de projeto: quanta defasagem o
-- negocio tolera? No fim, provamos na pratica esse congelamento.
-- =====================================================================

-- ---------------------------------------------------------------------
-- E.1  View: consulta batizada. Nao armazena dados; reexecuta a cada uso.
--      "Ocupacao de cada turma": vagas, matriculados e vagas restantes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ocupacao AS
SELECT t.id AS turma_id, t.codigo AS turma, d.nome AS disciplina,
       t.vagas,                                                       -- vagas ofertadas
       count(m.id) FILTER (WHERE m.status = 'MATRICULADO') AS ocupadas,  -- so matriculas ativas
       t.vagas - count(m.id) FILTER (WHERE m.status = 'MATRICULADO') AS restantes  -- vagas que sobram
FROM turma t
JOIN disciplina d ON d.id = t.disciplina_id
LEFT JOIN matricula m ON m.turma_id = t.id                            -- LEFT: turma sem matricula tambem aparece
GROUP BY t.id, t.codigo, d.nome, t.vagas;

-- consulta a view como se fosse uma tabela:
SELECT turma, disciplina, vagas, ocupadas, restantes
FROM vw_ocupacao
ORDER BY restantes, turma;

-- ---------------------------------------------------------------------
-- E.2  View sobre view: composicao.
--      Uma view pode se apoiar em outra. O planejador expande tudo antes
--      de executar. Aqui: apenas as turmas lotadas (sem vaga restante).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_turmas_lotadas AS
SELECT * FROM vw_ocupacao WHERE restantes <= 0;   -- reaproveita a view anterior

SELECT turma, disciplina, vagas, ocupadas
FROM vw_turmas_lotadas
ORDER BY turma;

-- ---------------------------------------------------------------------
-- E.3  View com regra de negocio: alunos reprovados por frequencia.
--      Encapsula o criterio "frequencia < 75%" num nome estavel, para
--      que relatorios nao repitam a regra (e nao divirjam quando ela mudar).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_risco_frequencia AS
SELECT a.matricula, a.nome, d.codigo AS disciplina, h.frequencia
FROM historico h
JOIN matricula m  ON m.id = h.matricula_id
JOIN aluno a      ON a.id = m.aluno_id
JOIN turma t      ON t.id = m.turma_id
JOIN disciplina d ON d.id = t.disciplina_id
WHERE h.frequencia < 75;              -- regra de reprovacao por falta

SELECT * FROM vw_risco_frequencia
ORDER BY frequencia
LIMIT 10;

-- ---------------------------------------------------------------------
-- E.4  MATERIALIZED VIEW: aqui os dados SAO gravados em disco.
--      Ganha-se velocidade de leitura; perde-se atualidade. Indicadores
--      por curso: quantos alunos, media geral e taxa de aprovacao.
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_indicadores_aula;   -- recomeca limpo se ja existir
CREATE MATERIALIZED VIEW mv_indicadores_aula AS
SELECT c.id AS curso_id, c.codigo AS curso,
       count(DISTINCT a.id)               AS alunos,          -- alunos distintos do curso
       round(avg(h.media_final), 2)       AS media_geral,     -- media das medias
       count(*) FILTER (WHERE h.situacao = 'APROVADO') AS aprovados  -- quantos aprovados
FROM curso c
JOIN aluno a      ON a.curso_id = c.id
JOIN matricula m  ON m.aluno_id = a.id
JOIN historico h  ON h.matricula_id = m.id
GROUP BY c.id, c.codigo;

-- indice UNICO: e pre-requisito para o REFRESH ... CONCURRENTLY (E.5)
CREATE UNIQUE INDEX uq_mv_indicadores_aula ON mv_indicadores_aula (curso_id);

SELECT curso, alunos, media_geral, aprovados
FROM mv_indicadores_aula
ORDER BY media_geral DESC;

-- ---------------------------------------------------------------------
-- E.5  A prova de que a materialized view fica "congelada".
--      Inserimos uma matricula nova e comparamos a contagem real (na
--      tabela) com a contagem da materialized view: elas DIVERGEM, porque
--      a mv nao sabe do INSERT ate um REFRESH.
-- ---------------------------------------------------------------------
-- cria uma matricula nova para o curso de id=1 (usa um aluno e uma turma desse curso)
INSERT INTO matricula (aluno_id, turma_id, status)
SELECT a.id, t.id, 'MATRICULADO'
FROM aluno a
JOIN curso c ON c.id = a.curso_id AND c.id = 1
JOIN turma t ON t.id = 1
WHERE NOT EXISTS (SELECT 1 FROM matricula m WHERE m.aluno_id = a.id AND m.turma_id = t.id)
LIMIT 1;

-- gera o historico dessa nova matricula (para entrar na contagem da mv)
INSERT INTO historico (matricula_id, nota_a1, nota_a2, frequencia, situacao)
SELECT m.id, 8.0, 7.0, 90, 'APROVADO'
FROM matricula m
WHERE NOT EXISTS (SELECT 1 FROM historico h WHERE h.matricula_id = m.id);

-- compara: a tabela ja "ve" o novo registro; a mv ainda nao
SELECT (SELECT count(*) FROM historico h
          JOIN matricula m ON m.id=h.matricula_id
          JOIN aluno a ON a.id=m.aluno_id
         WHERE a.curso_id = 1)                                      AS registros_na_tabela,
       (SELECT alunos FROM mv_indicadores_aula WHERE curso_id = 1)  AS alunos_na_mv;

-- atualiza a materialized view (CONCURRENTLY nao bloqueia leituras,
-- mas EXIGE o indice unico criado em E.4)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_indicadores_aula;

-- agora as duas fontes convergem
SELECT (SELECT count(DISTINCT a.id) FROM historico h
          JOIN matricula m ON m.id=h.matricula_id
          JOIN aluno a ON a.id=m.aluno_id
         WHERE a.curso_id = 1)                                      AS alunos_na_tabela,
       (SELECT alunos FROM mv_indicadores_aula WHERE curso_id = 1)  AS alunos_na_mv;
