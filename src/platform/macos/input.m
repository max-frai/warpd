/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "macos.h"

static int grabbed = 0;
static long grabbed_time;

static int input_fds[2];
static struct input_event *grabbed_keys;
static size_t grabbed_keys_sz = 0;

static uint8_t passthrough_keys[256] = {0};

static TISInputSourceRef saved_layout = NULL;
static int shutting_down = 0;

static CFMachPortRef tap;

uint8_t active_mods = 0;
pthread_mutex_t keymap_mtx = PTHREAD_MUTEX_INITIALIZER;

static struct {
	char name[32];
	char shifted_name[32];
} keymap[256] = { 0 };

struct mod {
	uint8_t mask;
	uint8_t code1;
	uint8_t code2;
} modifiers[] = {
    {PLATFORM_MOD_CONTROL, 60, 63},
    {PLATFORM_MOD_SHIFT, 57, 61},
    {PLATFORM_MOD_META, 55, 56},
    {PLATFORM_MOD_ALT, 59, 62},
};

static long get_time_ms()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);

	return ts.tv_nsec / 1E6 + ts.tv_sec * 1E3;
}

static void write_message(int fd, void *msg, ssize_t sz)
{
	assert(write(fd, msg, sz) == sz);
}

/* Returns -1 if the timeout expires before a message is available. */
static int read_message(int fd, void *msg, ssize_t sz, int timeout)
{
	fd_set fds;

	FD_ZERO(&fds);
	FD_SET(fd, &fds);

	select(fd + 1, &fds, NULL, NULL,
	       timeout ? &(struct timeval){.tv_usec = timeout * 1E3} : NULL);

	/* timeout */
	if (!FD_ISSET(fd, &fds))
		return -1;

	assert(read(fd, msg, sz) == sz);

	return 0;
}

void osx_input_interrupt()
{
	struct input_event ev = {0};
	write_message(input_fds[1], &ev, sizeof ev);
}

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
				   CGEventRef event, void *context)
{
	size_t i;
	int is_key_event = 0;

	uint8_t code = 0;
	uint8_t pressed = 0;
	uint8_t mods = 0;

	static uint8_t keymods[256] = {0}; /* Mods active at key down time. */
	static long pressed_timestamps[256];

	/* macOS will timeout the event tap, so we have to re-enable it :/ */
	if (type == kCGEventTapDisabledByTimeout) {
		CGEventTapEnable(tap, true);
		return event;
	}

	/* If only apple designed its system APIs like its macbooks... */
	switch (type) {
		NSEvent *nsev;
		CGEventFlags flags;

	case NX_SYSDEFINED: /* system codes (e.g brightness) */
		nsev = [NSEvent eventWithCGEvent:event];

		code = (nsev.data1 >> 16) + 220;
		pressed = !(nsev.data1 & 0x100);

		/*
		 * Pass other system events through, things like sticky keys
		 * rely on NX_SYSDEFINED events for visual notifications.
		 */
		if (nsev.subtype == NX_SUBTYPE_AUX_CONTROL_BUTTONS)
			is_key_event = 1;

		break;
	case kCGEventFlagsChanged: /* modifier codes */
		code = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) + 1;
		flags = CGEventGetFlags(event);
		pressed = 0;

		switch (code) {
			case 57: case 61: pressed = !!(flags & kCGEventFlagMaskShift); break;
			case 59: case 62: pressed = !!(flags & kCGEventFlagMaskAlternate); break;
			case 55: case 56: pressed = !!(flags & kCGEventFlagMaskCommand); break;
			case 60: case 63: pressed = !!(flags & kCGEventFlagMaskControl); break;
		}

		is_key_event = 1;
		break;
	case kCGEventKeyDown:
	case kCGEventKeyUp:
		/* Skip repeat events */
		if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
			if (grabbed)
				return nil;
			else
				return event;
		}

		/*
		 * We shift codes up by 1 so 0 is not a valid code. This is
		 * accounted for in the name table.
		 */
		code = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) + 1;
		pressed = type == kCGEventKeyDown;

		is_key_event = 1;
		break;
	default:
		break;
	}

	if (!is_key_event)
		return event;

	if (pressed == 1)
		pressed_timestamps[code] = get_time_ms();

	if (passthrough_keys[code]) {
		passthrough_keys[code]--;
		return event;
	}

	/* Compute the active mod set. */
	for (i = 0; i < sizeof modifiers / sizeof modifiers[0]; i++) {
		struct mod *mod = &modifiers[i];

		if (code == mod->code1 || code == mod->code2) {
			if (pressed)
				active_mods |= mod->mask;
			else
				active_mods &= ~mod->mask;
		}
	}

	/* Ensure mods are consistent across keydown/up events. */
	if (pressed == 0) {
		mods = keymods[code];
	} else if (pressed == 1) {
		mods = active_mods;
		keymods[code] = mods;
	}

	struct input_event ev;

	ev.code = code;
	ev.pressed = pressed;
	ev.mods = mods;

	write_message(input_fds[1], &ev, sizeof ev);

	for (i = 0; i < grabbed_keys_sz; i++)
		if (grabbed_keys[i].code == code &&
		    grabbed_keys[i].mods == active_mods) {
			grabbed = 1;
			grabbed_time = get_time_ms();
			return nil;
		}

	if (grabbed) {
		/* If the keydown occurred before the grab, allow the keyup to pass through. */
		if (pressed || pressed_timestamps[code] > grabbed_time) {
			return nil;
		}
	}
	return event;
}

