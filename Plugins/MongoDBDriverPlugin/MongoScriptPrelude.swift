import Foundation

/// The mongosh-shaped API the script runtime installs into every `JSContext`.
///
/// Written in JavaScript rather than bridged through `JSExport` because the surface is a
/// vocabulary, not an object graph: `db.<anything>.<anything>()` has to resolve without the host
/// knowing the collection names, which is what `Proxy` gives and a bridged class cannot. Everything
/// funnels into two host functions, so the Swift side stays one dispatcher.
///
/// Documents cross the bridge as JSON *text*, never as nested JSON values, because the host parses
/// a request with `JSONSerialization` and a document rebuilt from a Swift dictionary comes back
/// with its fields reordered. BSON field order decides how an embedded document compares and where
/// `_id` sits, so `__ejson` is used for every payload that carries one.
enum MongoScriptPrelude {
    static let source = [
        core, values, cursor, collection, database, serialization, output
    ].joined(separator: "\n")

    private static let core = """
    var __tp = (function () {
        function call(request) {
            var response = JSON.parse(__tp_exec(JSON.stringify(request)));
            if (!response.ok) {
                var failure = new Error(response.e.m);
                failure.code = response.e.c;
                failure.isMongoError = true;
                throw failure;
            }
            return response.v;
        }
        return { call: call };
    })();

    function __ejson(value) { return JSON.stringify(EJSON.serialize(value)); }
    """

