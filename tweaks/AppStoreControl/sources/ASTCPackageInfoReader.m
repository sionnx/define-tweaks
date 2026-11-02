//
//  ASTCPackageInfoReader.m
//  AppStoreControl
//

#import "ASTCPackageInfoReader.h"
#import "ASTCLog.h"

#import <zlib.h>

static NSString *const ASTCPackageErrorDomain = @"to.define.appstorecontrol.package";

/// End of central directory record: 22 bytes plus a comment of up to 64 KiB.
static const uint64_t kASTCTailLength = 22 + 0xFFFF;
/// Central directory bytes fetched per request while looking for Info.plist.
static const uint64_t kASTCDirectoryChunk = 256 * 1024;

static NSError *ASTCPackageError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:ASTCPackageErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"Unknown error"}];
}

static uint16_t ASTCRead16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t ASTCRead32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t ASTCRead64(const uint8_t *p) { return (uint64_t)ASTCRead32(p) | ((uint64_t)ASTCRead32(p + 4) << 32); }

/// YES for "Payload/<name>.app/Info.plist" (the main bundle, not a nested one).
static BOOL ASTCIsMainInfoPlist(NSString *name)
{
    if (![name hasPrefix:@"Payload/"] || ![name hasSuffix:@".app/Info.plist"]) {
        return NO;
    }
    return [name componentsSeparatedByString:@"/"].count == 3;
}

/// Inflates a raw deflate stream (ZIP method 8).
static NSData *ASTCInflate(NSData *compressed, uint64_t expectedLength)
{
    if (expectedLength == 0 || expectedLength > 16 * 1024 * 1024) {
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)expectedLength];
    z_stream stream = {0};
    stream.next_in = (Bytef *)compressed.bytes;
    stream.avail_in = (uInt)compressed.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        return nil;
    }
    int status = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    if (status != Z_STREAM_END) {
        return nil;
    }
    output.length = stream.total_out;
    return output;
}

/// State of one read; requests are chained through blocks.
@interface ASTCPackageRead : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) ASTCPackageInfoHandler completion;
@property (nonatomic, assign) uint64_t totalLength;
@property (nonatomic, assign) uint64_t directoryOffset;
@property (nonatomic, assign) uint64_t directorySize;
@property (nonatomic, assign) NSUInteger requestCount;
@property (nonatomic, assign) uint64_t bytesRead;
@property (nonatomic, assign) CFAbsoluteTime startTime;
@end

@implementation ASTCPackageRead
@end

@implementation ASTCPackageInfoReader {
    NSURLSession *_session;
}

+ (instancetype)sharedInstance
{
    static ASTCPackageInfoReader *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ASTCPackageInfoReader new];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPMaximumConnectionsPerHost = 4;
        configuration.timeoutIntervalForRequest = 15;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)readInfoPlistAtURL:(NSURL *)url completion:(ASTCPackageInfoHandler)completion
{
    ASTCPackageRead *read = [ASTCPackageRead new];
    read.url = url;
    read.completion = completion;
    read.startTime = CFAbsoluteTimeGetCurrent();

    // Suffix range: the server answers with the last bytes and the total size.
    [self fetch:read range:[NSString stringWithFormat:@"bytes=-%llu", kASTCTailLength] completion:^(NSData *data, NSError *error) {
        if (!data) {
            [self finish:read info:nil error:error];
            return;
        }
        [self parseTail:data read:read];
    }];
}

#pragma mark - Steps

