/* -*- c-basic-offset: 8 -*-
   rdesktop: A Remote Desktop Protocol client.
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

// THIS IS UNUSED IN CORD AND IS ONLY LEFT FOR REFERENCE - SEE CRDDeviceRedirectionGlue

/*
  Here are some resources, for your IRP hacking pleasure:

  http://cvs.sourceforge.net/viewcvs.py/mingw/w32api/include/ddk/winddk.h?view=markup

  http://win32.mvps.org/ntfs/streams.cpp

  http://www.acc.umu.se/~bosse/ntifs.h

  http://undocumented.ntinternals.net/UserMode/Undocumented%20Functions/NT%20Objects/File/

  http://us1.samba.org/samba/ftp/specs/smb-nt01.txt

  http://www.osronline.com/
*/

#import <unistd.h>
#import <sys/types.h>
#import <sys/time.h>
#import <dirent.h>		/* opendir, closedir, readdir */
#import <time.h>
#import <errno.h>
#import "rdesktop.h"

#define IRP_MJ_CREATE			0x00
#define IRP_MJ_CLOSE			0x02
#define IRP_MJ_READ			0x03
#define IRP_MJ_WRITE			0x04
#define	IRP_MJ_QUERY_INFORMATION	0x05
#define IRP_MJ_SET_INFORMATION		0x06
#define IRP_MJ_QUERY_VOLUME_INFORMATION	0x0a
#define IRP_MJ_DIRECTORY_CONTROL	0x0c
#define IRP_MJ_DEVICE_CONTROL		0x0e
#define IRP_MJ_LOCK_CONTROL             0x11

#define IRP_MN_QUERY_DIRECTORY          0x01
#define IRP_MN_NOTIFY_CHANGE_DIRECTORY  0x02

extern DEVICE_FNS serial_fns;
extern DEVICE_FNS printer_fns;
extern DEVICE_FNS parallel_fns;
extern DEVICE_FNS disk_fns;

// Return device_id for a given handle
int
get_device_index(RDConnectionRef conn, NTHandle handle)
{
	int i;
	for (i = 0; i < RDPDR_MAX_DEVICES; i++)
	{
		if (conn->rdpdrDevice[i].handle == handle)
			return i;
	}
	return -1;
}

// Converts a windows path to a unix path
void convert_to_unix_filename(char *filename)
{
	char *p;

	while ((p = strchr(filename, '\\')))
	{
		*p = '/';
	}
}

static RDBOOL rdpdr_handle_ok(RDConnectionRef conn, int device, int handle)
{
	switch (conn->rdpdrDevice[device].device_type)
	{
		case DEVICE_TYPE_PARALLEL:
		case DEVICE_TYPE_SERIAL:
		case DEVICE_TYPE_PRINTER:
		case DEVICE_TYPE_SCARD:
			if (conn->rdpdrDevice[device].handle != handle)
				return False;
			break;
		case DEVICE_TYPE_DISK:
			if (conn->fileInfo[handle].device_id != device)
				return False;
			break;
	}
	return True;
}

/* Add a new io request to the table containing pending io requests so it won't block rdesktop */
static RDBOOL add_async_iorequest(RDConnectionRef conn, uint32 device, uint32 file, uint32 fid, uint32 major, uint32 length, DEVICE_FNS * fns, uint32 total_timeout, uint32 interval_timeout, uint8 * buffer, uint32 offset) 
{
	struct async_iorequest *iorq;
	
	if (conn->ioRequest == NULL)
	{
		conn->ioRequest = (struct async_iorequest *) xmalloc(sizeof(struct async_iorequest));
		if (!conn->ioRequest)
			return False;
		conn->ioRequest->fd = 0;
		conn->ioRequest->next = NULL;
	}

	iorq = conn->ioRequest;

	while (iorq->fd != 0)
	{
		/* create new element if needed */
		if (iorq->next == NULL)
		{
			iorq->next =
				(struct async_iorequest *) xmalloc(sizeof(struct async_iorequest));
			if (!iorq->next)
				return False;
			iorq->next->fd = 0;
			iorq->next->next = NULL;
		}
		iorq = iorq->next;
	}
	iorq->device = device;
	iorq->fd = file;
	iorq->fid = fid;
	iorq->major = major;
	iorq->length = length;
	iorq->partial_len = 0;
	iorq->fns = fns;
	iorq->timeout = total_timeout;
	iorq->itv_timeout = interval_timeout;
	iorq->buffer = buffer;
	iorq->offset = offset;
	return True;
}

