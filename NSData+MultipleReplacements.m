/*
 *  NSData+MultipleReplacements.m
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

#import "NSData+MultipleReplacements.h"

NSInteger rangeSort(id valueA, id valueB, void *context)
{
    NSRange rangeA = [valueA rangeValue];
    NSRange rangeB = [valueB rangeValue];
    
    if (rangeA.location < rangeB.location) {
        return NSOrderedAscending;
    } else if (rangeA.location == rangeB.location) {
        return NSOrderedSame;
    } else {
        return NSOrderedDescending;//NSOrderedDescending;
    }
}

@implementation NSMutableData (NSData_MultipleReplacements)

- (void)replaceBytesInRanges:(NSArray *)ranges withDatas:(NSArray *)datas {
    if ([ranges count] != [datas count]) @throw [NSException exceptionWithName:@"-replaceBytesInRanges" reason:nil userInfo:nil];
    
    /*NSArray *sortedRangesBroken = [ranges sortedArrayUsingComparator:(NSComparator)^(id a, id b) {
        NSRange rangeA = [a rangeValue];
        NSRange rangeB = [b rangeValue];
        
        if (rangeA.location < rangeB.location) {
            return NSOrderedAscending;
        } else if (rangeA.location == rangeB.location) {
            return NSOrderedSame;
        } else {
            return NSOrderedDescending;
        }
        
        //return ((rangeA.location < rangeB.location) ? NSOrderedAscending : NSOrderedDescending);
    }];*/
    
    NSArray *sortedRanges = [ranges sortedArrayUsingFunction:rangeSort context:NULL];
    NSMutableArray *newRanges = [[NSMutableArray alloc] initWithCapacity:[sortedRanges count]];
    
    
    NSInteger currentDelta = 0;
    for (int idx = 0; idx < [sortedRanges count]; idx++) {
        NSRange range = [[sortedRanges objectAtIndex:idx] rangeValue];
        NSData *data = [datas objectAtIndex:idx];
        NSInteger delta = [data length] - range.length;
        
        range.location += currentDelta;
        currentDelta += delta;
        
        NSValue *newRangeValue = [NSValue valueWithRange:range];
        [newRanges addObject:newRangeValue];
    }
    
    for (int idx = 0; idx < [newRanges count]; idx++) {
        NSRange range = [[newRanges objectAtIndex:idx] rangeValue];
        NSData *data = [datas objectAtIndex:idx];
        
        [self replaceBytesInRange:range withBytes:[data bytes] length:[data length]];
    }
}

- (void)insertData:(NSData *)data atOffset:(NSUInteger)offset {
    [self replaceBytesInRange:NSMakeRange(offset, 0) withBytes:[data bytes] length:[data length]];
}

+ (id)dataWithDatas:(NSData *)firstData, ... {
    NSMutableData *mutableData = [NSMutableData dataWithCapacity:[firstData length]];
    
    va_list args;
    va_start(args, firstData);
    
    NSData *data;
    for (data = firstData; data != nil; data = va_arg(args, NSData *)) [mutableData appendData:data];
    va_end(args);
    
    return mutableData;
}

@end
