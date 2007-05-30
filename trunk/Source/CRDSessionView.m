/*	Copyright (c) 2006 Craig Dooley <xlnxminusx@gmail.com>

	This file is part of CoRD.
	CoRD is free software; you can redistribute it and/or modify it under the
	terms of the GNU General Public License as published by the Free Software
	Foundation; either version 2 of the License, or (at your option) any later
	version.

	CoRD is distributed in the hope that it will be useful, but WITHOUT ANY
	WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
	FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along with
	CoRD; if not, write to the Free Software Foundation, Inc., 51 Franklin St,
	Fifth Floor, Boston, MA 02110-1301 USA
*/

/*	Note: 'backing store' in this class refers to the buffer that rdesktop draws to, not an AppKit window buffer
*/

#import "CRDSessionView.h"


#import "CRDKeyboard.h"
#import "CRDBitmap.h"
#import "CRDSession.h"

@interface CRDSessionView (Private)
	- (void)send_modifiers:(NSEvent *)ev enable:(BOOL)en;
	- (void)recheckScheduledMouseInput:(NSTimer*)timer;
	- (void)generateTexture;
	- (void)createBackingStore:(NSSize)s;
	- (void)destroyBackingStore;
@end

#pragma mark -

@implementation CRDSessionView

#pragma mark -
#pragma mark NSView

- (id)initWithFrame:(NSRect)frame
{
	NSOpenGLPixelFormatAttribute pixelAttribs[4] = {NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, 24, 0};
	NSOpenGLPixelFormat *pf = [[[NSOpenGLPixelFormat alloc] initWithAttributes:pixelAttribs] autorelease];
	
	if (![super initWithFrame:frame pixelFormat:pf])
		return nil;

	[self setBounds:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];
	screenSize = frame.size;
		
	// OpenGL initialization
	[self createBackingStore:screenSize];
		
	// Other initializations
	[self setCursor:[NSCursor arrowCursor]];
	colorMap = calloc(256, sizeof(unsigned int));
	keyTranslator = [[CRDKeyboard alloc] init];
	
	
	[self resetCursorRects];
	[self resetClip];
	
    return self;
}

- (void)dealloc
{
	[keyTranslator release];
	[cursor release];
	[self destroyBackingStore];

	free(colorMap);
	colorMap = NULL;
	
	[super dealloc];
}

- (void)drawRect:(NSRect)rect
{
	[self generateTexture];
	
	glClear(GL_COLOR_BUFFER_BIT);
	GLfloat textureWidth = rdBufferWidth;
	GLfloat textureHeight = rdBufferHeight; 
	glBindTexture(GL_TEXTURE_RECTANGLE_EXT, rdBufferTexture);

	glBegin(GL_QUADS);
	
	glTexCoord2f(0.0f, textureHeight);
	glVertex2f(-1.0f, 1.0f);
	glTexCoord2f(0.0f, 0.0f);
	glVertex2f(-1.0f, -1.0f);
	glTexCoord2f(textureWidth, 0.0f);
	glVertex2f(1.0f, -1.0f);
	glTexCoord2f(textureWidth, textureHeight);
	glVertex2f(1.0f, 1.0f);

	glEnd();   

	[[self openGLContext] flushBuffer];
}

- (BOOL)isFlipped
{
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (BOOL)wantsDefaultClipping
{
	return NO;
}


- (void)resetCursorRects
{
    [self discardCursorRects];
    [self addCursorRect:[self visibleRect] cursor:cursor]; 
}

- (void)setFrame:(NSRect)frame
{	
	[super setFrame:frame];

	[self setBounds:(NSRect){frame.origin, screenSize}];
	[self reshape];
}


#pragma mark -
#pragma mark NSOpenGLView

-(void)prepareOpenGL
{
	glEnable(GL_TEXTURE_RECTANGLE_EXT);
	glShadeModel(GL_SMOOTH);
	glClearColor(0.0f, 0.0f, 0.0f, 0.0f); 
	glGenTextures(1, &rdBufferTexture);
}

- (void)reshape
{
    NSRect rect = [self bounds];
    rect.size = [self convertSize:rect.size toView:nil];
    glViewport(0.0, 0.0, NSWidth(rect), NSHeight(rect));
}


#pragma mark -
#pragma mark NSResponder Event Handlers

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)becomeFirstResponder
{
	[controller announceNewClipboardData];
	return YES;
}