static void
rdpdr_send_connect(RDConnectionRef conn)
{
	uint8 magic[4] = "rDCC";
	RDStreamRef s;

	s = channel_init(conn, conn->rdpdrChannel, 12);
	out_uint8a(s, magic, 4);
	out_uint16_le(s, 1);	/* unknown */
	out_uint16_le(s, 5);
	out_uint32_be(s, 0x815ed39d);	/* IP address (use 127.0.0.1) 0x815ed39d */
	s_mark_end(s);
	channel_send(conn, s, conn->rdpdrChannel);
}


static void
rdpdr_send_name(RDConnectionRef conn)
{
	uint8 magic[4] = "rDNC";
	RDStreamRef s;
	uint32 hostlen;

	if (NULL == conn->rdpdrClientname)
	{
		conn->rdpdrClientname = conn->hostname;
	}
	hostlen = (strlen(conn->rdpdrClientname) + 1) * 2;

	s = channel_init(conn, conn->rdpdrChannel, 16 + hostlen);
	out_uint8a(s, magic, 4);
	out_uint16_le(s, 0x63);	/* unknown */
	out_uint16_le(s, 0x72);
	out_uint32(s, 0);
	out_uint32_le(s, hostlen);
	rdp_out_unistr(s, conn->rdpdrClientname, hostlen - 2);
	s_mark_end(s);
	channel_send(conn, s, conn->rdpdrChannel);
}

/* Returns the size of the payload of the announce packet */
static int
announcedata_size(RDConnectionRef conn)
{
	int size, i;
	RDPrinterInfo *printerinfo;

	size = 8;
	size += conn->numDevices * 0x14;

	for (i = 0; i < conn->numDevices; i++)
	{
		if (conn->rdpdrDevice[i].device_type == DEVICE_TYPE_PRINTER)
		{
			printerinfo = (RDPrinterInfo *) conn->rdpdrDevice[i].pdevice_data;
			printerinfo->bloblen =
				printercache_load_blob(printerinfo->printer, &(printerinfo->blob));

			size += 0x18;
			size += 2 * strlen(printerinfo->driver) + 2;
			size += 2 * strlen(printerinfo->printer) + 2;
			size += printerinfo->bloblen;
		}
	}

	return size;
}

static void
rdpdr_send_available(RDConnectionRef conn)
{

	uint8 magic[4] = "rDAD";
	uint32 driverlen, printerlen, bloblen;
	int i;
	RDStreamRef s;
	RDPrinterInfo *printerinfo;

	s = channel_init(conn, conn->rdpdrChannel, announcedata_size(conn));
	out_uint8a(s, magic, 4);
	out_uint32_le(s, conn->numDevices);

	for (i = 0; i < conn->numDevices; i++)
	{
		out_uint32_le(s, conn->rdpdrDevice[i].device_type);
		out_uint32_le(s, i);	/* RDP Device ID */
		/* Is it possible to use share names longer than 8 chars?
		   /astrand */
		out_uint8p(s, conn->rdpdrDevice[i].name, 8);

		switch (conn->rdpdrDevice[i].device_type)
		{
			case DEVICE_TYPE_PRINTER:
				printerinfo = (RDPrinterInfo *) conn->rdpdrDevice[i].pdevice_data;

				driverlen = 2 * strlen(printerinfo->driver) + 2;
				printerlen = 2 * strlen(printerinfo->printer) + 2;
				bloblen = printerinfo->bloblen;

				out_uint32_le(s, 24 + driverlen + printerlen + bloblen);	/* length of extra info */
				out_uint32_le(s, printerinfo->default_printer ? 2 : 0);
				out_uint8s(s, 8);	/* unknown */
				out_uint32_le(s, driverlen);
				out_uint32_le(s, printerlen);
				out_uint32_le(s, bloblen);
				rdp_out_unistr(s, printerinfo->driver, driverlen - 2);
				rdp_out_unistr(s, printerinfo->printer, printerlen - 2);
				out_uint8a(s, printerinfo->blob, bloblen);

				if (printerinfo->blob)
					xfree(printerinfo->blob);	/* Blob is sent twice if reconnecting */
				break;
			default:
				out_uint32(s, 0);
		}
	}

	s_mark_end(s);
	channel_send(conn, s, conn->rdpdrChannel);
}

