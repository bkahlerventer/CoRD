//  Copyright (c) 2007 Dorian Johnson <arcadiclife@gmail.com>, Craig Dooley <xlnxminusx@gmail.com>
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


#import "AppController.h"
#import "RDInstance.h"
#import "CRDServerList.h"
#import "miscellany.h"

static NSImage *shared_documentIcon = nil;

#define TOOLBAR_DISCONNECT	@"Disconnect"
#define TOOLBAR_DRAWER @"Servers"

@interface AppController (Private)
	- (void)listUpdated;
	- (void)validateControls;
	- (void)saveInspectedServer;
	- (void)updateInstToMatchInspector:(RDInstance *)inst;
	- (void)setInspectorSettings:(RDInstance *)newSettings;
	- (void)addServer:(RDInstance *)inst;
	- (void)connectInstance:(RDInstance *)inst;
	- (void)completeConnection:(RDInstance *)inst;
	- (void)connectAsync:(RDInstance *)inst;
	- (void)resizeToMatchSelection;
@end


#pragma mark -
@implementation AppController

#pragma mark NSObject methods
- (id)init
{
	if (![super init])
		return nil;
		
	userDefaults = [[NSUserDefaults standardUserDefaults] retain];
	
	connectedServers = [[NSMutableArray alloc] init];
	savedServers = [[NSMutableArray alloc] init];
	
	connectedServersLabel = [[CRDLabelCell alloc] initTextCell:@"Active sessions"];
	savedServersLabel = [[CRDLabelCell alloc] initTextCell:@"Saved Servers"];

	inspectedServer = nil;
	
	return self;
}
- (void) dealloc
{
	[resourcePath release];
	[serversDirectory release];
	
	[connectedServers release];
	[savedServers release];
	
	[connectedServersLabel release];
	[savedServersLabel release];
	
	[userDefaults release];
	[super dealloc];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	RDInstance *inst = [self selectedServerInstance];
	RDInstance *viewedInst = [self viewedServer];
	SEL action = [item action];
	
    if (action == @selector(removeSelectedSavedServer:))
		return (inst != nil) && ![inst temporary] && [inst status] == CRDConnectionClosed;
    else if (action == @selector(connect:))
        return (inst != nil) && [inst status] != CRDConnectionConnected;
    else if (action == @selector(disconnect:))
		return (inst != nil) && [inst status] != CRDConnectionClosed;
	else if (action == @selector(keepSelectedServer:))
		return (inst != nil) && [inst status] == CRDConnectionConnected;
	else if (action == @selector(selectNext:))
		return viewedInst != nil;
	else if (action == @selector(selectPrevious:))
		return viewedInst != nil;
	else
		return YES;
}