    private static let values = """
    function ObjectId(hex) {
        if (!(this instanceof ObjectId)) { return new ObjectId(hex); }
        if (hex === undefined || hex === null) {
            this.__id = __tp.call({ op: "newObjectId" });
        } else {
            if (typeof hex !== "string" || !/^[0-9a-fA-F]{24}$/.test(hex)) {
                throw new Error("ObjectId takes a 24 character hex string");
            }
            this.__id = hex.toLowerCase();
        }
        this.str = this.__id;
    }
    ObjectId.prototype.toString = function () { return this.__id; };
    ObjectId.prototype.valueOf = function () { return this.__id; };
    ObjectId.prototype.equals = function (other) { return String(other) === this.__id; };
    ObjectId.prototype.getTimestamp = function () {
        return new Date(parseInt(this.__id.substring(0, 8), 16) * 1000);
    };
    ObjectId.prototype.toEJSON = function () { return { "$oid": this.__id }; };

    function __wholeText(value, name) {
        var text = value === undefined ? "0" : String(value);
        if (!/^[+-]?[0-9]+$/.test(text)) { throw new Error(name + " takes a whole number"); }
        return text;
    }

    function NumberLong(value) {
        if (!(this instanceof NumberLong)) { return new NumberLong(value); }
        this.__value = __wholeText(value, "NumberLong");
    }
    NumberLong.prototype.toString = function () { return this.__value; };
    NumberLong.prototype.valueOf = function () { return Number(this.__value); };
    NumberLong.prototype.toNumber = function () { return Number(this.__value); };
    NumberLong.prototype.toEJSON = function () { return { "$numberLong": this.__value }; };

    function NumberInt(value) {
        if (!(this instanceof NumberInt)) { return new NumberInt(value); }
        this.__value = __wholeText(value === undefined ? 0 : parseInt(value, 10), "NumberInt");
    }
    NumberInt.prototype.toString = function () { return this.__value; };
    NumberInt.prototype.valueOf = function () { return Number(this.__value); };
    NumberInt.prototype.toEJSON = function () { return { "$numberInt": this.__value }; };

    function NumberDecimal(value) {
        if (!(this instanceof NumberDecimal)) { return new NumberDecimal(value); }
        var text = value === undefined ? "0" : String(value);
        if (!/^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$/.test(text)) {
            throw new Error("NumberDecimal takes a number");
        }
        this.__value = text;
    }
    NumberDecimal.prototype.toString = function () { return this.__value; };
    NumberDecimal.prototype.toEJSON = function () { return { "$numberDecimal": this.__value }; };

    function Timestamp(t, i) {
        if (!(this instanceof Timestamp)) { return new Timestamp(t, i); }
        this.t = t === undefined ? 0 : t;
        this.i = i === undefined ? 0 : i;
    }
    Timestamp.prototype.toString = function () { return "Timestamp(" + this.t + ", " + this.i + ")"; };
    Timestamp.prototype.toEJSON = function () { return { "$timestamp": { t: this.t, i: this.i } }; };

    function __subTypeHex(subtype) {
        var hex = subtype.toString(16);
        return hex.length === 1 ? "0" + hex : hex;
    }

    function BinData(subtype, base64) {
        if (!(this instanceof BinData)) { return new BinData(subtype, base64); }
        this.__subtype = subtype;
        this.__base64 = base64;
    }
    BinData.prototype.toString = function () {
        return "BinData(" + this.__subtype + ", \\"" + this.__base64 + "\\")";
    };
    BinData.prototype.base64 = function () { return this.__base64; };
    BinData.prototype.toEJSON = function () {
        return { "$binary": { base64: this.__base64, subType: __subTypeHex(this.__subtype) } };
    };

    function HexData(subtype, hex) {
        return new BinData(subtype, __tp.call({ op: "hexToBase64", hex: String(hex) }));
    }

    // Every legacy spelling keeps its own tag. The Java, C# and Python drivers each wrote subtype 3
    // with a different byte order and nothing in the stored bytes says which, so collapsing them
    // onto `UUID` emits subtype 4 in identity order: the filter matches nothing and a write stores
    // different bytes.
    function UUID(value, tag) {
        if (!(this instanceof UUID)) { return new UUID(value, tag); }
        this.__tag = tag === undefined ? "UUID" : tag;
        var encoded = __tp.call({
            op: "encodeUuid",
            tag: this.__tag,
            value: value === undefined ? null : String(value)
        });
        this.__base64 = encoded.base64;
        this.__subtype = encoded.subtype;
        this.__text = encoded.text;
    }
    UUID.prototype.toString = function () { return this.__tag + "(\\"" + this.__text + "\\")"; };
    UUID.prototype.hex = function () { return this.__text.replace(/-/g, ""); };
    UUID.prototype.toEJSON = function () {
        return { "$binary": { base64: this.__base64, subType: __subTypeHex(this.__subtype) } };
    };

    // Callable as well as bare, because the translator this replaces accepted `MinKey()` too and a
    // saved query may use either form. A function carrying `toEJSON` is what makes both work; the
    // serializer asks for `toEJSON` before it asks whether something is a function, so this does
    // not serialize as `Code`.
    function __boundaryKey(name, wrapper) {
        var key = function () { return key; };
        key.toString = function () { return name; };
        key.toEJSON = function () { return wrapper; };
        return key;
    }
    var MinKey = __boundaryKey("MinKey", { "$minKey": 1 });
    var MaxKey = __boundaryKey("MaxKey", { "$maxKey": 1 });

    function Code(code, scope) {
        if (!(this instanceof Code)) { return new Code(code, scope); }
        this.code = String(code);
        this.scope = scope;
    }
    Code.prototype.toString = function () { return this.code; };
    Code.prototype.toEJSON = function () {
        return this.scope === undefined
            ? { "$code": this.code }
            : { "$code": this.code, "$scope": EJSON.serialize(this.scope) };
    };

    function DBRef(collection, id, database) {
        if (!(this instanceof DBRef)) { return new DBRef(collection, id, database); }
        this.$ref = collection;
        this.$id = id;
        if (database !== undefined) { this.$db = database; }
    }

    function ISODate(value) {
        if (value === undefined) { return new Date(); }
        var parsed = new Date(value);
        if (isNaN(parsed.getTime())) { throw new Error("ISODate could not read \\"" + value + "\\""); }
        return parsed;
    }

    // `Date("2020-01-01")` without `new` is a string in JavaScript, built from *today*, so a saved
    // filter written that way would silently stop matching. A Proxy with only an `apply` trap
    // forwards construction to the native Date, so `new Date(...)` and `instanceof Date` are
    // untouched and a bare call returns the date it names.
    var __NativeDate = Date;
    Date = new Proxy(__NativeDate, {
        apply: function (target, thisArg, args) {
            return args.length === 0 ? new target() : new target(args[0]);
        }
    });

    function LegacyJavaUUID(value) { return new UUID(value, "LegacyJavaUUID"); }
    function LegacyCSharpUUID(value) { return new UUID(value, "LegacyCSharpUUID"); }
    function LegacyPythonUUID(value) { return new UUID(value, "LegacyPythonUUID"); }
    function JUUID(value) { return new UUID(value, "JUUID"); }
    function CSUUID(value) { return new UUID(value, "CSUUID"); }
    function NUUID(value) { return new UUID(value, "NUUID"); }
    function PYUUID(value) { return new UUID(value, "PYUUID"); }
    function LUUID(value) { return new UUID(value, "LUUID"); }
    """