static void
rdpdr_send_completion(RDConnectionRef conn, uint32 device, uint32 id, uint32 status, uint32 result, uint8 * buffer,
		      uint32 length)
{
	uint8 magic[4] = "rDCI";
	RDStreamRef s;

	s = channel_init(conn, conn->rdpdrChannel, 20 + length);
	out_uint8a(s, magic, 4);
	out_uint32_le(s, device);
	out_uint32_le(s, id);
	out_uint32_le(s, status);
	out_uint32_le(s, result);
	out_uint8p(s, buffer, length);
	s_mark_end(s);
	/* JIF */
#ifdef WITH_DEBUG_RDP5
	printf("--> rdpdr_send_completion\n");
	/* hexdump(s->channel_hdr + 8, s->end - s->channel_hdr - 8); */
#endif
	channel_send(conn, s, conn->rdpdrChannel);
}

static void
rdpdr_process_irp(RDConnectionRef conn, RDStreamRef s)
{
	uint32 result = 0,
		length = 0,
		desired_access = 0,
		request,
		file,
		info_level,
		buffer_len,
		id,
		major,
		minor,
		device,
		offset,
		bytes_in,
		bytes_out,
		error_mode,
		share_mode, disposition, total_timeout, interval_timeout, flags_and_attributes = 0;

	char filename[PATH_MAX];
	uint8 *buffer, *pst_buf;
	RDStream out;
	DEVICE_FNS *fns;
	RDBOOL rw_blocking = True;
	NTStatus status = STATUS_INVALID_DEVICE_REQUEST;

	in_uint32_le(s, device);
	in_uint32_le(s, file);
	in_uint32_le(s, id);
	in_uint32_le(s, major);
	in_uint32_le(s, minor);

	buffer_len = 0;
	buffer = (uint8 *) xmalloc(1024);
	buffer[0] = 0;

	switch (conn->rdpdrDevice[device].device_type)
	{
		case DEVICE_TYPE_SERIAL:

			fns = &serial_fns;
			rw_blocking = False;
			break;

		case DEVICE_TYPE_PARALLEL:

			fns = &parallel_fns;
			rw_blocking = False;
			break;

		case DEVICE_TYPE_PRINTER:

			fns = &printer_fns;
			break;

		case DEVICE_TYPE_DISK:

			fns = &disk_fns;
			rw_blocking = False;
			break;

		case DEVICE_TYPE_SCARD:
		default:

			error("IRP for bad device %ld\n", device);
			return;
	}

	switch (major)
	{
		case IRP_MJ_CREATE:

			in_uint32_be(s, desired_access);
			in_uint8s(s, 0x08);	/* unknown */
			in_uint32_le(s, error_mode);
			in_uint32_le(s, share_mode);
			in_uint32_le(s, disposition);
			in_uint32_le(s, flags_and_attributes);
			in_uint32_le(s, length);

			if (length && (length / 2) < 256)
			{
				rdp_in_unistr(s, filename, length);
				convert_to_unix_filename(filename);
			}
			else
			{
				filename[0] = 0;
			}

			if (!fns->create)
			{
				status = STATUS_NOT_SUPPORTED;
				break;
			}

			status = fns->create(conn, device, desired_access, share_mode, disposition,
					     flags_and_attributes, filename, &result);
			buffer_len = 1;
			break;

		case IRP_MJ_CLOSE:
			if (!fns->close)
			{
				status = STATUS_NOT_SUPPORTED;
				break;
			}

			status = fns->close(conn, file);
			break;

		case IRP_MJ_READ:

			if (!fns->read)
			{
				status = STATUS_NOT_SUPPORTED;
				break;
			}

			in_uint32_le(s, length);
			in_uint32_le(s, offset);
#if WITH_DEBUG_RDP5
			DEBUG(("RDPDR IRP Read (length: %d, offset: %d)\n", length, offset));
#endif
			if (!rdpdr_handle_ok(conn, device, file))
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			if (rw_blocking)	/* Complete read immediately */
			{
				buffer = (uint8 *) xrealloc((void *) buffer, length);
				if (!buffer)
				{
					status = STATUS_CANCELLED;
					break;
				}
				status = fns->read(conn, file, buffer, length, offset, &result);
				buffer_len = result;
				break;
			}

			/* Add request to table */
			pst_buf = (uint8 *) xmalloc(length);
			if (!pst_buf)
			{
				status = STATUS_CANCELLED;
				break;
			}
			serial_get_timeout(conn, file, length, &total_timeout, &interval_timeout);
			if (add_async_iorequest
			    (conn, device, file, id, major, length, fns, total_timeout, interval_timeout,
			     pst_buf, offset))
			{
				status = STATUS_PENDING;
				break;
			}

			status = STATUS_CANCELLED;
			break;
		case IRP_MJ_WRITE:

			buffer_len = 1;

			if (!fns->write)
			{
				status = STATUS_NOT_SUPPORTED;
				break;
			}

			in_uint32_le(s, length);
			in_uint32_le(s, offset);
			in_uint8s(s, 0x18);
#if WITH_DEBUG_RDP5
			DEBUG(("RDPDR IRP Write (length: %d)\n", result));
#endif
			if (!rdpdr_handle_ok(conn, device, file))
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			if (rw_blocking)	/* Complete immediately */
			{
				status = fns->write(conn, file, s->p, length, offset, &result);
				break;
			}

			/* Add to table */
			pst_buf = (uint8 *) xmalloc(length);
			if (!pst_buf)
			{
				status = STATUS_CANCELLED;
				break;
			}

			in_uint8a(s, pst_buf, length);

			if (add_async_iorequest
			    (conn, device, file, id, major, length, fns, 0, 0, pst_buf, offset))
			{
				status = STATUS_PENDING;
				break;
			}

			status = STATUS_CANCELLED;
			break;

		case IRP_MJ_QUERY_INFORMATION:

			if (conn->rdpdrDevice[device].device_type != DEVICE_TYPE_DISK)
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}
			in_uint32_le(s, info_level);

			out.data = out.p = buffer;
			out.size = sizeof(buffer);
			status = disk_query_information(conn, file, info_level, &out);
			result = buffer_len = out.p - out.data;

			break;

		case IRP_MJ_SET_INFORMATION:

			if (conn->rdpdrDevice[device].device_type != DEVICE_TYPE_DISK)
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			in_uint32_le(s, info_level);

			out.data = out.p = buffer;
			out.size = sizeof(buffer);
			status = disk_set_information(conn, file, info_level, s, &out);
			result = buffer_len = out.p - out.data;
			break;

		case IRP_MJ_QUERY_VOLUME_INFORMATION:

			if (conn->rdpdrDevice[device].device_type != DEVICE_TYPE_DISK)
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			in_uint32_le(s, info_level);

			out.data = out.p = buffer;
			out.size = sizeof(buffer);
			status = disk_query_volume_information(conn, file, info_level, &out);
			result = buffer_len = out.p - out.data;
			break;

		case IRP_MJ_DIRECTORY_CONTROL:

			if (conn->rdpdrDevice[device].device_type != DEVICE_TYPE_DISK)
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			switch (minor)
			{
				case IRP_MN_QUERY_DIRECTORY:
					
					in_uint32_le(s, info_level);
					in_uint8s(s, 1);
					in_uint32_le(s, length);
					in_uint8s(s, 0x17);
					if (length && length < 2 * 255)
					{
						rdp_in_unistr(s, filename, length);
						convert_to_unix_filename(filename);
					}
					else
					{
						filename[0] = 0;
					}
					out.data = out.p = buffer;
					out.size = sizeof(buffer);
					status = disk_query_directory(conn, file, info_level, filename,
								      &out);
					result = buffer_len = out.p - out.data;
					if (!buffer_len)
						buffer_len++;
					break;

				case IRP_MN_NOTIFY_CHANGE_DIRECTORY:
					/* JIF
					   unimpl("IRP major=0x%x minor=0x%x: IRP_MN_NOTIFY_CHANGE_DIRECTORY\n", major, minor);  */

					in_uint32_le(s, info_level);	/* notify mask */

					conn->notifyStamp = True;

					status = disk_create_notify(conn, file, info_level);
					result = 0;

					if (status == STATUS_PENDING)
						add_async_iorequest(conn, device, file, id, major, length,
								    fns, 0, 0, NULL, 0);
					break;

				default:

					status = STATUS_INVALID_PARAMETER;
					/* JIF */
					unimpl("IRP major=0x%x minor=0x%x\n", major, minor);
			}
			break;

		case IRP_MJ_DEVICE_CONTROL:

			if (!fns->device_control)
			{
				status = STATUS_NOT_SUPPORTED;
				break;
			}

			in_uint32_le(s, bytes_out);
			in_uint32_le(s, bytes_in);
			in_uint32_le(s, request);
			in_uint8s(s, 0x14);

			buffer = (uint8 *) xrealloc((void *) buffer, bytes_out + 0x14);
			if (!buffer)
			{
				status = STATUS_CANCELLED;
				break;
			}

			out.data = out.p = buffer;
			out.size = sizeof(buffer);
			status = fns->device_control(conn, file, request, s, &out);
			result = buffer_len = out.p - out.data;

			/* Serial SERIAL_WAIT_ON_MASK */
			if (status == STATUS_PENDING)
			{
				if (add_async_iorequest
				    (conn, device, file, id, major, length, fns, 0, 0, NULL, 0))
				{
					status = STATUS_PENDING;
					break;
				}
			}
			break;


		case IRP_MJ_LOCK_CONTROL:

			if (conn->rdpdrDevice[device].device_type != DEVICE_TYPE_DISK)
			{
				status = STATUS_INVALID_HANDLE;
				break;
			}

			in_uint32_le(s, info_level);

			out.data = out.p = buffer;
			out.size = sizeof(buffer);
			/* FIXME: Perhaps consider actually *do*
			   something here :-) */
			status = STATUS_SUCCESS;
			result = buffer_len = out.p - out.data;
			break;

		default:
			unimpl("IRP major=0x%x minor=0x%x\n", major, minor);
			break;
	}

	if (status != STATUS_PENDING)
	{
		rdpdr_send_completion(conn, device, id, status, result, buffer, buffer_len);
	}
	if (buffer)
		xfree(buffer);
	buffer = NULL;
}

