using TablePro.Core.Debugging;

namespace TablePro.Core.Tests.Debugging;

public sealed class PlSqlDeclarationScanTests
{
    // A package body as ALL_SOURCE returns it, from the macOS app's measurements.
    private const string PackageBody = """
        package body pkg_calc as
          g_rate number := 0.1;
          function add_tax(p_amount number) return number is
            l_tax number;
          begin
            l_tax := p_amount * g_rate;
            return p_amount + l_tax;
          end add_tax;
          procedure run(p_n pls_integer) is
            l_total number := 0;
            l_name  varchar2(30) := 'probe';
          begin
            for i in 1 .. p_n loop
              l_total := l_total + add_tax(i);
            end loop;
            dbms_output.put_line(l_name || ' total=' || l_total);
          end run;
          function add_tax(p_amount number, p_rate number) return number is
          begin
            return p_amount + p_amount * p_rate;
          end add_tax;
        end pkg_calc;
        """;

    private static string[] Names(IEnumerable<PlSqlDeclaration> declarations) => [.. declarations.Select(d => d.Name)];

    [Fact]
    public void FindsSubprogramsAndTheirLineRanges()
    {
        var scan = new PlSqlDeclarationScan(PackageBody);

        Assert.Equal(["ADD_TAX 3-8", "RUN 9-17", "ADD_TAX 18-21"], scan.Subprograms.Select(s => $"{s.Name} {s.HeaderLine}-{s.EndLine}"));
        Assert.Equal([3, 18], scan.HeaderLines("ADD_TAX"));
        Assert.Equal([9], scan.HeaderLines("RUN"));
    }

    [Fact]
    public void CandidatesFollowTheFrameLine()
    {
        var scan = new PlSqlDeclarationScan(PackageBody);

        Assert.Equal(["P_AMOUNT", "L_TAX"], Names(scan.Candidates(6)));
        Assert.Equal([PlSqlDeclarationKind.Parameter, PlSqlDeclarationKind.Variable], scan.Candidates(6).Select(d => d.Kind));
        Assert.Equal(["P_N", "L_TOTAL", "L_NAME", "I"], Names(scan.Candidates(14)));
        Assert.Equal(["P_N", "L_TOTAL", "L_NAME"], Names(scan.Candidates(9)));
        Assert.Equal(["P_AMOUNT", "P_RATE"], Names(scan.Candidates(20)));
        Assert.Equal("VARCHAR2(30)", scan.Candidates(11).First(d => d.Name == "L_NAME").TypeText);
        Assert.Equal(["G_RATE"], Names(scan.PackageVariables));
    }

    [Fact]
    public void ALoopIndexIsVisibleOnlyInsideItsLoop()
    {
        Assert.Equal(["P_N", "L_TOTAL", "L_NAME"], Names(new PlSqlDeclarationScan(PackageBody).Candidates(16)));

        var shadowing = new PlSqlDeclarationScan("""
            procedure p is
              i varchar2(10) := 'outer';
            begin
              for i in 1 .. 2 loop
                null;
              end loop;
              null;
            end p;
            """);
        Assert.Equal(PlSqlDeclarationKind.Iterator, shadowing.Candidates(5).First(d => d.Name == "I").Kind);
        Assert.Equal(PlSqlDeclarationKind.Variable, shadowing.Candidates(7).First(d => d.Name == "I").Kind);
    }

    [Fact]
    public void TypesCursorsExceptionsAndConstantsAreToldApart()
    {
        var scan = new PlSqlDeclarationScan("""
            function f_calc(p_a number, p_b in out nocopy varchar2 default 'x') return number is
              type t_rec is record (a number, b varchar2(10));
              cursor c_rows is select 1 from dual;
              e_bad exception;
              pragma exception_init(e_bad, -20001);
              c_limit constant pls_integer := 10;
              l_rec t_rec;
            begin
              return p_a * 2;
            end f_calc;
            """);

        Assert.Equal(["P_A", "P_B", "C_LIMIT", "L_REC"], Names(scan.Candidates(9)));
        Assert.Equal(PlSqlDeclarationKind.Constant, scan.Candidates(9).First(d => d.Name == "C_LIMIT").Kind);
        Assert.Equal("VARCHAR2", scan.Candidates(9).First(d => d.Name == "P_B").TypeText);
    }

    [Fact]
    public void CommentsStringsAndQuotedNamesDoNotConfuseTheScan()
    {
        var scan = new PlSqlDeclarationScan("""
            procedure p is
              -- procedure fake is begin end;
              /* function g return number is begin return 1; end; */
              l_text varchar2(100) := q'[it's begin; end]';
              "Mixed Case" number;
            begin
              l_text := 'end; begin';
              declare
                l_inner number;
              begin
                null;
              end;
              case when l_text is null then null; else null; end case;
            end p;
            """);

        Assert.Equal(["P"], scan.Subprograms.Select(s => s.Name));
        Assert.Equal(14, scan.Subprograms[0].EndLine);
        Assert.Equal(["L_TEXT", "Mixed Case"], Names(scan.Candidates(7)));
        Assert.Equal(["L_TEXT", "Mixed Case", "L_INNER"], Names(scan.Candidates(11)));
    }