    private static let cursor = """
    function Cursor(handle, describe) {
        this.__handle = handle;
        this.__describe = describe;
        this.__batch = null;
        this.__index = 0;
        this.__exhausted = false;
        this.__started = false;
    }
    Cursor.prototype.__configure = function (name, value) {
        if (this.__started) { throw new Error("." + name + "() cannot be set once the cursor has started"); }
        __tp.call({ op: "cursorConfigure", handle: this.__handle, key: name, value: __ejson(value) });
        return this;
    };
    Cursor.prototype.sort = function (spec) { return this.__configure("sort", spec); };
    Cursor.prototype.projection = function (spec) {
        // An aggregation projects with a `$project` stage, and a cursor projection would be
        // accepted and then ignored, so it is refused rather than silently dropped.
        if (this.__describe.indexOf(".aggregate(") !== -1) {
            throw new Error("Use a $project stage rather than .projection() on an aggregation");
        }
        return this.__configure("projection", spec);
    };
    Cursor.prototype.limit = function (value) { return this.__configure("limit", value); };
    Cursor.prototype.skip = function (value) { return this.__configure("skip", value); };
    Cursor.prototype.batchSize = function (value) { return this.__configure("batchSize", value); };
    Cursor.prototype.hint = function (spec) { return this.__configure("hint", spec); };
    Cursor.prototype.collation = function (spec) { return this.__configure("collation", spec); };
    Cursor.prototype.maxTimeMS = function (value) { return this.__configure("maxTimeMS", value); };
    Cursor.prototype.allowDiskUse = function () { return this.__configure("allowDiskUse", true); };
    Cursor.prototype.__fill = function () {
        if (this.__batch !== null && this.__index < this.__batch.length) { return true; }
        if (this.__exhausted) { return false; }
        this.__started = true;
        var page = __tp.call({ op: "cursorFetch", handle: this.__handle });
        this.__batch = EJSON.deserialize(page.docs);
        this.__index = 0;
        this.__exhausted = page.done;
        return this.__batch.length > 0;
    };
    Cursor.prototype.hasNext = function () { return this.__fill(); };
    Cursor.prototype.next = function () {
        if (!this.__fill()) { throw new Error("The cursor has no more documents"); }
        return this.__batch[this.__index++];
    };
    Cursor.prototype.tryNext = function () { return this.__fill() ? this.__batch[this.__index++] : null; };
    Cursor.prototype.toArray = function () {
        var all = [];
        while (this.__fill()) { all.push(this.__batch[this.__index++]); }
        return all;
    };
    Cursor.prototype.forEach = function (body) {
        var index = 0;
        while (this.__fill()) { body(this.__batch[this.__index++], index++); }
        return undefined;
    };
    Cursor.prototype.map = function (body) {
        var mapped = [];
        while (this.__fill()) { mapped.push(body(this.__batch[this.__index++])); }
        return mapped;
    };
    Cursor.prototype.itcount = function () {
        var seen = 0;
        while (this.__fill()) { this.__index++; seen++; }
        return seen;
    };
    Cursor.prototype.size = function () { return this.itcount(); };
    Cursor.prototype.count = function () { return __tp.call({ op: "cursorCount", handle: this.__handle }); };
    Cursor.prototype.explain = function (verbosity) {
        return EJSON.deserialize(__tp.call({
            op: "cursorExplain",
            handle: this.__handle,
            verbosity: verbosity === undefined ? "queryPlanner" : String(verbosity)
        }));
    };
    Cursor.prototype.pretty = function () { return this; };
    Cursor.prototype.close = function () {
        __tp.call({ op: "cursorClose", handle: this.__handle });
        this.__exhausted = true;
        return undefined;
    };
    Cursor.prototype.isExhausted = function () { return !this.__fill(); };
    Cursor.prototype.objsLeftInBatch = function () {
        return this.__batch === null ? 0 : this.__batch.length - this.__index;
    };
    Cursor.prototype.toString = function () { return this.__describe; };
    """

