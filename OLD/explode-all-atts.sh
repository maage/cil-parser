#!/bin/bash

# SPDX-FileCopyrightText: 2021 Markus Linnala <markus.linnala@cybercom.com>
#
# SPDX-License-Identifier: Apache-2.0

if [ ! -f all-attrs ]; then
	./is-regression-fixed.sh --attr |sed 's/.*[(]typeattributeset //;s/ .*//'|sort -u > all-attrs
fi

for a in $(<all-attrs); do
	if [ ! -f attr-"$a" ]; then
		./is-regression-fixed.sh --attr --source "$a" | sed -r 's/.*[(]typeattributeset [^ ]+ //;s/[() ]/\n/g;/./!d' | sort -u > attr-"$a"
	fi
done
