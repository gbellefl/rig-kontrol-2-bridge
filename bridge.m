#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdatomic.h>
#include <unistd.h>

enum { FootswitchCount = 6, ExpressionCC = 27, MinimumPedalSpan = 32 };
static NSString *const PedalCalibrationKey = @"ExpressionPedalCalibration";

static int pedalMIDIValue(int raw, int heel, int toe)
{
    const double position = (double)(raw - heel) / (toe - heel);
    // Give each calibrated endpoint a small dead zone for mechanical play.
    if (position <= 0.01)
        return 0;
    if (position >= 0.99)
        return 127;
    return (int)lround(127 * (position - 0.01) / 0.98);
}

static int expressionSample(NSData *reply)
{
    const uint8_t *bytes = reply.bytes;
    // The built-in pedal is ABS_X, the third big-endian analog word on RK2.
    if (reply.length < 7 || bytes[0] != 0x03)
        return -1;
    const int value = (bytes[5] << 8) | bytes[6];
    return value <= 4096 ? value : -1;
}

// Rig Kontrol 2 uses vendor 0x17cc, product 0x1969. Its control protocol is
// documented by the Linux snd-usb-caiaq device.c, device.h, and input.c files.
static io_service_t controlInterface(io_service_t device)
{
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) != KERN_SUCCESS)
        return IO_OBJECT_NULL;
    io_service_t match = IO_OBJECT_NULL;
    io_service_t child;
    while ((child = IOIteratorNext(children)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
            CFTypeRef number = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceNumber"),
                                                               kCFAllocatorDefault, 0);
            if (number != NULL) {
                const BOOL isControl = [(__bridge NSNumber *)number intValue] == 0;
                CFRelease(number);
                if (isControl) {
                    match = child;
                    break;
                }
            }
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    return match;
}

static BOOL writeCommand(IOUSBHostPipe *pipe, const uint8_t *bytes, NSUInteger count, NSError **error)
{
    NSUInteger sent = 0;
    NSMutableData *message = [NSMutableData dataWithBytes:bytes length:count];
    return [pipe sendIORequestWithData:message bytesTransferred:&sent completionTimeout:1.0 error:error]
           && sent == count;
}

static NSString *failure(NSString *step, NSError *error)
{
    if (error == nil)
        return step;
    return [NSString stringWithFormat:@"%@ (0x%08x)", step, (unsigned int)error.code];
}

static NSData *exchangeCommand(IOUSBHostPipe *reader, IOUSBHostPipe *writer,
                               const uint8_t *command, NSUInteger length,
                               NSTimeInterval timeout, NSError **error)
{
    NSMutableData *reply = [NSMutableData dataWithLength:64];
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block IOReturn status = kIOReturnError;
    __block NSUInteger count = 0;
    if (![reader enqueueIORequestWithData:reply completionTimeout:timeout error:error
          completionHandler:^(IOReturn result, NSUInteger bytes) {
              status = result;
              count = bytes;
              dispatch_semaphore_signal(received);
          }])
        return nil;
    if (!writeCommand(writer, command, length, error)) {
        [reader abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        return nil;
    }
    const int64_t wait = (int64_t)((timeout + 0.15) * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, wait)) != 0) {
        [reader abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        if (error != NULL)
            *error = [NSError errorWithDomain:NSMachErrorDomain code:kIOReturnTimeout userInfo:nil];
        return nil;
    }
    if (status != kIOReturnSuccess) {
        if (error != NULL)
            *error = [NSError errorWithDomain:NSMachErrorDomain code:status userInfo:nil];
        return nil;
    }
    for (unsigned discarded = 0; ; ++discarded) {
        const uint8_t *bytes = reply.bytes;
        if (count > 0 && bytes[0] == command[0]) {
            [reply setLength:count];
            return reply;
        }
        if (discarded == 2)
            return nil;
        // Recover from a stale reply without sending another command.
        NSUInteger nextCount = 0;
        if (![reader sendIORequestWithData:reply bytesTransferred:&nextCount
                       completionTimeout:timeout error:error])
            return nil;
        count = nextCount;
    }
}

static NSData *request(IOUSBHostPipe *reader, IOUSBHostPipe *writer,
                       uint8_t command, NSTimeInterval timeout, NSError **error)
{
    return exchangeCommand(reader, writer, &command, sizeof(command), timeout, error);
}

