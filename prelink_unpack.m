/*
 *  prelink_unpack.m
 *  prelink_unpack
 *
 *  Copyright (c) 2010 Aidan Steele, Glass Echidna
 * 
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *  
 *  The above copyright notice and this permission notice shall be included in
 *  all copies or substantial portions of the Software.
 *  
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 *  THE SOFTWARE.
 */

#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import "prelink.h"
#import "RegexKitLite.h"
#import "NSData+MultipleReplacements.h"
  
NSData *preprocessPlist(NSData *inputData);
struct segment_command *segmentWithName(NSString *segmentName, void *kernelFile);
NSArray *arrayOfPrelinkInfo(struct segment_command *segmentCommand, void *kernelFile);
NSArray *arrayOfKextBlobs(struct segment_command *segmentCommand, void *kernelFile);
uint32_t sizeOfMachOObject(struct mach_header *header);
NSDictionary *namedKernelExtensions(NSArray *prelinkInfo, NSArray *kernelExtensionBlobs);
NSData *kernelWithoutPrelinkedKexts(void *kernelFile);
NSArray *removePrelinkedKexts(NSMutableData *unlinkedKernel, void *kernelFile, BOOL removePrelinkSegments);
void adjustKernelOffsets(NSMutableData *unlinkedKernel, NSArray *removedRanges);
void createKernelExtensionFileHierarchy(NSDictionary *namedKexts);
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
    NSDictionary *namedKexts = namedKernelExtensions(prelinkInfo, blobsArray);
    createKernelExtensionFileHierarchy(namedKexts);
    
    NSData *kernelData = kernelWithoutPrelinkedKexts(kernelFile);
    [kernelData writeToFile:@"mach_kernel" atomically:YES];
    
    [pool drain];
    return 0;
}

