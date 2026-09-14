# -*- coding: utf-8 -*-
"""college/ — o MESMO modelo, com identificadores em inglês.

O banco `matricula` (português) é a FONTE DA VERDADE; `college` é DERIVADO.
Este script lê sql/01_ddl.sql e sql/02_carga.sql, aplica o mapa de tradução
abaixo e escreve college/01_schema.sql e college/02_seed.sql.

Regras da tradução:
  · estrutura idêntica — nenhuma tabela, coluna ou restrição é criada ou removida;
  · nomes de tabela no SINGULAR, em inglês;
  · chave primária e estrangeira no padrão <tabela>_id (person_id, section_id);
  · demais colunas SEM o sufixo do nome da tabela — `person.name`, não
    `person.person_name`: é o padrão de mercado em inglês, e o sufixo do modelo
    português existe por convenção do professor [C14], que não se aplica aqui.

Uso:  python3 scripts/gerar_college.py
"""
import io, re, sys, os

# ============================================================ TABELAS (41)
TABELA = {
 'pais':'country', 'estado':'state', 'cidade':'city', 'endereco':'address',
 'pessoa':'person', 'telefone':'phone', 'documento_pessoa':'person_document',
 'usuario':'app_user',            # `user` é palavra reservada no SQL padrão
 'campus':'campus', 'departamento':'department', 'predio':'building',
 'sala':'room', 'recurso':'resource', 'sala_recurso':'room_resource',
 'professor':'professor', 'formacao_professor':'professor_degree',
 'curso':'program',               # curso = o diploma; ver nota de vocabulário
 'coordenacao_curso':'program_coordination', 'curriculo':'curriculum',
 'disciplina':'course',           # disciplina = a matéria cursada
 'curriculo_disciplina':'curriculum_course', 'pre_requisito':'prerequisite',
 'aluno':'student', 'aproveitamento_materia':'credit_transfer',
 'periodo_letivo':'academic_term', 'periodo_matricula':'enrollment_window',
 'feriado':'holiday', 'turma':'section', 'turma_professor':'section_professor',
 'turma_horario':'section_schedule', 'plano_ensino':'syllabus',
 'unidade_plano_ensino':'syllabus_unit', 'bibliografia':'bibliography',
 'plano_ensino_bibliografia':'syllabus_bibliography',
 'matricula':'enrollment', 'historico':'academic_record',
 'log_matricula':'enrollment_log', 'aula':'class_meeting',
 'presenca':'attendance', 'avaliacao':'assessment', 'nota':'grade',
}

