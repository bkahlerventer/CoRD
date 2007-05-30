/*
   rdesktop: A Remote Desktop Protocol client.
   Common data types
   Copyright (C) Matthew Chapman 1999-2005
   
   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.
   
   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

@class CRDBitmap;
@class CRDSession;
@class CRDSessionView;
@class CRDSessionDeviceManager;


typedef int RDBOOL;

#ifndef True
#define True  (1)
#define False (0)
#endif

typedef unsigned char uint8;
typedef signed char sint8;
typedef unsigned short uint16;
typedef signed short sint16;
typedef unsigned int uint32;
typedef signed int sint32;
typedef unsigned long long uint64; 
typedef signed long long sint64; 

typedef CRDBitmap * RDBitmapRef;
typedef CRDBitmap * RDGlyphRef;
typedef unsigned int * RDColorMapRef;
typedef CRDBitmap * RDCursorRef;

typedef struct RDConnection * RDConnectionRef;

typedef struct _RDPoint
{
	sint16 x, y;
} RDPoint;

typedef struct _RDColorEntry
{
	uint8 red;
	uint8 green;
	uint8 blue;
} RDColorEntry;

typedef struct _RDColorMap
{
	uint16 ncolours;
	RDColorEntry *colours;
} RDColorMap;

typedef struct _RDBounds
{
	sint16 left;
	sint16 top;
	sint16 right;
	sint16 bottom;
} RDBounds;

typedef struct _RDPen
{
	uint8 style;
	uint8 width;
	uint32 colour;
} RDPen;

typedef struct _RDBrush
{
	uint8 xorigin;
	uint8 yorigin;
	uint8 style;
	uint8 pattern[8];
} RDBrush;

typedef struct _RDFontGlyph
{
	sint16 offset;
	sint16 baseline;
	uint16 width;
	uint16 height;
	RDBitmapRef pixmap;
} RDFontGlyph;

typedef struct _RDDataBlob
{
	void *data;
	int size;
} RDDataBlob;



typedef struct _RDVirtualChannel
{
	uint16 mcs_id;
	char name[8];
	uint32 flags;
	RDStream input;
	void (*process) (RDConnectionRef, RDStreamRef);
} RDVirtualChannel;

typedef struct _RDComp
{
	uint32 roff;
	uint8 hist[RDP_MPPC_DICT_SIZE];
	RDStream ns;
} RDComp;

/* RDPDR */
typedef uint32 NTStatus;
typedef uint32 NTHandle;

/* PSTCACHE */
typedef uint8 RDHashKey[8];

/* Header for an entry in the persistent bitmap cache file */
typedef struct RDPersistentCacheCellHeader
{
	RDHashKey key;
	uint8 width, height;
	uint16 length;
	uint32 stamp;
} RDPersistentCacheCellHeader;

#define MAX_CBSIZE 256

/* RDPSND */
typedef struct
{
	uint16 wFormatTag;
	uint16 nChannels;
	uint32 nSamplesPerSec;
	uint32 nAvgBytesPerSec;
	uint16 nBlockAlign;
	uint16 wBitsPerSample;
	uint16 cbSize;
	uint8 cb[MAX_CBSIZE];
} RDWaveFormat;

typedef struct _RDRedirectedDevice
{
	uint32 device_type;
	NTHandle handle;
	char name[8];
	char *local_path;
	void *pdevice_data;
} RDRedirectedDevice;

typedef struct _RDSerialDevice
{
	int dtr;
	int rts;
	uint32 control, xonoff, onlimit, offlimit;
	uint32 baud_rate,
		queue_in_size,
		queue_out_size,
		wait_mask,
		read_interval_timeout,
		read_total_timeout_multiplier,
		read_total_timeout_constant,
		write_total_timeout_multiplier, write_total_timeout_constant, posix_wait_mask;
	uint8 stop_bits, parity, word_length;
	uint8 chars[6];
	struct termios *ptermios, *pold_termios;
	int event_txempty, event_cts, event_dsr, event_rlsd, event_pending;
} RDSerialDevice;

typedef struct _RDParallelDevice
{
	char *driver, *printer;
	uint32 queue_in_size,
		queue_out_size,
		wait_mask,
		read_interval_timeout,
		read_total_timeout_multiplier,
		read_total_timeout_constant,
		write_total_timeout_multiplier,
		write_total_timeout_constant, posix_wait_mask, bloblen;
	uint8 *blob;
} RDParallelDevice;

typedef struct _RDPrinterInfo
{
	FILE *printer_fp;
	char *driver, *printer;
	uint32 bloblen;
	uint8 *blob;
	RDBOOL default_printer;
} RDPrinterInfo;

// xxx: won't be needed
typedef struct notify_data
{
	time_t modify_time;
	time_t status_time;
	time_t total_time;
	unsigned int num_entries;
}
NOTIFY;


typedef struct _DEVICE_FNS DEVICE_FNS;

// Used to store incoming io request, until they are ready to be completed using a linked list ensures that they are processed in the right order, if multiple ios are being done on the same fd
typedef struct _RDAsynchronousIORequest
{
	uint32 fd, major, minor, offset, device, fid, length, partial_len, aborted;
	uint8 *buffer;
	DEVICE_FNS *fns;
	
	NSFileHandle *fileHandle;
	struct _RDAsynchronousIORequest *next;
} RDAsynchronousIORequest;

