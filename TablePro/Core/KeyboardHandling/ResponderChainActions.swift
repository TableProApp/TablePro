import AppKit

@objc protocol TableProResponderActions {
    @objc optional func undo(_ sender: Any?)
    @objc optional func redo(_ sender: Any?)
    @objc optional func copyRowsAsTSV(_ sender: Any?)
}