    [Fact]
    public void AnInnerBlockShadowsAnOuterNameOnlyWhileItRuns()
    {
        var scan = new PlSqlDeclarationScan("""
            procedure p_shadow is
              x constant number := 1;
              l_outer number := 2;
            begin
              declare
                x varchar2(20) := 'inner';
              begin
                l_outer := l_outer + 1;
              end;
              l_outer := x;
            end p_shadow;
            """);

        var inside = scan.Candidates(8);
        Assert.Equal(["L_OUTER", "X"], Names(inside));
        Assert.Equal("VARCHAR2(20)", inside.First(d => d.Name == "X").TypeText);
        Assert.Equal(PlSqlDeclarationKind.Variable, inside.First(d => d.Name == "X").Kind);

        var after = scan.Candidates(10);
        Assert.Equal(["X", "L_OUTER"], Names(after));
        Assert.Equal("NUMBER", after.First(d => d.Name == "X").TypeText);
        Assert.Equal(PlSqlDeclarationKind.Constant, after.First(d => d.Name == "X").Kind);
    }

    [Fact]
    public void ANestedBlockIsVisibleOnlyInsideItAndToSubprogramsItDeclares()
    {
        var scan = new PlSqlDeclarationScan("""
            procedure p_nested(p_n number) is
              l_a number := 1;
            begin
              declare
                l_b number := 2;
                procedure show(p_v number) is
                begin
                  dbms_output.put_line(p_v + l_b);
                end show;
              begin
                show(l_a);
              end;
              l_a := l_a + p_n;
            end p_nested;
            """);

        Assert.Equal(["P_V", "P_N", "L_A", "L_B"], Names(scan.Candidates(8)));
        Assert.Equal(["P_N", "L_A", "L_B"], Names(scan.Candidates(11)));
        Assert.Equal(["P_N", "L_A"], Names(scan.Candidates(13)));
    }

    [Fact]
    public void AQuotedNameIsShadowedOnlyByTheSameName()
    {
        var scan = new PlSqlDeclarationScan("""
            procedure p_case is
              "x" number := 1;
              "Y" number := 2;
            begin
              declare
                x varchar2(20) := 'upper';
                y varchar2(5) := 'y';
              begin
                null;
              end;
              null;
            end p_case;
            """);

        var inside = scan.Candidates(9);
        Assert.Equal(["\"x\"", "X", "Y"], inside.Select(d => d.LookupName));
        Assert.Equal(["NUMBER", "VARCHAR2(20)", "VARCHAR2(5)"], inside.Select(d => d.TypeText));

        var after = scan.Candidates(11);
        Assert.Equal(["\"x\"", "\"Y\""], after.Select(d => d.LookupName));
        Assert.Equal(["NUMBER", "NUMBER"], after.Select(d => d.TypeText));
    }

    [Fact]
    public void AQuotedNameIsLookedUpQuotedAndShownBare()
    {
        var scan = new PlSqlDeclarationScan("""
            package body pkg_quoted as
              "g.Rate" number := 0.2;
              procedure run("p.in" number) is
                "a.b" number := 7;
                "lower" number;
                "with space" varchar2(10);
                l_plain number;
              begin
                for "i.x" in 1 .. 2 loop
                  null;
                end loop;
              end run;
            end pkg_quoted;
            """);

        var candidates = scan.Candidates(10);
        Assert.Equal(["p.in", "a.b", "lower", "with space", "L_PLAIN", "i.x"], Names(candidates));
        Assert.Equal(["\"p.in\"", "\"a.b\"", "\"lower\"", "\"with space\"", "L_PLAIN", "\"i.x\""], candidates.Select(d => d.LookupName));
        Assert.Equal(["g.Rate"], Names(scan.PackageVariables));
        Assert.Equal(["\"g.Rate\""], scan.PackageVariables.Select(d => d.LookupName));
    }

    [Fact]
    public void ASpecificationListsOnlyItsVariables()
    {
        var scan = new PlSqlDeclarationScan("""
            package pkg_calc as
              g_spec_count pls_integer := 0;
              function add_tax(p_amount number) return number;
              procedure run(p_n pls_integer);
            end pkg_calc;
            """);

        Assert.Equal(["G_SPEC_COUNT"], Names(scan.PackageVariables));
        Assert.DoesNotContain(scan.Declarations, d => d.Kind == PlSqlDeclarationKind.Parameter);
        Assert.Empty(scan.HeaderLines("RUN"));
    }

    [Fact]
    public void AnExternalBodyHasNothingToStepThrough()
    {
        var scan = new PlSqlDeclarationScan("""
            package body pkg_ext as
              function native_sum(p_a number) return number as language c name "sum" library ext_lib;
              procedure run(p_n number) is
              begin
                null;
              end run;
            end pkg_ext;
            """);

        Assert.Empty(scan.HeaderLines("NATIVE_SUM"));
        Assert.Equal([3], scan.HeaderLines("RUN"));
        Assert.Equal(["P_N"], Names(scan.Candidates(5)));
    }
}