static BOOL writeFootswitchLEDs(IOUSBHostPipe *reader, IOUSBHostPipe *writer, unsigned switchMask)
{
    uint8_t ledBits = 0;
    // RK2 WRITE_IO orders footswitch LEDs 1 through 6 from bit 5 to bit 0.
    for (unsigned index = 0; index < FootswitchCount; ++index)
        ledBits |= ((switchMask >> index) & 1u) << (FootswitchCount - 1 - index);
    const uint8_t report[] = {0x05, ledBits, 0, 0};
    // Read the one-byte WRITE_IO acknowledgment before the next input command.
    return exchangeCommand(reader, writer, report, sizeof(report), 0.15, nil) != nil;
}

static NSString *runControlInput(atomic_bool *stop, const atomic_uchar *footswitchLEDs,
                                 void (^ready)(void), void (^ledStatus)(BOOL),
                                 void (^press)(unsigned switchIndex), void (^pedal)(int raw))
{
    CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@0x17cc
        productID:@0x1969 bcdDevice:nil deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil
        productIDArray:nil];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service)
        return @"Rig Kontrol 2 is missing from USB.";

    NSError *error = nil;
    io_service_t control = controlInterface(service);
    if (!control) {
        IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service
            options:IOUSBHostObjectInitOptionsNone queue:nil error:&error interestHandler:nil];
        if (!device) {
            IOObjectRelease(service);
            return failure(@"USB detected. Opening the device was denied or failed", error);
        }

        const IOUSBConfigurationDescriptor *configuration = [device configurationDescriptorWithIndex:0 error:&error];
        const BOOL configured = configuration && [device configureWithValue:configuration->bConfigurationValue
            matchInterfaces:YES error:&error];
        if (configured) {
            for (int attempt = 0; attempt < 25 && !control; ++attempt) {
                usleep(40000);
                control = controlInterface(service);
            }
        }
        [device destroy];
        if (!configured) {
            IOObjectRelease(service);
            return failure(@"Unable to configure USB", error);
        }
    }

    IOObjectRelease(service);
    if (!control)
        return @"USB configuration did not expose the control interface.";

    IOUSBHostInterface *interface = [[IOUSBHostInterface alloc] initWithIOService:control
        options:IOUSBHostObjectInitOptionsNone queue:nil error:&error interestHandler:nil];
    IOObjectRelease(control);
    if (!interface)
        return failure(@"Unable to open the control interface", error);
    if (![interface selectAlternateSetting:1 error:&error]) {
        [interface destroy];
        return failure(@"Unable to select the control setting", error);
    }

    IOUSBHostPipe *reader = [interface copyPipeWithAddress:0x81 error:&error];
    IOUSBHostPipe *writer = reader ? [interface copyPipeWithAddress:0x01 error:&error] : nil;
    NSString *result = nil;
    if (writer == nil)
        result = failure(@"Open the USB command pipes", error);
    else if (!request(reader, writer, 0x01, 0.45, &error))
        result = failure(@"Read the device information", error);
    else {
        BOOL haveSwitchState = NO;
        BOOL ledWriteFailed = NO;
        int sentLEDs = -1;
        unsigned ledBackoff = 0;
        unsigned previous = 0;
        unsigned misses = 0;
        unsigned analogMisses = 0;
        unsigned analogBackoff = 0;
        int samples[3] = {-1, -1, -1};
        int reported = -1;
        while (!atomic_load(stop)) {
            @autoreleasepool {
                NSError *readError = nil;
                NSData *reply = request(reader, writer, 0x04, 0.45, &readError);
                const uint8_t *bytes = reply.bytes;
                if (reply.length < 2 || bytes[0] != 0x04) {
                    if (++misses == 5) {
                        result = failure(@"Poll footswitch state", readError);
                        break;
                    }
                    usleep(50000);
                    continue;
                }
                misses = 0;
                const unsigned current = (~bytes[1]) & 0x7fu;
                if (!haveSwitchState) {
                    haveSwitchState = YES;
                    ready();
                } else {
                    const unsigned rising = current & ~previous;
                    for (unsigned bit = 0; bit < 7; ++bit)
                        if (rising & (1u << bit))
                            press(bit);
                }
                previous = current;

                const uint8_t desiredLEDs = atomic_load(footswitchLEDs);
                if (ledBackoff > 0) {
                    --ledBackoff;
                } else if (sentLEDs != desiredLEDs) {
                    const BOOL written = writeFootswitchLEDs(reader, writer, desiredLEDs);
                    if (written) {
                        sentLEDs = desiredLEDs;
                    } else {
                        ledBackoff = 20;
                        sentLEDs = -1;
                    }
                    if (ledWriteFailed != !written) {
                        ledWriteFailed = !written;
                        ledStatus(written);
                    }
                }

                if (analogBackoff > 0) {
                    --analogBackoff;
                } else {
                    const int raw = expressionSample(request(reader, writer, 0x03, 0.055, nil));
                    if (raw >= 0) {
                        analogMisses = 0;
                        if (samples[0] < 0)
                            samples[0] = samples[1] = raw;
                        samples[2] = raw;
                        const int filtered = MAX(MIN(samples[0], samples[1]),
                                                 MIN(MAX(samples[0], samples[1]), samples[2]));
                        samples[0] = samples[1];
                        samples[1] = samples[2];
                        if (filtered != reported) {
                            reported = filtered;
                            pedal(filtered);
                        }
                    } else if (++analogMisses >= 3) {
                        // An unavailable analog input must not slow down the footswitches.
                        samples[0] = -1;
                        analogBackoff = 40;
                        if (analogMisses == 3)
                            pedal(-1);
                        reported = -1;
                    }
                }
                usleep(25000);
            }
        }
        if (haveSwitchState && sentLEDs != 0 && atomic_load(stop))
            (void)writeFootswitchLEDs(reader, writer, 0);
    }

    [interface selectAlternateSetting:0 error:nil];
    [interface destroy];
    return result ?: @"Disconnected.";
}