- (void)awakeFromNib
{
	[gui_mainWindow setAcceptsMouseMovedEvents:YES];
	
	// Create the toolbar 
	toolbarItems = [[NSMutableDictionary alloc] init];
	
	[toolbarItems 
		setObject:create_static_toolbar_item(TOOLBAR_DRAWER,
			@"Hide or show the servers drawer", @selector(toggleDrawer:))
		forKey:TOOLBAR_DRAWER];
	[toolbarItems 
		setObject:create_static_toolbar_item(TOOLBAR_DISCONNECT,
			@"Close the selected connection", @selector(disconnect:))
		forKey:TOOLBAR_DISCONNECT];	
	
	gui_toolbar = [[NSToolbar alloc] initWithIdentifier:@"CoRDMainToolbar"];
	[gui_toolbar setDelegate:self];
	
	[gui_toolbar setAllowsUserCustomization:YES];
	[gui_toolbar setAutosavesConfiguration:YES];
	
	[gui_mainWindow setToolbar:gui_toolbar];
	
	g_appController = self;
	
	// Load files from the ~/Library/Application Support/CoRD/Servers dir
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	// Assure that the CoRD application support folder is created, locate and store other useful paths
	NSString *appSupport = 
		[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
			NSUserDomainMask, YES) objectAtIndex:0];
	NSString *cordDirectory = [[appSupport stringByAppendingPathComponent:@"CoRD"] retain];
	serversDirectory = [[cordDirectory stringByAppendingPathComponent:@"Servers"] retain];
	resourcePath = [[NSBundle mainBundle] resourcePath];
	
	ensure_directory_exists(cordDirectory, fileManager);
	ensure_directory_exists(serversDirectory, fileManager);

	// Get a list of files from the Servers directory, load each
	RDInstance *rdpinfo;
	NSString *path;
	NSArray *files = [fileManager directoryContentsAtPath:serversDirectory];
	NSEnumerator *enumerator = [files objectEnumerator];
	id filename;
	while ( (filename = [enumerator nextObject]) )
	{
		if ([[filename pathExtension] isEqualToString:@"rdp"])
		{
			path = [serversDirectory stringByAppendingPathComponent:filename];
			rdpinfo = [[RDInstance alloc] initWithRDPFile:path];
			if (rdpinfo != nil)
				[savedServers addObject:rdpinfo];
			else
				NSLog(@"RDP file '%@' failed to load!", filename);
				
			[rdpinfo release];
		}
	}

	// todo:dragndrop Register for all the types of drag operations
	//[gui_serverList setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
	//[gui_serverList setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
	//[gui_serverList registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
	
	// Remove the next line to have a header
	[gui_serverList setHeaderView:nil];
	
	// Since it's a custom class, the attributes pane isn't available for
	//	the password entry box. Set it up here.
	[[gui_password cell] setSendsActionOnEndEditing:YES];
	[[gui_password cell] setFont:[NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSSmallControlSize]]];


	[self validateControls];
	[self listUpdated];
}


#pragma mark -
#pragma mark Actions

- (IBAction)addNewSavedServer:(id)sender
{
	RDInstance *inst = [[[RDInstance alloc] init] autorelease];
	
	NSString *path = increment_file_name(serversDirectory, @"New Server", @".rdp");
		
	[inst setTemporary:NO];
	[inst setRdpFilename:path];
	[inst setLabel:[[path lastPathComponent] stringByDeletingPathExtension]];
	[inst writeRDPFile:nil];
	
	[savedServers addObject:inst];

	[self listUpdated];
	
	NSIndexSet *index = [NSIndexSet indexSetWithIndex:2 + [savedServers indexOfObjectIdenticalTo:inst]];
	[gui_serverList selectRowIndexes:index byExtendingSelection:NO];
}


/* Removes the currently selected server, and deletes the file.
	todo: allow this to work with connected servers
*/
- (IBAction)removeSelectedSavedServer:(id)sender
{
	RDInstance *inst = [self selectedServerInstance];
	
	if (inst == nil || [inst temporary] || [inst status] != CRDConnectionClosed)
		return;
	
	NSString *msg = [NSString stringWithFormat:@"Are you sure you wish to delete the saved server '%@'?", [inst label]];
	int ret = NSRunAlertPanel(@"Delete saved server", msg, @"Delete", @"Cancel", nil);
	
	if (ret == NSAlertAlternateReturn)
		return;
		
	[gui_serverList deselectAll:self];
	
	// Remove the server from the list, delete its backing file
	[[NSFileManager defaultManager] removeFileAtPath:[inst rdpFilename] handler:nil];
	[savedServers removeObject:inst];
	
	[self listUpdated];
}

// Connects to the currently selected saved server
- (IBAction)connect:(id)sender
{
	RDInstance *inst = [self selectedServerInstance];
	
	if (inst == nil)
		return;
		
	[self connectInstance:inst];
}

// Toggles whether or not the selected server is kept after disconnect
- (IBAction)keepSelectedServer:(id)sender
{
	RDInstance *inst = [self selectedServerInstance];
	if (inst == nil)
		return;
	
	[inst setTemporary:![inst temporary]];
	[self validateControls];
	[self listUpdated];
}

// Disconnects the currently selected active server
- (IBAction)disconnect:(id)sender
{
	RDInstance *inst = [self viewedServer];
	
	[self disconnectInstance:inst];

}


/* Hides or shows the inspector. */
- (IBAction)toggleInspector:(id)sender
{
	BOOL nowVisible = ![gui_inspector isVisible];
	if (nowVisible)
		[gui_inspector makeKeyAndOrderFront:sender];
	else
		[gui_inspector close];	
		
	[self validateControls];
}


