//
//  RDInstance.m
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

#import "RDInstance.h"
#import "RDCKeyboard.h"
#import "CRDServerCell.h"
#import "keychain.h"

// for sharedDocumentIcon
#import "AppController.h"



@interface RDInstance (Private)
	- (void)updateCellData;
	- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword;
	- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword force:(BOOL)force;
	- (void)setStatus:(CRDConnectionStatus)status;
@end


#pragma mark -

@implementation RDInstance

#pragma mark NSObject methods
- (id)init
{
	themes = cacheBitmaps = YES;
	return [self initWithRDPFile:nil];
}

- (void)dealloc
{
	if (connectionStatus == CRDConnectionConnected)
		[self disconnect];
	
	[label release];
	[hostName release];
	[username release];
	[password release];
	[domain release];
	[otherAttributes release];
	[rdpFilename release];
	
	// might be unneeded:
	[view release];
	
	[cellRepresentation release];
	[tabViewRepresentation release];
	[super dealloc];
}

- (id)initWithRDPFile:(NSString *)path
{
	if (![super init])
		return nil;

	fill_default_connection(&conn);
	
	// Use some safe defaults. The docs say it's fine to release a static string (@"").
	startDisplay = forwardAudio = screenDepth = screenWidth = screenHeight = port = 0;
	label = hostName = username = password = domain = @"";
	temporary = YES;
	[self setStatus:CRDConnectionClosed];
	
	// Other initializations
	otherAttributes = [[NSMutableDictionary alloc] init];
	cellRepresentation = [[CRDServerCell alloc] init];
	
	[cellRepresentation setImage:[AppController sharedDocumentIcon]];
	
	[self readRDPFile:path];
	
	
	return self;
}

