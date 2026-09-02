#!/usr/bin/env bash
#
# sessions.sh --- persistent psql sessions for the memcow harness.
#
# A retained pool backend is a connection that stays open ACROSS a lane
# reset; two slice cases and the reset soak need exactly that, and a plain
# `psql -c` cannot provide it.  A session here is a psql reading its input
# from a FIFO that the driver holds open on a fixed file descriptor, driven
# one statement at a time with sess_query, which appends a \echo marker and
# waits for it.  bash 3.2 compatible on purpose (macOS /bin/bash), hence the
# explicit fd numbers and the sequence counter kept in a file (a $(...)
# capture would lose a shell variable).
#
# Requires: $OUTPUTDIR, $SOCKDIR, $PORT, $MC_BINDIR, $DB (default database),
# all set by the sourcing script.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# --- persistent sessions ---------------------------------------------------

# sess_open NAME FD [DB] --- start a psql that reads its input from a FIFO
# held open on file descriptor FD, so it stays connected between commands.
sess_open()
{
	local name=$1 fd=$2 db=${3:-$DB}
	local dir="$OUTPUTDIR/sess-$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	mkfifo "$dir/in"
	PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t -d "$db" \
		-v ON_ERROR_STOP=0 -f "$dir/in" >"$dir/out" 2>&1 &
	echo $! >"$dir/pid"
	eval "exec $fd>\"$dir/in\""
	printf '0\n' >"$dir/seq"
}

# sess_send NAME FD SQL --- send without waiting (for a command that is
# expected to block).  Appends a marker the caller can sess_wait for.
sess_send()
{
	local name=$1 fd=$2 sql=$3 seq
	local seqf="$OUTPUTDIR/sess-$name/seq"
	seq=$(( $(cat "$seqf" 2>/dev/null || echo 0) + 1 ))
	printf '%s\n' "$seq" >"$seqf"
	# A statement that does not end in ';' would otherwise stay in psql's
	# query buffer while the \echo marker below runs at once (a meta-command
	# does not send the buffer), and the NEXT statement would be glued onto
	# it.  So the statement is terminated first; to psql a lone ';' is an
	# empty query, which prints nothing.
	# A session whose backend died (S14's straggler) has an exited psql at
	# the other end of the FIFO; the write then fails with EPIPE, which the
	# caller sees as a marker that never appears.  Not worth a message.
	eval "printf '%s\\n;\\n\\\\echo __MARK_%s_%s__\\n' \"\$sql\" \"$name\" \"\$seq\" >&$fd 2>/dev/null"
	printf '%s\n' "$seq"
}

# sess_wait NAME SEQ [TIMEOUT-SECONDS] --- wait for marker SEQ; rc 1 on timeout
sess_wait()
{
	local name=$1 seq=$2 timeout=${3:-30} i=0
	local out="$OUTPUTDIR/sess-$name/out"
	while ! grep -q "__MARK_${name}_${seq}__" "$out" 2>/dev/null; do
		i=$((i + 1))
		[ $i -lt $((timeout * 10)) ] || return 1
		sleep 0.1
	done
}

# sess_output NAME SEQ --- what the session printed for command SEQ
sess_output()
{
	local name=$1 seq=$2 prev=$(( $2 - 1 ))
	local out="$OUTPUTDIR/sess-$name/out"
	if [ "$prev" -eq 0 ]; then
		sed -n "1,/__MARK_${name}_${seq}__/p" "$out"
	else
		sed -n "/__MARK_${name}_${prev}__/,/__MARK_${name}_${seq}__/p" "$out"
	fi | grep -v '__MARK_'
}

# sess_query NAME FD SQL [TIMEOUT] --- send, wait, print the output
sess_query()
{
	local name=$1 fd=$2 sql=$3 timeout=${4:-30} seq
	seq=$(sess_send "$name" "$fd" "$sql")
	if ! sess_wait "$name" "$seq" "$timeout"; then
		printf 'SESSION TIMEOUT after %ss waiting for: %s\n' "$timeout" "$sql"
		return 1
	fi
	sess_output "$name" "$seq"
}

sess_close()	# sess_close NAME FD
{
	local name=$1 fd=$2 pid i=0
	local dir="$OUTPUTDIR/sess-$name"
	eval "exec $fd>&-"
	pid=$(cat "$dir/pid" 2>/dev/null)
	while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
		i=$((i + 1))
		if [ $i -gt 100 ]; then kill "$pid" 2>/dev/null; break; fi
		sleep 0.1
	done
	rm -f "$dir/in"
}

