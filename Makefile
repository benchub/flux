EXTENSION = flux
DATA = flux--0.1.sql flux--0.1--0.2.sql flux--0.2.sql
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