- (id)valueForUndefinedKey:(NSString *)key
{
	return [otherAttributes objectForKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key
{
	if ([self valueForKey:key] != value)
	{
		modified |= ![key isEqualToString:@"view"];
		[super setValue:value forKey:key];
	}
}


#pragma mark -
#pragma mark RDP methods

// Invoked on incoming data arrival, starts the processing of incoming packets
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent
{
	uint8 type;
	STREAM s;
	uint32 ext_disc_reason;
	
	do
	{
		s = rdp_recv(&conn, &type);
		if (s == NULL)
		{
			[g_appController performSelectorOnMainThread:@selector(disconnectInstance:)
					withObject:self waitUntilDone:NO];
			return;
		}
		
		switch (type)
		{
			case RDP_PDU_DEMAND_ACTIVE:
				process_demand_active(&conn, s);
				break;
			case RDP_PDU_DEACTIVATE:
				DEBUG(("RDP_PDU_DEACTIVATE\n"));
				break;
			case RDP_PDU_DATA:
				if (process_data_pdu(&conn, s, &ext_disc_reason))
				{
					[g_appController performSelectorOnMainThread:@selector(disconnectInstance:)
							withObject:self waitUntilDone:NO];
					return;
				}
				break;
			case 0:
				break;
			default:
				unimpl("PDU %d\n", type);
		}
		
	} while (conn.nextPacket < s->end);

}

// Using the current properties, attempt to connect to a server. Blocks until timeout on failure.
- (BOOL) connect
{

	// Fail quickly if it's a totally bogus host
	if ([hostName length] < 2)
	{
		conn.errorCode = ConnectionErrorGeneral;
		return NO;
	}
		
	[self performSelectorOnMainThread:@selector(setStatusAsNumber:)
			withObject:[NSNumber numberWithInt:CRDConnectionConnecting] waitUntilDone:NO];

	// Set RDP5 performance flags
	int performanceFlags = RDP5_DISABLE_NOTHING;
	if (!windowDrags)
		performanceFlags |= RDP5_NO_FULLWINDOWDRAG;
	
	if (!themes)
		performanceFlags |= RDP5_NO_THEMING;
	
	if (!drawDesktop)
		performanceFlags |= RDP5_NO_WALLPAPER;
	
	if (!windowAnimation)
		performanceFlags |= RDP5_NO_MENUANIMATIONS;
	
	conn.rdp5PerformanceFlags = performanceFlags;
	

	// Set RDP logon flags
	int logonFlags = RDP_LOGON_NORMAL;
	if (password && username)
		logonFlags |= RDP_LOGON_AUTO;
	
	// Set some other settings
	conn.bitmapCache = cacheBitmaps;
	conn.serverBpp = screenDepth;	
	conn.controller = g_appController;
	conn.consoleSession = consoleSession;
	conn.screenWidth = screenWidth;
	conn.screenHeight = screenHeight;
	conn.tcpPort = (port==0 || port>=65536) ? 3389 : port;


	// Set up disk redirection
	if (forwardDisks)
	{
		NSArray *localDrives = [[NSWorkspace sharedWorkspace] mountedLocalVolumePaths];
		NSMutableArray *validDrives = [NSMutableArray arrayWithCapacity:5];
		NSMutableArray *validNames = [NSMutableArray arrayWithCapacity:5];
		
		NSFileManager *fm = [NSFileManager defaultManager];
		NSEnumerator *volumeEnumerator = [localDrives objectEnumerator];
		id anObject;
		while ( (anObject = [volumeEnumerator nextObject]) )
		{
			if ([anObject characterAtIndex:0] != '.')
			{
				[validDrives addObject:anObject];
				[validNames addObject:[fm displayNameAtPath:anObject]];
			}
		}
		
		disk_enum_devices(&conn,convert_string_array(validDrives),
						  convert_string_array(validNames),[validDrives count]);
	}
	
	rdpdr_init(&conn);
	
	strncpy(conn.username, safe_string_conv(username), sizeof(conn.username));
	
	// Make the connection
	BOOL connected = rdp_connect(&conn, safe_string_conv(hostName), 
							logonFlags, 
							safe_string_conv(domain), 
							safe_string_conv(password), 
							safe_string_conv(cCommand), 
							safe_string_conv(cDirectory));
							
	// Upon success, set up our incoming socket
	if (connected)
	{
		inputRunLoop = [NSRunLoop currentRunLoop];
	
		NSStream *is = conn.inputStream;
		[is setDelegate:self];
		[is scheduleInRunLoop:inputRunLoop forMode:NSDefaultRunLoopMode];
		
		view = [[RDCView alloc] initWithFrame:NSMakeRect(0.0, 0.0, conn.screenWidth, conn.screenHeight)];
		[view setController:self];
		[view performSelectorOnMainThread:@selector(setNeedsDisplay:)
							   withObject:[NSNumber numberWithBool:YES]
							waitUntilDone:NO];
		conn.ui = view;
				
		[self setStatus:CRDConnectionConnected];
	}
	else
	{	
		[self setStatus:CRDConnectionClosed];
	}
	
	return connected;
}

- (void) disconnect
{
	NSStream *is = conn.inputStream;
	[is removeFromRunLoop:inputRunLoop forMode:NSDefaultRunLoopMode];
	tcp_disconnect(&conn);
	[self setStatus:CRDConnectionClosed];
}

- (void) sendInput:(uint16) type flags:(uint16)flags param1:(uint16)param1 param2:(uint16)param2
{
	if (connectionStatus == CRDConnectionConnected)
		rdp_send_input(&conn, time(NULL), type, flags, param1, param2);
}


#pragma mark GUI management

// Should be called just after a successful connect
- (void) createGUI:(NSScrollView *)enclosingView
{	
	[enclosingView setDocumentView:view];
	[enclosingView setHasVerticalScroller:YES];
	[enclosingView setHasHorizontalScroller:YES];
	[enclosingView setAutohidesScrollers:YES];
	[enclosingView setBorderType:NSNoBorder];
	
	tabViewRepresentation = [[NSTabViewItem alloc] initWithIdentifier:label];
	[tabViewRepresentation setView:enclosingView];
	[tabViewRepresentation setLabel:label];	
}


#pragma mark Input run loop management
- (void)startInputRunLoop
{
	// Run the run loop, allocating/releasing a pool occasionally
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	BOOL gotInput;
	unsigned x = 0;
	do
	{
		if (x++ % 10 == 0)
		{
			[pool release];
			pool = [[NSAutoreleasePool alloc] init];
		}
		gotInput = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode 
					beforeDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
	} while (connectionStatus == CRDConnectionConnected && gotInput);
	
	[pool release];
}

#pragma mark -
#pragma mark Reading/writing RDP files

// This probably isn't safe to call from anywhere other than initWith.. in its
//	current form
- (BOOL) readRDPFile:(NSString *)path
{
	if (path == nil)
		return NO;
		
	[self setRdpFilename:path];	
	
	NSString *fileContents = [NSString stringWithContentsOfFile:path
			encoding:NSASCIIStringEncoding error:NULL];
	NSArray *fileLines = [fileContents componentsSeparatedByString:@"\r\n"];
	
	if (fileLines == nil)
	{
		NSLog(@"Couldn't open RDP file '%@'!", path);
		return NO;
	}
		
	NSScanner *scan;
	NSCharacterSet *colonSet = [NSCharacterSet characterSetWithCharactersInString:@":"],
				   *emptySet = [NSCharacterSet characterSetWithCharactersInString:@""];
				   
	NSString *name, *type, *value, *stringVal;
	int numVal;
	BOOL b;
	
	// Loop through each line, extracting the name, type, and value
	NSEnumerator *enumerator = [fileLines objectEnumerator];
	id line;
	while ( (line = [enumerator nextObject]) )
	{
		scan = [NSScanner scannerWithString:line];
		[scan setCharactersToBeSkipped:colonSet];
		
		b = YES;
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&name];
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&type];
		
		if (![scan scanUpToCharactersFromSet:emptySet intoString:&value])
			value = @"";
		
		// This doesn't use key-value coding because none of the side effects
		//	in the setters are desirable at load time
		
		if (b)
		{
			if ([type isEqualToString:@"i"])
				numVal = [value intValue];
			
			if ([name isEqualToString:@"connect to console"])
				consoleSession = numVal;
			else if ([name isEqualToString:@"bitmapcachepersistenable"]) 
				cacheBitmaps = numVal;
			else if ([name isEqualToString:@"redirectdrives"])
				forwardDisks = numVal;
			else if ([name isEqualToString:@"disable wallpaper"])
				drawDesktop = !numVal;
			else if ([name isEqualToString:@"disable full window drag"])
				windowDrags = !numVal;
			else if ([name isEqualToString:@"disable menu anims"])
				windowAnimation = !numVal;
			else if ([name isEqualToString:@"disable themes"])
				themes = !numVal;
			else if ([name isEqualToString:@"audiomode"])
				forwardAudio = numVal;
			else if ([name isEqualToString:@"desktopwidth"]) 
				screenWidth = numVal;
			else if ([name isEqualToString:@"desktopheight"]) 
				screenHeight = numVal;
			else if ([name isEqualToString:@"session bpp"]) 
				screenDepth = numVal;
			else if ([name isEqualToString:@"username"])
				username = [value retain];
			else if ([name isEqualToString:@"cord save password"]) 
				savePassword = numVal;
			else if ([name isEqualToString:@"domain"])
				domain = [value retain];
			else if ([name isEqualToString:@"startdisplay"])
				startDisplay = numVal;
			else if ([name isEqualToString:@"cord label"])
				label = [value retain];			
			else if ([name isEqualToString:@"full address"]) {
				split_hostname(value, &hostName, &port);
				[hostName retain];
			}
			else
			{
				if ([type isEqualToString:@"i"])
					[otherAttributes setObject:[NSNumber numberWithInt:numVal] forKey:name];
				else
					[otherAttributes setObject:value forKey:name];				
			}
		}		
	}
		
	modified = NO;
	[self setTemporary:NO];
	
	if (savePassword)
	{
		const char *pass = keychain_get_password([hostName UTF8String], [username UTF8String]);
		if (pass != NULL)
		{
			password = [[NSString stringWithUTF8String:pass] retain];
			free((void*)pass);
		}
	}
	
	[self updateCellData];
	
	return YES;
}

