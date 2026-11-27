#!/usr/bin/env python3
# Writes the AI model catalog, schema 1: the model facts the apps take when a provider's own model list leaves them
# out, trimmed from the models.dev v2 catalog (MIT). ai-models.yml runs it nightly and publishes the result to
# https://updates.tablepro.app/ai/models-v1.json; core/crates/ai/ai-models.json is the copy every app bundles.
#
#   python3 -I scripts/ai-models/generate.py --previous core/crates/ai/ai-models.json \
#       --output core/crates/ai/ai-models.json
#
# It writes nothing and exits 1 when the source changed shape or when the result drops what --previous listed.

import argparse
import datetime
import json
import os
import re
import sys
import tempfile
import urllib.request

SOURCE_URL = "https://models.dev/experimental/v2.0/api.json?include=openai-codex"
CODEX_RELEASE_URL = "https://api.github.com/repos/openai/codex/releases/latest"
SCHEMA = 1
PROVIDERS = ("anthropic", "openai", "openai-codex", "google", "xai", "meta")
# The order the schema lists them in, which each model's `apis` keeps.
CHAT_APIS = ("responses", "chat-completions", "messages", "generate-content")
STATUSES = ("alpha", "beta", "deprecated")
DEFAULT_TYPES = ("effort", "toggle")
MAX_COUNT_DROP = 3
# TablePro's Gemini provider sends no thinking configuration, so listed levels would change nothing.
NO_EFFORTS = ("google",)

DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
# models.dev dates some models to the month only; the schema has no place for that.
MONTH = re.compile(r"[0-9]{4}-[0-9]{2}")
EFFORT = re.compile(r"[a-z][a-z0-9_-]*")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
CODEX_TAG = re.compile(r"rust-v([0-9]+\.[0-9]+\.[0-9]+)")

# The first default for a provider the previous file does not list; after that the previous file's default stays.
SOL = re.compile(r"gpt-[0-9]+(?:\.[0-9]+)?-sol")
DEFAULT_RULES = {
    "anthropic": re.compile(r"claude-opus-5-5"),
    "openai": SOL,
    "openai-codex": SOL,
    "google": re.compile(r"gemini-[0-9]+(?:\.[0-9]+)?-(?:pro|flash)"),
    "xai": re.compile(r"grok-[0-9]+(?:\.[0-9]+)?"),
    "meta": re.compile(r"muse-spark-1\.3"),
}


class CatalogError(Exception):
    pass


def typed(value, kind, where):
    if not isinstance(value, kind) or (isinstance(value, bool) and kind is int):
        raise CatalogError(f"{where}: expected {kind.__name__}, found {type(value).__name__}")
    return value


def optional(container, key, kind, where):
    if key not in container:
        return None
    return typed(container[key], kind, f"{where}.{key}")


def chat_apis(model, where):
    api = typed(model.get("api"), dict, f"{where}.api")
    return [name for name in CHAT_APIS if name in api]


def reasoning(provider, capabilities, where):
    raw = typed(capabilities.get("reasoning"), dict, f"{where}.capabilities.reasoning")
    where = f"{where}.capabilities.reasoning"
    supported = typed(raw.get("supported"), bool, f"{where}.supported")
    efforts = optional(raw, "effort", list, where) or []
    for index, effort in enumerate(efforts):
        if not isinstance(effort, str) or not EFFORT.fullmatch(effort):
            raise CatalogError(f"{where}.effort[{index}]: {effort!r} is not an effort name")
    toggle = optional(raw, "toggle", bool, where)
    budget = optional(raw, "budget", dict, where)
    if budget is not None:
        budget_min = typed(budget.get("min"), int, f"{where}.budget.min")
        if budget_min < 0:
            raise CatalogError(f"{where}.budget.min: {budget_min} is negative")
    default = optional(raw, "default", dict, where)
    default_effort = None
    if default is not None:
        kind = typed(default.get("type"), str, f"{where}.default.type")
        if kind not in DEFAULT_TYPES:
            raise CatalogError(f"{where}.default.type: {kind!r} is none of {', '.join(DEFAULT_TYPES)}")
        if kind == "effort":
            default_effort = typed(default.get("value"), str, f"{where}.default.value")
        else:
            typed(default.get("value"), bool, f"{where}.default.value")
    if not supported:
        return None

    levels = [effort for effort in efforts if effort != "none"]
    result = {}
    if levels and provider not in NO_EFFORTS:
        result["efforts"] = levels
    if toggle or "none" in efforts:
        result["toggle"] = True
    if budget is not None:
        result["budget_min"] = budget["min"]
    # A default the model does not list would be sent and refused.
    if default_effort is not None and default_effort != "none" and (not efforts or default_effort in levels):
        result["default"] = default_effort
    return result


