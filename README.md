Flux is a some code to track changes on a table and see what happened when.

To test it, do:

# create some database (create database testdb);
# load create.sql to database testdb: psql -d testdb -qAtX -f create.sql
# load pgtap.sql to database testdb: psql -d testdb -qAtX -f pgtap.sql
# run pg_prove: pg_prove -d testdb --recurse tests/
