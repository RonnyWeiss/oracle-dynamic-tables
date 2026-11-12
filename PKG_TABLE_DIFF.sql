CREATE OR REPLACE package pkg_table_diff authid current_user as
    --==============================================================================
    -- Table definition diff utilities.
    --
    -- Copyright (c) 2026 Ronny Weiss
    -- Version: 2026-05-26-05
    -- SPDX-License-Identifier: MIT
    --
    -- This package exports table metadata from the current schema as JSON and uses
    -- that JSON to generate CREATE TABLE or ALTER TABLE scripts. The generated JSON
    -- is intended to describe table structure, not table data.
    --
    -- Supported metadata:
    -- * table name and organization (HEAP or INDEX)
    -- * columns, datatypes, defaults, nullability, and character semantics
    -- * primary key
    -- * unique constraints
    -- * general check constraints, excluding plain NOT NULL checks because those are
    --   represented by the column nullable flag
    -- * foreign keys and ON DELETE behavior
    -- * standalone indexes that are not backing constraints or system-managed LOB indexes
    --
    -- JSON shape:
    -- {
    --   "table_name": "EMPLOYEES",
    --   "organization": "HEAP",
    --   "columns": [
    --     {
    --       "name": "ID",
    --       "data_type": "NUMBER",
    --       "nullable": false,
    --       "default": "1"
    --     },
    --     {
    --       "name": "NAME",
    --       "data_type": "VARCHAR2",
    --       "data_length": 100,
    --       "char_semantics": "CHAR",
    --       "nullable": true
    --     }
    --   ],
    --   "primary_key": {
    --     "name": "EMPLOYEES_PK",
    --     "columns": [ "ID" ]
    --   },
    --   "unique_constraints": [
    --     {
    --       "name": "EMPLOYEES_UK1",
    --       "columns": [ "NAME" ]
    --     }
    --   ],
    --   "check_constraints": [
    --     {
    --       "name": "EMPLOYEES_CK1",
    --       "condition": "NAME in ('DANIEL', 'FLORIAN')"
    --     }
    --   ],
    --   "foreign_keys": [
    --     {
    --       "name": "EMP_DEPT_FK",
    --       "columns": [ "DEPT_ID" ],
    --       "ref_table": "DEPARTMENTS",
    --       "ref_columns": [ "ID" ],
    --       "on_delete": "CASCADE"
    --     }
    --   ],
    --   "indexes": [
    --     {
    --       "name": "EMPLOYEES_IX1",
    --       "unique": false,
    --       "columns": [ "NAME", "UPPER(\"STATUS_NAME\")" ]
    --     }
    --   ]
    -- }
    --
    -- Notes:
    -- * Object lookup uses the current schema dictionary views (USER_*).
    -- * Generated DDL accepts only simple unquoted object identifiers from target
    --   JSON. Index column entries may additionally be SQL expressions.
    -- * Defaults and check conditions are SQL fragments; comments outside string
    --   literals are ignored and semicolons outside literals/comments are rejected.
    -- * p_table_like uses SQL LIKE semantics against USER_TABLES.TABLE_NAME.
    -- * generate_table_diff recreates keys, check constraints, foreign keys, and
    --   standalone indexes only when their exported signature differs.
    -- * p_drop_columns controls whether columns missing from the target JSON are
    --   emitted as DROP COLUMN statements.
    --==============================================================================

    --==============================================================================
    -- Generate an anonymous PL/SQL block for all tables matching a LIKE filter.
    --
    -- The returned block declares c_apply, c_skip_errors, c_print_diff_script, and
    -- c_drop_columns constants, plus one lowercase CLOB constant per matching table
    -- named after that table. It calls generate_table_diff for each table. Set
    -- c_print_diff_script to true in the generated block to print the generated DDL.
    -- Set c_drop_columns to true to include DROP COLUMN statements.
    -- Set c_skip_errors to false to stop at the first apply error.
    --
    -- Parameters:
    -- * p_table_like: USER_TABLES.TABLE_NAME LIKE pattern, for example 'T_SHARE_%'.
    --
    -- Returns:
    -- Anonymous PL/SQL diff/apply block as CLOB.
    --
    -- Example:
    -- select pkg_table_diff.export_table_diff_block('T_SHARE_%') from sys.dual;
    --==============================================================================
    function export_table_diff_block (
        p_table_like in varchar2 default '%'
    ) return clob;

    --==============================================================================
    -- Export one table definition as a generated diff/apply block.
    --
    -- Parameters:
    -- * p_table_name:          Name of the table to export. The lookup is case
    --                          insensitive.
    -- * p_as_clob_expression:  Use 'Y' to return an anonymous PL/SQL diff/apply
    --                          block matching export_table_diff_block for this one
    --                          table. Use 'N' to return formatted JSON.
    --
    -- Returns:
    -- Generated anonymous PL/SQL block, or formatted JSON CLOB.
    --
    -- Example:
    -- select pkg_table_diff.export_table_json('EMP') from sys.dual;
    --==============================================================================
    function export_table_json (
        p_table_name         in varchar2,
        p_as_clob_expression in varchar2 default 'Y'
    ) return clob;

    --==============================================================================
    -- Generate a CREATE TABLE or ALTER TABLE script from target JSON.
    --
    -- If the table does not exist, this returns a CREATE TABLE script plus supported
    -- constraints and indexes. If the table exists, this returns ALTER statements for
    -- changed columns and changed, missing, or new constraints/indexes.
    --
    -- Parameters:
    -- * p_target_json:  JSON table definition in the shape documented above.
    -- * p_apply:        If true, execute the generated statements immediately.
    --                   If false, only return the script.
    -- * p_drop_columns: If true, emit DROP COLUMN statements for current columns that
    --                   are absent from p_target_json. If false, leave extra columns.
    -- * p_print_diff_script:
    --                   If true, print processed tables, the generated SQL DDL
    --                   script, and skipped DROP COLUMN candidates through
    --                   DBMS_OUTPUT. If false, do not print it.
    -- * p_skip_errors:  If true and p_apply is true, log failed DDL statements
    --                   through DBMS_OUTPUT and continue with the next statement.
    --                   If false, re-raise the first apply error.
    --
    -- Returns:
    -- SQL DDL script as CLOB.
    --
    -- Example:
    -- declare
    --     l_target_json clob := q'[
    -- {
    --   "table_name": "EMPLOYEES",
    --   "organization": "HEAP",
    --   "columns": [
    --     {
    --       "name": "ID",
    --       "data_type": "NUMBER",
    --       "nullable": false,
    --       "default": "1"
    --     },
    --     {
    --       "name": "NAME",
    --       "data_type": "VARCHAR2",
    --       "data_length": 100,
    --       "char_semantics": "CHAR",
    --       "nullable": true
    --     }
    --   ],
    --   "primary_key": {
    --     "name": "EMPLOYEES_PK",
    --     "columns": [ "ID" ]
    --   }
    -- }
    -- ]';
    --     l_diff_script clob;
    -- begin
    --     l_diff_script := pkg_table_diff.generate_table_diff(
    --         p_target_json        => l_target_json,
    --         p_apply              => false,
    --         p_drop_columns       => false,
    --         p_print_diff_script  => false,
    --         p_skip_errors        => true );
    --     sys.dbms_output.put_line(l_diff_script);
    -- end;
    --==============================================================================
    function generate_table_diff (
        p_target_json        in clob,
        p_apply              in boolean := false,
        p_drop_columns       in boolean := false,
        p_print_diff_script  in boolean := false,
        p_skip_errors        in boolean := true
    ) return clob;

    --==============================================================================
    -- Apply a table definition JSON to the current schema.
    --
    -- This is a convenience wrapper around generate_table_diff followed by execution
    -- of the returned statements.
    --
    -- Parameters:
    -- * p_target_json: JSON table definition in the shape documented above.
    -- * p_drop_columns: If true, emit DROP COLUMN statements for current columns that
    --                   are absent from p_target_json. If false, leave extra columns.
    -- * p_print_diff_script:
    --                   If true, print processed tables, the generated SQL DDL
    --                   script, and skipped DROP COLUMN candidates through
    --                   DBMS_OUTPUT. If false, do not print it.
    -- * p_skip_errors: If true, log failed DDL statements through DBMS_OUTPUT and
    --                  continue with the next statement. If false, re-raise the
    --                  first apply error.
    --
    -- Example:
    -- begin
    --     pkg_table_diff.apply_table_diff(
    --         p_target_json        => pkg_table_diff.export_table_json('EMPLOYEES', 'Y'),
    --         p_drop_columns       => false,
    --         p_print_diff_script  => false,
    --         p_skip_errors        => true );
    -- end;
    --==============================================================================
    procedure apply_table_diff (
        p_target_json        in clob,
        p_drop_columns       in boolean := false,
        p_print_diff_script  in boolean := false,
        p_skip_errors        in boolean := true
    );

end pkg_table_diff;

/


