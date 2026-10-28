using System.Globalization;
using System.Text;
using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>
/// Decides what a parsed statement runs: <c>db</c>, then <c>getSiblingDB</c>, a collection by name or through
/// <c>getCollection</c>, a method and the cursor calls chained after it. Each becomes a plan of commands, so the same
/// statement always sends the same documents.
/// </summary>
internal sealed class ShellPlanner
{
    private readonly string _text;
    private string _database;

    private ShellPlanner(string text, string database)
    {
        _text = text;
        _database = database;
    }

    public static ShellPlan Plan(string statement, string currentDatabase) => Plan(ShellParser.ParseStatement(statement), currentDatabase);

    public static ShellPlan Plan(ShellStatement statement, string currentDatabase) => statement switch
    {
        UseStatement use => new UsePlan(use.Database),
        ShowStatement show => Show(show, currentDatabase),
        ChainStatement chain => new ShellPlanner(chain.Text, currentDatabase).PlanChain(chain),
        _ => throw new ShellUnsupportedException("The statement is not supported."),
    };

    private static ShellPlan Show(ShowStatement show, string database) => show.Subject switch
    {
        "dbs" or "databases" => new ListDatabasesPlan(),
        "collections" or "tables" => new ListCollectionsPlan(database, [], NamesOnly: true),
        "users" => new CommandPlan(database, new BsonDocument("usersInfo", 1), ReplyShape.Rows, "users"),
        "roles" => new CommandPlan(database, new BsonDocument("rolesInfo", 1), ReplyShape.Rows, "roles"),
        _ => throw new ShellUnsupportedException($"show {show.Subject} is not supported. Try show dbs, show collections, show users or show roles."),
    };

    private ShellPlan PlanChain(ChainStatement chain)
    {
        if (chain.Root != "db")
        {
            throw chain.Root is "rs" or "sh" or "sp"
                ? new ShellUnsupportedException($"{chain.Root}.* helpers are not supported; use db.adminCommand with the command they send.")
                : new ShellSyntaxException($"'{chain.Root}' is not defined: a statement starts with db, use or show", _text, 0);
        }

        var segments = chain.Segments;
        string? collection = null;
        ShellPlan? plan = null;
        var i = 0;
        while (i < segments.Count)
        {
            if (segments[i] is not MemberSegment member)
            {
                throw Error("Expected a method name before the parentheses", segments[i].Position);
            }

            var call = i + 1 < segments.Count ? segments[i + 1] as CallSegment : null;
            if (plan is not null)
            {
                if (call is null)
                {
                    throw Error($"Expected '(' after {member.Name}", member.Position + member.Name.Length);
                }

                plan = ApplyCursorCall(plan, member, call);
                i += 2;
                continue;
            }

            if (collection is null)
            {
                if (call is not null)
                {
                    switch (member.Name)
                    {
                        case "getSiblingDB":
                            _database = StringArg(call, 0, "getSiblingDB", "a database name");
                            break;
                        case "getCollection":
                            collection = StringArg(call, 0, "getCollection", "a collection name");
                            break;
                        default:
                            plan = DatabaseMethod(member, call);
                            break;
                    }

                    i += 2;
                    continue;
                }

                // A collection name may hold dots (db.system.users.find()): every name up to the one that is called.
                var names = new StringBuilder(member.Name);
                var j = i + 1;
                while (j < segments.Count && segments[j] is MemberSegment next && !(j + 1 < segments.Count && segments[j + 1] is CallSegment))
                {
                    names.Append('.').Append(next.Name);
                    j++;
                }

                collection = names.ToString();
                i = j;
                continue;
            }

            if (call is null)
            {
                collection = $"{collection}.{member.Name}";
                i++;
                continue;
            }

            plan = CollectionMethod(collection, member, call);
            i += 2;
        }

        if (plan is not null)
        {
            return plan;
        }

        if (collection is not null)
        {
            return new FindPlan(_database, collection, [], new FindSpec(), Single: false);
        }

        throw Error("db alone runs nothing: name a collection or call a method", 0);
    }

