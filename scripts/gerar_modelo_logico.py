# -*- coding: utf-8 -*-
"""Gera o MODELO LÓGICO em draw.io a partir do banco, não de uma lista à mão.

Só tabelas, colunas e relacionamentos com cardinalidade (mín, máx) — sem
painel de normalização, sem página de decisões, sem blocos de prosa.

As cardinalidades são DERIVADAS do esquema, e é isso que impede o erro clássico
de trocar os lados: para uma FK de T -> P,
  · do lado de T  = (1,1) se as colunas da FK são NOT NULL, senão (0,1)
                    — uma linha filha aponta para no máximo um pai;
  · do lado de P  = (0,1) se existe UNIQUE exatamente sobre as colunas da FK
                    (relacionamento 1:1), senão (0,N).
Notação (mín, máx) de Elmasri: o par fica junto da ENTIDADE que ele restringe
e diz quantas vezes CADA instância dela participa do relacionamento.

Uso:  python3 scripts/gerar_modelo_logico.py <banco> <schema> <saida.drawio> "<título da página>"

ATENÇÃO: docs/modelo-tabelas.drawio (p.1) foi ENRIQUECIDO à mão depois de
gerado — anotações [C#]/[E#], CHECKs por coluna e o painel de normalização
(1.354 rótulos vs 1.230 da saída crua). NUNCA regenerar por cima dele; para
conferir sincronia de esquema, gerar num arquivo temporário e comparar.
docs/modelo-college.drawio é saída crua deste script e pode ser regenerado.
"""
import html, io, sys, subprocess, collections

CONTAINER = 'bd2_aluno_postgres'

def psql(banco, sql):
    r = subprocess.run(['docker','exec',CONTAINER,'psql','-U','bd2','-d',banco,'-Atc',sql],
                       capture_output=True, text=True)
    if r.returncode: sys.exit('psql falhou: ' + r.stderr[:400])
    return [l for l in r.stdout.split('\n') if l]

def esc(s): return html.escape(str(s), quote=True)

# ---------------------------------------------------------------- leitura
def ler(banco, schema):
    cols = collections.OrderedDict()
    for l in psql(banco, f"""
        SELECT c.relname||'|'||a.attname||'|'||format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull
        FROM pg_class c JOIN pg_attribute a ON a.attrelid=c.oid
        WHERE c.relnamespace='{schema}'::regnamespace AND c.relkind='r'
          AND a.attnum>0 AND NOT a.attisdropped
        ORDER BY c.relname, a.attnum"""):
        t, col, tipo, nn = l.split('|')
        cols.setdefault(t, []).append({'nome': col, 'tipo': tipo, 'nn': nn in ('t', 'true')})

    pk = collections.defaultdict(set); uq = collections.defaultdict(list)
    for l in psql(banco, f"""
        SELECT con.contype::text||'|'||tc.relname||'|'||
          (SELECT string_agg(att.attname,',' ORDER BY x.ord)
           FROM unnest(con.conkey) WITH ORDINALITY x(k,ord)
           JOIN pg_attribute att ON att.attrelid=con.conrelid AND att.attnum=x.k)
        FROM pg_constraint con JOIN pg_class tc ON tc.oid=con.conrelid
        WHERE con.contype IN ('p','u') AND tc.relnamespace='{schema}'::regnamespace"""):
        tipo, t, c = l.split('|')
        (pk[t].update(c.split(',')) if tipo == 'p' else uq[t].append(tuple(c.split(','))))
    for l in psql(banco, f"""
        SELECT c.relname||'|'||(SELECT string_agg(att.attname,',' ORDER BY x.ord)
           FROM unnest(i.indkey) WITH ORDINALITY x(k,ord)
           JOIN pg_attribute att ON att.attrelid=i.indrelid AND att.attnum=x.k)
        FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid
        WHERE c.relnamespace='{schema}'::regnamespace AND i.indisunique"""):
        t, c = l.split('|'); uq[t].append(tuple(c.split(',')))

    fks = []
    for l in psql(banco, f"""
        SELECT tc.relname||'|'||tp.relname||'|'||
          (SELECT string_agg(att.attname,',' ORDER BY x.ord)
           FROM unnest(con.conkey) WITH ORDINALITY x(k,ord)
           JOIN pg_attribute att ON att.attrelid=con.conrelid AND att.attnum=x.k)||'|'||
          (SELECT string_agg(att.attname,',' ORDER BY x.ord)
           FROM unnest(con.confkey) WITH ORDINALITY x(k,ord)
           JOIN pg_attribute att ON att.attrelid=con.confrelid AND att.attnum=x.k)
        FROM pg_constraint con JOIN pg_class tc ON tc.oid=con.conrelid
        JOIN pg_class tp ON tp.oid=con.confrelid
        WHERE con.contype='f' AND tc.relnamespace='{schema}'::regnamespace
        ORDER BY tc.relname, con.conname"""):
        f, p, cc, pc = l.split('|')
        fks.append({'filho': f, 'pai': p, 'cols': cc.split(','), 'pcols': pc.split(',')})

    fkcols = collections.defaultdict(set)
    for f in fks: fkcols[f['filho']].update(f['cols'])
    return cols, pk, uq, fks, fkcols

