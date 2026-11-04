#!/usr/bin/env python3
"""
Prepares a company_dump.sh dump (foundry.django) for restore via psql into a
database whose schema was just created by `manage.py migrate` — so we ONLY emit
COPY blocks (plus the dump's fix-up footer); all DDL in the dump is skipped.

Used by ../restore_dump.sh. Kept in sync with the prepare_dump.py embedded in
foundry.django's gcp_dump_restore.sh (gc-uat branch) — fix bugs in both.

Usage:
  DB_HOST=127.0.0.1 DB_PORT=5432 DB_USER=caretaker DB_NAME=manufapp PGPASSWORD=... \
  FIELD_DEFAULTS=field_defaults.tsv EXPECTED_COUNTS=expected_counts.tsv \
    python3 prepare_dump.py < dump.sql > dump_ready.sql 2> prepare.log

Steps:
  1. Drop all non-PK unique constraints/indexes (avoid unique violations)
  2. Make all FK constraints DEFERRABLE (FK checks defer to COMMIT)
  3. Load each table in its own transaction (FKs are dropped, nothing to defer)
  4. Filter COPY column lists to match the target schema (drops added columns),
     and append target columns the dump predates, filled with the model default
  5. Replace \\N with column defaults for NOT NULL+default columns in COPY data
  6. Skip COPY blocks for tables absent from the target DB
  7. Skip ALL non-COPY lines from the dump (DDL already applied by migrations)
  8. Recreate unique indexes after COMMIT
  9. Reset all sequences to max(id) so future INSERTs don't collide
"""
import sys, subprocess, os, re

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_USER = os.environ.get("DB_USER", "caretaker")
DB_NAME = os.environ.get("DB_NAME", "manufapp")
PW      = os.environ.get("PGPASSWORD", "")

def psql(sql):
    env = dict(os.environ, PGPASSWORD=PW)
    r = subprocess.run(
        ["psql", "-h", DB_HOST, "-p", DB_PORT, "-U", DB_USER,
         "-d", DB_NAME, "-At", "-c", sql],
        capture_output=True, text=True, env=env
    )
    return r.stdout.strip()

# psql() swallows errors, so a bad connection would make every table look absent
# from the target and silently skip the whole dump. Fail loudly instead.
if psql("SELECT 1") != "1":
    sys.stderr.write(f"[FATAL] cannot query {DB_USER}@{DB_HOST}:{DB_PORT}/{DB_NAME}\n")
    sys.exit(1)

# Model field defaults (table → {column: COPY text}), written by field_defaults.py
# from the target image. Django 3.2 drops a new column's DB default once AddField
# has filled the existing rows, so a dump taken before that migration has no value
# for the column and the DB has no default to fall back on: the NOT NULL check
# then rolls back the whole table's COPY (sites, machines, warehouses, ...).
model_defaults = {}
if os.environ.get("FIELD_DEFAULTS"):
    with open(os.environ["FIELD_DEFAULTS"]) as fh:
        for row in fh:
            parts = row.rstrip("\n").split("\t", 3)
            if len(parts) == 4 and parts[0] == "FIELD_DEFAULT":
                model_defaults.setdefault(parts[1], {})[parts[2]] = parts[3]
else:
    sys.stderr.write("[WARN] FIELD_DEFAULTS not set — columns the dump predates stay NULL\n")

col_cache = {}

def get_cols(table):
    if table not in col_cache:
        out = psql(
            f"SELECT column_name FROM information_schema.columns "
            f"WHERE table_schema='public' AND table_name='{table}' "
            f"ORDER BY ordinal_position"
        )
        col_cache[table] = set(c for c in out.split("\n") if c)
    return col_cache[table]

# NOT NULL columns that have a DB-level default — if the dump has \N for
# these (e.g. column added after the dump was taken), replace \N with the default.
notnull_defaults_cache = {}

