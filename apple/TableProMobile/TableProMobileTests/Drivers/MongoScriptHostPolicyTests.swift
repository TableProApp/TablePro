import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

// A connection that never connected: the host's checks run before any server call, so an op they let through fails
// at the connection instead.
struct MongoScriptHostPolicyTests {
    private static let reachedServer = MongoDBError.notConnected.message

    private static var externalWrite: PluginStatementContext {
        var context = PluginStatementContext()
        context.origin = .external
        context.hostSplit = true
        context.allowsDestructive = false
        context.allowsServerCode = false
        return context
    }

    private static var externalRead: PluginStatementContext {
        var context = externalWrite
        context.readOnly = true
        return context
    }

    private func runtime() -> MongoScriptRuntime {
        MongoScriptRuntime(connection: MongoDBConnection(
            host: "127.0.0.1", port: 27_017, user: "", password: nil, database: "app", configuredDatabase: "app"
        ))
    }

    private func failure(
        of statement: String,
        under context: PluginStatementContext,
        in runtime: MongoScriptRuntime,
        shell: MongoScriptRuntime.Shell? = nil
    ) async -> String? {
        do {
            _ = try await runtime.evaluate(
                statement: statement,
                database: "app",
                valueCeiling: 100,
                access: MongoScriptAccess(context),
                shell: shell ?? MongoScriptRuntime.Shell(context)
            )
            return nil
        } catch let failure as MongoScriptStatementFailure {
            return (failure.underlying as? MongoDBError)?.message ?? failure.localizedDescription
        } catch let error as MongoDBError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    @Test("An approval without drops, deletes or server code refuses what the statement sends", arguments: [
        (#"db.users["delete" + "Many"]({})"#, MongoScriptRefusal.destructive("delete")),
        (#"db.users.find({["$wh" + "ere"]: "sleep(60000)"})"#, .serverCode("find")),
        (#"db.c.__reply("dropCollection", {})"#, .destructive("dropCollection")),
        ("db.users.bulkWrite([{deleteMany: {filter: {}}}])", .destructive("bulkWrite")),
        (#"db.runCommand({deleteIndexes: "users", index: "*"})"#, .destructive("deleteIndexes")),
        (#"db.runCommand({a: {toEJSON: MinKey}, drop: "users"})"#, .destructive("a")),
        (#"__tp.call({op: "delete", collection: "users", filter: "{}", multi: true})"#, .destructive("delete")),
        (#"__tp.call({op: "command", command: "{\"\\u0064rop\": \"users\"}"})"#, .destructive("drop")),
        (#"db.users.aggregate([{["$o" + "ut"]: "copy"}])"#, .serverCode("aggregate")),
        (#"db.users.find().projection({x: {["$_internal" + "JsEmit"]: {}}})"#, .serverCode("projection")),
        ("db.users.updateMany({}, [{$set: {a: {$function: {body: 'f', args: [], lang: 'js'}}}}])", .serverCode("update")),
        (
            #"db.runCommand({explain: {mapReduce: "users", map: "function(){emit(1,1)}", reduce: "function(k,v){return 1}", out: {inline: 1}}, verbosity: "executionStats"})"#,
            .serverCode("explain")
        ),
        ("db.orders.createIndex({createdAt: 1}, {expireAfterSeconds: 0})", .destructive("createIndex")),
        (#"db.runCommand({collMod: "orders", index: {keyPattern: {createdAt: 1}, expireAfterSeconds: 0}})"#, .destructive("collMod")),
        (#"db.runCommand({grantRolesToUser: "app", roles: ["root"]})"#, .destructive("grantRolesToUser")),
        (#"db.runCommand({createUser: "eve", pwd: "x", roles: ["root"]})"#, .destructive("createUser")),
        (#"db.runCommand({updateUser: "app", pwd: "x"})"#, .destructive("updateUser")),
        ("db.adminCommand({killOp: 1, op: 12})", .destructive("killOp"))
    ])
    func restrictedWriteRefuses(statement: String, refusal: MongoScriptRefusal) async {
        #expect(await failure(of: statement, under: Self.externalWrite, in: runtime()) == refusal.message)
    }

    @Test("Ordinary writes reach the server under the same approval", arguments: [
        "db.users.insertOne({a: 1})",
        "db.users.updateOne({a: 1}, {$set: {b: 2}})",
        "db.users.updateMany({}, {$set: {b: 2}})",
        "db.users.deleteOne({a: 1})",
        "db.users.createIndex({a: 1})",
        "db.users.bulkWrite([{insertOne: {document: {a: 1}}}, {deleteOne: {filter: {a: 1}}}])",
        "db.runCommand({ping: 1})",
        "db.users.find({a: 1}).sort({a: 1}).toArray()"
    ])
    func ordinaryWritesPass(statement: String) async {
        #expect(await failure(of: statement, under: Self.externalWrite, in: runtime()) == Self.reachedServer)
    }

    @Test("An approved drop still runs no server-side code")
    func approvedDropRunsNoServerCode() async {
        var context = Self.externalWrite
        context.allowsDestructive = true
        let runtime = runtime()
        #expect(await failure(of: "db.users.drop()", under: context, in: runtime) == Self.reachedServer)
        #expect(
            await failure(of: #"db.runCommand({mapReduce: "users", map: "f", reduce: "g", out: {inline: 1}})"#, under: context, in: runtime)
                == MongoScriptRefusal.serverCode("mapReduce").message
        )
    }

    @Test("Nothing an external statement defines outlives it")
    func externalShellIsBuiltPerStatement() async {
        let runtime = runtime()
        let plant = #"DBCollection.prototype.updateOne = function () { throw new Error("planted") }; var planted = 1"#
        #expect(await failure(of: plant, under: Self.externalWrite, in: runtime) == nil)
        #expect(await failure(of: "db.users.updateOne({a: 1}, {$set: {b: 2}})", under: PluginStatementContext(), in: runtime)
            == Self.reachedServer)
        #expect(await failure(of: "planted", under: Self.externalWrite, in: runtime) != nil)
    }

    @Test("The app's shell follows a database an external statement switched to")
    func appShellFollowsExternalUse() async throws {
        let runtime = runtime()
        _ = try await runtime.evaluate(statement: "db.getName()", database: "app", valueCeiling: 100, access: .readWrite)
        let switched = try await runtime.evaluate(
            statement: #"use("reporting")"#,
            database: "app",
            valueCeiling: 100,
            access: MongoScriptAccess(Self.externalWrite),
            shell: .external
        )
        #expect(switched.databaseSwitch == "reporting")
        let name = try await runtime.evaluate(statement: "db.getName()", database: "reporting", valueCeiling: 100, access: .readWrite)
        #expect(name.scalarRows == ["reporting"])
    }

    // In one shell, so the host alone has to hold the approval.
    @Test("A cursor an earlier statement opened is held to the approval of the statement that reads it")
    func cursorFromAnEarlierStatement() async {
        let runtime = runtime()
        let open = #"var c = db.users.find({$where: "sleep(1)"})"#
        #expect(await failure(of: open, under: PluginStatementContext(), in: runtime, shell: .app) == nil)
        #expect(await failure(of: "c.toArray()", under: Self.externalWrite, in: runtime, shell: .app)
            == MongoScriptRefusal.serverCode("find").message)
    }

    @Test("A read reaches no server-side code through a shell method an earlier statement rebound")
    func reboundFindUnderExternalRead() async {
        let runtime = runtime()
        let rebind = #"""
            DBCollection.prototype.find = function () {
                return new Cursor(this.__call("openCursor", {kind: "find", filter: JSON.stringify({["$wh" + "ere"]: "sleep(1)"})}), "x");
            }
            """#
        #expect(await failure(of: rebind, under: Self.externalWrite, in: runtime, shell: .app) == nil)
        #expect(await failure(of: "db.users.find({})", under: Self.externalRead, in: runtime, shell: .app)
            == MongoScriptRefusal.serverCode("find").message)
    }

    @Test("The app's own statements keep every op, a read's server-side code included", arguments: [
        "db.users.drop()",
        "db.users.deleteMany({})",
        "db.dropDatabase()",
        #"db.users.find({$where: "this.a > 1"}).toArray()"#
    ])
    func appStatementsKeepEveryOp(statement: String) async {
        #expect(await failure(of: statement, under: PluginStatementContext(), in: runtime()) == Self.reachedServer)
    }

    @Test("The app's contexts map to the access they always had")
    func appContextsMapUnchanged() async {
        var read = PluginStatementContext()
        read.readOnly = true
        #expect(MongoScriptAccess(PluginStatementContext()) == .readWrite)
        #expect(MongoScriptAccess(read) == .read)
        #expect(await failure(of: #"db.users.find({$where: "this.a > 1"})"#, under: read, in: runtime()) == Self.reachedServer)
    }
}
