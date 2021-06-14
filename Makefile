PROG := ./simple-cil-parser.py

exports = $(wildcard export/*.cil)
tests = $(wildcard test/*.cil)
pps = $(wildcard *.pp)
split_lines = $(wildcard split_lines/*.te)
tmp_cils = $(wildcard tmp/*.cil)
exports += $(tmp_cils)

parsed_exports = $(exports:%.cil=%.cil.json)
parsed_tests = $(tests:%.cil=%.cil.json)
new_tests = $(pps:%.pp=tmp/%.cil)
tests += $(new_tests)

.PRECIOUS: tmp/%.cil

split_lines_log = $(split_lines:split_lines/%.te=tmp/%.log)
cil_sums = $(tmp_cils:%=%.tosum)

# phony targets

all: commit test myexport
	# make this again as it can generate files
	$(MAKE) test myexport
	$(MAKE) status

test: commit $(parsed_tests)
myexport: commit $(parsed_exports)

commit:
	git add -u && git commit -m hop || :
	@mkdir -p tmp

tox: commit
	tox

parsimonious-install:
	pip3 install --upgrade --user parsimonious

parsimonious-stubgen:
	.tox/mypy/bin/stubgen -o . ~/.local/lib/python3.9/site-packages/parsimonious/*.py

status: status.txt dupes.txt

myclean: clean
	rm -f -- $(parsed_tests) $(parsed_exports) status.txt dupes.txt
	rm -rf split_lines UNKNOWN.egg-info .tox .mypy_cache

.PHONY: all test myexport commit tox parsimonious-install parsimonious-stubgen status myclean

# rules

%.cil.json: %.cil
	$(PROG) $<

tmp/%.cil: %.pp
	/usr/libexec/selinux/hll/pp < $< > $@

%.tosum: %
	grep -v cil_gen_require $< | sort -u > $@.tmp && mv $@.tmp $@

tmp/dupes.txt: $(cil_sums)
	sha256sum $^ | awk '{print $1}' | sort | uniq -c | egrep -v ' 1 ' | awk '{print $2}' > $@.tmp && mv $@.tmp $@

tmp/sums.txt: $(cil_sums)
	sha256sum $^ > $@.tmp && mv $@.tmp $@

dupes.txt: tmp/dupes.txt tmp/sums.txt
	./generate_dupes.sh > $@.tmp && mv $@.tmp $@

tmp/%.log: tmp/%.cil $(exports)
	./simple-cil-parser.py --from $^ > $@.tmp && mv $@.tmp $@

status.txt: $(split_lines_log)
	./generate_status.sh $^ > $@.tmp && mv $@.tmp $@

# selinux

QUIET := n

include /usr/share/selinux/devel/Makefile

SEMODULE := $(SBINDIR)/semodule -v