@interface Bridge : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation Bridge {
    NSWindow *_window;
    NSTextField *_status;
    NSTextField *_lastEvent;
    NSButton *_connect;
    NSTextField *_pedalStatus;
    NSProgressIndicator *_pedalLevel;
    NSButton *_setHeel;
    NSButton *_setToe;
    NSButton *_cancelCalibration;
    NSImageView *_switchLights[FootswitchCount];
    NSTextField *_switchValues[FootswitchCount];
    MIDIClientRef _client;
    MIDIEndpointRef _source;
    atomic_bool _stop;
    atomic_uchar _footswitchLEDs;
    BOOL _running;
    BOOL _quitting;
    BOOL _toggles[7];
    int _pedalRaw;
    int _heel;
    int _toe;
    int _pendingHeel;
    int _lastPedalValue;
    BOOL _heelTooClose;
    BOOL _pedalUnavailable;
}

- (void)showValue:(UInt32)value forSwitch:(unsigned)index
{
    const BOOL on = value == 127;
    _switchLights[index].contentTintColor = on ? NSColor.systemGreenColor : NSColor.systemGrayColor;
    _switchValues[index].stringValue = on ? @"On · 127" : @"Off · 0";
}

- (void)addSwitchIndicatorsTo:(NSView *)content
{
    NSImage *dot = [NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:nil];
    for (unsigned index = 0; index < FootswitchCount; ++index) {
        CGFloat x = 24 + (index % 3) * 134;
        CGFloat y = 340 - (index / 3) * 70;
        NSBox *tile = [[NSBox alloc] initWithFrame:NSMakeRect(x, y, 124, 62)];
        tile.boxType = NSBoxCustom;
        tile.borderWidth = 1;
        tile.borderColor = NSColor.separatorColor;
        tile.fillColor = NSColor.controlBackgroundColor;
        tile.cornerRadius = 8;
        tile.contentViewMargins = NSZeroSize;
        [content addSubview:tile];

        NSImageView *light = [[NSImageView alloc] initWithFrame:NSMakeRect(12, 23, 16, 16)];
        light.image = dot;
        light.imageScaling = NSImageScaleProportionallyUpOrDown;
        light.accessibilityElement = NO;
        [tile.contentView addSubview:light];
        _switchLights[index] = light;

        NSString *name = [NSString stringWithFormat:@"Switch %u", index + 1];
        NSTextField *label = [NSTextField labelWithString:name];
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        label.frame = NSMakeRect(36, 32, 80, 18);
        [tile.contentView addSubview:label];

        NSTextField *value = [NSTextField labelWithString:@""];
        value.textColor = NSColor.secondaryLabelColor;
        value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        value.accessibilityLabel = [name stringByAppendingString:@" MIDI value"];
        value.frame = NSMakeRect(36, 12, 80, 17);
        [tile.contentView addSubview:value];
        _switchValues[index] = value;
        [self showValue:0 forSwitch:index];
    }
}

