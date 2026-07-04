// Host loopback test for the USB fd-server SCM_RIGHTS handoff.
//
// Proves the exact cmsg layout the real Gutenprint DNP backend relies on:
//   1 data byte in the iov + a SCM_RIGHTS control message of CMSG_LEN(sizeof(int))
//   carrying a single int fd.
//
// No Android, no hardware, no USB. It:
//   - creates an AF_UNIX SOCK_STREAM socketpair (stands in for the app<->backend
//     connection; the real server uses bind/listen/accept but the message layout
//     over the accepted fd is identical),
//   - opens a temp file, writes a marker into it, then rewinds,
//   - "server" side: sends dup(temp_fd) via usbfd_send_one() — the SAME function
//     the FFI's accept loop uses (copied verbatim below to keep this standalone;
//     it must stay byte-for-byte identical to src/printing_ffi.c's usbfd_send_one),
//   - "client" side (mirrors the backend's printing_ffi_recv_fd): recvmsg's the
//     message, extracts the fd from the SCM_RIGHTS cmsg,
//   - reads through the RECEIVED fd and confirms it sees the marker the server
//     wrote — i.e. the received fd refers to the SAME open file description.
//
// Build + run:
//   clang -Wall -Wextra -o /tmp/usb_fd_loopback_test \
//       tool/android/tests/usb_fd_loopback_test.c && /tmp/usb_fd_loopback_test
// Prints "USB FD LOOPBACK TEST: PASS" and exits 0 on success; nonzero on failure.

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 // macOS: no MSG_NOSIGNAL; SO_NOSIGPIPE/ignore is set below
#endif

// ---------------------------------------------------------------------------
// VERBATIM copy of src/printing_ffi.c usbfd_send_one() (Android FFI server side).
// Keep in sync: this is the send half the DNP backend receives. Any change to the
// FFI's cmsg layout must be reflected here so this test still guards it.
// ---------------------------------------------------------------------------
static int usbfd_send_one(int conn_fd, int fd_to_send)
{
    char dummy = 'F'; // >= 1 data byte; the backend reads (and ignores) it
    struct iovec iov;
    iov.iov_base = &dummy;
    iov.iov_len = 1;

    union
    {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } cmsgu;
    memset(&cmsgu, 0, sizeof(cmsgu));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgu.buf;
    msg.msg_controllen = sizeof(cmsgu.buf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd_to_send, sizeof(int));
    msg.msg_controllen = cmsg->cmsg_len;

    ssize_t n;
    do
    {
        n = sendmsg(conn_fd, &msg, MSG_NOSIGNAL);
    } while (n < 0 && errno == EINTR);

    return (n >= 1) ? 0 : -1;
}

// ---------------------------------------------------------------------------
// Mirrors the backend's printing_ffi_recv_fd(): recvmsg once, pull the single fd
// out of the SCM_RIGHTS cmsg. Returns the received fd, or -1.
// ---------------------------------------------------------------------------
static int recv_one_fd(int conn_fd)
{
    char databuf[1];
    struct iovec iov;
    iov.iov_base = databuf;
    iov.iov_len = sizeof(databuf);

    union
    {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } cmsgu;
    memset(&cmsgu, 0, sizeof(cmsgu));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgu.buf;
    msg.msg_controllen = sizeof(cmsgu.buf);

    ssize_t n;
    do
    {
        n = recvmsg(conn_fd, &msg, 0);
    } while (n < 0 && errno == EINTR);

    if (n < 1)
    {
        fprintf(stderr, "recvmsg returned %zd: %s\n", n, strerror(errno));
        return -1;
    }

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg || cmsg->cmsg_len != CMSG_LEN(sizeof(int)) ||
        cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS)
    {
        fprintf(stderr, "no valid SCM_RIGHTS cmsg (cmsg=%p len=%lu expected=%lu)\n",
                (void *)cmsg,
                cmsg ? (unsigned long)cmsg->cmsg_len : 0UL,
                (unsigned long)CMSG_LEN(sizeof(int)));
        return -1;
    }

    int fd = -1;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
    return fd;
}

