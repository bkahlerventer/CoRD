/*	Copyright (c) 2007-2008 Dorian Johnson <info-2008@dorianjohnson.com>
	
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

#import "CRDShared.h"

@class CRDFullScreenWindow;
@class CRDLabelCell;
@class CRDServerList;
@class CRDSession;
@class CRDTabView;

@interface AppController : NSObject
{
	// Inspector
	IBOutlet NSWindow *gui_inspector;
	IBOutlet NSTextField *gui_label, *gui_host, *gui_username, *gui_password, *gui_domain;
    IBOutlet NSButton *gui_savePassword, *gui_consoleSession, *gui_forwardDisks, *gui_forwardPrinters, *gui_displayDragging, *gui_drawDesktop, *gui_enableAnimations, *gui_enableThemes;

    IBOutlet NSPopUpButton *gui_screenResolution, *gui_colorCount;
	IBOutlet NSBox *gui_performanceOptions;
    CRDSession *inspectedServer;
	
	// Drawer
	IBOutlet NSDrawer *gui_serversDrawer;
	IBOutlet CRDServerList *gui_serverList;
	IBOutlet NSButton *gui_connectButton, *gui_inspectorButton, *gui_addNewButton;
	CRDLabelCell *connectedServersLabel;
	CRDLabelCell *savedServersLabel;
	
	// Unified window
	IBOutlet NSWindow *gui_unifiedWindow;
	IBOutlet NSComboBox *gui_quickConnect;
	IBOutlet CRDTabView *gui_tabView;
	NSToolbar *gui_toolbar;
	NSMutableDictionary *toolbarItems;

	// Other display modes
	CRDFullScreenWindow *gui_fullScreenWindow;
	CRDDisplayMode displayMode, displayModeBeforeFullscreen;
	NSPoint windowCascadePoint;
	IBOutlet NSUserDefaultsController *userDefaultsController;
	NSUserDefaults *userDefaults;
	CRDSession *instanceReconnectingForFullscreen;
	
	// Menu
	IBOutlet NSMenu *gui_serversMenu;
	
	// Active sessions and disconnected saved servers
	NSMutableArray *connectedServers, *savedServers;
	
	// Support for server dragging
	CRDSession *dumpedInstance;
	BOOL dumpedInstanceWasSelected;
	
	BOOL isTerminating, useMinimalServersList;
}

// Actions
- (IBAction)addNewSavedServer:(id)sender;
- (IBAction)removeSelectedSavedServer:(id)sender;
- (IBAction)connect:(id)sender;
- (IBAction)disconnect:(id)sender;
- (IBAction)performConnectOrDisconnect:(id)sender;
- (IBAction)keepSelectedServer:(id)sender;
- (IBAction)toggleInspector:(id)sender;
- (IBAction)togglePerformanceDisclosure:(id)sender;
- (IBAction)fieldEdited:(id)sender;
- (IBAction)selectNext:(id)sender;
- (IBAction)selectPrevious:(id)sender;
- (IBAction)performStop:(id)sender;
- (IBAction)stopConnection:(id)sender;
- (IBAction)showOpen:(id)sender;
- (IBAction)toggleDrawer:(id)sender;
- (IBAction)startFullscreen:(id)sender;
- (IBAction)endFullscreen:(id)sender;
- (IBAction)performFullScreen:(id)sender;
- (IBAction)performUnified:(id)sender;
- (IBAction)startWindowed:(id)sender;
- (IBAction)startUnified:(id)sender;
- (IBAction)takeScreenCapture:(id)sender;
- (IBAction)performQuickConnect:(id)sender;
- (IBAction)helpForConnectionOptions:(id)sender;
- (IBAction)performServerMenuItem:(id)sender;
- (IBAction)performDisconnect:(id)sender;
- (IBAction)saveSelectedServer:(id)sender;
- (IBAction)sortSavedServersAlphabetically:(id)sender;
- (IBAction)doNothing:(id)sender;
- (IBAction)duplicateSelectedServer:(id)sender;

// Other methods are in no particular order
- (void)cellNeedsDisplay:(NSCell *)cell;

- (void)connectInstance:(CRDSession *)inst;
- (void)disconnectInstance:(CRDSession *)inst;
- (void)cancelConnectingInstance:(CRDSession *)inst;

- (CRDSession *)serverInstanceForRow:(int)row;
- (CRDSession *)selectedServer; // different than below?
//- (CRDSession *)selectedServerInstance;
- (CRDSession *)viewedServer;

- (BOOL)mainWindowIsFocused;
- (CRDDisplayMode)displayMode;
- (NSWindow *)unifiedWindow;
- (CRDFullScreenWindow *)fullScreenWindow;

- (void)holdSavedServer:(int)row;
- (void)reinsertHeldSavedServer:(int)intoRow;



@end

@interface AppController (SharedResources)
+ (NSImage *)sharedDocumentIcon;
+ (NSString *)savedServersPath;
@end




