import contextlib
import copy
import datetime
import io
import json
import pathlib
import tempfile
import unittest

import generate

NOW = datetime.datetime(2026, 11, 24, 19, 17, tzinfo=datetime.timezone.utc)
LATER = datetime.datetime(2026, 11, 25, 19, 17, tzinfo=datetime.timezone.utc)


def model(model_id, apis=("responses",), kind="chat", released="2026-01-01", **fields):
    result = {
        "id": model_id,
        "name": model_id.upper(),
        "release_date": released,
        "modalities": {"input": ["text"], "output": ["text"]},
        "limit": {"context": 200000, "output": 64000},
        "capabilities": {"reasoning": {"supported": False}},
        "api": {name: {"base_url": "https://example.invalid"} for name in apis},
    }
    if kind is not None:
        result["type"] = kind
    result.update(fields)
    return result


def thinking(**fields):
    return {"reasoning": {"supported": True, **fields}}


def source(**providers):
    result = {
        "anthropic": [model("claude-opus-5-5", apis=("messages", "chat-completions"))],
        "openai": [model("gpt-6.2-sol", apis=("responses", "chat-completions"))],
        "openai-codex": [model("gpt-6.2-sol")],
        "google": [model("gemini-3.8-flash", apis=("generate-content",))],
        "xai": [model("grok-4.7", apis=("responses", "chat-completions"))],
        "meta": [model("muse-spark-1.3", apis=("responses", "messages"))],
        "deepseek": [model("deepseek-chat", apis=("chat-completions",))],
    }
    result.update(providers)
    return {key: {"id": key, "name": key, "models": {m["id"]: m for m in models}} for key, models in result.items()}


def build(data, previous=None, now=NOW, allow_removals=False):
    return generate.build(data, "0.172.0", previous, now, allow_removals)


def models(catalog, provider):
    return {m["id"]: m for m in catalog["providers"][provider]["models"]}


class FilterTests(unittest.TestCase):
    def test_keeps_chat_models_and_drops_embedding_speech_image_and_moderation(self):
        catalog = build(source(openai=[
            model("gpt-6.2-sol", apis=("responses", "chat-completions")),
            model("text-embedding-3-large", kind="embedding", apis=("embeddings",)),
            model("tts-1", kind="speech", apis=("speech",)),
            model("gpt-image-2", kind="image", apis=("images",)),
            model("gpt-realtime-2", kind="realtime", apis=("realtime",)),
            model("omni-moderation-latest", apis=("moderations",)),
            model("gpt-5-search-api", apis=("chat-completions",)),
            model("untyped", kind=None, apis=("responses",)),
        ]))
        self.assertEqual(sorted(models(catalog, "openai")), ["gpt-5-search-api", "gpt-6.2-sol", "untyped"])

    def test_keeps_only_the_chat_apis_in_schema_order(self):
        catalog = build(source(google=[
            model("gemini-3.8-flash", apis=("interactions", "chat-completions", "generate-content", "realtime")),
        ]))
        self.assertEqual(models(catalog, "google")["gemini-3.8-flash"]["apis"], ["chat-completions", "generate-content"])

    def test_writes_only_the_six_providers(self):
        self.assertEqual(sorted(build(source())["providers"]), sorted(generate.PROVIDERS))

    def test_sorts_models_by_id(self):
        catalog = build(source(xai=[model("grok-4.7"), model("grok-4.5"), model("grok-4.6")]))
        self.assertEqual([m["id"] for m in catalog["providers"]["xai"]["models"]], ["grok-4.5", "grok-4.6", "grok-4.7"])


