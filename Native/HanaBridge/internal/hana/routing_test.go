package hana

import "testing"

func TestStatementRouting(t *testing.T) {
	cases := []struct {
		statement string
		keyword   string
		exec      bool
	}{
		{"INSERT INTO T VALUES (1)", "INSERT", true},
		{"update t set c = 1", "UPDATE", true},
		{"Delete From T", "DELETE", true},
		{"UPSERT T VALUES (1) WITH PRIMARY KEY", "UPSERT", true},
		{"REPLACE T VALUES (1) WITH PRIMARY KEY", "REPLACE", true},
		{"MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET T.C = S.C", "MERGE", true},
		{"  \n\tINSERT INTO T VALUES (1)", "INSERT", true},
		{"\uFEFFINSERT INTO T VALUES (1)", "INSERT", true},
		{"-- note\nINSERT INTO T VALUES (1)", "INSERT", true},
		{"-- note\r\nDELETE FROM T", "DELETE", true},
		{"/* leading */ UPDATE T SET C = 1", "UPDATE", true},
		{"/* one */ -- two\n /* three */INSERT INTO T VALUES (1)", "INSERT", true},
		{"(INSERT INTO T VALUES (1))", "INSERT", true},
		{";;INSERT INTO T VALUES (1)", "INSERT", true},
		{"; -- after an empty statement\nDELETE FROM T", "DELETE", true},
		{"SELECT * FROM T", "SELECT", false},
		{"(SELECT 1 FROM DUMMY)", "SELECT", false},
		{"WITH X AS (SELECT 1 AS A FROM DUMMY) SELECT * FROM X", "WITH", false},
		{"CALL P()", "CALL", false},
		{"DO BEGIN SELECT 1 FROM DUMMY; END", "DO", false},
		{"CREATE TABLE T (C INTEGER)", "CREATE", false},
		{"EXPLAIN PLAN FOR SELECT 1 FROM DUMMY", "EXPLAIN", false},
		{"SET SCHEMA APP", "SET", false},
		{"INSERTED_ROWS", "INSERTED_ROWS", false},
		{"INSERT1 INTO T", "INSERT1", false},
		{"-- only a comment", "", false},
		{"/* unterminated", "", false},
		{"", "", false},
		{"   ", "", false},
	}
	for _, testCase := range cases {
		if keyword := leadingKeyword(testCase.statement); keyword != testCase.keyword {
			t.Errorf("leadingKeyword(%q) = %q; want %q", testCase.statement, keyword, testCase.keyword)
		}
		if exec := routesToExec(testCase.statement); exec != testCase.exec {
			t.Errorf("routesToExec(%q) = %v; want %v", testCase.statement, exec, testCase.exec)
		}
	}
}
