import Foundation
import TableProPluginKit

extension Array where Element == ConnectionField {
    // A list with a visibility rule belongs to one mode (Redis Sentinel, Cluster) and leaves Host and Port to the rest.
    var endpointHostList: ConnectionField? {
        first { field in
            guard case .hostList = field.fieldType else { return false }
            return field.section == .connection && field.visibleWhen == nil
        }
    }
}
