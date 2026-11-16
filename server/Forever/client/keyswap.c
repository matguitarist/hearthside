// keyswap: loaded into Hearthside's copy of the Forever client (DYLD_INSERT_LIBRARIES), it puts the
// home server's public key into the client's table of Blizzard realm keys.
//
// When a world server says "enter encrypted mode", the client checks the packet's Ed25519 signature
// with the key of the region group the packet names; TrinityCore signs with its own key and names
// group 8. The keys are not in the executable: the client builds the table on the heap at start.
// It is 12 entries of 40 bytes: a u32 id (1 to 12), the 32-byte key, a u8 flag, 3 bytes of padding.
// A thread here finds the table by its first key, checks the ids, and writes the server's key over
// group 8's, again whenever the table is made anew. The official app's hardened runtime forbids
// writing another process's memory, so this runs inside the game.
//
// It also keeps the copy off Blizzard's login servers: every lookup of a *.actual.battle.net name
// (us., eu., trinity. and the rest), through getaddrinfo, DNS-SD or the Network framework, is sent
// to the home server, in this process only; every other name it looks up is written to the log. The client can reset its portal to its region ("US") on a first start; with this, a portal
// reset still lands on the home server, whose certificate covers *.actual.battle.net, and a modified
// client never logs on to Blizzard. Battle.net's app and the original game are not touched.
//
// The login connection's certificate is checked against the game's own roots, not the system's
// (SecTrustSetAnchorCertificates): the home server's certificate authority, which can only vouch for
// actual.battle.net names, is added to those roots, and each trust decision is written to the log.
//
// Environment: KEYSWAP_KEY (64 hex digits: the server's key), KEYSWAP_GROUP (default 8),
// KEYSWAP_LOGIN (the home server's address, for the login names), KEYSWAP_CA (the home server's
// certificate authority, a DER file), KEYSWAP_LOG (a file for what it does; default stderr).

#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netdb.h>
#include <Network/Network.h>
#include <strings.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { ENTRIES = 12, STRIDE = 40, TABLE = ENTRIES * STRIDE, WINDOW = 4 << 20 };

// The first entry's key, Blizzard's region group 1: the table's signature in memory.
static const char FIRST_KEY[] = "9B0671C815DFF513BFD4A2B26AE1F84EC9106841B2FB620DB65F6ADE7C21AD06";

static uint8_t first[32], server[32];
static int group = 8;
static FILE *out;
static const char *login_address;
static SecCertificateRef home_authority; // the home server's login CA, from KEYSWAP_CA (DER)
static uint8_t *buffer;

static void note(const char *format, ...) {
    if (!out) out = stderr;
    va_list args;
    va_start(args, format);
    fprintf(out, "keyswap: ");
    vfprintf(out, format, args);
    fputc('\n', out);
    fflush(out);
    va_end(args);
}

static int parse_key(const char *hex, uint8_t key[32]) {
    if (!hex || strlen(hex) != 64) return 0;
    for (int i = 0; i < 32; i++) {
        unsigned byte;
        if (sscanf(hex + 2 * i, "%2x", &byte) != 1) return 0;
        key[i] = (uint8_t)byte;
    }
    return 1;
}

// Memory read without faulting, should the region go away meanwhile.
static int peek(mach_vm_address_t at, void *into, mach_vm_size_t length) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), at, length, (mach_vm_address_t)into, &got) == KERN_SUCCESS &&
           got == length;
}

// Whether a table starts there: ids 1 to 12 in order, group 1's key, zero padding.
static int is_table(mach_vm_address_t at) {
    uint8_t raw[TABLE];
    if (!peek(at, raw, TABLE)) return 0;
    if (memcmp(raw + 4, first, 32) != 0) return 0;
    for (int i = 0; i < ENTRIES; i++) {
        uint32_t id;
        memcpy(&id, raw + i * STRIDE, 4);
        if (id != (uint32_t)i + 1 || raw[i * STRIDE + 38] || raw[i * STRIDE + 39]) return 0;
    }
    return 1;
}

