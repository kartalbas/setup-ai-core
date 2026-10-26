#!/usr/bin/env bash
# The stand-ins of every test that plants a config.env the process cannot read. Sourced; not run.

# make_unreadable <file>: the file stays and this process can no longer read it. A process that ignores file modes,
# such as root, reads it still: the plant then says so and fails, because a check that cannot plant the defect
# cannot go red either.
make_unreadable() {
  chmod 000 "$1"
  if { : < "$1"; } 2>/dev/null; then
    echo "FAIL: $1 is still readable after chmod 000; run this test as a user that file modes bind" >&2
    return 1
  fi
}

# harness_copy <harness root> <target folder>: the files a command of the harness runs from, in a folder a test may plant a defect in
harness_copy() {
  mkdir -p "$2"
  tar -C "$1" --exclude=node_modules --exclude=.git -cf - bin lib templates rules skills skeleton auto-mode.tsv VERSION | tar -C "$2" -xf -
}

# old_reader_copy <harness root> <target folder>: a copy of the harness whose config reader gives the default for a
# file it cannot read, as it did before; every check of an unreadable config.env must go red on it
old_reader_copy() {
  harness_copy "$1" "$2"
  sed -i.bak '/exists but cannot be read; fix its permissions/d' "$2/lib/common.sh"
  rm -f "$2/lib/common.sh.bak"
  if cmp -s "$1/lib/common.sh" "$2/lib/common.sh"; then
    echo "FAIL: the copy with the old reader equals $1/lib/common.sh" >&2
    return 1
  fi
}