/*
 * TODO: make sure names are consistent with the linux map + account
 * for OS keymap.
 */
const char *osx_input_lookup_name(uint8_t code, int shifted)
{
	static char name[256];

	pthread_mutex_lock(&keymap_mtx);
	strcpy(name, shifted ? keymap[code].shifted_name : keymap[code].name);
	pthread_mutex_unlock(&keymap_mtx);

	if (!name[0])
		return NULL;

	return name;
}

uint8_t osx_input_lookup_code(const char *name, int *shifted)
{
	size_t i;
	pthread_mutex_lock(&keymap_mtx);

	/*
	 * Horribly inefficient.
	 *
	 * TODO: Figure out the right Carbon incantation for reverse
	 * name lookups.
	 */
	for (i = 0; i < 256; i++) {
		if (keymap[i].name[0] && !strcmp(name, keymap[i].name)) {
			*shifted = 0;
			pthread_mutex_unlock(&keymap_mtx);
			return i;
		} else if (keymap[i].shifted_name[0] && !strcmp(name, keymap[i].shifted_name)) {
			*shifted = 1;
			pthread_mutex_unlock(&keymap_mtx);
			return i;
		}
	}

	pthread_mutex_unlock(&keymap_mtx);
	return 0;
}

static void _send_key(uint8_t code, int pressed)
{
	static int command_down = 0;

	/* left/right command keys */
	if (code == 56 || code == 55)
		command_down += pressed ? 1 : -1;

	/* events should bypass any active grabs */
	passthrough_keys[code]++;
	CGEventRef ev = CGEventCreateKeyboardEvent(NULL, code - 1, pressed);

	/* quartz inspects the event flags instead of maintaining its own state */
	if (command_down)
		CGEventSetFlags(ev, kCGEventFlagMaskCommand);

	CGEventPost(kCGHIDEventTap, ev);
	CFRelease(ev);
}

void send_key(uint8_t code, int pressed)
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		_send_key(code, pressed);
	});
}

void osx_input_ungrab_keyboard()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		grabbed = 0;
	});

	// Restore previous layout when exiting warpd mode
	NSLog(@"warpd: ungrabbing keyboard and restoring layout");
	shutting_down = 1;
	osx_restore_previous_layout();
	shutting_down = 0;
}

void osx_input_grab_keyboard()
{
	if (grabbed)
		return;

	dispatch_sync(dispatch_get_main_queue(), ^{
		grabbed = 1;
		grabbed_time = get_time_ms();
	});

	// Switch to English layout when entering warpd mode
	NSLog(@"warpd: grabbing keyboard and switching to English layout");
	osx_switch_to_english_layout();
}

struct input_event *osx_input_next_event(int timeout)
{
	static struct input_event ev;

	if (read_message(input_fds[0], &ev, sizeof ev, timeout) < 0)
		return 0;

	if (ev.code == 0 && ev.mods == 0)
		return NULL;

	return &ev;
}

struct input_event *osx_input_wait(struct input_event *keys, size_t sz)
{
	grabbed_keys = keys;
	grabbed_keys_sz = sz;

	while (1) {
		size_t i;
		struct input_event *ev = osx_input_next_event(0);

		if (ev == NULL)
			return NULL;

		for (i = 0; i < sz; i++)
			if (ev->pressed && keys[i].code == ev->code &&
			    keys[i].mods == ev->mods) {
				grabbed_keys = NULL;
				grabbed_keys_sz = 0;

				return ev;
			}
	}
}

