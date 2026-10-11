enum SQLiteQueryTimeout {
    static func milliseconds(seconds: Int) -> Int32 {
        PluginQueryTimeout.int32Milliseconds(seconds)
    }
}
