//
//  PluginMetadataRegistry+MongoDBDataCommands.swift
//  TablePro
//

import Foundation

extension PluginMetadataRegistry {
    // mongosh CRUD methods the plugin's prelude defines, and the write commands of MongoDB 4.0 to 8.x
    // (https://www.mongodb.com/docs/manual/reference/command/, Query and Write Operation Commands), named as
    // `QueryClassifier.mongoDataCommands` names them.
    static let mongoDBDataCommands: Set<String> = [
        "db.collection.insertOne", "db.collection.insertMany", "db.collection.insert",
        "db.collection.updateOne", "db.collection.updateMany", "db.collection.update",
        "db.collection.replaceOne", "db.collection.save",
        "db.collection.deleteOne", "db.collection.deleteMany", "db.collection.remove",
        "db.collection.findOneAndUpdate", "db.collection.findOneAndReplace", "db.collection.findOneAndDelete",
        "db.collection.bulkWrite",
        "insert", "update", "delete", "findAndModify", "findandmodify"
    ]
}
