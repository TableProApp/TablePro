//
//  CGContextHidden.m
//  CodeEditTextViewObjC
//
//  Created by Khan Winter on 2/12/24.
//

#import <Cocoa/Cocoa.h>
#import "CGContextHidden.h"

extern void CGContextSetFontSmoothingStyle(CGContextRef, int);

void ContextSetHiddenSmoothingStyle(CGContextRef context, int style) {
    CGContextSetFontSmoothingStyle(context, style);
}