- (void)addPedalControlsTo:(NSView *)content
{
    NSTextField *label = [NSTextField labelWithString:@"Expression Pedal"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    label.frame = NSMakeRect(24, 235, 392, 18);
    [content addSubview:label];

    _pedalLevel = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 213, 392, 12)];
    _pedalLevel.indeterminate = NO;
    _pedalLevel.maxValue = 127;
    _pedalLevel.accessibilityLabel = @"Expression pedal position";
    [content addSubview:_pedalLevel];

    _pedalStatus = [NSTextField labelWithString:@""];
    _pedalStatus.frame = NSMakeRect(24, 181, 392, 20);
    [content addSubview:_pedalStatus];

    _setHeel = [NSButton buttonWithTitle:@"Set Heel" target:self action:@selector(setHeel:)];
    _setHeel.frame = NSMakeRect(20, 140, 94, 34);
    [content addSubview:_setHeel];
    _setToe = [NSButton buttonWithTitle:@"Set Toe" target:self action:@selector(setToe:)];
    _setToe.frame = NSMakeRect(117, 140, 94, 34);
    [content addSubview:_setToe];
    _cancelCalibration = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelCalibration:)];
    _cancelCalibration.frame = NSMakeRect(214, 140, 94, 34);
    [content addSubview:_cancelCalibration];
    [self updatePedalDisplay];
}

- (OSStatus)sendControl:(UInt32)controller value:(UInt32)value
{
    UInt32 message = 0x20b00000u | (controller << 8u) | value;
    MIDIEventList list;
    MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
    MIDIEventListAdd(&list, sizeof(list), packet, 0, 1, &message);
    return MIDIReceivedEventList(_source, &list);
}

- (void)updatePedalDisplay
{
    const BOOL hasSample = _pedalRaw >= 0;
    const BOOL capturingToe = _pendingHeel >= 0;
    _setHeel.enabled = hasSample;
    _setToe.enabled = hasSample && capturingToe;
    _cancelCalibration.hidden = !capturingToe;

    NSString *status;
    if (!hasSample) {
        status = _pedalUnavailable ? @"No expression pedal data." : @"Waiting for pedal data…";
        _pedalLevel.doubleValue = 0;
    } else if (capturingToe) {
        status = _heelTooClose ? @"Move farther forward, then click Set Toe."
                              : @"Heel captured. Move fully forward and click Set Toe.";
    } else if (_heel < 0) {
        status = @"Move fully back and click Set Heel to calibrate.";
    } else {
        const int value = pedalMIDIValue(_pedalRaw, _heel, _toe);
        if (value != _lastPedalValue) {
            const OSStatus result = [self sendControl:ExpressionCC value:(UInt32)value];
            if (result == noErr)
                _lastPedalValue = value;
            else
                _lastEvent.stringValue = [NSString stringWithFormat:@"MIDI delivery failed (%d).", (int)result];
        }
        _pedalLevel.doubleValue = value;
        status = [NSString stringWithFormat:@"CC %d = %d  ·  %d%%", ExpressionCC, value,
                                                (value * 100 + 63) / 127];
    }
    if (![_pedalStatus.stringValue isEqualToString:status])
        _pedalStatus.stringValue = status;
}

- (void)setHeel:(id)sender
{
    (void)sender;
    if (_pedalRaw < 0)
        return;
    _pendingHeel = _pedalRaw;
    _heelTooClose = NO;
    [self updatePedalDisplay];
}

- (void)setToe:(id)sender
{
    (void)sender;
    if (_pendingHeel < 0 || _pedalRaw < 0)
        return;
    if (abs(_pedalRaw - _pendingHeel) < MinimumPedalSpan) {
        _heelTooClose = YES;
    } else {
        _heel = _pendingHeel;
        _toe = _pedalRaw;
        _pendingHeel = -1;
        _lastPedalValue = -1;
        [NSUserDefaults.standardUserDefaults setObject:@[@(_heel), @(_toe)] forKey:PedalCalibrationKey];
    }
    [self updatePedalDisplay];
}

