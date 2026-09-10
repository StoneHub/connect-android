import SwiftUI
#if !DEBUG
extension View {
    @inlinable
    func feedbackTarget(_ id: @autoclosure () -> String, label: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) -> some View { self }
    @inlinable
    func feedbackViewport() -> some View { self }
}
#endif
