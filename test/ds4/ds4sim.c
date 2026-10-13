/*
 * ds4sim — a virtual DualShock 4 over "Bluetooth" (uhid, bus 0005, 054c:09cc), for testing
 * hid-sony's BT path and the tester's capture script without a controller.
 *
 *   ds4sim <full|badcrc|minimal|short|none> <seconds>
 *
 * Answers GET_REPORT 0x05 (calibration) with a CRC-valid report, as the tester's pad did,
 * then sends input reports every 20 ms, toggling Cross, in the chosen format:
 *   full     0x11, 78 bytes, valid CRC      (a real DS4)
 *   badcrc   0x11, 78 bytes, wrong CRC
 *   minimal  0x01, 10 bytes                 (pads that never switch to 0x11)
 *   short    0x11, 64 bytes                 (wrong size)
 *   none     nothing                        (probe only)
 *
 * Build with any aarch64 Android clang, e.g.  aarch64-linux-android31-clang -O1 ds4sim.c -o ds4sim
 * Run as root next to ds4diag.sh (the owners' capture script):
 *   ./ds4sim badcrc 6 & sleep 2; sh ds4diag.sh 3; wait
 * Measured on v8 (hid-sony 5.10): full + minimal give input; badcrc + short are dropped silently.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/uhid.h>

static void say(const char *s) { write(2, s, strlen(s)); }
static void sayn(const char *s, long n)
{
	char b[24]; int i = 23; int neg = n < 0; b[i] = 0;
	if (neg) n = -n;
	do { b[--i] = '0' + n % 10; n /= 10; } while (n);
	if (neg) b[--i] = '-';
	say(s); say(b + i); say("\n");
}

static uint32_t crc32_bytes(uint32_t crc, const uint8_t *p, int n)
{
	while (n--) {
		crc ^= *p++;
		for (int k = 0; k < 8; k++)
			crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
	}
	return crc;
}
/* hid-sony: crc32_le(0xFFFFFFFF, &hdr, 1); ~crc32_le(crc, data, len) */
static uint32_t ds4_crc(uint8_t hdr, const uint8_t *p, int n)
{
	return ~crc32_bytes(crc32_bytes(0xFFFFFFFFu, &hdr, 1), p, n);
}
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put16(uint8_t *p, int v) { p[0] = v; p[1] = v >> 8; }

static const uint8_t rdesc[] = {
	0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,             /* Generic Desktop / Gamepad / Application */
	0x85, 0x01,                                     /* Report ID 1: the 9-byte basic report */
	0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, /* X Y Z Rz */
	0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
	0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, /* hat */
	0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
	0x65, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0E, /* 14 buttons */
	0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0E, 0x81, 0x02,
	0x75, 0x06, 0x95, 0x01, 0x81, 0x01,             /* 6-bit counter */
	0x05, 0x01, 0x09, 0x33, 0x09, 0x34,             /* Rx Ry (L2 R2) */
	0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
	0x06, 0x00, 0xFF,                               /* vendor */
	0x85, 0x11, 0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
	0x95, 0x4D, 0x81, 0x02,                         /* input 0x11: 77 bytes */
	0x85, 0x11, 0x09, 0x21, 0x95, 0x4D, 0x91, 0x02, /* output 0x11: 77 bytes */
	0x85, 0x05, 0x09, 0x22, 0x95, 0x28, 0xB1, 0x02, /* feature 0x05: 40 bytes */
	0xC0,
};

static int fd;
static long n_get, n_out, n_set;

static void wr(struct uhid_event *ev)
{
	if (write(fd, ev, sizeof(*ev)) != sizeof(*ev))
		sayn("ds4sim: uhid write failed, errno ", errno);
}

