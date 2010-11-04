#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import "prelink.h"
#import "RegexKitLite.h"
  
NSData *preprocessPlist(NSData *inputData);
struct segment_command *segmentWithName(NSString *segmentName, void *kernelFile);
NSArray *arrayOfPrelinkInfo(struct segment_command *segmentCommand, void *kernelFile);
NSArray *arrayOfKextBlobs(struct segment_command *segmentCommand, void *kernelFile);
uint32_t sizeOfMachOObject(struct mach_header *header);
NSDictionary *namedKernelExtensions(NSArray *prelinkInfo, NSArray *kernelExtensionBlobs);
void error(const char *err);

void error(const char *err) {
    printf("%s\n", err);
    exit(EXIT_FAILURE);
}

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    if (argc < 2) error("Usage: prelink_unpack [prelinked kernel]");
    
    void *kernelFile = NULL;
    struct mach_header *machHeader = NULL;
    int fd = 0;
    cpu_type_t cputype = 0;
    struct stat kstat = {0};
    
    
    fd = open(argv[1], O_RDONLY);
    // check for error
    fstat(fd, &kstat);
    
    kernelFile = mmap(NULL, kstat.st_size, PROT_READ, MAP_FILE|MAP_PRIVATE, fd, 0);
    if (!kernelFile) error("Failed to mmap() kernel.");
    
    machHeader = (struct mach_header *)kernelFile;
    if (machHeader->magic != MH_MAGIC && machHeader->magic != MH_CIGAM) error("Not a Mach-O object.");
    
    cputype = machHeader->cputype;
    if (machHeader->magic == MH_CIGAM) error("Wrong endianness.");
    if (cputype != CPU_TYPE_ARM) error("Not an ARM kernel.");
    
    // __PRELINK_INFO,__info contains plist of kexts
    // __PRELINK_TEXT,__text contains the actual kexts
    struct segment_command *segmentPrelinkInfo = segmentWithName(@"__PRELINK_INFO", kernelFile);
    struct segment_command *segmentPrelinkText = segmentWithName(@"__PRELINK_TEXT", kernelFile);
    
    NSArray *prelinkInfo = arrayOfPrelinkInfo(segmentPrelinkInfo, kernelFile);
    NSArray *blobsArray = arrayOfKextBlobs(segmentPrelinkText, kernelFile);
    NSDictionary *namedBlobs = namedKernelExtensions(prelinkInfo, blobsArray);
    
    for (NSString *blobIdentifier in namedBlobs) {
        [[namedBlobs objectForKey:blobIdentifier] writeToFile:[NSString stringWithFormat:@"kexts/%@", blobIdentifier] atomically:YES];
    }
    
    [pool drain];
    return 0;
}

NSDictionary *namedKernelExtensions(NSArray *prelinkInfo, NSArray *kernelExtensionBlobs) {
    NSMutableDictionary *namedDictionary = [NSMutableDictionary dictionaryWithCapacity:[kernelExtensionBlobs count]];
    
    for (NSData *kext in kernelExtensionBlobs) {
        const char *bytes = [kext bytes];
        struct segment_command *segmentText = segmentWithName(@"__TEXT", (void *)bytes);
        uint32_t vmAddr = segmentText->vmaddr - 0x1000; // TODO: why?
        NSNumber *vmAddrNumber = [NSNumber numberWithLong:vmAddr];
        
        NSUInteger prelinkIndex = [prelinkInfo indexOfObjectPassingTest:^(id obj, NSUInteger idx, BOOL *stop) {
            NSNumber *loadAddr = [obj objectForKey:[NSString stringWithUTF8String:kPrelinkExecutableLoadKey]];
            if ([loadAddr isEqualToNumber:vmAddrNumber]) {
                *stop = YES;
                return YES;
            }
            
            return NO;
        }];
        
        if (prelinkIndex == NSNotFound) continue;
        
        NSString *identifier = [[prelinkInfo objectAtIndex:prelinkIndex] objectForKey:(NSString *)kCFBundleIdentifierKey];
        [namedDictionary setObject:kext forKey:identifier];
    }
    
    return namedDictionary;
}