- (BOOL)resignFirstResponder
{
	[controller requestRemoteClipboardData];	
	return [super resignFirstResponder];
}


- (void)keyDown:(NSEvent *)ev
{
	[keyTranslator handleKeyEvent:ev keyDown:YES];
}

- (void)keyUp:(NSEvent *)ev
{
	[keyTranslator handleKeyEvent:ev keyDown:NO];
}

- (void)flagsChanged:(NSEvent *)ev
{ 	
	[keyTranslator handleFlagsChanged:ev];
}

- (void)mouseDown:(NSEvent *)ev
{
	int flags = [ev modifierFlags];
	if ((flags & NSShiftKeyMask) && (flags & NSControlKeyMask))
	{
		// xxx: this doesn't respect left or right			
		[keyTranslator sendScancode:SCANCODE_CHAR_LSHIFT flags:RDP_KEYRELEASE];
		[keyTranslator sendScancode:SCANCODE_CHAR_LCTRL flags:RDP_KEYRELEASE];
		[self rightMouseDown:ev];
		[keyTranslator sendScancode:SCANCODE_CHAR_LSHIFT flags:RDP_KEYPRESS];
		[keyTranslator sendScancode:SCANCODE_CHAR_LCTRL flags:RDP_KEYPRESS];
		return;
	}
	
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_DOWN | MOUSE_FLAG_BUTTON1];
}

- (void)mouseUp:(NSEvent *)ev
{
	int flags = [ev modifierFlags];
	if ((flags & NSShiftKeyMask) && (flags & NSControlKeyMask))
	{
		[keyTranslator sendScancode:SCANCODE_CHAR_LSHIFT flags:RDP_KEYRELEASE];
		[keyTranslator sendScancode:SCANCODE_CHAR_LCTRL flags:RDP_KEYRELEASE];
		[self rightMouseUp:ev];
		[keyTranslator sendScancode:SCANCODE_CHAR_LSHIFT flags:RDP_KEYPRESS];
		[keyTranslator sendScancode:SCANCODE_CHAR_LCTRL flags:RDP_KEYPRESS];
		return;
	}
	
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_BUTTON1];
}

- (void)rightMouseDown:(NSEvent *)ev
{
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_DOWN | MOUSE_FLAG_BUTTON2];
}

- (void)rightMouseUp:(NSEvent *)ev
{
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_BUTTON2];
}

- (void)otherMouseDown:(NSEvent *)ev
{
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_DOWN | MOUSE_FLAG_BUTTON3];
}

- (void)otherMouseUp:(NSEvent *)ev
{
	if ([self checkMouseInBounds:ev])
		[self sendMouseInput:MOUSE_FLAG_BUTTON3];
}

- (void)scrollWheel:(NSEvent *)ev
{
	if ([ev deltaY] > 0)
	{
		[self sendMouseInput:MOUSE_FLAG_DOWN | MOUSE_FLAG_BUTTON4];
		[self sendMouseInput:MOUSE_FLAG_BUTTON4];
	}
	else if ([ev deltaY] < 0)
	{
		[self sendMouseInput:MOUSE_FLAG_DOWN | MOUSE_FLAG_BUTTON5];
		[self sendMouseInput:MOUSE_FLAG_BUTTON5];
	}
}

- (void)mouseDragged:(NSEvent *)ev
{
	[self mouseMoved:ev];
}

- (void)mouseMoved:(NSEvent *)ev
{

	if ([self checkMouseInBounds:ev])
	{
		if ([mouseInputScheduler isValid])
			[mouseInputScheduler invalidate];
				
		[mouseInputScheduler release];
		mouseInputScheduler = nil;
		
		if ( [[NSDate date] timeIntervalSinceDate:lastMouseEventSentAt] >= (1.0/CRDMouseEventLimit) )
		{
			[lastMouseEventSentAt release];
			lastMouseEventSentAt = [[NSDate date] retain];
			[self sendMouseInput:MOUSE_FLAG_MOVE];
		}
		else
		{
			mouseInputScheduler = [[NSTimer scheduledTimerWithTimeInterval:(1.0/CRDMouseEventLimit)
					target:self selector:@selector(recheckScheduledMouseInput:)
					userInfo:nil repeats:NO] retain];
		}		
	}
}