class FieldTests(unittest.TestCase):
    def test_maps_name_date_output_images_and_deprecation(self):
        catalog = build(source(anthropic=[
            model("claude-opus-5-5", apis=("messages",), released="2026-09-22",
                  modalities={"input": ["text", "image/png", "application/pdf"], "output": ["text"]},
                  limit={"context": 1000000, "output": 128000}),
            model("claude-sonnet-4-5", apis=("messages",), status="deprecated", limit={"context": 200000}),
            model("claude-beta", apis=("messages",), status="beta", released="2026-09",
                  limit={"output": 0}),
        ]))
        listed = models(catalog, "anthropic")
        self.assertEqual(listed["claude-opus-5-5"], {
            "id": "claude-opus-5-5", "name": "CLAUDE-OPUS-5-5", "released": "2026-09-22", "output": 128000,
            "images": True, "apis": ["messages"],
        })
        self.assertIs(listed["claude-sonnet-4-5"]["deprecated"], True)
        self.assertIs(listed["claude-sonnet-4-5"]["images"], False)
        self.assertNotIn("output", listed["claude-sonnet-4-5"])
        self.assertNotIn("deprecated", listed["claude-beta"])
        self.assertNotIn("released", listed["claude-beta"])
        self.assertNotIn("output", listed["claude-beta"])

    def test_leaves_images_out_without_modalities(self):
        bare = model("grok-4.7")
        del bare["modalities"]
        self.assertNotIn("images", models(build(source(xai=[bare])), "xai")["grok-4.7"])

    def test_client_version_only_on_codex(self):
        catalog = build(source())
        self.assertEqual(catalog["providers"]["openai-codex"]["client_version"], "0.172.0")
        for key in set(generate.PROVIDERS) - {"openai-codex"}:
            self.assertNotIn("client_version", catalog["providers"][key])


class ReasoningTests(unittest.TestCase):
    def reasoning(self, provider="openai", model_id="gpt-6.2-sol", **fields):
        catalog = build(source(**{provider: [model(model_id, capabilities=thinking(**fields))]}))
        return models(catalog, provider)[model_id].get("reasoning")

    def test_folds_none_into_toggle(self):
        self.assertEqual(self.reasoning(effort=["none", "low", "medium", "high", "xhigh", "max"]),
                         {"efforts": ["low", "medium", "high", "xhigh", "max"], "toggle": True})

    def test_keeps_the_toggle_flag(self):
        self.assertEqual(self.reasoning(toggle=True, effort=["low", "high"]), {"efforts": ["low", "high"], "toggle": True})

    def test_no_toggle_when_the_model_always_reasons(self):
        self.assertEqual(self.reasoning(effort=["medium", "high", "xhigh"]), {"efforts": ["medium", "high", "xhigh"]})

    def test_budget_and_default(self):
        self.assertEqual(
            self.reasoning(toggle=True, effort=["low", "medium", "high", "max"], budget={"min": 1024},
                           default={"type": "effort", "value": "medium"}),
            {"efforts": ["low", "medium", "high", "max"], "toggle": True, "budget_min": 1024, "default": "medium"})

    def test_drops_a_default_the_model_does_not_list(self):
        self.assertEqual(self.reasoning(effort=["low", "high"], default={"type": "effort", "value": "max"}),
                         {"efforts": ["low", "high"]})

    def test_drops_a_toggle_default(self):
        self.assertEqual(self.reasoning(toggle=True, budget={"min": 512, "max": 24576},
                                        default={"type": "toggle", "value": False}),
                         {"toggle": True, "budget_min": 512})

    def test_a_reasoning_model_with_nothing_known(self):
        self.assertEqual(self.reasoning(), {})

    def test_no_reasoning_when_unsupported(self):
        self.assertIsNone(self.reasoning(supported=False, effort=["low"]))

    def test_google_keeps_everything_but_the_efforts(self):
        self.assertEqual(
            self.reasoning(provider="google", model_id="gemini-3.8-flash", effort=["none", "low", "medium", "high"],
                           default={"type": "effort", "value": "medium"}),
            {"toggle": True, "default": "medium"})