- (void)cancelCalibration:(id)sender
{
    (void)sender;
    _pendingHeel = -1;
    [self updatePedalDisplay];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    atomic_init(&_stop, false);
    atomic_init(&_footswitchLEDs, 0);
    _pedalRaw = _heel = _toe = _pendingHeel = _lastPedalValue = -1;
    NSArray *calibration = [NSUserDefaults.standardUserDefaults arrayForKey:PedalCalibrationKey];
    if (calibration.count == 2 && [calibration[0] isKindOfClass:NSNumber.class]
                               && [calibration[1] isKindOfClass:NSNumber.class]) {
        const int heel = [calibration[0] intValue];
        const int toe = [calibration[1] intValue];
        if (heel >= 0 && heel <= 4096 && toe >= 0 && toe <= 4096 && abs(heel - toe) >= MinimumPedalSpan) {
            _heel = heel;
            _toe = toe;
        }
    }
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 467)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Rig Kontrol 2 MIDI Bridge";
    _window.delegate = self;
    [_window center];
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Rig Kontrol 2 Bridge" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menu;

    NSView *content = _window.contentView;
    _status = [NSTextField wrappingLabelWithString:@"Opening the USB control interface…"];
    _status.frame = NSMakeRect(24, 409, 392, 40);
    _status.accessibilityLabel = @"USB status";
    [content addSubview:_status];

    [self addSwitchIndicatorsTo:content];
    [self addPedalControlsTo:content];

    _lastEvent = [NSTextField labelWithString:@"Last MIDI event: none"];
    _lastEvent.frame = NSMakeRect(24, 103, 392, 22);
    [content addSubview:_lastEvent];

    NSTextField *port = [NSTextField labelWithString:@"MIDI input in Live: Rig Kontrol 2 Bridge"];
    port.textColor = NSColor.secondaryLabelColor;
    port.frame = NSMakeRect(24, 77, 392, 22);
    [content addSubview:port];

    _connect = [NSButton buttonWithTitle:@"Reconnect" target:self action:@selector(connect:)];
    _connect.frame = NSMakeRect(20, 27, 107, 34);
    [content addSubview:_connect];

    NSButton *test = [NSButton buttonWithTitle:@"Send Software Test" target:self action:@selector(test:)];
    test.frame = NSMakeRect(135, 27, 158, 34);
    [content addSubview:test];

    OSStatus result = MIDIClientCreateWithBlock(CFSTR("Rig Kontrol 2 Bridge"), &_client, ^(const MIDINotification *note) {
        (void)note;
    });
    if (result == noErr)
        result = MIDISourceCreateWithProtocol(_client, CFSTR("Rig Kontrol 2 Bridge"), kMIDIProtocol_1_0, &_source);
    if (result == noErr)
        [self connect:nil];
    else
        _status.stringValue = [NSString stringWithFormat:@"Could not create the Core MIDI port (%d).", (int)result];

    [_window makeKeyAndOrderFront:nil];
    if (@available(macOS 14, *))
        [NSApp activate];
}

- (void)connect:(id)sender
{
    (void)sender;
    if (_running || _source == 0)
        return;
    _status.stringValue = @"Opening the USB control interface…";
    _pedalUnavailable = NO;
    [self updatePedalDisplay];
    _connect.enabled = NO;
    _running = YES;
    atomic_store(&_stop, false);
    atomic_bool *stop = &_stop;
    const atomic_uchar *footswitchLEDs = &_footswitchLEDs;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = runControlInput(stop, footswitchLEDs, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_status.stringValue = @"USB control connected. Press a footswitch.";
            });
        }, ^(BOOL available) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_status.stringValue = available ? @"USB control connected. Press a footswitch."
                    : @"USB control connected. Retrying footswitch LEDs…";
            });
        }, ^(unsigned index) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self emit:index physical:YES]; });
        }, ^(int raw) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_pedalRaw = raw;
                self->_pedalUnavailable = raw < 0;
                if (raw < 0)
                    self->_lastPedalValue = -1;
                [self updatePedalDisplay];
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_running = NO;
            self->_connect.enabled = YES;
            self->_status.stringValue = result;
            self->_pedalRaw = self->_pendingHeel = self->_lastPedalValue = -1;
            self->_pedalUnavailable = YES;
            [self updatePedalDisplay];
            if (self->_quitting)
                [NSApp replyToApplicationShouldTerminate:YES];
        });
    });
}

- (void)emit:(unsigned)index physical:(BOOL)physical
{
    if (_source == 0)
        return;
    const UInt32 controller = 20u + index;
    const UInt32 value = _toggles[index] ? 0u : 127u;
    const OSStatus result = [self sendControl:controller value:value];
    if (result == noErr) {
        _toggles[index] = value == 127u;
        if (index < FootswitchCount) {
            const uint8_t bit = 1u << index;
            if (_toggles[index])
                atomic_fetch_or(&_footswitchLEDs, bit);
            else
                atomic_fetch_and(&_footswitchLEDs, (uint8_t)~bit);
            [self showValue:value forSwitch:index];
        }
    }
    _lastEvent.stringValue = result == noErr
        ? [NSString stringWithFormat:@"%@  →  CC %u = %u",
               physical ? [NSString stringWithFormat:@"Footswitch %u", index + 1] : @"Software test",
               (unsigned int)controller, (unsigned int)value]
        : [NSString stringWithFormat:@"MIDI delivery failed (%d).", (int)result];
}

- (void)test:(id)sender
{
    (void)sender;
    [self emit:0 physical:NO];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    (void)sender;
    if (!_running)
        return NSTerminateNow;
    _quitting = YES;
    atomic_store(&_stop, true);
    return NSTerminateLater;
}
@end

int main(void)
{
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        Bridge *delegate = [[Bridge alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