#pragma mark -
#pragma mark Translating Input Events

- (BOOL)checkMouseInBounds:(NSEvent *)ev
{ 
	mouseLoc = [self convertPoint:[ev locationInWindow] fromView:nil];
	return NSPointInRect([self convertPoint:[ev locationInWindow] fromView:nil], [self bounds]);
}

- (void)sendMouseInput:(unsigned short)flags
{
	[controller sendInputOnConnectionThread:time(NULL) type:RDP_INPUT_MOUSE flags:flags param1:lrintf(mouseLoc.x) param2:lrintf(mouseLoc.y)];
}

- (void)recheckScheduledMouseInput:(NSTimer*)timer
{
	[self mouseMoved:deferredMouseEvent];
}



#pragma mark -
#pragma mark Drawing to the backing store 

- (void)ellipse:(NSRect)r color:(NSColor *)c
{
	[self focusBackingStore];
	[c set];
	[[NSBezierPath bezierPathWithOvalInRect:r] fill];
	[self releaseBackingStore];
}

- (void)polygon:(RDPoint*)points npoints:(int)nPoints color:(NSColor *)c
		winding:(NSWindingRule)winding
{
	NSBezierPath *bp = [NSBezierPath bezierPath];
	int i;
	
	[bp moveToPoint:NSMakePoint(points[0].x + 0.5, points[0].y + 0.5)];
	for (i = 1; i < nPoints; i++)
		[bp relativeLineToPoint:NSMakePoint(points[i].x, points[i].y)];

	[bp closePath];
	
	[self focusBackingStore];
	[c set];
	[bp fill];
	[self releaseBackingStore];
}

- (void)polyline:(RDPoint*)points npoints:(int)nPoints color:(NSColor *)c width:(int)w
{
	NSBezierPath *bp = [NSBezierPath bezierPath];
	int i;
	
	[bp moveToPoint:NSMakePoint(points[0].x + 0.5f, points[0].y + 0.5f)];
	for (i = 1; i < nPoints; i++)
		[bp relativeLineToPoint:NSMakePoint(points[i].x, points[i].y)];

	[bp setLineWidth:w];
	[bp closePath];
	
	[self focusBackingStore];
	[c set];
	[bp stroke];
	[self releaseBackingStore];
}

- (void)fillRect:(NSRect)rect withColor:(NSColor *)color
{	
	[self fillRect:rect withColor:color patternOrigin:NSZeroPoint];
}

- (void)fillRect:(NSRect)rect withColor:(NSColor *)color patternOrigin:(NSPoint)origin
{
	[self focusBackingStore];
	[color set];
	[[NSGraphicsContext currentContext] setPatternPhase:origin];
	NSRectFill(rect);
	[self releaseBackingStore];
}

- (void)fillRect:(NSRect)rect withRDColor:(int)color
{
	[self focusBackingStore];
	
	CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
	unsigned char r, g, b;
	
	[self rgbForRDCColor:color r:&r g:&g b:&b];
	CGContextSetRGBFillColor(context, r/255.0f, g/255.0f, b/255.0f, 1.0);
	CGContextFillRect(context, CGRECT_FROM_NSRECT(rect));
	
	[self releaseBackingStore];
}

- (void)drawBitmap:(CRDBitmap *)image inRect:(NSRect)to from:(NSPoint)origin operation:(NSCompositingOperation)op
{
	[self focusBackingStore];
	
	[image drawInRect:to
			 fromRect:NSMakeRect(origin.x, origin.y, NSWidth(to), NSHeight(to))
			operation:op];
	[self releaseBackingStore];
}

- (void)screenBlit:(NSRect)from to:(NSPoint)to
{
	[self focusBackingStore];
	NSRectClip(NSMakeRect(to.x, to.y, NSWidth(from), NSHeight(from)));
	CGImageRef rdBufferImage = CGBitmapContextCreateImage(rdBufferContext);
	
	CGContextDrawImage([[NSGraphicsContext currentContext] graphicsPort], CGRectMake(to.x - from.origin.x, to.y - from.origin.y,  screenSize.width, screenSize.height), rdBufferImage);
	
	CGImageRelease(rdBufferImage);
	
	[self releaseBackingStore];
}