class ShapeTests(unittest.TestCase):
    def assertRefused(self, data, message):
        with self.assertRaises(generate.CatalogError) as caught:
            build(data)
        self.assertIn(message, str(caught.exception))

    def changed(self, provider, model_id, mutate):
        data = source()
        mutate(data[provider]["models"][model_id])
        return data

    def test_a_missing_provider(self):
        data = source()
        del data["openai-codex"]
        self.assertRefused(data, "no openai-codex provider")

    def test_models_not_an_object(self):
        data = source()
        data["xai"]["models"] = list(data["xai"]["models"].values())
        self.assertRefused(data, "xai.models: expected dict")

    def test_a_provider_with_no_chat_model(self):
        self.assertRefused(source(meta=[model("muse-image-1.0", kind="image", apis=("images",))]),
                           "meta: no chat model left")

    def test_the_v1_shape_without_api(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.pop("api")), "xai/grok-4.7.api: expected dict")

    def test_an_id_that_differs_from_its_key(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.update(id="grok-5")), "differs from its key")

    def test_a_type_that_is_not_a_string(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.update(type=["chat"])), ".type: expected str")

    def test_reasoning_without_supported(self):
        self.assertRefused(
            self.changed("xai", "grok-4.7", lambda m: m["capabilities"].update(reasoning={"effort": ["low"]})),
            "reasoning.supported: expected bool")

    def test_reasoning_options_in_the_v1_shape(self):
        self.assertRefused(
            self.changed("xai", "grok-4.7", lambda m: m["capabilities"].update(
                reasoning={"supported": True, "effort": [{"type": "effort", "values": ["low"]}]})),
            "is not an effort name")

    def test_an_unknown_default_type(self):
        self.assertRefused(
            self.changed("xai", "grok-4.7", lambda m: m["capabilities"].update(
                reasoning={"supported": True, "default": {"type": "budget", "value": 1024}})),
            "default.type: 'budget'")

    def test_a_budget_without_a_minimum(self):
        self.assertRefused(
            self.changed("xai", "grok-4.7", lambda m: m["capabilities"].update(
                reasoning={"supported": True, "budget": {"max": 1024}})),
            "budget.min: expected int")

    def test_an_unknown_status(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.update(status="retired")),
                           "status: 'retired'")

    def test_a_date_in_another_format(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.update(release_date="2026-07-08T00:00:00Z")),
                           "release_date")

    def test_image_input_as_one_string(self):
        self.assertRefused(
            self.changed("xai", "grok-4.7", lambda m: m.update(modalities={"input": "text,image"})),
            "modalities.input: expected list")

    def test_an_output_limit_that_is_not_a_number(self):
        self.assertRefused(self.changed("xai", "grok-4.7", lambda m: m.update(limit={"output": "128k"})),
                           "limit.output: expected int")


class DefaultTests(unittest.TestCase):
    def test_initial_defaults(self):
        catalog = build(source(
            anthropic=[model("claude-fable-5-2", apis=("messages",), released="2026-11-09"),
                       model("claude-opus-5-5", apis=("messages",), released="2026-09-22")],
            openai=[model("gpt-6.2-astra", released="2026-11-17"), model("gpt-6.2-sol", released="2026-11-17"),
                    model("gpt-6.1-sol", released="2026-09-29"), model("gpt-7-pro", released="2026-12-01"),
                    model("gpt-7-mini-sol", released="2026-12-01"),
                    model("gpt-7-sol", released="2026-12-01", apis=("chat-completions",))],
            google=[model("gemini-3.8-flash", apis=("generate-content",), released="2026-09-02"),
                    model("gemini-flash-latest", apis=("generate-content",), released="2026-09-02"),
                    model("gemini-3.9-pro-preview", apis=("generate-content",), released="2026-10-01"),
                    model("gemini-3.9-flash-lite", apis=("generate-content",), released="2026-10-01"),
                    model("gemini-3.9-pro", apis=("generate-content",), released="2026-10-02", status="deprecated")],
            xai=[model("grok-4.7", released="2026-09-21"), model("grok-4.20-multi-agent-0309", released="2026-10-01"),
                 model("grok-4.5", released="2026-07-08")],
            meta=[model("muse-ember-1.0", released="2026-11-09"), model("muse-spark-1.3", released="2026-09-02")],
        ))
        defaults = {key: provider["default"] for key, provider in catalog["providers"].items()}
        self.assertEqual(defaults, {
            "anthropic": "claude-opus-5-5", "openai": "gpt-6.2-sol", "openai-codex": "gpt-6.2-sol",
            "google": "gemini-3.8-flash", "xai": "grok-4.7", "meta": "muse-spark-1.3",
        })

    def test_falls_back_to_the_newest_model_that_is_not_deprecated(self):
        catalog = build(source(anthropic=[
            model("claude-sonnet-5-5", apis=("messages",), released="2026-09-28"),
            model("claude-haiku-5-5", apis=("messages",), released="2026-10-07"),
            model("claude-haiku-6", apis=("messages",), released="2026-11-01", status="deprecated"),
        ]))
        self.assertEqual(catalog["providers"]["anthropic"]["default"], "claude-haiku-5-5")

    def test_keeps_the_previous_default(self):
        previous = build(source())
        previous["providers"]["xai"]["default"] = "grok-4.5"
        previous["providers"]["xai"]["models"].append({"id": "grok-4.5", "name": "Grok 4.5", "apis": ["responses"]})
        catalog = build(source(xai=[model("grok-4.5", released="2026-07-08"), model("grok-4.7")]), previous)
        self.assertEqual(catalog["providers"]["xai"]["default"], "grok-4.5")


