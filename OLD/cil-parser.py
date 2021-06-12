#!/usr/bin/python3

import sys

import parsimonious
from parsimonious.grammar import Grammar

grammar = Grammar(
    r"""
    exprs = ( expr )+
    expr = lpar ( e_roleattribute / e_roleattributeset / e_roletype
                / e_typeattribute / e_typeattributeset
                / e_user
                / e_userrole / e_userlevel / e_userrange
                / e_selinuxuser
                / e_selinuxuserdefault
                / e_userprefix
                / e_role
                / e_type
                / e_sensitivityorder / e_sensitivitycategory / e_sensitivity
                / e_categoryorder / e_category
                / e_handleunknown
                / e_mlsconstrain
                / e_mls / e_policycap
                / e_sidorder / e_sidcontext / e_sid
                / e_typealias / e_typealiasactual / e_typemember
                / e_roleallow
                / e_allow / e_dontaudit / e_auditallow / e_neverallow / e_allowx
                / e_typetransition / e_rangetransition / e_roletransition
                / e_typechange
                / e_filecon / e_genfscon / e_portcon
                / e_fsuse
                / e_common
                / e_classorder / e_classcommon / e_class
                / e_defaultrange
                / e_booleanif
                / e_boolean
                / e_optional
                ) rpar

    e_roleattribute = "roleattribute" spc roleattribute
    e_roletype = "roletype" spc role_attr_type spc role_attr_type

    e_roleattributeset = e_roleattributeset_require / e_roleattributeset_value
    e_roleattributeset_require = "roleattributeset" spc "cil_gen_require" spc role_attr_type
    e_roleattributeset_value = "roleattributeset" spc roleattribute spc valuelist

    e_typeattribute = "typeattribute" spc typeattribute
    e_typealias = "typealias" spc typealias
    e_typealiasactual = "typealiasactual" spc typealias spc type
    e_typemember = "typemember" spc typeattribute spc type spc class spc type

    e_user = "user" spc user _
    e_role = "role" spc role _
    e_type = "type" spc type _

    e_userrole = "userrole" spc user spc role
    e_userlevel = "userlevel" spc user lpar sensitivity_term rpar
    e_userrange = "userrange" spc user spc range
    e_selinuxuser = "selinuxuser" spc "root" spc user spc selinuxuser_range
    e_selinuxuserdefault = "selinuxuserdefault" spc user spc selinuxuser_range
    e_userprefix = "userprefix" spc user spc "user"

    e_handleunknown = "handleunknown" spc ("allow")
    e_mls = "mls" spc bool
    e_policycap = "policycap" spc policycap

    e_sid = "sid" spc sid
    e_sidorder = "sidorder" spc valuelist
    e_sidcontext = "sidcontext" spc sid spc context

    e_typeattributeset = e_typeattributeset_require / e_typeattributeset_value
    e_typeattributeset_require = "typeattributeset" spc "cil_gen_require" spc typeattribute
    e_typeattributeset_value = "typeattributeset" spc typeattribute spc ( logic_expr / valuelist )

    e_roleallow = "roleallow" spc role spc role

    e_allow = "allow" spc typeattribute spc typeattribute spc class_perm
    e_dontaudit = "dontaudit" spc typeattribute spc typeattribute spc class_perm
    e_auditallow = "auditallow" spc typeattribute spc typeattribute spc class_perm
    e_neverallow = "neverallow" spc typeattribute spc typeattribute spc class_perm
    e_allowx = "allowx" spc type spc type spc xclass_perm

    e_typetransition = "typetransition" spc typeattribute spc typeattribute spc class spc ( quoted_string spc )? typeattribute
    e_rangetransition = "rangetransition" spc typeattribute spc typeattribute spc class spc range
    e_roletransition = "roletransition" spc role spc typeattribute spc class spc role
    e_typechange = "typechange" spc typeattribute spc typeattribute spc class spc type

    e_filecon = "filecon" spc quoted_string spc typeattribute spc ( context / ( lpar rpar ) )
    e_portcon = "portcon" spc proto_term spc port_term context

    e_sensitivity = "sensitivity" spc sensitivity_term
    e_sensitivitycategory = "sensitivitycategory" spc sensitivity lpar category ( spc category)+ rpar
    e_sensitivityorder = "sensitivityorder" lpar sensitivity_term+ rpar
    e_category = "category" spc category
    e_categoryorder = "categoryorder" lpar category_term+ rpar

    e_fsuse = "fsuse" spc ( "trans" / "task" / "xattr" ) spc fs_type spc context
    e_genfscon = "genfscon" spc fs_type spc fs_path context
    e_common = "common" spc class spc valuelist
    e_class = "class" spc class spc valuelist_empty
    e_classcommon = "classcommon" spc class spc class
    e_classorder = "classorder" spc valuelist
    e_defaultrange = "defaultrange" spc class spc "target" spc "low"
    e_mlsconstrain = "mlsconstrain" lpar class spc valuelist rpar logic_expr

    e_booleanif = "booleanif" spc logic_expr lpar bool exprs rpar (lpar bool exprs rpar)? _

    e_boolean = "boolean" spc name spc bool
    e_optional = "optional" spc name exprs

    name = symbol ~r"(?!_[urt])"

    simple_expr = symbol
    simple_list_expr = symbol ( spc symbol )*
    eq_expr = "eq" spc symbol spc symbol
    neq_expr = "neq" spc symbol spc symbol
    dom_expr = "dom" spc symbol spc symbol
    domby_expr = "domby" spc symbol spc symbol
    not_expr = "not" spc logic_list_expr
    and_expr = "and" spc logic_expr logic_expr+
    or_expr = "or" spc logic_expr logic_expr+
    logic_list_expr = lpar ( eq_expr / neq_expr / domby_expr / dom_expr / and_expr / or_expr / not_expr / simple_list_expr ) rpar
    logic_expr = lpar ( eq_expr / neq_expr / domby_expr / dom_expr / and_expr / or_expr / not_expr / simple_expr ) rpar

    class_perm =  lpar class spc permlist rpar
    xclass_perm = lpar "ioctl" spc class spc hex_number_list rpar

    hex_number_list = lpar hex_number ( spc hex_number )* rpar

    context = lpar user spc role spc type range rpar

    port_list = lpar port_number (spc port_number)+ rpar
    port_number = ~r"(\d|[1-9]\d{1,3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d\d|655[0-2]\d|6553[0-5])(?!\d)"
    port_term = port_number / port_list

    proto_term = "tcp" / "udp" / "sctp"

    fs_type = symbol
    fs_path = ~r"[/\w]+"

    value = symbol
    value_term = value _
    valuelist = lpar ( ( value_term value_term+ ) / value_term ) rpar
    valuelist_empty = valuelist / ( lpar rpar )

    permlist = valuelist
    permlist_real = lpar perm ( spc perm ) rpar

    user = ~r"\w+_u" / "root"
    role = ~r"\w+_r"
    type = ~r"\w+_t"

    roleattribute = symbol
    typeattribute = symbol
    policycap = symbol
    sid = symbol
    typealias = symbol

    role_attr_type = symbol

    class = symbol
    perm = symbol

    sensitivity = "s0"
    sensitivity_term = sensitivity _

    category = ~r"c(\d|[1-9]\d{1,2}|10[01]\d|102[0-3])(?!\d)"
    category_term = category _
    category_pair = lpar "range" spc category spc category rpar
    selinuxuser_category_pair = lpar lpar "range" spc category spc category rpar rpar

    range_item = sensitivity_term category_pair?
    selinuxuser_range_item = sensitivity_term selinuxuser_category_pair

    range = lpar lpar range_item rpar lpar range_item rpar rpar
    selinuxuser_range = lpar lpar sensitivity_term rpar lpar sensitivity_term selinuxuser_category_pair rpar rpar

    list = lpar entries rpar
    entries = ( ws? entry )* ws?

    bool = "true" / "false"

    entry = ( symbol / quoted_string / list )

    symbol = ~r"[-\w]+"
    quoted_string = ~'"[^\"]*"'
    number = ~r"\d+"
    hex_number = ~r"0x[0-9a-f]+"
    meaningless = ws / comment
    _ = meaningless*
    ws = ~r"\s+"
    comment = ~r"#[^\r\n]*"
    spc = " "
    lpar = _ "(" _
    rpar = _ ")" _
    """)


class CilParser(parsimonious.NodeVisitor):
    def visit_expr(self, node, visited_children):
        print(node)
        print(visited_children)
        output = {}
        # for child in visited_children:
        #     output.update(child[0])
        return output

    def visit_e_allow(self, node, visited_children):
        print(node)
        print(visited_children)
        output = {}
        # for child in visited_children:
        #     output.update(child[0])
        return output

    def generic_visit(self, node, visited_children):
        # print(node)
        # print(visited_children)
        return {}


cilp = CilParser()

for file1 in sys.argv[1:]:
    print(f"# {file1}")
    with open(file1, 'r') as fd:
        tree = grammar.parse(fd.read())
        # print(cilp.visit(tree))
        print(tree)
