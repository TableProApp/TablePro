import sqlite3


def scenarios(ui):
    def repeated_parameters_preserve_wide_ids_and_sql_like_text(database, _base):
        sql = "INSERT INTO safety_items(id, note) VALUES (:large, :note), (:small, :note)"
        payload = "x'); DROP TABLE safety_items; -- 東京 😀 :large ? $1"
        ui.run_sql(sql)
        ui.wait_for_node(name=":large")
        ui.set_text_by_name(":large", "9223372036854775807")
        ui.set_text_by_name(":small", "-9223372036854775808")
        ui.set_text_by_name(":note", payload)
        ui.invoke(ui.wait_for_node(name="Run with values", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Run with values", present=False)
        ui.wait_for_database_count(database, 2)
        with sqlite3.connect(database) as connection:
            rows = connection.execute("SELECT id, note FROM safety_items ORDER BY id").fetchall()
        assert rows == [(-9223372036854775808, payload), (9223372036854775807, payload)], rows

    def cancelled_parameters_never_execute_and_retry_uses_new_values(database, _base):
        sql = "INSERT INTO safety_items(id, note) VALUES (:id, :note)"
        ui.run_sql(sql)
        ui.wait_for_node(name=":id")
        ui.set_text_by_name(":id", "41")
        ui.set_text_by_name(":note", "cancelled value")
        ui.invoke(ui.wait_for_node(name="Cancel", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Run with values", present=False)
        ui.assert_database_count_stable(database, 0)
        ui.run_sql(sql)
        ui.wait_for_node(name=":id")
        ui.set_text_by_name(":id", "42")
        ui.set_text_by_name(":note", "replacement value")
        ui.invoke(ui.wait_for_node(name="Run with values", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Run with values", present=False)
        ui.wait_for_database_count(database, 1)
        with sqlite3.connect(database) as connection:
            rows = connection.execute("SELECT id, note FROM safety_items").fetchall()
        assert rows == [(42, "replacement value")], rows

    result = [repeated_parameters_preserve_wide_ids_and_sql_like_text,
              cancelled_parameters_never_execute_and_retry_uses_new_values]
    for scenario in result:
        scenario.environment = "local"
    return result
