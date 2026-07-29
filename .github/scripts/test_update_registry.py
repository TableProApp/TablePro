#!/usr/bin/env python3
"""Tests for update-registry.py PluginKit version pruning (#1322).

Run: python3 .github/scripts/test_update_registry.py
"""
import importlib.util
import os

_spec = importlib.util.spec_from_file_location(
    "update_registry",
    os.path.join(os.path.dirname(__file__), "update-registry.py"),
)
update_registry = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(update_registry)


def test_kit_version_rejects_non_int():
    assert update_registry.kit_version({"pluginKitVersion": 14}) == 14
    assert update_registry.kit_version({"pluginKitVersion": None}) is None
    assert update_registry.kit_version({}) is None


def test_prune_drops_null_kit_binary():
    binaries = [
        {"architecture": "arm64", "pluginKitVersion": None, "downloadURL": "legacy"},
        {"architecture": "arm64", "pluginKitVersion": 14, "downloadURL": "v14"},
        {"architecture": "arm64", "pluginKitVersion": 13, "downloadURL": "v13"},
    ]
    kept = update_registry.prune_old_kit_versions(binaries, keep_count=2)
    versions = sorted(update_registry.kit_version(b) for b in kept)
    assert versions == [13, 14], versions
    assert all(update_registry.kit_version(b) is not None for b in kept)


def test_prune_keeps_only_two_newest():
    binaries = [
        {"architecture": "arm64", "pluginKitVersion": v, "downloadURL": str(v)}
        for v in (12, 13, 14)
    ]
    kept = update_registry.prune_old_kit_versions(binaries, keep_count=2)
    versions = sorted(update_registry.kit_version(b) for b in kept)
    assert versions == [13, 14], versions


def test_update_entry_drops_legacy_null_binary():
    manifest = {
        "schemaVersion": 2,
        "plugins": [
            {
                "id": "com.TablePro.DynamoDBDriverPlugin",
                "name": "DynamoDB",
                "version": "1.0.15",
                "summary": "old",
                "category": "database-driver",
                "binaries": [
                    {"architecture": "arm64", "pluginKitVersion": None, "downloadURL": "legacy"},
                ],
            }
        ],
    }

    class Args:
        id = "com.TablePro.DynamoDBDriverPlugin"
        name = "DynamoDB"
        version = "1.0.16"
        summary = "new"
        db_type_ids = '["dynamodb"]'
        arm64_url = "https://x/arm64"
        arm64_sha = "a"
        x86_64_url = "https://x/x86_64"
        x86_64_sha = "b"
        min_app_version = "0.43.0"
        icon = "icon"
        homepage = "https://tablepro.app"
        category = "database-driver"
        plugin_kit_version = 14
        keep_kit_versions = 2

    result = update_registry.update_plugin_entry(manifest, Args())
    entry = next(p for p in result["plugins"] if p["id"] == Args.id)
    kits = sorted(update_registry.kit_version(b) for b in entry["binaries"])
    assert kits == [14, 14], kits
    assert all(update_registry.kit_version(b) is not None for b in entry["binaries"])


if __name__ == "__main__":
    test_kit_version_rejects_non_int()
    test_prune_drops_null_kit_binary()
    test_prune_keeps_only_two_newest()
    test_update_entry_drops_legacy_null_binary()
    print("All update-registry tests passed.")