    private ShellPlan DatabaseMethod(MemberSegment member, CallSegment call)
    {
        var name = member.Name;
        var args = call.Arguments;
        switch (name)
        {
            case "runCommand":
                return new CommandPlan(_database, CommandArg(call, name), ReplyShape.Auto);
            case "adminCommand":
                return new CommandPlan("admin", CommandArg(call, name), ReplyShape.Auto);
            case "dropDatabase":
                return new CommandPlan(_database, new BsonDocument("dropDatabase", 1), ReplyShape.Document);
            case "getCollectionNames":
                return new ListCollectionsPlan(_database, [], NamesOnly: true);
            case "getCollectionInfos":
            case "listCollections":
                return new ListCollectionsPlan(_database, OptionalDoc(call, 0, name) ?? [], NamesOnly: false);
            case "createCollection":
            {
                var command = new BsonDocument("create", StringArg(call, 0, name, "a collection name"));
                command.Merge(OptionalDoc(call, 1, name) ?? [], overwriteExistingElements: false);
                return new CommandPlan(_database, command, ReplyShape.Document);
            }

            case "createView":
            {
                var command = new BsonDocument
                {
                    { "create", StringArg(call, 0, name, "a view name") },
                    { "viewOn", StringArg(call, 1, name, "the source collection") },
                    { "pipeline", new BsonArray(Pipeline(call, 2, name)) },
                };
                command.Merge(OptionalDoc(call, 3, name) ?? [], overwriteExistingElements: false);
                return new CommandPlan(_database, command, ReplyShape.Document);
            }

            case "stats":
            {
                var command = new BsonDocument("dbStats", 1);
                if (args.Count > 0 && args[0].IsNumeric)
                {
                    command.Add("scale", args[0]);
                }

                return new CommandPlan(_database, command, ReplyShape.Document);
            }

            case "serverStatus":
            {
                var command = new BsonDocument("serverStatus", 1);
                command.Merge(OptionalDoc(call, 0, name) ?? [], overwriteExistingElements: false);
                return new CommandPlan("admin", command, ReplyShape.Document);
            }

            case "version":
                return new CommandPlan("admin", new BsonDocument("buildInfo", 1), ReplyShape.Field, "version");
            case "buildInfo":
                return new CommandPlan("admin", new BsonDocument("buildInfo", 1), ReplyShape.Document);
            case "hostInfo":
                return new CommandPlan("admin", new BsonDocument("hostInfo", 1), ReplyShape.Document);
            case "currentOp":
            {
                var command = new BsonDocument("currentOp", 1);
                if (args.Count > 0 && args[0].IsBoolean)
                {
                    command.Add("$all", args[0]);
                }
                else
                {
                    command.Merge(OptionalDoc(call, 0, name) ?? [], overwriteExistingElements: false);
                }

                return new CommandPlan("admin", command, ReplyShape.Rows, "inprog");
            }

            case "killOp":
                return new CommandPlan("admin", new BsonDocument { { "killOp", 1 }, { "op", Required(call, 0, name, "the operation id") } }, ReplyShape.Document);
            case "getName":
                return new MessagePlan(_database);
            case "aggregate":
                return new AggregatePlan(_database, null, Pipeline(call, 0, name), OptionalDoc(call, 1, name) ?? []);
            case "getUsers":
                return new CommandPlan(_database, new BsonDocument("usersInfo", 1), ReplyShape.Rows, "users");
            case "getUser":
                return new CommandPlan(_database, new BsonDocument("usersInfo", StringArg(call, 0, name, "a user name")), ReplyShape.Rows, "users");
            case "getRoles":
                return new CommandPlan(_database, new BsonDocument("rolesInfo", 1), ReplyShape.Rows, "roles");
            case "createUser":
            {
                var user = DocArg(call, 0, name, "a user document");
                var command = new BsonDocument("createUser", user.GetValue("user", BsonNull.Value));
                foreach (var element in user)
                {
                    if (element.Name != "user")
                    {
                        command.Add(element);
                    }
                }

                return new CommandPlan(_database, command, ReplyShape.Document);
            }

            case "dropUser":
                return new CommandPlan(_database, new BsonDocument("dropUser", StringArg(call, 0, name, "a user name")), ReplyShape.Document);
            case "grantRolesToUser":
            case "revokeRolesFromUser":
                return new CommandPlan(_database, new BsonDocument { { name, StringArg(call, 0, name, "a user name") }, { "roles", ArrayArg(call, 1, name, "an array of roles") } }, ReplyShape.Document);
            default:
                throw new ShellUnsupportedException($"db.{name}() is not supported.");
        }
    }