def get_notnull_defaults(table):
    if table not in notnull_defaults_cache:
        out = psql(
            f"SELECT column_name || '|' || column_default "
            f"FROM information_schema.columns "
            f"WHERE table_schema='public' AND table_name='{table}' "
            f"AND is_nullable='NO' AND column_default IS NOT NULL "
            f"AND column_name != 'id' "
            f"AND column_default NOT LIKE 'nextval%%'"
        )
        defaults = {}
        for row in out.split("\n"):
            if not row.strip(): continue
            parts = row.split("|", 1)
            if len(parts) != 2: continue
            col, default = parts[0].strip(), parts[1].strip()
            # Map PostgreSQL column_default → COPY text-format value
            if default == 'false':
                defaults[col] = 'f'
            elif default == 'true':
                defaults[col] = 't'
            elif re.match(r"^-?\d+$", default):
                defaults[col] = default
            elif default.startswith("'") and "'::character" in default:
                defaults[col] = default.split("'")[1]
            elif default.startswith("'") and default.endswith("'"):
                defaults[col] = default[1:-1]
            elif default.startswith("'{}'"):
                defaults[col] = '{}'
            elif default in ('{}', '[]'):
                defaults[col] = default
            else:
                defaults[col] = default
        defaults.update(model_defaults.get(table, {}))
        notnull_defaults_cache[table] = defaults
    return notnull_defaults_cache[table]

# ── 1. psql savepoint mode: errors roll back just that statement ──────────────
sys.stdout.write("\\set ON_ERROR_ROLLBACK on\n\n")

# ── 2. Drop all non-PK unique constraints/indexes to avoid violations during COPY ─
# Two categories:
#   a) Constraint-backed unique indexes: must drop the CONSTRAINT
#      "DROP INDEX" fails with "constraint ... requires it" for these
#   b) Pure unique indexes (partial UniqueConstraint with condition): drop with DROP INDEX
#
# After COMMIT we recreate all of them using their original CREATE UNIQUE INDEX definition.

