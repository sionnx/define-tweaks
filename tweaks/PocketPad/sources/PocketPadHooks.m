#import "PocketPadHooks.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <substrate.h>

#import "PocketPadConfig.h"
#import "XLog.h"

typedef int (*PPSysctlFunction)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*PPSysctlByNameFunction)(const char *, void *, size_t *, void *, size_t);
typedef int (*PPUnameFunction)(struct utsname *);
typedef CFTypeRef (*PPMGCopyAnswerFunction)(CFStringRef, CFDictionaryRef);
typedef CFStringRef (*PPMGGetStringAnswerFunction)(CFStringRef);
typedef SInt32 (*PPMGGetSInt32AnswerFunction)(CFStringRef, SInt32);

static PPSysctlFunction PPOriginalSysctl;
static PPSysctlByNameFunction PPOriginalSysctlbyname;
static PPUnameFunction PPOriginalUname;
static PPMGCopyAnswerFunction PPOriginalMGCopyAnswer;
static PPMGGetStringAnswerFunction PPOriginalMGGetStringAnswer;
static PPMGGetSInt32AnswerFunction PPOriginalMGGetSInt32Answer;
static char *PPHardwareModelCString;

// One line without object addresses, so identical answers log identically.
static NSString *PPDescribeCFValue(CFTypeRef value)
{
	if (!value) return @"<nil>";
	NSString *description = [(__bridge id)value description];
	NSArray<NSString *> *parts = [description componentsSeparatedByCharactersInSet:
		NSCharacterSet.whitespaceAndNewlineCharacterSet];
	parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
	return [parts componentsJoinedByString:@" "];
}

static NSString *PPStringFromSysctlBuffer(const void *buffer, size_t length)
{
	if (!buffer || length == 0) return @"<no value>";
	size_t stringLength = strnlen(buffer, length);
	NSString *value = [[NSString alloc] initWithBytes:buffer
		length:stringLength
		encoding:NSUTF8StringEncoding];
	return value ?: @"<invalid UTF-8>";
}

// Replaces a successful read with the fake model. A read that failed only
// because the buffer was too small for the real value is completed as well:
// callers size the buffer from the fake length returned by the size query.
static int PPReplaceSysctlResult(const char *source, void *oldp, size_t *oldlenp,
	size_t capacity, int originalResult, int originalErrno)
{
	NSString *name = [NSString stringWithUTF8String:source];
	if (!oldlenp || (originalResult != 0 && (originalErrno != ENOMEM || !oldp))) {
		XLogOnce(@"sysctl", @"%@ original=<failed errno=%d> mapped=<unchanged>",
			name, originalErrno);
		errno = originalErrno;
		return originalResult;
	}

	NSString *original = !oldp ? @"<size query>"
		: originalResult != 0 ? @"<buffer too small>"
		: PPStringFromSysctlBuffer(oldp, *oldlenp);
	size_t fakeSize = strlen(PPHardwareModelCString) + 1;
	*oldlenp = fakeSize;
	if (oldp && capacity < fakeSize) {
		XLogOnce(@"sysctl", @"%@ original=%@ mapped=<ENOMEM capacity=%zu>",
			name, original, capacity);
		errno = ENOMEM;
		return -1;
	}
	if (oldp) memcpy(oldp, PPHardwareModelCString, fakeSize);
	XLogOnce(@"sysctl", @"%@ original=%@ mapped=%@", name, original, PPHardwareModel());
	return 0;
}

static int PPSysctlHook(int *name, u_int namelen, void *oldp, size_t *oldlenp,
	void *newp, size_t newlen)
{
	if (namelen < 2 || !name || name[0] != CTL_HW ||
		(name[1] != HW_MACHINE && name[1] != HW_MODEL)) {
		return PPOriginalSysctl(name, namelen, oldp, oldlenp, newp, newlen);
	}

	size_t capacity = oldlenp ? *oldlenp : 0;
	int result = PPOriginalSysctl(name, namelen, oldp, oldlenp, newp, newlen);
	int originalErrno = errno;
	const char *source = name[1] == HW_MACHINE ? "hw.machine" : "hw.model";
	return PPReplaceSysctlResult(source, oldp, oldlenp, capacity, result, originalErrno);
}

static int PPSysctlbynameHook(const char *name, void *oldp, size_t *oldlenp,
	void *newp, size_t newlen)
{
	if (!name || (strcmp(name, "hw.machine") != 0 && strcmp(name, "hw.model") != 0)) {
		return PPOriginalSysctlbyname(name, oldp, oldlenp, newp, newlen);
	}

	size_t capacity = oldlenp ? *oldlenp : 0;
	int result = PPOriginalSysctlbyname(name, oldp, oldlenp, newp, newlen);
	int originalErrno = errno;
	return PPReplaceSysctlResult(name, oldp, oldlenp, capacity, result, originalErrno);
}

static int PPUnameHook(struct utsname *value)
{
	int result = PPOriginalUname(value);
	if (result != 0 || !value) return result;

	NSString *original = @(value->machine);
	strncpy(value->machine, PPHardwareModelCString, sizeof(value->machine) - 1);
	value->machine[sizeof(value->machine) - 1] = '\0';
	XLogOnce(@"uname", @"machine original=%@ mapped=%@", original, PPHardwareModel());
	return 0;
}

