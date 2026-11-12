# pkg_table_diff — Oracle Table Definition Diff Utilities

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**pkg_table_diff needs only a compiled PL/SQL package.** Both source and target systems need nothing but the package installed. No Java, no CLI, no changelog files on disk, no daemon process.

## Why pkg_table_diff? (vs Liquibase / Flyway)

Most migration tools require an external runtime, file-based changelogs, and a central orchestration server.

| Feature | Liquibase / Flyway | pkg_table_diff |
|---|---|---|
| Runtime dependency | Java or CLI binary | None — pure PL/SQL |
| Changelog storage | Files on disk (XML/YAML) | In-memory JSON CLOB |
| Orchestration | Central server required | Executed from any SQL session |
| Dynamic schema changes | Declarative migration scripts | Runtime-driven: target JSON can come from anywhere (API, config table, CSV export) |
| Self-reconciliation | Not built-in | Export → diff → apply in one call |

**Best use cases:**
- **Runtime table adaptation** — Applications that create or modify tables based on user input or configuration without a deployment cycle.
- **Cross-schema sync** — Align table structures between dev / staging / prod via JSON round-trip, no external tool needed.
- **Lightweight DevOps** — No migration server: just package installation and PL/SQL execution.
- **Dynamic tenant schemas** — Onboard new tenants with per-tenant tables defined from configuration JSON.

The package is ideal when you want **schema evolution driven at runtime by data**, not by files or a CI pipeline.

Export table metadata from an Oracle schema as JSON, diff it against a target
definition, and generate ``CREATE TABLE`` or ``ALTER TABLE`` DDL to create or
synchronize the table structure.

## What It Does

- **Export** — Capture the full structural definition of any table in the current
  schema as well-formatted JSON (or as an executable PL/SQL block).
- **Diff** — Compare a target JSON definition against the live database and produce
  DDL to reconcile differences.
- **Apply** — Optionally execute the generated DDL immediately, with error handling.

The package focuses on **table structure**, not table data. All operations are scoped
to the calling user's schema via ``USER_*`` dictionary views.

## Features

| Capability | Details |
|---|---|
| Columns & datatypes | Column names, base datatypes, length/precision/scale, default values, nullable flag, character semantics (CHAR/BYTE). |
| Primary key | Name, column list. Rebuilt when the signature changes. |
| Unique constraints | Name, column list. Rebuilt when the signature changes. |
| Check constraints | Name, condition SQL fragment. Plain NOT NULL checks are omitted (represented by the column nullable flag). |
| Foreign keys | Name, column list, referenced table/columns, ON DELETE behavior (CASCADE, SET NULL, RESTRICT). Rebuilt when the signature changes. |
| Standalone indexes | Name, uniqueness, columns and SQL expressions. Excludes constraint-backing and system-managed LOB indexes. Rebuilt when the signature changes. |
| Table organization | Heap vs. IOT (INDEX) tables. |
| Batch export | Export all tables matching a LIKE pattern in one anonymous PL/SQL block. |
| Error-tolerant apply | SQL-statement parser handles strings, quoted identifiers, comments, and Q-strings during DDL execution. Failures can be skipped or raised immediately. |