CREATE OR REPLACE package body pkg_table_diff as

    --------------------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------------------
    c_lf                         constant varchar2(1) := chr(10);
    c_clob_expression_chunk_size constant pls_integer := 2400;
    --
    function export_table_json_raw (
        p_table_name in varchar2
    ) return clob;
    --
    function safe_expression (
        p_value in varchar2,
        p_kind  in varchar2
    ) return varchar2;
    --
    procedure apply_table_diff (
        p_script      in clob,
        p_skip_errors in boolean := true
    ) as
        l_pos           pls_integer := 1;
        l_start         pls_integer := 1;
        l_len           pls_integer;
        l_char          varchar2(1);
        l_next_char     varchar2(1);
        l_stmt          varchar2(32767);
        l_in_string     boolean := false;
        l_in_q_string   boolean := false;
        l_in_line_comm  boolean := false;
        l_in_block_comm boolean := false;
        l_q_end         varchar2(1);

        function next_char return varchar2 is
        begin
            if l_pos < l_len then
                return sys.dbms_lob.substr(p_script, 1, l_pos + 1);
            end if;

            return null;
        end next_char;

        procedure execute_stmt (
            p_from in pls_integer,
            p_to   in pls_integer
        ) is
        begin
            l_stmt := trim(sys.dbms_lob.substr(p_script, p_to - p_from, p_from));
            if l_stmt is not null then
                begin
                    execute immediate l_stmt;
                exception
                    when others then
                        sys.dbms_output.put_line('...Apply error: ' || sqlerrm);
                        sys.dbms_output.put_line('...Failed statement:');
                        sys.dbms_output.put_line(l_stmt);

                        if not p_skip_errors then
                            raise;
                        end if;
                end;
            end if;
        end execute_stmt;
    begin
        if p_script is null then
            return;
        end if;

        l_len := sys.dbms_lob.getlength(p_script);
        loop
            exit when l_pos > l_len;
            l_char      := sys.dbms_lob.substr(p_script, 1, l_pos);
            l_next_char := next_char;

            if l_in_line_comm then
                if l_char in ( chr(10), chr(13) ) then
                    l_in_line_comm := false;
                end if;
            elsif l_in_block_comm then
                if l_char = '*' and l_next_char = '/' then
                    l_in_block_comm := false;
                    l_pos := l_pos + 1;
                end if;
            elsif l_in_q_string then
                if l_char = l_q_end and l_next_char = '''' then
                    l_in_q_string := false;
                    l_pos := l_pos + 1;
                end if;
            elsif l_in_string then
                if l_char = '''' then
                    if l_next_char = '''' then
                        l_pos := l_pos + 1;
                    else
                        l_in_string := false;
                    end if;
                end if;
            elsif lower(l_char) = 'q' and l_next_char = '''' and l_pos + 2 <= l_len then
                declare
                    l_delimiter varchar2(1) := sys.dbms_lob.substr(p_script, 1, l_pos + 2);
                begin
                    l_q_end :=
                        case l_delimiter
                            when '[' then ']'
                            when '(' then ')'
                            when '{' then '}'
                            when '<' then '>'
                            else l_delimiter
                        end;
                    l_in_q_string := true;
                    l_pos := l_pos + 2;
                end;
            elsif l_char = '''' then
                l_in_string := true;
            elsif l_char = '-' and l_next_char = '-' then
                l_in_line_comm := true;
                l_pos := l_pos + 1;
            elsif l_char = '/' and l_next_char = '*' then
                l_in_block_comm := true;
                l_pos := l_pos + 1;
            elsif l_char = ';' then
                execute_stmt(
                    p_from => l_start,
                    p_to   => l_pos
                );
                l_start := l_pos + 1;
            end if;

            l_pos := l_pos + 1;
        end loop;
    end apply_table_diff;
    --
    procedure print_clob (
        p_clob in clob
    ) is
        l_pos   pls_integer := 1;
        l_chunk varchar2(32767);
    begin
        if p_clob is null then
            return;
        end if;

        while l_pos <= sys.dbms_lob.getlength(p_clob) loop
            l_chunk := sys.dbms_lob.substr(p_clob, 32767, l_pos);
            sys.dbms_output.put_line(l_chunk);
            l_pos := l_pos + length(l_chunk);
        end loop;
    end print_clob;
    --
    function to_q_literal (
        p_value in varchar2
    ) return varchar2 is
        l_pos     pls_integer := 1;
        l_amp_pos pls_integer;
        l_result  varchar2(32767);

        procedure append_result (
            p_expression in varchar2
        ) is
        begin
            if l_result is not null then
                l_result := l_result || ' || ';
            end if;

            l_result := l_result || p_expression;
        end append_result;

        function quote_text (
            p_text in varchar2
        ) return varchar2 is
            l_delimiters varchar2(30) := q'!~!@#$%^*_+=|:;?/!';
            l_delimiter  varchar2(1);
        begin
            if p_text is null then
                return '''''';
            end if;

            for i in 1..length(l_delimiters) loop
                l_delimiter := substr(l_delimiters, i, 1);
                if instr(p_text, l_delimiter || '''') = 0 then
                    return 'q''' || l_delimiter || p_text || l_delimiter || '''';
                end if;
            end loop;

            return '''' || replace(p_text, '''', '''''') || '''';
        end quote_text;
    begin
        if p_value is null then
            return quote_text(p_text => null);
        end if;

        loop
            l_amp_pos := instr(p_value, chr(38), l_pos);
            if l_amp_pos = 0 then
                if l_pos <= length(p_value) then
                    append_result(quote_text(p_text => substr(p_value, l_pos)));
                elsif l_result is null then
                    append_result(quote_text(p_text => null));
                end if;

                exit;
            end if;

            if l_amp_pos > l_pos then
                append_result(quote_text(p_text => substr(p_value, l_pos, l_amp_pos - l_pos)));
            end if;

            append_result('chr(38)');
            l_pos := l_amp_pos + 1;
        end loop;

        return l_result;
    end to_q_literal;
    --
    function to_clob_expression (
        p_value  in clob,
        p_indent in varchar2 default '        '
    ) return clob is
        l_expr  clob;
        l_pos   pls_integer := 1;
        l_chunk varchar2(32767);

        procedure append_expr (
            p_string in varchar2
        ) is
        begin
            if p_string is not null then
                sys.dbms_lob.writeappend(l_expr, length(p_string), p_string);
            end if;
        end append_expr;
    begin
        sys.dbms_lob.createtemporary(l_expr, true);

        if p_value is null or sys.dbms_lob.getlength(p_value) = 0 then
            append_expr('to_clob(' || to_q_literal(p_value => null) || ')');
            return l_expr;
        end if;

        while l_pos <= sys.dbms_lob.getlength(p_value) loop
            l_chunk := sys.dbms_lob.substr(p_value, c_clob_expression_chunk_size, l_pos);

            if l_pos > 1 then
                append_expr(' ||' || c_lf || p_indent);
            end if;

            append_expr('to_clob(' || to_q_literal(p_value => l_chunk) || ')');
            l_pos := l_pos + length(l_chunk);
        end loop;

        return l_expr;
    end to_clob_expression;
    --
    function format_json (
        p_json in clob
    ) return clob is
        l_in         clob := p_json;
        l_out        clob;
        l_char       varchar2(10);
        l_indent     number := 0;
        l_in_string  boolean := false;
        l_is_escaped boolean := false;
        --
        procedure append (
            p_string in varchar2
        ) is
        begin
            if p_string is not null then
                sys.dbms_lob.writeappend(l_out, length(p_string), p_string);
            end if;
        end;
        --
    begin
        if p_json is null then
            return null;
        end if;
        --
        sys.dbms_lob.createtemporary(l_out, true);
        for i in 1..sys.dbms_lob.getlength(l_in) loop
            l_char := sys.dbms_lob.substr(l_in, 1, i);

            if l_in_string then
                append(l_char);

                if l_is_escaped then
                    l_is_escaped := false;
                elsif l_char = '\' then
                    l_is_escaped := true;
                elsif l_char = '"' then
                    l_in_string := false;
                end if;
            elsif l_char = '"' then
                l_in_string := true;
                append(l_char);
            else
                case l_char
                    when '{' then
                        append('{');
                        append(chr(10));
                        l_indent := l_indent + 2;
                        append(rpad(' ', l_indent));
                    when '[' then
                        append('[');
                        append(chr(10));
                        l_indent := l_indent + 2;
                        append(rpad(' ', l_indent));
                    when '}' then
                        append(chr(10));
                        l_indent := l_indent - 2;
                        append(rpad(' ', l_indent));
                        append('}');
                    when ']' then
                        append(chr(10));
                        l_indent := l_indent - 2;
                        append(rpad(' ', l_indent));
                        append(']');
                    when ',' then
                        append(',');
                        append(chr(10));
                        append(rpad(' ', l_indent));
                    else
                        append(l_char);
                end case;
            end if;
        end loop;

        return l_out;
    end format_json;
    --
    function table_exists (
        p_table in varchar2
    ) return boolean is
        l_cnt number;
    begin
        select
            count(*)
        into l_cnt
        from
            user_tables
        where
            table_name = upper(p_table);

        return l_cnt > 0;
    end table_exists;
    --
    function get_current_organization (
        p_table in varchar2
    ) return varchar2 is
        l_iot varchar2(30);
    begin
        select
            iot_type
        into l_iot
        from
            user_tables
        where
            table_name = upper(p_table);

        return
            case
                when l_iot is null then
                    'HEAP'
                else 'INDEX'
            end;
    end get_current_organization;
    --
    procedure assert_valid (
        p_condition in boolean,
        p_message   in varchar2
    ) is
    begin
        if p_condition is null or not p_condition then
            raise_application_error(-20000, p_message);
        end if;
    end assert_valid;
    --
    function safe_identifier (
        p_name in varchar2,
        p_kind in varchar2
    ) return varchar2 is
        l_name varchar2(128) := upper(trim(p_name));
    begin
        assert_valid(l_name is not null, p_kind || ' is required');
        assert_valid(
            length(l_name) <= 128 and regexp_like(l_name, '^[A-Z][A-Z0-9_$#]*$'),
            'Invalid ' || p_kind || ': ' || substr(p_name, 1, 128)
        );

        return l_name;
    end safe_identifier;
    --
    function safe_identifier_list (
        p_array in sys.json_array_t,
        p_kind  in varchar2
    ) return varchar2 is
        l_list varchar2(32767);
    begin
        assert_valid(p_array is not null, p_kind || ' list is required');
        assert_valid(p_array.get_size > 0, p_kind || ' list must not be empty');

        for i in 0..p_array.get_size - 1 loop
            if i > 0 then
                l_list := l_list || ', ';
            end if;

            l_list := l_list || safe_identifier(
                p_name => p_array.get_string(i),
                p_kind => p_kind
            );
        end loop;

        return l_list;
    end safe_identifier_list;
    --
    function safe_index_column_or_expression (
        p_value in varchar2
    ) return varchar2 is
    begin
        if regexp_like(upper(trim(p_value)), '^[A-Z][A-Z0-9_$#]*$') then
            return safe_identifier(
                p_name => p_value,
                p_kind => 'index column name'
            );
        end if;

        return safe_expression(
            p_value => p_value,
            p_kind  => 'index column expression'
        );
    end safe_index_column_or_expression;
    --
    function safe_index_column_list (
        p_array in sys.json_array_t
    ) return varchar2 is
        l_list varchar2(32767);
    begin
        assert_valid(p_array is not null, 'index column list is required');
        assert_valid(p_array.get_size > 0, 'index column list must not be empty');

        for i in 0..p_array.get_size - 1 loop
            if i > 0 then
                l_list := l_list || ', ';
            end if;

            l_list := l_list || safe_index_column_or_expression(
                p_value => p_array.get_string(i)
            );
        end loop;

        return l_list;
    end safe_index_column_list;
    --
    function safe_expression (
        p_value in varchar2,
        p_kind  in varchar2
    ) return varchar2 is
        l_value        varchar2(32767) := trim(p_value);
        l_result       varchar2(32767);
        l_pos          pls_integer := 1;
        l_len          pls_integer;
        l_char         varchar2(1);
        l_next_char    varchar2(1);
        l_delimiter    varchar2(1);
        l_q_end        varchar2(1);
        l_in_string    boolean := false;
        l_in_q_string  boolean := false;
        l_in_line_comm boolean := false;
        l_in_block_comm boolean := false;

        procedure append_result (
            p_string in varchar2
        ) is
        begin
            if p_string is not null then
                l_result := l_result || p_string;
            end if;
        end append_result;
    begin
        assert_valid(l_value is not null, p_kind || ' is required');

        l_len := length(l_value);
        while l_pos <= l_len loop
            l_char      := substr(l_value, l_pos, 1);
            l_next_char := substr(l_value, l_pos + 1, 1);

            if l_in_line_comm then
                if l_char in ( chr(10), chr(13) ) then
                    l_in_line_comm := false;
                    append_result(p_string => l_char);
                end if;
                l_pos := l_pos + 1;
            elsif l_in_block_comm then
                if l_char = '*' and l_next_char = '/' then
                    l_in_block_comm := false;
                    append_result(p_string => ' ');
                    l_pos := l_pos + 2;
                else
                    l_pos := l_pos + 1;
                end if;
            elsif l_in_q_string then
                append_result(p_string => l_char);
                if l_char = l_q_end and l_next_char = '''' then
                    append_result(p_string => l_next_char);
                    l_in_q_string := false;
                    l_pos := l_pos + 2;
                else
                    l_pos := l_pos + 1;
                end if;
            elsif l_in_string then
                append_result(p_string => l_char);
                if l_char = '''' then
                    if l_next_char = '''' then
                        append_result(p_string => l_next_char);
                        l_pos := l_pos + 2;
                    else
                        l_in_string := false;
                        l_pos := l_pos + 1;
                    end if;
                else
                    l_pos := l_pos + 1;
                end if;
            elsif lower(l_char) = 'q' and l_next_char = '''' and l_pos + 2 <= l_len then
                l_delimiter := substr(l_value, l_pos + 2, 1);
                l_q_end :=
                    case l_delimiter
                        when '[' then ']'
                        when '(' then ')'
                        when '{' then '}'
                        when '<' then '>'
                        else l_delimiter
                    end;
                append_result(p_string => substr(l_value, l_pos, 3));
                l_in_q_string := true;
                l_pos := l_pos + 3;
            elsif l_char = '''' then
                append_result(p_string => l_char);
                l_in_string := true;
                l_pos := l_pos + 1;
            elsif l_char = '-' and l_next_char = '-' then
                append_result(p_string => ' ');
                l_in_line_comm := true;
                l_pos := l_pos + 2;
            elsif l_char = '/' and l_next_char = '*' then
                append_result(p_string => ' ');
                l_in_block_comm := true;
                l_pos := l_pos + 2;
            else
                assert_valid(l_char != ';', p_kind || ' must not contain semicolons');
                append_result(p_string => l_char);
                l_pos := l_pos + 1;
            end if;
        end loop;

        l_result := trim(l_result);
        assert_valid(l_result is not null, p_kind || ' must not only contain comments');

        return l_result;
    end safe_expression;
    --
    function safe_organization (
        p_organization in varchar2
    ) return varchar2 is
        l_organization varchar2(30) := upper(trim(p_organization));
    begin
        assert_valid(l_organization in ( 'HEAP', 'INDEX' ), 'Invalid table organization');
        return l_organization;
    end safe_organization;
    --
    function safe_on_delete (
        p_rule in varchar2
    ) return varchar2 is
        l_rule varchar2(30) := upper(trim(p_rule));
    begin
        assert_valid(l_rule in ( 'CASCADE', 'SET NULL' ), 'Invalid foreign key ON DELETE rule');
        return l_rule;
    end safe_on_delete;
    --
    function clob_to_varchar2 (
        p_clob in clob
    ) return varchar2 is
    begin
        if p_clob is null then
            return null;
        end if;

        assert_valid(
            sys.dbms_lob.getlength(p_clob) <= 32767,
            'CLOB value is too long for VARCHAR2 conversion'
        );

        return sys.dbms_lob.substr(p_clob, 32767, 1);
    end clob_to_varchar2;
    --
    function get_check_condition (
        p_table_name      in varchar2,
        p_constraint_name in varchar2
    ) return clob is
        l_table_name      varchar2(128) := safe_identifier(
                                               p_name => p_table_name,
                                               p_kind => 'table name'
                                           );
        l_constraint_name varchar2(128) := safe_identifier(
                                               p_name => p_constraint_name,
                                               p_kind => 'check constraint name'
                                           );
        l_cursor          integer;
        l_rows            integer;
        l_offset          integer := 0;
        l_chunk_size      integer := 32767;
        l_chunk           varchar2(32767);
        l_chunk_length    integer;
        l_condition       clob;
    begin
        sys.dbms_lob.createtemporary(l_condition, true);

        l_cursor := sys.dbms_sql.open_cursor;
        sys.dbms_sql.parse(
            c             => l_cursor,
            statement     => 'select search_condition ' ||
                             'from user_constraints ' ||
                             'where table_name = :table_name ' ||
                             'and constraint_name = :constraint_name',
            language_flag => sys.dbms_sql.native
        );
        sys.dbms_sql.bind_variable(l_cursor, ':table_name', l_table_name);
        sys.dbms_sql.bind_variable(l_cursor, ':constraint_name', l_constraint_name);
        sys.dbms_sql.define_column_long(l_cursor, 1);

        begin
            l_rows := sys.dbms_sql.execute(l_cursor);
            if sys.dbms_sql.fetch_rows(l_cursor) = 0 then
                sys.dbms_sql.close_cursor(l_cursor);
                sys.dbms_lob.freetemporary(l_condition);
                return null;
            end if;

            loop
                sys.dbms_sql.column_value_long(
                    c            => l_cursor,
                    position     => 1,
                    length       => l_chunk_size,
                    offset       => l_offset,
                    value        => l_chunk,
                    value_length => l_chunk_length
                );

                exit when l_chunk_length = 0;

                sys.dbms_lob.writeappend(l_condition, length(l_chunk), l_chunk);
                l_offset := l_offset + l_chunk_length;
            end loop;

            sys.dbms_sql.close_cursor(l_cursor);
        exception
            when others then
                if sys.dbms_sql.is_open(l_cursor) then
                    sys.dbms_sql.close_cursor(l_cursor);
                end if;

                if sys.dbms_lob.istemporary(l_condition) = 1 then
                    sys.dbms_lob.freetemporary(l_condition);
                end if;

                raise;
        end;

        return to_clob(trim(clob_to_varchar2(p_clob => l_condition)));
    end get_check_condition;
    --
    function is_not_null_check (
        p_constraint_name in varchar2,
        p_condition       in clob
    ) return boolean is
        l_condition varchar2(32767) := upper(trim(clob_to_varchar2(p_clob => p_condition)));
    begin
        if l_condition is null then
            return false;
        end if;

        for c in (
            select
                column_name
            from
                user_cons_columns
            where
                constraint_name = upper(p_constraint_name)
        ) loop
            if l_condition in (
                '"' || upper(c.column_name) || '" IS NOT NULL',
                upper(c.column_name) || ' IS NOT NULL'
            ) then
                return true;
            end if;
        end loop;

        return false;
    end is_not_null_check;
    --
    function build_datatype (
        p_type      in varchar2,
        p_len       in number,
        p_prec      in number,
        p_scale     in number,
        p_semantics in varchar2 default 'BYTE'
    ) return varchar2 is
        l_type      varchar2(128) := upper(trim(p_type));
        l_semantics varchar2(4) := upper(trim(coalesce(p_semantics, 'BYTE')));
    begin
        assert_valid(l_type is not null, 'Column data type is required');
        assert_valid(l_semantics in ( 'BYTE', 'CHAR' ), 'Invalid character semantics');

        case l_type
            when 'VARCHAR2' then
                assert_valid(p_len is null or p_len between 1 and 32767, 'Invalid VARCHAR2 length');
                if p_len is null then
                    return 'varchar2';
                elsif l_semantics = 'CHAR' then
                    return 'varchar2(' || p_len || ' char)';
                else
                    return 'varchar2(' || p_len || ' byte)';
                end if;
            when 'CHAR' then
                assert_valid(p_len is null or p_len between 1 and 32767, 'Invalid CHAR length');
                if p_len is null then
                    return 'char';
                elsif l_semantics = 'CHAR' then
                    return 'char(' || p_len || ' char)';
                else
                    return 'char(' || p_len || ' byte)';
                end if;
            when 'NUMBER' then
                assert_valid(p_prec is null or p_prec between 1 and 38, 'Invalid NUMBER precision');
                assert_valid(p_scale is null or p_scale between -84 and 127, 'Invalid NUMBER scale');
                if p_prec is null then
                    return 'number';
                elsif p_scale is null then
                    return 'number(' || p_prec || ')';
                else
                    return 'number(' || p_prec || ',' || p_scale || ')';
                end if;
            when 'DATE' then
                return 'date';
            when 'CLOB' then
                return 'clob';
            when 'NCLOB' then
                return 'nclob';
            when 'BLOB' then
                return 'blob';
            when 'BINARY_FLOAT' then
                return 'binary_float';
            when 'BINARY_DOUBLE' then
                return 'binary_double';
            when 'TIMESTAMP' then
                return 'timestamp';
            when 'TIMESTAMP WITH TIME ZONE' then
                return 'timestamp with time zone';
            when 'TIMESTAMP WITH LOCAL TIME ZONE' then
                return 'timestamp with local time zone';
            else
                raise_application_error(-20000, 'Unsupported data type: ' || substr(p_type, 1, 128));
        end case;
    end build_datatype;
    --
    function build_export_table_diff_block (
        p_table_like in varchar2 default null,
        p_table_name in varchar2 default null
    ) return clob is
        l_script    clob;
        l_calls     clob;
        l_json      clob;
        l_expr      clob;
        l_table     varchar2(128);
        l_constant  varchar2(261);

        procedure append_script (
            p_string in varchar2
        ) is
        begin
            if p_string is not null then
                sys.dbms_lob.writeappend(l_script, length(p_string), p_string);
            end if;
        end append_script;

        procedure append_calls (
            p_string in varchar2
        ) is
        begin
            if p_string is not null then
                sys.dbms_lob.writeappend(l_calls, length(p_string), p_string);
            end if;
        end append_calls;

        procedure append_script_clob (
            p_clob in clob
        ) is
        begin
            if p_clob is not null then
                sys.dbms_lob.append(l_script, p_clob);
            end if;
        end append_script_clob;

        function to_plsql_constant_name (
            p_name in varchar2
        ) return varchar2 is
        begin
            return lower(safe_identifier(
                p_name => p_name,
                p_kind => 'generated constant name'
            ));
        end to_plsql_constant_name;

        procedure append_table (
            p_name in varchar2
        ) is
        begin
            l_table    := safe_identifier(
                              p_name => p_name,
                              p_kind => 'table name'
                          );
            l_constant := to_plsql_constant_name(p_name => l_table);
            l_json     := export_table_json_raw(p_table_name => l_table);

            append_script('    -- ' || l_table || c_lf);
            append_script('    ' || l_constant || ' constant clob := ');
            l_expr := to_clob_expression(p_value => l_json);
            append_script_clob(p_clob => l_expr);
            if sys.dbms_lob.istemporary(l_expr) = 1 then
                sys.dbms_lob.freetemporary(l_expr);
            end if;
            append_script(';' || c_lf || c_lf);

            append_calls('    l_diff_script := pkg_table_diff.generate_table_diff(' || c_lf);
            append_calls('        p_target_json        => ' || l_constant || ',' || c_lf);
            append_calls('        p_apply              => c_apply,' || c_lf);
            append_calls('        p_drop_columns       => c_drop_columns,' || c_lf);
            append_calls('        p_print_diff_script  => c_print_diff_script,' || c_lf);
            append_calls('        p_skip_errors        => c_skip_errors );' || c_lf || c_lf);
        end append_table;
    begin
        sys.dbms_lob.createtemporary(l_script, true);
        sys.dbms_lob.createtemporary(l_calls, true);
        append_script('declare' || c_lf);
        append_script('    c_apply             constant boolean := false;' || c_lf);
        append_script('    c_skip_errors       constant boolean := true;' || c_lf);
        append_script('    c_print_diff_script constant boolean := false;' || c_lf);
        append_script('    c_drop_columns      constant boolean := false;' || c_lf);
        append_script(c_lf);
        append_script('    l_diff_script clob;' || c_lf);
        append_script(c_lf);

        if p_table_name is not null then
            append_table(p_name => p_table_name);
        else
            for t in (
                select
                    table_name
                from
                    user_tables
                where
                    table_name like upper(coalesce(p_table_like, '%'))
                order by
                    table_name
            ) loop
                append_table(p_name => t.table_name);
            end loop;
        end if;

        append_script('begin' || c_lf);
        append_script_clob(p_clob => l_calls);
        append_script('end;' || c_lf);
        return l_script;
    end build_export_table_diff_block;
    --
    function export_table_diff_block (
        p_table_like in varchar2 default '%'
    ) return clob is
    begin
        return build_export_table_diff_block(p_table_like => p_table_like);
    end export_table_diff_block;
    --
    --------------------------------------------------------------------------------
    -- EXPORT TABLE AS JSON
    --------------------------------------------------------------------------------
    function export_table_json_raw (
        p_table_name in varchar2
    ) return clob is

        l_table   varchar2(128)     := upper(p_table_name);
        l_root    sys.json_object_t := sys.json_object_t();
        l_cols    sys.json_array_t  := sys.json_array_t();
        l_pkey    sys.json_object_t;
        l_pcols   sys.json_array_t  := sys.json_array_t();
        l_fkeys   sys.json_array_t  := sys.json_array_t();
        l_ukeys   sys.json_array_t  := sys.json_array_t();
        l_ckeys   sys.json_array_t  := sys.json_array_t();
        l_indexes sys.json_array_t  := sys.json_array_t();
        l_clob    clob;
    begin
        l_root.put('table_name', l_table);
        l_root.put('organization', get_current_organization(p_table => l_table));
        for r in (
            select
                column_name,
                data_type,
                data_length,
                data_precision,
                data_scale,
                nullable,
                data_default,
                char_length,
                char_used
            from
                user_tab_columns
            where
                table_name = l_table
            order by
                column_id
        ) loop
            declare
                l_column sys.json_object_t := sys.json_object_t();
            begin
                l_column.put('name', r.column_name);
                l_column.put('data_type', r.data_type);
                if r.data_type in ( 'VARCHAR2', 'CHAR' ) then
                    if r.char_used = 'C' then
                        l_column.put('data_length', r.char_length);
                        l_column.put('char_semantics', 'CHAR');
                    else
                        l_column.put('data_length', r.data_length);
                        l_column.put('char_semantics', 'BYTE');
                    end if;
                end if;

                if r.data_type = 'NUMBER' then
                    if r.data_precision is not null then
                        l_column.put('data_precision', r.data_precision);
                    end if;

                    if r.data_scale is not null then
                        l_column.put('data_scale', r.data_scale);
                    end if;

                end if;

                l_column.put('nullable', (r.nullable = 'Y'));
                if r.data_default is not null then
                    l_column.put('default', trim(r.data_default));
                end if;

                l_cols.append(l_column);
            end;
        end loop;

        l_root.put('columns', l_cols);

        -- PK
        begin
            declare
                l_pk varchar2(128);
            begin
                select
                    constraint_name
                into l_pk
                from
                    user_constraints
                where
                        table_name = l_table
                    and constraint_type = 'P';

                l_pkey := sys.json_object_t();
                l_pkey.put('name', l_pk);
                for c in (
                    select
                        column_name
                    from
                        user_cons_columns
                    where
                        constraint_name = l_pk
                    order by
                        position
                ) loop
                    l_pcols.append(c.column_name);
                end loop;

                l_pkey.put('columns', l_pcols);
                l_root.put('primary_key', l_pkey);
            end;
        exception
            when no_data_found then
                null;
        end;

        -- FKs
        for fk in (
            select
                constraint_name,
                r_constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'R'
            order by constraint_name
        ) loop
            declare
                l_column        sys.json_object_t := sys.json_object_t();
                l_columns       sys.json_array_t := sys.json_array_t();
                l_ref_columns   sys.json_array_t := sys.json_array_t();
                l_ref_table     varchar2(128);
                l_rule          varchar2(128);
            begin
                l_column.put('name', fk.constraint_name);
                select
                    table_name
                into l_ref_table
                from
                    user_constraints
                where
                    constraint_name = fk.r_constraint_name;

                l_column.put('ref_table', l_ref_table);
                for c in (
                    select
                        column_name
                    from
                        user_cons_columns
                    where
                        constraint_name = fk.constraint_name
                    order by
                        position
                ) loop
                    l_columns.append(c.column_name);
                end loop;

                for c in (
                    select
                        column_name
                    from
                        user_cons_columns
                    where
                        constraint_name = fk.r_constraint_name
                    order by
                        position
                ) loop
                    l_ref_columns.append(c.column_name);
                end loop;

                l_column.put('columns', l_columns);
                l_column.put('ref_columns', l_ref_columns);
                select
                    delete_rule
                into l_rule
                from
                    user_constraints
                where
                    constraint_name = fk.constraint_name;

                if l_rule != 'NO ACTION' then
                    l_column.put('on_delete', l_rule);
                end if;
                l_fkeys.append(l_column);
            end;
        end loop;

        if l_fkeys.get_size > 0 then
            l_root.put('foreign_keys', l_fkeys);
        end if;

        -- UCs
        for uc in (
            select
                constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'U'
        ) loop
            declare
                l_column    sys.json_object_t := sys.json_object_t();
                l_columns   sys.json_array_t := sys.json_array_t();
            begin
                l_column.put(
                     'name',
                     uc.constraint_name
                );
                for c in (
                    select
                        column_name
                    from
                        user_cons_columns
                    where
                        constraint_name = uc.constraint_name
                    order by
                        position
                ) loop
                    l_columns.append(c.column_name);
                end loop;

                l_column.put('columns', l_columns);
                l_ukeys.append(l_column);
            end;
        end loop;

        if l_ukeys.get_size > 0 then
            l_root.put('unique_constraints', l_ukeys);
        end if;
        -- Checks
        for ck in (
            select
                c.constraint_name
            from
                user_constraints c
            where
                    c.table_name = l_table
                and c.constraint_type = 'C'
            order by
                c.constraint_name
        ) loop
            declare
                l_column    sys.json_object_t := sys.json_object_t();
                l_condition clob;
            begin
                l_condition := get_check_condition(
                    p_table_name      => l_table,
                    p_constraint_name => ck.constraint_name
                );

                if     l_condition is not null
                   and not is_not_null_check(
                               p_constraint_name => ck.constraint_name,
                               p_condition       => l_condition
                           )
                then
                    l_column.put('name', ck.constraint_name);
                    l_column.put('condition', clob_to_varchar2(p_clob => l_condition));
                    l_ckeys.append(l_column);
                end if;
            end;
        end loop;

        if l_ckeys.get_size > 0 then
            l_root.put('check_constraints', l_ckeys);
        end if;
        -- Indexes
        for ix in (
            select
                index_name,
                uniqueness
            from
                user_indexes ui
            where
                    ui.table_name = l_table
                and ui.index_type != 'LOB'
                and not exists (
                    select
                        1
                    from
                        user_lobs ul
                    where
                            ul.table_name = ui.table_name
                        and ul.index_name = ui.index_name
                )
                and not exists (
                    select
                        1
                    from
                        user_constraints uc
                    where
                        uc.index_name = ui.index_name
                )
        ) loop
            declare
                l_column  sys.json_object_t := sys.json_object_t();
                l_columns sys.json_array_t := sys.json_array_t();
            begin
                l_column.put('name', ix.index_name);
                l_column.put('unique', (ix.uniqueness = 'UNIQUE'));
                for c in (
                    select
                        ic.column_name,
                        ie.column_expression
                    from
                        user_ind_columns ic
                        left join user_ind_expressions ie
                            on  ie.index_name = ic.index_name
                            and ie.column_position = ic.column_position
                    where
                        ic.index_name = ix.index_name
                    order by
                        ic.column_position
                ) loop
                    if c.column_expression is not null then
                        l_columns.append(c.column_expression);
                    else
                        l_columns.append(c.column_name);
                    end if;
                end loop;

                if l_columns.get_size > 0 then
                    l_column.put('columns', l_columns);
                    l_indexes.append(l_column);
                end if;
            end;
        end loop;

        if l_indexes.get_size > 0 then
            l_root.put('indexes', l_indexes);
        end if;

        l_clob := format_json(p_json => l_root.to_clob);
        return l_clob;
    end export_table_json_raw;
    --
    function export_table_json (
        p_table_name         in varchar2,
        p_as_clob_expression in varchar2
    ) return clob is
        l_as_clob_expression varchar2(32767) := upper(trim(p_as_clob_expression));
        l_table              varchar2(128) := safe_identifier(
                                                  p_name => p_table_name,
                                                  p_kind => 'table name'
                                              );
        l_json               clob;
    begin
        if l_as_clob_expression = 'Y' then
            return build_export_table_diff_block(p_table_name => l_table);
        end if;

        l_json := export_table_json_raw(p_table_name => l_table);
        return l_json;
    end export_table_json;
    --
    --------------------------------------------------------------------------------
    -- CREATE TABLE FROM JSON
    --------------------------------------------------------------------------------
    function generate_create_table (
        p_json_object in sys.json_object_t
    ) return clob is

        l_table  varchar2(128) := safe_identifier(
            p_name => p_json_object.get_string('table_name'),
            p_kind => 'table name'
        );
        l_script clob := empty_clob();
        l_cols   sys.json_array_t;
        l_col    sys.json_object_t;
        l_line   varchar2(32767);
        l_org    varchar2(30);
    begin
        l_org    :=
            case
                when p_json_object.has('organization') then
                    safe_organization(p_organization => p_json_object.get_string('organization'))
                else 'HEAP'
            end;

        if l_org = 'INDEX' then
            l_script := 'create table ' || l_table || ' organization index (' || chr(10);
        else
            l_script := 'create table ' || l_table || ' (' || chr(10);
        end if;

        l_cols   := p_json_object.get_array('columns');
        for i in 0..l_cols.get_size - 1 loop
            l_col    := treat(l_cols.get(i) as sys.json_object_t);
            l_line   := '  ' ||
            safe_identifier(
                p_name => l_col.get_string('name'),
                p_kind => 'column name'
            ) ||
            ' ' ||
            build_datatype(
                          p_type => l_col.get_string(
                              'data_type'
                          ),
                          p_len =>
                    case
                        when l_col.has('data_length') then
                            l_col.get_number('data_length')
                    end,
                          p_prec =>
                    case
                        when l_col.has('data_precision') then
                            l_col.get_number('data_precision')
                    end,
                          p_scale =>
                    case
                        when l_col.has('data_scale') then
                            l_col.get_number('data_scale')
                    end,
                          p_semantics =>
                    case
                        when l_col.has('char_semantics') then
                            l_col.get_string('char_semantics')
                        else 'BYTE'
                    end
            );

            if l_col.has('default') then
                l_line := l_line || ' default ' || safe_expression(
                    p_value => l_col.get_string('default'),
                    p_kind  => 'column default'
                );
            end if;

            if l_col.has('nullable') and not l_col.get_boolean('nullable') then
                l_line := l_line || ' not null';
            end if;

            if i < l_cols.get_size - 1 then
                l_line := l_line || ',';
            end if;

            l_script := l_script || l_line || chr(10);
        end loop;
        --
        -- Build PK column list (once, for both IOT and HEAP)
        l_pk_columns_sql varchar2(32767) := '';
        if p_json_object.has('primary_key') then
            declare
                l_pk           sys.json_object_t := p_json_object.get_object('primary_key');
                l_pk_columns   sys.json_array_t  := l_pk.get_array('columns');
            begin
                for i in 0..l_pk_columns.get_size - 1 loop
                    if i > 0 then
                        l_pk_columns_sql := l_pk_columns_sql || ', ';
                    end if;
                    l_pk_columns_sql := l_pk_columns_sql || safe_identifier(
                        p_name => l_pk_columns.get_string(i),
                        p_kind => 'primary key column name'
                    );
                end loop;
            end;
        end if;
        --
        if l_org = 'INDEX' then
            -- IOT: PK must be defined inline in CREATE TABLE statement
            if l_pk_columns_sql is not null then
                l_script := l_script || ',' || chr(10) || '  constraint ' ||
                        safe_identifier(
                            p_name => p_json_object.get_string('primary_key').get_string('name'),
                            p_kind => 'primary key constraint name'
                        ) ||
                        ' primary key (' || l_pk_columns_sql || ');' || chr(10);
            end if;
            l_script := l_script || ');' || chr(10);
        else
            -- HEAP: PK added via separate ALTER TABLE statement
            l_script := l_script || ');' || chr(10);
            if l_pk_columns_sql is not null then
                l_script := l_script ||
                        'alter table ' ||
                        l_table ||
                        ' add constraint ' ||
                        safe_identifier(
                            p_name => p_json_object.get_string('primary_key').get_string('name'),
                            p_kind => 'primary key constraint name'
                        ) ||
                        ' primary key (' ||
                        l_pk_columns_sql ||
                        ');' ||
                        chr(10);
            end if;
        end if;
        --
        -- UCs
        if p_json_object.has('unique_constraints') then
            declare
                l_ucs sys.json_array_t := p_json_object.get_array('unique_constraints');
            begin
                for i in 0..l_ucs.get_size - 1 loop
                    declare
                        l_uc            sys.json_object_t := treat(l_ucs.get(i) as sys.json_object_t);
                        l_uc_columns    sys.json_array_t := l_uc.get_array('columns');
                        l_str           varchar2(32767) := '';
                    begin
                        for j in 0..l_uc_columns.get_size - 1 loop
                            if j > 0 then
                                l_str := l_str || ', ';
                            end if;
                            l_str := l_str || safe_identifier(
                                p_name => l_uc_columns.get_string(j),
                                p_kind => 'unique constraint column name'
                            );
                        end loop;

                        l_script := l_script ||
                        'alter table ' ||
                        l_table ||
                        ' add constraint ' ||
                        safe_identifier(
                            p_name => l_uc.get_string('name'),
                            p_kind => 'unique constraint name'
                        ) ||
                        ' unique (' ||
                        l_str ||
                        ');' ||
                        chr(10);

                    end;
                end loop;

            end;
        end if;
        --
        -- Checks
        if p_json_object.has('check_constraints') then
            declare
                l_cks sys.json_array_t := p_json_object.get_array('check_constraints');
            begin
                for i in 0..l_cks.get_size - 1 loop
                    declare
                        l_ck sys.json_object_t := treat(l_cks.get(i) as sys.json_object_t);
                    begin
                        l_script := l_script ||
                        'alter table ' ||
                        l_table ||
                        ' add constraint ' ||
                        safe_identifier(
                            p_name => l_ck.get_string('name'),
                            p_kind => 'check constraint name'
                        ) ||
                        ' check (' ||
                        safe_expression(
                            p_value => l_ck.get_string('condition'),
                            p_kind  => 'check constraint condition'
                        ) ||
                        ');' ||
                        chr(10);
                    end;
                end loop;
            end;
        end if;
        --
        -- FKs
        if p_json_object.has('foreign_keys') then
            declare
                l_fks sys.json_array_t := p_json_object.get_array('foreign_keys');
            begin
                for i in 0..l_fks.get_size - 1 loop
                    declare
                        l_fk        sys.json_object_t := treat(l_fks.get(i) as sys.json_object_t);
                        l_fk_col    sys.json_array_t  := l_fk.get_array('columns');
                        l_ref_col   sys.json_array_t  := l_fk.get_array('ref_columns');
                        l_str_1     varchar2(32767)   := '';
                        l_str_2     varchar2(32767)   := '';
                        l_rule      varchar2(30);
                    begin
                        for j in 0..l_fk_col.get_size - 1 loop
                            if j > 0 then
                                l_str_1 := l_str_1 || ', ';
                            end if;
                            l_str_1 := l_str_1 || safe_identifier(
                                p_name => l_fk_col.get_string(j),
                                p_kind => 'foreign key column name'
                            );
                        end loop;
                        --
                        for j in 0..l_ref_col.get_size - 1 loop
                            if j > 0 then
                                l_str_2 := l_str_2 || ', ';
                            end if;
                            l_str_2 := l_str_2 || safe_identifier(
                                p_name => l_ref_col.get_string(j),
                                p_kind => 'referenced column name'
                            );
                        end loop;

                        if l_fk.has('on_delete') then
                            l_rule := safe_on_delete(p_rule => l_fk.get_string('on_delete'));
                        end if;

                        l_script := l_script ||
                        'alter table ' ||
                        l_table ||
                        ' add constraint ' ||
                        safe_identifier(
                            p_name => l_fk.get_string('name'),
                            p_kind => 'foreign key constraint name'
                        ) ||
                        ' foreign key (' ||
                        l_str_1 ||
                        ') references ' ||
                        safe_identifier(
                            p_name => l_fk.get_string('ref_table'),
                            p_kind => 'referenced table name'
                        ) ||
                        ' (' ||
                        l_str_2 ||
                        ')';

                        if l_rule is not null then
                            l_script := l_script || ' on delete ' || lower(l_rule);
                        end if;

                        l_script := l_script || ';' || chr(10);
                    end;
                end loop;

            end;
        end if;
        --
        -- Indexes
        if p_json_object.has('indexes') then
            declare
                l_indexes sys.json_array_t := p_json_object.get_array('indexes');
            begin
                for i in 0..l_indexes.get_size - 1 loop
                    declare
                        ix              sys.json_object_t := treat(l_indexes.get(i) as sys.json_object_t);
                        l_ix_columns    sys.json_array_t := ix.get_array('columns');
                        l_str           varchar2(32767) := '';
                    begin
                        for j in 0..l_ix_columns.get_size - 1 loop
                            if j > 0 then
                                l_str := l_str || ', ';
                            end if;
                            l_str := l_str || safe_index_column_or_expression(
                                p_value => l_ix_columns.get_string(j)
                            );
                        end loop;

                        l_script := l_script ||
                        'create ' ||
                            case
                                when ix.get_boolean('unique') then
                                    'unique '
                            end
                                    ||
                        'index ' ||
                        safe_identifier(
                            p_name => ix.get_string('name'),
                            p_kind => 'index name'
                        ) ||
                        ' on ' ||
                        l_table ||
                        ' (' ||
                        l_str ||
                        ');' ||
                        chr(10);

                    end;
                end loop;

            end;
        end if;

        return l_script;
    end generate_create_table;
    --
    --------------------------------------------------------------------------------
    -- ALTER TABLE FROM JSON
    --------------------------------------------------------------------------------
    function generate_alter_table (
        p_json_object        in sys.json_object_t,
        p_drop_columns       in boolean,
        p_print_diff_script  in boolean
    ) return clob is

        l_table   varchar2(128) := safe_identifier(
            p_name => p_json_object.get_string('table_name'),
            p_kind => 'table name'
        );
        l_script  clob := empty_clob();
        type t_col is record (
                name      varchar2(128),
                dtype     varchar2(128),
                len       number,
                prec      number,
                scale     number,
                nullable  varchar2(1),
                def       varchar2(32767),
                semantics varchar2(4)
        );
        type t_cols is
            table of t_col index by varchar2(128);
        l_cur           t_cols;
        l_tar           t_cols;
        l_cols          sys.json_array_t;
        l_col           sys.json_object_t;
        l_org_cur       varchar2(128);
        l_org_tar       varchar2(128);
        l_cur_column    varchar2(128);

        function get_json_columns (
            p_object    in sys.json_object_t,
            p_key       in varchar2,
            p_normalize in boolean default true
        ) return varchar2 is
            l_array sys.json_array_t := p_object.get_array(p_key);
            l_value varchar2(32767);
            l_list  varchar2(32767);
        begin
            for i in 0..l_array.get_size - 1 loop
                if i > 0 then
                    l_list := l_list || ', ';
                end if;

                l_value := safe_identifier(
                    p_name => l_array.get_string(i),
                    p_kind => p_key || ' column name'
                );
                if p_normalize then
                    l_value := upper(l_value);
                end if;

                l_list := l_list || l_value;
            end loop;

            return l_list;
        end get_json_columns;

        function normalize_condition (
            p_condition in clob
        ) return varchar2 is
        begin
            return regexp_replace(
                trim(clob_to_varchar2(p_clob => p_condition)),
                '[[:space:]]+',
                ' '
            );
        end normalize_condition;

        function get_cons_columns (
            p_constraint_name in varchar2
        ) return varchar2 is
            l_list varchar2(32767);
        begin
            for c in (
                select
                    column_name
                from
                    user_cons_columns
                where
                    constraint_name = upper(p_constraint_name)
                order by
                    position
            ) loop
                if l_list is not null then
                    l_list := l_list || ', ';
                end if;

                l_list := l_list || upper(c.column_name);
            end loop;

            return l_list;
        end get_cons_columns;

        function get_index_columns (
            p_index_name in varchar2
        ) return varchar2 is
            l_list varchar2(32767);
        begin
            for c in (
                select
                    ic.column_name,
                    ie.column_expression
                from
                    user_ind_columns ic
                    left join user_ind_expressions ie
                        on  ie.index_name = ic.index_name
                        and ie.column_position = ic.column_position
                where
                    ic.index_name = upper(p_index_name)
                order by
                    ic.column_position
            ) loop
                if l_list is not null then
                    l_list := l_list || ', ';
                end if;

                if c.column_expression is not null then
                    l_list := l_list || regexp_replace(
                        trim(c.column_expression),
                        '[[:space:]]+',
                        ' '
                    );
                else
                    l_list := l_list || upper(c.column_name);
                end if;
            end loop;

            return l_list;
        end get_index_columns;

        function find_target_object (
            p_array_name in varchar2,
            p_name       in varchar2
        ) return sys.json_object_t is
            l_array  sys.json_array_t;
            l_object sys.json_object_t;
        begin
            if not p_json_object.has(p_array_name) then
                return null;
            end if;

            l_array := p_json_object.get_array(p_array_name);
            for i in 0..l_array.get_size - 1 loop
                l_object := treat(l_array.get(i) as sys.json_object_t);
                if upper(l_object.get_string('name')) = upper(p_name) then
                    return l_object;
                end if;
            end loop;

            return null;
        end find_target_object;

        function get_target_pk (
            p_name in varchar2
        ) return sys.json_object_t is
            l_pk sys.json_object_t;
        begin
            if not p_json_object.has('primary_key') then
                return null;
            end if;

            l_pk := p_json_object.get_object('primary_key');
            if upper(l_pk.get_string('name')) = upper(p_name) then
                return l_pk;
            end if;

            return null;
        end get_target_pk;

        function get_target_pk_sig (
            p_pk in sys.json_object_t
        ) return varchar2 is
        begin
            return 'P|' || get_json_columns(
                             p_object => p_pk,
                             p_key    => 'columns' );
        end get_target_pk_sig;

        function get_target_uc_sig (
            p_uc in sys.json_object_t
        ) return varchar2 is
        begin
            return 'U|' || get_json_columns(
                             p_object => p_uc,
                             p_key    => 'columns' );
        end get_target_uc_sig;

        function get_target_ck_sig (
            p_ck in sys.json_object_t
        ) return varchar2 is
        begin
            return 'C|' || normalize_condition(
                p_condition => to_clob(
                    safe_expression(
                        p_value => p_ck.get_string('condition'),
                        p_kind  => 'check constraint condition'
                    )
                )
            );
        end get_target_ck_sig;

        function get_target_fk_sig (
            p_fk in sys.json_object_t
        ) return varchar2 is
            l_delete_rule varchar2(128) := 'NO ACTION';
        begin
            if p_fk.has('on_delete') then
                l_delete_rule := safe_on_delete(p_rule => p_fk.get_string('on_delete'));
            end if;

            return 'R|' ||
                   get_json_columns(
                       p_object => p_fk,
                       p_key    => 'columns' ) ||
                   '|' ||
                   safe_identifier(
                       p_name => p_fk.get_string('ref_table'),
                       p_kind => 'referenced table name'
                   ) ||
                   '|' ||
                   get_json_columns(
                       p_object => p_fk,
                       p_key    => 'ref_columns' ) ||
                   '|' ||
                   l_delete_rule;
        end get_target_fk_sig;

        function get_target_ix_sig (
            p_index in sys.json_object_t
        ) return varchar2 is
        begin
            return 'I|' ||
                   case
                       when p_index.get_boolean('unique') then
                           'UNIQUE'
                       else
                           'NONUNIQUE'
                   end ||
                   '|' ||
                   regexp_replace(
                       safe_index_column_list(
                           p_array => p_index.get_array('columns')
                       ),
                       '[[:space:]]+',
                       ' '
                   );
        end get_target_ix_sig;

        function get_current_pk_sig (
            p_name in varchar2
        ) return varchar2 is
            l_constraint_name varchar2(128);
        begin
            select
                constraint_name
            into l_constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'P'
                and constraint_name = upper(p_name);

            return 'P|' || get_cons_columns(p_constraint_name => l_constraint_name);
        exception
            when no_data_found then
                return null;
        end get_current_pk_sig;

        function get_current_uc_sig (
            p_name in varchar2
        ) return varchar2 is
            l_constraint_name varchar2(128);
        begin
            select
                constraint_name
            into l_constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'U'
                and constraint_name = upper(p_name);

            return 'U|' || get_cons_columns(p_constraint_name => l_constraint_name);
        exception
            when no_data_found then
                return null;
        end get_current_uc_sig;

        function get_current_ck_sig (
            p_name in varchar2
        ) return varchar2 is
            l_condition clob;
            l_exists    pls_integer;
        begin
            select
                1
            into
                l_exists
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'C'
                and constraint_name = upper(p_name);

            l_condition := get_check_condition(
                p_table_name      => l_table,
                p_constraint_name => p_name
            );

            return 'C|' || normalize_condition(p_condition => l_condition);
        exception
            when no_data_found then
                return null;
        end get_current_ck_sig;

        function get_current_fk_sig (
            p_name in varchar2
        ) return varchar2 is
            l_r_constraint_name varchar2(128);
            l_ref_table         varchar2(128);
            l_delete_rule       varchar2(128);
        begin
            select
                r_constraint_name,
                delete_rule
            into
                l_r_constraint_name,
                l_delete_rule
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'R'
                and constraint_name = upper(p_name);

            select
                table_name
            into l_ref_table
            from
                user_constraints
            where
                constraint_name = l_r_constraint_name;

            return 'R|' ||
                   get_cons_columns(p_constraint_name => p_name) ||
                   '|' ||
                   upper(l_ref_table) ||
                   '|' ||
                   get_cons_columns(p_constraint_name => l_r_constraint_name) ||
                   '|' ||
                   upper(l_delete_rule);
        exception
            when no_data_found then
                return null;
        end get_current_fk_sig;

        function get_current_ix_sig (
            p_name in varchar2
        ) return varchar2 is
            l_uniqueness varchar2(128);
        begin
            select
                uniqueness
            into l_uniqueness
            from
                user_indexes ui
            where
                    ui.table_name = l_table
                and ui.index_name = upper(p_name)
                and ui.index_type != 'LOB'
                and not exists (
                    select
                        1
                    from
                        user_lobs ul
                    where
                            ul.table_name = ui.table_name
                        and ul.index_name = ui.index_name
                );

            return 'I|' || upper(l_uniqueness) || '|' || get_index_columns(p_index_name => p_name);
        exception
            when no_data_found then
                return null;
        end get_current_ix_sig;

        function get_pk_add_sql (
            p_pk in sys.json_object_t
        ) return clob is
        begin
            return 'alter table ' ||
                   l_table ||
                   ' add constraint ' ||
                   safe_identifier(
                       p_name => p_pk.get_string('name'),
                       p_kind => 'primary key constraint name'
                   ) ||
                   ' primary key (' ||
                   get_json_columns(
                       p_object    => p_pk,
                       p_key       => 'columns',
                       p_normalize => false ) ||
                   ');' ||
                   chr(10);
        end get_pk_add_sql;

        function get_uc_add_sql (
            p_uc in sys.json_object_t
        ) return clob is
        begin
            return 'alter table ' ||
                   l_table ||
                   ' add constraint ' ||
                   safe_identifier(
                       p_name => p_uc.get_string('name'),
                       p_kind => 'unique constraint name'
                   ) ||
                   ' unique (' ||
                   get_json_columns(
                       p_object    => p_uc,
                       p_key       => 'columns',
                       p_normalize => false ) ||
                   ');' ||
                   chr(10);
        end get_uc_add_sql;

        function get_ck_add_sql (
            p_ck in sys.json_object_t
        ) return clob is
        begin
            return 'alter table ' ||
                   l_table ||
                   ' add constraint ' ||
                   safe_identifier(
                       p_name => p_ck.get_string('name'),
                       p_kind => 'check constraint name'
                   ) ||
                   ' check (' ||
                   safe_expression(
                       p_value => p_ck.get_string('condition'),
                       p_kind  => 'check constraint condition'
                   ) ||
                   ');' ||
                   chr(10);
        end get_ck_add_sql;

        function get_fk_add_sql (
            p_fk in sys.json_object_t
        ) return clob is
            l_script      clob;
            l_delete_rule varchar2(128);
        begin
            if p_fk.has('on_delete') then
                l_delete_rule := safe_on_delete(p_rule => p_fk.get_string('on_delete'));
            end if;

            l_script := 'alter table ' ||
                        l_table ||
                        ' add constraint ' ||
                        safe_identifier(
                            p_name => p_fk.get_string('name'),
                            p_kind => 'foreign key constraint name'
                        ) ||
                        ' foreign key (' ||
                        get_json_columns(
                            p_object    => p_fk,
                            p_key       => 'columns',
                            p_normalize => false ) ||
                        ') references ' ||
                        safe_identifier(
                            p_name => p_fk.get_string('ref_table'),
                            p_kind => 'referenced table name'
                        ) ||
                        ' (' ||
                        get_json_columns(
                            p_object    => p_fk,
                            p_key       => 'ref_columns',
                            p_normalize => false ) ||
                        ')';

            if l_delete_rule is not null then
                l_script := l_script || ' on delete ' || lower(l_delete_rule);
            end if;

            return l_script || ';' || chr(10);
        end get_fk_add_sql;

        function get_ix_add_sql (
            p_index in sys.json_object_t
        ) return clob is
        begin
            return 'create ' ||
                   case
                       when p_index.get_boolean('unique') then
                           'unique '
                   end ||
                   'index ' ||
                   safe_identifier(
                       p_name => p_index.get_string('name'),
                       p_kind => 'index name'
                   ) ||
                   ' on ' ||
                   l_table ||
                   ' (' ||
                   safe_index_column_list(
                       p_array => p_index.get_array('columns')
                   ) ||
                   ');' ||
                   chr(10);
        end get_ix_add_sql;
    begin
        l_org_cur := get_current_organization(p_table => l_table);
        l_org_tar :=
            case
                when p_json_object.has('organization') then
                    safe_organization(p_organization => p_json_object.get_string('organization'))
                else 'HEAP'
            end;
        --
        -- Rebuild when changing organizations
        if l_org_cur != l_org_tar then
            l_script := '-- rebuild due to organization change' || chr(10);
            declare
                l_tmp sys.json_object_t := p_json_object;
                l_cr  clob;
            begin
                l_cr     := generate_create_table(p_json_object => l_tmp);
                l_cr     := replace(
                               l_cr,
                               'create table ' || l_table,
                               'create table ' || l_table || '_NEW'
                            );

                l_script := l_script || l_cr;
            end;

            l_script := l_script ||
            'insert into ' ||
            l_table ||
            '_NEW select * from ' ||
            l_table ||
            ';' ||
            chr(10) ||
            'drop table ' ||
            l_table ||
            ' cascade constraints;' ||
            chr(10) ||
            'alter table ' ||
            l_table ||
            '_NEW rename to ' ||
            l_table ||
            ';' ||
            chr(10);

            return l_script;
        end if;
        --
        -- Current columns
        for r in (
            select
                column_name,
                data_type,
                data_length,
                data_precision,
                data_scale,
                nullable,
                data_default,
                char_length,
                char_used
            from
                user_tab_columns
            where
                table_name = l_table
        ) loop
            l_cur_column                  := safe_identifier(
                p_name => r.column_name,
                p_kind => 'current column name'
            );
            l_cur(l_cur_column).name      := l_cur_column;
            l_cur(l_cur_column).dtype     := r.data_type;
            l_cur(l_cur_column).prec      := r.data_precision;
            l_cur(l_cur_column).scale     := r.data_scale;
            l_cur(l_cur_column).nullable  := r.nullable;
            l_cur(l_cur_column).def       := r.data_default;
            l_cur(l_cur_column).semantics := case
                                                 when r.char_used = 'C' then 'CHAR'
                                                 else 'BYTE'
                                             end;

            if r.data_type in ( 'VARCHAR2', 'CHAR' ) then
                if r.char_used = 'C' then
                    l_cur(l_cur_column).len := r.char_length;
                else
                    l_cur(l_cur_column).len := r.data_length;
                end if;
            else
                l_cur(l_cur_column).len := null;
            end if;

        end loop;
        --
        -- Target columns
        l_cols    := p_json_object.get_array('columns');
        for i in 0..l_cols.get_size - 1 loop
            l_col                         := treat(l_cols.get(i) as sys.json_object_t);
            l_cur_column                  := safe_identifier(
                p_name => l_col.get_string('name'),
                p_kind => 'column name'
            );
            l_tar(l_cur_column).name      := l_cur_column;
            l_tar(l_cur_column).dtype     := l_col.get_string('data_type');
            l_tar(l_cur_column).len       :=
                case
                    when l_col.has('data_length') then
                        l_col.get_number('data_length')
                end;

            l_tar(l_cur_column).prec      :=
                case
                    when l_col.has('data_precision') then
                        l_col.get_number('data_precision')
                end;

            l_tar(l_cur_column).scale     :=
                case
                    when l_col.has('data_scale') then
                        l_col.get_number('data_scale')
                end;

            l_tar(l_cur_column).semantics :=
                case
                    when l_col.has('char_semantics') then
                        l_col.get_string('char_semantics')
                    else 'BYTE'
                end;

            l_tar(l_cur_column).nullable  :=
                case
                    when not l_col.has('nullable') or l_col.get_boolean('nullable') then
                        'Y'
                    else 'N'
                end;

            if l_col.has('default') then
                l_tar(l_cur_column).def := safe_expression(
                    p_value => l_col.get_string('default'),
                    p_kind  => 'column default'
                );
            else
                l_tar(l_cur_column).def := null;
            end if;

        end loop;
        --
        -- new columns
        l_cur_column := l_tar.first;
        while l_cur_column is not null loop
            if not l_cur.exists(l_cur_column) then
                l_script := l_script ||
                'alter table ' ||
                l_table ||
                ' add (' ||
                l_tar(l_cur_column).name ||
                ' ' ||
                build_datatype(
                              p_type => l_tar(l_cur_column).dtype,
                              p_len => l_tar(l_cur_column).len,
                              p_prec => l_tar(l_cur_column).prec,
                              p_scale => l_tar(l_cur_column).scale,
                              p_semantics => l_tar(l_cur_column).semantics
                );

                if l_tar(l_cur_column).def is not null then
                    l_script := l_script || ' default ' || l_tar(l_cur_column).def;
                end if;

                if l_tar(l_cur_column).nullable = 'N' then l_script := l_script || ' not null';
                end if;

                l_script := l_script || ');' || chr(10);
            end if;

            l_cur_column := l_tar.next(l_cur_column);
        end loop;
        --
        -- modified columns
        l_cur_column := l_tar.first;
        while l_cur_column is not null loop
            if l_cur.exists(l_cur_column) then
                declare
                    l_curr             t_col            := l_cur(l_cur_column);
                    l_targ             t_col            := l_tar(l_cur_column);
                    l_datatype_changed boolean          := false;
                    l_default_changed  boolean          := false;
                    l_nullable_changed boolean          := false;
                    l_fragments        varchar2(32767)  := '';
                    l_curr_def         varchar2(32767)  := trim(l_curr.def);
                    l_targ_def         varchar2(32767)  := trim(l_targ.def);
                begin
                    if build_datatype(
                                     p_type => l_curr.dtype,
                                     p_len => l_curr.len,
                                     p_prec => l_curr.prec,
                                     p_scale => l_curr.scale,
                                     p_semantics => l_curr.semantics
                       ) != build_datatype(
                                          p_type => l_targ.dtype,
                                          p_len => l_targ.len,
                                          p_prec => l_targ.prec,
                                          p_scale => l_targ.scale,
                                          p_semantics => l_targ.semantics
                            ) then
                        l_datatype_changed := true;
                    end if;

                    if    (l_curr_def is null and l_targ_def is not null)
                       or (l_curr_def is not null and l_targ_def is null)
                       or l_curr_def != l_targ_def
                    then
                        l_default_changed := true;
                    end if;

                    if coalesce(l_curr.nullable, 'Y') != coalesce(l_targ.nullable, 'Y') then
                        l_nullable_changed := true;
                    end if;

                    if l_datatype_changed or l_default_changed or l_nullable_changed then
                        l_fragments := '';
                        if l_datatype_changed then
                            l_fragments := l_fragments ||
                            build_datatype(
                                          p_type => l_targ.dtype,
                                          p_len => l_targ.len,
                                          p_prec => l_targ.prec,
                                          p_scale => l_targ.scale,
                                          p_semantics => l_targ.semantics
                            );

                        end if;

                        if l_default_changed then
                            if l_fragments is not null then
                                l_fragments := l_fragments || ' ';
                            end if;

                            if l_targ.def is not null then
                                l_fragments := l_fragments || 'default ' || l_targ.def;
                            else
                                l_fragments := l_fragments || 'default null';
                            end if;

                        end if;

                        if l_nullable_changed then
                            if l_fragments is not null then
                                l_fragments := l_fragments || ' ';
                            end if;

                            if l_targ.nullable = 'N' then
                                l_fragments := l_fragments || 'not null';
                            else
                                l_fragments := l_fragments || 'null';
                            end if;

                        end if;

                        l_script    := l_script ||'alter table ' ||
                        l_table ||
                        ' modify (' ||
                        l_targ.name ||
                        ' ' ||
                        l_fragments ||
                        ');' ||
                        chr(10);

                    end if;

                end;
            end if;

            l_cur_column := l_tar.next(l_cur_column);
        end loop;
        --
        -- removed columns
        if p_drop_columns then
            l_cur_column := l_cur.first;
            while l_cur_column is not null loop
                if not l_tar.exists(l_cur_column) then
                    l_script := l_script ||
                    'alter table ' ||
                    l_table ||
                    ' drop column ' ||
                    l_cur(l_cur_column).name ||
                    ';' ||
                    chr(10);
                end if;

                l_cur_column := l_cur.next(l_cur_column);
            end loop;
        elsif p_print_diff_script then
            l_cur_column := l_cur.first;
            while l_cur_column is not null loop
                if not l_tar.exists(l_cur_column) then
                    sys.dbms_output.put_line(
                        'Warning: Skipped DROP COLUMN for ' ||
                        l_table ||
                        '.' ||
                        l_cur(l_cur_column).name ||
                        ' because p_drop_columns is false.'
                    );
                end if;

                l_cur_column := l_cur.next(l_cur_column);
            end loop;
        end if;
        --
        -- Constraints and Indexes: Drop/recreate only missing or changed objects.
        --
        -- Drop changed or removed FKs before parent keys.
        for c in (
            select
                constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'R'
        ) loop
            declare
                l_target sys.json_object_t := find_target_object(
                                                  p_array_name => 'foreign_keys',
                                                  p_name       => c.constraint_name );
            begin
                if    l_target is null
                   or get_current_fk_sig(p_name => c.constraint_name) != get_target_fk_sig(p_fk => l_target)
                then
                    l_script := l_script || 'alter table ' || l_table || ' drop constraint ' ||
                        safe_identifier(
                            p_name => c.constraint_name,
                            p_kind => 'foreign key constraint name'
                        ) || ';' || chr(10);
                end if;
            end;
        end loop;
        --
        -- Drop changed or removed PK.
        for c in (
            select
                constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'P'
        ) loop
            declare
                l_target sys.json_object_t := get_target_pk(p_name => c.constraint_name);
            begin
                if    l_target is null
                   or get_current_pk_sig(p_name => c.constraint_name) != get_target_pk_sig(p_pk => l_target)
                then
                    l_script := l_script || 'alter table ' || l_table || ' drop constraint ' ||
                        safe_identifier(
                            p_name => c.constraint_name,
                            p_kind => 'primary key constraint name'
                        ) || ';' || chr(10);
                end if;
            end;
        end loop;
        --
        -- Drop changed or removed UCs.
        for c in (
            select
                constraint_name
            from
                user_constraints
            where
                    table_name = l_table
                and constraint_type = 'U'
        ) loop
            declare
                l_target sys.json_object_t := find_target_object(
                                                  p_array_name => 'unique_constraints',
                                                  p_name       => c.constraint_name );
            begin
                if    l_target is null
                   or get_current_uc_sig(p_name => c.constraint_name) != get_target_uc_sig(p_uc => l_target)
                then
                    l_script := l_script || 'alter table ' || l_table || ' drop constraint ' ||
                        safe_identifier(
                            p_name => c.constraint_name,
                            p_kind => 'unique constraint name'
                        ) || ';' || chr(10);
                end if;
            end;
        end loop;
        --
        -- Drop changed or removed checks.
        for c in (
            select
                uc.constraint_name
            from
                user_constraints uc
            where
                    uc.table_name = l_table
                and uc.constraint_type = 'C'
        ) loop
            declare
                l_condition clob := get_check_condition(
                                        p_table_name      => l_table,
                                        p_constraint_name => c.constraint_name
                                    );
                l_target    sys.json_object_t := find_target_object(
                                                     p_array_name => 'check_constraints',
                                                     p_name       => c.constraint_name );
            begin
                if     l_condition is not null
                   and not is_not_null_check(
                               p_constraint_name => c.constraint_name,
                               p_condition       => l_condition
                           )
                   and (   l_target is null
                        or get_current_ck_sig(p_name => c.constraint_name) != get_target_ck_sig(p_ck => l_target))
                then
                    l_script := l_script || 'alter table ' || l_table || ' drop constraint ' ||
                        safe_identifier(
                            p_name => c.constraint_name,
                            p_kind => 'check constraint name'
                        ) || ';' || chr(10);
                end if;
            end;
        end loop;
        --
        -- Drop changed or removed unbound indexes.
        for ix in (
            select
                ui.index_name
            from
                user_indexes ui
            where
                    ui.table_name = l_table
                and ui.index_type != 'LOB'
                and not exists (
                    select
                        1
                    from
                        user_lobs ul
                    where
                            ul.table_name = ui.table_name
                        and ul.index_name = ui.index_name
                )
                and not exists (
                    select
                        1
                    from
                        user_constraints uc
                    where
                        uc.index_name = ui.index_name
                )
        ) loop
            declare
                l_target sys.json_object_t := find_target_object(
                                                  p_array_name => 'indexes',
                                                  p_name       => ix.index_name );
            begin
                if    l_target is null
                   or get_current_ix_sig(p_name => ix.index_name) != get_target_ix_sig(p_index => l_target)
                then
                    l_script := l_script || 'drop index ' ||
                        safe_identifier(
                            p_name => ix.index_name,
                            p_kind => 'index name'
                        ) || ';' || chr(10);
                end if;
            end;
        end loop;
        --
        -- Add changed or new PK.
        if p_json_object.has('primary_key') then
            declare
                l_pk sys.json_object_t := p_json_object.get_object('primary_key');
            begin
                -- Drop existing PK before adding a new one (HEAP and IOT, when PK name or columns change)
                if coalesce(get_current_pk_sig(p_name => l_pk.get_string('name')), '#NULL#') != get_target_pk_sig(p_pk => l_pk) then
                    l_script := l_script || 'alter table ' || l_table || ' drop primary key;' || chr(10);
                    l_script := l_script || get_pk_add_sql(p_pk => l_pk);
                end if;
            end;
        end if;
        --
        -- Add changed or new UCs.
        if p_json_object.has('unique_constraints') then
            declare
                l_ucs sys.json_array_t := p_json_object.get_array('unique_constraints');
            begin
                for i in 0..l_ucs.get_size - 1 loop
                    declare
                        l_uc sys.json_object_t := treat(l_ucs.get(i) as sys.json_object_t);
                    begin
                        if coalesce(get_current_uc_sig(p_name => l_uc.get_string('name')), '#NULL#') != get_target_uc_sig(p_uc => l_uc) then
                            l_script := l_script || get_uc_add_sql(p_uc => l_uc);
                        end if;
                    end;
                end loop;
            end;
        end if;
        --
        -- Add changed or new checks.
        if p_json_object.has('check_constraints') then
            declare
                l_cks sys.json_array_t := p_json_object.get_array('check_constraints');
            begin
                for i in 0..l_cks.get_size - 1 loop
                    declare
                        l_ck sys.json_object_t := treat(l_cks.get(i) as sys.json_object_t);
                    begin
                        if coalesce(get_current_ck_sig(p_name => l_ck.get_string('name')), '#NULL#') != get_target_ck_sig(p_ck => l_ck) then
                            l_script := l_script || get_ck_add_sql(p_ck => l_ck);
                        end if;
                    end;
                end loop;
            end;
        end if;
        --
        -- Add changed or new FKs.
        if p_json_object.has('foreign_keys') then
            declare
                l_fks sys.json_array_t := p_json_object.get_array('foreign_keys');
            begin
                for i in 0..l_fks.get_size - 1 loop
                    declare
                        l_fk sys.json_object_t := treat(l_fks.get(i) as sys.json_object_t);
                    begin
                        if coalesce(get_current_fk_sig(p_name => l_fk.get_string('name')), '#NULL#') != get_target_fk_sig(p_fk => l_fk) then
                            l_script := l_script || get_fk_add_sql(p_fk => l_fk);
                        end if;
                    end;
                end loop;
            end;
        end if;
        --
        -- Add changed or new indexes.
        if p_json_object.has('indexes') then
            declare
                l_indexes sys.json_array_t := p_json_object.get_array('indexes');
            begin
                for i in 0..l_indexes.get_size - 1 loop
                    declare
                        l_index sys.json_object_t := treat(l_indexes.get(i) as sys.json_object_t);
                    begin
                        if coalesce(get_current_ix_sig(p_name => l_index.get_string('name')), '#NULL#') != get_target_ix_sig(p_index => l_index) then
                            l_script := l_script || get_ix_add_sql(p_index => l_index);
                        end if;
                    end;
                end loop;
            end;
        end if;

        return l_script;
    end generate_alter_table;
    --
    --------------------------------------------------------------------------------
    -- MAIN DIFF
    --------------------------------------------------------------------------------
    function generate_table_diff (
        p_target_json        in clob,
        p_apply              in boolean := false,
        p_drop_columns       in boolean := false,
        p_print_diff_script  in boolean := false,
        p_skip_errors        in boolean := true
    ) return clob is

        l_json_obj  sys.json_object_t := sys.json_object_t.parse(p_target_json);
        l_table     varchar2(128) := safe_identifier(
            p_name => l_json_obj.get_string('table_name'),
            p_kind => 'table name'
        );
        l_script    clob;
    begin
        if p_print_diff_script then
            sys.dbms_output.put_line('...Processing table ' || l_table || '.');
        end if;

        if not table_exists(p_table => l_table) then
            l_script := generate_create_table(p_json_object => l_json_obj);
        else
            l_script := generate_alter_table(
                                            p_json_object        => l_json_obj,
                                            p_drop_columns       => p_drop_columns,
                                            p_print_diff_script  => p_print_diff_script
                        );
        end if;

        if p_print_diff_script then
            print_clob(p_clob => l_script);
        end if;

        if p_apply then
            apply_table_diff(
                p_script      => l_script,
                p_skip_errors => p_skip_errors
            );
        end if;
        --
        return l_script;
    end generate_table_diff;
    --
    --------------------------------------------------------------------------------
    -- APPLY
    --------------------------------------------------------------------------------
    procedure apply_table_diff (
        p_target_json        in clob,
        p_drop_columns       in boolean := false,
        p_print_diff_script  in boolean := false,
        p_skip_errors        in boolean := true
    ) is
        l_script clob;
    begin
        l_script := generate_table_diff(
                                       p_target_json        => p_target_json,
                                       p_apply              => false,
                                       p_drop_columns       => p_drop_columns,
                                       p_print_diff_script  => p_print_diff_script,
                                       p_skip_errors        => p_skip_errors
                    );
        --
        apply_table_diff(
            p_script      => l_script,
            p_skip_errors => p_skip_errors
        );
    end apply_table_diff;

end pkg_table_diff;
/

