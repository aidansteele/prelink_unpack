//
//  NSData+MultipleReplacements.m
//  prelink_unpack
//
//  Created by Aidan Steele on 5/11/10.
//  Copyright 2010 Glass Echidna. All rights reserved.
//

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
    
    NSArray *sortedRangesBroken = [ranges sortedArrayUsingComparator:(NSComparator)^(id a, id b) {
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
    }];
    
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

@end
