PROG := ./simple-cil-parser.py

exports = $(wildcard export/*.cil)
tests = $(wildcard test/*.cil)
pps = $(wildcard *.pp)
split_lines = $(wildcard split_lines/*.te)
tmp_cils = $(wildcard tmp/*.cil)

parsed_exports = $(exports:%.cil=%.cil.json)
parsed_tests = $(tests:%.cil=%.cil.json)
new_tests = $(pps:%.pp=tmp/%.cil)
tests += $(new_tests)

split_lines_log = $(split_lines:split_lines/%.te=tmp/%.log)
cil_sums = $(tmp_cils:%=%.tosum)

all: commit test myexport
	# make this again as it can generate files
	$(MAKE) test myexport
	$(MAKE) status

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

%.tosum: %
	grep -v cil_gen_require $< | sort -u > $@.tmp && mv $@.tmp $@

$(parsed_exports): %.json: %
$(parsed_tests): %.json: %

parsimonious:
	pip3 install --upgrade --user parsimonious
	.tox/mypy/bin/stubgen -o . ~/.local/lib/python3.9/site-packages/parsimonious/*.py

lines: commit split_lines
status: status.txt dupes.txt

split_lines:
	mkdir -p split_lines

tmp/dupes.txt: $(cil_sums)
	sha256sum $(cil_sums) | awk '{print $1}' | sort | uniq -c | egrep -v ' 1 ' | awk '{print $2}' > $@.tmp && mv $@.tmp $@

tmp/sums.txt: $(cil_sums)
	sha256sum $(cil_sums) > $@.tmp && mv $@.tmp $@

status.txt: $(split_lines_log)
	./generate_status.sh > $@.tmp && mv $@.tmp $@

dupes.txt: tmp/dupes.txt tmp/sums.txt
	./generate_dupes.sh > $@.tmp && mv $@.tmp $@

tmp/%.log: tmp/%.cil ./simple-cil-parser.py $(parser_exports)
	./simple-cil-parser.py --from $< export/*.cil > $@.tmp && mv $@.tmp $@

myclean: clean
	rm -f -- $(parsed_tests) $(parsed_exports) status.txt dupes.txt
	rm -rf split_lines UNKNOWN.egg-info .tox .mypy_cache

.PHONY: all test myexport commit myclean tox parsimonious lines split_lines_log status

QUIET := n

include /usr/share/selinux/devel/Makefile

SEMODULE := $(SBINDIR)/semodule -v
