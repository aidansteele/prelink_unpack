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
#import <mach-o/nlist.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <string.h>
#import <fcntl.h>
#import "prelink.h"
#import "RegexKitLite.h"
#import "NSData+MultipleReplacements.h"
  
NSData *preprocessPlist(NSData *inputData);
struct load_command *loadCommandPassingTest(void *kernelFile, BOOL (^commandTest)(struct load_command *));
struct segment_command *segmentWithName(NSString *segmentName, void *kernelFile);
NSArray *arrayOfPrelinkInfo(struct segment_command *segmentCommand, void *kernelFile);
NSArray *arrayOfKextBlobs(struct segment_command *segmentCommand, void *kernelFile);
uint32_t sizeOfMachOObject(struct mach_header *header);
NSDictionary *kextEntryPoints(void *kernelFile, NSArray *prelinkInfoArray);
NSDictionary *namedKernelExtensions(NSArray *prelinkInfo, NSArray *kernelExtensionBlobs);
NSData *kernelWithoutPrelinkedKexts(void *kernelFile);
NSArray *removePrelinkedKexts(NSMutableData *unlinkedKernel, void *kernelFile, BOOL removePrelinkSegments);
void symbolicateKexts(NSDictionary *entryPoints, NSDictionary *namedExtensions);
struct section *sectionContainingAddress(void *kernelFile, uint32_t address, BOOL isOffset, uint32_t *sectionNumber);
void adjustOffsets(NSMutableData *unlinkedKernel, NSArray *ranges, BOOL removed);
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
    NSDictionary *entryPoints = kextEntryPoints(kernelFile, prelinkInfo);
    NSDictionary *namedKexts = namedKernelExtensions(prelinkInfo, blobsArray);
    symbolicateKexts(entryPoints, namedKexts);
    NSData *kernelData = kernelWithoutPrelinkedKexts(kernelFile);
    
    createKernelExtensionFileHierarchy(namedKexts);
    [kernelData writeToFile:@"mach_kernel" atomically:YES];
    
    // print entrypoints to stdout
    for (NSString *kextName in entryPoints) {
        NSArray *addresses = [entryPoints objectForKey:kextName];
        NSNumber *startAddress = [addresses objectAtIndex:0];
        NSNumber *stopAddress = [addresses objectAtIndex:1];
        
        printf("%sStart: 0x%x\n%sStop: 0x%x\n\n", [kextName UTF8String], [startAddress unsignedIntValue], [kextName UTF8String], [stopAddress unsignedIntValue]);
    }
    
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
    adjustOffsets(unlinkedKernel, removedRanges, YES);
    
    return unlinkedKernel;
}

void adjustOffsets(NSMutableData *unlinkedKernel, NSArray *ranges, BOOL removed) {
    void *kernelFile = (void *)[unlinkedKernel bytes];
    
    NSArray *sortedRanges = [ranges sortedArrayUsingFunction:rangeSort context:nil];
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
            void *linkedKernelFile = (void *)[linkedKernel bytes];
            struct segment_command *mutableSegmentCommand = linkedKernelFile + ((void *)segmentCommand - kernelFile);

            for (int sectionIdx = 0; sectionIdx < segmentCommand->nsects; sectionIdx++) {
                struct section *mutableSection = linkedKernelFile + ((void *)segmentCommand - kernelFile) + sizeof(struct segment_command) + (sizeof(struct section) * sectionIdx);
                mutableSection->size = 0;
                mutableSection->offset = 0;
                mutableSection->reloff = 0; 
            }
            
            mutableSegmentCommand->fileoff = 0;
            mutableSegmentCommand->filesize = 0;     
        } else {
            removedSegmentsSize += segmentCommand->cmdsize; 
            [segmentReplacementRanges addObject:[NSValue valueWithRange:segmentCmdRange]];
            [segmentReplacementDatas addObject:nilData];
        }

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
    
    for (NSDictionary *prelink in prelinkInfo) {
        NSNumber *loadAddr = [prelink objectForKey:[NSString stringWithUTF8String:kPrelinkExecutableLoadKey]];
        
        NSUInteger kextBlobIndex = [kernelExtensionBlobs indexOfObjectPassingTest:^(id kextBlob, NSUInteger idx, BOOL *stop) {
            const char *bytes = [kextBlob bytes];
            
            struct segment_command *segmentText = (struct segment_command *)loadCommandPassingTest((void *)bytes, ^(struct load_command *command) {
                if (command->cmd == LC_SEGMENT) {
                    return (BOOL)(((struct segment_command *)command)->vmaddr - 0x1000 /* TODO: why? */ == [loadAddr unsignedIntValue]);
                }
                
                return NO;
            });
            
            return (BOOL)(segmentText != NULL);
        }];
        
        if (kextBlobIndex == NSNotFound) continue;        
        
        NSData *kextBlob = [kernelExtensionBlobs objectAtIndex:kextBlobIndex];
        NSString *identifier = [prelink objectForKey:(NSString *)kCFBundleExecutableKey];
        
        NSArray *kextEntry = [NSArray arrayWithObjects:kextBlob, prelink, nil];
        [namedDictionary setObject:kextEntry forKey:identifier];
    }
    
    return namedDictionary;
}