static void rdpdr_send_clientcapabilty(RDConnectionRef conn)
{
	uint8 magic[4] = "rDPC";
	RDStreamRef s;

	s = channel_init(conn, conn->rdpdrChannel, 0x50);
	out_uint8a(s, magic, 4);
	out_uint32_le(s, 5);	/* count */
	out_uint16_le(s, 1);	/* first */
	out_uint16_le(s, 0x28);	/* length */
	out_uint32_le(s, 1);
	out_uint32_le(s, 2);
	out_uint16_le(s, 2);
	out_uint16_le(s, 5);
	out_uint16_le(s, 1);
	out_uint16_le(s, 5);
	out_uint16_le(s, 0xFFFF);
	out_uint16_le(s, 0);
	out_uint32_le(s, 0);
	out_uint32_le(s, 3);
	out_uint32_le(s, 0);
	out_uint32_le(s, 0);
	out_uint16_le(s, 2);	/* second */
	out_uint16_le(s, 8);	/* length */
	out_uint32_le(s, 1);
	out_uint16_le(s, 3);	/* third */
	out_uint16_le(s, 8);	/* length */
	out_uint32_le(s, 1);
	out_uint16_le(s, 4);	/* fourth */
	out_uint16_le(s, 8);	/* length */
	out_uint32_le(s, 1);
	out_uint16_le(s, 5);	/* fifth */
	out_uint16_le(s, 8);	/* length */
	out_uint32_le(s, 1);

	s_mark_end(s);
	channel_send(conn, s, conn->rdpdrChannel);
}