typedef struct _RDFileInfo
{
	uint32 device_id, flags_and_attributes, accessmask;
	char path[PATH_MAX];
	DIR *pdir;
	struct dirent *pdirent;
	char pattern[PATH_MAX];
	RDBOOL delete_on_close;
	NOTIFY notify;
	uint32 info_class;
	RDAsynchronousIORequest *firstIORequest;
} RDFileInfo;





#import "orders.h"

struct bmpcache_entry
{
	RDBitmapRef bitmap;
	sint16 previous;
	sint16 next;
};

typedef enum _RDConnectionError
{
	ConnectionErrorNone = 0,
	ConnectionErrorTimeOut = 1,
	ConnectionErrorHostResolution = 2,
	ConnectionErrorGeneral = 3,
	ConnectionErrorCanceled = 4
} RDConnectionError;

struct RDConnection
{
	// Connection settings
	char username[64];
	char hostname[64];
	
	// State flags
	int isConnected, useRdp5, useEncryption, useBitmapCompression, rdp5PerformanceFlags, consoleSession, bitmapCache, bitmapCachePersist, bitmapCachePrecache, desktopSave, polygonEllipseOrders, licenseIssued, notifyStamp, pstcacheEnumerated;
	RDP_ORDER_STATE orderState;
	
	// Keyboard
	unsigned int keyboardLayout;
	int keyboardType, keyboardSubtype, keyboardFunctionkeys;
	
	// Connection details
	int tcpPort, currentStatus, screenWidth, screenHeight, serverBpp, shareID, serverRdpVersion;
	
	// Bitmap caches
	int pstcacheBpp;
	int pstcacheFd[8];
	int bmpcacheCount[3];
	unsigned char deskCache[0x38400 * 4];
	RDBitmapRef volatileBc[3];
	RDCursorRef cursorCache[0x20];
	RDDataBlob textCache[256];
	RDFontGlyph fontCache[12][256];
	
	// Device redirection
	char *rdpdrClientname;
	unsigned int numChannels, numDevices;
	int clipboardRequestType;
	NTHandle minTimeoutFd;
	RDFileInfo fileInfo[0x100];		// MAX_OPEN_FILES taken from disk.h
	RDRedirectedDevice rdpdrDevice[0x10];	//RDPDR_MAX_DEVICES taken from constants.h
	RDVirtualChannel channels[6];
	RDVirtualChannel *rdpdrChannel;
	RDVirtualChannel *cliprdrChannel;
	RDAsynchronousIORequest *ioRequest;
	char *printerNames[255];
	
	// MCS/licence
	unsigned char licenseKey[16], licenseSignKey[16];
	unsigned short mcsUserid;
	
	// Session directory
	RDBOOL sessionDirRedirect;
	char sessionDirServer[64];
	char sessionDirDomain[16];
	char sessionDirPassword[64];
	char sessionDirUsername[64];
	char sessionDirCookie[128];
	unsigned int sessionDirFlags;
	
	// Bitmap cache
	struct bmpcache_entry bmpcache[NBITMAPCACHE][NBITMAPCACHEENTRIES];
	int bmpcacheLru[3];
	int bmpcacheMru[3];
	
	// Network
	int packetNumber;
	unsigned char *nextPacket;
	void *inputStream; // NSInputStream
 	void *outputStream; // NSOutputStream
	void *host;
	RDStream inStream, outStream;
	RDStreamRef rdpStream;
	
	// Secure
	int rc4KeyLen;
	RC4_KEY rc4DecryptKey;
	RC4_KEY rc4EncryptKey;
	RSA *serverPublicKey;
	uint32 serverPublicKeyLen;
	uint8 secSignKey[16];
	uint8 secDecryptKey[16];
	uint8 secEncryptKey[16];
	uint8 secDecryptUpdateKey[16];
	uint8 secEncryptUpdateKey[16];
	uint8 secCryptedRandom[SEC_MAX_MODULUS_SIZE];
	uint32 secEncryptUseCount, secDecryptUseCount;
	
	// Unknown
	RDComp mppcDict;
	
	// UI
	CRDSessionView *ui;	// the associated CRDSessionView
	CRDSession *controller; // the associated CRDSession
	
	volatile RDConnectionError errorCode;
	
	// Managing current draw session (used by ui_stubs)
	void *rectsNeedingUpdate;
	int updateEntireScreen;
};



struct _DEVICE_FNS
{
	NTStatus(*create) (RDConnectionRef conn, uint32 device, uint32 desired_access, uint32 share_mode,
					   uint32 create_disposition, uint32 flags_and_attributes, char *filename,
					   NTHandle * handle);
	NTStatus(*close) (RDConnectionRef conn, NTHandle handle);
	NTStatus(*read) (RDConnectionRef conn, NTHandle handle, uint8 * data, uint32 length, uint32 offset,
					 uint32 * result);
	NTStatus(*write) (RDConnectionRef conn, NTHandle handle, uint8 * data, uint32 length, uint32 offset,
					  uint32 * result);
	NTStatus(*device_control) (RDConnectionRef conn, NTHandle handle, uint32 request, RDStreamRef in, RDStreamRef out);
};

typedef RDBOOL(*str_handle_lines_t) (const char *line, void *data);