/* Hides/shows the Performance Options. Called by the disclosure triangle. */
- (IBAction)togglePerformanceDisclosure:(id)sender
{
	BOOL nowVisible = ([sender state] != NSOffState);
	
	NSRect boxFrame = [gui_performanceOptions frame], windowFrame = [gui_inspector frame];
	
	if (nowVisible) {
		windowFrame.size.height += boxFrame.size.height;	
		windowFrame.origin.y	-= boxFrame.size.height;
	} else {
		windowFrame.size.height -= boxFrame.size.height;
		windowFrame.origin.y	+= boxFrame.size.height;
	}
	
	[gui_performanceOptions setHidden:!nowVisible];
	
	NSSize minSize = [gui_inspector minSize];
	[gui_inspector setMinSize:NSMakeSize(minSize.width, windowFrame.size.height)];
	[gui_inspector setMaxSize:NSMakeSize(FLT_MAX, windowFrame.size.height)];
	[gui_inspector setFrame:windowFrame display:YES animate:YES];

}


/* Called whenever anything in the inspector is edited */
- (IBAction)fieldEdited:(id)sender
{			
	if (inspectedServer != nil)
	{
		[self updateInstToMatchInspector:inspectedServer];
		[self listUpdated];
	}
}

- (IBAction)selectNext:(id)sender
{
	[gui_tabView selectNextTabViewItem:sender];
	
	RDInstance *inst = [self viewedServer];
	if (inst == nil)
		return;
		
	[gui_serverList selectRow:(1 + [connectedServers indexOfObjectIdenticalTo:inst])];
}

- (IBAction)selectPrevious:(id)sender
{
	[gui_tabView selectPreviousTabViewItem:sender];
	
	RDInstance *inst = [self viewedServer];
	if (inst == nil)
		return;
		
	[gui_serverList selectRow:(1 + [connectedServers indexOfObjectIdenticalTo:inst])];
}

- (IBAction)showOpen:(id)sender
{
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setAllowsMultipleSelection:YES];
	[panel runModalForTypes:[NSArray arrayWithObject:@"rdp"]];
	NSArray *filenames = [panel filenames];
	if ([filenames count] <= 0) return;
	
	[self application:[NSApplication sharedApplication] openFiles:filenames];
}

- (IBAction)toggleDrawer:(id)sender
{
	[self toggleDrawer:sender visible:!drawer_is_visisble(gui_serversDrawer)];
}


#pragma mark -
#pragma mark Toolbar methods

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar 
		itemForItemIdentifier:(NSString *)itemIdentifier 
		willBeInsertedIntoToolbar:(BOOL)flag
{	
	return [toolbarItems objectForKey:itemIdentifier];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)tb
{
		NSMutableArray *menuExtras = [NSMutableArray arrayWithObjects:
				NSToolbarSeparatorItemIdentifier,
				NSToolbarSpaceItemIdentifier,
				NSToolbarFlexibleSpaceItemIdentifier, nil];
		[menuExtras addObjectsFromArray:[toolbarItems allKeys]];
		return menuExtras;
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)tb
{

	NSMutableArray *defaultItems = [NSArray arrayWithObjects:
				TOOLBAR_DRAWER,
				NSToolbarFlexibleSpaceItemIdentifier,
				TOOLBAR_DISCONNECT,
				nil];
	return defaultItems;
}

-(BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem
{
	NSString *itemId = [toolbarItem itemIdentifier];
	
	RDInstance *inst = [self selectedServerInstance];
	RDInstance *viewedInst = [self viewedServer];
	
	if ([itemId isEqualToString:TOOLBAR_DRAWER])
		[toolbarItem setLabel:(drawer_is_visisble(gui_serversDrawer) ? @"Hide Servers" : @"Show Servers")];
	else if ([itemId isEqualToString:TOOLBAR_DISCONNECT])
		return viewedInst != nil;
	
	return YES;
}


#pragma mark -
#pragma mark NSApplication delegate methods

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
	[self application:sender openFiles:[NSArray arrayWithObject:filename]];
	return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
	NSEnumerator *enumerator = [filenames objectEnumerator];
	id file;
	while ( (file = [enumerator nextObject]) )
	{
		RDInstance *inst = [[RDInstance alloc] initWithRDPFile:file];
		
		if (inst != nil)
		{
			[inst setTemporary:YES];
			[connectedServers addObject:inst];
			[self listUpdated];
			[self connectInstance:inst];	
		}
	}
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)theApplication
{
    return NO;
}