static void
rdpdr_process(RDConnectionRef conn, RDStreamRef s)
{
	uint32 handle;
	uint8 *magic;

#if WITH_DEBUG_RDP5
	printf("--- rdpdr_process ---\n");
	hexdump(s->p, s->end - s->p);
#endif
	in_uint8p(s, magic, 4);

	if ((magic[0] == 'r') && (magic[1] == 'D'))
	{
		if ((magic[2] == 'R') && (magic[3] == 'I'))
		{
			rdpdr_process_irp(conn, s);
			return;
		}
		if ((magic[2] == 'n') && (magic[3] == 'I'))
		{
			rdpdr_send_connect(conn);
			rdpdr_send_name(conn);
			return;
		}
		if ((magic[2] == 'C') && (magic[3] == 'C'))
		{
			// connect from server
			rdpdr_send_clientcapabilty(conn);
			rdpdr_send_available(conn);
			return;
		}
		if ((magic[2] == 'r') && (magic[3] == 'd'))
		{
			/* connect to a specific resource */
			in_uint32(s, handle);
			
#if WITH_DEBUG_RDP5
			DEBUG(("RDPDR: Server connected to resource %d\n", handle));
#endif
			return;
		}
		if ((magic[2] == 'P') && (magic[3] == 'S'))
		{
			/* server capability */
			return;
		}
	}
	if ((magic[0] == 'R') && (magic[1] == 'P'))
	{
		if ((magic[2] == 'C') && (magic[3] == 'P'))
		{
			printercache_process(s);
			return;
		}
	}
	unimpl("RDPDR packet type %c%c%c%c\n", magic[0], magic[1], magic[2], magic[3]);
}