def entry(provider, model_id, model, apis):
    where = f"{provider}/{model_id}"
    name = typed(model.get("name"), str, f"{where}.name")
    if not name.strip():
        raise CatalogError(f"{where}.name: empty")
    result = {"id": model_id, "name": name, "apis": apis}

    released = optional(model, "release_date", str, where)
    if released is not None:
        if DATE.fullmatch(released):
            result["released"] = released
        elif not MONTH.fullmatch(released):
            raise CatalogError(f"{where}.release_date: {released!r} is not YYYY-MM-DD or YYYY-MM")

    status = optional(model, "status", str, where)
    if status is not None and status not in STATUSES:
        raise CatalogError(f"{where}.status: {status!r} is none of {', '.join(STATUSES)}")
    if status == "deprecated":
        result["deprecated"] = True

    limit = optional(model, "limit", dict, where)
    if limit is not None:
        output = optional(limit, "output", int, f"{where}.limit")
        if output:
            result["output"] = output

    modalities = optional(model, "modalities", dict, where)
    if modalities is not None and "input" in modalities:
        inputs = typed(modalities["input"], list, f"{where}.modalities.input")
        for index, kind in enumerate(inputs):
            typed(kind, str, f"{where}.modalities.input[{index}]")
        result["images"] = any(kind == "image" or kind.startswith("image/") for kind in inputs)

    capabilities = typed(model.get("capabilities"), dict, f"{where}.capabilities")
    thinking = reasoning(provider, capabilities, where)
    if thinking is not None:
        result["reasoning"] = thinking
    return result


def provider_models(source, provider):
    if provider not in source:
        raise CatalogError(f"the source has no {provider} provider")
    raw = typed(source[provider], dict, provider)
    models = typed(raw.get("models"), dict, f"{provider}.models")
    if not models:
        raise CatalogError(f"{provider}.models: empty")
    result = []
    for model_id, model in models.items():
        where = f"{provider}/{model_id}"
        typed(model, dict, where)
        if model.get("id") != model_id:
            raise CatalogError(f"{where}.id: {model.get('id')!r} differs from its key")
        kind = optional(model, "type", str, where)
        apis = chat_apis(model, where)
        if kind not in (None, "chat") or not apis:
            continue
        result.append(entry(provider, model_id, model, apis))
    if not result:
        raise CatalogError(f"{provider}: no chat model left")
    return sorted(result, key=lambda model: model["id"])


def newest(models):
    return max(models, key=lambda model: (model.get("released", ""), model["id"]))["id"]


def initial_default(provider, models):
    usable = [model for model in models if not model.get("deprecated")]
    if provider in ("openai", "openai-codex"):
        usable = [model for model in usable if "responses" in model["apis"]]
    rule = DEFAULT_RULES[provider]
    picked = [model for model in usable if rule.fullmatch(model["id"])]
    if picked:
        return newest(picked)
    if usable:
        return newest(usable)
    raise CatalogError(f"{provider}: no model to make the default")


def read_previous(path):
    try:
        with open(path, encoding="utf-8") as file:
            previous = json.load(file)
    except (OSError, ValueError) as error:
        raise CatalogError(f"could not read the previous catalog {path}: {error}") from error
    where = f"previous catalog {path}"
    typed(previous, dict, where)
    if previous.get("schema") != SCHEMA:
        raise CatalogError(f"{where}: schema {previous.get('schema')!r}, not {SCHEMA}")
    typed(previous.get("generated"), str, f"{where}: generated")
    providers = typed(previous.get("providers"), dict, f"{where}: providers")
    for key, provider in providers.items():
        typed(provider, dict, f"{where}: {key}")
        typed(provider.get("default"), str, f"{where}: {key}.default")
        for index, model in enumerate(typed(provider.get("models"), list, f"{where}: {key}.models")):
            typed(typed(model, dict, f"{where}: {key}.models[{index}]").get("id"), str,
                  f"{where}: {key}.models[{index}].id")
    return previous