# ============================================================ COLUNAS
COLUNA = {
 'id_pais':'country_id','nome_pais':'name','sigla_pais':'iso_code',
 'id_estado':'state_id','nome_estado':'name','uf_estado':'abbreviation',
 'id_cidade':'city_id','nome_cidade':'name','codigo_ibge_cidade':'ibge_code',
 'id_endereco':'address_id','logradouro_endereco':'street','numero_endereco':'number',
 'complemento_endereco':'complement','bairro_endereco':'district','cep_endereco':'postal_code',
 'id_pessoa':'person_id','nome_pessoa':'name','email_pessoa':'email',
 'cpf_pessoa':'cpf','nascimento_pessoa':'birth_date',
 'id_telefone':'phone_id','numero_telefone':'number','principal_telefone':'is_primary',
 'tipo_telefone':'phone_type',
 'id_documento_pessoa':'person_document_id','numero_documento_pessoa':'number',
 'orgao_documento_pessoa':'issuer','emissao_documento_pessoa':'issued_on',
 'tipo_documento_pessoa':'document_type',
 'id_usuario':'app_user_id','login_usuario':'login','ativo_usuario':'is_active',
 'papel_usuario':'role','id_usuario_avaliador':'reviewer_id',
 'id_campus':'campus_id','nome_campus':'name',
 'id_departamento':'department_id','nome_departamento':'name',
 'sigla_departamento':'abbreviation','id_professor_chefe':'head_professor_id',
 'id_predio':'building_id','nome_predio':'name','andares_predio':'floor_count',
 'id_sala':'room_id','codigo_sala':'code','andar_sala':'floor',
 'capacidade_sala':'capacity','tipo_sala':'room_type',
 'id_recurso':'resource_id','nome_recurso':'name','quantidade_sala_recurso':'quantity',
 'id_professor':'professor_id','matricula_professor':'employee_number',
 'regime_professor':'work_regime','titulacao_professor':'degree_level',
 'id_formacao_professor':'professor_degree_id','curso_formacao_professor':'program_name',
 'instituicao_formacao_professor':'institution',
 'ano_conclusao_formacao_professor':'completion_year',
 'titulacao_formacao_professor':'degree_level',
 'id_curso':'program_id','codigo_curso':'code','nome_curso':'name',
 'ch_total_curso':'total_hours','grau_curso':'degree_type','modalidade_curso':'delivery_mode',
 'id_coordenacao_curso':'program_coordination_id',
 'portaria_coordenacao_curso':'appointment_ref','vigencia_coordenacao_curso':'validity',
 'id_curriculo':'curriculum_id','portaria_curriculo':'approval_ref',
 'ano_vigencia_curriculo':'effective_year','ativo_curriculo':'is_active',
 'id_disciplina':'course_id','codigo_disciplina':'code','nome_disciplina':'name',
 'ementa_disciplina':'description','ch_teorica_disciplina':'theory_hours',
 'ch_pratica_disciplina':'lab_hours','ch_total_disciplina':'total_hours',
 'periodo_curriculo_disciplina':'term_number','tipo_curriculo_disciplina':'requirement_type',
 'id_requisito':'required_course_id','ch_minima_pre_requisito':'min_hours',
 'media_minima_pre_requisito':'min_grade','vinculo_pre_requisito':'link_type',
 'id_aluno':'student_id','matricula_aluno':'enrollment_number',
 'ingresso_aluno':'admission_date','forma_ingresso_aluno':'admission_type',
 'status_aluno':'status',
 'id_aproveitamento_materia':'credit_transfer_id',
 'disciplina_origem_aproveitamento_materia':'source_course',
 'instituicao_origem_aproveitamento_materia':'source_institution',
 'parecer_aproveitamento_materia':'review_note',
 'ch_origem_aproveitamento_materia':'source_hours',
 'nota_origem_aproveitamento_materia':'source_grade',
 'solicitacao_aproveitamento_materia':'requested_on',
 'decisao_aproveitamento_materia':'decided_on',
 'status_aproveitamento_materia':'status',
 'id_periodo_letivo':'academic_term_id','ano_periodo_letivo':'year',
 'semestre_periodo_letivo':'semester','data_inicio_periodo_letivo':'start_date',
 'data_fim_periodo_letivo':'end_date',
 'id_periodo_matricula':'enrollment_window_id','descricao_periodo_matricula':'description',
 'janela_periodo_matricula':'window_range',   # `window` é palavra RESERVADA no SQL
 'tipo_periodo_matricula':'window_type',
 'id_feriado':'holiday_id','descricao_feriado':'description',
 'data_feriado':'holiday_date','facultativo_feriado':'is_optional',
 'id_turma':'section_id','codigo_turma':'code','vagas_turma':'seats',
 'turno_turma':'shift','modalidade_turma':'delivery_mode',
 'ch_turma_professor':'hours','papel_turma_professor':'teaching_role',
 'id_turma_horario':'section_schedule_id','dia_semana_turma_horario':'weekday',
 'faixa_turma_horario':'time_range','tipo_aula_turma_horario':'meeting_type',
 'id_plano_ensino':'syllabus_id','objetivo_plano_ensino':'objective',
 'metodologia_plano_ensino':'methodology',
 'criterio_avaliacao_plano_ensino':'grading_criteria','aprovacao_plano_ensino':'approved_on',
 'id_unidade_plano_ensino':'syllabus_unit_id','titulo_unidade_plano_ensino':'title',
 'conteudo_unidade_plano_ensino':'content','ordem_unidade_plano_ensino':'position',
 'ch_unidade_plano_ensino':'hours',
 'id_bibliografia':'bibliography_id','titulo_bibliografia':'title',
 'autor_bibliografia':'author','editora_bibliografia':'publisher',
 'isbn_bibliografia':'isbn','ano_bibliografia':'year','edicao_bibliografia':'edition',
 'tipo_plano_ensino_bibliografia':'reference_type',
 'id_matricula':'enrollment_id','data_matricula':'enrolled_at','status_matricula':'status',
 'id_historico':'academic_record_id','data_fechamento_historico':'closed_on',
 'situacao_historico':'outcome',
 'id_log_matricula':'enrollment_log_id','ocorrido_em_log_matricula':'occurred_at',
 'acao_log_matricula':'action','detalhe_log_matricula':'detail',
 'id_aula':'class_meeting_id','conteudo_aula':'topic','data_aula':'meeting_date',
 'realizada_aula':'was_held',
 'presente_presenca':'was_present','justificada_presenca':'is_excused',
 'id_avaliacao':'assessment_id','nome_avaliacao':'name','peso_avaliacao':'weight',
 'data_avaliacao':'assessment_date','substitutiva_avaliacao':'is_makeup',
 'valor_nota':'value',
 # colunas de saída da view de derivação
 'media_final':'final_grade','frequencia':'attendance_rate',
 'aulas_previstas':'meetings_expected','presencas':'meetings_attended',
 'avaliacoes_lancadas':'assessments_recorded','usou_substitutiva':'used_makeup',
}

