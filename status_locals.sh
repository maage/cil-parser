#!/bin/bash

egrep -l '^# found:' tmp/*log > local_lines/found.txt
egrep -l '^# no:' tmp/*.log > local_lines/no.txt
egrep -l '^# some:' tmp/*.log > local_lines/some.txt
fgrep -vf local_lines/no.txt local_lines/found.txt|fgrep -vf local_lines/some.txt || :
