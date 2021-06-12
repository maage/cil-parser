PROG := ./simple-cil-parser.py

exports = $(wildcard export/*.cil)
tests = $(wildcard test/*.cil)
pps = $(wildcard *.pp)
local_lines = $(wildcard local_lines/*.te)

parsed_exports = $(exports:%.cil=%.cil.json)
parsed_tests = $(tests:%.cil=%.cil.json)
new_tests = $(pps:%.pp=tmp/%.cil)
tests += $(new_tests)

local_lines_log = $(local_lines:local_lines/%.te=tmp/%.log)

all: commit test myexport lines
test: commit $(parsed_tests)
myexport: commit $(parsed_exports)
tox: commit
	tox

parse: | commit
parse: $(exports)
	$(PROG) $^

commit:
	git add -u && git commit -m hop || :
	@mkdir -p tmp

%.cil.json: %.cil
	$(PROG) $<

tmp/%.cil: %.pp
	/usr/libexec/selinux/hll/pp < $< > $@

$(parsed_exports): %.json: %
$(parsed_tests): %.json: %

parsimonious:
	pip3 install --upgrade --user parsimonious
	.tox/mypy/bin/stubgen -o . ~/.local/lib/python3.9/site-packages/parsimonious/*.py

lines: commit status_locals.report.txt

local_lines_log: $(local_lines_log)

local_lines:
	mkdir -p local_lines

#status_locals.report.txt: local_lines
#	./local_lines.sh
#	$(MAKE) local_lines_log
#	./status_locals.sh > $@.tmp && mv $@.tmp $@

tmp/%.log: tmp/%.cil ./simple-cil-parser.py $(parser_exports)
	./simple-cil-parser.py --from $< export/*.cil > $@.tmp && mv $@.tmp $@

myclean: clean
	rm -f -- $(parsed_tests) $(parsed_exports) status_locals.report.txt
	rm -rf local_lines UNKNOWN.egg-info .tox .mypy_cache

.PHONY: all test myexport commit myclean tox parsimonious lines local_lines_log

QUIET := n

include /usr/share/selinux/devel/Makefile

SEMODULE := $(SBINDIR)/semodule -v