int
rdpdr_init(RDConnectionRef conn)
{
	if (conn->numDevices > 0)
	{
		conn->rdpdrChannel =
			channel_register(conn, "rdpdr",
					 CHANNEL_OPTION_INITIALIZED | CHANNEL_OPTION_COMPRESS_RDP,
					 rdpdr_process);
	}

	return (conn->rdpdrChannel != NULL);
}

/* Add file descriptors of pending io request to select() */
void
rdpdr_add_fds(RDConnectionRef conn, int *n, fd_set * rfds, fd_set * wfds, struct timeval *tv, RDBOOL * timeout)
{
	uint32 select_timeout = 0;	/* Timeout value to be used for select() (in millisecons). */
	struct async_iorequest *iorq;
	char c;

	iorq = conn->ioRequest;
	while (iorq != NULL)
	{
		if (iorq->fd != 0)
		{
			switch (iorq->major)
			{
				case IRP_MJ_READ:
					/* Is this FD valid? FDs will
					   be invalid when
					   reconnecting. FIXME: Real
					   support for reconnects. */

					FD_SET(iorq->fd, rfds);
					*n = MAX(*n, iorq->fd);

					/* Check if io request timeout is smaller than current (but not 0). */
					if (iorq->timeout
					    && (select_timeout == 0
						|| iorq->timeout < select_timeout))
					{
						/* Set new timeout */
						select_timeout = iorq->timeout;
						conn->minTimeoutFd = iorq->fd;	/* Remember fd */
						tv->tv_sec = select_timeout / 1000;
						tv->tv_usec = (select_timeout % 1000) * 1000;
						*timeout = True;
						break;
					}
					if (iorq->itv_timeout && iorq->partial_len > 0
					    && (select_timeout == 0
						|| iorq->itv_timeout < select_timeout))
					{
						/* Set new timeout */
						select_timeout = iorq->itv_timeout;
						conn->minTimeoutFd = iorq->fd;	/* Remember fd */
						tv->tv_sec = select_timeout / 1000;
						tv->tv_usec = (select_timeout % 1000) * 1000;
						*timeout = True;
						break;
					}
					break;

				case IRP_MJ_WRITE:
					/* FD still valid? See above. */
					if ((write(iorq->fd, &c, 0) != 0) && (errno == EBADF))
						break;

					FD_SET(iorq->fd, wfds);
					*n = MAX(*n, iorq->fd);
					break;

				case IRP_MJ_DEVICE_CONTROL:
					if (select_timeout > 5)
						select_timeout = 5;	/* serial event queue */
					break;

			}

		}

		iorq = iorq->next;
	}
}