    private static let collection = """
    function DBCollection(databaseName, name) {
        this.__db = databaseName;
        this.__name = name;
    }
    DBCollection.prototype.getName = function () { return this.__name; };
    DBCollection.prototype.getFullName = function () { return this.__db + "." + this.__name; };
    DBCollection.prototype.toString = function () { return this.getFullName(); };
    DBCollection.prototype.__call = function (op, payload) {
        payload = payload || {};
        payload.op = op;
        payload.db = this.__db;
        payload.collection = this.__name;
        return __tp.call(payload);
    };
    DBCollection.prototype.__reply = function (op, payload) {
        return EJSON.deserialize(this.__call(op, payload));
    };
    DBCollection.prototype.find = function (filter, projection) {
        var handle = this.__call("openCursor", {
            kind: "find",
            filter: __ejson(filter === undefined ? {} : filter),
            projection: projection === undefined ? null : __ejson(projection)
        });
        return new Cursor(handle, this.getFullName() + ".find()");
    };
    DBCollection.prototype.findOne = function (filter, projection) {
        var found = this.find(filter, projection).limit(1);
        return found.hasNext() ? found.next() : null;
    };
    DBCollection.prototype.aggregate = function (pipeline, options) {
        var stages = pipeline === undefined ? [] : pipeline;
        if (!Array.isArray(stages)) {
            stages = Array.prototype.slice.call(arguments);
            options = undefined;
        }
        var handle = this.__call("openCursor", {
            kind: "aggregate",
            pipeline: __ejson(stages),
            options: options === undefined ? null : __ejson(options)
        });
        return new Cursor(handle, this.getFullName() + ".aggregate()");
    };
    DBCollection.prototype.countDocuments = function (filter) {
        return this.__call("countDocuments", { filter: __ejson(filter === undefined ? {} : filter) });
    };
    DBCollection.prototype.count = function (filter) { return this.countDocuments(filter); };
    DBCollection.prototype.estimatedDocumentCount = function () {
        return this.__call("estimatedDocumentCount", {});
    };
    DBCollection.prototype.distinct = function (field, filter) {
        return this.__reply("distinct", {
            field: String(field),
            filter: __ejson(filter === undefined ? {} : filter)
        });
    };
    DBCollection.prototype.insertOne = function (document) {
        if (document === undefined || document === null) { throw new Error("insertOne needs a document"); }
        var reply = this.__reply("insertOne", { document: __ejson(document) });
        return { acknowledged: true, insertedId: reply.insertedIds[0] };
    };
    DBCollection.prototype.insertMany = function (documents) {
        var reply = this.__reply("insertMany", { documents: __ejson(documents) });
        return {
            acknowledged: true,
            insertedIds: reply.insertedIds,
            insertedCount: reply.insertedCount
        };
    };
    DBCollection.prototype.insert = function (documentOrArray) {
        return Array.isArray(documentOrArray)
            ? this.insertMany(documentOrArray)
            : this.insertOne(documentOrArray);
    };
    function __updateResult(reply) {
        // An upsert replies with n = 1 and an `upserted` entry even though nothing matched, so the
        // upserted rows come out of `n` to give mongosh's matchedCount.
        var upserted = reply.upserted || [];
        return {
            acknowledged: true,
            matchedCount: Math.max((reply.n || 0) - upserted.length, 0),
            modifiedCount: reply.nModified || 0,
            upsertedCount: upserted.length,
            upsertedId: upserted.length ? upserted[0]._id : null
        };
    }
    DBCollection.prototype.__write = function (op, filter, change, options, multi) {
        if (change === undefined || change === null) {
            throw new Error(op === "replace"
                ? "replaceOne needs a replacement document"
                : "update needs an update document or pipeline");
        }
        return __updateResult(this.__reply(op, {
            filter: __ejson(filter === undefined ? {} : filter),
            update: __ejson(change),
            options: options === undefined ? null : __ejson(options),
            multi: multi === true
        }));
    };
    DBCollection.prototype.updateOne = function (filter, update, options) {
        return this.__write("update", filter, update, options, false);
    };
    DBCollection.prototype.updateMany = function (filter, update, options) {
        return this.__write("update", filter, update, options, true);
    };
    DBCollection.prototype.update = function (filter, update, options) {
        return this.__write("update", filter, update, options, !!(options && options.multi));
    };
    DBCollection.prototype.replaceOne = function (filter, replacement, options) {
        return this.__write("replace", filter, replacement, options, false);
    };
    DBCollection.prototype.save = function (document) {
        if (document && document._id !== undefined) {
            return this.replaceOne({ _id: document._id }, document, { upsert: true });
        }
        return this.insertOne(document);
    };
    DBCollection.prototype.__delete = function (filter, options, multi) {
        var reply = this.__reply("delete", {
            filter: __ejson(filter === undefined ? {} : filter),
            options: options === undefined ? null : __ejson(options),
            multi: multi
        });
        return { acknowledged: true, deletedCount: reply.n || 0 };
    };
    DBCollection.prototype.deleteOne = function (filter, options) {
        return this.__delete(filter, options, false);
    };
    DBCollection.prototype.deleteMany = function (filter, options) {
        return this.__delete(filter, options, true);
    };
    DBCollection.prototype.remove = function (filter, justOne) {
        return justOne === true ? this.deleteOne(filter) : this.deleteMany(filter);
    };
    DBCollection.prototype.__findAndModify = function (filter, change, options, remove) {
        if (!remove && (change === undefined || change === null)) {
            throw new Error("findOneAndUpdate needs an update document or pipeline");
        }
        var reply = this.__reply("findAndModify", {
            filter: __ejson(filter === undefined ? {} : filter),
            update: change === undefined ? null : __ejson(change),
            options: options === undefined ? null : __ejson(options),
            remove: remove
        });
        return reply.value === undefined ? null : reply.value;
    };
    DBCollection.prototype.findOneAndUpdate = function (filter, update, options) {
        return this.__findAndModify(filter, update, options, false);
    };
    DBCollection.prototype.findOneAndReplace = function (filter, replacement, options) {
        return this.__findAndModify(filter, replacement, options, false);
    };
    DBCollection.prototype.findOneAndDelete = function (filter, options) {
        return this.__findAndModify(filter, undefined, options, true);
    };
    DBCollection.prototype.bulkWrite = function (operations) {
        var reply = this.__reply("bulkWrite", { operations: __ejson(operations) });
        reply.acknowledged = true;
        return reply;
    };
    DBCollection.prototype.createIndex = function (keys, options) {
        this.__reply("createIndex", {
            keys: __ejson(keys),
            options: options === undefined ? null : __ejson(options)
        });
        return __indexName(keys, options);
    };
    DBCollection.prototype.createIndexes = function (specs, options) {
        var made = [];
        for (var i = 0; i < specs.length; i++) { made.push(this.createIndex(specs[i], options)); }
        return made;
    };
    DBCollection.prototype.dropIndex = function (name) {
        return this.__reply("dropIndex", { index: __ejson(name) });
    };
    DBCollection.prototype.dropIndexes = function () {
        return this.__reply("dropIndex", { index: __ejson("*") });
    };
    DBCollection.prototype.getIndexes = function () { return this.__reply("listIndexes", {}); };
    DBCollection.prototype.getIndices = DBCollection.prototype.getIndexes;
    DBCollection.prototype.drop = function () { return this.__reply("dropCollection", {}); };
    DBCollection.prototype.renameCollection = function (name, dropTarget) {
        return this.__reply("renameCollection", { target: String(name), dropTarget: dropTarget === true });
    };
    DBCollection.prototype.stats = function () { return this.__reply("collectionStats", {}); };
    DBCollection.prototype.dataSize = function () { return this.stats().size; };
    DBCollection.prototype.storageSize = function () { return this.stats().storageSize; };
    DBCollection.prototype.totalIndexSize = function () { return this.stats().totalIndexSize; };
    DBCollection.prototype.totalSize = function () {
        var stats = this.stats();
        return stats.storageSize + stats.totalIndexSize;
    };
    DBCollection.prototype.isCapped = function () { return this.stats().capped === true; };
    DBCollection.prototype.validate = function (full) {
        return this.__reply("command", {
            command: __ejson({ validate: this.__name, full: full === true })
        });
    };
    DBCollection.prototype.hideIndex = function (index) { return this.__hideIndex(index, true); };
    DBCollection.prototype.unhideIndex = function (index) { return this.__hideIndex(index, false); };
    DBCollection.prototype.__hideIndex = function (index, hidden) {
        var key = typeof index === "string" ? { name: index } : { keyPattern: index };
        key.hidden = hidden;
        return this.__reply("command", {
            command: __ejson({ collMod: this.__name, index: key })
        });
    };
    DBCollection.prototype.explain = function (verbosity) {
        var target = this;
        var level = verbosity === undefined ? "queryPlanner" : String(verbosity);
        return {
            find: function (filter, projection) { return target.find(filter, projection).explain(level); },
            aggregate: function (pipeline) { return target.aggregate(pipeline).explain(level); },
            count: function (filter) { return target.find(filter).explain(level); }
        };
    };

    function __indexName(keys, options) {
        if (options && options.name) { return String(options.name); }
        var parts = [];
        for (var key in keys) {
            if (Object.prototype.hasOwnProperty.call(keys, key)) { parts.push(key + "_" + keys[key]); }
        }
        return parts.length ? parts.join("_") : "index";
    }
    """

