Everything has its limits. So does Flux.

The limits stem from certain design choices that were made during development,
and removing them might be complicated.

Here goes description of the limits we currently know about:

# Dropping the flux extension doesn't clean up anything

It is argueably correct to not clean up log tables, but we should probably at
least remove the _flux schema, and possibly the flux metadata tables in each schmea
flux was used.

# Can't change table name while it's being flux'ed

This is true, to some extent. Specifically, if you'd do:

    alter table some_table rename to other_table;

Logging of changes would still work, but getting data from history wouldn't,
because metadata (in \_flux\_tables table) doesn't match reality.

If you're sure you want to change the table name without losing history,
simply update \_flux\_tables with new table name, like this:

    alter table some_table rename to other_table;
    update _flux_tables set table_name = 'other_table' where table_name = 'some_table';

# Can't change primary key values while table is flux'ed

Consider:

    create table z (id int4 primary key, x text);
    insert into z (id, x) values (1, 'a');
    update z set id = -10 where id = 1;

If you'd have enabled change logging on the table, it will fail, like this:

    update z set id = -10 where id = 1;
    ERROR:  Primary key change is not supported on change-logged tables. Change was from ({1}) to ({-10}).

This is because tracking primary key changes is tricky. We might get to it
at one point in time, but for version 1.0 it doesn't really matter, as there
are very few use-cases where update of primary key is really needed.

# Can't change primary key definition while table is flux'ed

Well, it stems from similar problem as above. Basically, to make flux as fast
as possible when dealing with app-generated traffic (insert/update/delete),
triggers are very simple, and they don't check table schema. They get all the
data passed to them as arguments.

You can see it in \\d table, like here:

    $ \d z
    ...
    Triggers:
        change_logging_trigger_delete AFTER DELETE ON z FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_delete('_flux_z_log', 'all', 'null', '{id}')
        change_logging_trigger_insert AFTER INSERT ON z FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_insert('_flux_z_log', '{id}')
        change_logging_trigger_update AFTER UPDATE ON z FOR EACH ROW EXECUTE PROCEDURE _flux.trigger_update('_flux_z_log', 'all', 'null', '{id}')

Thanks to this trigger functions don't have to select anything - they just do
some operations on given arguments and (sometimes) issue insert to specific
log table.

If you'd want to change primary key, simply disable change logging, run
cleanup function, change primary key, and re-enable change logging.

Running cleanup is necessary, as flux allows only one row in metadata table
per logged table. If you'd want to keep old changes, you can do it, instead of
running cleanup() just delete for from \_flux\_tables for specific table, and
when you'll re-enable change logging, make sure to provide new name for log
table.

For example:

    select _flux.disable_change_logging( 'public', 'z' );
    delete from _flux_tables  where table_name = 'z';
    alter table z drop constraint z_pkey ;
    alter table z add primary key (id, x);
    select _flux.enable_change_logging('public', 'z', '_flux_z2_log');

# If you truncate the base table, you lose newest version of all rows

So, to make adding logging to existing tables cheap, decision was made that we
will not copy _current state_ of table to log table.

Also - all triggers save diffs, and not full rows, to limit disk space usage
by change logging.

This means that if you insert a row into table - there is information stored
that a row was inserted, with given primary key, but its column values are not
stored (because they can be fetched from base table).

Similarly, when you update row, information about the change is stored, but in
"reverse diff" way.

For example if you'd do:

    insert into some_table (id, payload) values (1, 'a');
    update some_table set payload = 'b' where id = 1;