    private ShellPlan CollectionMethod(string collection, MemberSegment member, CallSegment call)
    {
        var name = member.Name;
        var args = call.Arguments;
        switch (name)
        {
            case "find":
            {
                var spec = new FindSpec { Projection = OptionalDoc(call, 1, name) };
                ApplyFindOptions(spec, OptionalDoc(call, 2, name));
                return new FindPlan(_database, collection, OptionalDoc(call, 0, name) ?? [], spec, Single: false);
            }

            case "findOne":
            {
                var spec = new FindSpec { Projection = OptionalDoc(call, 1, name), Limit = 1 };
                ApplyFindOptions(spec, OptionalDoc(call, 2, name));
                return new FindPlan(_database, collection, OptionalDoc(call, 0, name) ?? [], spec, Single: true);
            }

            case "aggregate":
            {
                // mongosh also takes the stages as separate arguments: aggregate({$match: ...}, {$limit: 5}).
                if (args.Count > 0 && args[0] is BsonDocument && args.All(a => a is BsonDocument d && d.ElementCount == 1 && d.GetElement(0).Name.StartsWith('$')))
                {
                    return new AggregatePlan(_database, collection, args.Select(a => a.AsBsonDocument).ToList(), []);
                }

                return new AggregatePlan(_database, collection, Pipeline(call, 0, name), OptionalDoc(call, 1, name) ?? []);
            }

            case "countDocuments":
            case "count":
                return CountDocuments(collection, OptionalDoc(call, 0, name) ?? [], OptionalDoc(call, 1, name));
            case "estimatedDocumentCount":
            {
                var command = new BsonDocument("count", collection);
                if (OptionalDoc(call, 0, name)?.GetValue("maxTimeMS", null) is { } maxTime)
                {
                    command.Add("maxTimeMS", maxTime);
                }

                return new CommandPlan(_database, command, ReplyShape.Count);
            }

            case "distinct":
            {
                var command = new BsonDocument { { "distinct", collection }, { "key", StringArg(call, 0, name, "a field name") }, { "query", OptionalDoc(call, 1, name) ?? [] } };
                CopyOptions(command, OptionalDoc(call, 2, name), "collation", "maxTimeMS", "comment", "hint");
                return new CommandPlan(_database, command, ReplyShape.Values, "values");
            }

            case "insertOne":
                return Insert(collection, [DocArg(call, 0, name, "a document")], OptionalDoc(call, 1, name));
            case "insertMany":
            {
                var array = ArrayArg(call, 0, name, "an array of documents");
                return Insert(collection, Documents(array, call, name), OptionalDoc(call, 1, name));
            }

            case "insert":
            {
                var first = Required(call, 0, name, "a document or an array of documents");
                List<BsonDocument> documents = first is BsonArray many ? Documents(many, call, name) : [DocArg(call, 0, name, "a document")];
                return Insert(collection, documents, OptionalDoc(call, 1, name));
            }

            case "updateOne":
            case "updateMany":
            {
                var update = UpdateArg(call, name);
                var options = OptionalDoc(call, 2, name);
                return Update(collection, UpdateStatement(DocArg(call, 0, name, "a filter"), update, name == "updateMany", options), options);
            }

            case "replaceOne":
            {
                var replacement = ReplacementArg(call, name);
                var options = OptionalDoc(call, 2, name);
                return Update(collection, UpdateStatement(DocArg(call, 0, name, "a filter"), replacement, multi: false, options), options);
            }

            case "update":
            {
                // The legacy update replaces a document unless the second argument uses operators, and takes multi.
                var filter = DocArg(call, 0, name, "a filter");
                var change = Required(call, 1, name, "an update document");
                var options = OptionalDoc(call, 2, name);
                var multi = options?.GetValue("multi", false).ToBoolean() ?? false;
                if (multi && change is BsonDocument d && !IsOperatorDocument(d))
                {
                    throw Error("update with multi: true needs update operators such as $set", call.Position);
                }

                return Update(collection, UpdateStatement(filter, change, multi, options), options);
            }

            case "deleteOne":
            case "deleteMany":
            {
                if (args.Count == 0)
                {
                    throw Error($"{name} needs a filter; pass {{}} to match every document", call.Position);
                }

                var options = OptionalDoc(call, 1, name);
                return Delete(collection, DeleteStatement(DocArg(call, 0, name, "a filter"), name == "deleteOne", options), options);
            }

            case "remove":
            {
                var justOne = args.Count > 1 && (args[1].IsBoolean ? args[1].AsBoolean : args[1] is BsonDocument o && o.GetValue("justOne", false).ToBoolean());
                return Delete(collection, DeleteStatement(DocArg(call, 0, name, "a filter"), justOne, null), null);
            }

            case "findOneAndUpdate":
                return FindAndModify(collection, DocArg(call, 0, name, "a filter"), UpdateArg(call, name), remove: false, OptionalDoc(call, 2, name));
            case "findOneAndReplace":
                return FindAndModify(collection, DocArg(call, 0, name, "a filter"), ReplacementArg(call, name), remove: false, OptionalDoc(call, 2, name));
            case "findOneAndDelete":
                return FindAndModify(collection, DocArg(call, 0, name, "a filter"), null, remove: true, OptionalDoc(call, 1, name));
            case "findAndModify":
            {
                var command = new BsonDocument("findAndModify", collection);
                command.Merge(DocArg(call, 0, name, "a document of query, update and options"), overwriteExistingElements: false);
                return new CommandPlan(_database, command, ReplyShape.FindAndModify);
            }

            case "bulkWrite":
                return BulkWrite(collection, call);
            case "createIndex":
            {
                var options = OptionalDoc(call, 1, name);
                return CreateIndexes(collection, [DocArg(call, 0, name, "the index keys")], options, keepName: true);
            }

            case "createIndexes":
            {
                var keys = ArrayArg(call, 0, name, "an array of index keys");
                return CreateIndexes(collection, Documents(keys, call, name), OptionalDoc(call, 1, name), keepName: false);
            }

            case "dropIndex":
            {
                var index = Required(call, 0, name, "the index name or keys");
                if (!index.IsString && index is not BsonDocument)
                {
                    throw Error("dropIndex needs the index name or its keys", call.Position);
                }

                return new CommandPlan(_database, new BsonDocument { { "dropIndexes", collection }, { "index", index } }, ReplyShape.Document);
            }

            case "dropIndexes":
                return new CommandPlan(_database, new BsonDocument { { "dropIndexes", collection }, { "index", args.Count > 0 ? args[0] : "*" } }, ReplyShape.Document);
            case "hideIndex":
            case "unhideIndex":
            {
                var index = Required(call, 0, name, "the index name or keys");
                var spec = new BsonDocument { { index.IsString ? "name" : "keyPattern", index }, { "hidden", name == "hideIndex" } };
                return new CommandPlan(_database, new BsonDocument { { "collMod", collection }, { "index", spec } }, ReplyShape.Document);
            }

            case "getIndexes":
            case "getIndexSpecs":
                return new ListIndexesPlan(_database, collection);
            case "drop":
                return new CommandPlan(_database, new BsonDocument("drop", collection), ReplyShape.Document);
            case "renameCollection":
            {
                var target = StringArg(call, 0, name, "the new name");
                var command = new BsonDocument
                {
                    { "renameCollection", $"{_database}.{collection}" },
                    { "to", $"{_database}.{target}" },
                };
                if (args.Count > 1 && args[1].IsBoolean)
                {
                    command.Add("dropTarget", args[1]);
                }

                return new CommandPlan("admin", command, ReplyShape.Document);
            }

            case "stats":
            {
                var command = new BsonDocument("collStats", collection);
                if (args.Count > 0)
                {
                    if (args[0].IsNumeric)
                    {
                        command.Add("scale", args[0]);
                    }
                    else if (args[0] is BsonDocument options && options.TryGetValue("scale", out var scale))
                    {
                        command.Add("scale", scale);
                    }
                }

                return new CommandPlan(_database, command, ReplyShape.Document);
            }

            case "dataSize":
                return new CommandPlan(_database, new BsonDocument("collStats", collection), ReplyShape.Field, "size");
            case "storageSize":
                return new CommandPlan(_database, new BsonDocument("collStats", collection), ReplyShape.Field, "storageSize");
            case "totalIndexSize":
                return new CommandPlan(_database, new BsonDocument("collStats", collection), ReplyShape.Field, "totalIndexSize");
            case "totalSize":
                return new CommandPlan(_database, new BsonDocument("collStats", collection), ReplyShape.Field, "totalSize");
            case "isCapped":
                return new CommandPlan(_database, new BsonDocument("collStats", collection), ReplyShape.Field, "capped");
            default:
                throw new ShellUnsupportedException($"db.{collection}.{name}() is not supported.");
        }
    }

