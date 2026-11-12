//
//  BooleanPickerViewTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct BooleanPickerViewTests {
    @Test("Stored booleans select true or false")
    func storedBooleansSelectAChoice() {
        for text in ["1", "true", "t", "yes"] {
            #expect(BooleanPickerView.normalized(text) == "1", "\(text)")
        }
        for text in ["0", "false", "f", "no"] {
            #expect(BooleanPickerView.normalized(text) == "0", "\(text)")
        }
        #expect(BooleanPickerView.unrecognizedValue(of: .value("1")) == nil)
    }

    @Test("A TINYINT(1) holding 2 shows 2, never false")
    func otherIntegerShowsItself() {
        #expect(BooleanPickerView.normalized("2") == "2")
        #expect(BooleanPickerView.unrecognizedValue(of: .value("2")) == "2")
    }

    @Test("NULL and an empty value add no extra choice")
    func statesAddNoChoice() {
        #expect(BooleanPickerView.unrecognizedValue(of: .null) == nil)
        #expect(BooleanPickerView.unrecognizedValue(of: .value("")) == nil)
        #expect(BooleanPickerView.unrecognizedValue(of: .multipleValues) == nil)
    }
}