- (void)applicationWillTerminate:(NSNotification *)aNotification
{
	[self tableViewSelectionDidChange:nil];
	
	// Save drawer state to user defaults
	[userDefaults setBool:drawer_is_visisble(gui_serversDrawer) forKey:DEFAULTS_SHOW_DRAWER];
	[userDefaults setFloat:[gui_serversDrawer contentSize].width forKey:DEFAULTS_DRAWER_WIDTH];

}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{	
	// Make sure the drawer is in the user-saved position
	if ([userDefaults objectForKey:DEFAULTS_SHOW_DRAWER] != nil)
	{		
		float width = [userDefaults floatForKey:DEFAULTS_DRAWER_WIDTH];
		float height = [gui_serversDrawer contentSize].height;
		if (width > 0)
			[gui_serversDrawer setContentSize:NSMakeSize(width, height)];
			
		if ([userDefaults boolForKey:DEFAULTS_SHOW_DRAWER])
			[self toggleDrawer:self visible:YES];
	}
	else
	{
		[self toggleDrawer:self visible:YES];
	}
}


#pragma mark -
#pragma mark NSTableDataSource methods

- (int)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return 2 + [connectedServers count] + [savedServers count];
}

- (id)tableView:(NSTableView *)aTableView
		objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	if (rowIndex == 0)
		return [connectedServersLabel attributedStringValue];
	else if (rowIndex == [connectedServers count] + 1)
		return [savedServersLabel attributedStringValue];
	else
		return @"Filler";//[[self serverInstanceForRow:rowIndex] cellTextualData];	
}

/* Drag and drop methods */

- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id <NSDraggingInfo>)info
		proposedRow:(int)row proposedDropOperation:(NSTableViewDropOperation)op
{
	UNIMPL;
	/* todo:dragndrop - rewrite
	if ([info draggingSource] == (id)gui_serverList)
	{
		// inner list drag, currently ignoring. Todo: allow for item moving
		return NSDragOperationNone;
	} 
	else
	{
		// external drag, make sure there's at least one RDP file in there
		NSArray *files = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		NSArray *rdpFiles = filter_filenames(files, [NSArray arrayWithObjects:@"rdp",nil]);
		return ([rdpFiles count] > 0) ? NSDragOperationCopy : NSDragOperationNone;
	}*/
	return nil;
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info
		row:(int)row dropOperation:(NSTableViewDropOperation)operation
{
	UNIMPL;
	/* todo:dragndrop - rewrite 
	if ([info draggingSource] == (id)gui_serverList)
	{
		// inner list drag, currently ignoring. Todo: allow for item moving
		return NO;
	} 
	else
	{
		// external drag, load all rdp files passed
		NSArray *files = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		NSArray *rdpFiles = filter_filenames(files, [NSArray arrayWithObjects:@"rdp",nil]);
		NSEnumerator *enumerator = [rdpFiles objectEnumerator];
		id file;
		while ( (file = [enumerator nextObject]) )
		{
			[self addServer:[[[RDInstance alloc] initWithRDPFile:file] autorelease]];
		}
		
		return YES;
	}*/
	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes
		toPasteboard:(NSPasteboard*)pboard
{
	UNIMPL;
	/* todo:dragndrop - rewrite 
	NSMutableArray *filenames = [NSMutableArray arrayWithCapacity:5];
	NSEnumerator *e = [servers objectEnumerator];
	id rdp;
	unsigned i = 0;
	while ( (rdp = [e nextObject]) )
	{
		if ([rowIndexes containsIndex:i]) {
			[filenames addObject:[rdp filename]]; 	
		}
		i++;
	}
	[pboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
	[pboard setPropertyList:filenames forType:NSFilenamesPboardType];
	
	return YES;*/
	return NO;
}


#pragma mark NSTableView delegate

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	int selectedRow = [gui_serverList selectedRow];
	
	[self validateControls];
	[self fieldEdited:nil];
	
	// If there's no selection, clear the inspector
	if (selectedRow == -1)
	{
		[self setInspectorSettings:nil];	
		inspectedServer = nil;
		// todo: set all inspector controls to disabled
		
		return;
	} else {
		[inspectedServer writeRDPFile:nil];	
	}

	// todo: ensure inspector controls are enabled
	
	inspectedServer =  [self serverInstanceForRow:selectedRow];
	[self setInspectorSettings:inspectedServer];
	
	
	// If the new selection is connected, change the selected view
	if (selectedRow >= 1 && selectedRow <= [connectedServers count])
	{
		[gui_tabView selectTabViewItem:[inspectedServer tabViewRepresentation]];
		[self resizeToMatchSelection];
	}
	
	
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(int)rowIndex
{
	return (rowIndex >= 1) && (rowIndex != [connectedServers count] + 1);
}

- (float)tableView:(NSTableView *)tableView heightOfRow:(int)row
{	
	if (row == 0 || row == [connectedServers count] + 1)
		return [connectedServersLabel cellSize].height;
	else
		return [[[self serverInstanceForRow:row] cellRepresentation] cellSize].height;
}

- (id) tableColumn:(NSTableColumn *)column inTableView:(NSTableView *)tableView dataCellForRow:(int)row
{
	if (row == 0)
		return connectedServersLabel;
	else if (row == [connectedServers count] + 1)
		return savedServersLabel;
	else 
		return [[self serverInstanceForRow:row] cellRepresentation];
}

#pragma mark Other table view related
- (void)cellNeedsDisplay:(NSCell *)cell
{
	[gui_serverList setNeedsDisplay:YES];
}


#pragma mark -
#pragma mark Managing inspector settings

// Sets all of the values in the passed RDInstance to match the inspector
- (void)updateInstToMatchInspector:(RDInstance *)inst
{
	// Set all of the checkbox options
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_cacheBitmaps)		forKey:@"cacheBitmaps"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_displayDragging)	forKey:@"windowDrags"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_drawDesktop)		forKey:@"drawDesktop"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_enableAnimations)	forKey:@"windowAnimation"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_enableThemes)		forKey:@"themes"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_savePassword)		forKey:@"savePassword"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_forwardDisks)		forKey:@"forwardDisks"];
	[inst setValue:BUTTON_STATE_AS_NUMBER(gui_consoleSession)	forKey:@"consoleSession"];
	
	// Set the text fields
	[inst setValue:[gui_label stringValue] forKey:@"label"];
	[inst setValue:[gui_username stringValue] forKey:@"username"];
	[inst setValue:[gui_domain stringValue]	 forKey:@"domain"];	
	[inst setValue:[gui_password stringValue] forKey:@"password"];
	
	// Set host/port
	int port;
	NSString *s;
	split_hostname([gui_host stringValue], &s, &port);
	[inst setValue:[NSNumber numberWithInt:port] forKey:@"port"];
	[inst setValue:s forKey:@"hostName"];
	
	// Set screen depth
	[inst setValue:[NSNumber numberWithInt:([gui_colorCount indexOfSelectedItem]+1)*8]
			forKey:@"screenDepth"];
			
	// Get resolution.
	NSScanner *scanner = [NSScanner scannerWithString:[gui_screenResolution titleOfSelectedItem]];
	[scanner setCharactersToBeSkipped:[NSCharacterSet characterSetWithCharactersInString:@"x"]];
	int width, height;
	[scanner scanInt:&width]; [scanner scanInt:&height];
	[inst setValue:[NSNumber numberWithInt:width]  forKey:@"screenWidth"];
	[inst setValue:[NSNumber numberWithInt:height] forKey:@"screenHeight"];
	
}