// Saves all of the current settings to a Microsoft RDC client compatible file
- (BOOL) writeRDPFile:(NSString *)path
{
	if (path == nil && (path = [self rdpFilename]) == nil)
		return nil;

	#define write_int(n, v)	 [o appendString:[NSString stringWithFormat:@"%@:i:%d\r\n", (n), (v)]]
	#define write_string(n, v) [o appendString:[NSString stringWithFormat:@"%@:s:%@\r\n", (n), (v) ? (v) : @""]]
	
	NSMutableString *o = [[NSMutableString alloc] init];
	
	write_int(@"connect to console", cacheBitmaps);
	write_int(@"bitmapcachepersistenable", cacheBitmaps);
	write_int(@"redirectdrives", forwardDisks);
	write_int(@"disable wallpaper", drawDesktop);
	write_int(@"disable full window drag", windowDrags);
	write_int(@"disable menu anims", windowAnimation);
	write_int(@"disable themes", themes);
	write_int(@"audiomode", forwardAudio);
	write_int(@"desktopwidth", screenWidth);
	write_int(@"desktopheight", screenHeight);
	write_int(@"session bpp", screenDepth);
	write_int(@"cord save password", savePassword);
	write_int(@"startdisplay", startDisplay);
	
	
	write_string(@"full address", full_host_name(hostName, port));
	write_string(@"username", username);
	write_string(@"domain", domain);
	write_string(@"cord label", label);
	
	// Write all entries in otherAttributes
	NSString *type;
	NSEnumerator *enumerator = [otherAttributes keyEnumerator];
	id key, value;
	while ( (key = [enumerator nextObject]) && (value = [otherAttributes valueForKey:key]) )
	{
		if ([value isKindOfClass:[NSNumber class]])
			write_int(key, [value intValue]);
		else
			write_string(key, value);	
	}
	
	BOOL success = [o writeToFile:path atomically:YES encoding:NSASCIIStringEncoding error:NULL];
	
	if (!success)
		NSLog(@"Error writing to '%@'", path);
	
	[o release];
	#undef write_int(n, v)
	#undef write_string(n, v)
	
	modified = NO;
	
	return success;
}

