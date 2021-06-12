#!/bin/bash

D=split_lines

grep -El '^# found:' tmp/*log > "$D"/found.txt
grep -El '^# no:' tmp/*.log > "$D"/no.txt
grep -El '^# some:' tmp/*.log > "$D"/some.txt
grep -Fvf "$D"/no.txt "$D"/found.txt | grep -Fvf "$D"/some.txt || :