struct segment_command *segmentWithName(NSString *segmentName, void *kernelFile) {
    struct mach_header *header = NULL;
    struct load_command *checkCommand = NULL;
    struct segment_command *segmentCommand = NULL;
    uint32_t segment = 0;
    
    header = kernelFile;
    const char *utf8String = [segmentName UTF8String];
    checkCommand = kernelFile + sizeof(struct mach_header);
    
    do {
        if (checkCommand->cmd == LC_SEGMENT) {        
            segmentCommand = (struct segment_command *)checkCommand;
            if (strncmp(segmentCommand->segname, utf8String, 16) == 0) return segmentCommand;
        }
        
        checkCommand = (void *)checkCommand + checkCommand->cmdsize;
    } while (++segment < header->ncmds);
    
    return segmentCommand;
}

NSArray *arrayOfKextBlobs(struct segment_command *segmentCommand, void *kernelFile) { 
    const char *magic = "\xCE\xFA\xED\xFE\x0C\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00";
    char *reference = NULL;
    
    uint32_t textOffset = segmentCommand->fileoff;
    uint32_t textSize = segmentCommand->filesize;
    NSMutableArray *kextObjects = [NSMutableArray array];
    
    reference = kernelFile + textOffset;
    while (reference < kernelFile + textOffset + textSize) {
        reference = strstr(reference, magic);
        uint32_t objectSize = sizeOfMachOObject((struct mach_header *)reference);
        
        NSData *objectData = [[NSData alloc] initWithBytes:reference length:objectSize];
        [kextObjects addObject:objectData];
        [objectData release];
        
        reference = reference + objectSize;        
    }

    return kextObjects;
}

uint32_t sizeOfMachOObject(struct mach_header *header) {
    struct load_command *checkCommand = NULL;
    struct segment_command *segmentCommand = NULL;
    uint32_t segment = 0;
    
    uint32_t fileSize = 0;
    uint32_t fileOffset = 0;
    
    checkCommand = (void *)header + sizeof(struct mach_header);
    do {
        if (checkCommand->cmd == LC_SEGMENT) {        
            segmentCommand = (struct segment_command *)checkCommand;
            if (segmentCommand->fileoff > fileOffset) {
                fileOffset = segmentCommand->fileoff;
                fileSize = segmentCommand->filesize;
            }
        }
        
        checkCommand = (void *)checkCommand + checkCommand->cmdsize;
    } while (++segment < header->ncmds);
    
    return fileOffset + fileSize;
}

NSArray *arrayOfPrelinkInfo(struct segment_command *segmentCommand, void *kernelFile) {
    uint32_t infoOffset = segmentCommand->fileoff;
    uint32_t infoSize = segmentCommand->filesize;

    NSData *kextsPlistData = [[NSData alloc] initWithBytesNoCopy:(kernelFile + infoOffset) length:infoSize];
    kextsPlistData = preprocessPlist(kextsPlistData);
    
    NSDictionary *kextsPlistRoot = [NSPropertyListSerialization propertyListWithData:kextsPlistData options:0 format:nil error:nil];
    NSArray *prelinkInfo = [kextsPlistRoot objectForKey:[NSString stringWithUTF8String:kPrelinkInfoDictionaryKey]];

    [kextsPlistData release];
    return prelinkInfo;
}

NSData *preprocessPlist(NSData *inputData) {
    NSMutableString *intermediateString = [[NSMutableString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    [intermediateString replaceOccurrencesOfRegex:@"<integer IDREF=\"([^\"]+)\"\\/>" withString:@"<integer>0</integer>"];
    
    NSData *outputData = [NSData dataWithBytes:[intermediateString UTF8String] length:[intermediateString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    
    [intermediateString release];
    return outputData;
    
}
