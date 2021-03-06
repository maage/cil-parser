# SPDX-FileCopyrightText: 2021 Erik Rose
#
# SPDX-License-Identifier: MIT

from parsimonious.exceptions import UndefinedLabel as UndefinedLabel, VisitationError as VisitationError
from parsimonious.expressions import Expression
from parsimonious.grammar import Grammar

from typing import (
    Any,
    Callable,
    Iterator,
    List,
    NoReturn,
    Optional,
    Text,
)


class Node:
    expr: Expression = ...
    full_text: Text = ...
    start: int = ...
    end: int = ...
    children: List[Node] = ...
    def __init__(self, expr: Expression, full_text: Text, start: int, end: int, children: Optional[List[Node]] = ...) -> None: ...
    @property
    def expr_name(self) -> Text: ...
    def __iter__(self) -> Iterator[Node]: ...
    @property
    def text(self) -> Text: ...
    def prettily(self, error: Optional[Node] = ...) -> Text: ...
    def __eq__(self, other: Any) -> bool: ...
    def __ne__(self, other: Any) -> bool: ...

class RegexNode(Node): ...

class RuleDecoratorMeta(type):
    def __new__(metaclass: Any, name: Any, bases: Any, namespace: Any) -> RuleDecoratorMeta: ...

class NodeVisitor:
    grammar: Grammar = ...
    unwrapped_exceptions: Any = ...
    def visit(self, node: Node) -> Any: ...
    def generic_visit(self, node: Node, visited_children: Optional[List[Node]]) -> Any: ...
    def parse(self, text: Text, pos: int = ...) -> Node: ...
    def match(self, text: Text, pos: int = ...) -> Node: ...
    def lift_child(self, node: Node, children: List[Node]) -> Node: ...

def rule(rule_string: Text) -> Text: ...
