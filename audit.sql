\timing off
BEGIN;

-- We need to put functions somewhere. Naming the schema "_flux" is easy, but in final version it might be configurable.
DROP SCHEMA IF EXISTS _flux cascade;
CREATE SCHEMA _flux;

-- Simplifies creation of functions/types/tables.
SELECT format('Search path (temporarily) set to: %s',
    set_config(
        'search_path',
        '_flux, ' || current_setting('search_path'),
        true
    )
);

-- Possible modifiers of columns to be logged:
-- - all means: all columns from row will be used
-- - include means: only listed columns should be used
-- - exclude means: all but listed columns should be used
CREATE TYPE column_modifier as enum (
    'all',
    'include',
    'exclude'
);

-- What kind of event is responsible for given history change
CREATE TYPE change_type as enum (
    'insert',
    'update',
    'delete'
);

-- Trigger function that handles 'INSERT' events on audited tables.
CREATE OR REPLACE FUNCTION trigger_insert() RETURNS TRIGGER AS $$
DECLARE
    v_log_table     TEXT      :=   TG_ARGV[0];
    v_key_columns   TEXT[]    :=   TG_ARGV[1];
    v_orig_new      hstore;
    v_use_pkey      TEXT[];
    v_sql           TEXT;
BEGIN
    v_sql := format(
        'INSERT INTO %I.%I (change_when, change_by, change_type, row_pkey, row_data) VALUES ($1, $2, $3, $4, NULL)',
        TG_TABLE_SCHEMA,
        v_log_table
    );

    v_orig_new := hstore(NEW);
    v_use_pkey := v_orig_new->v_key_columns;

    EXECUTE v_sql
        USING clock_timestamp(), current_user, lower( TG_OP )::_flux.change_type, v_use_pkey;

    RETURN NULL;
END;
$$ language plpgsql;

-- Trigger function that handles 'DELETE' events on audited tables.
CREATE OR REPLACE FUNCTION trigger_delete() RETURNS TRIGGER AS $$
DECLARE
    v_log_table          TEXT                             :=   TG_ARGV[0];
    v_modifier_type      _flux.column_modifier   :=   TG_ARGV[1];
    v_modifier_columns   TEXT[]                           :=   NULL;
    v_key_columns        TEXT[]                           :=   TG_ARGV[3];
    v_orig_old           hstore;
    v_use_pkey           TEXT[];
    v_use_data           hstore;
    v_sql                TEXT;
BEGIN
    IF v_modifier_type <> 'all' THEN
        v_modifier_columns := TG_ARGV[2];
    END IF;

    v_sql := format(
        'INSERT INTO %I.%I (change_when, change_by, change_type, row_pkey, row_data) VALUES ($1, $2, $3, $4, $5)',
        TG_TABLE_SCHEMA,
        v_log_table
    );

    v_orig_old := hstore(OLD);
    v_use_pkey := v_orig_old->v_key_columns;
    IF v_modifier_type = 'include' THEN
        v_use_data := slice(v_orig_old, v_modifier_columns);
    ELSIF v_modifier_type = 'exclude' THEN
        v_use_data := delete(v_orig_old, v_modifier_columns);
    ELSE
        v_use_data := v_orig_old;
    END IF;

    EXECUTE v_sql
        USING clock_timestamp(), current_user, lower( TG_OP )::_flux.change_type, v_use_pkey, v_use_data;

    RETURN NULL;
END;
$$ language plpgsql;

-- Trigger function that handles 'UPDATE' events on _fluxed tables.
CREATE OR REPLACE FUNCTION trigger_update() RETURNS TRIGGER AS $$
DECLARE
    v_log_table          TEXT                    :=   TG_ARGV[0];
    v_modifier_type      _flux.column_modifier   :=   TG_ARGV[1];
    v_modifier_columns   TEXT[]                  :=   NULL;
    v_key_columns        TEXT[]                  :=   TG_ARGV[3];
    v_orig_new           hstore;
    v_orig_old           hstore;
    v_use_new            hstore;
    v_use_old            hstore;
    v_pkey_new           TEXT[];
    v_pkey_old           TEXT[];
    v_use_pkey           TEXT[];
    v_use_data           hstore;
    v_sql                TEXT;