    private ShellPlan ApplyCursorCall(ShellPlan plan, MemberSegment member, CallSegment call)
    {
        var name = member.Name;
        if (plan is FindPlan find && !find.Single)
        {
            var spec = find.Spec;
            switch (name)
            {
                case "sort":
                    spec.Sort = DocArg(call, 0, name, "a sort document");
                    return find;
                case "limit":
                    spec.Limit = IntArg(call, name);
                    return find;
                case "skip":
                    spec.Skip = IntArg(call, name);
                    return find;
                case "project":
                case "projection":
                    spec.Projection = DocArg(call, 0, name, "a projection document");
                    return find;
                case "hint":
                    spec.Hint = Required(call, 0, name, "an index name or keys");
                    return find;
                case "maxTimeMS":
                    spec.MaxTimeMs = IntArg(call, name);
                    return find;
                case "batchSize":
                    spec.BatchSize = IntArg(call, name);
                    return find;
                case "comment":
                    spec.Comment = Required(call, 0, name, "a comment");
                    return find;
                case "collation":
                    spec.Collation = DocArg(call, 0, name, "a collation document");
                    return find;
                case "allowDiskUse":
                    spec.AllowDiskUse = call.Arguments.Count == 0 || call.Arguments[0].ToBoolean();
                    return find;
                case "toArray":
                case "pretty":
                case "noCursorTimeout":
                    return find;
                case "count":
                case "itcount":
                case "size":
                {
                    // cursor.count() counts every match, as mongosh does; size() and itcount() honor skip and limit.
                    var honorPaging = name != "count" || (call.Arguments.Count > 0 && call.Arguments[0].ToBoolean());
                    var options = new BsonDocument();
                    if (honorPaging && spec.Skip is { } skip)
                    {
                        options.Add("skip", skip);
                    }

                    if (honorPaging && spec.Limit is { } limit && limit != 0)
                    {
                        options.Add("limit", Math.Abs(limit));
                    }

                    return CountDocuments(find.Collection, find.Filter, options);
                }

                case "explain":
                    return Explain(find.Database, spec.ToCommand(find.Collection, find.Filter), call);
            }

            throw new ShellUnsupportedException($".{name}() is not supported on a find cursor.");
        }

        if (plan is AggregatePlan aggregate)
        {
            switch (name)
            {
                case "sort":
                    aggregate.Pipeline.Add(new BsonDocument("$sort", DocArg(call, 0, name, "a sort document")));
                    return aggregate;
                case "skip":
                    aggregate.Pipeline.Add(new BsonDocument("$skip", IntArg(call, name)));
                    return aggregate;
                case "limit":
                    aggregate.Pipeline.Add(new BsonDocument("$limit", IntArg(call, name)));
                    return aggregate;
                case "toArray":
                case "pretty":
                    return aggregate;
                case "explain":
                {
                    var command = new BsonDocument
                    {
                        { "aggregate", aggregate.Collection is null ? 1 : aggregate.Collection },
                        { "pipeline", new BsonArray(aggregate.Pipeline) },
                        { "cursor", new BsonDocument() },
                    };
                    command.Merge(aggregate.Options, overwriteExistingElements: false);
                    return Explain(aggregate.Database, command, call);
                }
            }

            throw new ShellUnsupportedException($".{name}() is not supported on an aggregation cursor.");
        }

        throw new ShellUnsupportedException($"The method before .{name}() does not return a cursor, so .{name}() cannot follow it.");
    }