// Updates the CRDServerCell this instance manages to match the current details.
- (void)updateCellData
{
	// Update the text
	NSString *fullHost = (port && port != DEFAULT_PORT) ? [NSString stringWithFormat:@"%@:%d", hostName, port] : hostName;
	[cellRepresentation setDisplayedText:label username:username address:fullHost];
	
	// Update the image
	NSImage *base = [AppController sharedDocumentIcon];
	NSImage *icon = [[[NSImage alloc] initWithSize:NSMakeSize(CELL_IMAGE_WIDTH, CELL_IMAGE_HEIGHT)] autorelease];

	[icon lockFocus]; {
		[[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
		[base drawInRect:RECT_FROM_SIZE([icon size]) fromRect:RECT_FROM_SIZE([base size]) operation:NSCompositeSourceOver fraction:1.0];	
	} [icon unlockFocus];
	
	
	// If this is temporary, badge the lower right corner of the image
	if ([self temporary])
	{
		[icon lockFocus]; {
		
			NSImage *clockIcon = [NSImage imageNamed:@"Clock icon.png"];
			NSSize clockSize = [clockIcon size], iconSize = [icon size];
			NSRect src = NSMakeRect(0.0, 0.0, clockSize.width, clockSize.height);
			NSRect dest = NSMakeRect(iconSize.width - clockSize.width - 1.0, iconSize.height - clockSize.height, clockSize.width, clockSize.height);
			[clockIcon drawInRect:dest fromRect:src operation:NSCompositeSourceOver fraction:0.9];
			
		} [icon unlockFocus];
	}
	
	[cellRepresentation setImage:icon];
			
}

// Called right before modifying any data that effects the keychain
- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword
{
	[self updateKeychainData:newHost user:newUser password:newPassword force:NO];
}

// Force flag makes it save data to keychain regardless if it has changed. savePassword 
//	is still respected.
- (void)updateKeychainData:(NSString *)newHost user:(NSString *)newUser password:(NSString *)newPassword force:(BOOL)force
{
	if (savePassword && (force || ![hostName isEqualToString:newHost] || 
		![username isEqualToString:newUser] || ![password isEqualToString:newPassword]) )
	{
		keychain_update_password([hostName UTF8String], [username UTF8String],
				[newHost UTF8String], [newUser UTF8String], [newPassword UTF8String]);
	}
}

- (void)clearKeychainData
{
	keychain_clear_password([hostName UTF8String], [username UTF8String]);
}


#pragma mark -
#pragma mark Accessors
- (rdcConnection)conn
{
	return &conn;
}

- (NSString *)label
{
	return label;
}

- (RDCView *)view
{
	return view;
}

- (NSString *)rdpFilename
{
	return rdpFilename;
}

- (void)setRdpFilename:(NSString *)path
{
	[path retain];
	[rdpFilename release];
	rdpFilename = path;
}

- (BOOL)temporary
{
	return temporary;
}

- (void)setTemporary:(BOOL)temp
{
	temporary = temp;
	[self updateCellData];
}

- (CRDServerCell *)cellRepresentation
{
	return cellRepresentation;
}

- (NSTabViewItem *)tabViewRepresentation
{
	return tabViewRepresentation;
}

- (BOOL)modified
{
	return modified;
}

- (CRDConnectionStatus)status
{
	return connectionStatus;
}

- (void)setStatus:(CRDConnectionStatus)status
{
	[cellRepresentation setStatus:status];
	connectionStatus = status;
}

// Status needs to be set on the main thread when setting it to Connecting
//	so the the CRDServerCell will create its progressbar timer in the main run loop
- (void)setStatusAsNumber:(NSNumber *)status
{
	[self setStatus:[status intValue]];
}


/* Do a few simple setters that would otherwise be caught by key-value coding so that
	updateCellData can be called and keychain data can be updated. Keychain data
	must be done here and not at save time because the keychain item might already 
	exist so it has to be edited.
*/
- (void)setLabel:(NSString *)s
{
	[label autorelease];
	label = [s retain];
	[self updateCellData];
}

- (void)setHostName:(NSString *)s
{
	[self updateKeychainData:s user:username password:password];
	[hostName autorelease];
	hostName = [s retain];
	[self updateCellData];
}

- (void)setUsername:(NSString *)s
{
	[username autorelease];
	username = [s retain];
	[self updateCellData];
}

- (void)setPassword:(NSString *)pass
{
	[self updateKeychainData:hostName user:username password:pass];
	[password autorelease];
	password = [pass retain];
}

- (void)setPort:(int)newPort
{
	port = newPort;
	[self updateCellData];
}

- (void)setSavePassword:(BOOL)saves
{
	savePassword = saves;
	
	if (!savePassword)	
		[self clearKeychainData];
	else
		[self updateKeychainData:hostName user:username password:password force:YES];
}

@end


