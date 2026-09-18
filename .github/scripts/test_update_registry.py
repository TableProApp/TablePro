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


def _args(version, pkv, keep=2):
    class Args:
        id = "com.TablePro.DynamoDBDriverPlugin"
        name = "DynamoDB"
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

    Args.version = version
    Args.plugin_kit_version = pkv
    Args.keep_kit_versions = keep
    return Args


def _manifest(*kit_versions):
    return {
        "schemaVersion": 2,
        "plugins": [
            {
                "id": "com.TablePro.DynamoDBDriverPlugin",
                "name": "DynamoDB",
                "version": "1.0.15",
                "summary": "old",
                "category": "database-driver",
                "binaries": [
                    {
                        "architecture": arch,
                        "pluginKitVersion": pkv,
                        "downloadURL": f"old-{pkv}-{arch}",
                        "sha256": "x",
                    }
                    for pkv in kit_versions
                    for arch in ("arm64", "x86_64")
                ],
            }
        ],
    }


def test_publishing_a_new_kit_version_keeps_the_previous_one():
    """The retention policy's whole point: a user on the previous app can still install.

    Nothing covered this. The one existing merge test starts from a null-version binary, which
    is dropped rather than retained, so the surviving-binary path was never exercised.
    """
    result = update_registry.update_plugin_entry(_manifest(14), _args("1.0.16", 15))
    entry = next(p for p in result["plugins"] if p["id"] == "com.TablePro.DynamoDBDriverPlugin")
    kits = sorted(update_registry.kit_version(b) for b in entry["binaries"])
    assert kits == [14, 14, 15, 15], kits
    urls = {b["downloadURL"] for b in entry["binaries"]}
    assert "old-14-arm64" in urls, urls


def test_a_third_kit_version_evicts_the_oldest():
    result = update_registry.update_plugin_entry(_manifest(13, 14), _args("1.0.17", 15))
    entry = next(p for p in result["plugins"] if p["id"] == "com.TablePro.DynamoDBDriverPlugin")
    kits = sorted(update_registry.kit_version(b) for b in entry["binaries"])
    assert kits == [14, 14, 15, 15], kits


def test_republishing_the_same_kit_version_replaces_its_binaries():
    result = update_registry.update_plugin_entry(_manifest(14), _args("1.0.16", 14))
    entry = next(p for p in result["plugins"] if p["id"] == "com.TablePro.DynamoDBDriverPlugin")
    kits = sorted(update_registry.kit_version(b) for b in entry["binaries"])
    assert kits == [14, 14], kits
    urls = {b["downloadURL"] for b in entry["binaries"]}
    assert urls == {"https://x/arm64", "https://x/x86_64"}, urls


def test_publishing_below_the_retained_window_refuses():
    """Otherwise the entry advertises a version whose binary the prune just discarded."""
    try:
        update_registry.update_plugin_entry(_manifest(15, 16), _args("1.0.18", 14))
    except SystemExit as error:
        assert "older than the" in str(error), error
    else:
        raise AssertionError("expected SystemExit when the new binary would be pruned away")


if __name__ == "__main__":
    test_kit_version_rejects_non_int()
    test_prune_drops_null_kit_binary()
    test_prune_keeps_only_two_newest()
    test_update_entry_drops_legacy_null_binary()
    test_publishing_a_new_kit_version_keeps_the_previous_one()
    test_a_third_kit_version_evicts_the_oldest()
    test_republishing_the_same_kit_version_replaces_its_binaries()
    test_publishing_below_the_retained_window_refuses()
    print("All update-registry tests passed.")