/* Sets the inspector options to match an RDInstance */
- (void)setInspectorSettings:(RDInstance *)newSettings
{
	if (newSettings == nil)
		newSettings = [[[RDInstance alloc] init] autorelease];
		
	// Set the checkboxes 
	[gui_cacheBitmaps		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"cacheBitmaps"])];
	[gui_displayDragging	setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"windowDrags"])];
	[gui_drawDesktop		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"drawDesktop"])];
	[gui_enableAnimations	setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"windowAnimation"])];
	[gui_enableThemes		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"themes"])];
	[gui_savePassword		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"savePassword"])];
	[gui_forwardDisks		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"forwardDisks"])];
	[gui_consoleSession		setState:NUMBER_AS_BSTATE([newSettings valueForKey:@"consoleSession"])];
	
	// Set some of the textfield inputs
	[gui_label    setStringValue:[newSettings valueForKey:@"label"]];
	[gui_username setStringValue:[newSettings valueForKey:@"username"]];
	[gui_domain   setStringValue:[newSettings valueForKey:@"domain"]];
	[gui_password setStringValue:[newSettings valueForKey:@"password"]];
	
	// Set host
	int port = [[newSettings valueForKey:@"port"] intValue];
	NSString *host = [newSettings valueForKey:@"hostName"];
	
	[gui_host setStringValue:full_host_name(host, port)];
	
	// Set the color depth
	int colorDepth = [[newSettings valueForKey:@"screenDepth"] intValue];
	[gui_colorCount selectItemAtIndex:(colorDepth/8-1)];
	
	// Set the resolution
	int screenWidth = [[newSettings valueForKey:@"screenWidth"] intValue];
	int screenHeight = [[newSettings valueForKey:@"screenHeight"] intValue]; 
	if (screenWidth == 0 || screenHeight == 0) {
		screenWidth = 1024;
		screenHeight = 768;
	}
	
	NSString *resolutionLabel = [NSString stringWithFormat:@"%dx%d", screenWidth, screenHeight];
	// If this resolution doesn't exist in the pop-up box, create it. Either way, select it.
	if ([gui_screenResolution itemWithTitle:resolutionLabel] == nil)
		[gui_screenResolution addItemWithTitle:resolutionLabel];
	[gui_screenResolution selectItemWithTitle:resolutionLabel];
}


- (void) saveInspectedServer
{
	if ([inspectedServer modified])
		[inspectedServer writeRDPFile:nil];
}


#pragma mark -
#pragma mark NSWindow delegate

- (BOOL)windowShouldClose:(id)sender
{
	if (sender == gui_mainWindow)
	{
		[[NSApplication sharedApplication] hide:self];
		return NO;
	}
	
	return YES;
}

- (void)windowWillClose:(NSNotification *)sender
{
	if ([sender object] == gui_inspector)
	{
		[self fieldEdited:nil];
		[self saveInspectedServer];
		inspectedServer = nil;
		[self validateControls];
	}
}


#pragma mark -
#pragma mark Managing connected servers

// Starting point to connect to a instance. Threading is automatically handled.
- (void)connectInstance:(RDInstance *)inst
{
	if (inst == nil)
		return;
		
	[inst retain];
	[NSThread detachNewThreadSelector:@selector(connectAsync:) toTarget:self withObject:inst];
}

// Should only be called by connectInstance
- (void)connectAsync:(RDInstance *)inst
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	BOOL connected = [inst connect];
	
	[self performSelectorOnMainThread:@selector(completeConnection:)
			withObject:inst waitUntilDone:NO];
					
	if (connected)	
		[inst startInputRunLoop];

	[inst release];
	[pool release];
}

