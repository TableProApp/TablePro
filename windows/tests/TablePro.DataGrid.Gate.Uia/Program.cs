using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

// The gate writes uia-<name>.request into its out folder and waits for uia-<name>.done (lane wingates2, tool/).
var outDir = args.Length > 1 ? args[1] : Path.Combine(Path.GetTempPath(), "grid-gate");
var seconds = args.Length > 2 ? int.Parse(args[2], CultureInfo.InvariantCulture) : 3600;
Directory.CreateDirectory(outDir);
var clock = Stopwatch.StartNew();
while (clock.Elapsed.TotalSeconds < seconds && !File.Exists(Path.Combine(outDir, "stop")))
{
    foreach (var request in Directory.GetFiles(outDir, "uia-*.request"))
    {
        var name = Path.GetFileNameWithoutExtension(request);
        var pid = int.Parse(File.ReadAllText(request).Trim(), CultureInfo.InvariantCulture);
        var result = new JsonObject();
        try
        {
            using var automation = new UIA3Automation();
            var app = FlaUI.Core.Application.Attach(pid);
            var window = app.GetMainWindow(automation, TimeSpan.FromSeconds(20)) ?? throw new InvalidOperationException("no main window");
            Uia.Grid(automation, window, result);
        }
        catch (Exception ex)
        {
            result["error"] = ex.ToString();
        }
        File.WriteAllText(Path.Combine(outDir, name + ".json"), result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Delete(request);
        File.WriteAllText(Path.Combine(outDir, name + ".done"), "ok");
        Console.WriteLine($"{name} done");
    }
    Thread.Sleep(250);
}

internal static class Uia
{
    public static void Grid(UIA3Automation automation, Window window, JsonObject o)
    {
        var sw = Stopwatch.StartNew();
        var grid = window.FindFirstDescendant(cf => cf.ByClassName("DataGridView"))
            ?? window.FindFirstDescendant(cf => cf.ByControlType(ControlType.DataGrid))
            ?? throw new InvalidOperationException("grid not found");
        o["find_grid_ms"] = sw.ElapsedMilliseconds;
        o["grid"] = $"class={Class(grid)} type={grid.ControlType} name='{Name(grid)}'";
        o["patterns"] = $"Grid={grid.Patterns.Grid.IsSupported} Table={grid.Patterns.Table.IsSupported} Selection={grid.Patterns.Selection.IsSupported}";
        var gp = grid.Patterns.Grid.Pattern;
        o["grid_pattern"] = $"RowCount={gp.RowCount.Value} ColumnCount={gp.ColumnCount.Value}";
        var tp = grid.Patterns.Table.Pattern;
        try
        {
            var native = ((FlaUI.UIA3.Patterns.TablePattern)tp).NativePattern.GetCurrentColumnHeaders();
            o["table_column_headers"] = $"length={native.Length} major={tp.RowOrColumnMajor.ValueOrDefault}";
        }
        catch (Exception ex)
        {
            o["table_column_headers"] = $"{ex.GetType().Name} 0x{ex.HResult:X8}";
        }
        var headerItems = grid.FindAllDescendants(cf => cf.ByControlType(ControlType.HeaderItem));
        o["header_items_in_tree"] = $"{headerItems.Length} first='{(headerItems.Length > 0 ? Name(headerItems[0]) : "")}' invoke={(headerItems.Length > 0 && headerItems[0].Patterns.Invoke.IsSupported)}";
        sw.Restart();
        var selected = grid.Patterns.Selection.Pattern.Selection.ValueOrDefault ?? [];
        o["selection_pattern"] = $"can_select_multiple={grid.Patterns.Selection.Pattern.CanSelectMultiple.ValueOrDefault} selected={selected.Length} ms={sw.ElapsedMilliseconds} first={(selected.Length > 0 ? Cell(selected[0]) : "")} last={(selected.Length > 0 ? Cell(selected[^1]) : "")}";
        try
        {
            var target = gp.GetItem(2, 3);
            var bounds = target.BoundingRectangle;
            var center = new System.Drawing.Point(bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2));
            var hit = automation.FromPoint(center);
            o["hit_test"] = $"cell (2,3) bounds={bounds} from_point({center.X},{center.Y}): {Cell(hit)}";
        }
        catch (Exception ex)
        {
            o["hit_test"] = $"{ex.GetType().Name}: {ex.Message}";
        }
        var items = new JsonArray();
        foreach (var (r, c) in new[] { (2, 3), (0, 0), (500_000, 150), (999_999, 199) })
        {
            sw.Restart();
            try
            {
                var cell = gp.GetItem(r, c);
                var offscreen = cell.Properties.IsOffscreen.ValueOrDefault;
                items.Add($"GetItem({r},{c}) {sw.ElapsedMilliseconds} ms: {Cell(cell)} offscreen={offscreen} scroll_item={cell.Patterns.ScrollItem.IsSupported}");
            }
            catch (Exception ex)
            {
                items.Add($"GetItem({r},{c}): {ex.GetType().Name}: {ex.Message}");
            }
        }
        o["get_item"] = items;
        sw.Restart();
        var cells = grid.FindAllDescendants(cf => cf.ByControlType(ControlType.DataItem));
        o["cells_in_uia_tree"] = cells.Length;
        o["cells_find_ms"] = sw.ElapsedMilliseconds;
        o["sample_cells"] = new JsonArray(cells.Take(4).Select(c => (JsonNode)Cell(c)).ToArray());
        var focused = automation.FocusedElement();
        o["focused"] = focused is null ? "none" : $"{focused.ControlType} class={Class(focused)} name='{Name(focused)}'";
    }

    private static string Cell(AutomationElement cell)
    {
        var grid = cell.Patterns.GridItem.IsSupported
            ? $"row={cell.Patterns.GridItem.Pattern.Row.Value} col={cell.Patterns.GridItem.Pattern.Column.Value}"
            : "no GridItem";
        var header = cell.Patterns.TableItem.IsSupported
            ? string.Join("|", (cell.Patterns.TableItem.Pattern.ColumnHeaderItems.ValueOrDefault ?? []).Select(Name))
            : "no TableItem";
        var selected = cell.Patterns.SelectionItem.IsSupported ? cell.Patterns.SelectionItem.Pattern.IsSelected.Value.ToString() : "n/a";
        return $"type={cell.ControlType} class={Class(cell)} {grid} header='{header}' name='{Name(cell)}' selected={selected}";
    }

    private static string Name(AutomationElement e) => e.Properties.Name.ValueOrDefault ?? "";

    private static string Class(AutomationElement e) => e.Properties.ClassName.ValueOrDefault ?? "";
}
