# 0.3 ( 2018-03-27 )

- Added retention policies to log tables
  Retention time is set on enable\_change\_logging using 6th argument, or you
  can set it directly in \_flux\_tables by updating _retention_ column.

- Added retention cleanup to _cleanup()_ function, so it now serves two
  purposes:

    - remove obsolete log tables

    - remove old log data (rows) from log tables

# 0.2 ( 2018-03-27 )

- Added \_flux\_tables to extension, so on DROP EXTENSION flux it's metadata
  tables will get dropped too. Log tables are not dropped as they might be
  useful to user.

# 0.1 ( 2018-03-20 )

- Initial version. Works, with tests.
