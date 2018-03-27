EXTENSION = flux
DATA = flux--0.1--0.2.sql flux--0.2--0.3.sql flux--0.3.sql
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