    private static let database = """
    function DB(name) {
        this.__name = name;
        var owner = this;
        return new Proxy(this, {
            get: function (target, key) {
                if (typeof key !== "string") { return target[key]; }
                if (key in target) { return target[key]; }
                if (key.indexOf("__") === 0) { return undefined; }
                return new DBCollection(owner.__name, key);
            }
        });
    }
    DB.prototype.getName = function () { return this.__name; };
    DB.prototype.toString = function () { return this.__name; };
    DB.prototype.getCollection = function (name) { return new DBCollection(this.__name, String(name)); };
    DB.prototype.getSiblingDB = function (name) { return new DB(String(name)); };
    DB.prototype.getMongo = function () {
        return { getDB: function (name) { return new DB(String(name)); } };
    };
    DB.prototype.runCommand = function (command) {
        return EJSON.deserialize(__tp.call({ op: "command", db: this.__name, command: __ejson(command) }));
    };
    DB.prototype.adminCommand = function (command) {
        return EJSON.deserialize(__tp.call({ op: "command", db: "admin", command: __ejson(command) }));
    };
    DB.prototype.getCollectionNames = function () {
        return __tp.call({ op: "listCollections", db: this.__name });
    };
    DB.prototype.getCollectionInfos = function () {
        return this.runCommand({ listCollections: 1 }).cursor.firstBatch;
    };
    DB.prototype.createCollection = function (name, options) {
        var command = { create: String(name) };
        if (options) {
            for (var key in options) {
                if (Object.prototype.hasOwnProperty.call(options, key)) { command[key] = options[key]; }
            }
        }
        return this.runCommand(command);
    };
    DB.prototype.dropDatabase = function () { return this.runCommand({ dropDatabase: 1 }); };
    DB.prototype.stats = function () { return this.runCommand({ dbStats: 1 }); };
    DB.prototype.version = function () { return this.runCommand({ buildInfo: 1 }).version; };
    DB.prototype.serverStatus = function () { return this.adminCommand({ serverStatus: 1 }); };
    DB.prototype.hostInfo = function () { return this.adminCommand({ hostInfo: 1 }); };
    DB.prototype.currentOp = function () { return this.adminCommand({ currentOp: 1 }); };
    DB.prototype.killOp = function (id) { return this.adminCommand({ killOp: 1, op: id }); };
    DB.prototype.getCollectionNames = DB.prototype.getCollectionNames;

    var db = new DB(__tp.call({ op: "currentDatabase" }));

    function use(name) {
        db = new DB(String(name));
        __tp.call({ op: "useDatabase", db: String(name) });
        return "switched to db " + String(name);
    }

    function show(what) {
        var topic = String(what);
        if (topic === "dbs" || topic === "databases") {
            return db.adminCommand({ listDatabases: 1 }).databases;
        }
        if (topic === "collections" || topic === "tables") { return db.getCollectionNames(); }
        throw new Error("show " + topic + " is not something TablePro knows");
    }
    """

