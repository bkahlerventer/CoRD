//
//  RDCBitmap.h
//  Remote Desktop
//
//  Created by Craig Dooley on 8/28/06.

//  Copyright (c) 2006 Craig Dooley <xlnxminusx@gmail.com>
//  Permission is hereby granted, free of charge, to any person obtaining a 
//  copy of this software and associated documentation files (the "Software"), 
//  to deal in the Software without restriction, including without limitation 
//  the rights to use, copy, modify, merge, publish, distribute, sublicense, 
//  and/or sell copies of the Software, and to permit persons to whom the 
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in 
//  all copies or substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN 
//  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import <Cocoa/Cocoa.h>
#import "RDCView.h"

@interface RDCBitmap : NSObject {
	NSImage *image;
	NSBitmapImageRep *bitmap;
	NSData *data;
	NSCursor *cursor;
	unsigned char *planes[2];
	NSColor *color;
}

-(void)bitmapWithData:(const unsigned char *)d size:(NSSize)s view:(RDCView *)v;
-(void)glyphWithData:(const unsigned char *)d size:(NSSize)s view:(RDCView *)v;
-(void)cursorWithData:(const unsigned char *)d alpha:(const unsigned char *)a size:(NSSize)s hotspot:(NSPoint)hotspot view:(RDCView *)v;
-(NSImage *)image;
-(void)setColor:(NSColor *)color;
-(NSColor *)color;
-(NSCursor *)cursor;
@end