// The writable regions' tables, but for our own buffer. Returns how many (at most `room` kept).
static int find_tables(mach_vm_address_t *found, int room) {
    int count = 0;
    for (mach_vm_address_t at = 0;;) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object;
        if (mach_vm_region(mach_task_self(), &at, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                           &info_count, &object) != KERN_SUCCESS)
            break;
        int writable = (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE);
        int ours = at <= (mach_vm_address_t)buffer && (mach_vm_address_t)buffer < at + size;
        for (mach_vm_address_t from = at; writable && !ours && from < at + size;) {
            mach_vm_size_t take = at + size - from < WINDOW ? at + size - from : WINDOW;
            if (!peek(from, buffer, take)) break;
            for (uint8_t *hit = buffer; (hit = memmem(hit, take - (hit - buffer), first, 32)); hit++) {
                mach_vm_address_t start = from + (hit - buffer) - 4;
                if (start % 4 == 0 && is_table(start)) {
                    if (count < room) found[count] = start;
                    count++;
                }
            }
            if (take < WINDOW) break;
            from += WINDOW - 32; // overlapping, for a key across two windows
        }
        at += size;
    }
    return count;
}

static uint8_t *group_key(mach_vm_address_t table) { return (uint8_t *)table + (group - 1) * STRIDE + 4; }

static void *watch(void *unused) {
    (void)unused;
    mach_vm_address_t table = 0;
    int waiting = 0;
    note("loaded in %d, group %d", getpid(), group);
    for (;;) {
        if (table) {
            uint8_t now[32];
            if (!is_table(table) || !peek((mach_vm_address_t)group_key(table), now, 32)) {
                note("the key table is gone: looking again");
                table = 0;
            } else if (memcmp(now, server, 32) != 0) {
                memcpy(group_key(table), server, 32);
                note("server key written again");
            }
            usleep(500 * 1000);
            continue;
        }
        mach_vm_address_t found[4];
        int count = find_tables(found, 4);
        if (count == 1) {
            table = found[0];
            memcpy(group_key(table), server, 32);
            note("server key written at 0x%llx", (unsigned long long)table);
        } else {
            if (count > 1) note("%d key tables at once: waiting", count);
            else if (!waiting) note("waiting for the key table");
            waiting = 1;
            usleep(300 * 1000);
        }
    }
    return NULL;
}

// Whether a name is one of Battle.net's login names: *.actual.battle.net, any case.
static int is_login_name(const char *name) {
    static const char suffix[] = ".actual.battle.net";
    size_t length = name ? strlen(name) : 0, tail = sizeof suffix - 1;
    return length > tail && strcasecmp(name + length - tail, suffix) == 0;
}

// The name a lookup goes to: a login name becomes trinity.actual.battle.net, which /etc/hosts maps to
// the home server (the game takes an answer for a name, not one made from a bare address), or a
// name that cannot resolve when no KEYSWAP_LOGIN was given; never Blizzard. Every name is noted, so what
// the copy reaches can be checked.
static const char *route(const char *name, const char *how) {
    // KEYSWAP_LOGIN_NAME: another name for the login names to resolve to (a relay on loopback: "localhost").
    const char *home = getenv("KEYSWAP_LOGIN_NAME") ? getenv("KEYSWAP_LOGIN_NAME") : "trinity.actual.battle.net";
    if (!name) return name;
    if (!is_login_name(name) || strcasecmp(name, home) == 0) {
        note("%s: %s", how, name);
        return name;
    }
    const char *to = login_address ? home : "unreachable.invalid";
    note("%s: %s -> %s", how, name, to);
    return to;
}

// Inside this library the functions below are the real ones: interposing applies to the game only.
static int routed_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                              struct addrinfo **result) {
    const char *to = route(node, "getaddrinfo");
    int status = getaddrinfo(to, service, hints, result);
    if (to && (is_login_name(to) || is_login_name(node))) {
        char found[256] = "";
        for (struct addrinfo *a = status == 0 ? *result : NULL; a; a = a->ai_next) {
            char text[INET6_ADDRSTRLEN] = "?";
            if (a->ai_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)a->ai_addr)->sin_addr, text, sizeof text);
            if (a->ai_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ai_addr)->sin6_addr, text, sizeof text);
            size_t used = strlen(found);
            snprintf(found + used, sizeof found - used, " %s/%d", text, a->ai_socktype);
        }
        note("getaddrinfo %s service %s family %d socktype %d flags 0x%x: %s%s", to, service ? service : "-",
             hints ? hints->ai_family : -1, hints ? hints->ai_socktype : -1, hints ? hints->ai_flags : -1,
             status == 0 ? "ok" : gai_strerror(status), found);
    }
    return status;
}