// The single MobileGestalt override table. Every typed accessor below derives
// its answer from it, so the same question answers the same through each API.
static CFTypeRef PPMobileGestaltOverride(CFStringRef question)
{
	if (!question) return NULL;
	if (CFEqual(question, CFSTR("ProductType")) ||
		CFEqual(question, CFSTR("HWModelStr")) ||
		CFEqual(question, CFSTR("ProductName"))) {
		return (__bridge CFStringRef)PPHardwareModel();
	}
	if (CFEqual(question, CFSTR("DeviceClass"))) {
		return CFSTR("iPad");
	}
	if (CFEqual(question, CFSTR("DeviceClassNumber"))) {
		static CFNumberRef iPadClass;
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{
			SInt32 value = 3; // MGDeviceClassiPad
			iPadClass = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
		});
		return iPadClass;
	}
	return NULL;
}

static CFTypeRef PPMGCopyAnswerHook(CFStringRef question, CFDictionaryRef options)
{
	CFTypeRef original = PPOriginalMGCopyAnswer(question, options);
	CFTypeRef mapped = PPMobileGestaltOverride(question);
	XLogOnce(@"MobileGestalt", @"MGCopyAnswer %@ original=%@ mapped=%@",
		PPDescribeCFValue(question), PPDescribeCFValue(original),
		mapped ? PPDescribeCFValue(mapped) : @"<unchanged>");
	if (!mapped) return original;
	if (original) CFRelease(original);
	return CFRetain(mapped);
}

static CFStringRef PPMGGetStringAnswerHook(CFStringRef question)
{
	CFStringRef original = PPOriginalMGGetStringAnswer(question);
	CFTypeRef mapped = PPMobileGestaltOverride(question);
	if (mapped && CFGetTypeID(mapped) != CFStringGetTypeID()) mapped = NULL;
	XLogOnce(@"MobileGestalt", @"MGGetStringAnswer %@ original=%@ mapped=%@",
		PPDescribeCFValue(question), PPDescribeCFValue(original),
		mapped ? PPDescribeCFValue(mapped) : @"<unchanged>");
	if (!mapped) return original;
	if (original) CFRelease(original);
	return (CFStringRef)CFRetain(mapped);
}

static SInt32 PPMGGetSInt32AnswerHook(CFStringRef question, SInt32 defaultValue)
{
	SInt32 original = PPOriginalMGGetSInt32Answer(question, defaultValue);
	CFTypeRef mapped = PPMobileGestaltOverride(question);
	SInt32 value = original;
	if (!mapped || CFGetTypeID(mapped) != CFNumberGetTypeID() ||
		!CFNumberGetValue((CFNumberRef)mapped, kCFNumberSInt32Type, &value)) {
		XLogOnce(@"MobileGestalt", @"MGGetSInt32Answer %@ original=%d mapped=<unchanged>",
			PPDescribeCFValue(question), (int)original);
		return original;
	}
	XLogOnce(@"MobileGestalt", @"MGGetSInt32Answer %@ original=%d mapped=%d",
		PPDescribeCFValue(question), (int)original, (int)value);
	return value;
}

static void *PPMobileGestaltSymbol(const char *name)
{
	static void *handle;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
	});
	void *symbol = handle ? dlsym(handle, name) : NULL;
	return symbol ?: dlsym(RTLD_DEFAULT, name);
}

static void PPInstallMobileGestaltHooks(void)
{
	void *copyAnswer = PPMobileGestaltSymbol("MGCopyAnswer");
	void *stringAnswer = PPMobileGestaltSymbol("MGGetStringAnswer");
	void *intAnswer = PPMobileGestaltSymbol("MGGetSInt32Answer");

	if (copyAnswer) {
		MSHookFunction(copyAnswer, (void *)PPMGCopyAnswerHook,
			(void **)&PPOriginalMGCopyAnswer);
	}
	if (stringAnswer) {
		MSHookFunction(stringAnswer, (void *)PPMGGetStringAnswerHook,
			(void **)&PPOriginalMGGetStringAnswer);
	}
	if (intAnswer) {
		MSHookFunction(intAnswer, (void *)PPMGGetSInt32AnswerHook,
			(void **)&PPOriginalMGGetSInt32Answer);
	}
	XLog(@"Hooks", @"MobileGestalt copy=%d string=%d int=%d",
		copyAnswer != NULL, stringAnswer != NULL, intAnswer != NULL);
}

void PPInstallSystemHooks(void)
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		PPHardwareModelCString = strdup(PPHardwareModel().UTF8String);
		MSHookFunction((void *)sysctl, (void *)PPSysctlHook, (void **)&PPOriginalSysctl);
		MSHookFunction((void *)sysctlbyname, (void *)PPSysctlbynameHook,
			(void **)&PPOriginalSysctlbyname);
		MSHookFunction((void *)uname, (void *)PPUnameHook, (void **)&PPOriginalUname);
		PPInstallMobileGestaltHooks();
		XLog(@"Hooks", @"model=%@ sysctl=ok sysctlbyname=ok uname=ok",
			PPHardwareModel());
	});
}
