#import "PocketPadHooks.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <substrate.h>
#import <unistd.h>

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

static NSString *PPDescribeCFValue(CFTypeRef value)
{
	if (!value) return @"<nil>";
	CFStringRef description = CFCopyDescription(value);
	return (__bridge_transfer NSString *)description;
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

static int PPReplaceSysctlResult(const char *source, void *oldp, size_t *oldlenp,
	size_t capacity, int originalResult)
{
	if (originalResult != 0) {
		XLog(@"sysctl", @"%@ original=<read failed errno=%d> mapped=%@ pid=%d",
			[NSString stringWithUTF8String:source], errno, PPHardwareModel(), getpid());
		return originalResult;
	}

	NSString *original = oldp
		? PPStringFromSysctlBuffer(oldp, *oldlenp)
		: @"<size query>";
	size_t fakeSize = strlen(PPHardwareModelCString) + 1;
	if (!oldp) {
		*oldlenp = fakeSize;
	} else if (capacity < fakeSize) {
		*oldlenp = fakeSize;
		errno = ENOMEM;
		XLog(@"sysctl", @"%@ original=%@ mapped=%@ capacity=%zu pid=%d",
			[NSString stringWithUTF8String:source], original, PPHardwareModel(),
			capacity, getpid());
		return -1;
	} else {
		memcpy(oldp, PPHardwareModelCString, fakeSize);
		*oldlenp = fakeSize;
	}
	XLog(@"sysctl", @"%@ original=%@ mapped=%@ pid=%d",
		[NSString stringWithUTF8String:source], original, PPHardwareModel(), getpid());
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
	const char *source = name[1] == HW_MACHINE ? "hw.machine" : "hw.model";
	return PPReplaceSysctlResult(source, oldp, oldlenp, capacity, result);
}

static int PPSysctlbynameHook(const char *name, void *oldp, size_t *oldlenp,
	void *newp, size_t newlen)
{
	if (!name || (strcmp(name, "hw.machine") != 0 && strcmp(name, "hw.model") != 0)) {
		return PPOriginalSysctlbyname(name, oldp, oldlenp, newp, newlen);
	}

	size_t capacity = oldlenp ? *oldlenp : 0;
	int result = PPOriginalSysctlbyname(name, oldp, oldlenp, newp, newlen);
	return PPReplaceSysctlResult(name, oldp, oldlenp, capacity, result);
}

static int PPUnameHook(struct utsname *value)
{
	int result = PPOriginalUname(value);
	if (result != 0 || !value) return result;

	NSString *original = @(value->machine);
	strncpy(value->machine, PPHardwareModelCString, sizeof(value->machine) - 1);
	value->machine[sizeof(value->machine) - 1] = '\0';
	XLog(@"uname", @"machine original=%@ mapped=%@ pid=%d",
		original, PPHardwareModel(), getpid());
	return 0;
}

static CFStringRef PPMobileGestaltStringOverride(CFStringRef question)
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
	return NULL;
}

static BOOL PPMobileGestaltIntegerOverride(CFStringRef question, SInt32 *value)
{
	if (question && CFEqual(question, CFSTR("DeviceClassNumber"))) {
		*value = 3; // MGDeviceClassiPad
		return YES;
	}
	return NO;
}

static CFTypeRef PPMGCopyAnswerHook(CFStringRef question, CFDictionaryRef options)
{
	CFTypeRef original = PPOriginalMGCopyAnswer(question, options);
	CFStringRef mapped = PPMobileGestaltStringOverride(question);
	if (!mapped) {
		XLog(@"MobileGestalt", @"MGCopyAnswer %@ original=%@ mapped=<unchanged> pid=%d",
			PPDescribeCFValue(question), PPDescribeCFValue(original), getpid());
		return original;
	}

	XLog(@"MobileGestalt", @"MGCopyAnswer %@ original=%@ mapped=%@ pid=%d",
		PPDescribeCFValue(question), PPDescribeCFValue(original),
		PPDescribeCFValue(mapped), getpid());
	if (original) CFRelease(original);
	return CFRetain(mapped);
}

static CFStringRef PPMGGetStringAnswerHook(CFStringRef question)
{
	CFStringRef original = PPOriginalMGGetStringAnswer(question);
	CFStringRef mapped = PPMobileGestaltStringOverride(question);
	if (!mapped) {
		XLog(@"MobileGestalt", @"MGGetStringAnswer %@ original=%@ mapped=<unchanged> pid=%d",
			PPDescribeCFValue(question), PPDescribeCFValue(original), getpid());
		return original;
	}

	XLog(@"MobileGestalt", @"MGGetStringAnswer %@ original=%@ mapped=%@ pid=%d",
		PPDescribeCFValue(question), PPDescribeCFValue(original),
		PPDescribeCFValue(mapped), getpid());
	if (original) CFRelease(original);
	return CFRetain(mapped);
}

static SInt32 PPMGGetSInt32AnswerHook(CFStringRef question, SInt32 defaultValue)
{
	SInt32 original = PPOriginalMGGetSInt32Answer(question, defaultValue);
	SInt32 mapped = original;
	bool changed = PPMobileGestaltIntegerOverride(question, &mapped);
	XLog(@"MobileGestalt", @"MGGetSInt32Answer %@ original=%d mapped=%d changed=%d pid=%d",
		PPDescribeCFValue(question), (int)original, (int)mapped, changed, getpid());
	return mapped;
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
