/* MIT licence, FanaMac.
 *
 * Hides the CSL DD's second input report from the programs that list its axes.
 *
 * The base declares report 0x02 (eight more 16-bit axes, four dials) and never
 * sends it. SDL2 therefore lists 20 axes, each real one followed by its unused
 * twins, and Wine's joystick bus keeps only the first eight: the brake and the
 * handbrake never reach a CrossOver game.
 *
 * FanaMac names this plug-in as the base's HID device plug-in (see FanaMac's
 * NativeForce.swift). It wraps macOS's own one and passes everything through,
 * except the list of elements: report 0x02's elements and the collections are
 * left out. The collections have to go too, because SDL walks into them and
 * would find the hidden elements again. Inputs, queues and output reports are
 * still macOS's own code.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hid/IOHIDDevicePlugIn.h>
#include <IOKit/hid/IOHIDElement.h>

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define APPLE_PLUGIN "/System/Library/Extensions/IOHIDFamily.kext/Contents/PlugIns/IOHIDLib.plugin"
#define HIDDEN_REPORT 2

typedef struct {
    IOCFPlugInInterface *plugin;            /* must come first: this is the IUnknown */
    IOHIDDeviceDeviceInterface *device;
    UInt32 refs;
    CFUUIDRef factory;
    CFPlugInRef apple;
    IOCFPlugInInterface **real;
    IOHIDDeviceDeviceInterface **real_device;
} filter;

static filter *of_plugin(void *p) { return p; }
static filter *of_device(void *p) { return (filter *)((char *)p - offsetof(filter, device)); }

static int same(REFIID iid, CFUUIDRef uuid)
{
    CFUUIDBytes b = CFUUIDGetUUIDBytes(uuid);
    return memcmp(&iid, &b, sizeof b) == 0;
}

static HRESULT query(filter *f, REFIID iid, LPVOID *out)
{
    if (same(iid, IUnknownUUID) || same(iid, kIOCFPlugInInterfaceID)) {
        *out = &f->plugin;
        f->refs++;
        return S_OK;
    }
    if (same(iid, kIOHIDDeviceDeviceInterfaceID)) {
        if (!f->real_device && (*f->real)->QueryInterface(f->real, iid, (LPVOID *)&f->real_device) != S_OK) {
            *out = NULL;
            return E_NOINTERFACE;
        }
        *out = &f->device;
        f->refs++;
        return S_OK;
    }
    /* Queues, transactions, time stamps: macOS's own objects. */
    return (*f->real)->QueryInterface(f->real, iid, out);
}

static ULONG retain_filter(filter *f) { return ++f->refs; }

static ULONG release_filter(filter *f)
{
    if (--f->refs) return f->refs;
    if (f->real_device) (*f->real_device)->Release(f->real_device);
    (*f->real)->Release(f->real);
    CFRelease(f->apple);
    CFPlugInRemoveInstanceForFactory(f->factory);
    CFRelease(f->factory);
    free(f);
    return 0;
}

/* IOCFPlugInInterface */
static HRESULT p_query(void *p, REFIID iid, LPVOID *out) { return query(of_plugin(p), iid, out); }
static ULONG p_retain(void *p) { return retain_filter(of_plugin(p)); }
static ULONG p_release(void *p) { return release_filter(of_plugin(p)); }

static IOReturn p_probe(void *p, CFDictionaryRef props, io_service_t service, SInt32 *order)
{
    filter *f = of_plugin(p);
    return (*f->real)->Probe(f->real, props, service, order);
}

static IOReturn p_start(void *p, CFDictionaryRef props, io_service_t service)
{
    filter *f = of_plugin(p);
    return (*f->real)->Start(f->real, props, service);
}

static IOReturn p_stop(void *p)
{
    filter *f = of_plugin(p);
    return (*f->real)->Stop(f->real);
}

static IOCFPlugInInterface plugin_vt = {
    NULL, p_query, p_retain, p_release, 1, 0, p_probe, p_start, p_stop
};

/* IOHIDDeviceDeviceInterface */
#define REAL(f) (*(f)->real_device)

static HRESULT d_query(void *p, REFIID iid, LPVOID *out) { return query(of_device(p), iid, out); }
static ULONG d_retain(void *p) { return retain_filter(of_device(p)); }
static ULONG d_release(void *p) { return release_filter(of_device(p)); }

static IOReturn d_open(void *p, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->open(f->real_device, options);
}

static IOReturn d_close(void *p, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->close(f->real_device, options);
}

static IOReturn d_get_property(void *p, CFStringRef key, CFTypeRef *value)
{
    filter *f = of_device(p);
    return REAL(f)->getProperty(f->real_device, key, value);
}