/* serve the kernel's requests for up to ms milliseconds */
static void service(int ms)
{
	struct pollfd p = { .fd = fd, .events = POLLIN };
	struct uhid_event ev, rep;

	while (poll(&p, 1, ms) > 0) {
		ms = 0;
		if (read(fd, &ev, sizeof(ev)) <= 0)
			return;
		memset(&rep, 0, sizeof(rep));
		if (ev.type == UHID_GET_REPORT) {
			n_get++;
			sayn("ds4sim: GET_REPORT rnum ", ev.u.get_report.rnum);
			rep.type = UHID_GET_REPORT_REPLY;
			rep.u.get_report_reply.id = ev.u.get_report.id;
			if (ev.u.get_report.rnum == 0x05) {
				uint8_t *d = rep.u.get_report_reply.data;
				d[0] = 0x05;
				put16(d + 7, 8000); put16(d + 9, 8000); put16(d + 11, 8000);    /* gyro plus */
				put16(d + 13, -8000); put16(d + 15, -8000); put16(d + 17, -8000); /* gyro minus */
				put16(d + 19, 540); put16(d + 21, 540);                           /* speed */
				put16(d + 23, 8192); put16(d + 25, -8192); put16(d + 27, 8192);  /* accel */
				put16(d + 29, -8192); put16(d + 31, 8192); put16(d + 33, -8192);
				put32(d + 37, ds4_crc(0xA3, d, 37));
				rep.u.get_report_reply.size = 41;
			} else {
				rep.u.get_report_reply.err = EIO;
			}
			wr(&rep);
		} else if (ev.type == UHID_SET_REPORT) {
			n_set++;
			rep.type = UHID_SET_REPORT_REPLY;
			rep.u.set_report_reply.id = ev.u.set_report.id;
			wr(&rep);
		} else if (ev.type == UHID_OUTPUT) {
			n_out++;
		}
	}
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "none";
	int secs = argc > 2 ? argv[2][0] - '0' : 3;
	struct uhid_event ev;
	struct timespec t = { 0, 20 * 1000 * 1000 };

	fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
	if (fd < 0) { sayn("ds4sim: open /dev/uhid errno ", errno); _exit(1); }

	memset(&ev, 0, sizeof(ev));
	ev.type = UHID_CREATE2;
	strcpy((char *)ev.u.create2.name, "Wireless Controller");
	strcpy((char *)ev.u.create2.phys, "54:c0:78:06:51:9c");
	strcpy((char *)ev.u.create2.uniq, "a0:5a:5f:77:fd:61");
	ev.u.create2.rd_size = sizeof(rdesc);
	ev.u.create2.bus = 0x05;            /* BUS_BLUETOOTH */
	ev.u.create2.vendor = 0x054C;
	ev.u.create2.product = 0x09CC;
	ev.u.create2.version = 0x8100;
	memcpy(ev.u.create2.rd_data, rdesc, sizeof(rdesc));
	wr(&ev);
	say("ds4sim: created; serving probe\n");
	service(1500);

	long sent = 0;
	for (int i = 0; strcmp(mode, "none") && i < secs * 50; i++) {
		int cross = (i / 10) & 1;           /* toggle every 200 ms */
		memset(&ev, 0, sizeof(ev));
		ev.type = UHID_INPUT2;
		uint8_t *d = ev.u.input2.data;
		if (!strcmp(mode, "minimal")) {
			d[0] = 0x01; d[1] = d[2] = d[3] = d[4] = 0x80;
			d[5] = 0x08 | (cross ? 0x20 : 0); d[7] = (i & 0x3F) << 2;
			ev.u.input2.size = 10;
		} else {
			int len = !strcmp(mode, "short") ? 64 : 78;
			d[0] = 0x11; d[1] = 0xC0;
			d[3] = d[4] = d[5] = d[6] = 0x80;
			d[7] = 0x08 | (cross ? 0x20 : 0); d[9] = (i & 0x3F) << 2;
			put16(d + 12, i * 188);         /* timestamp */
			d[32] = 0x0B;                   /* battery: cable, full */
			put32(d + 74, ds4_crc(0xA1, d, 74) ^ (!strcmp(mode, "badcrc") ? 1 : 0));
			ev.u.input2.size = len;
		}
		wr(&ev);
		sent++;
		service(0);
		nanosleep(&t, 0);
	}
	service(300);
	sayn("ds4sim: input reports sent ", sent);
	sayn("ds4sim: GET_REPORT served ", n_get);
	sayn("ds4sim: OUTPUT reports seen ", n_out);
	sayn("ds4sim: SET_REPORT served ", n_set);

	memset(&ev, 0, sizeof(ev));
	ev.type = UHID_DESTROY;
	wr(&ev);
	_exit(0);
}
