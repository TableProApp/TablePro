using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>A mongosh statement as read, before anything decides what it runs.</summary>
internal abstract record ShellStatement(string Text);

/// <summary><c>use shop</c>: the tab's database for the statements after it.</summary>
internal sealed record UseStatement(string Text, string Database) : ShellStatement(Text);

/// <summary><c>show dbs</c>, <c>show collections</c>, <c>show users</c>, <c>show roles</c>.</summary>
internal sealed record ShowStatement(string Text, string Subject) : ShellStatement(Text);

/// <summary>A name followed by member accesses and calls, such as <c>db.users.find({}).limit(5)</c>.</summary>
internal sealed record ChainStatement(string Text, string Root, IReadOnlyList<ShellSegment> Segments) : ShellStatement(Text);

internal abstract record ShellSegment(int Position);

/// <summary><c>.name</c>, or <c>["name"]</c> for a name that is not an identifier.</summary>
internal sealed record MemberSegment(string Name, int Position) : ShellSegment(Position);

/// <summary>The arguments of a call, each read as a BSON value.</summary>
internal sealed record CallSegment(IReadOnlyList<BsonValue> Arguments, int Position) : ShellSegment(Position);