# ============================================================ TIPOS
TIPO = {
 'nota_t':'grade_value','pct_t':'percentage','cpf_t':'cpf',
 'turno_t':'shift','tipo_sala_t':'room_type','vinculo_t':'prerequisite_link',
 'tipo_disc_t':'requirement_type','status_mat_t':'enrollment_status',
 'situacao_t':'academic_outcome','tipo_telefone_t':'phone_type',
 'tipo_documento_t':'document_type','papel_usuario_t':'user_role',
 'regime_professor_t':'work_regime','titulacao_t':'degree_level',
 'forma_ingresso_t':'admission_type','status_aluno_t':'student_status',
 'grau_curso_t':'degree_type','modalidade_t':'delivery_mode',
 'papel_docente_t':'teaching_role','tipo_periodo_matricula_t':'enrollment_window_type',
 'tipo_aula_t':'meeting_type','tipo_bibliografia_t':'reference_type',
 'status_aproveitamento_t':'credit_transfer_status','acao_log_t':'log_action',
}

# ============================================================ RÓTULOS DE ENUM
# Onde o mesmo rótulo existe em dois ENUMs (trancado, pendente, teorica), a
# tradução é a MESMA nos dois — substituição textual não distingue contexto,
# e escolher uma palavra só é mais honesto que inventar duas.
ROTULO = {
 'matutino':'morning','noturno':'evening',
 'teorica':'lecture','laboratorio':'lab','auditorio':'auditorium','pratica':'lab_session',
 'pre_requisito':'prerequisite','co_requisito':'corequisite',
 'obrigatoria':'required','optativa':'elective','eletiva':'free_elective',
 'pendente':'pending','confirmada':'confirmed','trancada':'suspended','cancelada':'cancelled',
 'cursando':'in_progress','aprovado':'passed','reprovado_nota':'failed_grade',
 'reprovado_frequencia':'failed_attendance','trancado':'suspended',
 'celular':'mobile','residencial':'home','comercial':'work',
 'rg':'id_card','passaporte':'passport','cnh':'drivers_license','rne':'foreign_id',
 'secretaria':'registrar','coordenacao':'coordinator',
 'horista':'hourly','parcial':'part_time','integral':'full_time',
 'graduacao':'bachelor','especializacao':'specialization','mestrado':'master',
 'doutorado':'doctorate','pos_doutorado':'postdoc',
 'vestibular':'entrance_exam','enem':'national_exam','transferencia':'transfer',
 'portador_diploma':'second_degree',
 'ativo':'active','formado':'graduated','evadido':'dropped_out','jubilado':'dismissed',
 'bacharelado':'bachelor','licenciatura':'teaching_degree','tecnologo':'associate',
 'presencial':'on_campus','ead':'online','hibrido':'hybrid',
 'titular':'lead','auxiliar':'assistant','substituto':'substitute',
 'ajuste':'adjustment','trancamento':'withdrawal','rematricula':'re_enrollment',
 'basica':'core','complementar':'supplementary',
 'deferido':'approved','indeferido':'denied',
}


# ============================================================ APELIDOS LOCAIS
# Colunas de CTE e de listas VALUES. Não existem no banco — existem só dentro
# de uma consulta — mas deixá-las em português faria do arquivo um híbrido.
APELIDO = {
 'nome':'name','codigo':'code','data':'date','ano':'year','tipo':'kind',
 'vagas':'seats','turno':'shift','ativo':'is_active','peso':'weight',
 'media':'avg_grade','grau':'degree','sigla':'abbrev','descricao':'description',
 'portaria':'ref','andares':'floors','andar':'floor','cap':'capacity',
 'compl':'complement','bairro':'district','cep':'postal','num':'number',
 'uf':'abbrev','teo':'theory','pra':'lab','disc':'course_code','req':'requires',
 'vinculo':'link','periodo':'term','sem':'semester','vig':'validity',
 'papel':'role','mat':'employee_no','regime':'regime','titulacao':'degree_level',
 'facultativo':'is_optional','ini':'starts','fim':'ends','subst':'is_makeup',
 'freq':'attendance','encerrado':'is_closed','ord':'position','log':'street',
 'modalidade':'delivery_mode','status':'status','dia':'day','email':'email',
 'prof':'professor_code','campus':'campus','ch':'hours',
}

