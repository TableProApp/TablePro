namespace TablePro.Drivers.Beancount.Tests;

/// <summary>
/// What rledger 0.23 prints for the sample ledger, one answer per query. It rejects the semantic posting columns and
/// account booking, as an older build would, so the projection's fallbacks run.
/// </summary>
internal static class RledgerResponses
{
    public static FakeProcessRunner Runner(Func<string, ProcessOutput?>? overrides = null) => new(spec => Answer(spec, overrides));

    private static ProcessOutput Answer(ProcessSpec spec, Func<string, ProcessOutput?>? overrides)
    {
        var arguments = spec.Arguments;
        if (arguments is ["--version"])
        {
            return FakeProcessRunner.Ok("0.23.1\n");
        }

        if (arguments is ["query", "--help"])
        {
            return FakeProcessRunner.Ok("Usage: rledger query [OPTIONS] <FILE> <QUERY>\n      --no-cache  Skip the cache\n");
        }

        if (arguments.Count > 0 && arguments[0] == "check")
        {
            return new ProcessOutput(
                System.Text.Encoding.UTF8.GetBytes("""{"diagnostics":[{"file":"f","line":3,"column":1,"severity":"error","phase":"validation","code":"E2001","message":"Balance failed"}]}"""),
                string.Empty,
                1);
        }

        var bql = arguments[^1];
        if (overrides?.Invoke(bql) is { } overridden)
        {
            return overridden;
        }

        if (bql.Contains("posting_flag", StringComparison.Ordinal))
        {
            return FakeProcessRunner.Fail("error: unknown column 'posting_flag'");
        }

        if (bql.Contains("booking", StringComparison.Ordinal))
        {
            return FakeProcessRunner.Fail("error: unknown column 'booking'");
        }

        return bql switch
        {
            "SELECT * FROM #entries LIMIT 0" => FakeProcessRunner.Ok("""{"columns":["id","type","date","meta"],"rows":[]}"""),
            _ when bql.StartsWith("SELECT id, date, flag, payee, narration, filename, lineno, tags", StringComparison.Ordinal) => FakeProcessRunner.Ok("""
                {"columns":["id","date","flag","payee","narration","filename","lineno","tags","links","_entry_meta"],"rows":[
                  [1,"2026-01-05","*","Employer","January salary","f",5,["payroll"],["jan-2026"],{"filename":"f","lineno":5,"invoice":"INV-1"}],
                  [2,"2026-01-10","*","Grocer","Weekly shop","f",10,null,null,{"filename":"f","lineno":10}]]}
                """),
            _ when bql.StartsWith("SELECT id, date, flag, payee, narration, account", StringComparison.Ordinal) => FakeProcessRunner.Ok("""
                {"columns":["id","date","flag","payee","narration","account","number","currency","cost_number","cost_currency","filename","lineno","location","tags","links","_entry_meta","_posting_meta"],"rows":[
                  [1,"2026-01-05","*","Employer","January salary","Income:Salary","-2000.00","USD",null,null,"f",7,"f:7",["payroll"],["jan-2026"],null,null],
                  [1,"2026-01-05","*","Employer","January salary","Assets:Checking","2000.00","USD",null,null,"f",8,"f:8",["payroll"],["jan-2026"],null,null],
                  [2,"2026-01-10","*","Grocer","Weekly shop","Expenses:Food","50.00","USD",null,null,"f",11,"f:11",[],[],null,{"receipt":"R-17"}],
                  [2,"2026-01-10","*","Grocer","Weekly shop","Assets:Checking","-50.00","USD",null,null,"f",13,"f:13",[],[],null,null]]}
                """),
            "SELECT id, date, filename, lineno FROM #entries WHERE type = 'pad' ORDER BY id" =>
                FakeProcessRunner.Ok("""{"columns":["id","date","filename","lineno"],"rows":[[5,"2026-01-01","f",1]]}"""),
            "PRINT FROM FALSE" => FakeProcessRunner.Ok("""
                {"columns":["directive"],"rows":[["2026-01-01 open Assets:Checking USD\n"],["2026-01-01 pad Assets:Checking Equity:Opening\n"]]}
                """),
            "SELECT date, account, amount FROM #balances ORDER BY date, account" => FakeProcessRunner.Ok("""
                {"columns":["date","account","amount"],"rows":[
                  ["2026-01-02","Assets:Checking",{"number":"500.00","currency":"USD"}],
                  ["2026-02-01","Assets:Checking",{"number":"2450.00","currency":"USD"}]]}
                """),
            "SELECT account, open, currencies FROM #accounts ORDER BY account" => FakeProcessRunner.Ok("""
                {"columns":["account","open","currencies"],"rows":[["Assets:Checking","2026-01-01",["USD"]],["Expenses:Food","2026-01-01",["USD"]]]}
                """),
            "SELECT date, currency, amount FROM #prices ORDER BY date, currency" =>
                FakeProcessRunner.Ok("""{"columns":["date","currency","amount"],"rows":[["2026-03-01","EUR",{"number":"1.08","currency":"USD"}]]}"""),
            _ when bql.StartsWith("SELECT account, sum(units(position))", StringComparison.Ordinal) =>
                FakeProcessRunner.Ok("""{"columns":["account","balance"],"rows":[["Assets:Checking",{"positions":[{"number":"2450.00","currency":"USD"}]}]]}"""),
            "SELECT date, name FROM #commodities ORDER BY date, name" => FakeProcessRunner.Ok("""{"columns":["date","name"],"rows":[["2026-01-01","USD"]]}"""),
            "SELECT date, account, filename, tags, links FROM #documents ORDER BY date, account" =>
                FakeProcessRunner.Ok("""{"columns":["date","account","filename","tags","links"],"rows":[["2026-01-20","Assets:Checking","docs/statement.pdf",[],[]]]}"""),
            "SELECT date, account, comment FROM #notes ORDER BY date, account" =>
                FakeProcessRunner.Ok("""{"columns":["date","account","comment"],"rows":[["2026-01-15","Assets:Checking","Opened online"]]}"""),
            "SELECT account, close FROM #accounts WHERE close IS NOT NULL ORDER BY close, account" =>
                FakeProcessRunner.Ok("""{"columns":["account","close"],"rows":[["Expenses:Old","2026-06-30"]]}"""),
            _ when bql.StartsWith("SELECT id, type, date, filename, lineno", StringComparison.Ordinal) => FakeProcessRunner.Ok("""
                {"columns":["id","type","date","filename","lineno","_entry_meta"],"rows":[[3,"custom","2026-01-01","f",12,{"filename":"f","lineno":12,"owner":"radu"}]]}
                """),
            _ => FakeProcessRunner.Fail("error: table not supported"),
        };
    }
}