BEGIN
    IF v_modifier_type <> 'all' THEN
        v_modifier_columns := TG_ARGV[2];
    END IF;

    v_sql := format(
        'INSERT INTO %I.%I (change_when, change_by, change_type, row_pkey, row_data) VALUES ($1, $2, $3, $4, $5)',
        TG_TABLE_SCHEMA,
        v_log_table
    );

    v_orig_new := hstore(NEW);
    v_orig_old := hstore(OLD);
    v_pkey_new := v_orig_new->v_key_columns;
    v_pkey_old := v_orig_old->v_key_columns;

    IF v_pkey_new <> v_pkey_old THEN
        raise exception 'Primary key change is not supported on change-logged tables. Change was from (%) to (%).', v_pkey_old, v_pkey_new;
    END IF;

    v_use_pkey := v_pkey_new;

    IF v_modifier_type = 'include' THEN
        v_use_new := slice(v_orig_new, v_modifier_columns);
        v_use_old := slice(v_orig_old, v_modifier_columns);
    ELSIF v_modifier_type = 'exclude' THEN
        v_use_new := delete(v_orig_new, v_modifier_columns);
        v_use_old := delete(v_orig_old, v_modifier_columns);
    ELSE
        v_use_new := v_orig_new;
        v_use_old := v_orig_old;
    END IF;

    v_use_data := v_use_old - v_use_new;
    IF v_use_data = ''::hstore THEN
        -- The difference in data is none, so we can return without logging change.
        RETURN NULL;
    END IF;

    EXECUTE v_sql
        USING clock_timestamp(), current_user, lower( TG_OP )::_flux.change_type, v_use_pkey, v_use_data;

    RETURN NULL;
END;
$$ language plpgsql;

-- Helper function that makes sure that there is metadata table in given schema.
-- If it doesn't exist - create it.
-- If it does - check if it's schema looks like proper metadata table for _flux.
CREATE OR REPLACE FUNCTION create_metadata_table( IN schema_name TEXT ) RETURNS void as $$
DECLARE
    p_schema_name  ALIAS FOR schema_name;
    v_sql          TEXT;
    v_meta_columns TEXT[];
    v_expected     TEXT[] = array[ 'clean_it', 'log_table', 'modifier_columns', 'modifier_type', 'pkey_columns', 'table_name' ];
BEGIN
    -- Get array with names of columns in potentially existing copy of the meta table.
    SELECT
        array_agg(a.attname ORDER BY a.attname) INTO v_meta_columns
    FROM
        pg_class c
        join pg_namespace n on c.relnamespace = n.oid
        join pg_attribute a on c.oid = a.attrelid
    WHERE
        n.nspname = p_schema_name AND
        c.relname = '_change_logged_tables' AND
        c.relkind = 'r' AND
        NOT a.attisdropped AND
        a.attnum > 0;

    IF v_meta_columns IS NOT NULL THEN
        IF v_meta_columns = v_expected THEN
            RETURN;
        END IF;
        raise exception 'Table % already exists in schema % but its columns look wrong. Columns it has: %, columns it should have: %',
            '_change_logged_tables',
            p_schema_name,
            v_meta_columns,
            v_expected;
    END if;

    v_sql := format( 'CREATE TABLE %I._change_logged_tables (
        table_name         TEXT                            NOT NULL,
        pkey_columns       TEXT[]                          NOT NULL,
        modifier_columns   TEXT[],
        modifier_type      _flux.column_modifier  NOT NULL,
        log_table          TEXT                            NOT NULL,
        clean_it           BOOL                            NOT NULL DEFAULT false,
        PRIMARY KEY        (table_name),
        UNIQUE             (log_table)
    )', p_schema_name);
    execute v_sql;

    v_sql := format( 'ALTER TABLE %I._change_logged_tables
        ADD CONSTRAINT columns_listed_for_modified_columnsets
            CHECK (
                ( modifier_type = %L AND modifier_columns IS NULL ) OR
                ( modifier_type <> %L AND modifier_columns IS NOT NULL AND modifier_columns <> %L::TEXT[] )
        )
        ',
        p_schema_name, 'all', 'all', '{}'
    );
    execute v_sql;

    RETURN;