# ============================================================ OUTROS OBJETOS
OUTRO = {
 'academico':'academic',
 'f_usuario_sessao':'f_session_user','aluno_id_de':'student_id_of',
 'pessoa_id_de':'person_id_of','v_desempenho_matricula':'v_enrollment_performance',
 'mv_indicadores':'mv_course_indicators','mv_historico_consolidado':'mv_academic_record',
 'ux_mv_indicadores':'ux_mv_course_indicators','ux_mv_historico_consolidado':'ux_mv_academic_record',
 'v_oferta_periodo':'v_term_offering','v_vagas_disponiveis':'v_available_seats','v_historico_aluno':'v_student_record',
}

# tokens usados dentro de nomes de restrição/índice (uq_, fk_, ck_, ex_, idx_, ux_)
TOKEN = {
 'pais':'country','estado':'state','cidade':'city','endereco':'address',
 'pessoa':'person','telefone':'phone','documento':'document','usuario':'user',
 'departamento':'department','predio':'building','sala':'room','recurso':'resource',
 'formacao':'degree','curso':'program','coordenacao':'coordination',
 'curriculo':'curriculum','disciplina':'course','requisito':'requisite',
 'prereq':'prereq','aluno':'student','aproveitamento':'transfer','materia':'course',
 'periodo':'term','letivo':'academic','matricula':'enrollment','feriado':'holiday',
 'turma':'section','horario':'schedule','plano':'syllabus','ensino':'syllabus',
 'unidade':'unit','bibliografia':'bibliography','historico':'record',
 'aula':'meeting','presenca':'attendance','avaliacao':'assessment','nota':'grade',
 'prof':'prof','chefe':'head','titular':'lead','principal':'primary',
 'data':'date','datas':'dates','ano':'year','semestre':'semester','codigo':'code',
 'nome':'name','turno':'shift','vigencia':'validity','janela':'window','arco':'arc',
 'positiva':'positive','reflexivo':'reflexive','nao':'not','sem':'no',
 'choque':'conflict','ordem':'position','tipo':'type','vagas':'seats',
 'consolidado':'consolidated','indicadores':'indicators','detalhe':'detail',
 'confirmada':'confirmed','media':'grade','brin':'brin','gin':'gin','log':'log',
 'campus':'campus','professor':'professor','turno_prof':'shift_prof',
}

def traduz_restricao(nome):
    partes = nome.split('_')
    return '_'.join(TOKEN.get(p, p) for p in partes)

def construir_mapa():
    m = {}
    m.update(COLUNA); m.update(TABELA); m.update(TIPO); m.update(OUTRO)
    return m

def aplicar(texto):
    """Traduz IDENTIFICADORES sem tocar no conteúdo dos literais de texto.

    A separação importa: 'confirmada' entre aspas é um rótulo de ENUM e deve
    virar 'confirmed', mas "turma sem sala" dentro de uma mensagem é PROSA —
    substituir palavra por palavra ali produziria "section semester room".
    Por isso o texto é fatiado em literais e não-literais, e cada passe roda
    só onde faz sentido.
    """
    mapa = {}
    mapa.update(COLUNA); mapa.update(TABELA); mapa.update(TIPO); mapa.update(OUTRO)

    partes = re.split(r"('(?:[^']|'')*')", texto)   # ímpares = literais

    for i, parte in enumerate(partes):
        eh_literal = (i % 2 == 1)
        if eh_literal:
            # o literal INTEIRO precisa bater com um rótulo de ENUM ou com o
            # nome de um objeto do banco (schema, tabela, tipo). Prosa nunca
            # bate exatamente, e é assim que ela sai ilesa.
            interno = parte[1:-1]
            achou = False
            for d in (ROTULO, OUTRO, TABELA, TIPO, COLUNA):
                if interno in d:
                    partes[i] = "'%s'" % d[interno]; achou = True; break
            if not achou and 'search_path' in interno:
                # literal que é COMANDO SQL, não prosa: o `\gexec` do [C15] monta
                # um ALTER DATABASE dentro de uma string. O nome do schema aí
                # dentro precisa ser traduzido, ou o banco inglês nasce com o
                # search_path apontando para um schema que não existe.
                for pt_, en_ in OUTRO.items():
                    interno = re.sub(r'\b%s\b' % re.escape(pt_), en_, interno)
                partes[i] = "'%s'" % interno
            continue
        # nomes de restrição e índice, token a token
        parte = re.sub(r'\b(?:uq|fk|ck|ex|idx|ux|pk)_[a-z0-9_]+',
                       lambda mo: traduz_restricao(mo.group(0)), parte)
        # identificadores completos, do mais longo para o mais curto
        for pt in sorted(mapa, key=len, reverse=True):
            parte = re.sub(r'\b%s\b' % re.escape(pt), mapa[pt], parte)
        # apelidos locais de CTE e de listas VALUES
        for pt in sorted(APELIDO, key=len, reverse=True):
            parte = re.sub(r'\b%s\b' % re.escape(pt), APELIDO[pt], parte)
        partes[i] = parte
    return ''.join(partes)