static void update_keymap()
{
	if (shutting_down) {
		NSLog(@"warpd: skipping keymap update during shutdown");
		return;
	}

	static uint8_t valid_keycodes[256] = {
		[0x01] = 1, [0x02] = 1, [0x03] = 1, [0x04] = 1, [0x05] = 1, [0x06] = 1, [0x07] = 1, [0x08] = 1,
		[0x09] = 1, [0x0a] = 1, [0x0b] = 1, [0x0c] = 1, [0x0d] = 1, [0x0e] = 1, [0x0f] = 1, [0x10] = 1,
		[0x11] = 1, [0x12] = 1, [0x13] = 1, [0x14] = 1, [0x15] = 1, [0x16] = 1, [0x17] = 1, [0x18] = 1,
		[0x19] = 1, [0x1a] = 1, [0x1b] = 1, [0x1c] = 1, [0x1d] = 1, [0x1e] = 1, [0x1f] = 1, [0x20] = 1,
		[0x21] = 1, [0x22] = 1, [0x23] = 1, [0x24] = 1, [0x25] = 1, [0x26] = 1, [0x27] = 1, [0x28] = 1,
		[0x29] = 1, [0x2a] = 1, [0x2b] = 1, [0x2c] = 1, [0x2d] = 1, [0x2e] = 1, [0x2f] = 1, [0x30] = 1,
		[0x31] = 1, [0x32] = 1, [0x33] = 1, [0x34] = 1, [0x36] = 1, [0x37] = 1, [0x38] = 1, [0x39] = 1,
		[0x3a] = 1, [0x3b] = 1, [0x3c] = 1, [0x3d] = 1, [0x3e] = 1, [0x3f] = 1, [0x40] = 1, [0x41] = 1,
		[0x42] = 1, [0x44] = 1, [0x46] = 1, [0x48] = 1, [0x49] = 1, [0x4a] = 1, [0x4b] = 1, [0x4c] = 1,
		[0x4d] = 1, [0x4f] = 1, [0x50] = 1, [0x51] = 1, [0x52] = 1, [0x53] = 1, [0x54] = 1, [0x55] = 1,
		[0x56] = 1, [0x57] = 1, [0x58] = 1, [0x59] = 1, [0x5a] = 1, [0x5b] = 1, [0x5c] = 1, [0x5d] = 1,
		[0x5e] = 1, [0x5f] = 1, [0x60] = 1, [0x61] = 1, [0x62] = 1, [0x63] = 1, [0x64] = 1, [0x65] = 1,
		[0x66] = 1, [0x67] = 1, [0x68] = 1, [0x69] = 1, [0x6a] = 1, [0x6b] = 1, [0x6c] = 1, [0x6e] = 1,
		[0x6f] = 1, [0x70] = 1, [0x72] = 1, [0x73] = 1, [0x74] = 1, [0x75] = 1, [0x76] = 1, [0x77] = 1,
		[0x78] = 1, [0x79] = 1, [0x7a] = 1, [0x7b] = 1, [0x7c] = 1, [0x7d] = 1, [0x7e] = 1, [0x7f] = 1
	};

	pthread_mutex_lock(&keymap_mtx);

	int code;
	UInt32 deadkeystate = 0;
	UniChar chars[4];
	UniCharCount len;
	CFStringRef str;
	TISInputSourceRef kbd = TISCopyCurrentKeyboardLayoutInputSource();

	if (!kbd) {
		NSLog(@"warpd: ERROR - failed to get current keyboard layout");
		pthread_mutex_unlock(&keymap_mtx);
		return;
	}

	CFDataRef layout_data = TISGetInputSourceProperty(kbd, kTISPropertyUnicodeKeyLayoutData);
	if (!layout_data) {
		NSLog(@"warpd: ERROR - failed to get keyboard layout data (layout may not support Unicode)");
		CFRelease(kbd);
		pthread_mutex_unlock(&keymap_mtx);
		return;
	}

	const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layout_data);
	if (!layout) {
		NSLog(@"warpd: ERROR - failed to get keyboard layout pointer");
		CFRelease(kbd);
		pthread_mutex_unlock(&keymap_mtx);
		return;
	}

	// Log the layout we're processing
	CFStringRef layout_name = (CFStringRef)TISGetInputSourceProperty(kbd, kTISPropertyLocalizedName);
	CFStringRef layout_id = (CFStringRef)TISGetInputSourceProperty(kbd, kTISPropertyInputSourceID);

	char name_str[256] = "unknown";
	char id_str[256] = "unknown";

	if (layout_name) {
		CFStringGetCString(layout_name, name_str, sizeof(name_str), kCFStringEncodingUTF8);
	}
	if (layout_id) {
		CFStringGetCString(layout_id, id_str, sizeof(id_str), kCFStringEncodingUTF8);
	}

	NSLog(@"warpd: processing keymap for layout '%s' (%s)", name_str, id_str);

	for (code = 1; code < 256; code++) {
		if (!valid_keycodes[code]) {
			keymap[code].name[0] = 0;
			keymap[code].shifted_name[0] = 0;
			continue;
		}

		OSStatus status = UCKeyTranslate(layout, code-1, kUCKeyActionDisplay, 0, LMGetKbdType(),
			       kUCKeyTranslateNoDeadKeysBit, &deadkeystate,
			       sizeof(chars) / sizeof(chars[0]), &len, chars);

		if (status == noErr && len > 0) {
			str = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
			if (str) {
				if (!CFStringGetCString(str, keymap[code].name, 31, kCFStringEncodingUTF8)) {
					keymap[code].name[0] = 0;
				}
				CFRelease(str);
			}
		} else {
			keymap[code].name[0] = 0;
		}

		status = UCKeyTranslate(layout, code-1, kUCKeyActionDisplay, 2, LMGetKbdType(),
			       kUCKeyTranslateNoDeadKeysBit, &deadkeystate,
			       sizeof(chars) / sizeof(chars[0]), &len, chars);

		if (status == noErr && len > 0) {
			str = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
			if (str) {
				if (!CFStringGetCString(str, keymap[code].shifted_name, 31, kCFStringEncodingUTF8)) {
					keymap[code].shifted_name[0] = 0;
				}
				CFRelease(str);
			}
		} else {
			keymap[code].shifted_name[0] = 0;
		}

		//TODO: probably missing some keys...
#define fixup(keyname, newname) \
	if (!strcmp(keymap[code].name, keyname)) { \
		strcpy(keymap[code].name, newname); \
		strcpy(keymap[code].shifted_name, ""); \
	}
		fixup("\033", "esc");
		fixup("\x08", "backspace");
		fixup(" ", "space");
		fixup("\x7f", "delete");
#undef fixup

		if (keymap[code].name[0] < 31) { /* Exclude anything else with non printable characters (control codes) */
			strcpy(keymap[code].name, "");
			strcpy(keymap[code].shifted_name, "");
		}

		switch (code) {
#define set_name(keyname) \
	strcpy(keymap[code].name, keyname); \
	strcpy(keymap[code].shifted_name, ""); \
	break;
			case 55: set_name("rightmeta")
			case 56: set_name("leftmeta")
			case 57: set_name("leftshift")
			case 58: set_name("capslock")
			case 59: set_name("leftalt")
			case 60: set_name("leftcontrol")
			case 61: set_name("rightshift")
			case 62: set_name("rightalt")
			case 63: set_name("rightcontrol")
			case 124: set_name("leftarrow")
			case 127: set_name("uparrow")
			case 125: set_name("rightarrow")
			case 126: set_name("downarrow")

			case 0x42: set_name("kpdecimal")
			case 0x44: set_name("kpmultiply")
			case 0x46: set_name("kpplus")
			case 0x48: set_name("kpclear")
			case 0x4C: set_name("kpdivide")
			case 0x4D: set_name("kpenter")
			case 0x4F: set_name("kpminus")
			case 0x52: set_name("kpequals")
			case 0x53: set_name("kp0")
			case 0x54: set_name("kp1")
			case 0x55: set_name("kp2")
			case 0x56: set_name("kp3")
			case 0x57: set_name("kp4")
			case 0x58: set_name("kp5")
			case 0x59: set_name("kp6")
			case 0x5a: set_name("kp7")
			case 0x5C: set_name("kp8")
			case 0x5D: set_name("kp9")
#undef set_name
		}

		if (!strcmp(keymap[code].name, keymap[code].shifted_name))
			strcpy(keymap[code].shifted_name, "");

	}

	CFRelease(kbd);

	pthread_mutex_unlock(&keymap_mtx);
}

