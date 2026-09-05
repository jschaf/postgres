#!/usr/bin/env python3
"""Pipeline a simple or extended command behind startup, before ReadyForQuery.

R1 parks this connection in authentication, resets past it, then releases it.
No libpq startup wait can conceal an accidentally dispatched first command.
"""
import argparse
import os
import socket
import struct
import sys

ap = argparse.ArgumentParser()
ap.add_argument('--dbname', required=True)
ap.add_argument('--protocol', choices=['simple', 'extended'], required=True)
ap.add_argument('--guc', action='append', default=[], help='startup GUC pair NAME=VALUE')
args = ap.parse_args()
pack = struct.pack

def message(kind, payload):
    return kind + pack('!I', len(payload) + 4) + payload

params = {'user': os.environ.get('PGUSER', 'postgres'), 'database': args.dbname,
          'options': os.environ.get('PGOPTIONS', ''),
          'application_name': 'memcow-startup-probe'}
for guc in args.guc:
    name, sep, value = guc.partition('=')
    if not sep or not name:
        ap.error('--guc requires NAME=VALUE')
    params[name] = value
payload = pack('!I', 196608) + b''.join(
    k.encode() + b'\0' + v.encode() + b'\0' for k, v in params.items()) + b'\0'
startup = pack('!I', len(payload) + 4) + payload
marker = b'r1-cmd-ran'
if args.protocol == 'simple':
    command = message(b'Q', b"SELECT 'r1-cmd-ran'\0")
else:
    command = message(b'P', b'\0SELECT $1::text\0' + pack('!H', 0))
    command += message(b'B', b'\0\0' + pack('!HHI', 0, 1, len(marker)) + marker + pack('!H', 0))
    command += message(b'E', b'\0' + pack('!I', 0)) + message(b'S', b'')

with socket.socket(socket.AF_UNIX) as conn:
    conn.settimeout(40)
    conn.connect(os.path.join(os.environ['PGHOST'], '.s.PGSQL.' + os.environ['PGPORT']))
    conn.sendall(startup + command)
    def read(n):
        data = b''
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                raise RuntimeError('server closed connection before command completed')
            data += chunk
        return data
    completed = False
    while True:
        kind = read(1)
        data = read(struct.unpack('!I', read(4))[0] - 4)
        if kind == b'E':
            fields = {x[:1]: x[1:].decode() for x in data.split(b'\0') if x}
            print(fields.get(b'S', 'ERROR') + ': ' + fields.get(b'M', ''))
            sys.exit(1)
        if kind == b'D':
            print(data.decode('utf-8', errors='replace'))
        if kind == b'C':
            completed = True
        if kind == b'Z' and completed:
            break
    conn.sendall(message(b'X', b''))
