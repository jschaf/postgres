# contrib/memcow_lanes/Makefile

MODULES = memcow_lanes

EXTENSION = memcow_lanes
DATA = memcow_lanes--1.0.sql
PGFILEDESC = "memcow_lanes - lane reset for the memcow storage manager"

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/memcow_lanes
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
