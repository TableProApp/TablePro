//
//  VimKeyInterceptorFocusTests.swift
//  TableProTests
//
//  Regression tests for VimKeyInterceptor focus lifecycle
//

@testable import TablePro
import Testing

@Suite("VimKeyInterceptor Focus Lifecycle")
@MainActor
struct VimKeyInterceptorFocusTests {
    private func makeInterceptor() -> VimKeyInterceptor {
        let buffer = VimTextBufferMock(text: "hello")
        let engine = VimEngine(buffer: buffer)
        return VimKeyInterceptor(engine: engine, inlineSuggestionManager: nil)
    }

    @Test("Initial state: isEditorFocused is false")
    func initialStateIsFalse() {
        let interceptor = makeInterceptor()
        #expect(interceptor.isEditorFocused == false)
    }

    @Test("After editorDidFocus: isEditorFocused is true")
    func focusSetsTrue() {
        let interceptor = makeInterceptor()
        interceptor.editorDidFocus()
        #expect(interceptor.isEditorFocused == true)
    }

    @Test("After editorDidBlur: isEditorFocused is false")
    func blurSetsFalse() {
        let interceptor = makeInterceptor()
        interceptor.editorDidFocus()
        interceptor.editorDidBlur()
        #expect(interceptor.isEditorFocused == false)
    }

    @Test("After uninstall: isEditorFocused is false")
    func uninstallResetsFocused() {
        let interceptor = makeInterceptor()
        interceptor.editorDidFocus()
        interceptor.uninstall()
        #expect(interceptor.isEditorFocused == false)
    }

    @Test("Focus/blur/focus cycle works correctly")
    func focusBlurFocusCycle() {
        let interceptor = makeInterceptor()
        interceptor.editorDidFocus()
        #expect(interceptor.isEditorFocused == true)
        interceptor.editorDidBlur()
        #expect(interceptor.isEditorFocused == false)
        interceptor.editorDidFocus()
        #expect(interceptor.isEditorFocused == true)
    }

    @Test("editorDidBlur when already blurred is a no-op")
    func blurWhenAlreadyBlurred() {
        let interceptor = makeInterceptor()
        interceptor.editorDidBlur()
        interceptor.editorDidBlur()
        #expect(interceptor.isEditorFocused == false)
    }

    @Test("editorDidFocus when already focused is a no-op")
    func focusWhenAlreadyFocused() {
        let interceptor = makeInterceptor()
        interceptor.editorDidFocus()
        interceptor.editorDidFocus()
        #expect(interceptor.isEditorFocused == true)
    }
}
