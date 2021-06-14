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
import json
import os
import random
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
    # Tuple,
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


# type attribute set
@dataclass
class TASet:
    file: str
    string: str
    type: str
    attrs: set[str] = field(default_factory=set)
    is_logical: bool = False


@dataclass
class Typetransition:
    subject: str
    source: str
    klass: str
    target: str
    filename: Optional[str] = None


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
        self.filtered: DefaultDict[str, ParsedCil] = defaultdict(list)
        self.tasets: List[TASet] = []
        self.reverse_tasets: Dict[str, List[TASet]] = defaultdict(list)
        self.te_rules: Dict[str, TERule] = {}
        self.te_rule_tree: Dict[str, List[TERule]] = defaultdict(list)
        self.typetransitions: Dict[str, Typetransition] = {}
        self.cil_from: Optional[ParsedCil] = None

    def update_args(self) -> None:
        self.oargs = vars(self.args)
        self.vargs: Dict[str, Set[str]] = defaultdict(set)
        key = 'perm'
        if self.oargs[key] is not None:
            if isinstance(self.oargs[key], str):
                self.vargs[key].add(self.oargs[key])
            else:
                self.vargs[key].update(self.oargs[key])
        for key in ('source', 'target', 'not_source', 'not_target'):
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

    @staticmethod
    def file_nt(f1: str, f2: str) -> Optional[bool]:
        if not os.path.exists(f1):
            return None
        if not os.path.exists(f2):
            return None
        result = bool(os.path.getmtime(f1) > os.path.getmtime(f2))
        if result:
            print(
                f'Cache miss: {f1}:{os.path.getmtime(f1)} < {f2}:{os.path.getmtime(f2)}',
                file=sys.stderr,
            )
        return result

    def load(self) -> None:
        file1: str

        cache_file = 'tmp/_cache_filterd.json'
        filtered_cache: Dict[str, List[Any]] = {}
        rnd = random.Random().random()
        filtered_cache_changed = False
        if os.path.exists(cache_file):
            with open(cache_file, 'r') as fd:
                filtered_cache = json.load(fd)

        from_file = self.oargs['from']
        if from_file is not None:
            tree = grammar.parse(from_file.read())
            cil_from = cilp.visit(tree)
            self.cil_from = self.handle_file(cil_from)

        for file1 in self.args.files:
            nt = self.file_nt(file1, cache_file)
            if nt is not None and not nt:
                if file1 in filtered_cache:
                    self.filtered[file1].extend(filtered_cache[file1])
                    continue

            filtered_cache_changed = True
            queue = []
            # It is way faster to load json than parse cil
            nt = self.file_nt(file1, f'{file1}.json')
            if nt is not None and not nt:
                with open(f'{file1}.json', 'r') as fd:
                    queue.extend(json.load(fd))
            else:
                print(f'# {file1}')
                with open(file1, 'r') as fd:
                    tree = grammar.parse(fd.read())
                    queue = cilp.visit(tree)
                    tmp = f'{file1}.json.tmp.{rnd}'
                    with open(tmp, 'w') as out:
                        json.dump(queue, out)
                    os.replace(tmp, f'{file1}.json')
            self.filtered[file1].extend(self.handle_file(queue))

        if filtered_cache_changed:
            tmp = f'{cache_file}.tmp.{rnd}'
            with open(tmp, 'w') as out:
                json.dump(self.filtered, out)
            os.replace(tmp, cache_file)

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
            return TASet(file, str(e), e[1], [], True)
        for _ in e[2]:
            assert isinstance(_, str)
        return TASet(file, str(e), e[1], e[2])

    @staticmethod
    def create_typetransition(e: List[Union[str, List[Any]]]) -> Typetransition:
        assert isinstance(e, list)
        assert len(e) >= 5
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], str)
        assert isinstance(e[3], str)
        assert isinstance(e[4], str)
        if len(e) == 6:
            assert isinstance(e[5], str)
            return Typetransition(e[1], e[2], e[3], e[5], e[4])
        return Typetransition(e[1], e[2], e[3], e[4])

    def setup(self) -> None:
        self.setup_tasets()
        if self.args.resolveattr:
            return
        if self.args.attr:
            return
        self.setup_terule_tree()

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
                got_all = True
                got_any = False
                missing_perms = []

                # first query all
                self.oargs['perm'] = r.perms
                if self.search_terule(seen):
                    got_any = True
                else:
                    for perm in r.perms:
                        self.oargs['perm'] = perm
                        self.update_args()
                        if self.search_terule(seen):
                            got_any = True
                        else:
                            got_all = False
                            missing_perms.append(perm)
                if got_all:
                    perms = " ".join(r.perms)
                    status = 'found'
                elif got_any:
                    perms = " ".join(missing_perms)
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
                t: Typetransition = self.create_typetransition(e)
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

    def search_terule(self, seen: Optional[set[str]] = None) -> bool:
        found = False
        if (
            self.args.type is not None
            and self.args.source is not None
            and self.args.target is not None
            and self.oargs['class'] is not None
        ):
            for source in self.vargs['source']:
                for target in self.vargs['target']:
                    trt_key = " ".join(
                        (self.args.type, source, target, self.oargs['class'])
                    )
                    if trt_key in self.te_rule_tree:
                        for r in self.te_rule_tree[trt_key]:
                            if self.search_terule_one(r, seen):
                                found = True
            return found

        for file1, rules in self.filtered.items():
            if self.oargs['from'] is not None and (
                self.oargs['from'].name == file1
                or os.path.basename(self.oargs['from'].name) == os.path.basename(file1)
            ):
                continue
            for e in rules:
                if e[0] in type_enforcement_rule_types:
                    e_str = str(e)
                    if e_str in self.te_rules:
                        r = self.te_rules[e_str]
                        if self.search_terule_one(r, seen):
                            found = True
        return found

    def setup_terule_tree(self) -> None:
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] in type_enforcement_rule_types:
                    e_str = str(e)
                    r = self.te_rules.get(e_str, None)
                    if r is None:
                        r = self.create_terule(e, file1)
                        self.te_rules[e_str] = r
                    trt_key = " ".join((r.type, r.source, r.target, r.klass))
                    self.te_rule_tree[trt_key].append(r)

    def setup_tasets(self) -> None:
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] == 'typeattributeset':
                    r = self.create_taset(e, file1)
                    self.tasets.append(r)
                    for attr in r.attrs:
                        self.reverse_tasets[attr].append(r)

    def search_terule_one(self, r: TERule, seen: Optional[set[str]] = None) -> bool:
        if self.oargs['from'] is not None and (
            self.oargs['from'].name == r.file
            or os.path.basename(self.oargs['from'].name) == os.path.basename(r.file)
        ):
            return False
        if not self.match_type_enforcement_rule(r):
            return False
        if seen is not None:
            # only show each entity once
            if r.string in seen:
                return False
            seen.add(r.string)
        print(f'{r.file}:{r.string}')
        return True

    def search_typetransition(self, seen: Optional[set[str]] = None) -> Quad:
        found = Quad.FALSE
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] == 'typetransition':
                    e_str = str(e)
                    r = self.typetransitions.get(e_str, None)
                    if r is None:
                        r = self.create_typetransition(e)
                        self.typetransitions[e_str] = r
                    q = self.match_typetransition(r)
                    if q == Quad.FALSE:
                        continue
                    if found in (Quad.FALSE, Quad.TRUE):
                        # if MORE/PARTIAL set one of them
                        # else TRUE
                        found = q
                    if seen is not None:
                        # only show each entity once
                        if e_str in seen:
                            continue
                        seen.add(e_str)
                    print(f'{file1}:{e}')
        return found

    def search_taset(self, seen: Optional[set[str]] = None) -> bool:
        found = False
        for r in self.tasets:
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
        rset: set[str] = set()
        for rules in self.filtered.values():
            for e in rules:
                if e[0] == 'typeattributeset':
                    taset = self.create_taset(e)
                    rset.update(set(self.resolve_typeattributeset(taset)))
        for attr in sorted(rset):
            print(f'{attr}')

    def match_type_enforcement_rule(self, rule: TERule) -> bool:
        if self.args.type is not None and rule.type != self.args.type:
            return False
        if self.args.source is not None and rule.source not in self.vargs['source']:
            return False
        if self.args.target is not None and rule.target not in self.vargs['target']:
            return False
        if self.oargs['class'] is not None and rule.klass != self.oargs['class']:
            return False
        if self.args.perm is not None and self.args.perm not in rule.perms:
            return False
        if self.args.not_target is not None and rule.target in self.args.not_target:
            return False
        if self.args.not_source is not None and rule.source in self.args.not_source:
            return False
        return True

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

    def resolve_typeattributeset(self, taset: TASet) -> list[str]:
        if taset.is_logical:
            return []
        result: list[str] = []
        if self.args.source is None:
            result.append(taset.type)
        elif self.args.source != taset.type:
            return []
        if self.args.target is None:
            result.extend(taset.attrs)
        elif self.args.target not in taset.attrs:
            return []
        return result


def main() -> None:
    parser = argparse.ArgumentParser(description='Parse and search cil files')
    parser.add_argument('files', metavar='FILES', type=str, nargs='+')
    type_group = parser.add_mutually_exclusive_group()
    type_group.add_argument('--type', choices=type_enforcement_rule_types)
    type_group.add_argument('--attr', action='store_true')
    type_group.add_argument('--resolveattr', action='store_true')
    parser.add_argument('--source', type=str)
    parser.add_argument('--not-source', type=str)
    parser.add_argument('--target', type=str)
    parser.add_argument('--not-target', type=str)
    parser.add_argument('--class', type=str)
    parser.add_argument('--perm', type=str)
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