- (void)parseTail:(NSData *)tail read:(ASTCPackageRead *)read
{
    const uint8_t *bytes = tail.bytes;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--) {
        if (ASTCRead32(bytes + i) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        [self finish:read info:nil error:ASTCPackageError(2, @"No ZIP end of central directory record.")];
        return;
    }

    uint64_t directorySize = ASTCRead32(bytes + eocd + 12);
    uint64_t directoryOffset = ASTCRead32(bytes + eocd + 16);
    if (directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF) {
        // ZIP64: the locator sits right before the classic record.
        if (eocd < 20 || ASTCRead32(bytes + eocd - 20) != 0x07064b50) {
            [self finish:read info:nil error:ASTCPackageError(3, @"Missing ZIP64 locator.")];
            return;
        }
        uint64_t zip64Record = ASTCRead64(bytes + eocd - 20 + 8);
        uint64_t tailStart = read.totalLength - tail.length;
        if (zip64Record < tailStart || zip64Record + 56 > read.totalLength) {
            [self finish:read info:nil error:ASTCPackageError(4, @"ZIP64 record outside the fetched tail.")];
            return;
        }
        const uint8_t *record = bytes + (zip64Record - tailStart);
        directorySize = ASTCRead64(record + 40);
        directoryOffset = ASTCRead64(record + 48);
    }
    read.directoryOffset = directoryOffset;
    read.directorySize = directorySize;

    // Small packages: the whole directory is already in the tail.
    uint64_t tailStart = read.totalLength - tail.length;
    if (directoryOffset >= tailStart && directoryOffset + directorySize <= read.totalLength) {
        NSData *directory = [tail subdataWithRange:NSMakeRange((NSUInteger)(directoryOffset - tailStart), (NSUInteger)directorySize)];
        [self scanDirectory:directory atOffset:0 read:read];
        return;
    }
    [self scanDirectoryFrom:0 carry:nil read:read];
}

/// Fetches the central directory chunk by chunk until the entry is found.
- (void)scanDirectoryFrom:(uint64_t)position carry:(NSData *)carry read:(ASTCPackageRead *)read
{
    if (position >= read.directorySize) {
        [self finish:read info:nil error:ASTCPackageError(5, @"Info.plist not found in the package.")];
        return;
    }
    uint64_t length = MIN(kASTCDirectoryChunk, read.directorySize - position);
    uint64_t start = read.directoryOffset + position;
    NSString *range = [NSString stringWithFormat:@"bytes=%llu-%llu", start, start + length - 1];
    [self fetch:read range:range completion:^(NSData *data, NSError *error) {
        if (!data) {
            [self finish:read info:nil error:error];
            return;
        }
        NSMutableData *buffer = [NSMutableData dataWithData:carry ?: [NSData data]];
        [buffer appendData:data];
        [self scanDirectory:buffer atOffset:position + length read:read];
    }];
}

