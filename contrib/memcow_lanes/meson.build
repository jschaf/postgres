# Copyright (c) 2026, PostgreSQL Global Development Group

memcow_lanes_sources = files(
  'memcow_lanes.c',
)

if host_system == 'windows'
  memcow_lanes_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'memcow_lanes',
    '--FILEDESC', 'memcow_lanes - lane reset for the memcow storage manager',])
endif

memcow_lanes = shared_module('memcow_lanes',
  memcow_lanes_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += memcow_lanes

install_data(
  'memcow_lanes--1.0.sql',
  'memcow_lanes.control',
  kwargs: contrib_data_args,
)