END;
$$ language plpgsql;

-- Helper function that RETURNS array of column names of PRIMARY KEY in given TABLE.
-- Column names are ordered alphabetically.
CREATE OR REPLACE FUNCTION get_table_key_columns(
    IN    schema_name   TEXT,
    IN    table_name    TEXT,
    OUT   key_columns   TEXT[]
) RETURNS TEXT[] as $$
DECLARE
    p_schema_name   ALIAS     FOR   schema_name;
    p_table_name    ALIAS     FOR   table_name;
    v_key_columns   ALIAS     FOR   key_columns;
BEGIN
    SELECT
        array_agg(
            a.attname
            ORDER BY a.attname
        )
        INTO v_key_columns
    FROM
        pg_class c
        join pg_namespace n on c.relnamespace = n.oid
        join pg_index i on c.oid = i.indrelid
        join pg_attribute a on a.attnum = any( i.indkey::int2[] ) AND a.attrelid = c.oid
    WHERE
        n.nspname = p_schema_name AND
        c.relname = p_table_name AND
        c.relkind = 'r' AND
        i.indisprimary;
    RETURN;
END;
$$ language plpgsql;

-- Function that should be called to enable change logging on a table.
-- Usage:
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table' );
-- will enable logging of all columns in table_schema.table_name. Log of changes will go to table table_schema.log_table
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table', 'include', ARRAY['a', 'b', 'c'] );
-- will enable logging of only columns "a", "b", and "c" in table table_schema.table_name
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table', 'exclude', ARRAY['a', 'b', 'c'] );
-- will enable logging of all columns except "a", "b", and "c" in table table_schema.table_name
CREATE OR REPLACE FUNCTION enable_change_logging(
    IN   source_schema      TEXT,
    IN   source_table       TEXT,
    IN   log_table          TEXT,
    IN   modifier_type      column_modifier   DEFAULT   'all',
    IN   modifier_columns   TEXT[]            DEFAULT   NULL
) RETURNS void as $$
DECLARE
    p_source_schema      ALIAS     FOR   source_schema;
    p_source_table       ALIAS     FOR   source_table;
    p_log_table          ALIAS     FOR   log_table;
    p_modifier_type      ALIAS     FOR   modifier_type;
    p_modifier_columns   ALIAS     FOR   modifier_columns;
    v_source_table       RECORD;
    v_key_columns        TEXT[];
    v_sql                TEXT;
    v_temp               INT4;