int main(void)
{
    const char marker[] = "PRINTING_FFI_USB_FD_HANDOFF_OK";

    // macOS has no MSG_NOSIGNAL; ignore SIGPIPE so a send never kills the test.
    signal(SIGPIPE, SIG_IGN);

    // 1) A temp file stands in for the "USB device fd". Write a marker, rewind.
    char tmpl[] = "/tmp/usb_fd_loopback_XXXXXX";
    int src_fd = mkstemp(tmpl);
    if (src_fd < 0)
    {
        perror("mkstemp");
        return 1;
    }
    unlink(tmpl); // keep it out of the fs; the open fd keeps it alive
    if (write(src_fd, marker, sizeof(marker)) != (ssize_t)sizeof(marker))
    {
        perror("write marker");
        return 1;
    }

    // 2) Connection pair (accepted-conn stand-in). Layout over it == real server.
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
    {
        perror("socketpair");
        return 1;
    }

    // 3) SERVER side: send a dup() of the source fd (as the real accept loop does).
    int dup_fd = dup(src_fd);
    if (dup_fd < 0)
    {
        perror("dup");
        return 1;
    }
    if (usbfd_send_one(sv[0], dup_fd) != 0)
    {
        fprintf(stderr, "usbfd_send_one failed: %s\n", strerror(errno));
        return 1;
    }
    close(dup_fd); // server owns the dup; close after send (libusb owns the peer's)

    // 4) CLIENT side: receive the fd.
    int recv_fd = recv_one_fd(sv[1]);
    if (recv_fd < 0)
    {
        fprintf(stderr, "recv_one_fd failed\n");
        return 1;
    }
    // The received fd is a fresh descriptor in this process (the kernel may reuse
    // the numeric slot freed by close(dup_fd) above — that's fine; it's a distinct
    // open file description pointing at the same file, proven by the read/write
    // below). It must differ from src_fd, which is still open here.
    if (recv_fd == src_fd)
    {
        fprintf(stderr, "received fd %d aliases the still-open src fd %d\n", recv_fd, src_fd);
        return 1;
    }

    // 5) Prove the received fd refers to the SAME open file: read from its start
    //    and confirm we see the marker the server wrote.
    if (lseek(recv_fd, 0, SEEK_SET) == (off_t)-1)
    {
        perror("lseek recv_fd");
        return 1;
    }
    char readback[sizeof(marker)] = {0};
    ssize_t r = read(recv_fd, readback, sizeof(readback));
    if (r != (ssize_t)sizeof(marker))
    {
        fprintf(stderr, "short read via received fd: %zd (want %zu)\n", r, sizeof(marker));
        return 1;
    }
    if (memcmp(readback, marker, sizeof(marker)) != 0)
    {
        fprintf(stderr, "marker mismatch: got '%s' want '%s'\n", readback, marker);
        return 1;
    }

    // 6) Bidirectional proof: write through the received fd, read via the source fd.
    const char tail[] = "-BIDIR";
    if (lseek(recv_fd, 0, SEEK_END) == (off_t)-1 ||
        write(recv_fd, tail, sizeof(tail)) != (ssize_t)sizeof(tail))
    {
        perror("write via recv_fd");
        return 1;
    }
    char tailback[sizeof(tail)] = {0};
    if (lseek(src_fd, (off_t)sizeof(marker), SEEK_SET) == (off_t)-1 ||
        read(src_fd, tailback, sizeof(tailback)) != (ssize_t)sizeof(tail) ||
        memcmp(tailback, tail, sizeof(tail)) != 0)
    {
        fprintf(stderr, "bidirectional check failed: got '%s'\n", tailback);
        return 1;
    }

    close(recv_fd);
    close(src_fd);
    close(sv[0]);
    close(sv[1]);

    printf("received fd=%d refers to same open file as source fd=%d\n", recv_fd, src_fd);
    printf("cmsg layout: 1 data byte + CMSG_LEN(sizeof(int))=%lu control bytes\n",
           (unsigned long)CMSG_LEN(sizeof(int)));
    printf("USB FD LOOPBACK TEST: PASS\n");
    return 0;
}
