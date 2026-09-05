# contrib/memcow/Makefile

MODULE_big = memcow
OBJS = memcow.o lanes.o $(WIN32RES)

EXTENSION = memcow
DATA = memcow--1.0.sql
PGFILEDESC = "memcow - lane reset for the memcow storage manager"

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/memcow
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
