# Load Flux to your system

1. You need to download code, for example using: `git clone https://github.com/benchub/flux.git`
2. In downloaded directory run `sudo make install`
3. In your database, run: `create extension hstore` (hstore is required by
   flux)
4. In your database, run: `create extension flux`

You should be set to actually use it now.

# Using Flux

Usage of Flux boils down to calling some functions.

Currently there are five separate functions that you might want to call:

## \_flux.enable\_change\_logging( schema, table\_name, archive\_table\_name, _log type_, _column list_ )

Calling this function like:

    select _flux.enable_change_logging( 'public', 'some_table', '_some_table_archive' )

will enable change logging on public.some\_table. Changes will be written to
public.\_some\_table\_archive table, which will be created (if it exists already,
it will be treated as exception)

From this moment on, every insert, update or delete to some\_table will save
data to \_some\_table\_archive, with some minimal information (enough to recreate
the row in most cases)

It is required that the table that you enable logging on has a primary key.

If (optional)
then 5th argument is treated as list of fields that will modify what is
considered part of row.

For example:

    ..., 'include', ARRAY[ 'id', 'some_column', 'other_column' ] )

Will log only values to these 3 columns. Also - changes to other columns, that
didn't change columns listed above - will **not** generate change log.

    ..., 'exclude', ARRAY[ 'created_on', 'updated_on' ] )

This will log all columns, except for created\_on and updated\_on. Also
- updates that change only one of these columns (and not modify any other)
will not get logged.

For every schema that you have at least one table that you track changes in,
there will be additional table created, named "\_flux\_tables".

So, when you enable logging on public.some\_table, public.\_flux\_tables will be
created.

This table stores certain meta-infomation:

- name of each table (in this schema) that has, or had, change logging enabled.
- array with names of columns that constitute primary key
- information whether all columns should be logged, or just named (include) or all except named (exclude)
- in case of include/exclude modes - array with list of column names
- what is the name of table with logged changes
- flag whether given table information should be cleaned (more on this in \_flux.cleanup() description)

## \_flux.disable\_change\_logging( schema, table\_name )

Removes triggers from given table, and marks the table in flux metadata as "to
be removed".

## \_flux.cleanup()

This function scans all \*.\_flux\_tables tables, and finds cases where table
had logging enabled, but later was disabled.

For each such case log table is dropped, and row from respective \_flux\_tables.

The removal is split into two separate functions because
disable\_change\_logging requires exclusive lock on base table (the one that
we had change logging enabled before) - this is so that it can drop triggers.

This lock prohibits concurrent access to the table - which could be
problematic in production environment.

Given that cleanup can be easily called at another time (for example, using
cronjob that runs it during time with less load on server) - all the expensive
work (dropping table) can be done without any kind of locking of normal,
app-used table.

## \_flux.get\_row\_from\_history( source\_table, pkey\_values, restore\_as\_of )

This returns row data for specific primary key values, as it existed at
specific time.

There are couple of caveats here - row is returned in form of current table
schema, so if you changed schema in the mean time (between "restore\_as\_of")
and now - it might return data with some columns missing.

Sample usage:

    select * from _flux.get_row_from_history( NULL::public.some_table, '"id" => 123', '2018-01-01' );
    select * from _flux.get_row_from_history( NULL::public.some_table, '"group_name"=>"g", "param_name"=>"p"', '2018-02-01 15:00:00' );

First argument should be NULL casted to type that is the same as table you're
interested in (this is hack that allows get\_row\_from\_history function to
return actual rows with multiple columns).

Second argument is hstore value that contains information about all columns
that are part of primary key.

Third column is timestamp of moment in time when the row was visible at.

Please check documentation on limitations to learn more about changing
datatypes, adding columns, or removing columns.

## \_flux.get\_row\_history( source\_schema, source\_table, pkey\_value )

This functions returns whole history of a given row in table.

Sample usage:

    select * from _flux.get_row_history( 'public', 'some_table', '"id" => 123');
    select * from _flux.get_row_history( 'public', 'some_table', '"group_name"=>"g", "param_name"=>"p"' );

Returned rows will have three columns:

- valid\_from - when this row, in this version, started being visible
- valid\_to - when this row, in this version, ended being visible
- row\_data - row content, as hstore

For example, call from \_flux.get\_row\_history can return values like:

           valid_from       |        valid_to        |                         row_data
    ------------------------+------------------------+-----------------------------------------------------------
     2011-03-01 01:00:00+01 | infinity               | "id"=>"1", "ts"=>"2015-01-01 01:00:00+01", "payload"=>"b"
     2011-02-01 01:00:00+01 | 2011-03-01 01:00:00+01 | "id"=>"1", "ts"=>"2015-01-01 01:00:00+01", "payload"=>"a"
    (2 rows)

This means that on 2011-02-01 a row was inserted, with some columns as shown in row_data.

This version of row was active till 2011-03-01, when it was modified, and we can see that payload has changed.

This newer version of row has valid\_to set to infinity, which means that the row, with these values, currently exists in base table.

If it was deleted, then newest record from hsitory would have some specfic value in valid\_to.
