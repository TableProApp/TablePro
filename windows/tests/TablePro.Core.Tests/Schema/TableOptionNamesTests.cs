using System.Globalization;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Schema;

public sealed class TableOptionNamesTests
{
    [Fact]
    public void ASharedOptionShowsInTheUiLanguageWhileItsNameStaysEnglish()
    {
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");

            Assert.Equal("Jeu de caractères", TableOptionNames.DisplayName(TableOptionNames.Charset));
            // DDL builders switch on the constant, so translating it would break saving.
            Assert.Equal("Character set", TableOptionNames.Charset);
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [Fact]
    public void AnOptionADriverNamedItselfShowsAsWritten() =>
        Assert.Equal("Partition count", TableOptionNames.DisplayName("Partition count"));
}