class GuardTests(unittest.TestCase):
    def previous(self, **providers):
        return build(source(**providers))

    def assertRefused(self, data, previous, message, allow_removals=False):
        with self.assertRaises(generate.CatalogError) as caught:
            build(data, previous, allow_removals=allow_removals)
        self.assertIn(message, str(caught.exception))

    def test_refuses_an_id_gone_without_deprecation(self):
        previous = self.previous(xai=[model("grok-4.5"), model("grok-4.7")])
        self.assertRefused(source(xai=[model("grok-4.7")]), previous, "xai/grok-4.5: gone without being marked")

    def test_drops_an_id_marked_deprecated_first(self):
        previous = self.previous(xai=[model("grok-4.5", status="deprecated"), model("grok-4.7")])
        self.assertEqual(sorted(models(build(source(xai=[model("grok-4.7")]), previous), "xai")), ["grok-4.7"])

    def test_refuses_more_than_three_fewer_models(self):
        old = [model(f"grok-4.{n}", status="deprecated") for n in range(4)] + [model("grok-4.7")]
        self.assertRefused(source(xai=[model("grok-4.7")]), self.previous(xai=old), "5 models down to 1")

    def test_allows_three_fewer_models(self):
        old = [model(f"grok-4.{n}", status="deprecated") for n in range(3)] + [model("grok-4.7")]
        self.assertEqual(len(models(build(source(xai=[model("grok-4.7")]), self.previous(xai=old)), "xai")), 1)

    def test_refuses_a_deprecated_default(self):
        previous = self.previous()
        self.assertRefused(source(xai=[model("grok-4.7", status="deprecated"), model("grok-4.8")]), previous,
                           "xai: the default grok-4.7 is deprecated")

    def test_refuses_a_missing_default(self):
        previous = self.previous()
        previous["providers"]["xai"]["default"] = "grok-9"
        self.assertRefused(source(), previous, "xai: the default grok-9 is not listed")

    def test_refuses_a_provider_that_is_gone(self):
        previous = self.previous()
        previous["providers"]["mistral"] = {"default": "x", "models": [{"id": "x"}]}
        self.assertRefused(source(), previous, "mistral: the provider is gone")

    def test_allow_removals_passes_removals_but_not_defaults(self):
        previous = self.previous(xai=[model("grok-4.5"), model("grok-4.7")])
        catalog = build(source(xai=[model("grok-4.7")]), previous, allow_removals=True)
        self.assertEqual(sorted(models(catalog, "xai")), ["grok-4.7"])
        previous["providers"]["xai"]["default"] = "grok-4.5"
        self.assertRefused(source(xai=[model("grok-4.7")]), previous, "grok-4.5 is not listed", allow_removals=True)

    def test_lists_every_problem(self):
        previous = self.previous(xai=[model("grok-4.5"), model("grok-4.6"), model("grok-4.7")])
        with self.assertRaises(generate.CatalogError) as caught:
            build(source(xai=[model("grok-4.7")]), previous)
        self.assertIn("grok-4.5", str(caught.exception))
        self.assertIn("grok-4.6", str(caught.exception))


