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
    type: str
    source: str
    target: str
    klass: str
    perms: list[str] = field(default_factory=list)


# type attribute set
@dataclass
class TASet:
    type: str
    attrs: list[str] = field(default_factory=list)
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
        self.to_search: Optional[ParsedCil] = None

    def update_args(self) -> None:
        self.oargs = vars(self.args)
        self.vargs: Dict[str, Set[str]] = defaultdict(set)
        for key in (
            'source',
            'target',
            'not_source',
            'not_target',
            'perm',
        ):
            if self.oargs[key] is not None:
                assert isinstance(self.oargs[key], str)
                val: str = self.oargs[key]
                self.vargs[key] = set()
                self.vargs[key].add(val)

    @staticmethod
    def get_typeattributeset(
        e_attr: str, e_set: List[str], val: str, reverse: bool
    ) -> List[str]:
        if reverse and val == e_attr:
            return e_set
        elif val in e_set:
            return [e_attr]
        return []

    @staticmethod
    def file_nt(f1: str, f2: str) -> bool:
        if os.path.exists(f2):
            return bool(os.path.getmtime(f1) < os.path.getmtime(f2))
        return False

    def load(self) -> None:
        file1: str

        from_file = self.oargs['from']
        if from_file is not None:
            tree = grammar.parse(from_file.read())
            to_search = cilp.visit(tree)
            self.to_search = self.handle_file(to_search)

        for file1 in self.args.files:
            queue = []
            # It is way faster to load json than parse cil
            if self.file_nt(file1, f'{file1}.json'):
                with open(f'{file1}.json', 'r') as fd:
                    queue.extend(json.load(fd))
            else:
                print(f'# {file1}')
                with open(file1, 'r') as fd:
                    tree = grammar.parse(fd.read())
                    queue = cilp.visit(tree)
                    with open(f'{file1}.json.tmp', 'w') as out:
                        json.dump(queue, out)
                    os.replace(f'{file1}.json.tmp', f'{file1}.json')
            self.filtered[file1].extend(self.handle_file(queue))

    def handle_file(self, queue: List[Any]) -> ParsedCil:
        seen: set[str] = set()
        result: ParsedCil = []

        # First recurse and filter unique only
        # Also collect attrs data
        while queue:
            e = queue.pop(0)
            if e[0] == 'optional':
                queue.extend(e[2:])
                continue
            elif e[0] == 'booleanif':
                for b in e[2:]:
                    queue.extend(b[1:])
                continue
            elif e[0] == 'typeattributeset' and e[1] == 'cil_gen_require':
                continue
            elif e[0] == 'roleattributeset' and e[1] == 'cil_gen_require':
                continue

            if e[0] == 'typeattributeset':
                e_attr: str = e[1]
                e_set: List[str] = e[2]
                for key in 'source', 'target':
                    if self.oargs[key] is not None:
                        self.vargs[key].update(
                            self.get_typeattributeset(
                                e_attr,
                                e_set,
                                self.oargs[key],
                                self.oargs[f'reverse_{key}'],
                            )
                        )
                    not_key = f'not_{key}'
                    if self.oargs[not_key] is not None:
                        self.vargs[not_key].update(
                            self.get_typeattributeset(
                                e_attr,
                                e_set,
                                self.oargs[not_key],
                                self.oargs[f'reverse_{key}'],
                            )
                        )

            # only show each entity once
            e_str = str(e)
            if e_str in seen:
                continue
            seen.add(e_str)
            result.append(e)
        return result

    @staticmethod
    def create_terule(e: List[Union[str, List[Any]]]) -> TERule:
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
        return TERule(e[0], e[1], e[2], e[3][0], e[3][1])

    @staticmethod
    def create_taset(e: List[Union[str, List[Any]]]) -> TASet:
        assert isinstance(e, list)
        assert len(e) == 3
        assert isinstance(e[0], str)
        assert isinstance(e[1], str)
        assert isinstance(e[2], list)
        if e[2][0] in ('and', 'not', 'or'):
            return TASet(e[1], [], True)
        for _ in e[2]:
            assert isinstance(_, str)
        return TASet(e[1], e[2])

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
        else:
            return Typetransition(e[1], e[2], e[3], e[4])

    def search(self) -> None:
        if self.to_search is not None:
            self.search_from()
        elif self.args.resolveattr:
            self.search_resolveattr()
        elif self.args.attr:
            self.search_taset()
        else:
            self.search_terule()

    def search_from(self) -> None:
        assert self.to_search is not None
        for e in self.to_search:
            seen: set[str] = set()
            assert isinstance(e[0], str)
            if e[0] in type_enforcement_rule_types:
                r: TERule = self.create_terule(e)
                self.oargs['type'] = r.type
                self.oargs['source'] = r.source
                self.oargs['target'] = r.target
                self.oargs['class'] = r.klass
                got_all = True
                got_any = False
                missing_perms = []
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
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] in type_enforcement_rule_types:
                    rule = self.create_terule(e)
                    if not self.match_type_enforcement_rule(rule):
                        continue
                    found = True
                    if seen is not None:
                        # only show each entity once
                        e_str = str(e)
                        if e_str in seen:
                            continue
                        seen.add(e_str)
                    print(f'{file1}:{e}')
        return found

    def search_typetransition(self, seen: Optional[set[str]] = None) -> Quad:
        found = Quad.FALSE
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] == 'typetransition':
                    r = self.create_typetransition(e)
                    q = self.match_typetransition(r)
                    if q == Quad.FALSE:
                        continue
                    if found in (Quad.FALSE, Quad.TRUE):
                        # if MORE/PARTIAL set one of them
                        # else TRUE
                        found = q
                    if seen is not None:
                        # only show each entity once
                        e_str = str(e)
                        if e_str in seen:
                            continue
                        seen.add(e_str)
                    print(f'{file1}:{e}')
        return found

    def search_taset(self, seen: Optional[set[str]] = None) -> bool:
        found = False
        for file1, rules in self.filtered.items():
            for e in rules:
                if e[0] == 'typeattributeset':
                    taset = self.create_taset(e)
                    if not self.match_typeattributeset(taset):
                        continue
                    found = True
                    if seen is not None:
                        # only show each entity once
                        e_str = str(e)
                        if e_str in seen:
                            continue
                        seen.add(e_str)
                    print(f'{file1}:{e}')
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
            elif self.oargs['filename'] != r.filename:
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
    cs.search()


if __name__ == '__main__':
    main()