struct load_command *loadCommandPassingTest(void *kernelFile, BOOL (^commandTest)(struct load_command *)) {
    struct load_command *checkCommand = NULL;
    uint32_t loadCommand = 0;
    
    struct mach_header *header = kernelFile;
    checkCommand = kernelFile + sizeof(struct mach_header);
    
    do {
        if (commandTest(checkCommand) == YES) return checkCommand;
        checkCommand = (void *)checkCommand + checkCommand->cmdsize;
    } while (++loadCommand < header->ncmds);
    
    return NULL;
    
}

struct segment_command *segmentWithName(NSString *segmentName, void *kernelFile) {
    const char *utf8String = [segmentName UTF8String];
    
    return (struct segment_command *)loadCommandPassingTest(kernelFile, ^(struct load_command *command) {
        return (BOOL)(strncmp(((struct segment_command *)command)->segname, utf8String, 16) == 0);
    });
}

struct section *sectionContainingAddress(void *kernelFile, uint32_t address, BOOL isOffset, uint32_t *sectionNumber) {
    return (struct section *)loadCommandPassingTest(kernelFile, ^(struct load_command *command) {
        uint32_t sectionCount = 0;
        if (isOffset) {
            return NO;
        } else {
            if (command->cmd == LC_SEGMENT) {
                struct segment_command *segment = (struct segment_command *)command;
                for (int sectionIdx = 0; sectionIdx < segment->nsects; sectionIdx++) {
                    sectionCount++;
                    struct section *section = (struct section *)((void *)segment + sizeof(struct segment_command) + (sectionIdx * sizeof(struct section)));
                    
                    if (address >= section->addr && address < section->addr + section->size) {
                        if (sectionNumber) *sectionNumber = sectionCount;
                        return YES;
                    }
                }
                
            }
        }
        
        return NO;        
    });
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
        
        NSMutableData *objectData = [[NSMutableData alloc] initWithBytesNoCopy:reference length:objectSize freeWhenDone:NO];
        [kextObjects addObject:objectData];
        [objectData release];
        
        reference = reference + objectSize;        
    }

    return kextObjects;
}

