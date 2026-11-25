"""Pure parsing shared by the importer and isolated upstream audit."""
import ast
import operator
import re


def integer(text):
    text = re.sub(r"(?<=\d)[uUlL]+", "", text.strip())
    operations = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.LShift: operator.lshift, ast.RShift: operator.rshift}
    def visit(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int): return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in operations: return operations[type(node.op)](visit(node.left), visit(node.right))
        raise ValueError(text)
    return visit(ast.parse(text, mode="eval").body)
