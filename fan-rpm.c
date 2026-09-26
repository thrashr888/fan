#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Read-only SMC access. The 80-byte request layout is required by AppleSMC.
typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpu, gpu, memory;
} SMCLimits;

typedef struct {
    uint32_t size, type;
    uint8_t attributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimits limits;
    SMCKeyInfo info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCRequest;

_Static_assert(sizeof(SMCRequest) == 80, "unexpected SMC request size");
_Static_assert(offsetof(SMCRequest, bytes) == 48, "unexpected SMC byte offset");

static uint32_t fourcc(const char *name) {
    return ((uint32_t)(uint8_t)name[0] << 24) |
           ((uint32_t)(uint8_t)name[1] << 16) |
           ((uint32_t)(uint8_t)name[2] << 8) |
           (uint8_t)name[3];
}

static int call(io_connect_t connection, SMCRequest *input, SMCRequest *output) {
    size_t size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(
        connection, 2, input, sizeof(*input), output, &size);
    return result == KERN_SUCCESS && size == sizeof(*output) && output->result == 0;
}

static int read_key(io_connect_t connection, const char *name,
                    uint32_t *type, uint8_t *size, uint8_t bytes[32]) {
    SMCRequest input = {0}, output = {0};
    input.key = fourcc(name);
    input.command = 9; // key information
    if (!call(connection, &input, &output) ||
        output.info.size < 1 || output.info.size > 32)
        return 0;

    *type = output.info.type;
    *size = (uint8_t)output.info.size;
    memset(&input, 0, sizeof(input));
    input.key = fourcc(name);
    input.info.size = *size;
    input.command = 5; // read bytes
    if (!call(connection, &input, &output)) return 0;
    memcpy(bytes, output.bytes, *size);
    return 1;
}

int main(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"));
    if (!service) {
        fprintf(stderr, "fan-rpm: SMC service unavailable\n");
        return 1;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS) {
        fprintf(stderr, "fan-rpm: cannot open SMC (0x%x)\n", opened);
        return 1;
    }

    uint32_t type;
    uint8_t size, bytes[32] = {0};
    if (!read_key(connection, "FNum", &type, &size, bytes)) {
        fprintf(stderr, "fan-rpm: fan count unavailable\n");
        IOServiceClose(connection);
        return 1;
    }
    unsigned fans = bytes[0];
    if (fans == 0 || fans > 8) {
        fprintf(stderr, "fan-rpm: unexpected fan count %u\n", fans);
        IOServiceClose(connection);
        return 1;
    }

    for (unsigned i = 0; i < fans; i++) {
        char key[5];
        snprintf(key, sizeof(key), "F%uAc", i);
        memset(bytes, 0, sizeof(bytes));
        if (!read_key(connection, key, &type, &size, bytes)) {
            fprintf(stderr, "fan-rpm: %s unavailable\n", key);
            IOServiceClose(connection);
            return 1;
        }
        double rpm;
        if (type == fourcc("flt ") && size == 4) {
            float value;
            memcpy(&value, bytes, sizeof(value));
            rpm = value;
        } else if (type == fourcc("fpe2") && size == 2) {
            rpm = (double)(((unsigned)bytes[0] << 8) | bytes[1]) / 4.0;
        } else {
            fprintf(stderr, "fan-rpm: unsupported %s value type\n", key);
            IOServiceClose(connection);
            return 1;
        }
        if (!isfinite(rpm) || rpm < 0 || rpm > 15000) {
            fprintf(stderr, "fan-rpm: implausible %s reading\n", key);
            IOServiceClose(connection);
            return 1;
        }
        printf("%u\t%.0f\n", i, rpm);
    }
    IOServiceClose(connection);
    return 0;
}