struct async_iorequest *
rdpdr_remove_iorequest(RDConnectionRef conn, struct async_iorequest *prev, struct async_iorequest *iorq)
{
	if (!iorq)
		return NULL;

	if (iorq->buffer)
		xfree(iorq->buffer);
	if (prev)
	{
		prev->next = iorq->next;
		xfree(iorq);
		iorq = prev->next;
	}
	else
	{
		/* Even if NULL */
		conn->ioRequest = iorq->next;
		xfree(iorq);
		iorq = NULL;
	}
	return iorq;
}

/* Check if select() returned with one of the rdpdr file descriptors, and complete io if it did */
static void
_rdpdr_check_fds(RDConnectionRef conn, fd_set * rfds, fd_set * wfds, RDBOOL timed_out)
{
	NTStatus status;
	uint32 result = 0;
	DEVICE_FNS *fns;
	struct async_iorequest *iorq;
	struct async_iorequest *prev;
	uint32 req_size = 0;
	uint32 buffer_len;
	RDStream out;
	uint8 *buffer = NULL;


	if (timed_out)
	{
		/* check serial iv_timeout */

		iorq = conn->ioRequest;
		prev = NULL;
		while (iorq != NULL)
		{
			if (iorq->fd ==conn->minTimeoutFd)
			{
				if ((iorq->partial_len > 0) &&
				    (conn->rdpdrDevice[iorq->device].device_type ==
				     DEVICE_TYPE_SERIAL))
				{

					/* iv_timeout between 2 chars, send partial_len */
					/*printf("RDPDR: IVT total %u bytes read of %u\n", iorq->partial_len, iorq->length); */
					rdpdr_send_completion(conn,
										  iorq->device,
							      iorq->fid, STATUS_SUCCESS,
							      iorq->partial_len,
							      iorq->buffer, iorq->partial_len);
					iorq = rdpdr_remove_iorequest(conn, prev, iorq);
					return;
				}
				else
				{
					break;
				}

			}
			else
			{
				break;
			}


			prev = iorq;
			if (iorq)
				iorq = iorq->next;

		}

		rdpdr_abort_io(conn,conn->minTimeoutFd, 0, STATUS_TIMEOUT);
		return;
	}

	iorq = conn->ioRequest;
	prev = NULL;
	while (iorq != NULL)
	{
		if (iorq->fd != 0)
		{
			switch (iorq->major)
			{
				case IRP_MJ_READ:
					if (FD_ISSET(iorq->fd, rfds))
					{
						/* Read the data */
						fns = iorq->fns;

						req_size =
							(iorq->length - iorq->partial_len) >
							8192 ? 8192 : (iorq->length -
								       iorq->partial_len);
						/* never read larger chunks than 8k - chances are that it will block */
						status = fns->read(conn, iorq->fd,
								   iorq->buffer + iorq->partial_len,
								   req_size, iorq->offset, &result);

						if ((long) result > 0)
						{
							iorq->partial_len += result;
							iorq->offset += result;
						}
#if WITH_DEBUG_RDP5
						DEBUG(("RDPDR: %d bytes of data read\n", result));
#endif
						/* only delete link if all data has been transfered */
						/* or if result was 0 and status success - EOF      */
						if ((iorq->partial_len == iorq->length) ||
						    (result == 0))
						{
#if WITH_DEBUG_RDP5
							DEBUG(("RDPDR: AIO total %u bytes read of %u\n", iorq->partial_len, iorq->length));
#endif
							rdpdr_send_completion(conn,
												  iorq->device,
									      iorq->fid, status,
									      iorq->partial_len,
									      iorq->buffer,
									      iorq->partial_len);
							iorq = rdpdr_remove_iorequest(conn, prev, iorq);
						}
					}
					break;
				case IRP_MJ_WRITE:
					if (FD_ISSET(iorq->fd, wfds))
					{
						/* Write data. */
						fns = iorq->fns;

						req_size =
							(iorq->length - iorq->partial_len) >
							8192 ? 8192 : (iorq->length -
								       iorq->partial_len);

						/* never write larger chunks than 8k - chances are that it will block */
						status = fns->write(conn, iorq->fd,
								    iorq->buffer +
								    iorq->partial_len, req_size,
								    iorq->offset, &result);

						if ((long) result > 0)
						{
							iorq->partial_len += result;
							iorq->offset += result;
						}

#if WITH_DEBUG_RDP5
						DEBUG(("RDPDR: %d bytes of data written\n",
						       result));
#endif
						/* only delete link if all data has been transfered */
						/* or we couldn't write */
						if ((iorq->partial_len == iorq->length)
						    || (result == 0))
						{
#if WITH_DEBUG_RDP5
							DEBUG(("RDPDR: AIO total %u bytes written of %u\n", iorq->partial_len, iorq->length));
#endif
							rdpdr_send_completion(conn,
												  iorq->device,
									      iorq->fid, status,
									      iorq->partial_len,
									      (uint8 *) "", 1);

							iorq = rdpdr_remove_iorequest(conn, prev, iorq);
						}
					}
					break;
				case IRP_MJ_DEVICE_CONTROL:
					if (serial_get_event(conn, iorq->fd, &result))
					{
						buffer = (uint8 *) xrealloc((void *) buffer, 0x14);
						out.data = out.p = buffer;
						out.size = sizeof(buffer);
						out_uint32_le(&out, result);
						result = buffer_len = out.p - out.data;
						status = STATUS_SUCCESS;
						rdpdr_send_completion(conn,
											  iorq->device, iorq->fid,
								      status, result, buffer,
								      buffer_len);
						xfree(buffer);
						iorq = rdpdr_remove_iorequest(conn, prev, iorq);
					}

					break;
			}

		}
		prev = iorq;
		if (iorq)
			iorq = iorq->next;
	}

	/* Check notify */
	iorq = conn->ioRequest;
	prev = NULL;
	while (iorq != NULL)
	{
		if (iorq->fd != 0)
		{
			switch (iorq->major)
			{

				case IRP_MJ_DIRECTORY_CONTROL:
					if (conn->rdpdrDevice[iorq->device].device_type ==
					    DEVICE_TYPE_DISK)
					{

						if (conn->notifyStamp)
						{
							conn->notifyStamp = False;
							status = disk_check_notify(conn, iorq->fd);
							if (status != STATUS_PENDING)
							{
								rdpdr_send_completion(conn, 
													  iorq->device,
										      iorq->fid,
										      status, 0,
										      NULL, 0);
								iorq = rdpdr_remove_iorequest(conn, prev,
											      iorq);
							}
						}
					}
					break;



			}
		}

		prev = iorq;
		if (iorq)
			iorq = iorq->next;
	}

}

