# pkg_table_diff — Oracle Table Definition Diff Utilities

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Export table metadata from an Oracle schema as JSON, diff it against a target
definition, and generate `CREATE TABLE` or `ALTER TABLE` DDL to create or
synchronize the table structure.

## What It Does

- **Export** — Capture the full structural definition of any table in the current
  schema as well-formatted JSON (or as an executable PL/SQL block).
- **Diff** — Compare a target JSON definition against the live database and produce
  DDL to reconcile differences.
- **Apply** — Optionally execute the generated DDL immediately, with error handling.

The package focuses on **table structure**, not table data. All operations are scoped
to the calling user's schema via `USER_*` dictionary views.

## Features

| Capability | Details |
|---|---|
| Columns & datatypes | Column names, base datatypes, length/precision/scale, default values, nullable flag, character semantics (`CHAR`/`BYTE`). |
| Primary key | Name, column list. Rebuilt when the signature changes. |
| Unique constraints | Name, column list. Rebuilt when the signature changes. |
| Check constraints | Name, condition SQL fragment. Plain `NOT NULL` checks are omitted (represented by the column's nullable flag). |
| Foreign keys | Name, column list, referenced table/columns, ON DELETE behavior (`CASCADE`, `SET NULL`, `RESTRICT`). Rebuilt when the signature changes. |
| Standalone indexes | Name, uniqueness, columns and SQL expressions. Excludes constraint-backing and system-managed LOB indexes. Rebuilt when the signature changes. |
| Table organization | Heap vs. IOT (INDEX) tables. |
| Batch export | Export all tables matching a `LIKE` pattern in one anonymous PL/SQL block. |
| Error-tolerant apply | SQL-statement parser handles strings, quoted identifiers, comments, and Q-strings during DDL execution. Failures can be skipped or raised immediately. |

## JSON Shape

The exported and consumed JSON describes table structure:

```json
{
  "table_name": "EMPLOYEES",
  "organization": "HEAP",
  "columns": [
    {
      "name": "ID",
      "data_type": "NUMBER",
      "nullable": false,
      "default": "1"
    },
    {
      "name": "NAME",
      "data_type": "VARCHAR2",
      "data_length": 100,
      "char_semantics": "CHAR",
      "nullable": true
    }
  ],
  "primary_key": {
    "name": "EMPLOYEES_PK",
    "columns": ["ID"]
  },
  "unique_constraints": [
    {
      "name": "EMPLOYEES_UK1",
      "columns": ["NAME"]
    }
  ],
  "check_constraints": [
    {
      "name": "EMPLOYEES_CK1",
      "condition": "NAME in ('DANIEL', 'FLORIAN')"
    }
  ],
  "foreign_keys": [
    {
      "name": "EMP_DEPT_FK",
      "columns": ["DEPT_ID"],
      "ref_table": "DEPARTMENTS",
      "ref_columns": ["ID"],
      "on_delete": "CASCADE"
    }
  ],
  "indexes": [
    {
      "name": "EMPLOYEES_IX1",
      "unique": false,
      "columns": ["NAME", "UPPER(\"STATUS_NAME\")"]
    }
  ]
}
```

### Column Object Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Column name (unquoted identifier). |
| `data_type` | string | Oracle datatype keyword (e.g. `NUMBER`, `VARCHAR2`, `DATE`). |
| `data_length` | number \| null | Length for character/string types; omitted for others. |
| `char_semantics` | string \| null | `"CHAR"` or `"BYTE"` character semantics; omitted when not relevant. |
| `nullable` | boolean | Whether the column allows NULL values. |
| `default` | string \| null | Default value expression (SQL fragment); omitted when no default exists. |

## API Reference

### `export_table_json(p_table_name, p_as_clob_expression)`

Exports one table's metadata from the current schema as JSON.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_table_name` | `VARCHAR2` | *(required)* | Name of the table to export (case-insensitive lookup against `USER_TABLES`). |
| `p_as_clob_expression` | `VARCHAR2` | `'Y'` | `'N'` — returns formatted JSON. `'Y'` — returns an anonymous PL/SQL diff/apply block matching `export_table_diff_block`. |

**Returns:** CLOB containing JSON or a PL/SQL block.

**Example — formatted JSON:**
```sql
select pkg_table_diff.export_table_json('EMPLOYEES', 'N') from sys.dual;
```

**Example — PL/SQL apply block:**
```sql
select pkg_table_diff.export_table_json('EMPLOYEES', 'Y') from sys.dual;
-- Returns: declare ... begin pkg_table_diff.generate_table_diff(...); end;
```

### `export_table_diff_block(p_table_like)`

Generates an anonymous PL/SQL block for all tables matching a SQL LIKE filter.
The returned block declares constants (`c_apply`, `c_skip_errors`,
`c_print_diff_script`, `c_drop_columns`) and one lowercase CLOB constant per
matching table named after that table. It calls `generate_table_diff` for each
table.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_table_like` | `VARCHAR2` | `'%'` | `USER_TABLES.TABLE_NAME LIKE` pattern (e.g. `'T_SHARE_%'`). |

**Returns:** CLOB containing the anonymous PL/SQL block.

**Example:**
```sql
set long 1000000
select pkg_table_diff.export_table_diff_block('T_SHARE_%') from sys.dual;
-- Modify c_apply to TRUE, then run:
-- set serveroutput on
-- declare
--   c_apply boolean := true;
--   c_skip_errors boolean := false;
--   c_print_diff_script boolean := true;
--   c_drop_columns boolean := false;
--   t_share_1 clob := '...';
-- begin
--   pkg_table_diff.generate_table_diff(c_tab => ...);
-- end;
```

### `generate_table_diff(p_target_json, p_apply, p_drop_columns, p_print_diff_script, p_skip_errors)`

Core diff engine. Generates CREATE or ALTER DDL from a target JSON definition.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_target_json` | `CLOB` | *(required)* | JSON table definition (see JSON Schema above). |
| `p_apply` | `BOOLEAN` | `false` | If true, execute generated DDL immediately. |
| `p_drop_columns` | `BOOLEAN` | `false` | If true, emit `DROP COLUMN` for current columns absent from the target JSON. |
| `p_print_diff_script` | `BOOLEAN` | `false` | If true, prints processing progress and DDL to `DBMS_OUTPUT`. |
| `p_skip_errors` | `BOOLEAN` | `true` | If true (with `p_apply=true`), logs failed DDL statements via `DBMS_OUTPUT` and continues. If false, re-raises the first error. |

**Returns:** CLOB containing the SQL DDL script.

**Example — generate only:**
```sql
declare
  l_target_json clob := q'[
{
  "table_name": "EMPLOYEES",
  "organization": "HEAP",
  "columns": [
    {
      "name": "ID",
      "data_type": "NUMBER",
      "nullable": false,
      "default": "1"
    },
    {
      "name": "NAME",
      "data_type": "VARCHAR2",
      "data_length": 100,
      "char_semantics": "CHAR",
      "nullable": true
    }
  ],
  "primary_key": {
    "name": "EMPLOYEES_PK",
    "columns": ["ID"]
  }
}
]';
  l_diff_script clob;
begin
  l_diff_script := pkg_table_diff.generate_table_diff(
      p_target_json        => l_target_json,
      p_apply              => false,
      p_drop_columns       => false,
      p_print_diff_script  => true,
      p_skip_errors        => true
  );
end;
/
```

**Example — generate and apply:**
```sql
declare
  l_target_json clob := q'[... target JSON ...]';
begin
  pkg_table_diff.generate_table_diff(
      p_target_json        => l_target_json,
      p_apply              => true,
      p_drop_columns       => true,
      p_print_diff_script  => true,
      p_skip_errors        => false   -- raise on first error
  );
end;
/
```

### `apply_table_diff(p_target_json, p_drop_columns, p_print_diff_script, p_skip_errors)`

Convenience wrapper around `generate_table_diff` + DDL execution.

Same parameters and return behavior as `generate_table_diff`, but always calls
`p_apply => true` internally (DDL is executed via a SQL-statement parser that
handles strings, quoted identifiers, block comments, line comments, and Q-strings).

**Example:**
```sql
begin
  pkg_table_diff.apply_table_diff(
      p_target_json        => pkg_table_diff.export_table_json('EMPLOYEES', 'N'),
      p_drop_columns       => false,
      p_print_diff_script  => true,
      p_skip_errors        => true
  );
end;
/
```

## Usage Patterns

### Round-trip: Export → Modify → Apply

1. **Export** the current table structure as JSON (with `'Y'` for PL/SQL block):
   ```sql
   set serveroutput on
   declare
     l_block clob := pkg_table_diff.export_table_json('EMPLOYEES', 'Y');
   begin
     dbms_output.put_line(l_block);
   end;
   /
   ```

2. **Capture** the returned PL/SQL block, modify `c_apply` to `true`, edit the
   CLOB constants as needed, and re-run.

3. **Verify** changes by re-exporting or querying data.

### Batch Synchronize Multiple Tables

1. Generate a diff/apply block for all matching tables:
   ```sql
   set long 2000000
   set pagesize 0
   select pkg_table_diff.export_table_diff_block('T_%') from sys.dual;
   ```

2. Modify the output: set `c_apply => true` and run against the target schema.

### Self-Reconcile (apply current structure back)

```sql
begin
  -- Take the live table, export it as a block, then apply it — no-op if unchanged
  pkg_table_diff.apply_table_diff(
      p_target_json        => pkg_table_diff.export_table_json('MY_TABLE', 'Y'),
      p_drop_columns       => false,
      p_print_diff_script  => true,
      p_skip_errors        => true
  );
end;
/
```

## Diff Logic Details

### Column Diffs (`generate_alter_table`)

The ALTER path detects:

- **New columns** — added to the target JSON but absent from the current table.
- **Dropped columns** — present in the current table but absent from the target
  JSON (emitted as `DROP COLUMN` when `p_drop_columns => true`; otherwise skipped).
- **Modified columns** — changed datatype, nullable flag, or default value
  (handled via `ALTER TABLE ... MODIFY`).

### Constraint / Index Diffs

Primary keys, unique constraints, check constraints, foreign keys, and standalone
indexes are rebuilt **only when their signature changes**:

1. Current signature is computed by querying the dictionary.
2. Target signature is parsed from the JSON.
3. If signatures differ, the constraint/index is **dropped then recreated** with
   the target name and columns.

### Index Handling

- Constraint-backing indexes are excluded (replaced by explicit PK/UK definitions).
- LOB indexes (`user_indexes.index_type = 'LOB'`) are excluded.
- Standalone (non-constraint) indexes are captured and rebuilt.
- Index column entries may be plain column names or SQL expressions (e.g.
  `UPPER("STATUS_NAME")`).

## Limitations

- **Schema scope**: Only the calling user's schema (`USER_*` views). No cross-schema support.
- **Object names in JSON**: Simple unquoted identifiers only (no double-quotes).
- **DDL parser**: Splits on semicolons respecting strings, comments, and Q-strings. Does not validate SQL syntax before execution.
- **No data migration**: Column changes use `MODIFY`/`ADD`/`DROP`. Large tables may need additional tools for data migration.
- **Only table DDL**: Views, synonyms, triggers, sequences, grants, etc. are not handled.

## Requirements

- Oracle Database 12c or later (uses `sys.json_object_t`, `sys.json_array_t`).
- Calling user must have appropriate privileges on the target table(s) and any referenced tables (for foreign keys).
- No external dependencies beyond standard Oracle dictionary views.

## License

SPDX-License-Identifier: MIT
Copyright (c) 2026 Ronny Weiss

See [LICENSE](LICENSE) for details.
