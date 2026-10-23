#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, FrozenSet, List, NamedTuple, Optional, Set, Tuple

TOKEN = re.compile(r'\s+|//[^\n]*|--[^\n]*|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*|[(),;<>]|\S')
INDEXES = {"QUERYABLE", "SEARCHABLE", "SORTABLE"}
PERMISSIONS = {"READ", "CREATE", "WRITE"}


class SchemaError(Exception):
    pass


class Field(NamedTuple):
    type: str
    indexes: FrozenSet[str]


class RecordType(NamedTuple):
    fields: Dict[str, Field]
    grants: Set[Tuple[str, str]]


class Schema(NamedTuple):
    roles: Set[str]
    types: Dict[str, RecordType]


class Tokens:
    def __init__(self, text: str):
        self.items = [token for token in TOKEN.findall(text)
                      if not token.isspace() and not token.startswith(("//", "--"))]
        self.position = 0

    def peek(self) -> str:
        return self.items[self.position] if self.position < len(self.items) else ""

    def take(self) -> str:
        token = self.peek()
        if not token:
            raise SchemaError("the schema ends early")
        self.position += 1
        return token

    def keyword(self) -> str:
        return self.take().upper()

    def expect(self, *words: str) -> None:
        for word in words:
            token = self.take()
            if token.upper() != word:
                raise SchemaError(f"expected {word}, got {token}")

    def name(self) -> str:
        token = self.take()
        if token.startswith('"'):
            return token[1:-1]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
            raise SchemaError(f"expected a name, got {token}")
        return token


def parse(text: str) -> Schema:
    tokens = Tokens(text)
    tokens.expect("DEFINE", "SCHEMA")
    schema = Schema(set(), {})
    while tokens.peek():
        word = tokens.keyword()
        if word == ";":
            continue
        if word == "CREATE":
            tokens.expect("ROLE")
            schema.roles.add(tokens.name())
        elif word == "RECORD":
            tokens.expect("TYPE")
            name = tokens.name()
            if name in schema.types:
                raise SchemaError(f"record type {name} is defined twice")
            schema.types[name] = record_type(tokens, name)
        else:
            raise SchemaError(f"expected CREATE ROLE or RECORD TYPE, got {word}")
    return schema


def record_type(tokens: Tokens, name: str) -> RecordType:
    tokens.expect("(")
    record = RecordType({}, set())
    while True:
        if tokens.peek().upper() == "GRANT":
            tokens.take()
            permissions = [tokens.keyword()]
            while tokens.peek() == ",":
                tokens.take()
                permissions.append(tokens.keyword())
            unknown = [permission for permission in permissions if permission not in PERMISSIONS]
            if unknown:
                raise SchemaError(f"{name}: unknown permission {unknown[0]}")
            tokens.expect("TO")
            role = tokens.name()
            record.grants.update((permission, role) for permission in permissions)
        else:
            field = tokens.name()
            if field in record.fields:
                raise SchemaError(f"{name}.{field} is defined twice")
            kind = data_type(tokens)
            indexes = set()
            while tokens.peek() not in (",", ")"):
                index = tokens.keyword()
                if index not in INDEXES:
                    raise SchemaError(f"{name}.{field}: expected an index, got {index}")
                indexes.add(index)
            record.fields[field] = Field(kind, frozenset(indexes))
        separator = tokens.take()
        if separator == ")":
            return record
        if separator != ",":
            raise SchemaError(f"{name}: expected , or ), got {separator}")


def data_type(tokens: Tokens) -> str:
    word = tokens.keyword()
    if word == "LIST":
        tokens.expect("<")
        element = data_type(tokens)
        tokens.expect(">")
        return f"LIST<{element}>"
    if word == "ENCRYPTED":
        return f"ENCRYPTED {tokens.keyword()}"
    if word == "NUMBER" and tokens.peek().upper() == "PREFERRED":
        tokens.take()
        tokens.expect("AS")
        return f"NUMBER PREFERRED AS {tokens.keyword()}"
    return word


# Production only grows: a type, field, index or grant it has and the snapshot lacks is never read by
# the build that holds the snapshot, so only the snapshot's side is checked.
def gaps(snapshot: Schema, production: Schema) -> List[str]:
    found = [f"role {role}: not in production" for role in sorted(snapshot.roles - production.roles)]
    for name, record in snapshot.types.items():
        deployed = production.types.get(name)
        if deployed is None:
            found.append(f"record type {name}: not in production")
            continue
        for field, wanted in record.fields.items():
            live = deployed.fields.get(field)
            if live is None:
                found.append(f"{name}.{field}: not in production")
            elif live.type != wanted.type:
                found.append(f"{name}.{field}: {wanted.type} in the snapshot, {live.type} in production")
            elif not wanted.indexes <= live.indexes:
                missing = ", ".join(sorted(wanted.indexes - live.indexes))
                found.append(f"{name}.{field}: {missing} not in production")
        for permission, role in sorted(record.grants - deployed.grants):
            found.append(f"{name}: GRANT {permission} TO {role} not in production")
    return found


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Compare CloudKit schema files as cktool export-schema writes them.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("covers", help="list what the snapshot declares and production lacks")
    command.add_argument("snapshot", type=Path)
    command.add_argument("production", type=Path)
    args = parser.parse_args(argv)

    try:
        snapshot = parse(args.snapshot.read_text(encoding="utf-8"))
        production = parse(args.production.read_text(encoding="utf-8"))
    except (SchemaError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    found = gaps(snapshot, production)
    for gap in found:
        print(gap, file=sys.stderr)
    if found:
        return 1
    print(f"production has every record type, field, index, role and grant in {args.snapshot.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