void
rdpdr_check_fds(RDConnectionRef conn, fd_set * rfds, fd_set * wfds, RDBOOL timed_out)
{
	fd_set dummy;


	FD_ZERO(&dummy);


	/* fist check event queue only,
	   any serial wait event must be done before read block will be sent
	 */

	_rdpdr_check_fds(conn, &dummy, &dummy, False);
	_rdpdr_check_fds(conn, rfds, wfds, timed_out);
}


/* Abort a pending io request for a given handle and major */
RDBOOL
rdpdr_abort_io(RDConnectionRef conn, uint32 fd, uint32 major, NTStatus status)
{
	uint32 result;
	struct async_iorequest *iorq;
	struct async_iorequest *prev;

	iorq = conn->ioRequest;
	prev = NULL;
	while (iorq != NULL)
	{
		/* Only remove from table when major is not set, or when correct major is supplied.
		   Abort read should not abort a write io request. */
		if ((iorq->fd == fd) && (major == 0 || iorq->major == major))
		{
			result = 0;
			rdpdr_send_completion(conn, iorq->device, iorq->fid, status, result, (uint8 *) "",
					      1);

			iorq = rdpdr_remove_iorequest(conn, prev, iorq);
			return True;
		}

		prev = iorq;
		iorq = iorq->next;
	}

	return False;
}
