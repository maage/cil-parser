#!/usr/bin/python3

import argparse
from collections import defaultdict
import copy
from dataclasses import (
    dataclass,
    field,
)
from enum import (
    Enum,
    auto,
)

import json
import os

import random
import sqlite3
import string

import sys

from typing import (
    # cast,
    Any,
    # Callable,
    # Collection,
    # Counter,
    Dict,
    DefaultDict,
    # Generator,
    # Iterator,
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


CilExpression = List[Union[str, List[Any]]]
TERulesSql = List[Dict[str, str]]
TASetsSql = List[Dict[str, Union[str, bool]]]
TypetransitionsSql = List[Dict[str, Optional[str]]]
ParsedCil = Tuple[List["TERule"], List["TASet"], List["Typetransition"]]


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
    # pylint: disable=no-self-use, unused-argument
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


def bool_to_str10(lst: List[bool]) -> str:
    return " ".join(str(a * 1) for a in lst)


def str10_to_bool(s: str) -> List[bool]:
    return [a == "1" for a in s.split(" ")]


def expr_to_str(e: CilExpression, optional: List[str], booleanvalue: List[bool]) -> str:
    rstring = []
    bi = -1
    for o in optional:
        if o.startswith("["):
            bi += 1
            rstring.append(f"{o}=={booleanvalue[bi]}")
        else:
            rstring.append(o)
    rstring.append(str(e))
    return " ".join(rstring)


# type enforcement rule
@dataclass
class TERule:
    file: str
    string: str
    type: str
    source: str
    target: str
    klass: str
    perms: List[str] = field(default_factory=list)
    optional: List[str] = field(default_factory=list)
    booleanvalue: List[bool] = field(default_factory=list)

    def sqldict(self) -> Dict[str, str]:
        return {
            "file": self.file,
            "string": self.string,
            "type": self.type,
            "source": self.source,
            "target": self.target,
            "class": self.klass,
            "perms": " ".join(self.perms),
            "optional": " ".join(self.optional),
            "booleanvalue": bool_to_str10(self.booleanvalue),
        }

    @classmethod
    def fromsqlrow(cls, res: sqlite3.Row) -> "TERule":
        return TERule(
            res["file"],
            res["string"],
            res["type"],
            res["source"],
            res["target"],
            res["class"],
            res["perms"].split(" "),
            res["optional"].split(" "),
            str10_to_bool(res["booleanvalue"]),
        )

    @classmethod
    def fromexpr(
        cls, e: CilExpression, file: str, optional: List[str], booleanvalue: List[bool]
    ) -> "TERule":
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
        rstring = expr_to_str(e, optional, booleanvalue)
        return TERule(
            file, rstring, e[0], e[1], e[2], e[3][0], e[3][1], optional, booleanvalue
        )


# type attribute set
@dataclass
class TASet:
    file: str
    string: str
    type: str
    attrs: set[str] = field(default_factory=set)
    is_logical: bool = False
    optional: List[str] = field(default_factory=list)
    booleanvalue: List[bool] = field(default_factory=list)

    def sqldict(self) -> Dict[str, Union[str, bool]]:
        return {
            "file": self.file,
            "string": self.string,
            "type": self.type,
            "attrs": " ".join(self.attrs),
            "is_logical": self.is_logical,
            "optional": " ".join(self.optional),
            "booleanvalue": bool_to_str10(self.booleanvalue),
        }

    @classmethod
    def fromsqlrow(cls, res: sqlite3.Row) -> "TASet":
        return TASet(
            res["file"],
            res["string"],
            res["type"],
            res["attrs"].split(" "),
            res["is_logical"],
            res["optional"].split(" "),
            str10_to_bool(res["booleanvalue"]),
        )

    @classmethod
    def fromexpr(
        cls, e: CilExpression, file: str, optional: List[str], booleanvalue: List[bool]
    ) -> "TASet":
        assert isinstance(e, list)
        assert len(e) == 3
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], list)
        rstring = expr_to_str(e, optional, booleanvalue)
        if e[2][0] in ("and", "not", "or"):
            return TASet(file, rstring, e[1], set(), True, optional, booleanvalue)
        for _ in e[2]:
            assert isinstance(_, str)
        return TASet(file, rstring, e[1], set(e[2]), False, optional, booleanvalue)


