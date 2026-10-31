using TablePro.Storage.Library.Folders;

namespace TablePro.Storage.Tests.Library;

public sealed class SqlFrontmatterTests
{
    [Fact]
    public void SplitKeepsEachHeaderLinesOwnTextAndLineEnding()
    {
        var document = SqlFrontmatter.Split("--@Name:  Revenue\r\n  -- @author: alice\n-- @x:1\rSELECT 1;\n");

        Assert.Equal(["--@Name:  Revenue", "  -- @author: alice", "-- @x:1"], document.Header.Select(l => l.Text));
        Assert.Equal(["\r\n", "\n", "\r"], document.Header.Select(l => l.Terminator));
        Assert.Equal(["name", "author", "x"], document.Header.Select(l => l.Key));
        Assert.Equal([SqlFrontmatterKey.Name, null, null], document.Header.Select(l => l.OwnedKey));
        Assert.Equal("SELECT 1;\n", document.Body);
    }

    [Fact]
    public void TheHeaderEndsAtTheFirstLineThatIsNotAKeyLine()
    {
        var document = SqlFrontmatter.Split("-- @name: Revenue\n\n-- @author: alice\nSELECT 1;");
        Assert.Equal(["name"], document.Header.Select(l => l.Key));
        Assert.Equal("\n-- @author: alice\nSELECT 1;", document.Body);
    }

    [Fact]
    public void AHeaderLineAtTheEndOfTheFileHasNoTerminator()
    {
        var document = SqlFrontmatter.Split("-- @name: Revenue");
        Assert.Equal([string.Empty], document.Header.Select(l => l.Terminator));
        Assert.Empty(document.Body);
    }

    [Fact]
    public void AByteOrderMarkIsKeptApartFromTheHeader()
    {
        var document = SqlFrontmatter.Split("﻿-- @name: Revenue\nSELECT 1;");
        Assert.Equal("﻿", document.ByteOrderMark);
        Assert.Equal(["-- @name: Revenue"], document.Header.Select(l => l.Text));
    }

    [Fact]
    public void OwnedKeysAreReadPastForeignOnesAndTheLastDuplicateWins()
    {
        var metadata = SqlFrontmatter.Parse("-- @formatter:off\n-- @name: First\n-- @author: alice\n-- @name: Second\n-- @keyword:\nSELECT 1;");
        Assert.Equal(new SqlFileMetadata("Second", null, null), metadata);
    }

    [Fact]
    public void RenamingKeepsEveryHeaderLineTheAppDoesNotOwnInPlace()
    {
        var rewritten = SqlFrontmatter.Rewrite("-- @author: alice\n-- @name: Old\n-- @ticket: 42\nSELECT 1;", new SqlFileMetadata("New"));
        Assert.Equal("-- @author: alice\n-- @name: New\n-- @ticket: 42\nSELECT 1;", rewritten);
    }

    [Fact]
    public void SavingTheMetadataTheFileAlreadyHasLeavesItByteForByte()
    {
        const string content = "--@name:   Revenue\r\n-- @keyword: rev\r\nSELECT 1;";
        Assert.Equal(content, SqlFrontmatter.Rewrite(content, new SqlFileMetadata("Revenue", "rev")));
    }

    [Fact]
    public void ANewKeyGoesBesideTheOwnedKeysInCanonicalOrder()
    {
        var rewritten = SqlFrontmatter.Rewrite("-- @formatter:off\n-- @name: Revenue\n-- @description: Monthly\nSELECT 1;", new SqlFileMetadata("Revenue", "rev", "Monthly"));
        Assert.Equal("-- @formatter:off\n-- @name: Revenue\n-- @keyword: rev\n-- @description: Monthly\nSELECT 1;", rewritten);
    }

    [Fact]
    public void ClearingAValueRemovesOnlyThatKeysLine()
    {
        var rewritten = SqlFrontmatter.Rewrite("-- @name: Revenue\n-- @keyword: rev\n-- @x: y\nSELECT 1;", new SqlFileMetadata("Revenue"));
        Assert.Equal("-- @name: Revenue\n-- @x: y\nSELECT 1;", rewritten);
    }

    [Fact]
    public void AHeaderCreatedInACrlfFileUsesCrlfAndIsSeparatedFromTheSql()
    {
        var rewritten = SqlFrontmatter.Rewrite("SELECT 1;\r\nSELECT 2;", new SqlFileMetadata("Two", "two"));
        Assert.Equal("-- @name: Two\r\n-- @keyword: two\r\n\r\nSELECT 1;\r\nSELECT 2;", rewritten);
    }

    [Fact]
    public void AMultiLineDescriptionIsWrittenOnOneHeaderLine()
    {
        var rewritten = SqlFrontmatter.Rewrite("SELECT 1;", new SqlFileMetadata(Description: "First line\nsecond line\r\n\r\nDROP TABLE x;"));
        Assert.Equal("-- @description: First line second line DROP TABLE x;\n\nSELECT 1;", rewritten);
        Assert.Equal("\nSELECT 1;", SqlFrontmatter.Split(rewritten).Body);
    }

    [Fact]
    public void TheRewrittenHeaderReadsBackAsTheMetadataThatWasSaved()
    {
        var metadata = new SqlFileMetadata("Revenue by month", "rev", "Joins orders");
        Assert.Equal(metadata, SqlFrontmatter.Parse(SqlFrontmatter.Rewrite("-- @owner: data\nSELECT 1;", metadata)));
    }
}