# 2a — constraint-backed unique constraints
constraint_rows = psql(
    "SELECT tc.table_name || '|' || tc.constraint_name "
    "FROM information_schema.table_constraints tc "
    "WHERE tc.constraint_type = 'UNIQUE' "
    "AND tc.table_schema = 'public'"
)
constraint_names = set()
if constraint_rows:
    sys.stdout.write("-- Drop unique constraints (constraint-backed) to allow bulk COPY\n")
    for row in constraint_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            table, cname = parts[0].strip(), parts[1].strip()
            constraint_names.add(cname)
            sys.stdout.write(f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS {cname};\n")
    sys.stdout.write("\n")

# 2b — collect ALL non-PK unique index definitions for recreation later
unique_rows = psql(
    "SELECT indexname || '|' || indexdef "
    "FROM pg_indexes "
    "WHERE schemaname='public' "
    "AND indexdef LIKE 'CREATE UNIQUE INDEX%' "
    "AND indexname NOT LIKE '%pkey'"
)
unique_indexes = []  # list of (name, create_sql) to recreate after import
if unique_rows:
    for row in unique_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            name, defn = parts[0].strip(), parts[1].strip()
            unique_indexes.append((name, defn))
            # Only pure (non-constraint-backed) indexes need DROP INDEX
            if name not in constraint_names:
                sys.stdout.write(f"-- Drop partial unique index\nDROP INDEX IF EXISTS {name};\n")
    sys.stdout.write("\n")

# ── 3. Drop ALL FK constraints (DDL outside main transaction) ─────────────────
# Rationale: company-specific dumps don't include every referenced table
# (e.g. companies.profile_img_id → documents, which may be absent).
# Making FKs DEFERRABLE still fails at COMMIT when the referenced row simply
# doesn't exist.  Dropping them entirely lets the COPY complete and the
# COMMIT succeed; referential integrity is enforced by the application layer.
fk_rows = psql(
    "SELECT quote_ident(conrelid::regclass::text) || '|' || quote_ident(conname) "
    "FROM pg_constraint "
    "WHERE contype = 'f' AND connamespace = 'public'::regnamespace"
)
if fk_rows:
    sys.stdout.write("-- Drop all FK constraints (referenced tables may be absent from dump)\n")
    for row in fk_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            table, cname = parts[0].strip(), parts[1].strip()
            sys.stdout.write(f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS {cname};\n")
    sys.stdout.write("\n")

# ── 4. Truncate all business tables to remove migration-seeded rows ───────────
# Migrations insert default data (e.g. partnerskucode rows) whose PKs collide
# with the dump.  Truncating before COPY avoids duplicate-key violations.
SKIP_TABLES = {
    'django_migrations', 'auth_permission', 'django_content_type',
    'auth_group', 'auth_group_permissions',
    'django_celery_beat_crontabschedule', 'django_celery_beat_intervalschedule',
    'django_celery_beat_periodictask', 'django_celery_beat_periodictasks',
    'django_celery_beat_solarschedule', 'django_celery_beat_clockedschedule',
}
all_tables_raw = psql(
    "SELECT tablename FROM pg_tables WHERE schemaname='public'"
)
business_tables = [
    t.strip() for t in all_tables_raw.split("\n")
    if t.strip() and t.strip() not in SKIP_TABLES
]
# One statement per table: a single TRUNCATE of every table (or one transaction
# around every COPY) locks each table and index at once, which overflows the lock
# table on small Cloud SQL tiers ("out of shared memory", ~3200 slots on db-g1-small).
if business_tables:
    sys.stdout.write(f"-- Truncate business tables (clear migration-seeded rows)\n")
    for t in business_tables:
        sys.stdout.write(f'TRUNCATE TABLE "{t}" CASCADE;\n')
    sys.stdout.write("\n")

# ── 5. COPY blocks — each commits on its own (see the TRUNCATE note above) ────

copy_table      = None
keep_indices    = None
kept_bare_cols  = None
skip_block      = False
fill_vals       = []
row_counts      = {}

# company_dump.sh ends with a fix-up footer (content_type remap for core_taggedrecord,
# dangling created_by/last_updated_by reassignment, profile_img/slug cleanup). It must
# run after the data loads: without the content_type remap every tag points at the
# wrong model (source DB content_type ids != freshly-migrated target ids), so
# machines/SKUs show no tags at all.
FOOTER_MARKER   = "-- Fix dangling user-FK references"
FOOTER_SKIP     = ("SET session_replication_role", "ALTER TABLE core_customtag ADD CONSTRAINT core_customtag_slug_key")
footer_lines    = []
in_footer       = False

for raw in sys.stdin:
    line = raw.rstrip("\n")

    if in_footer or (not copy_table and line.startswith(FOOTER_MARKER)):
        in_footer = True
        if not line.startswith(FOOTER_SKIP):  # replica role is session-scoped; slug index is recreated below
            footer_lines.append(raw)
        continue

    if not copy_table:
        # Only emit COPY blocks — skip ALL other lines from the dump.
        # The schema is already created by Django migrations; passing DDL
        # through (CREATE TABLE, ALTER TABLE, SET commands, etc.) causes
        # "relation already exists" errors that cascade into COPY data being
        # misread as SQL statements, aborting the entire transaction.
        m = re.match(r'COPY "(\w+)" \((.+)\) FROM stdin;', line)
        if not m:
            continue  # skip all DDL / comments / SET commands from dump

        copy_table = m.group(1)
        raw_cols   = [c.strip() for c in m.group(2).split(",")]
        bare_cols  = [c.strip('"') for c in raw_cols]
        tgt_cols   = get_cols(copy_table)

        if not tgt_cols:
            sys.stderr.write(f"[SKIP] table not in target: {copy_table}\n")
            skip_block      = True
            keep_indices    = None
            kept_bare_cols  = None
        else:
            keep           = [(i, raw_cols[i], bare_cols[i])
                              for i in range(len(raw_cols)) if bare_cols[i] in tgt_cols]
            keep_indices   = [i         for i, _, _  in keep]
            kept_raw_cols  = [rc        for _, rc, _ in keep]
            kept_bare_cols = [bc        for _, _,  bc in keep]
            dropped        = [bc for bc in bare_cols if bc not in tgt_cols]
            if dropped:
                sys.stderr.write(f"[FILTER] {copy_table}: dropped cols {dropped}\n")
            # Columns added after the dump was taken: fill them the way AddField
            # filled the existing rows, with the model default.
            fill_defs      = {c: v for c, v in model_defaults.get(copy_table, {}).items()
                              if c in tgt_cols and c not in bare_cols}
            fill_vals      = list(fill_defs.values())
            kept_raw_cols  = kept_raw_cols + [f'"{c}"' for c in fill_defs]
            if fill_defs:
                sys.stderr.write(f"[FILL] {copy_table}: added cols {list(fill_defs)} with model defaults\n")
            kept_str       = ", ".join(kept_raw_cols)
            sys.stdout.write(f'COPY "{copy_table}" ({kept_str}) FROM stdin;\n')
            skip_block = False
        continue

    # Inside a COPY block
    if line == "\\.":
        if not skip_block:
            sys.stdout.write(raw)
        copy_table      = None
        keep_indices    = None
        kept_bare_cols  = None
        skip_block      = False
    elif skip_block:
        pass  # drop the row
    elif keep_indices is not None:
        parts      = line.split("\t")
        nn_defs    = get_notnull_defaults(copy_table)
        filtered   = []
        for idx, i in enumerate(keep_indices):
            val = parts[i] if i < len(parts) else r"\N"
            col = kept_bare_cols[idx]
            # Replace \N with the column default for NOT NULL+default columns
            # to avoid "null value violates not-null constraint" on COPY
            if val == r"\N" and col in nn_defs:
                val = nn_defs[col]
            filtered.append(val)
        sys.stdout.write("\t".join(filtered + fill_vals) + "\n")
        row_counts[copy_table] = row_counts.get(copy_table, 0) + 1
    else:
        sys.stdout.write(raw)

# Rows emitted per table — restore_dump.sh compares these with count(*) after the
# import to report any table whose COPY failed (and was rolled back).
if os.environ.get("EXPECTED_COUNTS"):
    with open(os.environ["EXPECTED_COUNTS"], "w") as fh:
        for t in sorted(row_counts):
            fh.write(f"{t}\t{row_counts[t]}\n")


# ── 5b. Dump footer fix-ups (must run after data, before unique indexes) ──────
if footer_lines:
    sys.stdout.write("-- company_dump.sh footer: content_type remap + FK fix-ups\n")
    sys.stdout.write("".join(footer_lines))
    sys.stdout.write("\n")
else:
    sys.stderr.write("[WARN] dump has no fix-up footer — tags may point at the wrong content types\n")

# ── 6. Recreate unique indexes ─────────────────────────────────────────────────
if unique_indexes:
    sys.stdout.write("-- Recreate unique indexes\n")
    for name, defn in unique_indexes:
        sys.stdout.write(f"{defn.replace('CREATE UNIQUE INDEX', 'CREATE UNIQUE INDEX IF NOT EXISTS', 1)};\n")
    sys.stdout.write("\n")

# ── 7. Reset sequences so future INSERTs don't collide with restored IDs ──────
reset_sql = psql(
    "SELECT 'SELECT SETVAL(' || quote_literal(s.relname::text) || "
    "', COALESCE((SELECT MAX(id) FROM ' || quote_ident(t.relname) || '), 1));' "
    "FROM pg_class s "
    "JOIN pg_depend dep ON dep.objid = s.oid AND dep.deptype = 'a' "
    "JOIN pg_class t ON t.oid = dep.refobjid "
    "JOIN pg_attribute col ON col.attrelid = t.oid AND col.attnum = dep.refobjsubid "
    "WHERE s.relkind = 'S' "
    "AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname='public') "
    "AND col.attname = 'id'"
)
if reset_sql:
    sys.stdout.write("-- Reset sequences to max restored id\n")
    for stmt in reset_sql.split("\n"):
        if stmt.strip():
            sys.stdout.write(stmt + "\n")
    sys.stdout.write("\n")
