# SPDX-FileCopyrightText: 2021 Markus Linnala <markus.linnala@cybercom.com>
#
# SPDX-License-Identifier: Apache-2.0

PROG := ./simple-cil-parser.py

DESTDIR ?=

exports = $(wildcard export/*.cil)
tests = $(wildcard test/*.cil)
split_lines = $(wildcard sl/*.te)

.PRECIOUS: tmp/%.cil

pp_split_lines = $(split_lines:sl/%.te=%.pp)
split_lines_log = $(split_lines:sl/%.te=tmp/%.log)
tmp_cils = $(split_lines:sl/%.te=tmp/%.cil)
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
	.tox/mypy/bin/stubgen -o . ~/.local/lib/python3.11/site-packages/parsimonious/*.py

myclean: clean
	rm -f -- $(parsed_tests) status.txt dupes.txt
	rm -rf sl UNKNOWN.egg-info .tox .mypy_cache

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
	awk '{if(d[$$1]++==1){print$$1}}' $< > $@.tmp && mv -- $@.tmp $@

# Make fails if there is too many args for a command
define multi_arg_command =
	                                            $(1) $(wordlist     1, 1000,$(3)) >  $(2).tmp
	if [ "$(wordlist  1001, 2000,$(3))" ]; then $(1) $(wordlist  1001, 2000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  2001, 3000,$(3))" ]; then $(1) $(wordlist  2001, 3000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  3001, 4000,$(3))" ]; then $(1) $(wordlist  3001, 4000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  4001, 5000,$(3))" ]; then $(1) $(wordlist  4001, 5000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  5001, 6000,$(3))" ]; then $(1) $(wordlist  5001, 6000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  6001, 7000,$(3))" ]; then $(1) $(wordlist  6001, 7000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  7001, 8000,$(3))" ]; then $(1) $(wordlist  7001, 8000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  8001, 9000,$(3))" ]; then $(1) $(wordlist  8001, 9000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist  9001,10000,$(3))" ]; then $(1) $(wordlist  9001,10000,$(3)) >> $(2).tmp; fi
	if [ "$(wordlist 10001,11000,$(3))" ]; then exit 1; fi
	mv -- $(2).tmp $(2)
endef

tmp/sums.txt: | tmp
tmp/sums.txt: $(cil_sums)
ifeq ($(cil_sums),)
	touch $@
else
	$(call multi_arg_command,sha256sum,$@,$^)
endif

dupes.txt: tmp/dupes.txt tmp/sums.txt
	./generate_dupes.sh > $@.tmp && mv -- $@.tmp $@

tmp/%.log: tmp/%.cil tmp/_cache
	$(PROG) --from-all-known --from $< > $@.tmp && mv -- $@.tmp $@

status.txt: $(split_lines_log)
	$(call multi_arg_command,./generate_status.sh,$@,$^)

# selinux

QUIET := n

include $(DESTDIR)/usr/share/selinux/devel/Makefile

SEMODULE := $(SBINDIR)/semodule -v