In history flux would write that at some point in time row was inserted (with
no information about column values. And then, at some point in time, the row
was modified. And the stored column value is "payload: 'a'" - that is *old*
value (because new, current one, is in base table).

This means that if you'd then `truncate some_table`, then you will lose
information about versions of the rows that were live at the time of truncate.

While we could add trigger on truncate and store all rows, it would make
truncate take long time, and this is not something that is acceptable.

# Changing datatypes might yield weird results

Let's consider following case:

    create table x (id serial primary key, payload int4);
    select _flux.enable_change_logging( 'public', 'x', '_x_log' );
    insert into x (payload) values (1);
    update x set payload = 2;
    alter table x alter column payload set data type int4[] using array[payload];
    update x set payload = '{1,2,3}';
    update x set payload = '{4,5,6}';

Now, let's see what flux knows about changes in the table:

    select * from _x_log order by change_when;
              change_when          | change_by | change_type | row_pkey |       row_data       
    -------------------------------+-----------+-------------+----------+----------------------
     2018-03-20 18:20:56.701313+01 | depesz    | insert      | {1}      | 
     2018-03-20 18:20:56.703165+01 | depesz    | update      | {1}      | "payload"=>"1"
     2018-03-20 18:22:50.864579+01 | depesz    | update      | {1}      | "payload"=>"{2}"
     2018-03-20 18:22:50.866682+01 | depesz    | update      | {1}      | "payload"=>"{1,2,3}"
    (4 rows)

And in here we see that:

1. we lost information about change of value from integer 2 to array of
   integers {2} - according to history, there never was value 2. This is
   because alter table set data type modified the value, but it didn't call
   update trigger (well, because it wasn't trigger)'
1. value of payload was integer, and then array of integers. Without type
   information.

If I'd try to get row from history, and it will be with payload as array, it
will work ok:

    select * from _flux.get_row_from_history( NULL::public.x, 'id=>1', '2018-03-20 18:22:50.865+01' );
     id | payload 
    ----+---------
      1 | {1,2,3}
    (1 row)

But if I'd try to get row from moment in time when there was scalar integer
value:

    select * from _flux.get_row_from_history( NULL::public.x, 'id=>1', '2018-03-20 18:20:56.702+01' );
    ERROR:  malformed array literal: "1"
    DETAIL:  Array value must start with "{" or dimension information.
    CONTEXT:  PL/pgSQL function _flux.get_row_from_history(anyelement,hstore,timestamp with time zone) line 52 at RETURN NEXT

This is because datatype extracted from history doesn't match current reality.

We still can get the row data, though, using full history viewing:


    select * from _flux.get_row_history( 'public', 'x', 'id=>1') where '2018-03-20 18:20:56.702+01' between valid_from and valid_to;
              valid_from           |           valid_to            |         row_data          
    -------------------------------+-------------------------------+---------------------------
     2018-03-20 18:20:56.701313+01 | 2018-03-20 18:20:56.703165+01 | "id"=>"1", "payload"=>"1"
    (1 row)

# Dropping colums removes data from get\_row\_from\_history output

Consider following case:

    create table x (id serial primary key, a int4, b int4);
    select _flux.enable_change_logging( 'public', 'x', '_x_log' );
    insert into x (a,b) values (1,2);
    update x set a=10, b=20;
    alter table x drop column b;

Afterwards log table contains:

    select * from _x_log;
              change_when          | change_by | change_type | row_pkey |      row_data      
    -------------------------------+-----------+-------------+----------+--------------------
     2018-03-20 18:50:20.429632+01 | depesz    | insert      | {1}      | 
     2018-03-20 18:50:22.43725+01  | depesz    | update      | {1}      | "a"=>"1", "b"=>"2"
    (2 rows)

Please note that we don't have any information that column b was ever set to
20 - this is, again, because flux doesn't store *current* values of columns,
just diffs.

What's more interesting is that if I'd check data when b was present:

    select * from _flux.get_row_from_history( NULL::x, 'id=>1', '2018-03-20 18:50:21');
     id | a 
    ----+---
      1 | 1
    (1 row)

we will be missing data for column b. This is because get\_row\_from\_history
functions returns recordset formatted as current table. If we'd like to see
column b at this time, we'd have to use get\_row\_history function as shown in
previous limitation description.