static IOReturn d_set_property(void *p, CFStringRef key, CFTypeRef value)
{
    filter *f = of_device(p);
    return REAL(f)->setProperty(f->real_device, key, value);
}

static IOReturn d_event_source(void *p, CFTypeRef *source)
{
    filter *f = of_device(p);
    return REAL(f)->getAsyncEventSource(f->real_device, source);
}

/* The one call that does something of its own. */
static IOReturn d_copy_elements(void *p, CFDictionaryRef match, CFArrayRef *out, IOOptionBits options)
{
    filter *f = of_device(p);
    if (!out) return REAL(f)->copyMatchingElements(f->real_device, match, out, options);
    CFArrayRef all = NULL;
    IOReturn result = REAL(f)->copyMatchingElements(f->real_device, match, &all, options);
    if (result != kIOReturnSuccess || !all) {
        *out = all;
        return result;
    }
    CFMutableArrayRef kept = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(all, i);
        if (IOHIDElementGetReportID(e) != HIDDEN_REPORT && IOHIDElementGetType(e) != kIOHIDElementTypeCollection)
            CFArrayAppendValue(kept, e);
    }
    CFRelease(all);
    *out = kept;
    return result;
}

static IOReturn d_set_value(void *p, IOHIDElementRef e, IOHIDValueRef value, uint32_t timeout,
                            IOHIDValueCallback callback, void *context, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->setValue(f->real_device, e, value, timeout, callback, context, options);
}

static IOReturn d_get_value(void *p, IOHIDElementRef e, IOHIDValueRef *value, uint32_t timeout,
                            IOHIDValueCallback callback, void *context, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->getValue(f->real_device, e, value, timeout, callback, context, options);
}

static IOReturn d_input_callback(void *p, uint8_t *report, CFIndex length,
                                 IOHIDReportCallback callback, void *context, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->setInputReportCallback(f->real_device, report, length, callback, context, options);
}

static IOReturn d_set_report(void *p, IOHIDReportType type, uint32_t id, const uint8_t *report, CFIndex length,
                             uint32_t timeout, IOHIDReportCallback callback, void *context, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->setReport(f->real_device, type, id, report, length, timeout, callback, context, options);
}

static IOReturn d_get_report(void *p, IOHIDReportType type, uint32_t id, uint8_t *report, CFIndex *length,
                             uint32_t timeout, IOHIDReportCallback callback, void *context, IOOptionBits options)
{
    filter *f = of_device(p);
    return REAL(f)->getReport(f->real_device, type, id, report, length, timeout, callback, context, options);
}

static IOHIDDeviceDeviceInterface device_vt = {
    NULL, d_query, d_retain, d_release, d_open, d_close, d_get_property, d_set_property, d_event_source,
    d_copy_elements, d_set_value, d_get_value, d_input_callback, d_set_report, d_get_report
};

/* A new instance of macOS's plug-in, or NULL. */
static IOCFPlugInInterface **apple_instance(CFPlugInRef apple, CFUUIDRef type)
{
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(type, apple);
    if (!factories) return NULL;
    IUnknownVTbl **unknown = NULL;
    if (CFArrayGetCount(factories) > 0)
        unknown = CFPlugInInstanceCreate(kCFAllocatorDefault, (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0), type);
    CFRelease(factories);
    if (!unknown) return NULL;
    IOCFPlugInInterface **real = NULL;
    HRESULT result = (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kIOCFPlugInInterfaceID), (LPVOID *)&real);
    (*unknown)->Release(unknown);
    return result == S_OK ? real : NULL;
}

/* Factory named in Info.plist. */
void *FanaMacHIDFilterFactory(CFAllocatorRef alloc, CFUUIDRef type)
{
    (void)alloc;
    if (!CFEqual(type, kIOHIDDeviceTypeID)) return NULL;

    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR(APPLE_PLUGIN), kCFURLPOSIXPathStyle, true);
    CFPlugInRef apple = CFPlugInCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!apple) return NULL;

    IOCFPlugInInterface **real = apple_instance(apple, type);
    filter *f = real ? calloc(1, sizeof *f) : NULL;
    if (!f) {
        if (real) (*real)->Release(real);
        CFRelease(apple);
        return NULL;
    }
    f->plugin = &plugin_vt;
    f->device = &device_vt;
    f->refs = 1;
    f->apple = apple;
    f->real = real;
    f->factory = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("23B1088A-E68E-47C3-A0CA-F73740D96BA4"));
    CFPlugInAddInstanceForFactory(f->factory);
    return f;
}