    private static CommandPlan Explain(string database, BsonDocument command, CallSegment call)
    {
        var verbosity = call.Arguments.Count == 0 ? "queryPlanner"
            : call.Arguments[0].IsString ? call.Arguments[0].AsString
            : call.Arguments[0].ToBoolean() ? "allPlansExecution" : "queryPlanner";
        return new CommandPlan(database, new BsonDocument { { "explain", command }, { "verbosity", verbosity } }, ReplyShape.Document);
    }

    private CommandPlan CountDocuments(string collection, BsonDocument filter, BsonDocument? options)
    {
        var pipeline = new BsonArray { new BsonDocument("$match", filter) };
        if (options?.GetValue("skip", null) is { IsNumeric: true } skip)
        {
            pipeline.Add(new BsonDocument("$skip", skip));
        }

        if (options?.GetValue("limit", null) is { IsNumeric: true } limit)
        {
            pipeline.Add(new BsonDocument("$limit", limit));
        }

        pipeline.Add(new BsonDocument("$group", new BsonDocument { { "_id", 1 }, { "n", new BsonDocument("$sum", 1) } }));
        var command = new BsonDocument { { "aggregate", collection }, { "pipeline", pipeline }, { "cursor", new BsonDocument() } };
        CopyOptions(command, options, "hint", "collation", "maxTimeMS", "comment");
        return new CommandPlan(_database, command, ReplyShape.Count);
    }

