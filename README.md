<!--
SPDX-FileCopyrightText: 2021 Markus Linnala <markus.linnala@cybercom.com>

SPDX-License-Identifier: Apache-2.0
-->

# SELinux CIL parser

Parse CIL representation and then allow to find duplicate definitions.

SELinux allows duplicate TE rules and some other definitions, but not duplicate filecon and similar rules. Because refpolicy uses M4, it is really hard to see if your local rule is fixed in upstream policy or if it is implemented partially. This project implements tools to provide this information.

It only supports definitions used in Fedora selinux-policy rawhide branch with exceptions:
- attributes with logical expressions skipped

```
$ ./simple-cil-parser.py --help
usage: simple-cil-parser.py [-h]
                            [--type {allow,auditallow,dontaudit,neverallow,allowxperm,auditallowxperm,dontauditxperm,neverallowxperm} | --attr | --resolveattr]
                            [--source SOURCE] [--not-source NOT_SOURCE]
                            [--target TARGET] [--not-target NOT_TARGET]
                            [--class CLASS] [--perm PERM] [--reverse-source]
                            [--reverse-target] [--from FROM]
                            FILES [FILES ...]

Parse and search cil files

positional arguments:
  FILES

optional arguments:
  -h, --help            show this help message and exit
  --type {allow,auditallow,dontaudit,neverallow,allowxperm,auditallowxperm,dontauditxperm,neverallowxperm}
  --attr
  --resolveattr
  --source SOURCE
  --not-source NOT_SOURCE
  --target TARGET
  --not-target NOT_TARGET
  --class CLASS
  --perm PERM
  --reverse-source
  --reverse-target
  --from FROM
```

Parse CIL modules and write out JSON representation for faster usage later on.

Similar CLI as *sesearch* to allow to search rules. Differencies:
- only subset of what sesearch does implemented
- allow to resolve attributes
- allow to find duplicate rules
- shows what is defined where, but only once per module
- sesearch resolves self attributes and like and simple-cil-parser.py does not
- works only on exported cil files
- does not use system SELinux policy at all
- not even nearly as fast as *sesearch*

To find out how much of CIL module is defined in other modules you do it like:
```
$ ./simple-cil-parser.py --from foo.cil export/*.cil
```

*split\_lines.sh* allows to split TE file into submodules per line. This can then be used to find duplicate definitions.

Workflow:
```
$ ./split_te.sh -- your_module.te
$ rm -f export/your_module.*
$ make -j $(nproc)
$ ls -l *.txt
```

If there is anything in txt files, then you have duplicates.i
Entries in *dupes.txt* describe duplicate entries within *your_module.te*.
Entries in *status.txt* list log files that describe duplicate entries in exported modules and *your_module.te*.

There is two previous tries for the posterity:
- *is-regression-fixed.sh* kind of same as simple-cil-parser.py but implemented as shell script/sed
- *cil-parser.py* failed parser implementation