// Called from main thread in connectAsync
- (void)completeConnection:(RDInstance *)inst
{
	if ([inst status] == CRDConnectionConnected)
	{
		// Move it into the proper list
		if (![inst temporary])
		{
			[inst retain];
			[savedServers removeObject:inst];
			[connectedServers addObject:inst];
			[inst release];
		}
		
		NSIndexSet *index = [NSIndexSet indexSetWithIndex:1 + [connectedServers indexOfObject:inst]];
		[gui_serverList selectRowIndexes:index byExtendingSelection:NO];
		
		// Create the gui, add to window
		NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:[gui_tabView frame]] autorelease];
		[inst createGUI:scroll];
		[gui_tabView addTabViewItem:[inst tabViewRepresentation]];
		[gui_tabView selectLastTabViewItem:self];
		
		[gui_mainWindow makeFirstResponder:[inst view]];
		
		
		[self resizeToMatchSelection];
		[self listUpdated];
	}
	else
	{
		[self cellNeedsDisplay:(NSCell *)[inst cellRepresentation]];
		ConnectionErrorCode errorCode = [inst conn]->errorCode;
		
		if (errorCode != ConnectionErrorNone && errorCode != ConnectionErrorCanceled)
		{
			NSString *descs[] = {
					@"No error",
					@"The connection timed out.",
					@"The host name could not be resolved.",
					@"There was an error connecting.",
					@"You canceled the connection." };
			NSString *title = [NSString stringWithFormat:@"Couldn't connect to %@", [inst label]];
			
			NSAlert *alert = [NSAlert alertWithMessageText:title defaultButton:nil
						alternateButton:@"Retry" otherButton:nil informativeTextWithFormat:descs[errorCode]];
			[alert setAlertStyle:NSCriticalAlertStyle];
			
			// Retry if needed
			if ([alert runModal] == NSAlertAlternateReturn)
				[self performSelectorOnMainThread:@selector(connectInstance:) withObject:inst waitUntilDone:NO];
		}
	}
	
	
}

// Assures that the connected instance is disconnected and removed from view.
- (void)disconnectInstance:(RDInstance *)inst
{
	if (inst == nil || [connectedServers indexOfObjectIdenticalTo:inst] == NSNotFound)
		return;
		
	if ([inst tabViewRepresentation] != nil)
		[gui_tabView removeTabViewItem:[inst tabViewRepresentation]];
	
	if ([inst status] == CRDConnectionConnected)
		[inst disconnect];
		
	
	// If it's not temporary, move it to the saved servers list. Update the table view
	//	and selection as needed.
	[inst retain];
	[connectedServers removeObject:inst];
	
	if (![inst temporary])
	{
		[savedServers addObject:inst];
		NSIndexSet *index = [NSIndexSet indexSetWithIndex:(2 + [connectedServers count] + [savedServers indexOfObjectIdenticalTo:inst])];
		[gui_serverList selectRowIndexes:index byExtendingSelection:NO];
	} 
	else
	{
		// xxx: remove file (gracefully, though. It might not have started as a saved server)
		[gui_serverList deselectAll:self];
	}
	
	[inst release];

	[self listUpdated];
	[self resizeToMatchSelection];
}


#pragma mark -
#pragma mark Other methods

- (BOOL)mainWindowIsFocused
{
	return [gui_mainWindow isMainWindow] && [gui_mainWindow isKeyWindow];
}

- (void)toggleDrawer:(id)sender visible:(BOOL)visible
{
	NSString *newLabel = (visible) ? @"Hide Drawer" : @"Show Drawer";
	
	[gui_drawerToggleMenu setTitle:newLabel];
	
	if (visible)
		[gui_serversDrawer open];
	else
		[gui_serversDrawer close];
}