    private CommandPlan Insert(string collection, List<BsonDocument> documents, BsonDocument? options)
    {
        // As every driver does, a document without an _id gets an ObjectId here, so the result can name it.
        var ids = new BsonArray(documents.Count);
        foreach (var document in documents)
        {
            if (!document.TryGetValue("_id", out var id))
            {
                id = new BsonObjectId(ObjectId.GenerateNewId());
                document.InsertAt(0, new BsonElement("_id", id));
            }

            ids.Add(id);
        }

        var command = new BsonDocument { { "insert", collection }, { "documents", new BsonArray(documents) } };
        command.Add("ordered", options?.GetValue("ordered", true) ?? true);
        CopyOptions(command, options, "writeConcern", "bypassDocumentValidation", "comment");
        return new CommandPlan(_database, command, ReplyShape.Write, InsertedIds: ids);
    }

    private static BsonDocument UpdateStatement(BsonDocument filter, BsonValue update, bool multi, BsonDocument? options)
    {
        var statement = new BsonDocument { { "q", filter }, { "u", update }, { "multi", multi } };
        statement.Add("upsert", options?.GetValue("upsert", false).ToBoolean() ?? false);
        CopyOptions(statement, options, "arrayFilters", "hint", "collation");
        return statement;
    }

    private CommandPlan Update(string collection, BsonDocument statement, BsonDocument? options)
    {
        var command = new BsonDocument { { "update", collection }, { "updates", new BsonArray { statement } }, { "ordered", true } };
        CopyOptions(command, options, "writeConcern", "let", "comment", "bypassDocumentValidation");
        return new CommandPlan(_database, command, ReplyShape.Write);
    }

    private static BsonDocument DeleteStatement(BsonDocument filter, bool justOne, BsonDocument? options)
    {
        var statement = new BsonDocument { { "q", filter }, { "limit", justOne ? 1 : 0 } };
        CopyOptions(statement, options, "hint", "collation");
        return statement;
    }

    private CommandPlan Delete(string collection, BsonDocument statement, BsonDocument? options)
    {
        var command = new BsonDocument { { "delete", collection }, { "deletes", new BsonArray { statement } }, { "ordered", true } };
        CopyOptions(command, options, "writeConcern", "let", "comment");
        return new CommandPlan(_database, command, ReplyShape.Write);
    }

    private CommandPlan FindAndModify(string collection, BsonDocument filter, BsonValue? update, bool remove, BsonDocument? options)
    {
        var command = new BsonDocument { { "findAndModify", collection }, { "query", filter } };
        if (remove)
        {
            command.Add("remove", true);
        }
        else
        {
            command.Add("update", update!);
            var returnsNew = options is not null
                && (options.GetValue("returnDocument", "before").ToString() == "after" || options.GetValue("returnNewDocument", false).ToBoolean());
            command.Add("new", returnsNew);
            command.Add("upsert", options?.GetValue("upsert", false).ToBoolean() ?? false);
        }

        if (options?.GetValue("projection", null) is BsonDocument projection)
        {
            command.Add("fields", projection);
        }

        CopyOptions(command, options, "sort", "arrayFilters", "collation", "hint", "maxTimeMS", "writeConcern", "let", "comment", "bypassDocumentValidation");
        return new CommandPlan(_database, command, ReplyShape.FindAndModify);
    }

