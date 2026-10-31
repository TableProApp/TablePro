using System.Globalization;
using System.Text;
using System.Text.Json;
using TablePro.Core.Localization;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;
using TablePro.Mcp.Protocol;
using TablePro.Mcp.Tools;

namespace TablePro.Mcp.Tests;

public sealed class LanguageTests
{
    [Fact]
    public async Task ToolResultsStayEnglishWhenTheAppShowsAnotherLanguage()
    {
        var options = new McpServerOptions();
        var host = new FakeHost { ProfilesFailure = new WordedWhenReadException() };
        var handler = new McpProtocolHandler(new McpTools(host, options), new McpAuditLog(), options);
        var request = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}"""u8.ToArray();
        var saved = CultureInfo.CurrentUICulture;
        byte[]? answer;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");
            answer = await handler.HandleAsync(request, McpPrincipal.Owner, TestContext.Current.CancellationToken);

            // The pin stays inside the request: the caller's language is untouched.
            Assert.Equal("fr", CultureInfo.CurrentUICulture.Name);
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }

        var text = JsonDocument.Parse(Encoding.UTF8.GetString(answer!)).RootElement
            .GetProperty("result").GetProperty("content")[0].GetProperty("text").GetString();
        Assert.Equal("internal_failure: This connection is read-only, so nothing was saved.", text);
    }

    /// <summary>A failure worded when its message is read, as a driver's message is in the culture of the moment.</summary>
    private sealed class WordedWhenReadException : Exception
    {
        public override string Message => CoreStrings.Get("Driver/ReadOnlyNothingSaved");
    }
}