BEGIN
    -- Sanity check params
    IF p_modifier_type = 'all' AND ( p_modifier_columns IS NOT NULL OR p_modifier_columns <> '{}'::TEXT[] ) THEN
        RAISE EXCEPTION 'Providing list of columns when modifier type is ''all'' is not allowed/sensible.';
    END IF;
    IF p_modifier_type <> 'all' AND ( p_modifier_columns IS NULL OR p_modifier_columns = '{}'::TEXT[] ) THEN
        RAISE EXCEPTION 'You have to provide list of columns when calling enable_change_logging with modifier %.', p_modifier_type;
    END IF;

    SELECT c.oid INTO v_temp
    FROM pg_class c JOIN pg_namespace n on c.relnamespace = n.oid
    WHERE n.nspname = p_source_schema AND c.relname = p_log_table AND c.relkind = 'r';
    IF found THEN
        raise exception 'Table %.% already exist. Cannot log changes there.', p_source_schema, p_log_table;
    END IF;

    -- Make sure we have metadata in given SCHEMA
    perform _flux.create_metadata_table( p_source_schema );

    v_key_columns := _flux.get_table_key_columns( p_source_schema, p_source_table );
    -- Make sure that the table does have PRIMARY KEY.
    IF v_key_columns IS NULL THEN
        raise exception 'There is no PRIMARY KEY on the TABLE %.% ?!', p_source_schema, p_source_table;
    END IF;

    -- At this moment, we have all the information we need, all looks sane, so we can create actual temporal logging "things"

    v_sql := format( 'CREATE TABLE %I.%I (
        change_when   timestamptz                  NOT NULL,
        change_by     TEXT                         NOT NULL,
        change_type   _flux.change_type   NOT NULL,
        row_pkey      TEXT[]                       NOT NULL,
        row_data      hstore,
        PRIMARY KEY   (row_pkey, change_when)
        )',
        p_source_schema,
        p_log_table
    );
    execute v_sql;

    v_sql := format(
        'INSERT INTO %I._change_logged_tables
            (table_name, pkey_columns, modifier_columns, modifier_type, log_table)
            VALUES ($1, $2, $3, $4, $5)',
        p_source_schema
    );
    EXECUTE v_sql USING p_source_table, v_key_columns, p_modifier_columns, p_modifier_type, p_log_table;

    v_sql := format(
        'CREATE TRIGGER change_logging_trigger_insert AFTER INSERT ON %I.%I FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_insert(%L, %L)',
        p_source_schema,
        p_source_table,
        p_log_table,
        v_key_columns
    );
    execute v_sql;
    v_sql := format(
        'CREATE TRIGGER change_logging_trigger_update AFTER UPDATE ON %I.%I FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_update(%L, %L, %L, %L)',
        p_source_schema,
        p_source_table,
        p_log_table,
        p_modifier_type,
        p_modifier_columns,
        v_key_columns
    );
    execute v_sql;
    v_sql := format(
        'CREATE TRIGGER change_logging_trigger_delete AFTER DELETE ON %I.%I FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_delete(%L, %L, %L, %L)',
        p_source_schema,
        p_source_table,
        p_log_table,
        p_modifier_type,
        p_modifier_columns,
        v_key_columns
    );
    execute v_sql;

    RETURN;
END;
$$ language plpgsql;

-- Function that should be called to disable change logging on a table.
-- Usage:
-- select _flux.disable_change_logging( 'table_schema', 'table_name' );
-- This function does *NOT* remove log tables, as this operation can take significant time, and it would keep lock on base table.
-- To remove the log tables, simply call _flux.cleanup() function afterwards.
CREATE OR REPLACE FUNCTION disable_change_logging(
    IN   source_schema      TEXT,
    IN   source_table       TEXT
) RETURNS VOID AS $$
DECLARE
    p_source_schema ALIAS FOR source_schema;
    p_source_table ALIAS FOR source_table;
    v_sql TEXT;
BEGIN
    v_sql := format(
        'DROP TRIGGER change_logging_trigger_insert ON %I.%I',
        p_source_schema,
        p_source_table
    );
    execute v_sql;
    v_sql := format(
        'DROP TRIGGER change_logging_trigger_update ON %I.%I',
        p_source_schema,
        p_source_table
    );
    execute v_sql;
    v_sql := format(
        'DROP TRIGGER change_logging_trigger_delete ON %I.%I',
        p_source_schema,
        p_source_table
    );
    execute v_sql;
    v_sql := format(
        'UPDATE %I._change_logged_tables SET clean_it = true WHERE table_name = $1',
        p_source_schema
    );
    execute v_sql USING p_source_table;
    RETURN;
END;
$$ language plpgsql;

