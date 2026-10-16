from pathlib import Path
import importlib.util
import json
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_jobs", ROOT / "scripts/check-ci-jobs.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
bounded_spec = importlib.util.spec_from_file_location("bounded_operations", ROOT / "scripts/check-bounded-operations.py")
bounded_checker = importlib.util.module_from_spec(bounded_spec)
bounded_spec.loader.exec_module(bounded_checker)
port_spec = importlib.util.spec_from_file_location("ci_mcp_port", ROOT / "scripts/ci-mcp-port.py")
port_helper = importlib.util.module_from_spec(port_spec)
port_spec.loader.exec_module(port_helper)


class CiWorkflowTests(unittest.TestCase):
    def test_forgejo_gtk_jobs_select_distinct_run_scoped_mcp_ports(self):
        ci = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        nightly = (ROOT / ".forgejo/workflows/nightly.yml").read_text()
        for workflow in (ci, nightly):
            self.assertIn("scripts/ci-mcp-port.py", workflow)
        for call in [
            'scripts/ci-mcp-port.py "${{ matrix.shard }}"',
            "scripts/ci-mcp-port.py 4",
            'scripts/ci-mcp-port.py "${{ matrix.mcp_port_slot }}"',
            'scripts/ci-mcp-port.py "${{ matrix.run }}"',
        ]:
            self.assertIn(call, ci + nightly)
        ports = [port_helper.port_for_run(137, slot) for slot in range(1, 12)]
        self.assertEqual(len(ports), len(set(ports)))
        self.assertTrue(all(20000 <= port <= 59999 for port in ports))

    def test_forgejo_driver_jobs_reuse_and_clean_the_run_scoped_database(self):
        workflow = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        driver = workflow.split("  driver:\n", 1)[1].split("  consumers:\n", 1)[0]
        self.assertIn("TABLEPRO_TEST_RUN_ID: forgejo-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.driver }}", driver)
        self.assertIn("cleanup-testcontainers.py", driver)
        self.assertIn("trap cleanup_testcontainers EXIT", driver)
        self.assertIn("--test-threads=1", driver)

    def test_bounded_operation_guard_catches_multiline_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.rs"
            source.write_text("connection\n    .query(\"SELECT 1\");\nconn.fetch_columns(None, \"x\");\nconnection.execute_controlled(\"ok\", &control);\n")
            found = list(bounded_checker.unbounded_calls([source]))
        self.assertEqual([row[2] for row in found], ["connection .query(", "conn.fetch_columns("])

    def test_cross_consumer_server_targets_are_gated_and_documented(self):
        local = (ROOT / "scripts/ci-local.sh").read_text()
        for package, target in [
            ("tablepro-mcp", "mongodb_extended_json"),
            ("tablepro-policy", "session_postgres"),
            ("tablepro-policy", "session_mssql"),
        ]:
            self.assertIn(f"-p {package} --test {target} -- --include-ignored --test-threads=1", local)
        registry = json.loads((ROOT / "scripts/isolated-tests.json").read_text())
        self.assertEqual(
            {entry[2].split("::")[-1] for entry in registry["app-server"]},
            {
                "postgres_numeric_parser_outputs_round_trip_through_server",
                "postgres_extended_temporal_grid_edits_preserve_native_values",
                "value_contract_postgres_temporal_array_grid_edits_preserve_boundaries_and_siblings",
                "value_contract_postgres_float4_array_grid_edit_preserves_extreme_values_and_sibling",
                "value_contract_postgres_integer_array_grid_edits_preserve_width_and_siblings",
                "value_contract_postgres_text_array_grid_edit_preserves_escaped_values_and_siblings",
                "value_contract_postgres_bit_array_grid_edit_preserves_wire_values_and_sibling",
                "value_contract_postgres_citext_array_grid_edit_preserves_case_nulls_and_sibling",
                "value_contract_clickhouse_enum8_and_enum16_grid_edits_preserve_labels_and_refuse_invalid_values",
                "value_contract_mysql_unparseable_procedure_uses_human_approval_before_execution",
                "value_contract_mongodb_int32_grid_edit_preserves_integer_width",
                "value_contract_mongodb_date_grid_edit_preserves_millisecond_instant",
                "value_contract_mongodb_decimal128_grid_edit_preserves_wide_precision",
                "value_contract_mongodb_nested_document_edit_preserves_extended_bson_and_row_identity",
                "value_contract_mongodb_off_page_type_change_during_census_refuses_edit",
                "value_contract_mongodb_browse_uses_a_bounded_sample_and_page_find",
                "value_contract_mongodb_census_is_not_a_snapshot_for_already_read_documents",
                "value_contract_mongodb_run_find_merges_page_types_and_exports_materialized_values",
                "postgres_value_query_refetches_by_enum_and_domain_composite_key",
                "mysql_value_query_refetches_the_exact_blob_for_a_composite_key",
                "mssql_value_query_refetches_the_exact_blob_for_a_composite_key",
                "clickhouse_value_query_refetches_the_exact_text_for_a_composite_key",
                "mongodb_guarded_refetch_preserves_long_text_and_binary_values",
                "redis_guarded_refetch_preserves_binary_key_and_value",
                "value_contract_mysql_unsigned_integer_grid_edits_refuse_coercion_and_preserve_u64",
                "value_contract_mysql_temporal_parser_keyed_edit_preserves_native_values_and_siblings",
                "value_contract_mysql_enum_set_keyed_edits_preserve_native_values_across_sql_modes",
                "value_contract_mariadb_enum_set_grid_edit_preserves_values_across_sql_modes",
                "value_contract_mysql_spatial_grid_refusal_preserves_native_bytes",
                "value_contract_mysql_bit_parser_edits_preserve_native_values",
                "value_contract_mongodb_collection_wide_mixed_metadata_refuses_edit",
                "value_contract_mssql_legacy_datetime_text_grid_edit_preserves_wire_value_and_siblings",
                "value_contract_mssql_datetimeoffset_grid_edit_preserves_local_time_offset_and_siblings",
                "value_contract_mssql_max_values_survive_connection_session_and_consumers",
                "value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers",
                "value_contract_postgres_csv_import_preserves_explicit_identity_values",
            },
        )
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        fast = workflow.split("  fast:\n", 1)[1].split("  gtk-safety:\n", 1)[0]
        for required in [
            "run-test-layer.py app-server",
            "/var/run/docker.sock:/var/run/docker.sock",
            "./.github/actions/dockerhub-login",
            "secrets.DOCKERHUB_USERNAME",
            "secrets.DOCKERHUB_TOKEN",
            "credentials:",
        ]:
            self.assertIn(required, fast)
        self.assertIn(
            "cargo test --locked -p tablepro-app --features duckdb --lib value_contract_duckdb",
            workflow,
        )
        ledger = subprocess.check_output(["python3", str(ROOT / "scripts/inventory-ignored-tests.py")], text=True)
        for package, target in [
            ("tablepro-mcp", "mongodb_extended_json"),
            ("tablepro-policy", "session_postgres"),
            ("tablepro-policy", "session_mssql"),
        ]:
            self.assertIn(f"-p {package} --test {target}", ledger)
        self.assertIn("scripts/run-test-layer.py app-server", ledger)
        self.assertNotIn("tablepro-driver-tests", ledger)
        self.assertNotIn("tablepro-driver-src", ledger)

    def test_full_gate_enforces_function_size_like_preflight(self):
        script = (ROOT / "scripts/ci-local.sh").read_text()
        full = script.split("run_full() {", 1)[1].split("run_integration()", 1)[0]
        self.assertIn("python3 scripts/check-function-size.py", full)

    def test_jobs_share_an_immutable_checkout(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        self.assertNotIn("continue-on-error:", workflow)
        self.assertIn("revision: ${{ steps.pin.outputs.revision }}", workflow)
        self.assertIn("ref: ${{ needs.pin-revision.outputs.revision }}", workflow)
        self.assertNotIn("needs.preflight.outputs.commit", workflow)
        self.assertNotIn("needs.resolve-ref.outputs.commit", workflow)
        gate = workflow.split("  regression-gate:\n", 1)[1]
        self.assertNotIn("needs.pin-revision.outputs.revision", gate.split("steps:", 1)[1])
        for line in workflow.splitlines():
            if line.strip().startswith("ref:"):
                self.assertNotIn("github.ref", line)
        quality = (ROOT / ".github/workflows/linux-quality.yml").read_text()
        self.assertEqual(quality.count("ref: ${{ needs.resolve-ref.outputs.commit }}"), 2)

    def test_preflight_and_fast_share_cache_and_run_after_pin_revision(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        preflight = workflow.split("  preflight:\n", 1)[1].split("  fast:\n", 1)[0]
        fast = workflow.split("  fast:\n", 1)[1].split("  gtk-safety:\n", 1)[0]
        ensure = workflow.split("  ensure-ci-gtk-image:\n", 1)[1].split("  preflight:\n", 1)[0]
        self.assertIn("needs: pin-revision", preflight)
        self.assertIn("needs: [pin-revision, ensure-ci-gtk-image]", fast)
        self.assertNotIn("needs: preflight", fast)
        self.assertIn("mozilla-actions/sccache-action@", preflight)
        self.assertIn("mozilla-actions/sccache-action@", fast)
        self.assertIn("shared-key: linux-build", preflight)
        self.assertIn("shared-key: linux-build", fast)
        self.assertIn(
            "save-if: ${{ github.event_name == 'pull_request' || (github.event_name == 'push' && (github.ref == 'refs/heads/linux' || github.ref == 'refs/heads/main')) }}",
            preflight,
        )
        self.assertIn("persist-credentials: false", preflight)
        self.assertIn("ghcr.io/cozygarage/bookie/ci-debian-testing-gtk", ensure)
        self.assertIn('echo "tag=${tag}" >> "$GITHUB_OUTPUT"', ensure)
        self.assertNotIn('echo "image=', ensure)
        self.assertIn(
            "image: ghcr.io/cozygarage/bookie/ci-debian-testing-gtk:${{ needs.ensure-ci-gtk-image.outputs.tag }}",
            fast,
        )
        self.assertNotIn("needs.ensure-ci-gtk-image.outputs.image", fast)
        self.assertNotIn("prefix-key: linux-preflight", workflow)
        self.assertNotIn("prefix-key: linux-fast-gtk", workflow)

    def test_required_jobs_never_accept_failure_skip_cancel_or_missing(self):
        success = {name: {"result": "success"} for name in checker.REQUIRED | {checker.SCHEDULED}}
        self.assertEqual(checker.assess(success, "push")[0], [])
        for name in checker.REQUIRED:
            for state in ["failure", "skipped", "cancelled", "missing"]:
                results = success | {name: {"result": state}}
                deferred = name in checker.MERGE_ONLY and state == "skipped"
                expected = [] if deferred else [name]
                self.assertEqual(checker.assess(results, "push")[0], expected, (name, state))
        self.assertEqual(set(checker.assess({}, "push")[0]), checker.REQUIRED | {checker.SCHEDULED})

    def test_only_pull_request_runs_are_cancelled_when_a_newer_run_starts(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)
        self.assertNotIn("event_name == 'push' }}", workflow.split("concurrency:", 1)[1].split("jobs:", 1)[0])

    def test_push_and_pull_request_may_defer_only_the_merge_tier_jobs(self):
        success = {name: {"result": "success"} for name in checker.REQUIRED | {checker.SCHEDULED}}
        for name in checker.REQUIRED:
            results = success | {name: {"result": "skipped"}}
            expected = [] if name in checker.MERGE_ONLY else [name]
            self.assertEqual(checker.assess(results, "pull_request")[0], expected, name)
            self.assertEqual(checker.assess(results, "push")[0], expected, name)
        for name in checker.MERGE_ONLY:
            results = success | {name: {"result": "skipped"}}
            self.assertEqual(checker.assess(results, "schedule")[0], [name], name)

    def test_the_workflow_runs_merge_tier_jobs_only_on_schedule_or_dispatch(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        guarded = set(
            re.findall(
                r"^  ([a-z0-9-]+):\n    if: github.event_name == 'schedule' \|\| github.event_name == 'workflow_dispatch'\n",
                workflow,
                re.M,
            )
        )
        self.assertEqual(guarded, checker.MERGE_ONLY)
        self.assertIn(
            "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
            workflow.split("  current-stable-clippy:\n", 1)[1].split("  integration:\n", 1)[0],
        )

    def test_github_docker_hub_jobs_authenticate_when_secrets_exist(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        soak = (ROOT / ".github/workflows/gtk-soak.yml").read_text()
        action = (ROOT / ".github/actions/dockerhub-login/action.yml").read_text()
        self.assertIn("if: inputs.username != ''", action)
        self.assertNotIn("echo \"$DOCKERHUB_TOKEN\"", action)
        self.assertNotIn("echo '${{ inputs.password }}'", action)
        fast = re.search(r"^  fast:\n(.*?)(?=^  [a-z0-9-]+:|\Z)", workflow, re.M | re.S).group(1)
        ensure = re.search(r"^  ensure-ci-gtk-image:\n(.*?)(?=^  [a-z0-9-]+:|\Z)", workflow, re.M | re.S).group(1)
        self.assertIn(
            "image: ghcr.io/cozygarage/bookie/ci-debian-testing-gtk:${{ needs.ensure-ci-gtk-image.outputs.tag }}",
            fast,
        )
        self.assertNotIn("needs.ensure-ci-gtk-image.outputs.image", fast)
        self.assertIn("secrets.GITHUB_TOKEN", fast)
        self.assertIn("./.github/actions/dockerhub-login", fast)
        self.assertIn("secrets.DOCKERHUB_USERNAME", fast)
        self.assertIn("secrets.DOCKERHUB_TOKEN", fast)
        self.assertIn("ghcr.io/cozygarage/bookie/ci-debian-testing-gtk", ensure)
        self.assertIn("tag: ${{ steps.publish.outputs.tag }}", ensure)
        self.assertIn("./.github/actions/dockerhub-login", ensure)
        for job in ["gtk-safety", "current-stable-clippy", "duckdb"]:
            section = re.search(rf"^  {job}:\n(.*?)(?=^  [a-z0-9-]+:|\Z)", workflow, re.M | re.S).group(1)
            self.assertIn("image: debian:testing", section, job)
            self.assertIn("secrets.DOCKERHUB_USERNAME", section, job)
            self.assertIn("secrets.DOCKERHUB_TOKEN", section, job)
        for job in ["fast", "integration", "b4-rollback", "driver-tls", "postgres-release"]:
            section = re.search(rf"^  {job}:\n(.*?)(?=^  [a-z0-9-]+:|\Z)", workflow, re.M | re.S).group(1)
            self.assertIn("./.github/actions/dockerhub-login", section, job)
        self.assertIn("secrets.DOCKERHUB_USERNAME", soak)
        self.assertIn("secrets.DOCKERHUB_TOKEN", soak)

    def test_only_push_and_pr_can_skip_current_stable_clippy(self):
        results = {name: {"result": "success"} for name in checker.REQUIRED}
        results[checker.SCHEDULED] = {"result": "skipped"}
        for event in ["push", "pull_request"]:
            self.assertEqual(checker.assess(results, event)[0], [])
        for event in ["schedule", "workflow_dispatch"]:
            self.assertEqual(checker.assess(results, event)[0], [checker.SCHEDULED])

    def test_summary_depends_on_every_required_job_and_always_runs(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        section = workflow.split("  regression-gate:\n", 1)[1]
        self.assertIn("if: always()", section)
        self.assertIn("CI_JOB_RESULTS: ${{ toJSON(needs) }}", section)
        self.assertIn("python3 scripts/check-ci-jobs.py", section)
        for name in checker.REQUIRED | {checker.SCHEDULED}:
            self.assertIn(f"      - {name}\n", section)

    def test_b4_rollback_gate_runs_focused_mysql_and_postgres_tests_before_broad_integration(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        focused = workflow.split("  b4-rollback:\n", 1)[1].split("  driver-tls:\n", 1)[0]
        for required in [
            "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
            "prefix-key: linux-integration",
            "run-test-layer.py b4-rollback",
            "regression-b4-rollback-${{ github.run_id }}-${{ github.run_attempt }}",
        ]:
            self.assertIn(required, focused)
        integration = workflow.split("  integration:\n", 1)[1].split("  b4-rollback:\n", 1)[0]
        self.assertIn("needs: [pin-revision, b4-rollback]", integration)
        layers = json.loads((ROOT / "scripts/test-layers.json").read_text())["layers"]["b4-rollback"]
        commands = [step["argv"] for step in layers["steps"]]
        self.assertEqual(len(commands), 2)
        self.assertIn("mysql_atomic", commands[0])
        self.assertIn(
            "rollback_failure::a_batch_reports_rollback_failure_after_postgres_terminates_its_backend",
            commands[1],
        )

    def test_mysql_approval_dialog_runs_in_hosted_installed_gtk_acceptance(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        acceptance = workflow.split("  postgres-release:\n", 1)[1].split("  duckdb:\n", 1)[0]
        self.assertIn("Build staged release GTK binary", acceptance)
        self.assertIn("TABLEPRO_GTK_BINARY: target/installed/usr/bin/tablepro", acceptance)
        self.assertIn("bash scripts/test-gtk-mysql-approval.sh", acceptance)

    def test_docker_ssh_targets_run_in_hosted_and_local_integration(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        hosted = workflow.split("  integration:\n", 1)[1].split("  b4-rollback:\n", 1)[0]
        local = (ROOT / "scripts/ci-local.sh").read_text().split("run_integration() {", 1)[1].split("run_release()", 1)[0]
        self.assertIn("run-test-layer.py drivers", hosted)
        self.assertIn("scripts/test-ssh.sh", local)
        script = (ROOT / "scripts/test-ssh.sh").read_text()
        for required in ["set -euo pipefail", "--test agent_auth", "--test openssh_session", "--include-ignored", "--test-threads=1"]:
            self.assertIn(required, script)

    def test_postgres_release_openssh_test_is_listed_in_its_actual_tier(self):
        ledger = subprocess.check_output(["python3", str(ROOT / "scripts/inventory-ignored-tests.py")], text=True)
        self.assertIn(
            "agentd_refuses_without_learning_an_unknown_system_openssh_key_then_queries_after_trust](../crates/agentd/tests/g5_system_openssh.rs) | Release",
            ledger,
        )
        self.assertIn("scripts/test-postgres-release.sh", ledger)

    def test_postgres_release_gtk_uses_the_staged_release_binary(self):
        workflow = (ROOT / ".github/workflows/build-linux.yml").read_text()
        release = workflow.split("  postgres-release:\n", 1)[1].split("  duckdb:\n", 1)[0]
        self.assertIn("timeout-minutes: 45", release)
        self.assertIn("cargo build --locked --release -p tablepro-app", release)
        self.assertIn("target/release/tablepro-app target/installed/usr/bin/tablepro", release)
        self.assertIn("TABLEPRO_GTK_BINARY: target/installed/usr/bin/tablepro", release)

    def test_postgres_release_default_covers_b4_ssh_audit_and_reconnect_scenarios(self):
        script = (ROOT / "scripts/test-postgres-release.sh").read_text()
        default_scenarios = next(
            line for line in script.splitlines() if 'TABLEPRO_GTK_SCENARIO="${TABLEPRO_GTK_SCENARIO:-' in line
        )
        for scenario in [
            "postgres_ssh_unknown_host_key_decline_is_durably_audited",
            "postgres_ssh_multihop_trusts_both_hops_and_queries",
            "postgres_ssh_setup_failure_is_durably_audited",
            "postgres_ssh_tunnel_loss_retires_session_and_reconnects",
            "postgres_ssh_second_hop_decline_does_not_learn_key",
            "postgres_ssh_changed_second_hop_key_is_refused",
        ]:
            with self.subTest(scenario=scenario):
                self.assertIn(scenario, default_scenarios)

    def test_analysis_and_flatpak_skip_docs_and_reuse_cache(self):
        cancel_push_or_pr = (
            "cancel-in-progress: ${{ github.event_name == 'pull_request' || github.event_name == 'push' }}"
        )
        for name in ["codeql.yml", "sonar-rust.yml"]:
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn('"!docs/**"', workflow)
            self.assertIn('"!**.md"', workflow)
            self.assertIn('"**"', workflow)
            self.assertIn(
                cancel_push_or_pr,
                workflow.split("concurrency:", 1)[1].split("jobs:", 1)[0],
            )
        flatpak = (ROOT / ".github/workflows/flatpak-linux.yml").read_text()
        self.assertIn(
            "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            flatpak.split("concurrency:", 1)[1].split("jobs:", 1)[0],
        )
        self.assertIn("hashFiles('apps/linux/flatpak/**')", flatpak)
        self.assertNotIn("github.sha }}", flatpak.split("cache-key:", 1)[1].split("\n", 1)[0])
        self.assertIn("""'["default"]' || '["default","development"]'""", flatpak)
        self.assertNotIn("matrix.manifest", flatpak)
        contracts = (ROOT / ".github/workflows/linux-ci-contracts.yml").read_text()
        self.assertIn(
            cancel_push_or_pr,
            contracts.split("concurrency:", 1)[1].split("jobs:", 1)[0],
        )

    def test_sonar_imports_python_tool_coverage_report(self):
        workflow = (ROOT / ".github/workflows/sonar-rust.yml").read_text()
        self.assertIn("coverage==7.10.6", workflow)
        self.assertIn("coverage run --branch --source=scripts", workflow)
        self.assertIn("unittest discover -s scripts/tests", workflow)
        self.assertIn("coverage xml -o target/sonar/python-coverage.xml", workflow)
        self.assertIn("-Dsonar.python.coverage.reportPaths=target/sonar/python-coverage.xml", workflow)


    def test_arch_package_container_mounts_the_repository_root(self):
        script = (ROOT / "scripts/test-arch-package-container.sh").read_text()
        self.assertIn('-v "$PWD:/src:ro"', script)
        self.assertNotIn('$PWD/..', script)

    def test_nightly_soak_installs_the_binary_under_usr_bin(self):
        nightly = (ROOT / ".forgejo/workflows/nightly.yml").read_text()
        soak = nightly.split("\n  gtk-soak:\n", 1)[1].split("\n  arch-package:\n", 1)[0]
        self.assertIn('binary="$PWD/target-soak-${{ matrix.run }}/usr/bin/tablepro"', soak)

    def test_forgejo_workflows_use_no_node_actions_on_host_executors(self):
        for workflow in (ROOT / ".forgejo/workflows").glob("*.yml"):
            self.assertNotIn("uses:", workflow.read_text(), workflow.name)

    def test_forgejo_distro_floor_reuses_one_package_across_bases(self):
        workflow = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        self.assertNotIn("\n  distro-floor-build:\n", workflow)
        floor = workflow.split("\n  distro-floor:\n", 1)[1].split("\n  driver:\n", 1)[0]
        self.assertIn("scripts/distro-floor-package.sh", floor)
        self.assertIn("DISTRO_FLOOR_PACKAGE=", floor)
        self.assertIn("PREBUILT_DEB=", floor)
        builder = (ROOT / "scripts/distro-floor-package.sh").read_text()
        self.assertIn("BASE=ubuntu:24.04", builder)
        self.assertIn("scripts/build-deb.sh", builder)
        self.assertIn("flock", builder)
        self.assertIn("chown", builder)
        floor_script = (ROOT / "scripts/test-distro-floor.sh").read_text()
        self.assertIn('apt-get install -y -qq "/package/$DISTRO_FLOOR_DEB_NAME"', floor_script)
        self.assertLess(floor_script.index('if [ -n "${DISTRO_FLOOR_DEB_NAME:-}" ]'), floor_script.index("pkg-config --modversion"))
        self.assertIn('cp "/prebuilt/$PREBUILT_DEB_NAME"', (ROOT / "scripts/test-deb-package.sh").read_text())
        gtk_safety_script = (ROOT / "scripts/test-gtk-safety.sh").read_text()
        self.assertIn('timeout 600s python3 -u "$ROOT/apps/linux/app/tests/gtk_safety.py"', gtk_safety_script)
        runtime_image = (ROOT / "scripts/distro-floor/Dockerfile.runtime").read_text()
        self.assertIn("python3-pyatspi", runtime_image)
        self.assertIn("gir1.2-gtk-4.0", runtime_image)
        self.assertNotIn("rustup", runtime_image)


if __name__ == "__main__":
    unittest.main()