def cardinalidade(f, cols, uq):
    nn = {c['nome']: c['nn'] for c in cols[f['filho']]}
    filho_min = 1 if all(nn.get(c, False) for c in f['cols']) else 0
    unico = tuple(f['cols']) in {tuple(u) for u in uq[f['filho']]}
    return f'({filho_min},1)', ('(0,1)' if unico else '(0,N)')

# ---------------------------------------------------------------- geometria
LARG, LIN, CAB = 300, 20, 26
COLW = (150, 105, 45)

def ordenar(tabelas, fks, cols):
    """Ordem topológica = a ordem em que as tabelas podem ser CRIADAS.

    Só FK NOT NULL conta como dependência. Uma FK anulável não obriga ordem
    nenhuma — a linha nasce com NULL e é preenchida depois, que é exatamente
    como o DDL resolve a circularidade entre departamento e professor
    (a constraint entra por ALTER TABLE, no fim). Contar a FK anulável como
    dependência criaria um ciclo, e o ciclo colapsava metade do modelo numa
    coluna só.
    """
    nn = {t: {c['nome']: c['nn'] for c in cols[t]} for t in tabelas}
    dep = {t: {f['pai'] for f in fks
               if f['filho'] == t and f['pai'] != t
               and all(nn[t].get(c, False) for c in f['cols'])}
           for t in tabelas}
    nivel, restantes = {}, dict(dep)
    n = 0
    while restantes:
        prontos = [t for t, d in restantes.items() if not (d - set(nivel))]
        if not prontos:                       # ciclo mesmo entre FKs obrigatórias
            prontos = [min(restantes)]        # solta UMA, não todas
        for t in prontos: nivel[t] = n; restantes.pop(t)
        n += 1
    return nivel