static DNSServiceErrorType routed_DNSServiceGetAddrInfo(DNSServiceRef *ref, DNSServiceFlags flags, uint32_t interface,
                                                        DNSServiceProtocol protocol, const char *host,
                                                        DNSServiceGetAddrInfoReply reply, void *context) {
    return DNSServiceGetAddrInfo(ref, flags, interface, protocol, route(host, "dnssd"), reply, context);
}

static nw_endpoint_t routed_nw_endpoint_create_host(const char *host, const char *port) {
    return nw_endpoint_create_host(route(host, "network"), port);
}

// connect, noted with its result for every IPv4 or IPv6 address: what the copy reaches and why a
// connection fails (macOS refuses a LAN address to an app without Local Network access, for one).
static int noted_connect(int socket, const struct sockaddr *address, socklen_t length) {
    int result = connect(socket, address, length), saved = errno;
    char text[INET6_ADDRSTRLEN] = "?";
    int port = 0;
    if (address && address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        inet_ntop(AF_INET, &v4->sin_addr, text, sizeof text);
        port = ntohs(v4->sin_port);
    } else if (address && address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        inet_ntop(AF_INET6, &v6->sin6_addr, text, sizeof text);
        port = ntohs(v6->sin6_port);
    }
    if (address && (address->sa_family == AF_INET || address->sa_family == AF_INET6))
        note("connect %s port %d: %s", text, port, result == 0 ? "ok" : saved == EINPROGRESS ? "in progress" : strerror(saved));
    errno = saved;
    return result;
}

// Sockets opened, and sends to the home server: a login over UDP (QUIC) never calls connect.
static int noted_socket(int domain, int type, int protocol) {
    int result = socket(domain, type, protocol), saved = errno;
    if (domain == AF_INET || domain == AF_INET6)
        note("socket %s %s: %d%s%s", domain == AF_INET ? "ipv4" : "ipv6",
             (type & 0xff) == SOCK_STREAM ? "tcp" : (type & 0xff) == SOCK_DGRAM ? "udp" : "other", result,
             result < 0 ? " " : "", result < 0 ? strerror(saved) : "");
    errno = saved;
    return result;
}

static int is_home(const struct sockaddr *to) {
    if (!to || !login_address) return 0;
    char text[INET6_ADDRSTRLEN] = "";
    if (to->sa_family == AF_INET) inet_ntop(AF_INET, &((const struct sockaddr_in *)to)->sin_addr, text, sizeof text);
    return strcmp(text, login_address) == 0;
}

static ssize_t noted_sendto(int socket, const void *buffer, size_t length, int flags, const struct sockaddr *to,
                            socklen_t size) {
    ssize_t result = sendto(socket, buffer, length, flags, to, size);
    int saved = errno;
    if (is_home(to)) note("sendto home port %d: %s", ntohs(((const struct sockaddr_in *)to)->sin_port),
                          result >= 0 ? "ok" : strerror(saved));
    errno = saved;
    return result;
}

static ssize_t noted_sendmsg(int socket, const struct msghdr *message, int flags) {
    ssize_t result = sendmsg(socket, message, flags);
    int saved = errno;
    const struct sockaddr *to = message ? (const struct sockaddr *)message->msg_name : NULL;
    if (is_home(to)) note("sendmsg home port %d: %s", ntohs(((const struct sockaddr_in *)to)->sin_port),
                          result >= 0 ? "ok" : strerror(saved));
    errno = saved;
    return result;
}

static int noted_connectx(int socket, const sa_endpoints_t *endpoints, sae_associd_t association,
                          unsigned int flags, const struct iovec *io, unsigned int count, size_t *sent,
                          sae_connid_t *connection) {
    int result = connectx(socket, endpoints, association, flags, io, count, sent, connection), saved = errno;
    char text[INET6_ADDRSTRLEN] = "?";
    const struct sockaddr *to = endpoints ? endpoints->sae_dstaddr : NULL;
    if (to && to->sa_family == AF_INET) inet_ntop(AF_INET, &((const struct sockaddr_in *)to)->sin_addr, text, sizeof text);
    if (to && to->sa_family == AF_INET6) inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)to)->sin6_addr, text, sizeof text);
    note("connectx %s: %s", text, result == 0 ? "ok" : saved == EINPROGRESS ? "in progress" : strerror(saved));
    errno = saved;
    return result;
}

