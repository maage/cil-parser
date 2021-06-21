PROG := ./simple-cil-parser.py

exports = $(wildcard export/*.cil)
tests = $(wildcard test/*.cil)
split_lines = $(wildcard split_lines/*.te)

.PRECIOUS: tmp/%.cil

pp_split_lines = $(split_lines:split_lines/%.te=%.pp)
split_lines_log = $(split_lines:split_lines/%.te=tmp/%.log)
tmp_cils = $(split_lines:split_lines/%.te=tmp/%.cil)
exports += $(tmp_cils)
cil_sums = $(tmp_cils:%=%.tosum)

# phony targets

all: commit $(pp_split_lines) tmp/_cache dupes.txt status.txt

test: commit $(parsed_tests)

tmp:
	@mkdir -p tmp

commit: | tmp
commit:
	git add -u && git commit -m hop || :

tox: commit
	tox

parsimonious-install:
	pip3 install --upgrade --user parsimonious

parsimonious-stubgen:
	.tox/mypy/bin/stubgen -o . ~/.local/lib/python3.9/site-packages/parsimonious/*.py

myclean: clean
	rm -f -- $(parsed_tests) status.txt dupes.txt
	rm -rf split_lines UNKNOWN.egg-info .tox .mypy_cache

.PHONY: all test commit tox parsimonious-install parsimonious-stubgen myclean

# rules

tmp/_cache: | tmp
tmp/_cache: $(PROG) $(exports)
	@$(PROG) $(exports)
	@touch -- $@

tmp/%.cil: %.pp
	/usr/libexec/selinux/hll/pp < $< > $@.tmp && mv -- $@.tmp $@

%.tosum: %
	grep -v cil_gen_require $< | sort -u > $@.tmp && mv -- $@.tmp $@

tmp/dupes.txt: tmp/sums.txt
	awk '{print $$1}' tmp/sums.txt | sort | uniq -c | egrep -v ' 1 ' | awk '{print $$2}' > $@.tmp && mv -- $@.tmp $@

tmp/sums.txt: | tmp
tmp/sums.txt: $(cil_sums)
ifeq ($(cil_sums),)
	touch $@
else
	sha256sum $^ > $@.tmp && mv -- $@.tmp $@
endif

dupes.txt: tmp/dupes.txt tmp/sums.txt
	./generate_dupes.sh > $@.tmp && mv -- $@.tmp $@

tmp/%.log: tmp/%.cil tmp/_cache
	$(PROG) --from-all-known --from $< > $@.tmp && mv -- $@.tmp $@

status.txt: $(split_lines_log)
	./generate_status.sh $^ > $@.tmp && mv -- $@.tmp $@

# selinux

QUIET := n

include /usr/share/selinux/devel/Makefile

SEMODULE := $(SBINDIR)/semodule -v