    private static let serialization = """
    var EJSON = (function () {
        function serialize(value) {
            if (value === null || value === undefined) { return null; }
            if (typeof value === "boolean" || typeof value === "string") { return value; }
            if (typeof value === "number") { return serializeNumber(value); }
            if (typeof value.toEJSON === "function") { return value.toEJSON(); }
            if (typeof value === "function") { return { "$code": String(value) }; }
            if (Array.isArray(value)) {
                var list = [];
                for (var i = 0; i < value.length; i++) { list.push(serialize(value[i])); }
                return list;
            }
            if (value instanceof Date) { return { "$date": { "$numberLong": String(value.getTime()) } }; }
            if (value instanceof RegExp) {
                return { "$regularExpression": { pattern: value.source, options: value.flags } };
            }
            var document = {};
            for (var key in value) {
                if (Object.prototype.hasOwnProperty.call(value, key)) { document[key] = serialize(value[key]); }
            }
            return document;
        }

        function serializeNumber(value) {
            if (!isFinite(value)) { return { "$numberDouble": String(value) }; }
            if (Math.floor(value) !== value) { return { "$numberDouble": String(value) }; }
            return value >= -2147483648 && value <= 2147483647
                ? { "$numberInt": String(value) }
                : { "$numberLong": String(value) };
        }

        function deserialize(value) {
            if (value === null || typeof value !== "object") { return value; }
            if (Array.isArray(value)) {
                var list = [];
                for (var i = 0; i < value.length; i++) { list.push(deserialize(value[i])); }
                return list;
            }
            var keys = Object.keys(value);
            if (keys.length === 1 || (keys.length === 2 && keys[0] === "$code")) {
                var revived = revive(value, keys[0]);
                if (revived !== undefined) { return revived; }
            }
            var document = {};
            for (var key in value) {
                if (Object.prototype.hasOwnProperty.call(value, key)) { document[key] = deserialize(value[key]); }
            }
            return document;
        }

        function revive(value, key) {
            switch (key) {
            case "$oid": return new ObjectId(value.$oid);
            case "$numberInt": return parseInt(value.$numberInt, 10);
            case "$numberDouble": return Number(value.$numberDouble);
            case "$numberLong": return new NumberLong(value.$numberLong);
            case "$numberDecimal": return new NumberDecimal(value.$numberDecimal);
            case "$date":
                return new Date(typeof value.$date === "object" ? Number(value.$date.$numberLong) : value.$date);
            case "$regularExpression":
                return new RegExp(value.$regularExpression.pattern, value.$regularExpression.options);
            case "$binary": return new BinData(parseInt(value.$binary.subType, 16), value.$binary.base64);
            case "$timestamp": return new Timestamp(value.$timestamp.t, value.$timestamp.i);
            case "$minKey": return MinKey;
            case "$maxKey": return MaxKey;
            case "$code": return new Code(value.$code, value.$scope);
            case "$symbol": return String(value.$symbol);
            default: return undefined;
            }
        }

        return {
            serialize: serialize,
            deserialize: deserialize,
            stringify: function (value, indent) {
                return JSON.stringify(serialize(value), null, indent === undefined ? 0 : indent);
            },
            parse: function (text) {
                return deserialize(typeof text === "string" ? JSON.parse(text) : text);
            }
        };
    })();
    """