void symbolicateKexts(NSDictionary *entryPoints, NSDictionary *namedExtensions) {
    unsigned char *symbolStrings = NULL;
    struct mach_header *header = NULL;
    const uint32_t numberSymbols = 3; // KextStart(), KextStop(), _kmod_info
    
    for (NSString *kextName in entryPoints) {
        NSData *kextObject = [[namedExtensions objectForKey:kextName] objectAtIndex:0];
        NSArray *addresses = [entryPoints objectForKey:kextName];
        
        NSNumber *startAddress = [addresses objectAtIndex:0];
        NSNumber *stopAddress = [addresses objectAtIndex:1];
        NSNumber *kmodAddress = [addresses objectAtIndex:2];
        
        if (![kextObject isKindOfClass:[NSMutableData class]]) error("Kext is not stored in NSMutableData");
        NSMutableData *mutableKext = (NSMutableData *)kextObject;
        header = (struct mach_header *)[mutableKext bytes]; 
        
        NSUInteger startSymbolLength = [kextName length] + 7; // "_..Start\x00"
        NSUInteger stopSymbolLength = [kextName length] + 6; // "_..Stop\x00"
        NSUInteger kmodSymbolLength = 11; // "_kmod_info\x00"
        NSUInteger stringsLength = startSymbolLength + stopSymbolLength + kmodSymbolLength + 4; // \x00\x00\x00\x00 at start of table
        
        NSString *startSymbol = [NSString stringWithFormat:@"_%@Start", kextName];
        NSString *stopSymbol = [NSString stringWithFormat:@"_%@Stop", kextName];
        
        symbolStrings = malloc(stringsLength);
        memset(symbolStrings, 0, stringsLength);
        memcpy(symbolStrings + 4, [startSymbol UTF8String], startSymbolLength);
        memcpy(symbolStrings + 4 + startSymbolLength, [stopSymbol UTF8String], stopSymbolLength);
        memcpy(symbolStrings + 4 + startSymbolLength + stopSymbolLength, "_kmod_info", kmodSymbolLength);
        
        uint32_t dataSectionNumber = 0, startSectionNumber = 0, stopSectionNumber = 0;
        sectionContainingAddress((void *)header, [kmodAddress unsignedIntValue], NO, &dataSectionNumber);
        sectionContainingAddress((void *)header, [startAddress unsignedIntValue], NO, &startSectionNumber);
        sectionContainingAddress((void *)header, [stopAddress unsignedIntValue], NO, &stopSectionNumber);
        
        struct symtab_command symtabCommand = {
            .cmd = LC_SYMTAB,
            .cmdsize = sizeof(struct symtab_command),
            .nsyms = numberSymbols, 
            .strsize = stringsLength,
        };
        
        struct nlist symbols[] = {{
            .n_un = 0x4, // \x00\x00\x00\x00 at start of table
            .n_type = N_EXT|N_SECT,
            .n_sect = startSectionNumber,
            .n_desc = 0,
            .n_value = [startAddress unsignedIntValue],
        }, {
            .n_un = 0x4 + startSymbolLength, // \x00\x00\x00\x00 and MyKextStop\x00 at start of table 
            .n_type = N_EXT|N_SECT,
            .n_sect = stopSectionNumber,
            .n_desc = 0,
            .n_value = [stopAddress unsignedIntValue],
        }, {
            .n_un = 0x4 + startSymbolLength + stopSymbolLength, // \x00\x00\x00\x00 and MyKextStop\x00 at start of table 
            .n_type = N_EXT|N_SECT,
            .n_sect = dataSectionNumber,
            .n_desc = 0,
            .n_value = [kmodAddress unsignedIntValue],
        }};
       
        NSMutableData *segmentData = [[NSMutableData alloc] initWithBytesNoCopy:&symtabCommand length:sizeof(struct symtab_command) freeWhenDone:NO];       
        NSMutableData *symbolTableData = [[NSMutableData alloc] initWithBytesNoCopy:symbolStrings length:stringsLength freeWhenDone:NO];
        [symbolTableData appendBytes:symbols length:(numberSymbols * sizeof(struct nlist))];
        
        NSUInteger symtabSegmentCmdOffset = sizeof(struct mach_header) + header->sizeofcmds;
        NSArray *rangesArray = [NSArray arrayWithObject:[NSValue valueWithRange:NSMakeRange(symtabSegmentCmdOffset, sizeof(struct symtab_command))]];
        
        [mutableKext insertData:segmentData atOffset:symtabSegmentCmdOffset];
        adjustOffsets(mutableKext, rangesArray, NO);
        
        header->ncmds += 1;//2;
        header->sizeofcmds += sizeof(struct symtab_command);// + sizeof(struct uuid_command);
        
        NSUInteger machoBinaryLength = [mutableKext length];
        [mutableKext insertData:symbolTableData atOffset:machoBinaryLength]; // add to end TODO: why not just append?
        
        // TODO: Work-around for rdar://8650086
        NSUInteger sizeDifference = numberSymbols * (sizeof(struct nlist_64) - sizeof(struct nlist));
        [mutableKext increaseLengthBy:sizeDifference];
        
        struct symtab_command *embeddedCommand = (struct symtab_command *)loadCommandPassingTest(header, ^(struct load_command *command) {
            return (BOOL)(command->cmd == LC_SYMTAB);
        });
        
        if (!embeddedCommand) error("Unable to symbolicate kexts.");
        
        embeddedCommand->stroff = machoBinaryLength;
        embeddedCommand->symoff = machoBinaryLength + stringsLength;
        
        [segmentData release];
        [symbolTableData release];
        free(symbolStrings);
        symbolStrings = NULL;
    }
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

NSDictionary *kextEntryPoints(void *kernelFile, NSArray *prelinkInfoArray) {
    NSMutableDictionary *entryPoints = [NSMutableDictionary dictionaryWithCapacity:[prelinkInfoArray count]];
    
    struct segment_command *prelinkTextSegment = segmentWithName(@"__PRELINK_TEXT", kernelFile);
    if (prelinkTextSegment->nsects != 1) error("Too many sections in __PRELINK_TEXT segment. Unsure how to proceed.");
    struct section *textSection = (void *)prelinkTextSegment + sizeof(struct segment_command);
    uint32_t prelinkLoadAddress = textSection->addr;
    void *basePointer = kernelFile + textSection->offset;
    
    for (NSDictionary *kextDict in prelinkInfoArray) {
        if ([kextDict objectForKey:[NSString stringWithUTF8String:kPrelinkKmodInfoKey]]) {
            NSNumber *kmodAddress = [kextDict objectForKey:[NSString stringWithUTF8String:kPrelinkKmodInfoKey]];
            NSString *identifier = [kextDict objectForKey:(NSString *)kCFBundleExecutableKey];
            
            kmod_info_32_v1_t *kmodInfo = basePointer + ([kmodAddress unsignedIntValue] - prelinkLoadAddress);
            NSNumber *startAddr = [NSNumber numberWithUnsignedInt:kmodInfo->start_addr];
            NSNumber *stopAddr = [NSNumber numberWithUnsignedInt:kmodInfo->stop_addr];
            
            [entryPoints setObject:[NSArray arrayWithObjects:startAddr, stopAddr, kmodAddress, nil] forKey:identifier];
        }
    }
    
    return entryPoints;
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