def gerar(banco, schema, saida, titulo):
    cols, pk, uq, fks, fkcols = ler(banco, schema)
    tabelas = list(cols)
    nivel = ordenar(tabelas, fks, cols)
    porcol = collections.defaultdict(list)
    for t in sorted(tabelas, key=lambda t: (nivel[t], t)): porcol[nivel[t]].append(t)

    # Duas passagens. A primeira decide QUAL corredor cada aresta usa e conta
    # quantos trilhos cada corredor precisa; só então a largura de cada corredor
    # é definida e o x das colunas é calculado. Sem isso, um corredor com muitas
    # arestas transborda para dentro da coluna seguinte — foi o que aconteceu.
    ncol = max(porcol) + 1
    def corredor_de(f):
        """Corredor usado pela aresta: o índice i vale para o vão entre a
        coluna i e a i+1. -1 é o vão à esquerda de tudo."""
        cf, cp = nivel[f['filho']], nivel[f['pai']]
        if cf > cp:
            return cp if cf - cp == 1 else cf - 1      # vizinha: ao lado do pai
        if cf < cp:
            return cf                                   # reversa: à direita do filho
        return cf - 1                                   # mesma coluna: à esquerda

    trilhos = collections.Counter()
    for f in fks:
        cf, cp = nivel[f['filho']], nivel[f['pai']]
        trilhos[corredor_de(f)] += 1
        if cf - cp > 1:                                 # salto para a esquerda
            trilhos[cp] += 1
        elif cp - cf > 1:                               # reversa longa
            trilhos[cp - 1] += 1

    LARGVAO = {c: max(150, trilhos[c] * 12 + 46) for c in range(-1, ncol)}
    colx, acc = {}, 40 + LARGVAO[-1]
    for c in range(ncol):
        colx[c] = acc
        acc += LARG + LARGVAO[c]

    alt = {t: CAB + LIN * (len(cols[t]) + 1) for t in tabelas}
    pos = {}
    for c, ts in porcol.items():
        yy = 90
        for t in ts:
            pos[t] = (colx[c], yy); yy += alt[t] + 34
    maxy = max(pos[t][1] + alt[t] for t in tabelas)

    out = []
    w = out.append
    w('<mxfile host="app.diagrams.net" type="device">')
    w('  <diagram id="logico" name="%s">' % esc(titulo))
    w('    <mxGraphModel dx="1400" dy="800" grid="1" gridSize="10" guides="1" tooltips="1" '
      'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1600" pageHeight="1200" '
      'math="0" shadow="0">')
    w('      <root><mxCell id="0" /><mxCell id="1" parent="0" />')

    linhay = {}
    for t in tabelas:
        x, yt = pos[t]
        st = ('shape=table;startSize=%d;container=1;collapsible=0;childLayout=tableLayout;'
              'fixedRows=1;rowLines=0;fontStyle=1;align=center;resizeLast=1;html=1;fontSize=13;'
              'fillColor=#ffffff;strokeColor=#5c5c5c;' % CAB)
        w('        <mxCell id="t_%s" value="%s" style="%s" vertex="1" parent="1">' % (t, esc(t), esc(st)))
        w('          <mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry" />' % (x, yt, LARG, alt[t]))
        w('        </mxCell>')

        def linha(idx, off, celulas, fundo):
            rid = 't_%s_r%d' % (t, idx)
            rs = ('shape=tableRow;horizontal=0;startSize=0;swimlaneHead=0;swimlaneBody=0;'
                  'fillColor=%s;collapsible=0;dropTarget=0;points=[[0,0.5],[1,0.5]];'
                  'portConstraint=eastwest;top=0;left=0;right=0;bottom=0;' % fundo)
            w('        <mxCell id="%s" value="" style="%s" vertex="1" parent="t_%s">' % (rid, esc(rs), t))
            w('          <mxGeometry y="%d" width="%d" height="%d" as="geometry" />' % (off, LARG, LIN))
            w('        </mxCell>')
            cx = 0
            for j, (val, al, extra) in enumerate(celulas):
                cs = ('shape=partialRectangle;connectable=0;fillColor=none;top=0;left=0;bottom=0;'
                      'right=0;align=%s;overflow=hidden;whiteSpace=wrap;html=1;%s' % (al, extra))
                w('        <mxCell id="%s_c%d" value="%s" style="%s" vertex="1" parent="%s">'
                  % (rid, j, esc(val), esc(cs), rid))
                w('          <mxGeometry x="%d" width="%d" height="%d" as="geometry">'
                  '<mxRectangle width="%d" height="%d" as="alternateBounds" /></mxGeometry>'
                  % (cx, COLW[j], LIN, COLW[j], LIN))
                w('        </mxCell>')
                cx += COLW[j]

        linha(0, CAB, [('COLUNA' if 'academico' in schema else 'COLUMN', 'left', 'fontSize=9;spacingLeft=5;fontStyle=1;'),
                       ('TIPO' if 'academico' in schema else 'TYPE', 'left', 'fontSize=9;spacingLeft=5;fontStyle=1;'),
                       ('CH', 'left', 'fontSize=9;spacingLeft=4;fontStyle=1;')], '#eeeeee')
        off = CAB + LIN
        for i, c in enumerate(cols[t], start=1):
            marca = []
            if c['nome'] in pk[t]: marca.append('PK')
            if c['nome'] in fkcols[t]: marca.append('FK')
            if not marca and any(u == (c['nome'],) for u in uq[t]): marca.append('U')
            tipo = (c['tipo'].replace('character varying', 'varchar')
                    .replace('timestamp with time zone', 'timestamptz')
                    .replace(' without time zone', ''))
            linhay[(t, c['nome'])] = pos[t][1] + off + LIN / 2.0
            linha(i, off, [(c['nome'], 'left', 'fontSize=10;spacingLeft=5;'
                            + ('fontStyle=1;' if 'PK' in marca else '')),
                           (tipo, 'left', 'fontSize=9;spacingLeft=5;fontColor=#666666;'),
                           ('/'.join(marca), 'left', 'fontSize=8;spacingLeft=4;fontColor=#b85450;')], 'none')
            off += LIN

    # ------------------------------------------------------------ arestas
    usados = collections.Counter()
    def trilho(c):
        k = usados[c]; usados[c] += 1
        x = colx[c] + LARG + 16 + k * 12 if c >= 0 else 40 + 16 + k * 12
        limite = (colx[c + 1] if c + 1 < ncol else colx[c] + LARG + LARGVAO[c]) - 10
        assert x < limite, 'corredor %d transbordou (%d trilhos)' % (c, k + 1)
        return x

    lane = [maxy + 50]
    for i, f in enumerate(fks):
        cf, cp = nivel[f['filho']], nivel[f['pai']]
        ys = linhay[(f['filho'], f['cols'][0])]
        yt = linhay[(f['pai'], f['pcols'][0])]
        card_f, card_p = cardinalidade(f, cols, uq)
        if cf > cp:                                    # filho depende de pai à esquerda
            if cf - cp == 1:
                tx = trilho(cp)
                pts = [(tx, ys), (tx, yt)]
            else:                                      # salto: desce, cruza por baixo, sobe
                gx, tx2, ly = trilho(cf - 1), trilho(cp), lane[0]
                lane[0] += 14
                pts = [(gx, ys), (gx, ly), (tx2, ly), (tx2, yt)]
            anc = 'exitX=0;exitY=0.5;entryX=1;entryY=0.5;'
        elif cf < cp:                                  # reversa: sai pela direita
            if cp - cf == 1:
                tx = trilho(cf)
                pts = [(tx, ys), (tx, yt)]
            else:
                # reversa que pula colunas: sem descer para a pista, o trecho
                # horizontal de volta atravessaria as tabelas do meio
                gx, tx2, ly = trilho(cf), trilho(cp - 1), lane[0]
                lane[0] += 14
                pts = [(gx, ys), (gx, ly), (tx2, ly), (tx2, yt)]
            anc = 'exitX=1;exitY=0.5;entryX=0;entryY=0.5;'
        else:                                          # mesma coluna
            tx = trilho(cf - 1)
            pts = [(tx, ys), (tx, yt)]
            anc = 'exitX=0;exitY=0.5;entryX=0;entryY=0.5;'
        st = ('edgeStyle=none;html=1;rounded=0;strokeColor=#5c5c5c;'
              'startArrow=ERmany;startFill=0;endArrow=ERone;endFill=0;%s'
              'fontSize=9;exitDx=0;exitDy=0;entryDx=0;entryDy=0;' % anc)
        w('        <mxCell id="fk%d" style="%s" edge="1" parent="1" source="t_%s_r%d" target="t_%s_r%d">'
          % (i, esc(st), f['filho'], [c['nome'] for c in cols[f['filho']]].index(f['cols'][0]) + 1,
             f['pai'], [c['nome'] for c in cols[f['pai']]].index(f['pcols'][0]) + 1))
        w('          <mxGeometry relative="1" as="geometry"><Array as="points">')
        for px, py in pts: w('            <mxPoint x="%d" y="%d" />' % (px, py))
        w('          </Array></mxGeometry>')
        w('        </mxCell>')
        # o rótulo do lado do PAI recua um pouco na linha: várias arestas chegam
        # na mesma PK e, exatamente na ponta, os pares se empilhariam
        for lado, txt in (('-1', card_f), ('0.88', card_p)):
            w('        <mxCell id="fk%d_l%s" value="%s" style="edgeLabel;html=1;align=center;'
              'verticalAlign=middle;resizable=0;points=[];fontSize=9;labelBackgroundColor=#ffffff;" '
              'vertex="1" connectable="0" parent="fk%d">' % (i, lado.replace('-', 'm').replace('.', ''), esc(txt), i))
            w('          <mxGeometry x="%s" relative="1" as="geometry"><mxPoint as="offset" /></mxGeometry>'
              % lado)
            w('        </mxCell>')

    chave = ('<b>(m&#237;n, m&#225;x)</b> junto de cada entidade: quantas vezes CADA linha dela participa do '
             'relacionamento &#183; <b>PK</b> chave prim&#225;ria &#183; <b>FK</b> chave estrangeira &#183; '
             '<b>U</b> &#250;nica'
             if 'academico' in schema else
             '<b>(min, max)</b> next to each entity: how many times EACH of its rows takes part in the '
             'relationship &#183; <b>PK</b> primary key &#183; <b>FK</b> foreign key &#183; <b>U</b> unique')
    w('        <mxCell id="chave" value="%s" style="text;html=1;align=left;verticalAlign=middle;'
      'fillColor=#ffffff;strokeColor=#999999;fontSize=11;spacing=6;" vertex="1" parent="1">' % esc(chave))
    w('          <mxGeometry x="40" y="%d" width="1000" height="34" as="geometry" />' % (lane[0] + 40))
    w('        </mxCell>')
    w('      </root>')
    w('    </mxGraphModel>')
    w('  </diagram>')
    w('</mxfile>')
    io.open(saida, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    print('%s  ·  %d tabelas  ·  %d relacionamentos  ·  %d colunas topológicas'
          % (saida, len(tabelas), len(fks), len(porcol)))

if __name__ == '__main__':
    gerar(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