CABECALHO = """-- ============================================================================
-- %s — %s
-- College · English mirror of the Brazilian academic model
--
-- GENERATED FILE — do not edit by hand.
--   source: %s   (Portuguese, the single source of truth)
--   run:    python3 scripts/gerar_college.py
--
-- SCOPE: schema + data only. Queries, views, indexes, transactions and the
-- security layer stay in the Portuguese repository — the security script
-- creates ROLES, which are CLUSTER-wide objects and would collide with the
-- ones already owned by the `matricula` database.
--
-- The structure is IDENTICAL to the Portuguese model: same 41 tables, same
-- columns, same constraints. Only the identifiers changed. Explanatory
-- comments were left in Portuguese on purpose — they carry the reasoning
-- behind each decision, and machine-translating that prose would degrade it.
--
-- VOCABULARY NOTE, because a literal translation would mislead an English
-- reader: in the Brazilian system `curso` is the degree a student graduates
-- with and `disciplina` is the subject taught in a term. The English academic
-- vocabulary maps these to PROGRAM and COURSE respectively — so
-- `curso -> program` and `disciplina -> course`. Translating `curso` as
-- "course" would collide with the other concept in every query.
-- ============================================================================
"""

def gerar(origem, destino, titulo):
    s = io.open(origem, encoding='utf-8').read()
    s = aplicar(s)
    s = s.replace('SET search_path TO academic, public;',
                  'SET search_path TO academic, public;')
    io.open(destino, 'w', encoding='utf-8').write(
        CABECALHO % (os.path.basename(destino), titulo, origem) + s)
    return len(s.splitlines())

# Palavras reservadas do PostgreSQL 17 que NÃO podem ser nome de coluna sem
# aspas. Traduzir para o inglês aumenta muito a chance de esbarrar numa delas
# (`user`, `window`, `order`), então o gerador confere antes de escrever.
RESERVADAS = set("""
all analyse analyze and any array as asc asymmetric authorization binary both case cast check collate collation
column concurrently constraint create cross current_catalog current_date current_role current_schema current_time
current_timestamp current_user default deferrable desc distinct do else end except false fetch for foreign freeze
from full grant group having ilike in initially inner intersect into is isnull join lateral leading left like
limit localtime localtimestamp natural not notnull null offset on only or order outer overlaps placing primary
references returning right select session_user similar some symmetric system_user table tablesample then to
trailing true union unique user using variadic verbose when where window with
""".split())

def conferir_reservadas():
    problemas = []
    for d, nome in ((TABELA,'TABELA'), (COLUNA,'COLUNA'), (TIPO,'TIPO'),
                    (OUTRO,'OUTRO'), (APELIDO,'APELIDO')):
        for pt, en in d.items():
            if en in RESERVADAS:
                problemas.append('%s: %s -> %s' % (nome, pt, en))
    if problemas:
        raise SystemExit('ABORTADO — nome traduzido é palavra reservada no SQL:\n  '
                         + '\n  '.join(problemas))

if __name__ == '__main__':
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(base)
    conferir_reservadas()
    n1 = gerar('sql/01_ddl.sql', 'college/01_schema.sql', 'schema (41 tables)')
    n2 = gerar('sql/02_carga.sql', 'college/02_seed.sql', 'deterministic seed data')
    n3 = gerar('sql/04_views.sql', 'college/03_views.sql',
               'views and materialized views')
    n4 = gerar('sql/05_volume_legado.sql', 'college/04_legacy_volume.sql',
               'legacy terms 2020-2024, for query-plan evidence')
    print('college/01_schema.sql        %d linhas' % n1)
    print('college/02_seed.sql          %d linhas' % n2)
    print('college/03_views.sql         %d linhas' % n3)
    print('college/04_legacy_volume.sql %d linhas' % n4)