class StampTests(unittest.TestCase):
    def test_keeps_the_stamp_when_nothing_changed(self):
        previous = json.loads(generate.render(build(source(), now=NOW)))
        self.assertEqual(previous["generated"], "2026-11-24T19:17:00Z")
        self.assertEqual(build(source(), previous, now=LATER)["generated"], "2026-11-24T19:17:00Z")

    def test_moves_the_stamp_when_the_content_changed(self):
        previous = json.loads(generate.render(build(source(), now=NOW)))
        catalog = build(source(xai=[model("grok-4.7"), model("grok-4.8")]), previous, now=LATER)
        self.assertEqual(catalog["generated"], "2026-11-25T19:17:00Z")

    def test_a_new_codex_version_is_a_change(self):
        previous = json.loads(generate.render(build(source(), now=NOW)))
        catalog = generate.build(source(), "0.173.0", previous, LATER)
        self.assertEqual(catalog["generated"], "2026-11-25T19:17:00Z")


class CodexVersionTests(unittest.TestCase):
    def test_reads_the_rust_release_tag(self):
        self.assertEqual(generate.codex_version_of({"tag_name": "rust-v0.172.0"}), "0.172.0")

    def test_refuses_another_tag(self):
        for tag in ["v0.172.0", "rust-v0.172.0-alpha.1", None]:
            with self.subTest(tag=tag), self.assertRaises(generate.CatalogError):
                generate.codex_version_of({"tag_name": tag})

    def test_refuses_an_explicit_version_that_is_not_x_y_z(self):
        with self.assertRaises(generate.CatalogError):
            generate.codex_version("latest")


class MainTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source = self.root / "api.json"
        self.output = self.root / "ai-models.json"

    def run_main(self, data, *extra):
        self.source.write_text(json.dumps(data), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = generate.main(["--source", str(self.source), "--codex-version", "0.172.0",
                                    "--output", str(self.output), *extra], now=NOW)
        return status, stderr.getvalue()

    def test_writes_sorted_indented_json_with_a_trailing_newline(self):
        self.assertEqual(self.run_main(source()), (0, ""))
        text = self.output.read_text(encoding="utf-8")
        self.assertTrue(text.endswith("}\n"))
        self.assertTrue(text.startswith('{\n  "generated": "2026-11-24T19:17:00Z",\n  "providers": {\n'))
        self.assertEqual(text, generate.render(json.loads(text)))
        self.assertEqual(json.loads(text)["schema"], 1)

    def test_the_same_input_writes_the_same_bytes(self):
        self.run_main(source())
        first = self.output.read_bytes()
        self.run_main(source(), "--previous", str(self.output))
        self.assertEqual(self.output.read_bytes(), first)

    def test_writes_nothing_on_a_shape_change(self):
        data = source()
        del data["meta"]
        status, stderr = self.run_main(data)
        self.assertEqual(status, 1)
        self.assertIn("no meta provider", stderr)
        self.assertFalse(self.output.exists())

    def test_leaves_the_previous_file_alone_when_a_guard_refuses(self):
        self.run_main(source(xai=[model("grok-4.5"), model("grok-4.7")]))
        before = self.output.read_bytes()
        status, stderr = self.run_main(source(), "--previous", str(self.output))
        self.assertEqual(status, 1)
        self.assertIn("xai/grok-4.5: gone without being marked deprecated first", stderr)
        self.assertEqual(self.output.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["ai-models.json", "api.json"])

    def test_refuses_a_previous_file_of_another_schema(self):
        self.output.write_text(json.dumps({"schema": 2, "generated": "x", "providers": {}}), encoding="utf-8")
        status, stderr = self.run_main(source(), "--previous", str(self.output))
        self.assertEqual(status, 1)
        self.assertIn("schema 2, not 1", stderr)

    def test_does_not_change_its_input(self):
        data = source()
        snapshot = copy.deepcopy(data)
        build(data)
        self.assertEqual(data, snapshot)


if __name__ == "__main__":
    unittest.main()
