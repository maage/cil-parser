#!/usr/bin/python3

import argparse
from collections import defaultdict
from dataclasses import (
    dataclass,
    field,
)
from enum import (
    Enum,
    auto,
)

# import json
import os

import random
import sqlite3
import string

# import sys

from typing import (
    # cast,
    Any,
    # Callable,
    # Collection,
    # Counter,
    Dict,
    DefaultDict,
    # Generator,
    Iterator,
    List,
    # Mapping,
    # NewType,
    Optional,
    # Sequence,
    Set,
    # TextIO,
    Tuple,
    # TypeVar,
    # TYPE_CHECKING,
    Union,
)

import parsimonious
from parsimonious.grammar import Grammar
from parsimonious.nodes import Node


ParsedCil = List[List[Union[str, List[Any]]]]


grammar = Grammar(
    r"""
    exprs = s_expr+
    s_expr = lpar items* rpar
    items = item _
    item = s_expr / literal

    literal = quoted_string / symbol
    quoted_string = ~'"[^\"]*"'
    # https://github.com/SELinuxProject/cil/wiki#basic-token-types
    # has also: *$%@+!.
    # and is missing / or something is bad with description of characters
    # / is used in paths: see base-module genfscon
    symbol = ~r"[-/\w]+"

    _ = ( ~r"\s+" / ~r";[^\r\n]+" )*
    lpar = _ "(" _
    rpar = _ ")" _
    """
)


class CilParser(parsimonious.NodeVisitor):
    def visit_s_expr(self, node: Node, visited_children: List[Any]) -> List[Any]:
        # Go into items 2nd in definition (index 1) and extend to not to
        # create new level here needlessly.
        v = []
        for c in visited_children[1]:
            v.extend(c)
        return v

    def visit_item(self, node: Node, visited_children: List[List[Any]]) -> List[Any]:
        # Only one child possible, no new level.
        return visited_children[0]

    def visit_literal(self, node: Node, visited_children: Any) -> str:
        # No resolution, just use text as is.
        # quoted strings start / end "
        # others are symbols
        text: str = node.children[0].text
        return text

    def visit_lpar(self, node: Node, visited_children: Any) -> None:
        return None

    def visit_rpar(self, node: Node, visited_children: Any) -> None:
        return None

    def visit__(self, node: Node, visited_children: Any) -> None:
        return None

    def generic_visit(
        self, node: Node, visited_children: Optional[List[Node]]
    ) -> Union[List[Node], Node]:
        # Drop _, (, )
        v = []
        if visited_children:
            for c in visited_children:
                if c is not None:
                    v.append(c)
            return v
        return node


class Quad(Enum):
    FALSE = auto()
    PARTIAL = auto()
    TRUE = auto()
    MORE = auto()


QuadType = Union[Quad, bool]


# type enforcement rule
@dataclass
class TERule:
    file: str
    string: str
    type: str
    source: str
    target: str
    klass: str
    perms: list[str] = field(default_factory=list)

    def sqldict(self) -> Dict[str, str]:
        return {
            'file': self.file,
            'string': self.string,
            'type': self.type,
            'source': self.source,
            'target': self.target,
            'class': self.klass,
            'perms': ' '.join(self.perms),
        }


# type attribute set
@dataclass
class TASet:
    file: str
    string: str
    type: str
    attrs: set[str] = field(default_factory=set)
    is_logical: bool = False

    def sqldict(self) -> Dict[str, Union[str, bool]]:
        return {
            'file': self.file,
            'string': self.string,
            'type': self.type,
            'attrs': ' '.join(self.attrs),
            'is_logical': self.is_logical,
        }


@dataclass
class Typetransition:
    file: str
    string: str
    subject: str
    source: str
    klass: str
    target: str
    filename: Optional[str] = None

    def sqldict(self) -> Dict[str, Optional[str]]:
        return {
            'file': self.file,
            'string': self.string,
            'subject': self.subject,
            'source': self.source,
            'class': self.klass,
            'target': self.target,
            'filename': self.filename,
        }


cilp = CilParser()


type_enforcement_rule_types = [
    'allow',
    'auditallow',
    'dontaudit',
    'neverallow',
    'allowxperm',
    'auditallowxperm',
    'dontauditxperm',
    'neverallowxperm',
]


class CilSearcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.update_args()
        self.tasets: DefaultDict[str, List[TASet]] = defaultdict(list)
        self.reverse_tasets: DefaultDict[str, List[TASet]] = defaultdict(list)
        self.typetransitions: List[Typetransition] = []
        self.cil_from: Optional[ParsedCil] = None

    def update_args(self) -> None:
        self.oargs = vars(self.args)
        self.vargs: DefaultDict[str, Set[str]] = defaultdict(set)
        for key in ('perms',):
            if key not in self.oargs:
                self.oargs[key] = None
                continue
            if self.oargs[key] is None:
                continue
            if isinstance(self.oargs[key], str):
                self.vargs[key].add(self.oargs[key])
            else:
                self.vargs[key].update(self.oargs[key])
        for key in ('subject', 'source', 'target', 'not_source', 'not_target'):
            if key not in self.oargs:
                self.oargs[key] = None
                continue
            if self.oargs[key] is None:
                continue
            vals = set()
            if isinstance(self.oargs[key], str):
                vals.add(self.oargs[key])
            else:
                vals.update(self.oargs[key])
            self.vargs[key].update(vals)
            for val in vals:
                if val in self.reverse_tasets:
                    for r in self.reverse_tasets[val]:
                        self.vargs[key].add(r.type)

    @staticmethod
    def get_typeattributeset(
        e_attr: str, e_set: List[str], val: str, reverse: bool
    ) -> List[str]:
        if reverse and val == e_attr:
            return e_set
        if val in e_set:
            return [e_attr]
        return []

    def setup_cache(self) -> None:
        con = sqlite3.connect('export/cache.db', timeout=3600)
        # con.enable_callback_tracebacks(print)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute('PRAGMA foreign_keys')

        cur.execute('BEGIN EXCLUSIVE TRANSACTION')

        cur.execute(
            '''CREATE TABLE IF NOT EXISTS files
            ( file TEXT PRIMARY KEY
            , mtime_us INTEGER NOT NULL
            )'''
        )
        cur.execute(
            '''CREATE TABLE IF NOT EXISTS te_rules
            ( id INTEGER PRIMARY KEY AUTOINCREMENT
            , file TEXT
            , string TEXT NOT NULL
            , type TEXT NOT NULL
            , source TEXT NOT NULL
            , target TEXT NOT NULL
            , class TEXT NOT NULL
            , perms TEXT NOT NULL
            , FOREIGN KEY(file) REFERENCES files(file)
            )'''
        )
        cur.execute(
            '''CREATE TABLE IF NOT EXISTS typeattributes
            ( id INTEGER PRIMARY KEY AUTOINCREMENT
            , file TEXT
            , string TEXT NOT NULL
            , type TEXT NOT NULL
            , attrs TEXT NOT NULL
            , is_logical INTEGER DEFAULT (0)
            , FOREIGN KEY(file) REFERENCES files(file)
            )'''
        )
        cur.execute(
            '''CREATE TABLE IF NOT EXISTS typetransitions
            ( id INTEGER PRIMARY KEY AUTOINCREMENT
            , file TEXT
            , string TEXT NOT NULL
            , subject TEXT NOT NULL
            , source TEXT NOT NULL
            , class TEXT NOT NULL
            , target TEXT NOT NULL
            , filename TEXT
            , FOREIGN KEY(file) REFERENCES files(file)
            )'''
        )

        con.commit()
        self.cur = cur
        self.con = con

    def refresh_cache(self) -> None:
        if self.args.from_all_known:
            return

        cur = self.cur

        cur.execute('BEGIN EXCLUSIVE TRANSACTION')

        files_no_need_to_update = set()
        for file1 in self.args.files:
            if os.path.exists(file1):
                mtime_us = int(os.path.getmtime(file1) * 1000000)
                cur.execute(
                    'SELECT file FROM files WHERE file=:file AND mtime_us == :mtime_us',
                    {'file': file1, 'mtime_us': mtime_us},
                )
                for res in cur.fetchall():
                    files_no_need_to_update.add(res[0])
        files_to_update = set(self.args.files) - files_no_need_to_update
        # print(f'# files_to_update: {files_to_update}')
        for idx, file1 in enumerate(files_to_update):
            print(f'# {idx+1}/{len(files_to_update)} {file1}')
            with open(file1, 'r') as fd:
                tree = grammar.parse(fd.read())
                mtime_us = int(os.path.getmtime(file1) * 1000000)
                queue = cilp.visit(tree)
                rules = self.handle_file(queue)
                cur.execute(
                    '''
                    DELETE FROM te_rules
                    WHERE file=:file
                    ''',
                    {'file': file1},
                )
                cur.execute(
                    '''
                    DELETE FROM typeattributes
                    WHERE file=:file
                    ''',
                    {'file': file1},
                )
                cur.execute(
                    '''
                    DELETE FROM typetransitions
                    WHERE file=:file
                    ''',
                    {'file': file1},
                )

                te_rules = []
                typeattributes = []
                typetransitions = []
                for e in rules:
                    if e[0] in type_enforcement_rule_types:
                        te = self.create_terule(e, file1)
                        te_rules.append(te)
                    elif e[0] == 'typeattributeset':
                        ta = self.create_taset(e, file1)
                        typeattributes.append(ta)
                    elif e[0] == 'typetransition':
                        tt = self.create_typetransition(e, file1)
                        typetransitions.append(tt)

                def gen_te_rules() -> Iterator[Any]:
                    for r in te_rules:
                        yield r.sqldict()

                cur.executemany(
                    '''
                    INSERT INTO te_rules
                          ( file,  string,  type,  source,  target,  class,  perms)
                    VALUES(:file, :string, :type, :source, :target, :class, :perms)
                    ''',
                    gen_te_rules(),
                )

                def gen_typeattributes() -> Iterator[Any]:
                    for r in typeattributes:
                        yield r.sqldict()

                cur.executemany(
                    '''
                    INSERT INTO typeattributes
                          ( file,  string,  type,  attrs,  is_logical)
                    VALUES(:file, :string, :type, :attrs, :is_logical)
                    ''',
                    gen_typeattributes(),
                )

                def gen_typetransitions() -> Iterator[Any]:
                    for r in typetransitions:
                        yield r.sqldict()

                cur.executemany(
                    '''
                    INSERT INTO typetransitions
                          ( file,  string,  subject,  source,  class,  target,  filename)
                    VALUES(:file, :string, :subject, :source, :class, :target, :filename)
                    ''',
                    gen_typetransitions(),
                )

                cur.execute(
                    '''
                    REPLACE INTO files
                           ( file,  mtime_us)
                    VALUES (:file, :mtime_us)
                    ''',
                    {'file': file1, 'mtime_us': mtime_us},
                )
        self.con.commit()

    def load(self) -> None:
        self.setup_cache()
        self.refresh_cache()

        from_file = self.oargs['from']
        if from_file is not None:
            print(f'# {1}/{1} {from_file}')
            tree = grammar.parse(from_file.read())
            cil_from = cilp.visit(tree)
            self.cil_from = self.handle_file(cil_from)

    @staticmethod
    def handle_file(queue: List[Any]) -> ParsedCil:
        seen: set[str] = set()
        result: ParsedCil = []

        # First recurse and filter unique only
        # Also collect attrs data
        while queue:
            e = queue.pop(0)
            if e[0] == 'optional':
                queue.extend(e[2:])
                continue
            if e[0] == 'booleanif':
                for b in e[2:]:
                    queue.extend(b[1:])
                continue
            if e[0] == 'typeattributeset' and e[1] == 'cil_gen_require':
                continue
            if e[0] == 'roleattributeset' and e[1] == 'cil_gen_require':
                continue

            # only show each entity once
            e_str = str(e)
            if e_str in seen:
                continue
            seen.add(e_str)

            result.append(e)
        return result

    @staticmethod
    def create_terule(e: List[Union[str, List[Any]]], file: str) -> TERule:
        # Do first full assert of the type and then create Rule
        assert isinstance(e, list)
        assert len(e) == 4
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], str)
        assert isinstance(e[3], list)
        assert isinstance(e[3][0], str)
        assert isinstance(e[3][1], list)
        for _ in e[3][1]:
            assert isinstance(_, str)
        return TERule(file, str(e), e[0], e[1], e[2], e[3][0], e[3][1])

    @staticmethod
    def create_taset(e: List[Union[str, List[Any]]], file: str) -> TASet:
        assert isinstance(e, list)
        assert len(e) == 3
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], list)
        if e[2][0] in ('and', 'not', 'or'):
            return TASet(file, str(e), e[1], set(), True)
        for _ in e[2]:
            assert isinstance(_, str)
        return TASet(file, str(e), e[1], set(e[2]))

    @staticmethod
    def create_typetransition(
        e: List[Union[str, List[Any]]], file: str
    ) -> Typetransition:
        assert isinstance(e, list)
        assert len(e) >= 5
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], str)
        assert isinstance(e[3], str)
        assert isinstance(e[4], str)
        if len(e) == 6:
            assert isinstance(e[5], str)
            return Typetransition(file, str(e), e[1], e[2], e[3], e[5], e[4])
        return Typetransition(file, str(e), e[1], e[2], e[3], e[4])

    def setup(self) -> None:
        self.setup_tasets()

    def setup_tasets(self) -> None:
        rnd = ''.join(
            random.choice(string.ascii_letters + string.digits) for _ in range(16)
        )
        tables = []
        try:
            args = []
            query = []

            if not self.args.from_all_known:
                table = 'temp_files_' + rnd
                self.cur.execute(f'CREATE TEMPORARY TABLE {table}(x)')
                tables.append(table)
                self.cur.executemany(
                    f'INSERT INTO {table} VALUES (?)', [(a,) for a in self.args.files]
                )
                query.append(f'file IN {table}')

            full_query = f'SELECT * FROM typeattributes'
            if query:
                full_query = full_query + ' WHERE ' + ' AND '.join(query)

            for res in self.cur.fetchall():
                r = TASet(
                    res['file'],
                    res['string'],
                    res['type'],
                    res['attrs'].split(' '),
                    res['is_logical'],
                )
                self.tasets[r.type].append(r)
                for attr in r.attrs:
                    self.reverse_tasets[attr].append(r)
        finally:
            for t in tables:
                self.cur.execute(f'DROP TABLE {t}')

    def search(self) -> None:
        if self.cil_from is not None:
            self.search_from()
        elif self.args.resolveattr:
            self.search_resolveattr()
        elif self.args.attr:
            self.search_taset()
        else:
            self.search_terule()

    def search_from(self) -> None:
        assert self.cil_from is not None
        for e in self.cil_from:
            seen: set[str] = set()
            assert isinstance(e[0], str)
            if e[0] in type_enforcement_rule_types:
                r: TERule = self.create_terule(e, 'cil_from')
                self.oargs['type'] = r.type
                self.oargs['source'] = r.source
                self.oargs['target'] = r.target
                self.oargs['class'] = r.klass
                self.oargs['perms'] = r.perms
                self.update_args()

                got_all, got_any, missing_perms = self.search_terule(seen)
                if got_all:
                    perms = " ".join(r.perms)
                    status = 'found'
                elif got_any:
                    mp = []
                    for pp in r.perms:
                        if pp in missing_perms:
                            mp.append(f'-{pp}')
                        else:
                            mp.append(pp)
                    perms = " ".join(mp)
                    status = 'some'
                else:
                    perms = " ".join(r.perms)
                    status = 'no'
                print(
                    f'# {status}: ({r.type} {r.source} {r.target} ({r.klass} ({perms})))'
                )
            elif e[0] in ('boolean', 'filecon'):
                # Assume error during module load
                continue
            elif e[0] == 'typetransition':
                t: Typetransition = self.create_typetransition(e, 'cil_from')
                self.oargs['subject'] = t.subject
                self.oargs['source'] = t.source
                self.oargs['class'] = t.klass
                self.oargs['filename'] = t.filename
                self.oargs['target'] = t.target
                self.update_args()
                q = self.search_typetransition(seen)
                if q == Quad.TRUE:
                    status = 'found'
                elif q == Quad.PARTIAL:
                    status = 'partial'
                elif q == Quad.MORE:
                    status = 'more'
                else:
                    status = 'no'
                rpre = " ".join([e[0], t.subject, t.source, t.klass])
                if t.filename is None:
                    print(f'# {status}: ({rpre} {t.target})')
                else:
                    print(f'# {status}: ({rpre} {t.filename} {t.target})')
            else:
                print(f'# skip: {e}')

    def search_terule(
        self, seen: Optional[set[str]] = None
    ) -> Tuple[bool, bool, Set[str]]:
        got_all = True
        got_any = False
        missing_perms: Set[str] = set()
        if self.oargs['perms'] is not None:
            got_all = False
            missing_perms.update(self.vargs['perms'])
            wanted_perms = self.vargs['perms']

        rnd = ''.join(
            random.choice(string.ascii_letters + string.digits) for _ in range(16)
        )
        tables = []
        try:
            args = []
            query = []

            if not self.args.from_all_known:
                table = 'temp_files_' + rnd
                self.cur.execute(f'CREATE TEMPORARY TABLE {table}(x)')
                tables.append(table)
                self.cur.executemany(
                    f'INSERT INTO {table} VALUES (?)', [(a,) for a in self.args.files]
                )
                query.append(f'file IN {table}')

            if self.args.type is not None:
                query.append('type=?')
                args.append(self.args.type)

            multivars = [
                (
                    self.args.source,
                    'source',
                ),
                (
                    self.args.target,
                    'target',
                ),
                (
                    self.args.not_source,
                    'not_source',
                ),
                (
                    self.args.not_target,
                    'not_target',
                ),
            ]

            for var, name in multivars:
                if var is not None:
                    table = f'temp_{name}s_' + rnd
                    self.cur.execute(f'CREATE TEMPORARY TABLE {table}(x)')
                    tables.append(table)
                    self.cur.executemany(
                        f'INSERT INTO {table} VALUES (?)',
                        [(a,) for a in self.vargs[name]],
                    )
                    query.append(f'{name} IN {table}')

            for k in ('class',):
                query.append(f'{k}=?')
                args.append(self.oargs[k])

            full_query = f'SELECT * FROM te_rules'
            if query:
                full_query = full_query + ' WHERE ' + ' AND '.join(query)
            self.cur.execute(full_query, args)
            for res in self.cur.fetchall():
                r = TERule(
                    res['file'],
                    res['string'],
                    res['type'],
                    res['source'],
                    res['target'],
                    res['class'],
                    res['perms'].split(' '),
                )
                if self.oargs['from'] is not None and (
                    self.oargs['from'].name == r.file
                    or os.path.basename(self.oargs['from'].name)
                    == os.path.basename(r.file)
                ):
                    continue
                if seen is not None:
                    # only show each entity once
                    if r.string in seen:
                        continue
                    seen.add(r.string)
                if self.oargs['perms'] is not None:
                    got_perms = set(r.perms)
                    if wanted_perms.isdisjoint(got_perms):
                        continue
                    got_any = True
                    missing_perms -= got_perms
                    if not missing_perms:
                        got_all = True
                else:
                    got_any = True
                print(f'{r.file}:{r.string}')
            return got_all, got_any, missing_perms
        finally:
            for t in tables:
                self.cur.execute(f'DROP TABLE {t}')

    def search_typetransition(self, seen: Optional[set[str]] = None) -> Quad:
        found = Quad.FALSE
        rnd = ''.join(
            random.choice(string.ascii_letters + string.digits) for _ in range(16)
        )
        tables = []
        filestable = 'temp_files_' + rnd
        try:
            args = []
            query = []

            if not self.args.from_all_known:
                table = 'temp_files_' + rnd
                self.cur.execute(f'CREATE TEMPORARY TABLE {table}(x)')
                tables.append(table)
                self.cur.executemany(
                    f'INSERT INTO {table} VALUES (?)', [(a,) for a in self.args.files]
                )
                query.append(f'file IN {table}')

            multivars = [
                (self.args.source, 'source'),
                (self.args.target, 'target'),
                (self.args.not_source, 'not_source'),
                (self.args.not_target, 'not_target'),
            ]

            for var, name in multivars:
                if var is not None:
                    table = f'temp_{name}s_' + rnd
                    self.cur.execute(f'CREATE TEMPORARY TABLE {table}(x)')
                    tables.append(table)
                    self.cur.executemany(
                        f'INSERT INTO {table} VALUES (?)',
                        [(a,) for a in self.vargs[name]],
                    )
                    query.append(f'{name} IN {table}')

            for k in ('class', 'subject'):
                query.append(f'{k}=?')
                args.append(self.oargs[k])

            full_query = f'SELECT * FROM typetransitions'
            if query:
                full_query = full_query + ' WHERE ' + ' AND '.join(query)
            self.cur.execute(full_query, args)
            for res in self.cur.fetchall():
                r = Typetransition(
                    res['file'],
                    res['string'],
                    res['subject'],
                    res['source'],
                    res['class'],
                    res['target'],
                    res['filename'],
                )
                if self.oargs['from'] is not None and (
                    self.oargs['from'].name == r.file
                    or os.path.basename(self.oargs['from'].name)
                    == os.path.basename(r.file)
                ):
                    continue
                q = self.match_typetransition(r)
                if q == Quad.FALSE:
                    continue
                if seen is not None:
                    # only show each entity once
                    if r.string in seen:
                        continue
                    seen.add(r.string)
                print(f'{r.file}:{r.string}')
                found = q
            return found
        finally:
            for t in tables:
                self.cur.execute(f'DROP TABLE {t}')

    def search_taset(self, seen: Optional[set[str]] = None) -> bool:
        found = False
        result: set[TASet] = set()
        if 'source' in self.vargs and self.vargs['source'] is not None:
            for s in self.vargs['source']:
                if s in self.reverse_tasets:
                    tas = self.reverse_tasets[self.args.source]
                    if tas is not None:
                        result.update(tas)
        if 'target' in self.vargs and self.vargs['target'] is not None:
            for s in self.vargs['target']:
                if s in self.tasets:
                    tas = self.tasets[s]
                    if tas is not None:
                        result.update(tas)
        for r in result:
            if not self.match_typeattributeset(r):
                continue
            found = True
            if seen is not None:
                # only show each entity once
                if r.string in seen:
                    continue
                seen.add(r.string)
            print(f'{r.file}:{r.string}')
        return found

    def search_resolveattr(self) -> None:
        result: set[str] = set()
        if 'source' in self.vargs and self.vargs['source'] is not None:
            for s in self.vargs['source']:
                if s in self.reverse_tasets:
                    result.add(s)
                    for r in self.reverse_tasets[s]:
                        result.update(r.attrs)
        if 'target' in self.vargs and self.vargs['target'] is not None:
            for t in self.vargs['target']:
                if t in self.tasets:
                    result.add(t)
                    result.update([r.type for r in self.tasets[t]])
        for attr in sorted(result):
            print(f'{attr}')

    def match_typeattributeset(self, taset: TASet) -> bool:
        if self.args.source is not None and self.args.source != taset.type:
            return False
        if self.args.target is not None and self.args.target not in taset.attrs:
            return False
        return True

    def match_typetransition(self, r: Typetransition) -> Quad:
        if r.subject != self.oargs['subject']:
            return Quad.FALSE
        if r.source not in self.vargs['source']:
            return Quad.FALSE
        if r.target not in self.vargs['target']:
            return Quad.FALSE
        if r.klass != self.oargs['class']:
            return Quad.FALSE
        if self.oargs['filename'] is None:
            if r.filename is not None:
                return Quad.PARTIAL
        else:
            if r.filename is None:
                return Quad.MORE
            if self.oargs['filename'] != r.filename:
                return Quad.FALSE
        return Quad.TRUE


def main() -> None:
    parser = argparse.ArgumentParser(description='Parse and search cil files')
    files_group = parser.add_mutually_exclusive_group(required=True)
    files_group.add_argument('files', metavar='FILES', type=str, nargs='*', default=[])
    files_group.add_argument('--from-all-known', action='store_true')
    type_group = parser.add_mutually_exclusive_group()
    type_group.add_argument('--type', choices=type_enforcement_rule_types)
    type_group.add_argument('--attr', action='store_true')
    type_group.add_argument('--resolveattr', action='store_true')
    parser.add_argument('--source', type=str)
    parser.add_argument('--not-source', type=str)
    parser.add_argument('--target', type=str)
    parser.add_argument('--not-target', type=str)
    parser.add_argument('--class', type=str)
    parser.add_argument('--perms', type=str)
    parser.add_argument('--reverse-source', action='store_true')
    parser.add_argument('--reverse-target', action='store_true')
    parser.add_argument('--from', type=argparse.FileType('r'))

    args = parser.parse_args()
    # print(args)
    # sys.exit(0)

    cs = CilSearcher(args)
    cs.load()
    cs.setup()
    cs.search()


if __name__ == '__main__':
    main()