- (void)drawLineFrom:(NSPoint)start to:(NSPoint)end color:(NSColor *)color width:(int)width
{
	[NSBezierPath setDefaultLineWidth:0.0];
	
	[self focusBackingStore];
	[color set];
	[NSBezierPath strokeLineFromPoint:start toPoint:end];
	[self releaseBackingStore];
}

- (void)drawGlyph:(CRDBitmap *)glyph at:(NSRect)r foregroundColor:(NSColor *)foregroundColor;
{
	// Assumes that focusBackingStore has already been called (for efficiency)
	
	if (![[glyph color] isEqual:foregroundColor])
	{
		[glyph overlayColor:foregroundColor];
		[glyph setColor:foregroundColor];
	}
	
	[glyph drawInRect:r fromRect:NSMakeRect(0, 0, NSWidth(r), NSHeight(r)) operation:NSCompositeSourceOver];
	
	//NSRectFill(r);
}

- (void)swapRect:(NSRect)r
{
	[self focusBackingStore];
	CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
	CGContextSaveGState(context);
	CGContextSetBlendMode(context, kCGBlendModeDifference);
	CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
	CGContextFillRect(context, CGRectMake(r.origin.x, r.origin.y, r.size.width, r.size.height));
	CGContextFlush(context);
	CGContextRestoreGState(context);
	[self releaseBackingStore];
}


#pragma mark -
#pragma mark Clipping backing store drawing

- (void)setClip:(NSRect)r
{
	clipRect = r;
}

- (void)resetClip
{
	clipRect = RECT_FROM_SIZE(screenSize);
}


#pragma mark -
#pragma mark Working with the backing store

- (void)startUpdate
{
	[self focusBackingStore];
}

- (void)stopUpdate
{
	[self releaseBackingStore];
}

- (void)focusBackingStore
{
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:rdBufferContext flipped:NO]];
	NSRectClip(clipRect);
}

- (void)releaseBackingStore
{
	[NSGraphicsContext restoreGraphicsState];
}

- (void)createBackingStore:(NSSize)s
{
	rdBufferWidth = s.width;
	rdBufferHeight = s.height;
		
	rdBufferBitmapLength = rdBufferWidth*rdBufferHeight*4;
	rdBufferBitmapData = malloc(rdBufferBitmapLength);

	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
	
	unsigned int byteOrder;

	rdBufferContext = CGBitmapContextCreate(rdBufferBitmapData, rdBufferWidth, rdBufferHeight, 8, rdBufferWidth*4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little); 		
}

- (void)destroyBackingStore
{
	CGContextRelease(rdBufferContext);
	free(rdBufferBitmapData);
	
	rdBufferBitmapData = NULL;
	rdBufferContext = NULL;
	rdBufferTexture = rdBufferBitmapLength = rdBufferWidth = rdBufferHeight = 0;
}

- (void)generateTexture
{
	CGContextFlush(rdBufferContext);

	glBindTexture(GL_TEXTURE_RECTANGLE_EXT, rdBufferTexture);
	
	glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE, GL_STORAGE_SHARED_APPLE); 
	glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);
		
	GLenum format;
	
#ifdef __LITTLE_ENDIAN__
	format = GL_UNSIGNED_INT_8_8_8_8_REV;
#else
	format = GL_UNSIGNED_INT_8_8_8_8;
#endif


	glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, rdBufferWidth, rdBufferHeight, 0, GL_BGRA, format, rdBufferBitmapData);

	glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
}

- (int)getBackingStoreBytes:(unsigned char **)retBytes
{
	*retBytes = rdBufferBitmapData;
	return rdBufferBitmapLength;
}


#pragma mark -
#pragma mark Converting RDP Colors