-- Function that should be called to remove obsolete log tables
-- Usage:
-- select _flux.cleanup()
CREATE OR REPLACE FUNCTION cleanup() RETURNS VOID AS $$
DECLARE
    v_expected     TEXT[]    =   array[   'clean_it',   'log_table',   'modifier_columns',   'modifier_type',   'pkey_columns',   'table_name'   ];
    v_temp         RECORD;
    v_tables_sql   TEXT;
    v_table        RECORD;
    v_sql          TEXT;
BEGIN
    -- Get array with names of columns in potentially existing copy of the meta table.
    for v_temp IN
        SELECT
            n.nspname as table_schema,
            array_agg(a.attname::TEXT ORDER BY a.attname::TEXT) as table_columns
        FROM
            pg_class c
            join pg_namespace n on c.relnamespace = n.oid
            join pg_attribute a on c.oid = a.attrelid
        WHERE
            c.relname = '_change_logged_tables' AND
            c.relkind = 'r' AND
            NOT a.attisdropped AND
            a.attnum > 0
        GROUP BY n.nspname
        ORDER BY n.nspname
    LOOP
        CONTINUE WHEN v_temp.table_columns <> v_expected;
        v_tables_sql := format( 'with d as (DELETE FROM %I._change_logged_tables WHERE clean_it returning *) SELECT * FROM d', v_temp.table_schema );
        for v_table IN EXECUTE v_tables_sql LOOP
            RAISE WARNING 'Dropping old log table: %.%', v_temp.table_schema, v_table.log_table;
            v_sql := format('DROP TABLE %I.%I', v_temp.table_schema, v_table.log_table);
            execute v_sql;
        END loop;
    END loop;
    RETURN;
END;
$$ language plpgsql;

-- Returns row from given table, with given primary key, as it existed alter table specific time in the past.
-- Sample usage:
-- SELECT * FROM _flux.get_row_from_history( NULL::some_schema.some_table, 'id=>312123', '2018-02-14 07:00:00+00' );
CREATE OR REPLACE FUNCTION get_row_from_history(
    IN source_table ANYELEMENT,
    IN pkey_values hstore,
    IN restore_as_of timestamptz
) RETURNS SETOF ANYELEMENT as $$
DECLARE
    p_source_table       ALIAS  FOR source_table;
    p_source_pkey        ALIAS  FOR pkey_values;
    p_restore_as_of      ALIAS  FOR restore_as_of;
    v_metadata           RECORD;
    v_sql                TEXT;
    v_base_row_condition TEXT;
    v_current            HSTORE;
    v_temprec            RECORD;
    v_pkey               TEXT[];
    v_source             RECORD;
BEGIN
    -- Get information about table itself
    SELECT
        n.nspname as schema_name,
        c.relname as table_name
        INTO v_source
    FROM
        pg_type t
        join pg_class c on t.typrelid = c.oid
        join pg_namespace n on c.relnamespace = n.oid
    WHERE
        t.oid = pg_typeof( p_source_table );

    v_sql := format('SELECT * FROM %I._change_logged_tables WHERE NOT clean_it AND table_name = $1', v_source.schema_name);
    execute v_sql INTO v_metadata USING v_source.table_name;

    IF v_metadata IS NULL THEN
        raise exception 'Audit logging does not seem to be enabled for table %.', pg_typeof( p_source_table );
    END IF;

    v_pkey := p_source_pkey->v_metadata.pkey_columns;

    SELECT string_agg(format('%I=%L', k,v), ' AND ') INTO v_base_row_condition FROM each(p_source_pkey) as x(k,v);

    v_sql := format( 'SELECT hstore(x) FROM %I.%I x WHERE %s', v_source.schema_name, v_metadata.table_name, v_base_row_condition );
    execute v_sql INTO v_current;

    v_sql := format( 'SELECT * FROM %I.%I WHERE row_pkey = $1 AND change_when >= $2 ORDER BY change_when DESC', v_source.schema_name, v_metadata.log_table );
    for v_temprec IN EXECUTE v_sql USING v_pkey, p_restore_as_of LOOP
        IF v_temprec.change_type = 'delete' THEN
            v_current := v_temprec.row_data;
        ELSIF v_temprec.change_type = 'update' THEN
            v_current := v_current || v_temprec.row_data;
        ELSE
            v_current := NULL;
        END IF;
    END LOOP;

    IF v_current IS NOT NULL THEN
        RETURN next populate_record( p_source_table, v_current );
    END IF;
    RETURN;