void osx_switch_to_english_layout()
{
	NSLog(@"warpd: switch_to_english_layout called");

	// Don't save if we already have one saved
	if (saved_layout) {
		NSLog(@"warpd: layout already saved, not overwriting");
		return;
	} else {
		saved_layout = TISCopyCurrentKeyboardInputSource();
		NSLog(@"warpd: saved current layout for restoration");
	}

	// Log current layout before switching
	CFStringRef current_id = NULL;
	CFStringRef current_name = NULL;
	TISInputSourceRef current_layout = TISCopyCurrentKeyboardInputSource();

	if (current_layout) {
		current_id = (CFStringRef)TISGetInputSourceProperty(current_layout, kTISPropertyInputSourceID);
		current_name = (CFStringRef)TISGetInputSourceProperty(current_layout, kTISPropertyLocalizedName);
	}

	char current_id_str[256] = "unknown";
	char current_name_str[256] = "unknown";

	if (current_id) {
		CFStringGetCString(current_id, current_id_str, sizeof(current_id_str), kCFStringEncodingUTF8);
	}
	if (current_name) {
		CFStringGetCString(current_name, current_name_str, sizeof(current_name_str), kCFStringEncodingUTF8);
	}

	NSLog(@"warpd: switching layout from '%s' (%s) to English", current_name_str, current_id_str);

	// Check if we're already on English
	if (current_id && (CFStringCompare(current_id, CFSTR("com.apple.keylayout.US"), 0) == kCFCompareEqualTo ||
	                   CFStringCompare(current_id, CFSTR("com.apple.keylayout.ABC"), 0) == kCFCompareEqualTo)) {
		NSLog(@"warpd: already on English layout, no switch needed");
		if (current_layout) CFRelease(current_layout);
		return;
	}

	CFArrayRef input_sources = TISCreateInputSourceList(NULL, false);
	if (!input_sources) {
		NSLog(@"warpd: failed to get input source list");
		if (current_layout) CFRelease(current_layout);
		return;
	}

	CFIndex count = CFArrayGetCount(input_sources);
	bool switched = false;

	for (CFIndex i = 0; i < count; i++) {
		TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(input_sources, i);

		CFStringRef source_id = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
		if (source_id && (CFStringCompare(source_id, CFSTR("com.apple.keylayout.US"), 0) == kCFCompareEqualTo ||
		                  CFStringCompare(source_id, CFSTR("com.apple.keylayout.ABC"), 0) == kCFCompareEqualTo)) {

			char target_id_str[256];
			CFStringGetCString(source_id, target_id_str, sizeof(target_id_str), kCFStringEncodingUTF8);

			OSStatus status = TISSelectInputSource(source);
			if (status == noErr) {
				NSLog(@"warpd: successfully switched to English layout (%s)", target_id_str);
				switched = true;
			} else {
				NSLog(@"warpd: failed to switch to English layout, error: %d", (int)status);
			}
			break;
		}
	}

	if (!switched) {
		NSLog(@"warpd: warning - no English layout found, continuing with current layout");
	}

	CFRelease(input_sources);
	if (current_layout) CFRelease(current_layout);
}