// The game's roots, and ours.
static OSStatus anchored_SecTrustSetAnchorCertificates(SecTrustRef trust, CFArrayRef anchors) {
    if (!home_authority) return SecTrustSetAnchorCertificates(trust, anchors);
    CFMutableArrayRef all = anchors ? CFArrayCreateMutableCopy(NULL, 0, anchors)
                                    : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(all, home_authority);
    OSStatus status = SecTrustSetAnchorCertificates(trust, all);
    note("trust: %ld roots of the game's, and the home server's", anchors ? (long)CFArrayGetCount(anchors) : 0L);
    CFRelease(all);
    return status;
}

static void note_trust(SecTrustRef trust, int trusted, CFErrorRef error) {
    char name[256] = "?", why[512] = "";
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    SecCertificateRef leaf = chain && CFArrayGetCount(chain) > 0 ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0) : NULL;
    CFStringRef common = NULL;
    if (leaf && SecCertificateCopyCommonName(leaf, &common) == errSecSuccess && common) {
        CFStringGetCString(common, name, sizeof name, kCFStringEncodingUTF8);
        CFRelease(common);
    }
    if (chain) CFRelease(chain);
    if (error) {
        CFStringRef text = CFErrorCopyDescription(error);
        if (text) {
            CFStringGetCString(text, why, sizeof why, kCFStringEncodingUTF8);
            CFRelease(text);
        }
    }
    note("trust %s: %s%s%s", name, trusted ? "trusted" : "refused", *why ? ": " : "", why);
}

static bool noted_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    CFErrorRef own = NULL;
    bool trusted = SecTrustEvaluateWithError(trust, &own);
    note_trust(trust, trusted, own);
    if (error) *error = own;
    else if (own) CFRelease(own);
    return trusted;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus noted_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    OSStatus status = SecTrustEvaluate(trust, result);
    int trusted = status == errSecSuccess && result &&
                  (*result == kSecTrustResultProceed || *result == kSecTrustResultUnspecified);
    note_trust(trust, trusted, NULL);
    return status;
}
#pragma clang diagnostic pop

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
__attribute__((used)) static const struct {
    const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)routed_getaddrinfo, (const void *)getaddrinfo},
    {(const void *)routed_DNSServiceGetAddrInfo, (const void *)DNSServiceGetAddrInfo},
    {(const void *)routed_nw_endpoint_create_host, (const void *)nw_endpoint_create_host},
    {(const void *)noted_connect, (const void *)connect},
    {(const void *)noted_connectx, (const void *)connectx},
    {(const void *)noted_socket, (const void *)socket},
    {(const void *)noted_sendto, (const void *)sendto},
    {(const void *)noted_sendmsg, (const void *)sendmsg},
    {(const void *)anchored_SecTrustSetAnchorCertificates, (const void *)SecTrustSetAnchorCertificates},
    {(const void *)noted_SecTrustEvaluateWithError, (const void *)SecTrustEvaluateWithError},
    {(const void *)noted_SecTrustEvaluate, (const void *)SecTrustEvaluate},
};
#pragma clang diagnostic pop

__attribute__((constructor)) static void start(void) {
    const char *log = getenv("KEYSWAP_LOG");
    out = log ? fopen(log, "a") : NULL;
    if (!out) out = stderr;
    login_address = getenv("KEYSWAP_LOGIN");
    const char *authority = getenv("KEYSWAP_CA");
    FILE *der = authority ? fopen(authority, "rb") : NULL;
    if (der) {
        uint8_t bytes[8192];
        size_t length = fread(bytes, 1, sizeof bytes, der);
        fclose(der);
        CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)length);
        home_authority = data ? SecCertificateCreateWithData(NULL, data) : NULL;
        if (data) CFRelease(data);
    }
    note(home_authority ? "the home server's certificate authority is loaded" : "no KEYSWAP_CA: the game's roots only");
    // The game's helpers must not load it too.
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char *g = getenv("KEYSWAP_GROUP");
    if (g) group = atoi(g);
    if (!parse_key(FIRST_KEY, first) || !parse_key(getenv("KEYSWAP_KEY"), server) || group < 2 || group > ENTRIES) {
        note("no valid KEYSWAP_KEY or KEYSWAP_GROUP: nothing done");
        return;
    }
    buffer = malloc(WINDOW);
    pthread_t thread;
    if (!buffer || pthread_create(&thread, NULL, watch, NULL) != 0) {
        note("could not start");
        return;
    }
    pthread_detach(thread);
}
