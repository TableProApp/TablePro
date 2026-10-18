#!/usr/bin/env python3
"""Fixture tests for check-plugin-manifest.py."""

import importlib.util
import unittest
from pathlib import Path

import yaml

SPEC = importlib.util.spec_from_file_location("check_plugin_manifest", Path(__file__).with_name("check-plugin-manifest.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

PROJECT = """name: App

targetTemplates:
  DriverPlugin:
    type: bundle
    dependencies:
      - target: TableProPluginKit

targets:
  TablePro:
    type: application
    dependencies:
      - target: TableProPluginKit
        embed: true
      # Plugins shipped inside the app bundle.
      - target: MySQLDriver
        embed: true
        copy: { destination: plugins }
      - target: RedisDriver
        embed: true
        copy:
          destination: plugins
      - target: mcp-server
        copy:
          destination: executables
      - package: Sparkle
  MySQLDriver:
    templates: [DriverPlugin, MySQLLinkage]
  RedisDriver:
    templates:
      - DriverPlugin
  OracleDriver:
    templates: [DriverPlugin]  # registry only
  MySQLDriverTests:
    templates: [PluginTests, MySQLLinkage]

aggregateTargets:
  BundledPlugins:
    targets:
      - MySQLDriver
      - RedisDriver

  RegistryPlugins:
    targets: [OracleDriver]
    scheme: {}

  AllPlugins:
    targets:
      - BundledPlugins
      - RegistryPlugins
    scheme: {}

schemes:
  App:
    build:
      targets:
        App: all
"""

PLUGINS = {"OracleDriver": {"name": "Oracle Driver"}}


def problems(project=PROJECT, plugins=None):
    return check.aggregate_problems(yaml.safe_load(project), PLUGINS if plugins is None else plugins)


def edited(old, new):
    assert old in PROJECT, old
    return PROJECT.replace(old, new, 1)


class EmbeddedPluginsTests(unittest.TestCase):
    def test_takes_both_copy_forms_and_only_the_plugins_destination(self):
        app = yaml.safe_load(PROJECT)["targets"]["TablePro"]
        self.assertEqual(check.embedded_plugins(app), {"MySQLDriver", "RedisDriver"})


class AggregateProblemsTests(unittest.TestCase):
    def test_consistent_project_passes(self):
        self.assertEqual(problems(), [])

    def test_published_plugin_missing_from_registry_aggregate(self):
        found = problems(edited("    targets: [OracleDriver]", "    targets: []"))
        self.assertIn("plugin-registry.json publishes OracleDriver but RegistryPlugins does not build it", found)
        self.assertIn("OracleDriver is in 0 of BundledPlugins and RegistryPlugins, expected exactly one", found)

    def test_registry_aggregate_target_that_is_not_published(self):
        self.assertEqual(
            problems(plugins={}),
            ["RegistryPlugins builds OracleDriver but plugin-registry.json does not publish it"],
        )

    def test_bundled_plugin_in_the_metadata(self):
        plugins = {**PLUGINS, "RedisDriver": {"name": "Redis Driver"}}
        self.assertEqual(
            problems(plugins=plugins),
            ["plugin-registry.json publishes RedisDriver but RegistryPlugins does not build it"],
        )

    def test_embedded_plugin_missing_from_bundled_aggregate(self):
        found = problems(edited("      - MySQLDriver\n      - RedisDriver\n", "      - RedisDriver\n"))
        self.assertIn("the TablePro target embeds MySQLDriver but BundledPlugins does not list it", found)

    def test_bundled_aggregate_lists_a_plugin_the_app_does_not_embed(self):
        project = edited("      - target: MySQLDriver\n        embed: true\n        copy: { destination: plugins }\n", "")
        self.assertEqual(problems(project), ["BundledPlugins lists MySQLDriver but the TablePro target does not embed it"])

    def test_plugin_in_both_aggregates(self):
        project = edited("    targets: [OracleDriver]", "    targets: [OracleDriver, RedisDriver]")
        self.assertIn("RedisDriver is in 2 of BundledPlugins and RegistryPlugins, expected exactly one", problems(project))

    def test_aggregate_member_that_is_not_a_plugin(self):
        project = edited("      - MySQLDriver\n      - RedisDriver\n", "      - MySQLDriver\n      - RedisDriver\n      - mcp-server\n")
        self.assertIn("mcp-server is in a plugin aggregate but is not a DriverPlugin target", problems(project))

    def test_all_plugins_depends_on_the_two_aggregates_only(self):
        project = edited("      - BundledPlugins\n      - RegistryPlugins\n", "      - BundledPlugins\n      - OracleDriver\n")
        self.assertEqual(
            problems(project),
            ["AllPlugins must depend on BundledPlugins and RegistryPlugins only, not ['BundledPlugins', 'OracleDriver']"],
        )

    def test_missing_aggregate(self):
        project = edited("  RegistryPlugins:\n    targets: [OracleDriver]\n    scheme: {}\n", "")
        self.assertEqual(problems(project), ["project.yml has no RegistryPlugins aggregate target"])


if __name__ == "__main__":
    unittest.main()