END;
$$ language plpgsql;

-- Returns full row history, with all changes shown:
-- Sample usage:
-- SELECT * FROM _flux.get_row_history( 'some_schema', 'some_table', 'id=>312123' );
CREATE OR REPLACE FUNCTION get_row_history(
    IN    source_schema  TEXT,
    IN    source_table   TEXT,
    IN    pkey_value     hstore,
    OUT   valid_from     timestamptz,
    OUT   valid_to       timestamptz,
    OUT   row_data       hstore
) RETURNS SETOF record as $$
DECLARE
    p_source_schema  ALIAS   FOR   source_schema;
    p_source_table   ALIAS   FOR   source_table;
    p_pkey_value     ALIAS   FOR   pkey_value;
    v_valid_from     ALIAS   FOR   valid_from;
    v_valid_to       ALIAS   FOR   valid_to;
    v_row_data       ALIAS   FOR   row_data;

    v_metadata           RECORD;
    v_sql                TEXT;
    v_base_row_condition TEXT;
    v_temprec            RECORD;
    v_pkey               TEXT[];
    v_source             RECORD;
BEGIN
    v_valid_from := '-infinity';
    v_valid_to := 'infinity';

    -- Get information about table itself
    SELECT
        n.nspname as schema_name,
        c.relname as table_name
        INTO v_source
    FROM
        pg_class c
        join pg_namespace n on c.relnamespace = n.oid
    WHERE
        c.relname = p_source_table AND
        n.nspname = p_source_schema AND
        c.relkind = 'r';
    IF NOT FOUND THEN
        raise exception 'Looks like table %.% does not exist!', p_source_schema, p_source_table;
    END IF;

    v_sql := format('SELECT * FROM %I._change_logged_tables WHERE NOT clean_it AND table_name = $1', p_source_schema);
    execute v_sql INTO v_metadata USING p_source_table;

    IF v_metadata IS NULL THEN
        raise exception 'Audit logging does not seem to be enabled for table %.%.', p_source_schema, p_source_table;
    END IF;

    v_pkey := p_pkey_value->v_metadata.pkey_columns;

    SELECT string_agg(format('%I=%L', k,v), ' AND ') INTO v_base_row_condition FROM each(p_pkey_value) as x(k,v);

    v_sql := format( 'SELECT hstore(x) FROM %I.%I x WHERE %s', p_source_schema, p_source_table, v_base_row_condition );
    execute v_sql INTO v_row_data;

    v_sql := format( 'SELECT * FROM %I.%I WHERE row_pkey = $1 ORDER BY change_when DESC', p_source_schema, v_metadata.log_table );
    for v_temprec IN EXECUTE v_sql USING v_pkey LOOP
        IF v_row_data IS NOT NULL THEN
            v_valid_from := v_temprec.change_when;
            RETURN next;
        END IF;
        v_valid_from := '-infinity';
        v_valid_to := v_temprec.change_when;

        IF v_temprec.change_type = 'delete' THEN
            v_row_data := v_temprec.row_data;
        ELSIF v_temprec.change_type = 'update' THEN
            v_row_data := v_row_data || v_temprec.row_data;
        ELSE
            v_row_data := NULL;
        END IF;

    END LOOP;

    IF v_row_data IS NOT NULL THEN
        RETURN next;
    END IF;

    RETURN;
END;
$$ language plpgsql;

COMMIT;