- (void)rgbForRDCColor:(int)col r:(unsigned char *)r g:(unsigned char *)g b:(unsigned char *)b
{
	if (bitdepth == 16)
	{
		*r = (( (col >> 11) & 0x1f) * 255 + 15) / 31;
		*g = (( (col >> 5) & 0x3f) * 255 + 31) / 63;
		*b = ((col & 0x1f) * 255 + 15) / 31;
		return;
	}
	else if (bitdepth == 15)
	{
		*r = (( (col >> 10) & 0x1f) * 255 + 15) / 31;
		*g = (( (col >> 5) & 0x1f) * 255 + 15) / 31;
		*b = ((col & 0x1f) * 255 + 15) / 31;
		return;
	}
	
	int t = (bitdepth == 8) ? colorMap[col] : col;

	*b = (t >> 16) & 0xff;
	*g = (t >> 8)  & 0xff;
	*r = t & 0xff;
}

- (NSColor *)nscolorForRDCColor:(int)col
{
	unsigned char r, g, b;
	[self rgbForRDCColor:col r:&r g:&g b:&b];
	
	return [NSColor colorWithDeviceRed:(float)r / 255.0f
								 green:(float)g / 255.0f
							  	  blue:(float)b / 255.0f
							     alpha:1.0f];
}


#pragma mark -
#pragma mark Other

- (void)setNeedsDisplayInRects:(NSArray *)rects
{
	NSEnumerator *enumerator = [rects objectEnumerator];
	id dirtyRect;
	
	while ( (dirtyRect = [enumerator nextObject]) )
		[self setNeedsDisplayInRectAsValue:dirtyRect];
	
	[rects release];
}

- (void)setNeedsDisplayInRectAsValue:(NSValue *)rectValue
{
	NSRect r = [rectValue rectValue];
	
	// Hack: make the box 1px bigger all around; seems to make updates much more
	//	reliable when the screen is stretched
	r.origin.x = (int)r.origin.x - 1.0f;
	r.origin.y = (int)r.origin.y - 1.0f;
	r.size.width = (int)r.size.width + 2.0f;
	r.size.height = (int)r.size.height + 2.0f;

	[self setNeedsDisplayInRect:r];
}


- (void)writeScreenCaptureToFile:(NSString *)path
{
	int width = [self width], height = [self height];
	NSBitmapImageRep *img = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
			pixelsWide:width
			pixelsHigh:height
			bitsPerSample:8
			samplesPerPixel:4
			hasAlpha:YES
			isPlanar:NO
			colorSpaceName:NSDeviceRGBColorSpace
			bytesPerRow:width*4
			bitsPerPixel:32];
			
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:img]]; 
	{
		NSAffineTransform *xform = [NSAffineTransform transform];
		[xform translateXBy:0.0 yBy:height];
		[xform scaleXBy:1.0 yBy:-1.0];
		[xform concat];
		
		CGImageRef screenDump = CGBitmapContextCreateImage(rdBufferContext);
		CGContextDrawImage([[NSGraphicsContext currentContext] graphicsPort], CGRectMake(0,0,width, height), screenDump);		
		CGImageRelease(screenDump);
	} [NSGraphicsContext restoreGraphicsState];
	
	NSData *fileContent = [img representationUsingType:NSPNGFileType properties:nil];
	[fileContent writeToFile:path atomically:YES];
	
	[img release];
}


- (void)setScreenSize:(NSSize)newSize
{
	screenSize = newSize;
	[self setBounds:RECT_FROM_SIZE(screenSize)];
	
	[self destroyBackingStore];
	[self createBackingStore:screenSize];

	[self resetClip];
	
	[self setNeedsDisplay:YES];
}


#pragma mark -
#pragma mark Accessors

- (void)setController:(CRDSession *)instance
{
	controller = instance;
	[keyTranslator setController:instance];
	bitdepth = [instance conn]->serverBpp;
}

- (int)bitsPerPixel
{
	return bitdepth;
}

- (int)width
{
	return [self bounds].size.width;
}

- (int)height
{
	return [self bounds].size.height;
}

- (unsigned int *)colorMap
{
	return colorMap;
}

- (void)setColorMap:(unsigned int *)map
{
	free(colorMap);
	colorMap = map;
}

- (void)setBitdepth:(int)depth
{
	bitdepth = depth;
}

- (void)setCursor:(NSCursor *)cur
{
	[cur retain];
	[cursor release];
	cursor = cur;
	
	[[self window] invalidateCursorRectsForView:self];
	[[self window] resetCursorRects];
}

- (CGContextRef)rdBufferContext
{
	return rdBufferContext;
}

@end
