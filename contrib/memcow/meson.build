# Copyright (c) 2026, PostgreSQL Global Development Group

memcow_sources = files(
  'memcow.c',
  'lanes.c',
)

if host_system == 'windows'
  memcow_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'memcow',
    '--FILEDESC', 'memcow - lane reset for the memcow storage manager',])
endif

memcow = shared_module('memcow',
  memcow_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += memcow

install_data(
  'memcow--1.0.sql',
  'memcow.control',
  kwargs: contrib_data_args,
)