- (void)resizeToMatchSelection
{
	// todo: make this work with drawer
	
	RDInstance *inst = [self viewedServer];
	NSSize newContentSize = (inst != nil) ? [[inst view] frame].size : NSMakeSize(600, 450);


	NSRect windowFrame = [gui_mainWindow frame];
	NSRect screenRect = [[gui_mainWindow screen] visibleFrame];

	float scrollerWidth = [NSScroller scrollerWidth];
	float toolbarHeight = windowFrame.size.height - [[gui_mainWindow contentView] frame].size.height;
	
	// xxx: find a better way to do this so that unneccessary scrollbars are never seen even after manually resizing
	[gui_mainWindow setContentMaxSize:newContentSize];	
	
	NSRect newWindowFrame = NSMakeRect( windowFrame.origin.x, windowFrame.origin.y +
										windowFrame.size.height-newContentSize.height-toolbarHeight, 
										newContentSize.width, newContentSize.height + toolbarHeight);
	if (newWindowFrame.size.height > screenRect.size.height &&
		newWindowFrame.size.width + scrollerWidth <= screenRect.size.width)
	{
		newWindowFrame.origin.y = screenRect.origin.y;
		newWindowFrame.size.height = screenRect.size.height;
		newWindowFrame.size.width += scrollerWidth;

	} else if (newWindowFrame.size.width > screenRect.size.width &&
				newWindowFrame.size.height+scrollerWidth <= screenRect.size.height)
	{
		newWindowFrame.origin.x = screenRect.origin.x;
		newWindowFrame.size.width = screenRect.size.width;
		newWindowFrame.size.height += scrollerWidth;
	}
	
	// Try to make it not outside of the screen
	if (newWindowFrame.origin.y < screenRect.origin.y)
		newWindowFrame.origin.y = screenRect.origin.y;
	
	if (newWindowFrame.origin.x + newWindowFrame.size.width > screenRect.size.width)
		newWindowFrame.origin.x -= (newWindowFrame.origin.x + newWindowFrame.size.width) - (screenRect.origin.x + screenRect.size.width);
	
	[gui_mainWindow setContentMaxSize:newWindowFrame.size];
	[gui_mainWindow setFrame:newWindowFrame display:YES animate:YES];
}


#pragma mark -
#pragma mark Internal use
- (void) listUpdated
{	
	[gui_serverList reloadData];
	[gui_serverList setNeedsDisplay:YES];
}

- (RDInstance *)serverInstanceForRow:(int)row
{
	int connectedCount = [connectedServers count];
	int savedCount = [savedServers count];
	if ( (row <= 0) || (row == 1+connectedCount) || (row > 1 + connectedCount + savedCount) )
		return nil;
	else if (row <= connectedCount)
		return [connectedServers objectAtIndex:row-1];
	else 
		return [savedServers objectAtIndex:row - connectedCount - 2];
}

- (RDInstance *)selectedServerInstance
{
	return [self serverInstanceForRow:[gui_serverList selectedRow]];
}

// Returns the connected server that the tab view is displaying
- (RDInstance *)viewedServer
{
	NSTabViewItem *selectedItem = [gui_tabView selectedTabViewItem];

	if (selectedItem == nil)
		return nil;
		
	// Linear search the connectedServers array for this item
	NSEnumerator *enumerator = [connectedServers objectEnumerator];
	id item;
	
	while ( (item = [enumerator nextObject]) )
	{
		if ([item tabViewRepresentation] == selectedItem)
			return item;
	}
	
	return nil;
}

// Enables/disables gui controls as needed
- (void)validateControls
{
	[gui_inspectorToggleMenu setTitle:([gui_inspector isVisible] ? @"Hide Inspector" : @"Show Inspector")];
	[gui_inspectorToggleMenu setEnabled:[gui_serverList selectedRow] == -1];
	
	RDInstance *inst = [self serverInstanceForRow:[gui_serverList selectedRow]];
	
	[gui_connectButton setEnabled:(inst != nil && [inst status] != CRDConnectionConnected)];
	[gui_inspectorButton setEnabled:(inst != nil)];
	
	[gui_keepServerMenu setState:([inst temporary] ? NSOffState : NSOnState)];
	[[[NSApplication sharedApplication] menu] update];
}


#pragma mark -
#pragma mark Application-wide resources
+ (NSImage *)sharedDocumentIcon
{
	if (shared_documentIcon == nil)
	{
		// The stored icon is loaded as flipped for whatever reason, so flip it back
		// xxx: maybe use nscopybits?
		NSImage *icon = [NSImage imageNamed:@"rdp document.icns"];
		shared_documentIcon = [[NSImage alloc] initWithSize:[icon size]];
		[icon setFlipped:YES];
		[shared_documentIcon lockFocus];
		
		NSRect r = NSMakeRect(0.0,0.0, [icon size].width, [icon size].height);
		[icon drawInRect:r fromRect:r operation:NSCompositeSourceOver fraction:1.0];
		
		[shared_documentIcon unlockFocus];
		
	}
	
	return shared_documentIcon;
}


@end
