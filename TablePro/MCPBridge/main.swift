import Foundation

let proxy = MCPBridgeProxy()

Task {
    await proxy.run()
}

RunLoop.main.run()