@dataclass
class Typetransition:
    file: str
    string: str
    subject: str
    source: str
    klass: str
    target: str
    filename: Optional[str] = None
    optional: List[str] = field(default_factory=list)
    booleanvalue: List[bool] = field(default_factory=list)

    def sqldict(self) -> Dict[str, Optional[str]]:
        return {
            "file": self.file,
            "string": self.string,
            "subject": self.subject,
            "source": self.source,
            "class": self.klass,
            "target": self.target,
            "filename": self.filename,
            "optional": " ".join(self.optional),
            "booleanvalue": bool_to_str10(self.booleanvalue),
        }

    @classmethod
    def fromsqlrow(cls, res: sqlite3.Row) -> "Typetransition":
        return Typetransition(
            res["file"],
            res["string"],
            res["subject"],
            res["source"],
            res["class"],
            res["target"],
            res["filename"],
            res["optional"].split(" "),
            str10_to_bool(res["booleanvalue"]),
        )

    @classmethod
    def fromexpr(
        cls, e: CilExpression, file: str, optional: List[str], booleanvalue: List[bool]
    ) -> "Typetransition":
        assert isinstance(e, list)
        assert len(e) >= 5
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], str)
        assert isinstance(e[3], str)
        assert isinstance(e[4], str)
        rstring = expr_to_str(e, optional, booleanvalue)
        if len(e) == 6:
            assert isinstance(e[5], str)
            return Typetransition(
                file, rstring, e[1], e[2], e[3], e[5], e[4], optional, booleanvalue
            )
        return Typetransition(
            file, rstring, e[1], e[2], e[3], e[4], None, optional, booleanvalue
        )


cilp = CilParser()


type_enforcement_rule_types = [
    "allow",
    "auditallow",
    "dontaudit",
    "neverallow",
    "allowxperm",
    "auditallowxperm",
    "dontauditxperm",
    "neverallowxperm",
]


class CilSearcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.tasets: DefaultDict[str, List[TASet]] = defaultdict(list)
        self.reverse_tasets: DefaultDict[str, List[TASet]] = defaultdict(list)
        self.typetransitions: List[Typetransition] = []
        self.cil_from: Optional[ParsedCil] = None
        self.args = args
        self.update_args()
        self.con: Optional[sqlite3.Connection] = None
        self.cur: Optional[sqlite3.Cursor] = None
        self.files: List[str] = []

    def update_args(self) -> None:
        self.oargs = vars(self.args)
        self.vargs: DefaultDict[str, Set[str]] = defaultdict(set)
        for key in ("perms",):
            if key not in self.oargs:
                self.oargs[key] = None
                continue
            if self.oargs[key] is None:
                continue
            if isinstance(self.oargs[key], str):
                self.vargs[key].add(self.oargs[key])
            else:
                self.vargs[key].update(self.oargs[key])
        for key in ("subject", "source", "target", "not_source", "not_target"):
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
                for r in self.reverse_tasets[val]:
                    self.vargs[key].add(r.type)

    def setup_cache(self) -> None:
        con = sqlite3.connect("export/cache.db", timeout=3600)
        # con.enable_callback_tracebacks(print)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute("PRAGMA foreign_keys")

        cur.execute("BEGIN EXCLUSIVE TRANSACTION")

        cur.execute(
            """CREATE TABLE IF NOT EXISTS files
            ( file TEXT PRIMARY KEY
            , mtime_us INTEGER NOT NULL
            )"""
        )

        # perms: perms joined with " "
        # optional: optional names joined with " "
        # booleanvalue: true(1)/false(0) value of rules joined with " "
        cur.execute(
            """CREATE TABLE IF NOT EXISTS te_rules
            ( file TEXT NOT NULL
            , string TEXT NOT NULL
            , type TEXT NOT NULL
            , source TEXT NOT NULL
            , target TEXT NOT NULL
            , class TEXT NOT NULL
            , perms TEXT NOT NULL
            , optional TEXT NOT NULL
            , booleanvalue TEXT NOT NULL
            , FOREIGN KEY(file) REFERENCES files(file)
            )"""
        )
        cur.execute(
            """CREATE TABLE IF NOT EXISTS typeattributes
            ( file TEXT NOT NULL
            , string TEXT NOT NULL
            , type TEXT NOT NULL
            , attrs TEXT NOT NULL
            , is_logical INTEGER DEFAULT (0)
            , optional TEXT NOT NULL
            , booleanvalue TEXT NOT NULL
            , FOREIGN KEY(file) REFERENCES files(file)
            )"""
        )
        cur.execute(
            """CREATE TABLE IF NOT EXISTS typetransitions
            ( file TEXT NOT NULL
            , string TEXT NOT NULL
            , subject TEXT NOT NULL
            , source TEXT NOT NULL
            , class TEXT NOT NULL
            , target TEXT NOT NULL
            , filename TEXT
            , optional TEXT NOT NULL
            , booleanvalue TEXT NOT NULL
            , FOREIGN KEY(file) REFERENCES files(file)
            )"""
        )

        con.commit()
        self.cur = cur
        self.con = con

    def refresh_cache(self) -> None:
        assert self.con is not None
        assert self.cur is not None

        if self.args.from_all_known:
            self.cur.execute("SELECT file FROM files")
            for res in self.cur.fetchall():
                file1 = res[0]
                if os.path.exists(file1):
                    self.files.append(file1)
            return

        files_no_need_to_update = set()
        for file1 in self.args.files:
            if os.path.exists(file1):
                self.files.append(file1)
                mtime_us = int(os.path.getmtime(file1) * 1000000)
                self.cur.execute(
                    """
                    SELECT file FROM files
                    WHERE file=:file AND mtime_us == :mtime_us
                    """,
                    {"file": file1, "mtime_us": mtime_us},
                )
                for res in self.cur.fetchall():
                    files_no_need_to_update.add(res[0])
        files_to_update = set(self.files) - files_no_need_to_update
        # print(f'# files_to_update: {files_to_update}')
        for idx, file1 in enumerate(files_to_update):
            self.cur.execute("BEGIN EXCLUSIVE TRANSACTION")

            need_update = False
            if os.path.exists(file1):
                need_update = True
                mtime_us = int(os.path.getmtime(file1) * 1000000)
                self.cur.execute(
                    """
                    SELECT file FROM files
                    WHERE file=:file AND mtime_us == :mtime_us
                    """,
                    {"file": file1, "mtime_us": mtime_us},
                )
                for _ in self.cur.fetchall():
                    need_update = False
                    break

            if not need_update:
                # file was removed/updated in meantime
                self.con.commit()
                continue

            print(f"# {idx+1}/{len(files_to_update)} {file1}")
            self.refresh_cache_one_file(file1)
            self.con.commit()

    def refresh_cache_one_file(self, file1: str) -> None:
        assert self.cur is not None
        with open(file1, "r") as fd:
            mtime_us = int(os.path.getmtime(file1) * 1000000)

            tree = grammar.parse(fd.read())
            queue = cilp.visit(tree)
            res = self.handle_file(queue, file1, [], [])

            te_rules: TERulesSql = []
            typeattributes: TASetsSql = []
            typetransitions: TypetransitionsSql = []

            for te in res[0]:
                te_rules.append(te.sqldict())
            for ta in res[1]:
                typeattributes.append(ta.sqldict())
            for tt in res[2]:
                typetransitions.append(tt.sqldict())

            self.cur.execute(
                """
                DELETE FROM te_rules
                WHERE file=:file
                """,
                {"file": file1},
            )
            self.cur.execute(
                """
                DELETE FROM typeattributes
                WHERE file=:file
                """,
                {"file": file1},
            )
            self.cur.execute(
                """
                DELETE FROM typetransitions
                WHERE file=:file
                """,
                {"file": file1},
            )

            self.cur.executemany(
                """
                INSERT INTO te_rules
                      ( file,  string,  type,  source,  target,  class,  perms,  optional,  booleanvalue)
                VALUES(:file, :string, :type, :source, :target, :class, :perms, :optional, :booleanvalue)
                """,
                te_rules,
            )

            self.cur.executemany(
                """
                INSERT INTO typeattributes
                      ( file,  string,  type,  attrs,  is_logical,  optional,  booleanvalue)
                VALUES(:file, :string, :type, :attrs, :is_logical, :optional, :booleanvalue)
                """,
                typeattributes,
            )

            self.cur.executemany(
                """
                INSERT INTO typetransitions
                      ( file,  string,  subject,  source,  class,  target,  filename,  optional,  booleanvalue)
                VALUES(:file, :string, :subject, :source, :class, :target, :filename, :optional, :booleanvalue)
                """,
                typetransitions,
            )

            self.cur.execute(
                """
                REPLACE INTO files
                       ( file,  mtime_us)
                VALUES (:file, :mtime_us)
                """,
                {"file": file1, "mtime_us": mtime_us},
            )

    def load(self) -> None:
        self.setup_cache()
        self.refresh_cache()
        self.handle_from_arg()

    def handle_from_arg(self) -> None:
        from_file = self.oargs["from"]
        if from_file is not None:
            print(f"# {1}/{1} {from_file.name}")
            tree = grammar.parse(from_file.read())
            cil_from = cilp.visit(tree)
            self.cil_from = self.handle_file(cil_from, "cil_from", [], [])

    def handle_file(
        self, queue: List[Any], file1: str, op: List[Any], bv: List[bool]
    ) -> ParsedCil:
        seen: set[str] = set()

        te_rules: List["TERule"] = []
        typeattributes: List["TASet"] = []
        typetransitions: List["Typetransition"] = []

        # First recurse and filter unique only per rule. Drop all
        # cil_gen_requires as there is no info there for us.
        while queue:
            e = queue.pop(0)
            if e[0] == "optional":
                op2, bv2 = copy.copy(op), copy.copy(bv)
                op2.append(e[1])
                res = self.handle_file(e[2:], file1, op2, bv2)
                te_rules.extend(res[0])
                typeattributes.extend(res[1])
                typetransitions.extend(res[2])
                continue
            if e[0] == "booleanif":
                for b in e[2:]:
                    op2, bv2 = copy.copy(op), copy.copy(bv)
                    op2.append(json.dumps(e[1]))
                    bv2.append(b[0] == "true")
                    res = self.handle_file(b[1:], file1, op2, bv2)
                    te_rules.extend(res[0])
                    typeattributes.extend(res[1])
                    typetransitions.extend(res[2])
                continue
            if e[0] == "typeattributeset" and e[1] == "cil_gen_require":
                continue
            if e[0] == "roleattributeset" and e[1] == "cil_gen_require":
                continue

            # only show each entity once
            e_str = str(e)
            if e_str in seen:
                continue
            seen.add(e_str)

            if e[0] in type_enforcement_rule_types:
                te = TERule.fromexpr(e, file1, op, bv)
                te_rules.append(te)
            elif e[0] == "typeattributeset":
                ta = TASet.fromexpr(e, file1, op, bv)
                typeattributes.append(ta)
            elif e[0] == "typetransition":
                tt = Typetransition.fromexpr(e, file1, op, bv)
                typetransitions.append(tt)
            elif e[0] in [
                "category",
                "categoryorder",
                "class",
                "classcommon",
                "classorder",
                "common",
                "defaultrange",
                "filecon",
                "fsuse",
                "genfscon",
                "handleunknown",
                "mls",
                "mlsconstrain",
                "policycap",
                "portcon",
                "rangetransition",
                "role",
                "roleallow",
                "roleattribute",
                "roleattributeset",
                "roletransition",
                "roletype",
                "selinuxuser",
                "selinuxuserdefault",
                "sensitivity",
                "sensitivitycategory",
                "sensitivityorder",
                "sid",
                "sidcontext",
                "sidorder",
                "type",
                "typealias",
                "typealiasactual",
                "typeattribute",
                "typechange",
                "typemember",
                "user",
                "userlevel",
                "userprefix",
                "userrange",
                "userrole",
            ]:
                None
            elif e[0] == "boolean":
                # ['boolean', 'name', 'false']
                None
            else:
                print(e)
                sys.exit(1)

        return (te_rules, typeattributes, typetransitions)

    @staticmethod
    def rand_str(size: int) -> str:
        return "".join(
            random.choice(string.ascii_letters + string.digits) for _ in range(size)
        )

    def sql_temp_table_query(
        self,
        tables: List[str],
        multivars: List[Tuple[Set[str], str]],
        simplevars: List[str],
        full_query: str,
    ) -> Tuple[str, List[str]]:
        assert self.cur is not None
        rnd = self.rand_str(16)

        args: List[str] = []
        query: List[str] = []

        table = "temp_files_" + rnd
        self.cur.execute(f"CREATE TEMPORARY TABLE {table}(x)")
        tables.append(table)
        self.cur.executemany(
            f"INSERT INTO {table} VALUES (?)", [(a,) for a in self.files]
        )
        query.append(f"file IN {table}")

        for var, name in multivars:
            if var is not None:
                table = f"temp_{name}s_" + rnd
                self.cur.execute(f"CREATE TEMPORARY TABLE {table}(x)")
                tables.append(table)
                self.cur.executemany(
                    f"INSERT INTO {table} VALUES (?)",
                    [(a,) for a in self.vargs[name]],
                )
                query.append(f"{name} IN {table}")

        for k in simplevars:
            query.append(f"{k}=?")
            args.append(self.oargs[k])

        if query:
            full_query = full_query + " WHERE " + " AND ".join(query)

        return (full_query, args)

    def setup(self) -> None:
        self.setup_tasets()

    def setup_tasets(self) -> None:
        assert self.cur is not None
        tables: List[str] = []
        try:
            full_query, args = self.sql_temp_table_query(
                tables, [], [], "SELECT * FROM typeattributes"
            )
            self.cur.execute(full_query, args)
            for res in self.cur.fetchall():
                r = TASet.fromsqlrow(res)
                self.tasets[r.type].append(r)
                for attr in r.attrs:
                    self.reverse_tasets[attr].append(r)
        finally:
            for t in tables:
                self.cur.execute(f"DROP TABLE {t}")

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
        # pylint: disable=too-many-branches, too-many-statements
        assert self.cil_from is not None
        seen: set[str] = set()
        te_rules, typeattributes, typetransitions = self.cil_from
        for r in te_rules:
            self.oargs["type"] = r.type
            self.oargs["source"] = r.source
            self.oargs["target"] = r.target
            self.oargs["class"] = r.klass
            self.oargs["perms"] = r.perms
            self.update_args()

            got_all, got_any, missing_perms = self.search_terule(seen)
            if got_all:
                perms = " ".join(r.perms)
                status = "found"
            elif got_any:
                mp = []
                # pylint: disable=not-an-iterable
                for pp in r.perms:
                    if pp in missing_perms:
                        mp.append(f"-{pp}")
                    else:
                        mp.append(pp)
                perms = " ".join(mp)
                status = "some"
            else:
                perms = " ".join(r.perms)
                status = "no"
            print(f"# {status}: ({r.type} {r.source} {r.target} ({r.klass} ({perms})))")
        for t in typetransitions:
            self.oargs["subject"] = t.subject
            self.oargs["source"] = t.source
            self.oargs["class"] = t.klass
            self.oargs["filename"] = t.filename
            self.oargs["target"] = t.target
            self.update_args()
            q = self.search_typetransition(seen)
            if q == Quad.TRUE:
                status = "found"
            elif q == Quad.PARTIAL:
                status = "partial"
            elif q == Quad.MORE:
                status = "more"
            else:
                status = "no"
            rpre = " ".join(["typetransitions", t.subject, t.source, t.klass])
            if t.filename is None:
                print(f"# {status}: ({rpre} {t.target})")
            else:
                print(f"# {status}: ({rpre} {t.filename} {t.target})")

    @staticmethod
    def handle_seen(
        seen: Optional[set[str]], r: Union[TERule, Typetransition, TASet]
    ) -> bool:
        if seen is None:
            return True
        seen_key = " ".join((r.file, r.string))
        # only show each entity once
        if seen_key in seen:
            return False
        seen.add(seen_key)
        return True

    def search_terule(
        self, seen: Optional[set[str]] = None
    ) -> Tuple[bool, bool, Set[str]]:
        assert self.cur is not None
        got_all = True
        got_any = False
        missing_perms: Set[str] = set()
        if self.oargs["perms"] is not None:
            got_all = False
            missing_perms.update(self.vargs["perms"])
            wanted_perms = self.vargs["perms"]

        tables: List[str] = []
        multivars = [
            (self.args.source, "source"),
            (self.args.target, "target"),
            (self.args.not_source, "not_source"),
            (self.args.not_target, "not_target"),
        ]
        simplevars = ["class", "type"]
        try:
            full_query, args = self.sql_temp_table_query(
                tables, multivars, simplevars, "SELECT * FROM te_rules"
            )
            self.cur.execute(full_query, args)
            for res in self.cur.fetchall():
                r = TERule.fromsqlrow(res)
                if self.oargs["from"] is not None and (
                    self.oargs["from"].name == r.file
                    or os.path.basename(self.oargs["from"].name)
                    == os.path.basename(r.file)
                ):
                    continue
                if not self.handle_seen(seen, r):
                    continue
                if self.oargs["perms"] is not None:
                    got_perms = set(r.perms)
                    if wanted_perms.isdisjoint(got_perms):
                        continue
                    got_any = True
                    missing_perms -= got_perms
                    if not missing_perms:
                        got_all = True
                else:
                    got_any = True
                print(f"{r.file}:{r.string}")
            return got_all, got_any, missing_perms
        finally:
            for t in tables:
                self.cur.execute(f"DROP TABLE {t}")

    def search_typetransition(self, seen: Optional[set[str]] = None) -> Quad:
        assert self.cur is not None
        found = Quad.FALSE
        tables: List[str] = []
        multivars = [
            (self.args.source, "source"),
            (self.args.target, "target"),
            (self.args.not_source, "not_source"),
            (self.args.not_target, "not_target"),
        ]
        simplevars = ["class", "subject"]
        try:
            full_query, args = self.sql_temp_table_query(
                tables, multivars, simplevars, "SELECT * FROM typetransitions"
            )
            self.cur.execute(full_query, args)
            for res in self.cur.fetchall():
                r = Typetransition.fromsqlrow(res)
                if self.oargs["from"] is not None and (
                    self.oargs["from"].name == r.file
                    or os.path.basename(self.oargs["from"].name)
                    == os.path.basename(r.file)
                ):
                    continue
                q = self.match_typetransition(r)
                if q == Quad.FALSE:
                    continue
                if not self.handle_seen(seen, r):
                    continue
                print(f"{r.file}:{r.string}")
                found = q
            return found
        finally:
            for t in tables:
                self.cur.execute(f"DROP TABLE {t}")

    def search_taset(self, seen: Optional[set[str]] = None) -> bool:
        found = False
        result: set[TASet] = set()
        if "source" in self.vargs and self.vargs["source"] is not None:
            for s in self.vargs["source"]:
                if s in self.reverse_tasets:
                    tas = self.reverse_tasets[self.args.source]
                    if tas is not None:
                        result.update(tas)
        if "target" in self.vargs and self.vargs["target"] is not None:
            for s in self.vargs["target"]:
                if s in self.tasets:
                    tas = self.tasets[s]
                    if tas is not None:
                        result.update(tas)
        for r in result:
            if not self.match_typeattributeset(r):
                continue
            found = True
            if not self.handle_seen(seen, r):
                continue
            print(f"{r.file}:{r.string}")
        return found

    def search_resolveattr(self) -> None:
        result: set[str] = set()
        if "source" in self.vargs and self.vargs["source"] is not None:
            for s in self.vargs["source"]:
                if s in self.reverse_tasets:
                    result.add(s)
                    for r in self.reverse_tasets[s]:
                        result.update(r.attrs)
        if "target" in self.vargs and self.vargs["target"] is not None:
            for t in self.vargs["target"]:
                if t in self.tasets:
                    result.add(t)
                    result.update([r.type for r in self.tasets[t]])
        for attr in sorted(result):
            print(f"{attr}")

    def match_typeattributeset(self, taset: TASet) -> bool:
        if self.args.source is not None and self.args.source != taset.type:
            return False
        if self.args.target is not None and self.args.target not in taset.attrs:
            return False
        return True

    def match_typetransition(self, r: Typetransition) -> Quad:
        # pylint: disable=too-many-return-statements
        if r.subject != self.oargs["subject"]:
            return Quad.FALSE
        if r.source not in self.vargs["source"]:
            return Quad.FALSE
        if r.target not in self.vargs["target"]:
            return Quad.FALSE
        if r.klass != self.oargs["class"]:
            return Quad.FALSE
        if self.oargs["filename"] is None:
            if r.filename is not None:
                return Quad.PARTIAL
        else:
            if r.filename is None:
                return Quad.MORE
            if self.oargs["filename"] != r.filename:
                return Quad.FALSE
        return Quad.TRUE


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse and search cil files")
    files_group = parser.add_mutually_exclusive_group(required=True)
    files_group.add_argument("files", metavar="FILES", type=str, nargs="*", default=[])
    files_group.add_argument("--from-all-known", action="store_true")
    type_group = parser.add_mutually_exclusive_group()
    type_group.add_argument("--type", choices=type_enforcement_rule_types)
    type_group.add_argument("--attr", action="store_true")
    type_group.add_argument("--resolveattr", action="store_true")
    parser.add_argument("--source", type=str)
    parser.add_argument("--not-source", type=str)
    parser.add_argument("--target", type=str)
    parser.add_argument("--not-target", type=str)
    parser.add_argument("--class", type=str)
    parser.add_argument("--perms", type=str)
    parser.add_argument("--reverse-source", action="store_true")
    parser.add_argument("--reverse-target", action="store_true")
    parser.add_argument("--from", type=argparse.FileType("r"))

    args = parser.parse_args()
    # print(args)
    # sys.exit(0)

    cs = CilSearcher(args)
    cs.load()
    cs.setup()
    cs.search()


if __name__ == "__main__":
    main()