    private BatchPlan BulkWrite(string collection, CallSegment call)
    {
        var operations = ArrayArg(call, 0, "bulkWrite", "an array of operations");
        var options = OptionalDoc(call, 1, "bulkWrite");
        var steps = new List<CommandPlan>(operations.Count);
        foreach (var item in operations)
        {
            if (item is not BsonDocument { ElementCount: 1 } operation || operation[0] is not BsonDocument body)
            {
                throw Error("Each bulkWrite operation is one of {insertOne: ...}, {updateOne: ...} and the like", call.Position);
            }

            var kind = operation.GetElement(0).Name;
            steps.Add(kind switch
            {
                "insertOne" => Insert(collection, [Field<BsonDocument>(body, "document", kind, call)], null),
                "updateOne" or "updateMany" => Update(collection, UpdateStatement(Field<BsonDocument>(body, "filter", kind, call), CheckedUpdate(body.GetValue("update", BsonNull.Value), kind, call), kind == "updateMany", body), null),
                "replaceOne" => Update(collection, UpdateStatement(Field<BsonDocument>(body, "filter", kind, call), CheckedReplacement(body.GetValue("replacement", BsonNull.Value), kind, call), multi: false, body), null),
                "deleteOne" or "deleteMany" => Delete(collection, DeleteStatement(Field<BsonDocument>(body, "filter", kind, call), kind == "deleteOne", body), null),
                _ => throw new ShellUnsupportedException($"bulkWrite does not know the operation {kind}."),
            });
        }

        return new BatchPlan(steps, options?.GetValue("ordered", true).ToBoolean() ?? true);
    }

    private CommandPlan CreateIndexes(string collection, List<BsonDocument> keys, BsonDocument? options, bool keepName)
    {
        var indexes = new BsonArray(keys.Count);
        foreach (var key in keys)
        {
            var index = new BsonDocument { { "key", key }, { "name", keepName && options?.GetValue("name", null) is { IsString: true } name ? name : IndexName(key) } };
            if (options is not null)
            {
                foreach (var option in options)
                {
                    if (option.Name is not ("name" or "commitQuorum"))
                    {
                        index.Set(option.Name, option.Value);
                    }
                }
            }

            indexes.Add(index);
        }

        var command = new BsonDocument { { "createIndexes", collection }, { "indexes", indexes } };
        CopyOptions(command, options, "commitQuorum");
        return new CommandPlan(_database, command, ReplyShape.Document);
    }

    /// <summary>The name the server would give: each field and its direction or type, joined by underscores.</summary>
    public static string IndexName(BsonDocument keys) =>
        string.Join('_', keys.Select(k => $"{k.Name}_{(k.Value.IsString ? k.Value.AsString : k.Value.ToString())}"));

    private static bool IsOperatorDocument(BsonDocument document) =>
        document.ElementCount > 0 && document.All(e => e.Name.StartsWith('$'));

    private BsonValue UpdateArg(CallSegment call, string method) =>
        CheckedUpdate(Required(call, 1, method, "an update document or pipeline"), method, call);

    private BsonValue CheckedUpdate(BsonValue update, string method, CallSegment call)
    {
        // A forgotten $set would replace the whole document; mongosh refuses it too.
        if (update is BsonArray || (update is BsonDocument document && IsOperatorDocument(document)))
        {
            return update;
        }

        throw Error($"{method} needs update operators such as $set, or a pipeline; use replaceOne to replace a document", call.Position);
    }

    private BsonDocument ReplacementArg(CallSegment call, string method) =>
        CheckedReplacement(Required(call, 1, method, "a replacement document"), method, call);

    private BsonDocument CheckedReplacement(BsonValue replacement, string method, CallSegment call)
    {
        if (replacement is BsonDocument document && !document.Any(e => e.Name.StartsWith('$')))
        {
            return document;
        }

        throw Error($"{method} takes a document without update operators; use updateOne to apply $set", call.Position);
    }