void createKernelExtensionFileHierarchy(NSDictionary *namedKexts) {
    for (NSString *kextName in namedKexts) {
        NSArray *kextArray = [namedKexts objectForKey:kextName];
        NSData *kextBlob = [kextArray objectAtIndex:0];
        id kextPlist = [kextArray objectAtIndex:1];
        
        NSString *kextPath = [NSString stringWithFormat:@"kexts/%@.kext/Contents/MacOS", kextName];
        [[NSFileManager defaultManager] createDirectoryAtPath:kextPath withIntermediateDirectories:YES attributes:nil error:nil];
        [kextBlob writeToFile:[kextPath stringByAppendingPathComponent:kextName] atomically:YES];
        [kextPlist writeToFile:[[kextPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    }
}

NSData *kernelWithoutPrelinkedKexts(void *kernelFile) {
    uint32_t kernelSize = sizeOfMachOObject(kernelFile);
    NSMutableData *unlinkedKernel = [NSMutableData dataWithBytes:kernelFile length:kernelSize];
    
    NSArray *removedRanges = removePrelinkedKexts(unlinkedKernel, kernelFile, NO);
    adjustKernelOffsets(unlinkedKernel, removedRanges);
    
    return unlinkedKernel;
}

void adjustKernelOffsets(NSMutableData *unlinkedKernel, NSArray *removedRanges) {
    void *kernelFile = (void *)[unlinkedKernel bytes];
    
    NSArray *sortedRanges = [removedRanges sortedArrayUsingFunction:rangeSort context:nil];
    NSUInteger (^newOffset)(NSUInteger) = ^(NSUInteger oldOffset) {
        NSUInteger delta = 0;
        NSValue *rangeValue = nil;
        NSEnumerator *rangeEnum = [sortedRanges objectEnumerator];
        
        while ((rangeValue = [rangeEnum nextObject]) && oldOffset > [rangeValue rangeValue].location) delta += [rangeValue rangeValue].length;
        return oldOffset - delta;
    };
    
    struct mach_header *header = NULL;
    struct load_command *checkCommand = NULL;
    struct segment_command *segmentCommand = NULL;
    struct symtab_command *symtabCommand = NULL;
    struct section *section = NULL;
    uint32_t segment = 0;
    
    header = kernelFile;
    checkCommand = kernelFile + sizeof(struct mach_header);
    
    do {
        if (checkCommand->cmd == LC_SEGMENT) {
            segmentCommand = (struct segment_command *)checkCommand;
            segmentCommand->fileoff = newOffset(segmentCommand->fileoff);
            
            for (uint32_t sectionIdx = 0; sectionIdx < segmentCommand->nsects; sectionIdx++) {
                section = (void *)segmentCommand + sizeof(struct segment_command) + sectionIdx * sizeof(struct section);
                section->offset = newOffset(section->offset);
                section->reloff = newOffset(section->reloff);
            }
            
        } else if (checkCommand->cmd == LC_SYMTAB) {
            symtabCommand = (struct symtab_command *)checkCommand;
            symtabCommand->symoff = newOffset(symtabCommand->symoff);
            symtabCommand->stroff = newOffset(symtabCommand->stroff);
        }
        
        checkCommand = (void *)checkCommand + checkCommand->cmdsize;
    } while (++segment < header->ncmds);
}

NSArray *removePrelinkedKexts(NSMutableData *linkedKernel, void *kernelFile, BOOL removePrelinkSegments) {
    const NSUInteger numberOfSegments = 3;
    
    void *linkedKernelFile = (void *)[linkedKernel bytes];
    struct mach_header *header = linkedKernelFile;
    
    NSMutableArray *segmentReplacementRanges = [[NSMutableArray alloc] initWithCapacity:(numberOfSegments * 2)];
    NSMutableArray *segmentReplacementDatas = [[NSMutableArray alloc] initWithCapacity:(numberOfSegments * 2)];
    NSData *nilData = [[NSData alloc] init];
    
    NSUInteger removedSegmentsSize = 0;
    
    for (NSString *segmentName in [NSArray arrayWithObjects:@"__PRELINK_INFO", @"__PRELINK_TEXT", @"__PRELINK_STATE", nil]) {
        struct segment_command *segmentCommand = segmentWithName(segmentName, kernelFile);
        NSRange segmentCmdRange = NSMakeRange((void *)segmentCommand - kernelFile, segmentCommand->cmdsize);
        NSRange segmentDataRange = NSMakeRange(segmentCommand->fileoff, segmentCommand->filesize);
                
        
        if (!removePrelinkSegments) {
            segmentCmdRange = NSMakeRange((void *)segmentCommand - kernelFile + sizeof(struct segment_command), 
                                          segmentCommand->cmdsize - sizeof(struct segment_command));
            
            void *linkedKernelFile = (void *)[linkedKernel bytes];
            struct segment_command *mutableSegmentCommand = linkedKernelFile + ((void *)segmentCommand - kernelFile);
            
            mutableSegmentCommand->fileoff = 0;
            mutableSegmentCommand->filesize = 0;
            mutableSegmentCommand->nsects = 0;
            mutableSegmentCommand->cmdsize = sizeof(struct segment_command);
            removedSegmentsSize += segmentCommand->cmdsize - sizeof(struct segment_command);       
        } else {
           removedSegmentsSize += segmentCommand->cmdsize;  
        }
        
         
        [segmentReplacementRanges addObject:[NSValue valueWithRange:segmentCmdRange]];
        [segmentReplacementDatas addObject:nilData];
        
        [segmentReplacementRanges addObject:[NSValue valueWithRange:segmentDataRange]];
        [segmentReplacementDatas addObject:nilData];
    }
    
    [linkedKernel replaceBytesInRanges:segmentReplacementRanges withDatas:segmentReplacementDatas];
    if (removePrelinkSegments) header->ncmds -= numberOfSegments;
    header->sizeofcmds -= removedSegmentsSize;
    
    [segmentReplacementDatas release];
    [nilData release];
    return [segmentReplacementRanges autorelease];
}

NSDictionary *namedKernelExtensions(NSArray *prelinkInfo, NSArray *kernelExtensionBlobs) {
    NSMutableDictionary *namedDictionary = [NSMutableDictionary dictionaryWithCapacity:[kernelExtensionBlobs count]];
    
    for (NSData *kextBlob in kernelExtensionBlobs) {
        const char *bytes = [kextBlob bytes];
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
        
        NSString *identifier = [[prelinkInfo objectAtIndex:prelinkIndex] objectForKey:(NSString *)kCFBundleExecutableKey];
        NSArray *kextEntry = [NSArray arrayWithObjects:kextBlob, [prelinkInfo objectAtIndex:prelinkIndex], nil];
        [namedDictionary setObject:kextEntry forKey:identifier];
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
        
        NSData *objectData = [[NSData alloc] initWithBytesNoCopy:reference length:objectSize freeWhenDone:NO];
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

    NSData *kextsPlistData = [NSData dataWithBytesNoCopy:(kernelFile + infoOffset) length:infoSize freeWhenDone:NO];
    kextsPlistData = preprocessPlist(kextsPlistData);
    
    NSDictionary *kextsPlistRoot = [NSPropertyListSerialization propertyListWithData:kextsPlistData options:0 format:nil error:nil];
    NSArray *prelinkInfo = [kextsPlistRoot objectForKey:[NSString stringWithUTF8String:kPrelinkInfoDictionaryKey]];

    return prelinkInfo;
}

NSData *preprocessPlist(NSData *inputData) {
    NSMutableString *intermediateString = [[NSMutableString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    [intermediateString replaceOccurrencesOfRegex:@"<integer IDREF=\"([^\"]+)\"\\/>" withString:@"<integer>0</integer>"];
    
    NSData *outputData = [NSData dataWithBytes:[intermediateString UTF8String] length:[intermediateString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    
    [intermediateString release];
    return outputData;
    
}