def problems(previous, catalog, allow_removals):
    found = []
    if previous is not None and not allow_removals:
        for key, old in sorted(previous["providers"].items()):
            new = catalog["providers"].get(key)
            if new is None:
                found.append(f"{key}: the provider is gone")
                continue
            listed = {model["id"] for model in new["models"]}
            for model in old["models"]:
                if model["id"] not in listed and model.get("deprecated") is not True:
                    found.append(f"{key}/{model['id']}: gone without being marked deprecated first")
            if len(old["models"]) - len(listed) > MAX_COUNT_DROP:
                found.append(f"{key}: {len(old['models'])} models down to {len(listed)}, "
                             f"more than {MAX_COUNT_DROP} fewer")
    for key, provider in sorted(catalog["providers"].items()):
        default = next((model for model in provider["models"] if model["id"] == provider["default"]), None)
        if default is None:
            found.append(f"{key}: the default {provider['default']} is not listed")
        elif default.get("deprecated"):
            found.append(f"{key}: the default {provider['default']} is deprecated")
    return found


def build(source, client_version, previous=None, now=None, allow_removals=False):
    typed(source, dict, "the source")
    providers = {}
    for key in PROVIDERS:
        models = provider_models(source, key)
        old = (previous or {}).get("providers", {}).get(key)
        provider = {"default": old["default"] if old else initial_default(key, models), "models": models}
        if key == "openai-codex":
            provider["client_version"] = client_version
        providers[key] = provider
    catalog = {"schema": SCHEMA, "providers": providers}

    found = problems(previous, catalog, allow_removals)
    if found:
        raise CatalogError("refusing to write the catalog:\n" + "\n".join(f"  {line}" for line in found)
                           + "\nOnce a person has checked these, regenerate core/crates/ai/ai-models.json with"
                           " --allow-removals (or edit its defaults) and commit it; the push publishes it.")

    unchanged = previous is not None and {k: v for k, v in previous.items() if k != "generated"} == catalog
    if unchanged:
        catalog["generated"] = previous["generated"]
    else:
        moment = now or datetime.datetime.now(datetime.timezone.utc)
        catalog["generated"] = moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return catalog


def render(catalog):
    return json.dumps(catalog, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def fetch(url, accept="application/json", token=None):
    headers = {"Accept": accept, "User-Agent": "ai-models-generate"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
            return json.loads(response.read())
    except (OSError, ValueError) as error:
        raise CatalogError(f"could not read {url}: {error}") from error


def codex_version_of(release):
    tag = typed(release, dict, "the openai/codex release").get("tag_name")
    match = CODEX_TAG.fullmatch(tag) if isinstance(tag, str) else None
    if not match:
        raise CatalogError(f"the openai/codex release tag {tag!r} is not rust-vX.Y.Z")
    return match.group(1)


def codex_version(explicit):
    if explicit is not None:
        if not VERSION.fullmatch(explicit):
            raise CatalogError(f"--codex-version {explicit!r} is not X.Y.Z")
        return explicit
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    return codex_version_of(fetch(CODEX_RELEASE_URL, accept="application/vnd.github+json", token=token))


def load_source(path):
    if path is None:
        return fetch(SOURCE_URL)
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError) as error:
        raise CatalogError(f"could not read {path}: {error}") from error


def write(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".ai-models-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as file:
            file.write(text)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def parse(argv):
    parser = argparse.ArgumentParser(description="Write the AI model catalog from models.dev.")
    parser.add_argument("--output", required=True, help="where to write the catalog")
    parser.add_argument("--source", help="a saved models.dev v2 api.json instead of fetching it")
    parser.add_argument("--codex-version", help="the Codex client version instead of the latest openai/codex release")
    parser.add_argument("--previous", help="the catalog published or committed now: defaults and guards come from it")
    parser.add_argument("--allow-removals", action="store_true",
                        help="drop ids and providers the previous catalog listed, after a person has checked them")
    return parser.parse_args(argv)


def main(argv=None, now=None):
    args = parse(argv)
    try:
        previous = read_previous(args.previous) if args.previous else None
        source = load_source(args.source)
        version = codex_version(args.codex_version)
        catalog = build(source, version, previous, now, args.allow_removals)
    except CatalogError as error:
        print(f"generate.py: {error}", file=sys.stderr)
        return 1
    write(args.output, render(catalog))
    return 0


if __name__ == "__main__":
    sys.exit(main())
