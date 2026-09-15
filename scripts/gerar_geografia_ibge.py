# -*- coding: utf-8 -*-
"""Gera os seeds de geografia COMPLETA do Brasil (27 estados, 5.570 municípios)
a partir da lista do IBGE, para os dois bancos:

  sql/02b_geografia_ibge.sql        (matricula — identificadores em português)
  college/02b_geography_ibge.sql    (college   — identificadores em inglês)

Fonte dos dados: https://github.com/leogermani/estados-e-municipios-ibge
(estados.json e municipios.json — espelho da lista oficial do IBGE; o código
de 7 dígitos do município começa com os 2 dígitos do estado).

Os arquivos gerados são COMMITADOS: a reconstrução do banco continua offline e
determinística. Rodar este script só quando a fonte mudar.

Uso:  python3 scripts/gerar_geografia_ibge.py [estados.json municipios.json]
      (sem argumentos, baixa os dois JSONs do GitHub)
"""
import io, json, sys, urllib.request

RAW = 'https://raw.githubusercontent.com/leogermani/estados-e-municipios-ibge/master/'

def carregar():
    if len(sys.argv) == 3:
        est = json.load(io.open(sys.argv[1], encoding='utf-8'))
        mun = json.load(io.open(sys.argv[2], encoding='utf-8'))
    else:
        est = json.loads(urllib.request.urlopen(RAW + 'estados.json').read().decode('utf-8'))
        mun = json.loads(urllib.request.urlopen(RAW + 'municipios.json').read().decode('utf-8'))
    return est, mun

def q(s):                               # literal SQL com aspas escapadas
    return "'" + s.replace("'", "''") + "'"

def escrever(caminho, cab, ins_estado, val_estado, fim_estado,
             ins_cidade, val_cidade, fim_cidade, verifica):
    out = [cab, '\\set ON_ERROR_STOP on', '', 'BEGIN;', '', ins_estado]
    out.append(',\n'.join(val_estado))
    out.append(fim_estado)
    out.append('')
    out.append(ins_cidade)
    out.append(',\n'.join(val_cidade))
    out.append(fim_cidade)
    out.append('')
    out.append('COMMIT;')
    out.append('')
    out.append(verifica)
    io.open(caminho, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    print('%s  ·  %d estados  ·  %d municípios' % (caminho, len(val_estado), len(val_cidade)))

est, mun = carregar()
estados  = sorted(est.items(), key=lambda kv: kv[0])           # por código IBGE
cidades  = sorted(mun.items(), key=lambda kv: kv[0])
cod2uf   = {cod: dados['sigla'] for cod, dados in est.items()}

CAB = ('-- =========================================================================\n'
       '-- {arq} — GERADO por scripts/gerar_geografia_ibge.py. NÃO EDITAR À MÃO.\n'
       '-- Geografia completa do Brasil: 27 estados + 5.570 municípios com código\n'
       '-- IBGE (fonte: github.com/leogermani/estados-e-municipios-ibge).\n'
       '-- Roda DEPOIS da carga base e é idempotente: ON CONFLICT DO NOTHING sobre\n'
       '-- as unicidades de UF e de código IBGE preserva as linhas já semeadas.\n'
       '-- =========================================================================')

# ---------- matricula (português) ----------
escrever(
    'sql/02b_geografia_ibge.sql',
    CAB.format(arq='02b_geografia_ibge.sql'),
    ('INSERT INTO estado (id_pais, nome_estado, uf_estado)\n'
     "SELECT p.id_pais, v.nome, v.uf\nFROM (VALUES"),
    ['  (%s, %s)' % (q(d['nome']), q(d['sigla'])) for _, d in estados],
    (") AS v(nome, uf)\nJOIN pais p ON p.sigla_pais = 'BR'\n"
     'ON CONFLICT (id_pais, uf_estado) DO NOTHING;'),
    ('INSERT INTO cidade (id_estado, nome_cidade, codigo_ibge_cidade)\n'
     'SELECT e.id_estado, v.nome, v.ibge\nFROM (VALUES'),
    ['  (%s, %s, %s)' % (q(cod2uf[c[:2]]), q(nome), q(c)) for c, nome in cidades],
    (") AS v(uf, nome, ibge)\nJOIN estado e ON e.uf_estado = v.uf\n"
     'ON CONFLICT (codigo_ibge_cidade) DO NOTHING;'),
    ('DO $$\nDECLARE n_est int; n_cid int;\nBEGIN\n'
     '  SELECT count(*) INTO n_est FROM estado;\n'
     '  SELECT count(*) INTO n_cid FROM cidade;\n'
     "  IF n_est <> 27   THEN RAISE EXCEPTION 'Geografia: % estados (esperado 27)', n_est; END IF;\n"
     "  IF n_cid <> 5570 THEN RAISE EXCEPTION 'Geografia: % cidades (esperado 5570)', n_cid; END IF;\n"
     "  RAISE NOTICE 'Geografia IBGE OK: % estados, % municípios.', n_est, n_cid;\nEND $$;"))

# ---------- college (inglês) ----------
escrever(
    'college/02b_geography_ibge.sql',
    CAB.format(arq='02b_geography_ibge.sql').replace('geografia', 'geography'),
    ('INSERT INTO state (country_id, name, abbreviation)\n'
     "SELECT c.country_id, v.name, v.uf\nFROM (VALUES"),
    ['  (%s, %s)' % (q(d['nome']), q(d['sigla'])) for _, d in estados],
    (") AS v(name, uf)\nJOIN country c ON c.iso_code = 'BR'\n"
     'ON CONFLICT (country_id, abbreviation) DO NOTHING;'),
    ('INSERT INTO city (state_id, name, ibge_code)\n'
     'SELECT s.state_id, v.name, v.ibge\nFROM (VALUES'),
    ['  (%s, %s, %s)' % (q(cod2uf[c[:2]]), q(nome), q(c)) for c, nome in cidades],
    (") AS v(uf, name, ibge)\nJOIN state s ON s.abbreviation = v.uf\n"
     'ON CONFLICT (ibge_code) DO NOTHING;'),
    ('DO $$\nDECLARE n_st int; n_ct int;\nBEGIN\n'
     '  SELECT count(*) INTO n_st FROM state;\n'
     '  SELECT count(*) INTO n_ct FROM city;\n'
     "  IF n_st <> 27   THEN RAISE EXCEPTION 'Geography: % states (expected 27)', n_st; END IF;\n"
     "  IF n_ct <> 5570 THEN RAISE EXCEPTION 'Geography: % cities (expected 5570)', n_ct; END IF;\n"
     "  RAISE NOTICE 'IBGE geography OK: % states, % cities.', n_st, n_ct;\nEND $$;"))
