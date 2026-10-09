"""Preserve pinned execution recovery SQL while replacing cross-namespace PID probes."""

import ast
import copy
import hashlib
from pathlib import Path


SOURCE_SHA256 = "75e15a1be8aaacb6303c3a5fe9916aa41b6a89a5352bc74f0acf2d296a70b19c"


class OwnerCalls(ast.NodeTransformer):
    def __init__(self):
        self.replaced = 0

    def visit_Call(self, node):
        node = self.generic_visit(node)
        if not isinstance(node.func, ast.Name) or node.func.id != "_owner_is_live":
            return node
        records = {part.value.id for argument in node.args for part in ast.walk(argument)
                   if isinstance(part, ast.Subscript) and isinstance(part.value, ast.Name)}
        if len(records) != 1:
            raise ValueError("Pinned execution owner-call shape changed")
        self.replaced += 1
        return ast.copy_location(ast.Call(func=ast.Name(id="_sandbox_owner_is_live", ctx=ast.Load()),
                                          args=[ast.Name(id=records.pop(), ctx=ast.Load())], keywords=[]), node)


def broker_owner_functions(module, owner_alive):
    source = Path(module.__file__).read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("Execution recovery source differs from the pinned contract")
    tree = ast.parse(source, filename=module.__file__)
    replacements = {}
    for function in tree.body:
        if not isinstance(function, ast.FunctionDef):
            continue
        copied = copy.deepcopy(function)
        transform = OwnerCalls()
        transform.visit(copied)
        if not transform.replaced:
            continue
        namespace = dict(module.__dict__)
        namespace["_sandbox_owner_is_live"] = owner_alive
        wrapper = ast.fix_missing_locations(ast.Module(body=[copied], type_ignores=[]))
        exec(compile(wrapper, module.__file__, "exec"), namespace)
        replacements[function.name] = namespace[function.name]
    if not {"recover_interrupted_executions", "terminalize_dead_owner", "live_inflight_execution"} <= set(replacements):
        raise ValueError("Pinned execution recovery entry points changed")
    return replacements