/// Walks complete entries in `buffer`. `nextPosition` is where the following
/// chunk starts, or 0 when the buffer holds the whole directory.
- (void)scanDirectory:(NSData *)buffer atOffset:(uint64_t)nextPosition read:(ASTCPackageRead *)read
{
    const uint8_t *bytes = buffer.bytes;
    NSUInteger cursor = 0;
    while (cursor + 46 <= buffer.length && ASTCRead32(bytes + cursor) == 0x02014b50) {
        const uint8_t *entry = bytes + cursor;
        uint16_t nameLength = ASTCRead16(entry + 28);
        uint16_t extraLength = ASTCRead16(entry + 30);
        uint16_t commentLength = ASTCRead16(entry + 32);
        NSUInteger entryLength = 46 + nameLength + extraLength + commentLength;
        if (cursor + entryLength > buffer.length) {
            break;
        }
        NSString *name = [[NSString alloc] initWithBytes:entry + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if (ASTCIsMainInfoPlist(name)) {
            uint16_t method = ASTCRead16(entry + 10);
            uint64_t compressedSize = ASTCRead32(entry + 20);
            uint64_t uncompressedSize = ASTCRead32(entry + 24);
            uint64_t localOffset = ASTCRead32(entry + 42);
            // ZIP64 extra field carries the 64-bit values that overflowed.
            const uint8_t *extra = entry + 46 + nameLength;
            for (NSUInteger e = 0; e + 4 <= extraLength;) {
                uint16_t tag = ASTCRead16(extra + e);
                uint16_t size = ASTCRead16(extra + e + 2);
                if (tag == 0x0001) {
                    const uint8_t *field = extra + e + 4;
                    NSUInteger used = 0;
                    if (uncompressedSize == 0xFFFFFFFF && used + 8 <= size) { uncompressedSize = ASTCRead64(field + used); used += 8; }
                    if (compressedSize == 0xFFFFFFFF && used + 8 <= size) { compressedSize = ASTCRead64(field + used); used += 8; }
                    if (localOffset == 0xFFFFFFFF && used + 8 <= size) { localOffset = ASTCRead64(field + used); used += 8; }
                }
                e += 4 + size;
            }
            [self readEntryAtOffset:localOffset method:method compressedSize:compressedSize
                   uncompressedSize:uncompressedSize read:read];
            return;
        }
        cursor += entryLength;
    }
    if (nextPosition == 0) {
        [self finish:read info:nil error:ASTCPackageError(5, @"Info.plist not found in the package.")];
        return;
    }
    NSData *carry = [buffer subdataWithRange:NSMakeRange(cursor, buffer.length - cursor)];
    [self scanDirectoryFrom:nextPosition carry:carry read:read];
}

- (void)readEntryAtOffset:(uint64_t)offset
                   method:(uint16_t)method
           compressedSize:(uint64_t)compressedSize
         uncompressedSize:(uint64_t)uncompressedSize
                     read:(ASTCPackageRead *)read
{
    // The local header repeats the name and may carry a different extra
    // field; fetch generous slack so one request covers header and data.
    uint64_t end = MIN(offset + 30 + 1024 + compressedSize, read.totalLength) - 1;
    NSString *range = [NSString stringWithFormat:@"bytes=%llu-%llu", offset, end];
    [self fetch:read range:range completion:^(NSData *data, NSError *error) {
        if (!data) {
            [self finish:read info:nil error:error];
            return;
        }
        const uint8_t *bytes = data.bytes;
        if (data.length < 30 || ASTCRead32(bytes) != 0x04034b50) {
            [self finish:read info:nil error:ASTCPackageError(6, @"Bad local file header.")];
            return;
        }
        uint64_t dataStart = 30 + ASTCRead16(bytes + 26) + ASTCRead16(bytes + 28);
        if (dataStart + compressedSize > data.length) {
            [self finish:read info:nil error:ASTCPackageError(7, @"Truncated Info.plist entry.")];
            return;
        }
        NSData *payload = [data subdataWithRange:NSMakeRange((NSUInteger)dataStart, (NSUInteger)compressedSize)];
        NSData *plistData = method == 0 ? payload : (method == 8 ? ASTCInflate(payload, uncompressedSize) : nil);
        if (!plistData) {
            [self finish:read info:nil error:ASTCPackageError(8, @"Could not decompress Info.plist.")];
            return;
        }
        id info = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:NULL];
        if (![info isKindOfClass:[NSDictionary class]]) {
            [self finish:read info:nil error:ASTCPackageError(9, @"Info.plist is not a dictionary.")];
            return;
        }
        [self finish:read info:info error:nil];
    }];
}

#pragma mark - Transport

- (void)fetch:(ASTCPackageRead *)read range:(NSString *)range completion:(void (^)(NSData *data, NSError *error))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:read.url];
    [request setValue:range forHTTPHeaderField:@"Range"];
    read.requestCount++;
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || http.statusCode != 206 || data.length == 0) {
            completion(nil, error ?: ASTCPackageError(1, [NSString stringWithFormat:@"Range request failed (HTTP %ld).", (long)http.statusCode]));
            return;
        }
        read.bytesRead += data.length;
        if (read.totalLength == 0) {
            // "bytes 123-456/789"
            NSString *contentRange = http.allHeaderFields[@"Content-Range"];
            NSString *total = [contentRange componentsSeparatedByString:@"/"].lastObject;
            read.totalLength = strtoull(total.UTF8String, NULL, 10);
            if (read.totalLength == 0) {
                completion(nil, ASTCPackageError(1, @"The server did not report the package size."));
                return;
            }
        }
        completion(data, nil);
    }] resume];
}

- (void)finish:(ASTCPackageRead *)read info:(NSDictionary *)info error:(NSError *)error
{
    ASTCLog(@"package Info.plist read took %.2fs: %lu requests, %llu bytes of %llu, minOS=%@ error=%@",
           CFAbsoluteTimeGetCurrent() - read.startTime, (unsigned long)read.requestCount,
           read.bytesRead, read.totalLength, info[@"MinimumOSVersion"], error.localizedDescription);
    if (read.completion) {
        read.completion(info, error);
    }
}

@end
