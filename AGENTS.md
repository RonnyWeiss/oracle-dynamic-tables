# Agent Instructions

Use the custom local skill at:

`.agents/skills/plsql-professional-developer/SKILL.md`

Apply this skill for Oracle SQL and PL/SQL work, including package, procedure,
function, trigger, script, query, review, formatting, commenting, and security
tasks.

## Project Overview

This repository contains a single PL/SQL package: **`pkg_table_diff`**. It provides
table-definition diff utilities for Oracle databases. The package exports table
metadata from the current schema as JSON, compares a target JSON table definition
with the existing database table, and generates CREATE TABLE or ALTER TABLE DDL
to create or synchronize the table structure.

## Public API

| API Method | Purpose |
|---|---|
| `export_table_json(p_table_name, p_as_clob_expression)` | Exports one table metadata as formatted JSON or as a PL/SQL diff block (CLOB). The lookup is case-insensitive against USER_TABLES. |
| `export_table_diff_block(p_table_like)` | Generates an anonymous PL/SQL block for **all** tables matching a SQL LIKE pattern (USER_TABLES.TABLE_NAME). The returned block contains constants per table and calls generate_table_diff for each. |
| `generate_table_diff(p_target_json, p_apply, p_drop_columns, p_print_diff_script, p_skip_errors)` | Core diff engine. Takes target JSON, generates CREATE or ALTER DDL, optionally applies it, returns the script as CLOB. |
| `apply_table_diff(p_target_json, p_drop_columns, p_print_diff_script, p_skip_errors)` | Convenience wrapper: calls generate_table_diff then executes returned DDL via EXECUTE IMMEDIATE. Parses SQL statements from CLOB (handles strings, quotes, comments). |

## JSON Schema

The exported and consumed JSON shape is documented at the top of PKG_TABLE_DIFF.sql
and in the project README. It covers: table name, organization (HEAP/INDEX),
columns, primary key, unique constraints, check constraints, foreign keys (incl.
ON DELETE), and standalone indexes.

## Key Details

- **Dictionary views**: Object lookup uses current-schema USER_* views. The package works against the calling user schema only.
- **Column diff logic** (generate_alter_table): Detects added, dropped, or modified columns (datatype, nullable, default, length/precision/scale). Missing columns are either skipped or emitted as DROP COLUMN depending on p_drop_columns.
- **Constraint/index diff**: Rebuilds primary keys, unique constraints, check constraints, foreign keys, and standalone indexes only when their signature differs from target JSON. Dropping-and-recreating handles name changes or column reordering.
- **Standalone indexes** exclude constraint-backing and system-managed LOB indexes.
- **Defaults & check conditions**: Treated as SQL fragments; comments outside string literals are ignored, semicolons outside literals/comments rejected.
- **p_table_like**: Uses standard SQL LIKE semantics against USER_TABLES.TABLE_NAME.

## Git Workflow

Every change should be committed in git.