## JSON Schema

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
      "columns": ["NAME"]
    }
  ]
}
```

### Column Object Fields

| Field | Type | Description |
|---|---|---|
| name | string | Column name (unquoted identifier). |
| data_type | string | Oracle datatype keyword (e.g. NUMBER, VARCHAR2, DATE). |
| data_length | number or null | Length for character/string types; omitted for others. |
| char_semantics | string or null | CHAR or BYTE character semantics; omitted when not relevant. |
| nullable | boolean | Whether the column allows NULL values. |
| default | string or null | Default value expression (SQL fragment); omitted when no default exists. |

## API Reference

### export_table_json(p_table_name, p_as_clob_expression)

Exports one table's metadata from the current schema as JSON.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| p_table_name | VARCHAR2 | required | Name of the table to export (case-insensitive lookup against USER_TABLES). |
| p_as_clob_expression | VARCHAR2 | Y | N returns formatted JSON. Y returns an anonymous PL/SQL diff/apply block matching export_table_diff_block. |

**Returns:** CLOB containing JSON or a PL/SQL block.

**Example — formatted JSON:**
```sql
select pkg_table_diff.export_table_json('EMPLOYEES', 'N') from sys.dual;
```

### export_table_diff_block(p_table_like)

Generates an anonymous PL/SQL block for all tables matching a SQL LIKE filter.
The returned block declares constants (c_apply, c_skip_errors, c_print_diff_script, c_drop_columns) and one lowercase CLOB constant per matching table named after that table. It calls generate_table_diff for each table.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| p_table_like | VARCHAR2 | % | USER_TABLES.TABLE_NAME LIKE pattern (e.g. 'T_SHARE_%'). |

**Returns:** CLOB containing the anonymous PL/SQL block.

### generate_table_diff(p_target_json, p_apply, p_drop_columns, p_print_diff_script, p_skip_errors)

Core diff engine. Generates CREATE or ALTER DDL from a target JSON definition.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| p_target_json | CLOB | required | JSON table definition (see JSON Schema above). |
| p_apply | BOOLEAN | false | If true, execute generated DDL immediately. |
| p_drop_columns | BOOLEAN | false | If true, emit DROP COLUMN for current columns absent from the target JSON. |
| p_print_diff_script | BOOLEAN | false | If true, prints processing progress and DDL to DBMS_OUTPUT. |
| p_skip_errors | BOOLEAN | true | If true (with p_apply=true), logs failed DDL statements via DBMS_OUTPUT and continues. If false, re-raises the first error. |

**Returns:** CLOB containing the SQL DDL script.

### apply_table_diff(p_target_json, p_drop_columns, p_print_diff_script, p_skip_errors)

Convenience wrapper around generate_table_diff + DDL execution.

Same parameters and return behavior as generate_table_diff, but always calls `p_apply => true` internally (DDL is executed via a SQL-statement parser that handles strings, quoted identifiers, block comments, line comments, and Q-strings).

## Usage Patterns

### Round-trip: Export → Modify → Apply

1. **Export** the current table structure as JSON (with 'Y' for PL/SQL block).
2. **Capture** the returned PL/SQL block, modify c_apply to true, edit the CLOB constants as needed, and re-run.
3. **Verify** changes by re-exporting or querying data.

### Batch Synchronize Multiple Tables

1. Generate a diff/apply block for all matching tables:
```sql
set long 2000000; select pkg_table_diff.export_table_diff_block('T_%') from sys.dual;
```
2. Modify the output: set `c_apply => true` and run against the target schema.

### Self-Reconcile (apply current structure back)

Take the live table, export it as a block, then apply it — no-op if unchanged.

## Diff Logic Details

### Column Diffs (generate_alter_table)

The ALTER path detects:
- **New columns** — added to the target JSON but absent from the current table.
- **Dropped columns** — present in the current table but absent from the target JSON (emitted as DROP COLUMN when p_drop_columns => true; otherwise skipped).
- **Modified columns** — changed datatype, nullable flag, or default value.

### Constraint / Index Diffs

Primary keys, unique constraints, check constraints, foreign keys, and standalone indexes are rebuilt **only when their signature changes**:
1. Current signature is computed by querying the dictionary.
2. Target signature is parsed from the JSON.
3. If signatures differ, the constraint/index is **dropped then recreated** with the target name and columns.

### Index Handling
- Constraint-backing indexes are excluded (replaced by explicit PK/UK definitions).
- LOB indexes (`user_indexes.index_type = 'LOB'`) are excluded.
- Standalone (non-constraint) indexes are captured and rebuilt.
- Index column entries may be plain column names or SQL expressions.

## Limitations
- **Schema scope**: Only the calling user's schema (USER_* views). No cross-schema support.
- **Object names in JSON**: Simple unquoted identifiers only (no double-quotes).
- **DDL parser**: Splits on semicolons respecting strings, comments, and Q-strings. Does not validate SQL syntax before execution.
- **No data migration**: Column changes use MODIFY/ADD/DROP. Large tables may need additional tools for data migration.
- **Only table DDL**: Views, synonyms, triggers, sequences, grants, etc. are not handled.

## Requirements
- Oracle Database 12c or later (uses sys.json_object_t, sys.json_array_t).
- Calling user must have appropriate privileges on the target table(s) and any referenced tables (for foreign keys).
- No external dependencies beyond standard Oracle dictionary views.

## License

SPDX-License-Identifier: MIT
Copyright (c) 2026 Ronny Weiss

See [LICENSE](LICENSE) for details.

---

---


---


## Known Limitations

### Table Rebuild (Organization Change)
When changing the table organization (HEAP $\leftrightarrow$ INDEX), the package generates a rebuild script that creates a _NEW temporary table, copies all rows, drops the original, and renames. This sequence requires **single-session execution** — concurrent apply attempts on the same table will conflict during the rename step.

## Development Process

This repository was built with local AI assistance using **Ollama**.

The process follows a **"Senior Vibe Engineer"** workflow:
- Code generation is step-by-step and context-aware.
- Every line of code is manually reviewed by the author before merging.
- No "raw" LLM dumps — strict adherence to Oracle best practices and project security standards.