    private static void ApplyFindOptions(FindSpec spec, BsonDocument? options)
    {
        if (options is null)
        {
            return;
        }

        if (options.GetValue("projection", null) is BsonDocument projection)
        {
            spec.Projection = projection;
        }

        if (options.GetValue("sort", null) is BsonDocument sort)
        {
            spec.Sort = sort;
        }

        if (options.GetValue("skip", null) is { IsNumeric: true } skip)
        {
            spec.Skip = skip.ToInt32();
        }

        if (options.GetValue("limit", null) is { IsNumeric: true } limit)
        {
            spec.Limit = limit.ToInt32();
        }

        if (options.GetValue("hint", null) is { } hint)
        {
            spec.Hint = hint;
        }

        if (options.GetValue("maxTimeMS", null) is { IsNumeric: true } maxTime)
        {
            spec.MaxTimeMs = maxTime.ToInt64();
        }

        if (options.GetValue("collation", null) is BsonDocument collation)
        {
            spec.Collation = collation;
        }

        if (options.GetValue("comment", null) is { } comment)
        {
            spec.Comment = comment;
        }

        if (options.GetValue("allowDiskUse", null) is { IsBoolean: true } disk)
        {
            spec.AllowDiskUse = disk.AsBoolean;
        }
    }

    private static void CopyOptions(BsonDocument target, BsonDocument? options, params string[] names)
    {
        if (options is null)
        {
            return;
        }

        foreach (var name in names)
        {
            if (options.TryGetValue(name, out var value))
            {
                target.Set(name, value);
            }
        }
    }

    private BsonDocument CommandArg(CallSegment call, string method)
    {
        var arg = Required(call, 0, method, "a command document");
        if (arg.IsString)
        {
            return new BsonDocument(arg.AsString, 1);
        }

        return arg as BsonDocument ?? throw Error($"{method} needs a command document", call.Position);
    }

    private List<BsonDocument> Pipeline(CallSegment call, int index, string method)
    {
        if (index >= call.Arguments.Count)
        {
            return [];
        }

        return call.Arguments[index] is BsonArray stages
            ? Documents(stages, call, method)
            : throw Error($"{method} needs an array of pipeline stages", call.Position);
    }

    private List<BsonDocument> Documents(BsonArray array, CallSegment call, string method)
    {
        var documents = new List<BsonDocument>(array.Count);
        foreach (var item in array)
        {
            documents.Add(item as BsonDocument ?? throw Error($"{method} needs documents in its array", call.Position));
        }

        return documents;
    }

    private T Field<T>(BsonDocument body, string name, string operation, CallSegment call)
        where T : BsonValue =>
        body.GetValue(name, null) as T ?? throw Error($"{operation} needs {name}", call.Position);

    private BsonValue Required(CallSegment call, int index, string method, string what) =>
        index < call.Arguments.Count ? call.Arguments[index] : throw Error($"{method} needs {what}", call.Position);

    private string StringArg(CallSegment call, int index, string method, string what)
    {
        var value = Required(call, index, method, what);
        return value.IsString ? value.AsString : throw Error($"{method} needs {what} as a quoted string", call.Position);
    }

    private BsonDocument DocArg(CallSegment call, int index, string method, string what)
    {
        var value = Required(call, index, method, what);
        return value as BsonDocument ?? throw Error($"{method} needs {what} in braces", call.Position);
    }

    private BsonArray ArrayArg(CallSegment call, int index, string method, string what)
    {
        var value = Required(call, index, method, what);
        return value as BsonArray ?? throw Error($"{method} needs {what}", call.Position);
    }

    private BsonDocument? OptionalDoc(CallSegment call, int index, string method)
    {
        if (index >= call.Arguments.Count || call.Arguments[index].IsBsonNull)
        {
            return null;
        }

        return call.Arguments[index] as BsonDocument ?? throw Error($"Argument {index + 1} of {method} must be a document", call.Position);
    }

    private int IntArg(CallSegment call, string method)
    {
        var value = Required(call, 0, method, "a whole number");
        if (value.IsInt32 || value.IsInt64 || (value.IsDouble && Math.Floor(value.AsDouble) == value.AsDouble))
        {
            var number = value.ToInt64();
            if (number is >= int.MinValue and <= int.MaxValue)
            {
                return (int)number;
            }
        }

        throw Error(string.Create(CultureInfo.InvariantCulture, $"{method} needs a whole number"), call.Position);
    }

    private ShellSyntaxException Error(string reason, int position) => new(reason, _text, position);
}
