# college — the same model, in English

An English mirror of the Brazilian academic model that lives in `../sql/`.
Same 41 tables, same columns, same constraints — only the identifiers changed.

**Not hand-written.** `../scripts/gerar_college.py` reads the Portuguese files
and applies a translation map. The Portuguese database (`matricula`) is the
single source of truth; this one is derived. When the model changes there,
re-run the generator instead of editing anything here.

```bash
python3 scripts/gerar_college.py          # regenerate from ../sql/
docker exec bd2_aluno_postgres psql -U bd2 -d postgres -c "CREATE DATABASE college"
for f in college/0*.sql; do
  docker exec -i bd2_aluno_postgres psql -q -v ON_ERROR_STOP=1 -U bd2 -d college < "$f"
done
```

## Naming rules

| Rule | Example |
|---|---|
| Tables are **singular** | `pessoa` → `person`, `aluno` → `student` |
| Keys are `<table>_id` | `id_pessoa` → `person_id` |
| Other columns drop the table suffix | `nome_pessoa` → `person.name`, not `person.person_name` |
| Enum labels translate too | `'confirmada'` → `'confirmed'`, `'noturno'` → `'evening'` |

The suffix on every column is the professor's convention `[C14]` and it earns
its keep in Portuguese, where `nome_pessoa` and `nome_curso` never collide.
In English the market convention is the short form, so it was dropped for
non-key columns.

## Two names that are not literal translations

**`curso` → `program`** and **`disciplina` → `course`.** In the Brazilian
system `curso` is the degree you graduate with and `disciplina` is the subject
taught in a term. English academic vocabulary calls those *program* and
*course*. Translating `curso` as "course" would make one English word mean two
different things in every query — the one place where being literal would cost
clarity.

**`usuario` → `app_user`.** `user` is a reserved word in SQL. The generator
refuses to write a file if any translated name collides with a PostgreSQL
reserved keyword — that check caught `janela → window` too, now `window_range`.

## Scope

Schema, seed data, views and the legacy volume. Queries, indexes, transactions
and the security layer stay in the Portuguese repository: the security script
creates ROLES, which are cluster-wide objects and would collide with the ones
the `matricula` database already owns.

## Proof that the translation is faithful

Both databases are built from the same generator input, then compared table by
table:

```
41 tables · matricula 184,239 rows · college 184,239 rows · zero differences
```