    private static let output = """
    function tojson(value, indent) {
        if (value === undefined) { return "undefined"; }
        if (value === null) { return "null"; }
        if (typeof value === "string") { return value; }
        if (typeof value.toEJSON === "function") { return value.toString(); }
        if (typeof value !== "object") { return String(value); }
        if (value instanceof Cursor) { return value.toString(); }
        return JSON.stringify(EJSON.serialize(value), null, indent === undefined ? 2 : indent);
    }

    function __emit(text) {
        if (__tp_print(text) === false) {
            var stopped = new Error("The script was cancelled.");
            stopped.isMongoError = true;
            stopped.code = 0;
            throw stopped;
        }
    }

    function print() {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) { parts.push(tojson(arguments[i], 0)); }
        __emit(parts.join(" "));
    }

    function printjson(value) { __emit(tojson(value, 2)); }

    var console = {
        log: function () { print.apply(null, arguments); },
        info: function () { print.apply(null, arguments); },
        warn: function () { print.apply(null, arguments); },
        error: function () { print.apply(null, arguments); },
        debug: function () { print.apply(null, arguments); }
    };

    function sleep(milliseconds) { __tp.call({ op: "sleep", ms: Number(milliseconds) }); }

    /// Tells the host what a statement evaluated to, so a cursor nothing has read can be drained
    /// straight into the result grid without its documents crossing into JavaScript at all.
    function __tp_classify(value) {
        if (value === undefined || value === null) { return JSON.stringify({ kind: "none" }); }
        if (value instanceof Cursor) {
            return JSON.stringify({ kind: "cursor", handle: value.__handle });
        }
        if (Array.isArray(value)) {
            var texts = [];
            for (var i = 0; i < value.length; i++) { texts.push(tojson(value[i], 0)); }
            return JSON.stringify({ kind: "array", json: __ejson(value), texts: texts });
        }
        return JSON.stringify({
            kind: typeof value === "object" && typeof value.toEJSON !== "function" ? "document" : "scalar",
            json: __ejson(value),
            text: tojson(value, 0)
        });
    }
    """
}