void osx_restore_previous_layout()
{
	NSLog(@"warpd: restore_previous_layout called");

	if (saved_layout) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			NSLog(@"warpd: attempting to restore previous layout");

			OSStatus status = TISSelectInputSource(saved_layout);
			if (status == noErr) {
				NSLog(@"warpd: successfully restored previous layout");
			} else {
				NSLog(@"warpd: failed to restore previous layout, error: %d", (int)status);
			}

			CFRelease(saved_layout);
			saved_layout = NULL;
		});
	} else {
		NSLog(@"warpd: no previous layout to restore - saved_layout is NULL");
	}
}

// Safe wrapper for update_keymap that can be called from notifications
static void safe_update_keymap(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	NSLog(@"warpd: keyboard layout change notification received");
	// Dispatch to a background queue to avoid blocking notification delivery
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		update_keymap();
	});
}

/* Called by the main thread to set up event stream. */
void macos_init_input()
{
	/* Request accessibility access if not present. */
	NSDictionary *options = @{(id)kAXTrustedCheckOptionPrompt : @YES};
	BOOL access = AXIsProcessTrustedWithOptions((CFDictionaryRef)options);

	if (!access) {
		printf("Waiting for accessibility permissions\n");
		tap = nil;
		while (!tap) {
			tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0,
					     kCGEventMaskForAllEvents, eventTapCallback, NULL);
			usleep(100000);
		}
		printf("Accessibility permission granted, proceeding\n");
	} else {
		tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0,
				     kCGEventMaskForAllEvents, eventTapCallback, NULL);
	}


	if (!tap) {
		fprintf(stderr,
			"Failed to create event tap, make sure warpd is "
			"whitelisted as an accessibility feature.\n");
		exit(-1);
	}

	CFRunLoopSourceRef runLoopSource =
	    CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);

	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource,
			   kCFRunLoopCommonModes);


	CGEventTapEnable(tap, true);

	CFNotificationCenterAddObserver(
	    CFNotificationCenterGetLocalCenter(), NULL, safe_update_keymap,
	    CFSTR("NSTextInputContextKeyboardSelectionDidChangeNotification"),
	    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

	// Initialize keymap in background to avoid blocking startup
	NSLog(@"warpd: scheduling initial keymap build");
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		update_keymap();
	});

	if (pipe(input_fds) < 0) {
		perror("pipe");
		exit(-1);
	}
}
