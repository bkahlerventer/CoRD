/*	Copyright (c) 2010 Nick Peelman <nick@peelman.us>
	
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

#import <Cocoa/Cocoa.h>
#import "CRDFileHandler.h"


@implementation CRDFileHandler

+ (NSString *)readFileAtURL:(NSURL *)url
{
	if (![url isFileURL] || ![[NSFileManager defaultManager] isReadableFileAtPath:[url path]])
		return NO;

	NSString *fileContents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
		
	NSArray *fileLines = [fileContents componentsSeparatedByString:@"\r\n"];

	if (fileLines == nil)
	{
		NSLog(@"Couldn't open RDP file '%@'!", [url path]);
		return @"Error opening file";
	}
		
	NSScanner *scan;
	NSCharacterSet *colonSet = [NSCharacterSet characterSetWithCharactersInString:@":"],
				   *emptySet = [NSCharacterSet characterSetWithCharactersInString:@""];
				   
	NSMutableDictionary *dictionary = [[[NSMutableDictionary alloc] initWithCapacity:1] autorelease];
	
	NSString *name, *type, *value;
	BOOL b;
	
	id line;
	for ( line in fileLines )
	{
		scan = [NSScanner scannerWithString:line];
		[scan setCharactersToBeSkipped:colonSet];
		
		b = YES;
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&name];
		b &= [scan scanUpToCharactersFromSet:colonSet intoString:&type];
		
		if (![scan scanUpToCharactersFromSet:emptySet intoString:&value])
			value = @"";
		
		if (!b)
			continue;
			
		[dictionary setObject:value forKey:name];
	}	
	
	NSString *rtn = [NSString stringWithFormat:@"<html>\
	<head>\
		<style type=\"text/css\">\
			body {background: #040404;color: #fff;padding: 2em 0;font-size: 10.5pt; font-family:Helvetica;}\
			h1 { background-repeat:no-repeat; font-size: 14pt; padding: 0.6em 0 0.3em; margin-top: 1em; text-shadow: rgba(0,0,0,0.95) 1px 2px 3px; }\
			p {color:blue;}\
		</style>\
	</head>\
	<body>\
	<div id=\"header\"><img src=\"CoRD.png\" /></div>\
		<h1 id=\"label\"><strong>Label:</strong> %@</h1>\
		<span id=\"hostname\"><strong>Hostname:</strong> %@</span><br/>\
		<span id=\"username\"><strong>Username:</strong> %@</span><br/>\
		<span id=\"domain\"><strong>Domain:</strong> %@</span><br/>\
		<span id=\"resolution\"><strong>Resolution:</strong> %@x%@</span><br/>\
	</body>\
					 </html>", [dictionary objectForKey:@"cord label"], [dictionary objectForKey:@"full address"], [dictionary objectForKey:@"username"], [dictionary objectForKey:@"domain"], [dictionary objectForKey:@"desktopwidth"],[dictionary objectForKey:@"desktopheight"]];
	return rtn;
}

@end
