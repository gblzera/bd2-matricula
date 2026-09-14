#!/usr/bin/env bash
# =============================================================================
# Demonstração da disputa pela ÚLTIMA VAGA de TABD-N1 em duas sessões reais.
#
# Uso: ./scripts/demo_concorrencia.sh [sem_protecao|lock|serializable]
#   sem_protecao  reproduz a ANOMALIA (overbooking 9/8) em READ COMMITTED
#   lock          Correção A: SELECT ... FOR UPDATE serializa o trecho crítico
#   serializable  Correção B: mesmo código ingênuo, isolamento SERIALIZABLE
#
# Cronologia: a sessão A entra primeiro e segura a janela crítica por 4s;
# a sessão B entra 1s depois, sem pausa. O interlacing é determinístico.
# =============================================================================
set -uo pipefail   # sem -e de propósito: no modo serializable UMA sessão DEVE falhar (40001)
cd "$(dirname "$0")/.."

MODO=${1:-sem_protecao}
C=bd2_aluno_postgres
PSQL="docker exec -i $C psql -U bd2 -d matricula -qtA"

case "$MODO" in
  sem_protecao) SCRIPT=scripts/concorrencia/sessao_read_committed.sql; FUNCAO=fn_matricular_sem_protecao ;;
  lock)         SCRIPT=scripts/concorrencia/sessao_read_committed.sql; FUNCAO=fn_matricular_com_lock ;;
  serializable) SCRIPT=scripts/concorrencia/sessao_serializable.sql;   FUNCAO=fn_matricular_sem_protecao ;;
  *) echo "modo inválido: use sem_protecao | lock | serializable"; exit 1 ;;
esac

TURMA=$($PSQL -c "SELECT t.id_turma FROM turma t
                  JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                  WHERE t.codigo_turma = 'TABD-N1'
                    AND pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2")

# Dois alunos elegíveis (TABD no currículo, ativos, ainda não matriculados)
read -r ALUNO_A ALUNO_B <<< "$($PSQL -c "
  SELECT string_agg(id_aluno::text, ' ') FROM (
    SELECT a.id_aluno
    FROM aluno a
    JOIN curriculo_disciplina cd ON cd.id_curriculo = a.id_curriculo
    JOIN turma t ON t.id_disciplina = cd.id_disciplina
    WHERE t.id_turma = $TURMA AND a.status_aluno = 'ativo'
      AND NOT EXISTS (SELECT 1 FROM matricula m
                      WHERE m.id_aluno = a.id_aluno AND m.id_turma = t.id_turma)
    ORDER BY a.id_aluno LIMIT 2) s")"

echo "=============================================================="
echo " Demo [$MODO] — TABD-N1 (turma id=$TURMA) · alunos $ALUNO_A e $ALUNO_B"
echo "=============================================================="
$PSQL -c "SELECT fn_demo_reset($TURMA)"
$PSQL -c "SELECT 'Estado inicial: ' || confirmadas || '/' || vagas_turma || ' confirmadas'
          FROM v_vagas_disponiveis WHERE id_turma = $TURMA"
echo ""

OUT_A=$(mktemp); OUT_B=$(mktemp)

docker exec -i $C psql -U bd2 -d matricula \
  -v funcao=$FUNCAO -v aluno="$ALUNO_A" -v turma="$TURMA" -v pausa=4 \
  < "$SCRIPT" > "$OUT_A" 2>&1 &
PID_A=$!
sleep 1
docker exec -i $C psql -U bd2 -d matricula \
  -v funcao=$FUNCAO -v aluno="$ALUNO_B" -v turma="$TURMA" -v pausa=0 \
  < "$SCRIPT" > "$OUT_B" 2>&1
wait $PID_A

echo "--- Sessão A (aluno $ALUNO_A, pausa de 4s na janela crítica):"
cat "$OUT_A"
echo ""
echo "--- Sessão B (aluno $ALUNO_B, sem pausa, entrou 1s depois):"
cat "$OUT_B"
echo ""
$PSQL -c "SELECT 'Estado final: ' || confirmadas || '/' || vagas_turma || ' — ' ||
          CASE WHEN confirmadas > vagas_turma
               THEN 'ANOMALIA! turma estourada (overbooking)'
               ELSE 'limite de vagas respeitado' END
          FROM v_vagas_disponiveis WHERE id_turma = $TURMA"
rm -f "$OUT_A" "$OUT_B"
