DROP function enable_change_logging(TEXT, TEXT, TEXT, column_modifier, TEXT[]);

-- Function that should be called to enable change logging on a table.
-- Usage:
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table' );
-- will enable logging of all columns in table_schema.table_name. Log of changes will go to table table_schema.log_table
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table', 'include', ARRAY['a', 'b', 'c'] );
-- will enable logging of only columns "a", "b", and "c" in table table_schema.table_name
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table', 'exclude', ARRAY['a', 'b', 'c'] );
-- will enable logging of all columns except "a", "b", and "c" in table table_schema.table_name
-- select _flux.enable_change_logging( 'table_schema', 'table_name', 'log_table', 'all', NULL, '3 months' );
-- will enable logging of all columns, and make retention policy: keep changes for 3 months.
CREATE OR REPLACE FUNCTION enable_change_logging(
    IN   source_schema      TEXT,
    IN   source_table       TEXT,
    IN   log_table          TEXT,
    IN   modifier_type      column_modifier   DEFAULT   'all',
    IN   modifier_columns   TEXT[]            DEFAULT   NULL,
    IN   retention          INTERVAL          DEFAULT   NULL
) RETURNS void as $$
DECLARE
    p_source_schema      ALIAS     FOR   source_schema;
    p_source_table       ALIAS     FOR   source_table;
    p_log_table          ALIAS     FOR   log_table;
    p_retention          ALIAS     FOR   retention;
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
        change_when   timestamptz         NOT NULL,
        change_by     TEXT                NOT NULL,
        change_type   _flux.change_type   NOT NULL,
        row_pkey      TEXT[]              NOT NULL,
        row_data      hstore,
        PRIMARY KEY   (row_pkey, change_when)
        )',
        p_source_schema,
        p_log_table
    );
    execute v_sql;

    v_sql := format(
        'INSERT INTO %I._flux_tables
            (table_name, pkey_columns, modifier_columns, modifier_type, log_table, retention)
            VALUES ($1, $2, $3, $4, $5, $6)',
        p_source_schema
    );
    EXECUTE v_sql USING p_source_table, v_key_columns, p_modifier_columns, p_modifier_type, p_log_table, p_retention;

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
$$ language plpgsql
SET search_path FROM current
;

-- Helper function that makes sure that there is metadata table in given schema.
-- If it doesn't exist - create it.
-- If it does - check if it's schema looks like proper metadata table for _flux.
CREATE OR REPLACE FUNCTION create_metadata_table( IN schema_name TEXT ) RETURNS void as $$
DECLARE
    p_schema_name  ALIAS FOR schema_name;
    v_sql          TEXT;
    v_meta_columns TEXT[];
    v_expected     TEXT[] = array[ 'clean_it', 'log_table', 'modifier_columns', 'modifier_type', 'pkey_columns', 'retention', 'table_name' ];
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
        c.relname = '_flux_tables' AND
        c.relkind = 'r' AND
        NOT a.attisdropped AND
        a.attnum > 0;

    IF v_meta_columns IS NOT NULL THEN
        IF v_meta_columns = v_expected THEN
            RETURN;
        END IF;
        raise exception 'Table % already exists in schema % but its columns look wrong. Columns it has: %, columns it should have: %',
            '_flux_tables',
            p_schema_name,
            v_meta_columns,
            v_expected;
    END if;

    v_sql := format( 'CREATE TABLE %I._flux_tables (
        table_name         TEXT                            NOT NULL,
        pkey_columns       TEXT[]                          NOT NULL,
        modifier_columns   TEXT[],
        modifier_type      _flux.column_modifier  NOT NULL,
        log_table          TEXT                            NOT NULL,
        clean_it           BOOL                            NOT NULL DEFAULT false,
        retention          INTERVAL,
        PRIMARY KEY        (table_name),
        UNIQUE             (log_table)
    )', p_schema_name);
    execute v_sql;

    v_sql := format( 'ALTER TABLE %I._flux_tables
        ADD CONSTRAINT columns_listed_for_modified_columnsets
            CHECK (
                ( modifier_type = %L AND modifier_columns IS NULL ) OR
                ( modifier_type <> %L AND modifier_columns IS NOT NULL AND modifier_columns <> %L::TEXT[] )
        )
        ',
        p_schema_name, 'all', 'all', '{}'
    );
    execute v_sql;

    PERFORM add_metadata_to_extension( p_schema_name );

    RETURN;
END;
$$ language plpgsql
SET search_path FROM current
;

-- Function that should be called to remove obsolete log tables
-- Usage:
-- select _flux.cleanup()
CREATE OR REPLACE FUNCTION cleanup() RETURNS VOID AS $$
DECLARE
    v_expected     TEXT[]    =   array[ 'clean_it', 'log_table', 'modifier_columns', 'modifier_type', 'pkey_columns', 'retention', 'table_name' ];
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
            c.relname = '_flux_tables' AND
            c.relkind = 'r' AND
            NOT a.attisdropped AND
            a.attnum > 0
        GROUP BY n.nspname
        ORDER BY n.nspname
    LOOP
        CONTINUE WHEN v_temp.table_columns <> v_expected;

        -- Drop old log tables
        v_tables_sql := format( 'with d as (DELETE FROM %I._flux_tables WHERE clean_it returning *) SELECT * FROM d', v_temp.table_schema );
        for v_table IN EXECUTE v_tables_sql LOOP
            v_sql := format('DROP TABLE %I.%I', v_temp.table_schema, v_table.log_table);
            execute v_sql;
        END loop;

        -- handle retention
        v_tables_sql := format('SELECT * FROM %I._flux_tables WHERE retention IS NOT NULL ORDER BY table_name', v_temp.table_schema);
        for v_table IN EXECUTE v_tables_sql LOOP
            v_sql := format('DELETE FROM %I.%I WHERE change_when < now() - $1::INTERVAL', v_temp.table_schema, v_table.log_table);
            execute v_sql USING v_table.retention;
        END loop;

    END loop;
    RETURN;
END;
$$ language plpgsql
SET search_path FROM current
;


-- One time add retention column to existing _flux_tables, on upgrade
DO $$
DECLARE
    v_expected TEXT[]  = array[ 'clean_it', 'log_table', 'modifier_columns', 'modifier_type', 'pkey_columns', 'table_name' ];
    v_temp     RECORD;
    v_sql      TEXT;
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
            c.relname = '_flux_tables' AND
            c.relkind = 'r' AND
            NOT a.attisdropped AND
            a.attnum > 0
        GROUP BY n.nspname
        ORDER BY n.nspname
    LOOP
        CONTINUE WHEN v_temp.table_columns <> v_expected;
        v_sql := format( 'ALTER TABLE %I._flux_tables ADD COLUMN retention INTERVAL', v_temp.table_schema );
        execute v_sql;
    END loop;
    RETURN;
END;
$$ language plpgsql;
