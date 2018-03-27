-- function to add created metadata TABLE to flux extension, so it will get dropped on DROP EXTENSION
-- This needs security definer to modify the extension, so it's in separate function, though the only
-- sensible usecase for it, IS to be called from create_metadata_table function.
CREATE OR REPLACE FUNCTION add_metadata_to_extension( IN schema_name TEXT ) RETURNS void as $$
DECLARE
    p_schema_name  ALIAS FOR schema_name;
    v_sql          TEXT;
BEGIN
    v_sql := format( 'ALTER EXTENSION flux ADD TABLE %I._flux_tables', p_schema_name );
    execute v_sql;
    RETURN;
END;
$$ language plpgsql
security definer
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

-- One time add existing _flux_tables to flux extension, on upgrade
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
        v_sql := format( 'ALTER EXTENSION flux ADD TABLE %I._flux_tables', v_temp.table_schema );
        execute v_sql;
    END loop;
    RETURN;
END;
$$ language plpgsql;
